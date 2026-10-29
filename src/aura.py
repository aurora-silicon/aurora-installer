# SPDX-License-Identifier: MIT
"""Aurora's bootloader (aura) images: version detection and variable handling.

aura shares m1n1's raw image format, so the same code handles both. Installs
made before the switch carry m1n1 (or an early aura) marked with the legacy
`##m1n1_ver##` tag; current aura images carry `##aura_ver##`.
"""

import os
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
