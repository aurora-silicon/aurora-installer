#!/usr/bin/python3 -I
# SPDX-License-Identifier: MIT
"""stac_host_chain: the Touch ID keyboard host certificate chain, from Linux.

New installs collect this Mac's chain at install time. For a system
installed before that, this reads it from the Mac's own iBoot System
Container (the APFS container holding the Hardware volume, where macOS
keeps it) and writes apple/stac-host-chain.der for the kernel.

The disk is opened O_RDONLY and read as raw bytes: nothing is mounted and
nothing on it is written. The chain is found by content, with the same
rules as the installer (asahi_firmware.touchid_host_chain), in chunks that
overlap so a record across a chunk boundary is still seen whole.

    python3 -I tools/stac-host-chain/stac_host_chain.py [--check]
        [--disk /dev/nvme0n1 | --device PARTITION_OR_IMAGE] [-o OUT] [--force]
"""
import argparse, os, pathlib, stat, struct, sys, uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from asahi_firmware.touchid_host_chain import ChainError, ChainScanner, FILENAME, \
    is_chain  # noqa: E402

DEFAULT_DISK = "/dev/nvme0n1"
ISC_TYPE = uuid.UUID("69646961-6700-11aa-aa11-00306543ecac")
ISC_NAME = "iBootSystemContainer"
# Where the running system's vendor firmware is unpacked, as in
# tools/speaker-tuning; the first that exists is the default output.
RUNNING_BUNDLES = ("/lib/firmware/vendor/apple", "/run/aurora-firmware/vendorfw/apple")
CHUNK = 4 << 20
OVERLAP = 128 << 10


class Refused(Exception):
    """Nothing was written."""


def open_ro(path):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    mode = os.fstat(fd).st_mode
    if not (stat.S_ISBLK(mode) or stat.S_ISREG(mode)):
        os.close(fd)
        raise Refused(f"{path} is not a block device or an image file")
    return fd


def size_of(fd):
    return os.lseek(fd, 0, os.SEEK_END)


def is_container(fd, offset=0):
    """An APFS container superblock (NXSB) at offset."""
    return os.pread(fd, 36, offset)[32:36] == b"NXSB"


def find_isc(fd):
    """(start, end) in bytes of the one iBoot System Container partition,
    by GPT type GUID or partition name."""
    for sector in (4096, 512):
        header = os.pread(fd, 92, sector)
        if len(header) < 92 or header[:8] != b"EFI PART":
            continue
        table, count, size = struct.unpack_from("<QII", header, 72)
        if not (1 <= count <= 256 and 128 <= size <= 1024 and size % 8 == 0):
            raise Refused("the GPT header is not plausible")
        entries = os.pread(fd, count * size, table * sector)
        found = []
        for i in range(count):
            entry = entries[i * size:(i + 1) * size]
            if len(entry) < 128 or entry[:16] == bytes(16):
                continue
            first, last = struct.unpack_from("<QQ", entry, 32)
            name = entry[56:128].decode("utf-16-le", "replace").split("\0")[0]
            if entry[:16] == ISC_TYPE.bytes_le or name == ISC_NAME:
                if last < first:
                    raise Refused(f"GPT entry {i + 1} has a negative size")
                found.append((first * sector, (last + 1) * sector))
        if len(found) != 1:
            raise Refused(f"{len(found)} iBoot System Container partitions in the GPT")
        return found[0]
    raise Refused("no GPT on the disk")


def carve(fd, start, end, chunk=CHUNK, overlap=OVERLAP):
    """Scans [start, end) in chunks that overlap by `overlap` bytes."""
    if chunk <= overlap:
        raise ValueError("chunk must be larger than overlap")
    scanner = ChainScanner()
    pos = start
    while pos < end:
        n = min(chunk, end - pos)
        data = os.pread(fd, n, pos)
        if len(data) != n:
            raise Refused(f"short read at byte {pos}")
        scanner.add(data)
        if pos + n >= end:
            break
        pos += n - overlap
    return scanner


def collect(disk=DEFAULT_DISK, device=None, chunk=CHUNK, overlap=OVERLAP):
    """The chain, or None when the container holds none.

    APFS is copy-on-write, so earlier copies of the certificate may still
    be in free blocks. Copies that name the same enclave key resolve to the
    newest; leaves for different keys are refused."""
    fd = open_ro(device or disk)
    try:
        if device is not None and is_container(fd):
            start, end = 0, size_of(fd)
        else:
            start, end = find_isc(fd)
            if not is_container(fd, start):
                raise Refused("the iBoot System Container partition holds no APFS container")
        return carve(fd, start, end, chunk, overlap).result(newest_of_one_key=True)
    finally:
        os.close(fd)


def default_output(roots=RUNNING_BUNDLES):
    name = os.path.basename(FILENAME)
    for root in roots:
        if os.path.isdir(root):
            return os.path.join(root, name)
    return os.path.join(roots[0], name)


def write(path, data, force=False):
    """Atomically writes data, mode 0644 (root:root when run as root).
    Returns False when the same chain is already there. A different
    existing chain is kept unless force."""
    if not is_chain(data):
        raise Refused("refusing to write something that is not a host certificate chain")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        fd = None
    except OSError as e:
        raise Refused(f"{path}: {e.strerror}")
    if fd is not None:
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise Refused(f"{path} is not a regular file")
            existing = f.read(64 << 10)
        if existing == data:
            return False
        if not force:
            raise Refused(f"{path} holds a different file; pass --force to replace it")
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o755, exist_ok=True)
    tmp = os.path.join(directory, f".{os.path.basename(path)}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fchmod(f.fileno(), 0o644)
            if os.geteuid() == 0:
                os.fchown(f.fileno(), 0, 0)
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="stac_host_chain",
        description="Read this Mac's Touch ID keyboard host certificate chain from its "
                    "iBoot System Container (read-only) and write it for the kernel.")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--disk", default=DEFAULT_DISK,
                     help=f"internal disk whose GPT names the container (default {DEFAULT_DISK})")
    src.add_argument("--device", help="the container partition, or an image of it")
    ap.add_argument("-o", "--output", help=f"output file (default: {default_output()})")
    ap.add_argument("--force", action="store_true", help="replace a different existing chain")
    ap.add_argument("--check", action="store_true", help="find the chain, write nothing")
    a = ap.parse_args(argv)
    try:
        chain = collect(disk=a.disk, device=a.device)
    except (ChainError, Refused, OSError) as e:
        print(f"stac_host_chain: {e}", file=sys.stderr)
        return 1
    if chain is None:
        print("stac_host_chain: no Touch ID keyboard host certificate chain on this Mac",
              file=sys.stderr)
        return 2
    if a.check:
        print(f"Found a host certificate chain ({len(chain)} bytes); nothing written")
        return 0
    output = a.output or default_output()
    try:
        changed = write(output, chain, force=a.force)
    except (Refused, OSError) as e:
        print(f"stac_host_chain: {e}", file=sys.stderr)
        return 1
    print(f"{output}: {'written' if changed else 'already holds this chain'} ({len(chain)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
