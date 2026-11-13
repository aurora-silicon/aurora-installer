# SPDX-License-Identifier: MIT
"""MediaTek MT7932 (J700) Wi-Fi and Bluetooth firmware from a macOS tree.

The same conversion as the native installer's NeoFirmwareConversions
(macOS/Sources/AuroraFirmware/NeoFirmwareConversions.swift) for the files a
macOS update can change: the Wi-Fi patch and RAM images, the power-profile
record, the radio configuration and the Bluetooth images and PTX. The
factory calibration (OCA2, WCAL, BCAL), the Bluetooth address and the
regulatory policies are this Mac's own records and are not handled here.
"""
import logging, os, re

from .core import FWFile

log = logging.getLogger("asahi_firmware.mt7932")

# Paths inside a macOS System volume.
WIFI_DIR = "System/Library/DriverExtensions/com.apple.AppleSunriseWLAN.dext/IZUBA"
BT_DIR = "usr/share/firmware/bluetooth"

PATCH = "IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin"
RAM = "IZUBA_W7932_2.bin"
PPR = "IZUBA_PPR_MT7932.bin"
CONFIG = "IZUBA_wifi.cfg"
WIFI_SOURCES = (PATCH, RAM, PPR, CONFIG)

# Names the kernel drivers request (mt7932-fullmac, mt7932_bt_pcie).
OUT_PATCH = "mediatek/mt7932/" + PATCH
OUT_RAM = "mediatek/mt7932/" + RAM
OUT_PPR = "mediatek/mt7932/ppr.bin"
OUT_CONFIG = "mediatek/mt7932/config-original.bin"
# Version-independent names for the Bluetooth images: the newest image of
# each kind under one name that does not change with macOS.
ALIAS_B0 = "mediatek/mt7932/bt-b0.bin"
ALIAS_B1 = "mediatek/mt7932/bt-b1.bin"
ALIAS_PTX = "mediatek/mt7932/bt-ptb.ptx"

BT_IMAGE = re.compile(r"MT7932(B[01])_OS_TypeB_([0-9]+(?:\.[0-9]+){3})_([0-9]{12})\.bin")
BT_PTX = re.compile(r"MT7932_PTB_IzubaA_([0-9]+(?:\.[0-9]+){3})_([0-9]{14})\.ptx")

# Every name this collection writes; a package's MT7932 firmware set is the
# subset of its names that match.
OWNED = re.compile(r"mediatek/(?:mt7932/(?:" + re.escape(PATCH) + "|" + re.escape(RAM)
                   + r"|ppr\.bin|config-original\.bin|bt-b[01]\.bin|bt-ptb\.ptx)"
                   r"|MT7932B[01]_OS_TypeB_[^/]*\.bin|MT7932_PTB_IzubaA_[^/]*\.ptx)")

BUDGET = 16 << 20


class Invalid(ValueError):
    pass


def require(cond, why):
    if not cond:
        raise Invalid(why)


def le(data, at, n):
    require(0 <= at and at + n <= len(data), "truncated record")
    return int.from_bytes(data[at:at + n], "little")


def configuration(data):
    """IZUBA_wifi.cfg ("key value" lines) -> the J7CF records the driver
    loads as config-original.bin."""
    require(len(data) <= 1 << 20, "radio configuration exceeds its budget")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise Invalid("radio configuration must be ASCII")
    records, keys = bytearray(), set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition(" ")
        value = value.strip()
        k, v = key.encode(), value.encode()
        require(k and len(k) < 32 and len(v) < 32 and b"\0" not in k and b"\0" not in v
                and key not in keys, "invalid or repeated radio setting")
        keys.add(key)
        records += bytes([3, len(k), len(v), 0]) + k.ljust(32, b"\0") + v.ljust(32, b"\0")
        require(len(keys) <= 65, "too many radio settings")
    require(len(keys) in (64, 65) and "Sta5gBw" in keys and "DisRoaming" in keys,
            "required radio settings are missing")
    return b"J7CF" + len(keys).to_bytes(4, "little") + bytes(records)


def validate_ppr(data):
    require(len(data) == 412 and data[:4] == b"BLOB", "invalid PPR envelope")


def validate_image(data):
    require(0 < len(data) <= BUDGET, "missing or oversized Wi-Fi image")


def validate_bluetooth(data):
    require(32 < len(data) <= BUDGET
            and data[-16:-8] == bytes([0x41, 0x4c, 0x50, 0x53, 0x8a, 0x10, 0x8a, 0x10]),
            "invalid Bluetooth firmware trailer")


def validate_ptx(data):
    require(len(data) == 198 and data[:4] == b"BLOB", "invalid PTX envelope")
    require(le(data, 4, 4) == 96 and le(data, 8, 2) == 1 and le(data, 10, 2) == 4
            and le(data, 12, 4) == 0, "invalid PTX header")
    offset = 96
    for index, (kind, size) in enumerate(((0x101, 14), (0x201, 44), (0x301, 44), (0x401, 0))):
        at = 16 + index * 20
        require(le(data, at, 4) == kind and le(data, at + 4, 4) == offset
                and le(data, at + 8, 4) == size and le(data, at + 16, 4) == 0,
                "invalid PTX record")
        require(sum(data[offset:offset + size]) == le(data, at + 12, 4), "PTX checksum changed")
        offset += size
    require(offset == len(data), "trailing PTX data")


def version_key(version, stamp):
    return tuple(int(x) for x in version.split(".")) + (int(stamp),)


def _read(path):
    with open(path, "rb") as f:
        data = f.read(BUDGET + 1)
    require(len(data) <= BUDGET, f"{os.path.basename(path)} exceeds its budget")
    return data


class MT7932FWCollection:
    """wifi_dir: a copy of WIFI_DIR (at least WIFI_SOURCES); bt_dir: a copy
    of BT_DIR (its MT7932 files are used). Raises Invalid when a file is
    missing or does not have the layout the driver checks."""

    def __init__(self, wifi_dir, bt_dir):
        self.out = {}
        for name in WIFI_SOURCES:
            path = os.path.join(wifi_dir, name)
            require(os.path.isfile(path), f"{name} is missing")
        patch, ram = _read(os.path.join(wifi_dir, PATCH)), _read(os.path.join(wifi_dir, RAM))
        validate_image(patch)
        validate_image(ram)
        ppr = _read(os.path.join(wifi_dir, PPR))
        validate_ppr(ppr)
        self.out[OUT_PATCH] = FWFile(OUT_PATCH, patch)
        self.out[OUT_RAM] = FWFile(OUT_RAM, ram)
        self.out[OUT_PPR] = FWFile(OUT_PPR, ppr)
        self.out[OUT_CONFIG] = FWFile(OUT_CONFIG,
                                      configuration(_read(os.path.join(wifi_dir, CONFIG))))

        newest = {}
        names = sorted(os.listdir(bt_dir)) if os.path.isdir(bt_dir) else []
        for fname in names:
            path = os.path.join(bt_dir, fname)
            if not os.path.isfile(path):
                continue
            m, p = BT_IMAGE.fullmatch(fname), BT_PTX.fullmatch(fname)
            if m:
                data = _read(path)
                validate_bluetooth(data)
                kind, key = m[1], version_key(m[2], m[3])
            elif p:
                data = _read(path)
                validate_ptx(data)
                kind, key = "PTX", version_key(p[1], p[2])
            else:
                continue
            self.out["mediatek/" + fname] = FWFile("mediatek/" + fname, data)
            if kind not in newest or key > newest[kind][0]:
                newest[kind] = (key, data)
        for kind, alias in (("B0", ALIAS_B0), ("B1", ALIAS_B1), ("PTX", ALIAS_PTX)):
            require(kind in newest, f"no MT7932 Bluetooth {kind} file in {BT_DIR}")
            self.out[alias] = FWFile(alias, newest[kind][1])

    def files(self):
        return sorted(self.out.items())


def owned(name):
    return OWNED.fullmatch(name) is not None
