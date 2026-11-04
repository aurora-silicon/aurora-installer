# SPDX-License-Identifier: MIT
"""Optional, machine-local Apple AVD MCPU reload images.

No firmware is bundled. Unknown layouts remain disabled instead of borrowing
another SoC's image. Source authentication belongs to the installer transaction.
"""

from dataclasses import dataclass
import json
import logging
import os
from pathlib import Path
import plistlib
import stat

from .core import FWFile
from .img4 import img4p_extract

log = logging.getLogger("asahi_firmware.avd")


@dataclass(frozen=True)
class AVDSource:
    component: str
    image_type: str


@dataclass(frozen=True)
class AVDSoC:
    size: int = None
    version: int = None
    preloaded: bool = False
    sources: tuple = ()


# Size and version are independent of the AVD hardware register version.
# T6040's observed version is the macOS firmware property; it is not an
# established byte offset within the image. Its disk image is a reload copy:
# iBoot/IPCE supplies the image macOS actually starts.
AVD_SOCS = {
    "t8103": AVDSoC(),
    "t6000": AVDSoC(),
    "t6001": AVDSoC(),
    "t6002": AVDSoC(),
    "t8112": AVDSoC(),
    "t6020": AVDSoC(),
    "t6021": AVDSoC(),
    "t6022": AVDSoC(),
    "t8122": AVDSoC(),
    "t6030": AVDSoC(),
    "t6031": AVDSoC(),
    "t6034": AVDSoC(),
    "t8132": AVDSoC(),
    "t6040": AVDSoC(60616, 0x23F3B998, preloaded=True),
    "t6041": AVDSoC(),
    "t6042": AVDSoC(),
    "t8140": AVDSoC(),
    "t8142": AVDSoC(),
}


def soc_name(chip_id):
    if isinstance(chip_id, int):
        return f"t{chip_id:04x}"
    return chip_id if chip_id in AVD_SOCS else None


def firmware_name(chip_id):
    soc = soc_name(chip_id)
    return f"apple/avd-apple-{soc}.bin" if soc in AVD_SOCS else None


def selected_identity(source):
    manifest = Path(source) / "BuildManifest.plist"
    if manifest.exists():
        with manifest.open("rb") as stream:
            identities = plistlib.load(stream).get("BuildIdentities", [])
        if len(identities) != 1:
            raise ValueError("AVD collection requires one selected build identity")
        return identities[0]
    return None


def selected_chip_id(source):
    """Use the selected install identity, never the refresh host's hardware."""
    source = Path(source)
    chips = set()
    identity = selected_identity(source)
    if identity is not None:
        chips.add(identity.get("ApChipID"))
    stub_info = source / "stub_info.json"
    if stub_info.exists():
        with stub_info.open() as stream:
            chip = json.load(stream).get("manifest_info", {}).get("chip_id")
        if chip is not None:
            chips.add(chip)
    if not chips:
        return None
    if any(not isinstance(chip, str) or not chip.startswith("0x") for chip in chips):
        raise ValueError("Invalid selected AVD chip identity")
    values = {int(chip, 16) for chip in chips}
    if len(values) != 1:
        raise ValueError("Conflicting selected AVD chip identities")
    return values.pop()


def reload_image(data, chip_id):
    """Validate a previously collected raw MCPU image for the selected SoC."""
    soc = soc_name(chip_id)
    spec = AVD_SOCS.get(soc)
    if spec is None or spec.size is None or spec.version is None:
        return None
    if len(data) != spec.size:
        raise ValueError(f"Unexpected {soc} AVD reload image size: {len(data)}")
    return FWFile(firmware_name(soc), data, version=spec.version)


def collect_avd(chip_id, components):
    """Unwrap only configured components of the already selected identity.

    Source rules must be established independently for each SoC before enabling
    them in AVD_SOCS. In particular, preloading is not proof of an IM4P tag.
    """
    spec = AVD_SOCS.get(soc_name(chip_id))
    if spec is None or spec.size is None:
        return None
    image = None
    for rule in spec.sources:
        data = components.get(rule.component)
        if data is None:
            continue
        if len(data) > 16 << 20:
            raise ValueError("AVD source exceeds its size limit")
        image_type, raw = img4p_extract(data, maximum_size=spec.size)
        if image_type != rule.image_type:
            raise ValueError("Unexpected selected AVD image type")
        candidate = reload_image(raw, chip_id)
        if image is not None and image.data != candidate.data:
            raise ValueError("Conflicting AVD reload images")
        image = candidate
    return image


def collect_from_restore(restore, identity, chip_id):
    """Read selected restore components; never scan other build identities."""
    spec = AVD_SOCS.get(soc_name(chip_id))
    if spec is None or not spec.sources:
        return None
    if int(identity["ApChipID"], 16) != chip_id:
        raise ValueError("AVD restore identity differs from the selected chip")
    components = {}
    for rule in spec.sources:
        entry = identity["Manifest"].get(rule.component)
        if entry is None:
            continue
        path = entry["Info"]["Path"]
        if not isinstance(path, str) or path.startswith("/") or "\\" in path or any(
                part in ("", ".", "..") for part in path.split("/")):
            raise ValueError("Unsafe selected AVD source path")
        try:
            with (Path(restore) / path).open("rb") as source:
                components[rule.component] = source.read((16 << 20) + 1)
        except FileNotFoundError:
            continue
    return collect_avd(chip_id, components)


class AVDFWCollection:
    """Read only the selected machine's optional fallback reload copy."""

    def __init__(self, source_path, chip_id):
        self.fwfiles = []
        name = firmware_name(chip_id)
        spec = AVD_SOCS.get(soc_name(chip_id))
        if name is None or spec.size is None:
            return
        path = Path(source_path) / name
        if path.parent.is_symlink():
            raise ValueError("AVD reload copy directory must not be a symlink")
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size != spec.size:
                    raise ValueError("AVD reload copy must be a regular file of the expected size")
                data = source.read(spec.size + 1)
        except FileNotFoundError:
            log.info("Apple AVD reload image absent; using open firmware")
            return
        image = reload_image(data, chip_id)
        self.fwfiles.append((image.name, image))

    def files(self):
        return self.fwfiles
