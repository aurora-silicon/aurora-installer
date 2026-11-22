#!/usr/bin/env python3
"""Regenerate vectors.json for Tests/RestoreImageKeyCheck.swift.

Independent reference: pyca/cryptography (OpenSSL) HPKE, P-256, AES-GCM and
HKDF. Every key is a new disposable random key; regenerating changes the bytes.
Usage: python3 generate.py > vectors.json
"""
import base64
import json
import os

from cryptography.hazmat.primitives import hashes, hpke, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def b64(data):
    return base64.b64encode(data).decode()


def der(tag, body):
    n = len(body)
    if n < 0x80:
        head = bytes([n])
    elif n < 0x100:
        head = bytes([0x81, n])
    else:
        head = bytes([0x82, n >> 8, n & 0xFF])
    return bytes([tag]) + head + body


def pkcs8_without_public(scalar):
    """PKCS#8 whose ECPrivateKey carries neither parameters nor public key."""
    algorithm = der(0x30, der(0x06, bytes.fromhex("2a8648ce3d0201"))
                    + der(0x06, bytes.fromhex("2a8648ce3d030107")))
    key = der(0x30, der(0x02, b"\x01") + der(0x04, scalar))
    info = der(0x30, der(0x02, b"\x00") + algorithm + der(0x04, key))
    lines = [b64(info)[i:i + 64] for i in range(0, len(b64(info)), 64)]
    return "-----BEGIN PRIVATE KEY-----\n" + "\n".join(lines) + "\n-----END PRIVATE KEY-----\n"


suite = hpke.Suite(hpke.KEM.P256, hpke.KDF.HKDF_SHA256, hpke.AEAD.AES_256_GCM)
out = {"hpke": [], "points": [], "gcm": [], "hkdf": []}
for index in range(8):
    private = ec.generate_private_key(ec.SECP256R1())
    scalar = private.private_numbers().private_value.to_bytes(32, "big")
    public = private.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    pem = private.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()).decode()
    key = os.urandom(32)
    sealed = suite.encrypt(key, private.public_key())
    out["hpke"].append({
        "pem": pem if index % 2 == 0 else pkcs8_without_public(scalar),
        "public": b64(public), "enc": b64(sealed[:65]), "wrapped": b64(sealed[65:]),
        "key": b64(key)})
# Scalars near the edges of [1, n-1] plus random ones: public point = d*G.
order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
scalars = [1, 2, 3, order - 1, order - 2, (1 << 255) + 1]
scalars += [int.from_bytes(os.urandom(32), "big") % (order - 1) + 1 for _ in range(10)]
for value in scalars:
    public = ec.derive_private_key(value, ec.SECP256R1()).public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    out["points"].append({"scalar": b64(value.to_bytes(32, "big")), "public": b64(public)})
for length in [0, 1, 15, 16, 17, 32, 48, 100]:
    key, nonce, plain = os.urandom(32), os.urandom(12), os.urandom(length)
    out["gcm"].append({"key": b64(key), "nonce": b64(nonce), "plain": b64(plain),
                       "sealed": b64(AESGCM(key).encrypt(nonce, plain, None))})
for size in [12, 32, 80, 255]:
    ikm, salt, info = os.urandom(32), os.urandom(len(str(size))), os.urandom(9)
    for s in [salt, b""]:
        derived = HKDF(hashes.SHA256(), size, s or None, info).derive(ikm)
        out["hkdf"].append({"ikm": b64(ikm), "salt": b64(s), "info": b64(info),
                            "size": size, "okm": b64(derived)})
print(json.dumps(out, indent=1))
