# SPDX-License-Identifier: MIT
"""Touch ID keyboard host certificate chain, on synthetic certificates only.

The certificates are built here (or by a throwaway openssl test CA) with the
chain's subject and issuer names. No Apple-issued certificate is used.
"""
import base64
import importlib.util
import os
import pathlib
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from asahi_firmware import touchid_host_chain as thc  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "stac_host_chain", REPO / "tools" / "stac-host-chain" / "stac_host_chain.py")
tool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tool)

CN, O, OU = b"\x55\x04\x03", b"\x55\x04\x0a", b"\x55\x04\x0b"
HEX = "0123456789abcdef" * 4


def tlv(tag, content):
    n = len(content)
    if n < 0x80:
        return bytes([tag, n]) + content
    if n < 0x100:
        return bytes([tag, 0x81, n]) + content
    return bytes([tag, 0x82, n >> 8, n & 0xff]) + content


def name(attrs):
    return tlv(0x30, b"".join(
        tlv(0x31, tlv(0x30, tlv(0x06, oid) + tlv(0x0c, value.encode()))) for oid, value in attrs))


def certificate(subject, issuer, serial, not_before="260101000000Z"):
    alg = tlv(0x30, tlv(0x06, bytes.fromhex("2a8648ce3d040302")))
    validity = tlv(0x30, tlv(0x17, not_before.encode()) + tlv(0x17, b"260102000000Z"))
    key = tlv(0x30, tlv(0x30, tlv(0x06, bytes.fromhex("2a8648ce3d0201"))
                        + tlv(0x06, bytes.fromhex("2a8648ce3d030107")))
              + tlv(0x03, b"\x00\x04" + bytes([serial]) * 64))
    tbs = tlv(0x30, tlv(0xa0, tlv(0x02, b"\x02")) + tlv(0x02, bytes([1, serial])) + alg
              + name(issuer) + validity + name(subject) + key + tlv(0xa3, tlv(0x30, b"")))
    return tlv(0x30, tbs + alg + tlv(0x03, b"\x00" + b"\x5a" * 70))


def leaf(cn=HEX, unit="BAA Certification", issuer="Basic Attestation User Sub CA2",
         serial=1, not_before="260101000000Z"):
    return certificate([(CN, cn), (OU, unit), (O, "Apple Inc.")],
                       [(CN, issuer), (O, "Apple Inc.")], serial, not_before)


def intermediate(serial=2):
    return certificate([(CN, "Basic Attestation User Sub CA2"), (O, "Apple Inc.")],
                       [(CN, "Basic Attestation User Root CA"), (O, "Apple Inc.")], serial)


def chain(l=None):
    return (l or leaf()) + intermediate()


def pem(der):
    body = base64.encodebytes(der).decode()
    return f"-----BEGIN CERTIFICATE-----\n{body}-----END CERTIFICATE-----\n"


def result(*blobs, **kw):
    s = thc.ChainScanner()
    for b in blobs:
        s.add(b)
    return s.result(**kw)


class ParserTest(unittest.TestCase):
    def test_raw_der_inside_other_bytes(self):
        self.assertEqual(result(b"\x30\x82\xff\xff\x00" + chain() + b"\x30\x82\x01"), chain())

    def test_pem_and_xml_plist(self):
        self.assertEqual(result((pem(leaf()) + pem(intermediate())).encode()), chain())
        xml = plistlib.dumps({"HostChain": chain(), "Other": "text"}, fmt=plistlib.FMT_XML)
        self.assertEqual(result(xml), chain())

    def test_binary_plist_with_separate_records(self):
        blob = plistlib.dumps({"certs": [intermediate(), leaf()]}, fmt=plistlib.FMT_BINARY)
        self.assertEqual(result(blob), chain())

    def test_copies_are_one_chain(self):
        self.assertEqual(result(chain(), base64.b64encode(chain()), chain() * 2), chain())

    def test_two_chains_are_ambiguous(self):
        other = chain(leaf("f" * 64, serial=9))
        with self.assertRaises(thc.ChainError):
            result(chain(), other)
        with self.assertRaises(thc.ChainError):
            result(chain(), other, newest_of_one_key=True)

    def test_newest_copy_of_one_key(self):
        old = chain(leaf(serial=3, not_before="250101000000Z"))
        new = chain(leaf(serial=4, not_before="260301000000Z"))
        with self.assertRaises(thc.ChainError):
            result(old, new)
        self.assertEqual(result(new, old, newest_of_one_key=True), new)

    def test_absent_and_incomplete(self):
        self.assertIsNone(result())
        self.assertIsNone(result(b"nothing"))
        self.assertIsNone(result(intermediate()))
        with self.assertRaises(thc.ChainError):
            result(leaf())
        self.assertEqual(result(leaf(), intermediate()), chain())

    def test_other_certificates_ignored(self):
        for l in (leaf("A" * 64), leaf("a" * 63), leaf(unit="Other"),
                  leaf(issuer="Basic Attestation User Sub CA1")):
            self.assertIsNone(result(chain(l)))

    def test_malformed_lengths(self):
        self.assertIsNone(result(chain()[:200]))
        padded = b"\x30\x83\x00" + leaf()[2:]
        self.assertIsNone(thc.certificate(padded, 0))
        bad = bytearray(chain())
        bad[6] = 0xff
        self.assertIsNone(thc.certificate(bytes(bad), 0))
        import random
        rng = random.Random(1)
        for _ in range(200):
            noisy = bytearray(chain())
            for _ in range(8):
                noisy[rng.randrange(len(noisy))] = rng.randrange(256)
            try:
                result(bytes(noisy))
            except thc.ChainError:
                pass

    def test_is_chain(self):
        self.assertTrue(thc.is_chain(chain()))
        self.assertFalse(thc.is_chain(intermediate() + leaf()))
        self.assertFalse(thc.is_chain(leaf()))
        self.assertFalse(thc.is_chain(chain() + b"\0"))


@unittest.skipUnless(shutil.which("openssl"), "needs openssl")
class OpensslTest(unittest.TestCase):
    """A real (self-made) CA hierarchy with the chain's names, signed by openssl."""

    def test_openssl_chain(self):
        with tempfile.TemporaryDirectory() as d:
            def run(*args):
                subprocess.run(["openssl", *args], cwd=d, check=True, capture_output=True)

            def key(n):
                run("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", n)

            for n in ("root.key", "sub.key", "leaf.key"):
                key(n)
            run("req", "-new", "-x509", "-key", "root.key", "-days", "1", "-out", "root.pem",
                "-subj", "/CN=Basic Attestation User Root CA/O=Apple Inc.")
            for k, subj, ca, cakey, out in (
                    ("sub.key", "/CN=Basic Attestation User Sub CA2/O=Apple Inc.",
                     "root.pem", "root.key", "sub.pem"),
                    ("leaf.key", f"/CN={HEX}/OU=BAA Certification/O=Apple Inc.",
                     "sub.pem", "sub.key", "leaf.pem")):
                run("req", "-new", "-key", k, "-subj", subj, "-out", "req.csr")
                run("x509", "-req", "-in", "req.csr", "-CA", ca, "-CAkey", cakey,
                    "-set_serial", "7", "-days", "1", "-out", out)
            pems = b""
            ders = []
            for n in ("leaf.pem", "sub.pem", "root.pem"):
                run("x509", "-in", n, "-outform", "DER", "-out", n + ".der")
                ders.append(pathlib.Path(d, n + ".der").read_bytes())
                pems += pathlib.Path(d, n).read_bytes()
            self.assertEqual(result(pems), ders[0] + ders[1])
            self.assertEqual(result(b"".join(ders)), ders[0] + ders[1])


class CollectionTest(unittest.TestCase):
    def test_update_reads_the_extracted_archive(self):
        with tempfile.TemporaryDirectory() as d:
            col = thc.TouchIDHostChainFWCollection(d)
            self.assertEqual(col.files(), [])
            os.makedirs(os.path.join(d, "apple"))
            with open(os.path.join(d, thc.FILENAME), "wb") as f:
                f.write(chain())
            col = thc.TouchIDHostChainFWCollection(d)
            self.assertEqual([(n, fw.data) for n, fw in col.files()],
                             [(thc.FILENAME, chain())])
            with open(os.path.join(d, thc.FILENAME), "wb") as f:
                f.write(leaf())
            self.assertEqual(thc.TouchIDHostChainFWCollection(d).files(), [])

    def test_tree_scan(self):
        with tempfile.TemporaryDirectory() as d:
            vol, outside = os.path.join(d, "vol"), os.path.join(d, "outside")
            os.makedirs(os.path.join(vol, "a", "b"))
            os.makedirs(outside)
            pathlib.Path(vol, "a", "b", "record.plist").write_bytes(
                plistlib.dumps({"c": chain()}, fmt=plistlib.FMT_XML))
            other = chain(leaf("e" * 64))
            pathlib.Path(outside, "other.der").write_bytes(other)
            os.symlink(os.path.join(outside, "other.der"), os.path.join(vol, "link.der"))
            os.symlink(outside, os.path.join(vol, "linkdir"))
            pathlib.Path(vol, "big.bin").write_bytes(other + bytes(1 << 20))
            self.assertEqual(thc.scan_tree(vol), (chain(), 0))
            with self.assertRaises(thc.ChainError):
                thc.scan_tree(vol, max_entries=2)
            with self.assertRaises(thc.ChainError):
                thc.scan_tree(vol, max_depth=1)
            with self.assertRaises(thc.ChainError):
                thc.scan_tree(vol, max_total=100)
            self.assertEqual(thc.scan_tree(os.path.join(d, "missing")), (None, 0))
            col = thc.TouchIDHostChainFWCollection.__new__(thc.TouchIDHostChainFWCollection)
            col.fwfiles = []
            col.load(vol)
            self.assertEqual([fw.data for _, fw in col.files()], [chain()])


def gpt_image(path, sector, part_first, part_last, payloads, type_guid=tool.ISC_TYPE):
    """A sparse disk image: a GPT naming one container partition, and
    payloads written at absolute offsets."""
    with open(path, "wb") as f:
        f.truncate((part_last + 34) * sector)
        entry = bytearray(128)
        entry[0:16] = type_guid.bytes_le
        entry[16:32] = uuid.uuid4().bytes_le
        struct.pack_into("<QQ", entry, 32, part_first, part_last)
        entry[56:56 + 40] = tool.ISC_NAME.encode("utf-16-le")
        header = bytearray(92)
        header[0:8] = b"EFI PART"
        struct.pack_into("<QII", header, 72, 2, 128, 128)
        f.seek(sector)
        f.write(header)
        f.seek(2 * sector)
        f.write(entry)
        f.seek(part_first * sector + 32)
        f.write(b"NXSB")
        for offset, data in payloads:
            f.seek(offset)
            f.write(data)


class ToolTest(unittest.TestCase):
    def test_carve_across_chunk_boundaries(self):
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "disk.img")
            sector, first, last = 4096, 64, 64 + 255
            base = first * sector
            # The chain straddles the first chunk boundary; a base64 copy
            # sits later; a different key's chain lies outside the partition.
            payloads = [(base + 8192 - 100, chain()),
                        (base + 300000, base64.b64encode(chain())),
                        ((last + 2) * sector, chain(leaf("e" * 64)))]
            gpt_image(img, sector, first, last, payloads)
            fd = os.open(img, os.O_RDONLY)
            try:
                self.assertEqual(tool.find_isc(fd), (base, (last + 1) * sector))
                self.assertEqual(
                    tool.carve(fd, base, (last + 1) * sector, chunk=8192, overlap=4096).result(),
                    chain())
            finally:
                os.close(fd)
            self.assertEqual(tool.collect(disk=img, chunk=8192, overlap=4096), chain())

    def test_512_byte_sectors_and_device_argument(self):
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "disk.img")
            gpt_image(img, 512, 40, 40 + 2047, [(40 * 512 + 5000, chain())])
            self.assertEqual(tool.collect(disk=img), chain())
            part = os.path.join(d, "part.img")
            with open(img, "rb") as f:
                f.seek(40 * 512)
                pathlib.Path(part).write_bytes(f.read(2048 * 512))
            self.assertEqual(tool.collect(device=part), chain())

    def test_absent_and_stale_copies(self):
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "disk.img")
            gpt_image(img, 4096, 64, 64 + 63, [])
            self.assertIsNone(tool.collect(disk=img))
            old = chain(leaf(serial=3, not_before="250101000000Z"))
            gpt_image(img, 4096, 64, 64 + 63, [(64 * 4096 + 9000, old),
                                               (64 * 4096 + 90000, chain())])
            self.assertEqual(tool.collect(disk=img), chain())
            gpt_image(img, 4096, 64, 64 + 63, [(64 * 4096 + 9000, chain()),
                                               (64 * 4096 + 90000, chain(leaf("e" * 64)))])
            with self.assertRaises(thc.ChainError):
                tool.collect(disk=img)

    def test_no_container_partition(self):
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "disk.img")
            gpt_image(img, 4096, 64, 127, [], type_guid=uuid.uuid4())
            # The name still matches; a disk with neither is refused.
            self.assertIsNone(tool.collect(disk=img))
            pathlib.Path(img).write_bytes(bytes(1 << 16))
            with self.assertRaises(tool.Refused):
                tool.collect(disk=img)

    def test_write_is_atomic_and_keeps_a_different_chain(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "apple", "stac-host-chain.der")
            self.assertTrue(tool.write(out, chain()))
            self.assertEqual(pathlib.Path(out).read_bytes(), chain())
            self.assertEqual(os.stat(out).st_mode & 0o777, 0o644)
            self.assertFalse(tool.write(out, chain()))
            other = chain(leaf("e" * 64))
            with self.assertRaises(tool.Refused):
                tool.write(out, other)
            self.assertEqual(pathlib.Path(out).read_bytes(), chain())
            self.assertTrue(tool.write(out, other, force=True))
            self.assertEqual(pathlib.Path(out).read_bytes(), other)
            with self.assertRaises(tool.Refused):
                tool.write(out, leaf(), force=True)
            self.assertEqual(sorted(os.listdir(os.path.dirname(out))), ["stac-host-chain.der"])

    def test_default_output_follows_running_bundles(self):
        with tempfile.TemporaryDirectory() as d:
            second = os.path.join(d, "run")
            os.makedirs(second)
            self.assertEqual(tool.default_output((os.path.join(d, "lib"), second)),
                             os.path.join(second, "stac-host-chain.der"))

    def test_main_check_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "disk.img")
            gpt_image(img, 4096, 64, 127, [(64 * 4096 + 5000, chain())])
            out = os.path.join(d, "out.der")
            self.assertEqual(tool.main(["--disk", img, "-o", out, "--check"]), 0)
            self.assertFalse(os.path.exists(out))
            self.assertEqual(tool.main(["--disk", img, "-o", out]), 0)
            self.assertEqual(pathlib.Path(out).read_bytes(), chain())
            gpt_image(img, 4096, 64, 127, [])
            self.assertEqual(tool.main(["--disk", img, "-o", out]), 2)


if __name__ == "__main__":
    unittest.main()
