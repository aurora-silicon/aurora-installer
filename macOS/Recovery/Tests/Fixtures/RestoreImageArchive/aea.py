"""Apple Encrypted Archive (profile 1) writer for the Recovery fixtures, with a disposable key.

An independent build of the format RestoreImageArchive.swift reads, after the restore image
helper's Go reference (macOS/RestoreImage/Reference/swift_aea_test.go) and
asahi_firmware/aea_ro.py: HKDF-SHA256 key schedule from the archive key, AES-256-CTR, the
root header's HMAC over the metadata and the first cluster header's MAC, each cluster
header's HMAC over its trailer (the next cluster's MAC and its segments' MACs), and each
segment's HMAC. AES comes from pyca/cryptography; LZFSE from the Go helper in
../../Linux/lzfse (go-compressions/lzfse), run with `go run`, offline.

`build` takes hooks so a fixture can be wrong in exactly one place with every MAC still
right, and returns the archive with the offsets of its parts.
"""
import hashlib
import hmac
import os
import struct
import subprocess

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

HERE = os.path.dirname(os.path.abspath(__file__))
GO = os.path.join(HERE, "..", "..", "Linux", "lzfse")


def hkdf(ikm, salt, info, size):
    prk = hmac.new(salt or b"\0" * 32, ikm, hashlib.sha256).digest()
    out, block, counter = b"", b"", 1
    while len(out) < size:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:size]


def indexed(name, index):
    return name + struct.pack("<I", index)


def ctr(material, data):
    if not data:
        return b""
    cipher = Cipher(algorithms.AES(material[32:64]), modes.CTR(material[64:80])).encryptor()
    return cipher.update(data) + cipher.finalize()


def mac(material, data, salt):
    return hmac.new(material[:32], salt + data + struct.pack("<Q", len(salt)),
                    hashlib.sha256).digest()


_lzfse = {}


def lzfse(data):
    """Real LZFSE (bvx2/bvxn) from the Go encoder, cached per input."""
    if data not in _lzfse:
        env = dict(os.environ, GOFLAGS="-mod=mod", GOPROXY="off")
        _lzfse[data] = subprocess.run(["go", "-C", GO, "run", "."], input=data, env=env,
                                      check=True, capture_output=True).stdout
    return _lzfse[data]


def entry(name, value):
    body = name.encode() + b"\0" + value
    return struct.pack("<I", len(body) + 4) + body


# Metadata shaped like a restore image's (a key URL and an FCS response), not a real one.
METADATA = entry("com.apple.wkms.fcs-key-url",
                 b"https://wkms-public.apple.com/fcs-keys/" + b"B" * 43 + b"=") + entry(
    "com.apple.wkms.fcs-response", b'{"enc-request":"fixture","wrapped-key":"fixture"}')


def build(plain, key, segment=1 << 20, width=256, compress=(), salt=b"\x07" * 32,
          metadata=METADATA, profile=1, segments_hook=None, root_hook=None, extra=b"", cut=0):
    """The archive and a layout dict. `compress`: segment ids stored as LZFSE.
    `segments_hook(list)` may change each segment's psize/size/digest/body before any MAC
    is taken; `root_hook(dict)` the root fields; `extra` bytes follow the last segment and
    `cut` bytes are dropped from the end, both counted in the root's archive length."""
    count = -(-len(plain) // segment)
    clusters = max(1, -(-count // width))
    segs = []
    for sid in range(clusters * width):
        part = plain[sid * segment:(sid + 1) * segment]
        body = part
        if sid in compress and part:
            body = lzfse(part)
            assert len(body) < len(part), "fixture segment does not compress"
        segs.append({"psize": len(part), "size": len(body), "body": body,
                     "digest": hashlib.sha256(part).digest()})
    if segments_hook:
        segments_hook(segs)
    main = hkdf(key, salt, b"AEA_AMK" + struct.pack("<I", profile), 32)
    blobs = [b""] * clusters
    next_mac = b"\0" * 32
    for k in reversed(range(clusters)):
        ck = hkdf(main, b"", indexed(b"AEA_CK", k), 32)
        entries, macs, bodies = b"", b"", b""
        for i in range(width):
            s = segs[k * width + i]
            sk = hkdf(ck, b"", indexed(b"AEA_SK", i), 80)
            encrypted = ctr(sk, s["body"])
            entries += struct.pack("<II", s["psize"], s["size"]) + s["digest"]
            macs += mac(sk, encrypted, b"")
            bodies += encrypted
        material = hkdf(ck, b"", b"AEA_CHEK", 80)
        header = ctr(material, entries)
        trailer = next_mac + macs
        next_mac = mac(material, header, trailer)
        blobs[k] = header + trailer + bodies
    prefix_size = 12 + len(metadata) + 32 + 112
    total = prefix_size + sum(len(b) for b in blobs) + len(extra) - cut
    fields = {"plain": len(plain), "total": total, "segment": segment, "width": width,
              "codec": b"e", "digest": 2}
    if root_hook:
        root_hook(fields)
    root_plain = struct.pack("<QQII", fields["plain"], fields["total"], fields["segment"],
                             fields["width"]) + fields["codec"] + bytes([fields["digest"]])
    root_plain += b"\0" * (48 - len(root_plain))
    material = hkdf(main, b"", b"AEA_RHEK", 80)
    root = ctr(material, root_plain)
    root_mac = mac(material, root, next_mac + metadata)
    out = (b"AEA1" + struct.pack("<I", profile) + struct.pack("<I", len(metadata)) + metadata
           + salt + root_mac + root + next_mac + b"".join(blobs) + extra)
    if cut:
        out = out[:-cut]
    layout = {"metadata": 12, "salt": 12 + len(metadata), "root_mac": 44 + len(metadata),
              "root": 76 + len(metadata), "clusters": []}
    at = prefix_size
    for k, blob in enumerate(blobs):
        layout["clusters"].append(at)
        at += len(blob)
    return out, layout
