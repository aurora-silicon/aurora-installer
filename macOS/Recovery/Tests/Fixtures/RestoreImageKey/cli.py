#!/usr/bin/env python3
"""Regenerate cli-archive.bin and cli-release-key.pem for Tests/RestoreImageKeyTool.sh.

Standard library only, deterministic. cli-archive.bin is the first bytes of the
restore image helper's Go reference AEA (go-aea.json: header, metadata, salt and
root header) with its metadata replaced by an FCS key URL and an FCS response
that wraps the same archive key for the Go vectors' disposable release key
(go-vectors.json); the root header MAC is recomputed for the new metadata.
Usage (from this directory): python3 cli.py
"""
import base64
import hashlib
import hmac
import json
import struct

fixtures = "../../../../RestoreImage/Tests/RestoreImageCoreTests/Fixtures/"
aea = json.load(open(fixtures + "go-aea.json"))
go = json.load(open(fixtures + "go-vectors.json"))
key = base64.b64decode(aea["key"])
assert key == base64.b64decode(go["key"]), "the Go vectors wrap another key"
head = base64.b64decode(next(r["data"] for r in aea["records"] if r["record"]["offset"] == 0))
assert head[:8] == b"AEA1\x01\x00\x00\x00"
length = struct.unpack_from("<I", head, 8)[0]
salt = head[12 + length:44 + length]
root = head[44 + length:156 + length]
assert len(head) == 156 + length and len(root) == 112


def hkdf(ikm, salt, info, size):
    prk = hmac.new(salt or b"\0" * 32, ikm, hashlib.sha256).digest()
    out, block = b"", b""
    for counter in range(1, -(-size // 32) + 1):
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
    return out[:size]


def entry(name, value):
    body = name.encode() + b"\0" + value
    return struct.pack("<I", len(body) + 4) + body


url = "https://wkms-public.apple.com/fcs-keys/" + "A" * 43 + "="
response = json.dumps({"enc-request": go["enc"], "wrapped-key": go["wrapped"]}).encode()
auth = entry("com.apple.wkms.fcs-key-url", url.encode()) + entry(
    "com.apple.wkms.fcs-response", response)
main = hkdf(key, salt, b"AEA_AMK" + head[4:8], 32)
material = hkdf(main, b"", b"AEA_RHEK", 80)
mac_salt = root[80:112] + auth
mac = hmac.new(material[:32], mac_salt + root[32:80] + struct.pack("<Q", len(mac_salt)),
               hashlib.sha256).digest()
# The same recipe reproduces the Go archive's own root header MAC.
assert hmac.new(material[:32], root[80:112] + head[12:12 + length] + root[32:80]
                + struct.pack("<Q", 32 + length), hashlib.sha256).digest() == root[:32]
out = head[:8] + struct.pack("<I", len(auth)) + auth + salt + mac + root[32:]
open("cli-archive.bin", "wb").write(out)
open("cli-release-key.pem", "w").write(go["pem"])
