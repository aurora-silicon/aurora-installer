# SPDX-License-Identifier: MIT
"""Aurora's bootloader (aura) images: version detection and variable handling.

aura shares m1n1's raw image format, so the same code handles both. Installs
made before the switch carry m1n1 (or an early aura) marked with the legacy
`##m1n1_ver##` tag; current aura images carry `##aura_ver##`.
"""

import os, re, struct, zlib
from typing import NamedTuple, Optional

AURA_VERSION_MARKER = b"##aura_ver##"
LEGACY_VERSION_MARKER = b"##m1n1_ver##"

# Boot object names an installer_data template may still name. The package
# ships Stage 1 as boot/aura.bin; legacy templates say m1n1.bin.
STAGE1_NAME = "aura.bin"
LEGACY_STAGE1_NAMES = ("m1n1.bin",)


class LoaderVersion(NamedTuple):
    loader: str     # "aura" or "m1n1"
    version: str

    @property
    def legacy(self):
        """True for a pre-aura (m1n1-marked) install, which should be upgraded."""
        return self.loader != "aura"

    def __str__(self):
        return f"{self.loader} {self.version}"


def build(src, dest, vars):
    if isinstance(vars, (list, tuple)):
        vars = b"".join(i.encode("ascii") + b"\n" for i in vars) + b"\0\0\0\0"

    with open(src, "rb") as fd:
        image = fd.read()

    with open(dest, "wb") as fd:
        fd.write(image + vars)


def extract_vars(src):
    with open(src, "rb") as fd:
        image = fd.read()

    try:
        vars = image.split(b"STACKBOT")[1].split(b"\0")[0].decode("ascii")
    except Exception:
        return None

    return [i for i in vars.split("\n") if i]


def _marker_value(data, marker):
    if marker not in data:
        return None
    try:
        return data.split(marker, 1)[1].split(b"\0")[0].decode("ascii")
    except UnicodeDecodeError:
        return None


def find_version(data) -> Optional[LoaderVersion]:
    """The bootloader version in an image: aura's marker first, then legacy m1n1."""
    for loader, marker in (("aura", AURA_VERSION_MARKER), ("m1n1", LEGACY_VERSION_MARKER)):
        version = _marker_value(data, marker)
        if version is not None:
            return LoaderVersion(loader, version)
    return None


def get_version(path) -> Optional[LoaderVersion]:
    with open(path, "rb") as fd:
        return find_version(fd.read())


def needs_upgrade(installed: Optional[LoaderVersion], bundled: Optional[LoaderVersion]):
    """Whether an install's Stage 1 should be replaced by the bundled aura."""
    if installed is None or bundled is None:
        return False
    return installed.legacy or installed != bundled


def stage1_path(boot_dir, name):
    """Resolve a template's boot object, mapping legacy m1n1.bin to aura.bin."""
    path = os.path.join(boot_dir, name)
    if name in LEGACY_STAGE1_NAMES and not os.path.exists(path):
        return os.path.join(boot_dir, STAGE1_NAME)
    return path


# A Stage 1 enrolled as a Mach-O (T6050) carries its settings in a config
# block instead of variables after STACKBOT: the magic, then version 1, the
# proxy window in ms, the ESP PARTUUID (ASCII, NUL-padded to 40 bytes), and
# ";" plus the Stage 2 path on the ESP (NUL-padded to 192 bytes), then the
# CRC-32 of those fields.
STAGE1_CFG_MAGIC = b"AURORA-S1-CFG01\0"
STAGE1_CFG_FIELDS = struct.Struct("<II40s192s")
STAGE1_CFG_SIZE = len(STAGE1_CFG_MAGIC) + STAGE1_CFG_FIELDS.size + 4
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")


def macho_segments(image):
    """{name: (fileoff, filesize)} of a 64-bit Mach-O's segments."""
    if len(image) < 32 or struct.unpack_from("<I", image)[0] != 0xfeedfacf:
        raise ValueError("not a 64-bit Mach-O")
    ncmds, sizeofcmds = struct.unpack_from("<II", image, 16)
    off, end, segs = 32, 32 + sizeofcmds, {}
    for _ in range(ncmds):
        if off + 8 > end:
            raise ValueError("malformed Mach-O load commands")
        cmd, size = struct.unpack_from("<II", image, off)
        if size < 8 or off + size > end:
            raise ValueError("malformed Mach-O load commands")
        if cmd == 0x19:  # LC_SEGMENT_64
            name = image[off + 8:off + 24].rstrip(b"\0").decode("ascii", "replace")
            fileoff, filesize = struct.unpack_from("<QQ", image, off + 40)
            segs[name] = (fileoff, filesize)
        off += size
    return segs


def fill_stage1_macho(src, dest, esp_uuid, stage2_path, window_ms=0):
    """Write the Mach-O Stage 1 at src to dest with its config block filled."""
    with open(src, "rb") as fd:
        image = fd.read()
    segs = macho_segments(image)
    if "__TEXT_BOOT_EXEC" in segs:
        # kmutil would record a nonzero kcbz and iBoot would start SPTM.
        raise ValueError("Stage 1 Mach-O has a __TEXT_BOOT_EXEC segment")
    if not _UUID.fullmatch(esp_uuid):
        raise ValueError("ESP PARTUUID must be lowercase 8-4-4-4-12 hex")
    path = b";" + stage2_path.encode("ascii")
    parts = stage2_path.split("/")
    if (len(path) >= 192 or any(p in ("", ".", "..") for p in parts)
            or any(not 0x20 <= ord(c) < 0x7f or c in ";\\" for c in stage2_path)):
        raise ValueError(f"bad Stage 2 path {stage2_path!r}")
    if not 0 <= window_ms <= 99999:
        raise ValueError("Stage 1 proxy window must be 0..99999 ms")
    if image.count(STAGE1_CFG_MAGIC) != 1:
        raise ValueError("Stage 1 config block must occur exactly once")
    at = image.index(STAGE1_CFG_MAGIC)
    if not any(name != "__LINKEDIT" and size and start <= at and at + STAGE1_CFG_SIZE <= start + size
               for name, (start, size) in segs.items()):
        raise ValueError("Stage 1 config block is not in a file-backed segment")
    if struct.unpack_from("<I", image, at + len(STAGE1_CFG_MAGIC))[0] != 1:
        raise ValueError("unsupported Stage 1 config version")
    fields = STAGE1_CFG_FIELDS.pack(1, window_ms, esp_uuid.encode("ascii"), path)
    block = STAGE1_CFG_MAGIC + fields + struct.pack("<I", zlib.crc32(fields))
    out = image[:at] + block + image[at + STAGE1_CFG_SIZE:]
    assert len(out) == len(image)
    with open(dest, "wb") as fd:
        fd.write(out)
