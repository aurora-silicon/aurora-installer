# SPDX-License-Identifier: MIT
import base64, hashlib, json, os, plistlib, shutil, subprocess, sys, tempfile, unittest, zipfile
from types import SimpleNamespace
from unittest import mock

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "src"))

import aea  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
HAVE_AEA_TOOL = sys.platform == "darwin" and os.path.exists(aea.AEA_TOOL)
KEY_ID = "A" * 43 + "="
KEY_URL = "https://wkms-public.apple.com/fcs-keys/" + KEY_ID

def h(s):
    return bytes.fromhex(s)

def cryptokit_vectors(kind):
    with open(os.path.join(FIXTURES, "aea-cryptokit-vectors.json")) as fd:
        return [v for v in json.load(fd)["vectors"] if v["kind"] == kind]

def p256_pkcs8_pem(d):
    """A PKCS#8 PEM for P-256 scalar d (RFC 5915 inside RFC 5208)."""
    pub = aea._enc_point(aea._mul(d, aea._G))
    ec = (b"\x30\x6b\x02\x01\x01\x04\x20" + d.to_bytes(32, "big")
          + b"\xa1\x44\x03\x42\x00" + pub)
    der = (b"\x30\x81\x87\x02\x01\x00"
           b"\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07"
           b"\x04\x6d" + ec)
    b64 = base64.b64encode(der)
    lines = [b64[i:i + 64] for i in range(0, len(b64), 64)]
    return b"-----BEGIN PRIVATE KEY-----\n" + b"\n".join(lines) + b"\n-----END PRIVATE KEY-----\n", pub

def auth_blob(fields):
    out = b""
    for k, v in fields.items():
        entry = k.encode() + b"\0" + v
        out += (4 + len(entry)).to_bytes(4, "little") + entry
    return out

def write_aea_prologue(path, blob, profile=1):
    with open(path, "wb") as fd:
        fd.write(aea.AEA_MAGIC + profile.to_bytes(3, "little") + b"\0" + len(blob).to_bytes(4, "little") + blob)

def make_fcs_archive(tmp, plain, archive_key, d=0x1234567890ABCDEF, url=KEY_URL):
    """An AEA1 archive whose key is sealed to an FCS-style P-256 key, like Apple's."""
    pem, pub = p256_pkcs8_pem(d)
    enc, wrapped = aea.hpke_seal(pub, archive_key, eph_sk=0xC0FFEE)
    resp = json.dumps({"enc-request": base64.b64encode(enc).decode(),
                       "wrapped-key": base64.b64encode(wrapped).decode()}).encode()
    src = os.path.join(tmp, "plain.bin")
    with open(src, "wb") as fd:
        fd.write(plain)
    kpath = os.path.join(tmp, "key.txt")
    with open(kpath, "wb") as fd:
        fd.write(b"base64:" + base64.b64encode(archive_key))
    out = os.path.join(tmp, "payload.dmg.aea")
    subprocess.run([aea.AEA_TOOL, "encrypt", "-profile", "1", "-key", kpath, "-i", src, "-o", out,
                    "-auth-data-key", "com.apple.wkms.fcs-key-url",
                    "-auth-data-value", "base64:" + base64.b64encode(url.encode()).decode(),
                    "-auth-data-key", "com.apple.wkms.fcs-response",
                    "-auth-data-value", "base64:" + base64.b64encode(resp).decode()],
                   check=True)
    os.unlink(src)
    os.unlink(kpath)
    pem_dir = os.path.join(tmp, "pem")
    os.makedirs(pem_dir)
    with open(os.path.join(pem_dir, url.rsplit("/", 1)[1]), "wb") as fd:
        fd.write(pem)
    return out, pem_dir, pem


class GCMTest(unittest.TestCase):
    def test_gcm_spec_vectors(self):
        # McGrew & Viega, GCM specification, test cases 13 and 14 (AES-256)
        self.assertEqual(aea.aes256gcm_seal(bytes(32), bytes(12), b""), h("530f8afbc74536b9a963b4f1c4cb738b"))
        self.assertEqual(aea.aes256gcm_seal(bytes(32), bytes(12), bytes(16)),
                         h("cea7403d4d606b6e074ec5d3baf39d18") + h("d0d1c8a799996bf0265b98b5d48ab919"))

    def test_cryptokit_vector(self):
        v = cryptokit_vectors("gcm")[0]
        sealed = aea.aes256gcm_seal(h(v["key"]), h(v["nonce"]), h(v["pt"]), h(v["aad"]))
        self.assertEqual(sealed, h(v["ct"]) + h(v["tag"]))
        self.assertEqual(aea.aes256gcm_open(h(v["key"]), h(v["nonce"]), sealed, h(v["aad"])), h(v["pt"]))

    def test_tag_mismatch(self):
        sealed = bytearray(aea.aes256gcm_seal(bytes(32), bytes(12), b"hello world"))
        sealed[-1] ^= 1
        with self.assertRaises(aea.AEAError):
            aea.aes256gcm_open(bytes(32), bytes(12), bytes(sealed))


class HPKETest(unittest.TestCase):
    def vectors(self):
        return cryptokit_vectors("hpke")

    def test_open_cryptokit_vectors(self):
        vs = self.vectors()
        self.assertEqual(len(vs), 3)
        for v in vs:
            sk = int.from_bytes(h(v["sk"]), "big")
            self.assertEqual(aea._enc_point(aea._mul(sk, aea._G)), h(v["pk"]))
            self.assertEqual(aea.hpke_open(sk, h(v["enc"]), h(v["ct"])), h(v["pt"]))

    def test_seal_open_round_trip(self):
        sk = 0x5EED
        pk = aea._enc_point(aea._mul(sk, aea._G))
        enc, ct = aea.hpke_seal(pk, b"k" * 32, eph_sk=0xBEEF)
        self.assertEqual(aea.hpke_open(sk, enc, ct), b"k" * 32)
        with self.assertRaises(aea.AEAError):
            aea.hpke_open(sk + 1, enc, ct)

    def test_rejects_point_off_curve(self):
        v = self.vectors()[0]
        enc = bytearray(h(v["enc"]))
        enc[-1] ^= 1
        with self.assertRaises(aea.AEAError):
            aea.hpke_open(int.from_bytes(h(v["sk"]), "big"), bytes(enc), h(v["ct"]))

    def test_pkcs8(self):
        pem, _ = p256_pkcs8_pem(12345)
        self.assertEqual(aea.pkcs8_p256_scalar(pem), 12345)
        with self.assertRaises(aea.AEAError):
            aea.pkcs8_p256_scalar(b"-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n")


class AuthDataTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "x.aea")

    def tearDown(self):
        self.tmp.cleanup()

    def test_parse(self):
        write_aea_prologue(self.path, auth_blob({"a": b"1", "com.apple.wkms.fcs-key-url": KEY_URL.encode()}))
        profile, f = aea.aea_auth_data(self.path)
        self.assertEqual(profile, 1)
        self.assertEqual(f["com.apple.wkms.fcs-key-url"], KEY_URL.encode())

    def test_not_aea(self):
        with open(self.path, "wb") as fd:
            fd.write(b"koly" + bytes(100))
        self.assertFalse(aea.file_is_aea(self.path))
        with self.assertRaises(aea.AEAError):
            aea.aea_auth_data(self.path)

    def test_malformed_entries(self):
        good = auth_blob({"a": b"1"})
        for blob in (good[:-1],                               # entry overruns the blob
                     (3).to_bytes(4, "little"),               # length below the header
                     (8).to_bytes(4, "little") + b"abcd",     # no NUL separator
                     good + b"\x01\x00"):                     # trailing partial header
            write_aea_prologue(self.path, blob)
            with self.assertRaises(aea.AEAError, msg=blob.hex()):
                aea.aea_auth_data(self.path)

    def test_truncated_and_oversized(self):
        with open(self.path, "wb") as fd:
            fd.write(aea.AEA_MAGIC + b"\1\0\0\0" + (100).to_bytes(4, "little") + b"short")
        with self.assertRaises(aea.AEAError):
            aea.aea_auth_data(self.path)
        with open(self.path, "wb") as fd:
            fd.write(aea.AEA_MAGIC + b"\1\0\0\0" + (2 << 20).to_bytes(4, "little"))
        with self.assertRaises(aea.AEAError):
            aea.aea_auth_data(self.path)

    def test_missing_fcs_fields(self):
        write_aea_prologue(self.path, auth_blob({"com.apple.wkms.fcs-key-url": KEY_URL.encode()}))
        with self.assertRaises(aea.AEAError):
            aea.archive_key(self.path, pem=b"unused")


class KeyURLTest(unittest.TestCase):
    def test_allowed(self):
        aea.check_key_url(KEY_URL)
        aea.check_key_url("https://fcs-keys-pub-prod.cdn-apple.com/fcs-keys/" + KEY_ID)

    def test_rejected(self):
        for url in ("http://wkms-public.apple.com/fcs-keys/" + KEY_ID,
                    "https://wkms-public.apple.com.evil.example/fcs-keys/" + KEY_ID,
                    "https://evil.example/fcs-keys/" + KEY_ID,
                    "https://wkms-public.apple.com/fcs-keys/" + KEY_ID + "/../x",
                    "https://wkms-public.apple.com/fcs-keys/short=",
                    "https://wkms-public.apple.com/other/" + KEY_ID,
                    KEY_URL + "\n"):
            with self.assertRaises(aea.AEAError, msg=url):
                aea.check_key_url(url)

    def test_archive_key_checks_url_even_with_pem(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "x.aea")
            write_aea_prologue(path, auth_blob({
                "com.apple.wkms.fcs-key-url": b"https://evil.example/fcs-keys/" + KEY_ID.encode(),
                "com.apple.wkms.fcs-response": b'{"enc-request": "", "wrapped-key": ""}'}))
            with self.assertRaises(aea.AEAError):
                aea.archive_key(path, pem=b"unused")

    def test_redirect_off_service_refused(self):
        handler = aea._NoOffsiteRedirect()
        with self.assertRaises(aea.AEAError):
            handler.redirect_request(None, None, 301, "Moved", {}, "https://evil.example/fcs-keys/" + KEY_ID)


@unittest.skipUnless(HAVE_AEA_TOOL, "needs macOS /usr/bin/aea")
class DecryptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.plain = os.urandom(200_000) + b"koly" + bytes(508)
        self.archive, self.pem_dir, self.pem = make_fcs_archive(self.tmp.name, self.plain, os.urandom(32))
        self.digest = hashlib.sha384(self.plain).digest()

    def tearDown(self):
        self.tmp.cleanup()

    def leftovers(self, d):
        return [n for n in os.listdir(d) if n.startswith(".aea")]

    def test_archive_key_via_pem_dir(self):
        with mock.patch.dict(os.environ, {"AEA_FCS_PEM_DIR": self.pem_dir}):
            self.assertEqual(len(aea.archive_key(self.archive)), 32)

    def test_decrypt_verified(self):
        out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(out_dir)
        dst = os.path.join(out_dir, "payload.dmg")
        with mock.patch.dict(os.environ, {"AEA_FCS_PEM_DIR": self.pem_dir}):
            aea.decrypt_verified(self.archive, dst, self.digest)
        with open(dst, "rb") as fd:
            self.assertEqual(fd.read(), self.plain)
        mask = os.umask(0)
        os.umask(mask)
        self.assertEqual(os.stat(dst).st_mode & 0o777, 0o644 & ~mask)
        self.assertEqual(self.leftovers(out_dir), [])

    def test_in_place(self):
        aea.decrypt_verified(self.archive, self.archive, self.digest, pem=self.pem)
        self.assertFalse(aea.file_is_aea(self.archive))
        with open(self.archive, "rb") as fd:
            self.assertEqual(fd.read(), self.plain)

    def test_wrong_digest_leaves_nothing(self):
        out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(out_dir)
        dst = os.path.join(out_dir, "payload.dmg")
        with self.assertRaises(aea.AEAError):
            aea.decrypt_verified(self.archive, dst, hashlib.sha384(b"other").digest(), pem=self.pem)
        self.assertFalse(os.path.exists(dst))
        self.assertEqual(self.leftovers(out_dir), [])
        self.assertTrue(aea.file_is_aea(self.archive))

    def test_wrong_key_leaves_nothing(self):
        out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(out_dir)
        dst = os.path.join(out_dir, "payload.dmg")
        with self.assertRaises(aea.AEAError):
            aea.decrypt_verified(self.archive, dst, self.digest, key=bytes(32))
        self.assertFalse(os.path.exists(dst))
        self.assertEqual(self.leftovers(out_dir), [])

    def test_rejects_non_sha384(self):
        with self.assertRaises(aea.AEAError):
            aea.decrypt_verified(self.archive, self.archive + ".out", hashlib.sha256(self.plain).digest(),
                                 pem=self.pem)


@unittest.skipUnless(HAVE_AEA_TOOL, "needs macOS /usr/bin/aea")
class StubExtractTest(unittest.TestCase):
    """StubInstaller.extract_decrypted against a synthetic restore zip."""

    def setUp(self):
        import stub
        self.tmp = tempfile.TemporaryDirectory()
        self.plain = os.urandom(150_000)
        archive, self.pem_dir, _ = make_fcs_archive(self.tmp.name, self.plain, os.urandom(32))
        self.zip_path = os.path.join(self.tmp.name, "restore.ipsw")
        with zipfile.ZipFile(self.zip_path, "w", zipfile.ZIP_STORED) as z:
            z.write(archive, "043-00000-000.dmg.aea")
            z.writestr("Firmware/plain.im4p", b"0\x83IM4P plain component")
        self.ins = stub.StubInstaller(None, None, None)
        self.ins.pkg = zipfile.ZipFile(self.zip_path)
        self.ins.verbose = False
        self.scratch = os.path.join(self.tmp.name, "scratch")
        os.makedirs(self.scratch)
        self.env = mock.patch.dict(os.environ, {"AEA_FCS_PEM_DIR": self.pem_dir,
                                                "AEA_SCRATCH_DIR": self.scratch})
        self.env.start()
        self.quiet = mock.patch("sys.stdout")   # progress output
        self.quiet.start()

    def tearDown(self):
        self.quiet.stop()
        self.env.stop()
        self.ins.pkg.close()
        self.ins.cleanup_aea_scratch()
        self.tmp.cleanup()

    def test_encrypted_member_is_decrypted(self):
        val = {"Info": {"Path": "043-00000-000.dmg.aea"}, "Digest": hashlib.sha384(self.plain).digest()}
        dst = os.path.join(self.tmp.name, "pb", "restore", "043-00000-000.dmg.aea")
        self.assertTrue(self.ins.extract_decrypted("Ap,ExclaveOS", val, dst))
        with open(dst, "rb") as fd:
            self.assertEqual(fd.read(), self.plain)
        # the encrypted copy staged in scratch is gone
        self.assertEqual([n for n in os.listdir(self.ins.aea_scratch)], [])

    def test_plain_member_is_copied(self):
        val = {"Info": {"Path": "Firmware/plain.im4p"}}
        dst = os.path.join(self.tmp.name, "pb", "restore", "Firmware/plain.im4p")
        self.assertFalse(self.ins.extract_decrypted("SIO", val, dst))
        with open(dst, "rb") as fd:
            self.assertEqual(fd.read(), b"0\x83IM4P plain component")

    def test_digest_mismatch_aborts(self):
        val = {"Info": {"Path": "043-00000-000.dmg.aea"}, "Digest": hashlib.sha384(b"x").digest()}
        dst = os.path.join(self.tmp.name, "pb", "restore", "043-00000-000.dmg.aea")
        with self.assertRaises(aea.AEAError):
            self.ins.extract_decrypted("Ap,ExclaveOS", val, dst)
        self.assertFalse(os.path.exists(dst))

    def test_missing_digest_aborts(self):
        val = {"Info": {"Path": "043-00000-000.dmg.aea"}}
        with self.assertRaises(Exception):
            self.ins.extract_decrypted("Ap,ExclaveOS", val, os.path.join(self.tmp.name, "out"))

    def test_copy_compress_local(self):
        src = os.path.join(self.tmp.name, "image.dmg")
        with open(src, "wb") as fd:
            fd.write(self.plain * 3)
        dst = os.path.join(self.tmp.name, "compressed.dmg")
        with mock.patch("sys.stdout"):
            self.ins.copy_compress_local(src, dst)
        with open(dst, "rb") as fd:
            self.assertEqual(fd.read(), self.plain * 3)


class SelectionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import main
        cls.main = main

    def installer(self, device_class, chip_id, expert, sys_firmware="mBoot-20457.41.3",
                  macos="27.2", sfr="26.2.123.0.0,0"):
        m = self.main
        ins = m.InstallerMain.__new__(m.InstallerMain)
        ins.sysinfo = SimpleNamespace(device_class=device_class, chip_id=chip_id, sys_firmware=sys_firmware,
                                      macos_ver=macos, sfr_full_ver=sfr)
        ins.device = m.DEVICES[device_class]
        ins.expert = expert
        ins.choice = lambda prompt, options, default=None: default
        return ins

    def test_split_ver_mboot(self):
        sv = self.main.split_ver
        self.assertLess(sv("iBoot-13822.120.5"), sv("mBoot-20457.1.29"))
        self.assertLess(sv("mBoot-20457.1.29"), sv("mBoot-20457.41.3"))
        self.assertLessEqual(sv("mBoot-20457.1.29"), sv("mBoot-20457.1.29"))

    def test_27_0_for_j775c_in_expert_mode(self):
        with mock.patch("sys.stdout"):
            ipsw = self.installer("j775cap", 0x6050, True).choose_ipsw()
        self.assertEqual(ipsw.version, "27.0")
        self.assertTrue(ipsw.url.endswith("UniversalMac_27.0_26A428_Restore.ipsw"))

    def test_j775c_needs_expert(self):
        with mock.patch("sys.stdout"), self.assertRaises(SystemExit):
            self.installer("j775cap", 0x6050, False).choose_ipsw()

    def test_j775c_needs_new_enough_firmware(self):
        with mock.patch("sys.stdout"), self.assertRaises(SystemExit):
            self.installer("j775cap", 0x6050, True, sys_firmware="mBoot-20400.1.1").choose_ipsw()

    def test_27_0_not_offered_elsewhere(self):
        for ipsw in self.main.IPSW_VERSIONS:
            if ipsw.version == "27.0":
                self.assertEqual(ipsw.devices, ["j775cap"])
        with mock.patch("sys.stdout"):
            ipsw = self.installer("j813ap", 0x8142, True, sys_firmware="iBoot-13822.120.5",
                                  macos="26.6.1", sfr="25.7.76.0.0,0").choose_ipsw()
        self.assertEqual(ipsw.version, "26.6.1")

    def test_stub_size(self):
        m = self.main
        self.assertEqual(self.installer("j775cap", 0x6050, True).stub_size(),
                         m.align_down(m.psize("4GB"), m.PART_ALIGN))
        self.assertEqual(self.installer("j613ap", 0x8122, True).stub_size(), m.STUB_SIZE)


if __name__ == "__main__":
    unittest.main()
