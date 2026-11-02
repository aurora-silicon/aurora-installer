# SPDX-License-Identifier: MIT
"""Apple Encrypted Archive (AEA1) payloads in macOS restore images.

Since macOS 26, some restore-image components (BaseSystem, Ap,ExclaveOS) ship
as AEA1 archives. A stub built from the encrypted bytes cannot boot its paired
recoveryOS, so the installer decrypts them first.

The archive's auth data carries two public fields:

- com.apple.wkms.fcs-key-url: an Apple URL serving a P-256 PKCS#8 private key
  for released builds (no credentials or device identity);
- com.apple.wkms.fcs-response: the 32-byte archive key, HPKE-sealed to that key
  (RFC 9180 base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM,
  empty info and aad).

This module opens the sealed key with standard-library Python only, then has
macOS's own /usr/bin/aea decrypt the archive. Every result is checked against
the SHA-384 digest the BuildManifest records for the component before it is
put in place.
"""
import base64, hashlib, hmac, json, logging, os, re, struct, subprocess, tempfile
import urllib.parse, urllib.request

__all__ = ["AEA_MAGIC", "AEAError", "is_aea", "file_is_aea", "aea_auth_data",
           "archive_key", "decrypt_verified"]

AEA_MAGIC = b"AEA1"
AEA_TOOL = "/usr/bin/aea"

# The same allow-list as the native installer's restore-image helper.
KEY_URL_RE = re.compile(
    r"^https://(wkms-public\.apple\.com|fcs-keys-pub-prod\.cdn-apple\.com)"
    r"/fcs-keys/[A-Za-z0-9_-]{43}=\Z")

class AEAError(Exception):
    pass

def is_aea(prefix):
    return bytes(prefix[:4]) == AEA_MAGIC

def file_is_aea(path):
    with open(path, "rb") as fd:
        return is_aea(fd.read(4))

# ----------------------------------------------------------------- header

def aea_auth_data(path):
    """Return (profile, {key: value bytes}) from an AEA1 prologue."""
    with open(path, "rb") as fd:
        head = fd.read(12)
        if len(head) != 12 or not is_aea(head):
            raise AEAError("not an AEA1 archive")
        profile = int.from_bytes(head[4:7], "little")
        (size,) = struct.unpack_from("<I", head, 8)
        if size > 1 << 20:
            raise AEAError("AEA auth data too large")
        blob = fd.read(size)
        if len(blob) != size:
            raise AEAError("truncated AEA auth data")
    fields = {}
    p = 0
    while p < len(blob):
        if p + 4 > len(blob):
            raise AEAError("malformed AEA auth data")
        (n,) = struct.unpack_from("<I", blob, p)
        if n < 4 or p + n > len(blob):
            raise AEAError("malformed AEA auth data")
        k, sep, v = blob[p + 4:p + n].partition(b"\0")
        if not sep:
            raise AEAError("malformed AEA auth data entry")
        fields[k.decode("ascii", "strict")] = v
        p += n
    return profile, fields

# ------------------------------------------------------------------ P-256

_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
_A = _P - 3
_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
      0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)

def _add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2:
        if (y1 + y2) % _P == 0:
            return None
        m = (3 * x1 * x1 + _A) * pow(2 * y1, -1, _P)
    else:
        m = (y2 - y1) * pow(x2 - x1, -1, _P)
    x3 = (m * m - x1 - x2) % _P
    return x3, (m * (x1 - x3) - y1) % _P

def _mul(k, pt):
    r = None
    while k:
        if k & 1:
            r = _add(r, pt)
        pt = _add(pt, pt)
        k >>= 1
    return r

def _point(b):
    if len(b) != 65 or b[0] != 4:
        raise AEAError("expected an uncompressed P-256 point")
    x, y = int.from_bytes(b[1:33], "big"), int.from_bytes(b[33:], "big")
    if not (0 <= x < _P and 0 <= y < _P) or (y * y - (x * x * x + _A * x + _B)) % _P:
        raise AEAError("point not on P-256")
    return x, y

def _enc_point(pt):
    return b"\x04" + pt[0].to_bytes(32, "big") + pt[1].to_bytes(32, "big")

def pkcs8_p256_scalar(pem):
    body = b"".join(l for l in pem.strip().splitlines() if not l.startswith(b"-----"))
    der = base64.b64decode(body)
    # ECPrivateKey ::= SEQUENCE { version 1, privateKey OCTET STRING (32) ... }
    i = der.find(b"\x02\x01\x01\x04\x20")
    if i < 0 or b"\x2a\x86\x48\xce\x3d\x03\x01\x07" not in der:  # prime256v1 OID
        raise AEAError("not a P-256 PKCS#8 private key")
    d = int.from_bytes(der[i + 5:i + 37], "big")
    if not 0 < d < _N:
        raise AEAError("bad P-256 scalar")
    return d

# ------------------------------------------------------------ AES-256-GCM

_SBOX = [0] * 256

def _init_sbox():
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1 | q >> 7) & 0xFF) ^ ((q << 2 | q >> 6) & 0xFF) \
            ^ ((q << 3 | q >> 5) & 0xFF) ^ ((q << 4 | q >> 4) & 0xFF)
        _SBOX[p] = x ^ 0x63
        if p == 1:
            break
    _SBOX[0] = 0x63

_init_sbox()

def _xt(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1

def _expand(key):
    w = [list(key[i:i + 4]) for i in range(0, 32, 4)]
    rc = 1
    for i in range(8, 60):
        t = list(w[i - 1])
        if i % 8 == 0:
            t = [_SBOX[b] for b in t[1:] + t[:1]]
            t[0] ^= rc
            rc = _xt(rc)
        elif i % 8 == 4:
            t = [_SBOX[b] for b in t]
        w.append([a ^ b for a, b in zip(w[i - 8], t)])
    return [sum(w[r * 4:r * 4 + 4], []) for r in range(15)]

def _aes(rk, block):
    s = [b ^ k for b, k in zip(block, rk[0])]
    for r in range(1, 15):
        s = [_SBOX[b] for b in s]
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]  # ShiftRows
        if r != 14:
            m = []
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                t = a[0] ^ a[1] ^ a[2] ^ a[3]
                m += [a[i] ^ t ^ _xt(a[i] ^ a[(i + 1) % 4]) for i in range(4)]
            s = m
        s = [b ^ k for b, k in zip(s, rk[r])]
    return bytes(s)

def _gmul(x, y):
    r = 0
    for i in range(127, -1, -1):
        if (y >> i) & 1:
            r ^= x
        x = (x >> 1) ^ (0xE1 << 120) if x & 1 else x >> 1
    return r

def _gcm(key, nonce, data, aad):
    """Return (CTR-transformed data, tag) for a 96-bit nonce."""
    if len(key) != 32 or len(nonce) != 12:
        raise AEAError("bad AES-256-GCM key or nonce")
    rk = _expand(key)
    h = int.from_bytes(_aes(rk, bytes(16)), "big")
    out = bytearray()
    for i in range(0, len(data), 16):
        ctr = nonce + (2 + i // 16).to_bytes(4, "big")
        out += bytes(a ^ b for a, b in zip(data[i:i + 16], _aes(rk, ctr)))
    return bytes(out), rk, h

def _gcm_tag(rk, h, nonce, aad, ct):
    pad = lambda b: b + b"\0" * (-len(b) % 16)
    blob = pad(aad) + pad(ct) + struct.pack(">QQ", len(aad) * 8, len(ct) * 8)
    y = 0
    for i in range(0, len(blob), 16):
        y = _gmul(y ^ int.from_bytes(blob[i:i + 16], "big"), h)
    return (y ^ int.from_bytes(_aes(rk, nonce + b"\0\0\0\1"), "big")).to_bytes(16, "big")

def aes256gcm_open(key, nonce, data, aad=b""):
    if len(data) < 16:
        raise AEAError("AES-GCM input too short")
    ct, tag = data[:-16], data[-16:]
    pt, rk, h = _gcm(key, nonce, ct, aad)
    if not hmac.compare_digest(_gcm_tag(rk, h, nonce, aad, ct), tag):
        raise AEAError("AES-GCM tag mismatch")
    return pt

def aes256gcm_seal(key, nonce, pt, aad=b""):
    ct, rk, h = _gcm(key, nonce, pt, aad)
    return ct + _gcm_tag(rk, h, nonce, aad, ct)

# ------------------------------------------------------------------- HPKE

_KEM = b"KEM\x00\x10"                          # DHKEM(P-256, HKDF-SHA256)
_SUITE = b"HPKE\x00\x10\x00\x01\x00\x02"       # + HKDF-SHA256, AES-256-GCM

def _extract(salt, ikm):
    return hmac.new(salt or bytes(32), ikm, hashlib.sha256).digest()

def _expand_hkdf(prk, info, n):
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:n]

def _lx(suite, salt, label, ikm):
    return _extract(salt, b"HPKE-v1" + suite + label + ikm)

def _le(suite, prk, label, info, n):
    return _expand_hkdf(prk, n.to_bytes(2, "big") + b"HPKE-v1" + suite + label + info, n)

def _key_schedule(dh_x, enc, pk_r, info):
    eae = _lx(_KEM, b"", b"eae_prk", dh_x.to_bytes(32, "big"))
    shared = _le(_KEM, eae, b"shared_secret", enc + pk_r, 32)
    ctx = b"\0" + _lx(_SUITE, b"", b"psk_id_hash", b"") + _lx(_SUITE, b"", b"info_hash", info)
    secret = _lx(_SUITE, shared, b"secret", b"")
    return _le(_SUITE, secret, b"key", ctx, 32), _le(_SUITE, secret, b"base_nonce", ctx, 12)

def hpke_open(sk, enc, ct, info=b"", aad=b""):
    """RFC 9180 base-mode single-shot open, P-256/SHA-256/AES-256-GCM."""
    dh = _mul(sk, _point(enc))
    if dh is None:
        raise AEAError("bad DH")
    key, nonce = _key_schedule(dh[0], enc, _enc_point(_mul(sk, _G)), info)
    return aes256gcm_open(key, nonce, ct, aad)

def hpke_seal(pk_r, ct_plain, eph_sk, info=b"", aad=b""):
    """The matching seal, with an explicit ephemeral scalar (for tests)."""
    enc = _enc_point(_mul(eph_sk, _G))
    dh = _mul(eph_sk, _point(pk_r))
    key, nonce = _key_schedule(dh[0], enc, pk_r, info)
    return enc, aes256gcm_seal(key, nonce, ct_plain, aad)

# -------------------------------------------------------------- the key

def check_key_url(url):
    if not KEY_URL_RE.match(url):
        raise AEAError(f"refusing AEA key URL outside Apple's FCS key service: {url!r}")

class _NoOffsiteRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_key_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def fetch_fcs_private_key(url, timeout=60):
    check_key_url(url)
    pem_dir = os.environ.get("AEA_FCS_PEM_DIR")
    if pem_dir:
        name = url.rsplit("/", 1)[1]
        with open(os.path.join(pem_dir, name), "rb") as fd:
            return fd.read(16384)
    opener = urllib.request.build_opener(_NoOffsiteRedirect)
    req = urllib.request.Request(url, headers={"User-Agent": "aurora-installer"})
    with opener.open(req, timeout=timeout) as r:
        check_key_url(r.geturl())
        return r.read(16384)

def archive_key(path, pem=None):
    """The archive's 32-byte symmetric key."""
    _, f = aea_auth_data(path)
    try:
        url = f["com.apple.wkms.fcs-key-url"].decode("ascii")
        resp = json.loads(f["com.apple.wkms.fcs-response"])
        enc = base64.b64decode(resp["enc-request"], validate=True)
        wrapped = base64.b64decode(resp["wrapped-key"], validate=True)
    except (KeyError, ValueError, TypeError) as e:
        raise AEAError(f"{path}: no usable FCS key fields in the AEA auth data ({e})") from e
    if pem is None:
        pem = fetch_fcs_private_key(url)
    else:
        check_key_url(url)
    key = hpke_open(pkcs8_p256_scalar(pem), enc, wrapped)
    if len(key) != 32:
        raise AEAError("unexpected archive key length")
    return key

# ---------------------------------------------------------------- decrypt

def _sha384(path):
    h = hashlib.sha384()
    with open(path, "rb") as fd:
        for chunk in iter(lambda: fd.read(8 << 20), b""):
            h.update(chunk)
    return h.digest()

def decrypt_verified(src, dst, sha384_digest, pem=None, key=None):
    """Decrypt AEA src to dst; dst appears only if SHA-384(dst) equals the digest.

    For a restore-image component the BuildManifest Digest is the SHA-384 of the
    decrypted image, so a match proves dst is exactly the image Apple signed.
    The output is written next to dst and renamed into place, and nothing is
    left behind on failure. src and dst may be the same path."""
    want = bytes(sha384_digest)
    if len(want) != 48:
        raise AEAError("expected a SHA-384 manifest digest")
    if key is None:
        key = archive_key(src, pem)
    dst_dir = os.path.dirname(os.path.abspath(dst))
    fd, tmp = tempfile.mkstemp(prefix=".aea-", dir=dst_dir)
    os.close(fd)
    kfd, kpath = tempfile.mkstemp(prefix=".aea-key-")
    try:
        os.write(kfd, b"base64:" + base64.b64encode(key))
        os.close(kfd)
        kfd = None
        logging.info(f"  aea decrypt {src} -> {dst}")
        res = subprocess.run([AEA_TOOL, "decrypt", "-i", src, "-o", tmp, "-key", kpath],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if res.returncode != 0:
            raise AEAError(f"{src}: aea decrypt failed: {res.stdout.decode(errors='replace').strip()}")
        got = _sha384(tmp)
        if not hmac.compare_digest(got, want):
            raise AEAError(f"{src}: decrypted digest {got.hex()} does not match the manifest {want.hex()}")
        mask = os.umask(0)
        os.umask(mask)
        os.chmod(tmp, 0o644 & ~mask)   # as an ordinary extracted file, not mkstemp's 0600
        os.replace(tmp, dst)
        tmp = None
    finally:
        if kfd is not None:
            os.close(kfd)
        os.unlink(kpath)
        if tmp is not None and os.path.exists(tmp):
            os.unlink(tmp)
    return dst
