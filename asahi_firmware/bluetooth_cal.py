# SPDX-License-Identifier: MIT
"""Bluetooth calibration from the factory data.

The M3 and M4 Macs' device tree carries no Taurus calibration for their
BCM4388: macOS reads it from the factory data, the BTBF field of the
BWCl record (an IMG4 whose IM4P payload is a DER set of fields, each a
SEQUENCE of the reversed four-character name, a string and the value).
Linux's hci_bcm4377 loads it as apple/bluetooth-taurus-calibration-bf.bin.
"""
import logging, os

from .core import FWFile

log = logging.getLogger("asahi_firmware.bluetooth_cal")

FACTORY_DIR = "/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata"
FILENAME = "apple/bluetooth-taurus-calibration-bf.bin"


class FactoryError(ValueError):
    pass


def _element(data, at, end):
    if end - at < 2:
        raise FactoryError("truncated element")
    tag = data[at]
    at += 1
    if tag & 0x1f == 0x1f:
        # High tag number form: base-128 continuation bytes.
        while True:
            if at >= end:
                raise FactoryError("truncated tag")
            byte = data[at]
            at += 1
            if not byte & 0x80:
                break
        tag = 0x1f | (tag & 0xe0)
    if at >= end:
        raise FactoryError("truncated length")
    length = data[at]
    at += 1
    if length & 0x80:
        count = length & 0x7f
        if not 1 <= count <= 4 or at + count > end:
            raise FactoryError("invalid length")
        length = int.from_bytes(data[at:at + count], "big")
        at += count
    if length > end - at:
        raise FactoryError("element escapes its container")
    return tag, at, at + length


def _children(data, start, end):
    items = []
    while start < end:
        item = _element(data, start, end)
        items.append(item)
        start = item[2]
    return items


def factory_fields(data, record_type):
    """The named fields of a factory IMG4 record of the given IM4P type."""
    tag, start, end = _element(data, 0, len(data))
    if tag != 0x30 or end != len(data):
        raise FactoryError("invalid envelope")
    outer = _children(data, start, end)
    if len(outer) < 2 or data[outer[0][1]:outer[0][2]] != b"IMG4":
        raise FactoryError("not an IMG4")
    payload = _children(data, outer[1][1], outer[1][2])
    if (len(payload) < 4 or data[payload[0][1]:payload[0][2]] != b"IM4P"
            or data[payload[1][1]:payload[1][2]] != record_type.encode()
            or payload[3][0] != 0x04):
        raise FactoryError(f"not an IM4P {record_type}")
    fields = {}
    pending = [(payload[3][1], payload[3][2], 0)]
    while pending:
        start, end, depth = pending.pop()
        if depth > 32:
            raise FactoryError("nesting too deep")
        for tag, istart, iend in _children(data, start, end):
            if not tag & 0x20:
                continue
            inner = _children(data, istart, iend)
            if (tag == 0x30 and len(inner) == 3 and inner[0][0] == 0x02
                    and inner[0][2] - inner[0][1] == 4 and inner[1][0] == 0x16
                    and inner[2][0] == 0x04):
                name = bytes(reversed(data[inner[0][1]:inner[0][2]])).decode("ascii", "replace")
                if name in fields:
                    raise FactoryError(f"duplicate field {name}")
                fields[name] = data[inner[2][1]:inner[2][2]]
            else:
                pending.append((istart, iend, depth + 1))
    return fields


def bluetooth_calibration(data):
    """The btbf calibration blob of a BWCl record."""
    blob = factory_fields(data, "BWCl").get("BTBF")
    if blob is None:
        raise FactoryError("no BTBF field")
    if len(blob) < 16 or blob[:4] != b"BLOB" or len(blob) > 1 << 20:
        raise FactoryError("BTBF is not a calibration BLOB")
    return blob


class BluetoothCalFWCollection(object):
    def __init__(self, path=None):
        self.fwfiles = []
        self.load(path if path is not None else FACTORY_DIR)

    def files(self):
        return self.fwfiles

    def load(self, path):
        try:
            names = sorted(f for f in os.listdir(path) if f.startswith("BWCl-"))
        except OSError:
            log.info("No factory data; no Bluetooth calibration collected")
            return
        if not names:
            return
        if len(names) > 1:
            log.warning(f"Several Bluetooth calibration records ({names}); none collected")
            return
        try:
            with open(os.path.join(path, names[0]), "rb") as f:
                blob = bluetooth_calibration(f.read())
        except (OSError, FactoryError) as e:
            log.warning(f"Unable to read the Bluetooth calibration from {names[0]}: {e}")
            return
        self.fwfiles.append((FILENAME, FWFile(FILENAME, blob)))
        log.info(f"  Collected {FILENAME} ({len(blob)} bytes)")
