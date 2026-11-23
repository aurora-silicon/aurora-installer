# SPDX-License-Identifier: MIT
"""The host certificate chain a Magic Keyboard with Touch ID pairs with.

The chain is two concatenated DER certificates: this Mac's attestation leaf
(subject CN = 64 lowercase hex digits, OU "BAA Certification", O "Apple
Inc.", issuer CN "Basic Attestation User Sub CA2") and its intermediate
(CN "Basic Attestation User Sub CA2", issuer CN "Basic Attestation User Root
CA"). The leaf is bound to this Mac's Secure Enclave, so it is per-machine
data and is only ever written into this Mac's own vendor firmware.

macOS keeps a copy on the Hardware volume, but neither the file nor its
container format is fixed, so it is found by content: raw DER, and base64
(PEM, or a property list's <data>). The kernel checks the leaf against the
enclave before it uses the chain, so only the structure is checked here and
never the validity dates.
"""
import base64, binascii, logging, os, re, stat
from .core import FWFile

log = logging.getLogger("asahi_firmware.touchid_host_chain")

FILENAME = "apple/stac-host-chain.der"
HARDWARE_ROOT = "/System/Volumes/Hardware"
LEAF_ISSUER = "Basic Attestation User Sub CA2"
INTERMEDIATE_ISSUER = "Basic Attestation User Root CA"
LEAF_UNIT = "BAA Certification"
ORGANIZATION = "Apple Inc."
MAX_CERTIFICATE = 16 << 10
MAX_BASE64_RUN = 1 << 16

OID_CN = b"\x55\x04\x03"
OID_O = b"\x55\x04\x0a"
OID_OU = b"\x55\x04\x0b"
STRING_TAGS = (0x0c, 0x13, 0x16, 0x14)
LEAF_CN = re.compile(r"[0-9a-f]{64}\Z")
BASE64_RUN = re.compile(rb"MII[A-Za-z0-9+/\t\n\r ]*(={0,2})")

LEAF, INTERMEDIATE = "leaf", "intermediate"


class ChainError(Exception):
    """Several different chains, a leaf without its intermediate, or a scan
    that reached its bounds."""


class Certificate(object):
    __slots__ = ("kind", "der", "cn", "not_before")

    def __init__(self, kind, der, cn, not_before):
        self.kind, self.der, self.cn, self.not_before = kind, der, cn, not_before


def element(b, off, end):
    """One definite, minimally encoded TLV: (tag, start, end) or None."""
    if off < 0 or off + 2 > end:
        return None
    tag = b[off]
    if tag & 0x1f == 0x1f:
        return None
    first = b[off + 1]
    start, length = off + 2, first
    if first >= 0x80:
        count = first & 0x7f
        if count < 1 or count > 3 or start + count > end or b[start] == 0:
            return None
        length = int.from_bytes(b[start:start + count], "big")
        if length < 0x80:
            return None
        start += count
    if length > end - start:
        return None
    return tag, start, start + length


def children(b, parent, maximum=64):
    """The children of a constructed element; they must fill it exactly."""
    _, off, end = parent
    out = []
    while off < end:
        child = element(b, off, end) if len(out) < maximum else None
        if child is None:
            return None
        out.append(child)
        off = child[2]
    return out


def name(b, el):
    """An X.501 Name as [(oid, str or None)], or None when malformed."""
    if el[0] != 0x30:
        return None
    sets = children(b, el)
    if sets is None:
        return None
    out = []
    for s in sets:
        attrs = children(b, s) if s[0] == 0x31 else None
        if attrs is None:
            return None
        for a in attrs:
            parts = children(b, a) if a[0] == 0x30 else None
            if parts is None or len(parts) != 2 or parts[0][0] != 0x06:
                return None
            value = None
            if parts[1][0] in STRING_TAGS:
                try:
                    value = bytes(b[parts[1][1]:parts[1][2]]).decode("utf-8")
                except UnicodeDecodeError:
                    value = None
            out.append((bytes(b[parts[0][1]:parts[0][2]]), value))
    return out


def single(attrs, oid):
    values = [v for o, v in attrs if o == oid]
    return values[0] if len(values) == 1 else None


def _time(b, el):
    """notBefore as a sortable 'YYYYMMDDHHMMSS' string ('' if unknown)."""
    text = bytes(b[el[1]:el[2]]).decode("ascii", "replace").rstrip("Z")
    if el[0] == 0x17 and len(text) >= 12:
        return ("19" if text[:2] >= "50" else "20") + text[:12]
    if el[0] == 0x18 and len(text) >= 14:
        return text[:14]
    return ""


def certificate(b, off, end=None):
    """The host leaf or its intermediate at `off`, or None."""
    end = len(b) if end is None else end
    outer = element(b, off, end)
    if outer is None or outer[0] != 0x30 or outer[2] - off > MAX_CERTIFICATE:
        return None
    parts = children(b, outer, 3)
    if not parts or len(parts) != 3 or [p[0] for p in parts] != [0x30, 0x30, 0x03]:
        return None
    fields = children(b, parts[0], 10)
    if fields is None:
        return None
    if fields and fields[0][0] == 0xa0:
        fields = fields[1:]
    if len(fields) < 6 or [f[0] for f in fields[:6]] != [0x02, 0x30, 0x30, 0x30, 0x30, 0x30]:
        return None
    previous = 0xa0
    for f in fields[6:]:
        if f[0] <= previous or f[0] > 0xa3:
            return None
        previous = f[0]
    issuer, subject = name(b, fields[2]), name(b, fields[4])
    if issuer is None or subject is None:
        return None
    issuer_cn, subject_cn = single(issuer, OID_CN), single(subject, OID_CN)
    if issuer_cn is None or subject_cn is None:
        return None
    der = bytes(b[off:outer[2]])
    validity = children(b, fields[3], 2)
    not_before = _time(b, validity[0]) if validity else ""
    if subject_cn == LEAF_ISSUER and issuer_cn == INTERMEDIATE_ISSUER:
        return Certificate(INTERMEDIATE, der, subject_cn, not_before)
    if (issuer_cn == LEAF_ISSUER and LEAF_CN.match(subject_cn)
            and single(subject, OID_OU) == LEAF_UNIT
            and single(subject, OID_O) == ORGANIZATION):
        return Certificate(LEAF, der, subject_cn, not_before)
    return None


class Found(object):
    def __init__(self):
        self.leaves = {}          # der -> Certificate
        self.intermediates = set()
        self.adjacent = []        # (leaf der, intermediate der)


def scan_der(b, found):
    """Every 30 82 that starts a matching certificate. A leaf followed
    directly by an intermediate is recorded as a pair."""
    off, last_leaf = 0, None
    while True:
        off = b.find(b"\x30\x82", off)
        if off < 0:
            return
        cert = certificate(b, off)
        if cert is None:
            off += 1
            continue
        if cert.kind == LEAF:
            found.leaves[cert.der] = cert
            last_leaf = (cert.der, off + len(cert.der))
        else:
            found.intermediates.add(cert.der)
            if last_leaf is not None and last_leaf[1] == off:
                found.adjacent.append((last_leaf[0], cert.der))
        off += len(cert.der)


def scan_base64(b, found):
    """Base64 runs (whitespace allowed inside) starting with MII, the
    encoding of a DER SEQUENCE with a two-byte length."""
    off = 0
    while True:
        m = BASE64_RUN.search(b, off)
        if m is None:
            return
        text = re.sub(rb"[\t\n\r ]", b"", m.group(0)[:MAX_BASE64_RUN])
        core = text.rstrip(b"=")
        pad = len(text) - len(core)
        if len(text) % 4:
            text = core[:len(core) - len(core) % 4]
        elif pad == 0:
            text = core
        try:
            scan_der(base64.b64decode(text, validate=True), found)
        except (binascii.Error, ValueError):
            pass
        off = max(m.end(), m.start() + 3)


def certificates(data):
    found = Found()
    data = bytes(data)
    scan_der(data, found)
    scan_base64(data, found)
    return found


def is_chain(data):
    """Exactly a leaf followed by its intermediate, nothing else."""
    data = bytes(data)
    leaf = certificate(data, 0)
    if leaf is None or leaf.kind != LEAF:
        return False
    inter = certificate(data, len(leaf.der))
    return inter is not None and inter.kind == INTERMEDIATE and \
        len(leaf.der) + len(inter.der) == len(data)


class ChainScanner(object):
    """Accumulates the certificates found in each blob (a file, or a chunk
    of a disk). One blob may hold both certificates, back to back or in
    separate records; the same bytes may appear in several blobs."""

    def __init__(self):
        self.leaves = {}
        self.intermediates = set()
        self.paired = {}

    def add(self, data):
        found = certificates(data)
        self.leaves.update(found.leaves)
        self.intermediates |= found.intermediates
        for leaf, inter in found.adjacent:
            self.paired.setdefault(leaf, set()).add(inter)
        if not found.adjacent and len(found.leaves) == 1 and len(found.intermediates) == 1:
            self.paired.setdefault(next(iter(found.leaves)), set()).update(found.intermediates)

    def result(self, newest_of_one_key=False):
        """leaf || intermediate, or None when there is no leaf.

        Exactly one distinct leaf is required. With newest_of_one_key, several
        leaves that all name the same enclave key (the same CN) resolve to the
        one with the latest notBefore: re-issued copies of one Mac's
        certificate, which the kernel accepts alike."""
        if not self.leaves:
            return None
        leaves = list(self.leaves.values())
        if len(leaves) > 1:
            if not newest_of_one_key or len({c.cn for c in leaves}) != 1:
                raise ChainError(f"{len(leaves)} different host certificate chains")
            leaves.sort(key=lambda c: (c.not_before, c.der))
            if leaves[-1].not_before == leaves[-2].not_before:
                raise ChainError(f"{len(leaves)} host certificates with the same notBefore")
        leaf = leaves[-1].der
        candidates = self.paired.get(leaf) or self.intermediates
        if not candidates:
            raise ChainError("a host certificate without its intermediate")
        if len(candidates) != 1:
            raise ChainError(f"{len(candidates)} intermediates for the host certificate")
        return leaf + next(iter(candidates))


def scan_tree(root, max_file=1 << 20, max_entries=20000, max_total=128 << 20, max_depth=16):
    """Bounded walk of one volume. Symlinks, other mounts, special files and
    files over max_file are skipped; unreadable entries are skipped. Returns
    (chain or None, number of unreadable entries)."""
    scanner = ChainScanner()
    try:
        st = os.lstat(root)
    except FileNotFoundError:
        return None, 0
    if not stat.S_ISDIR(st.st_mode):
        return None, 0
    dev = st.st_dev
    counts = {"entries": 0, "total": 0, "unreadable": 0}

    def walk(path, depth):
        if depth > max_depth:
            raise ChainError("the scan reached its depth bound")
        try:
            names = sorted(os.listdir(path))
        except OSError:
            counts["unreadable"] += 1
            return
        counts["entries"] += len(names)
        if counts["entries"] > max_entries:
            raise ChainError("the scan reached its file count bound")
        for n in names:
            p = os.path.join(path, n)
            try:
                st = os.lstat(p)
            except OSError:
                counts["unreadable"] += 1
                continue
            if st.st_dev != dev:
                continue
            if stat.S_ISDIR(st.st_mode):
                walk(p, depth + 1)
            elif stat.S_ISREG(st.st_mode) and 0 < st.st_size <= max_file:
                try:
                    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                                 | getattr(os, "O_CLOEXEC", 0))
                except OSError:
                    counts["unreadable"] += 1
                    continue
                with os.fdopen(fd, "rb") as f:
                    fst = os.fstat(f.fileno())
                    if not stat.S_ISREG(fst.st_mode) or fst.st_dev != dev:
                        continue
                    data = f.read(max_file + 1)
                if len(data) > max_file:
                    continue
                if len(data) > max_total - counts["total"]:
                    raise ChainError("the scan reached its total size bound")
                counts["total"] += len(data)
                scanner.add(data)

    walk(root, 0)
    return scanner.result(), counts["unreadable"]


class TouchIDHostChainFWCollection(object):
    """Absence is valid: a Mac that never paired such a keyboard has no
    chain. Any failure leaves the chain out and is logged once."""

    def __init__(self, path=None):
        self.fwfiles = []
        if path is None:
            self.load()
        else:
            self.update(path)

    def files(self):
        return self.fwfiles

    def _add(self, data):
        if not is_chain(data):
            log.warning("Touch ID keyboard host certificate chain is malformed; not saved")
            return
        self.fwfiles.append((FILENAME, FWFile(FILENAME, data)))

    def update(self, path):
        try:
            with open(os.path.join(path, FILENAME), "rb") as f:
                data = f.read(MAX_CERTIFICATE * 2 + 1)
        except FileNotFoundError:
            log.info("No Touch ID keyboard host certificate chain in the firmware archive")
            return
        except OSError as e:
            log.warning(f"Unable to read the Touch ID keyboard host certificate chain: {e}")
            return
        self._add(data)

    def load(self, root=HARDWARE_ROOT):
        try:
            chain, unreadable = scan_tree(root)
        except ChainError as e:
            log.warning(f"Touch ID keyboard host certificate chain not collected: {e}")
            return
        if chain is None:
            log.info("No Touch ID keyboard host certificate chain on the Hardware volume"
                     + (f" ({unreadable} entries unreadable)" if unreadable else ""))
            return
        self._add(chain)
        if self.fwfiles:
            log.info(f"  Collected {FILENAME}")
