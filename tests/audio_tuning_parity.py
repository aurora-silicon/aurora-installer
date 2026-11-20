# SPDX-License-Identifier: MIT
"""One synthetic Mac, collected by both speaker tuning collectors.

The fixture under tests/fixtures/audio-tuning-parity/root is a made-up
system volume: tuning folders for three acoustic IDs, the shared DSP
database (macOS 26 layout) and per-folder databases (macOS 27 layout), the
volume configurations, shared files, a loudness manager and a synthetic
AudioDSP image with a made-up lsm2 lattice. Nothing in it comes from macOS.

The Python collector (asahi_firmware.audio_tuning) and the native installer
(NativeAudioTuningInputs, macOS/Tests/.../NativeAudioTuningParityTests.swift)
must write the same bundle for each case, byte for byte. expected.json holds
each bundle's SHA-256 per file; both test suites check against it, and the
Swift test also runs this script (`collect`) and compares every byte.

    python3 -I tests/audio_tuning_parity.py build DIR     # write the fixture
    python3 -I tests/audio_tuning_parity.py collect ROOT CASE OUT
    python3 -I tests/audio_tuning_parity.py golden         # rewrite expected.json
"""
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import struct
import sys
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

from asahi_firmware import audio_tuning, lsm2_fill, lsm2_lattice  # noqa: E402
import macho_fixtures  # noqa: E402

FIXTURE = HERE / "fixtures" / "audio-tuning-parity"
ROOT = FIXTURE / "root"
EXPECTED = FIXTURE / "expected.json"
TUNINGS = "System/Library/Audio/Tunings"

# A made-up serial number (the shared unit ID test vector) and board.
SERIAL = b"SYNTHETIC0A" + b"\0" * 21
TARGET = b"J999AP\0"

# Each case is one Mac: acoustic-id, speaker-thiele-small, build, speaker ID
# and whether the device tree root (board, unit) is readable.
CASES = {
    # macOS 26 layout: the shared database, a short lsm2 preset (fill),
    # calibration, shared files, the loudness manager, sidecars, a link.
    "aid97": {"acoustic": 97, "spts": bytes([2, 0, 22, 6, 1, 9]), "build": "00A001",
              "speaker": 3, "identity": True},
    # macOS 27 layout with another key in the folder's database (reduced),
    # a full lsm2 preset (no fill), no calibration, nothing identified.
    "aid98": {"acoustic": 98, "spts": None, "build": "00A002", "speaker": None,
              "identity": False},
    # macOS 27 layout holding only its entry (copied byte for byte),
    # calibration without a readable unit, an invalid strap (65535).
    "aid99": {"acoustic": 99, "spts": bytes([7, 7, 7]), "build": "25Z999",
              "speaker": 65535, "identity": False},
}

# Generated readback: every base ID and the saved append-map IDs, in an
# order the unit might use, with made-up values and names that exercise the
# encoder (empty, non-ASCII, astral, escapes, the 1024-byte limit).
COMPONENT_SHA256 = "5a" * 32
UNIT_VERSION = 0x00010203
NAMES = {0: "", 1: "Synthétique ✓ \"q\" \\ \U0001F600 \t", 2: "x" * 1024}


def readback(path, effect, files):
    saved = lsm2_fill.preset_ids(effect["aupreset"]["data"])
    ids = sorted(lsm2_fill.base_ids() | (saved - lsm2_fill.base_ids()), reverse=True)
    return {"unit_version": UNIT_VERSION, "component_sha256": COMPONENT_SHA256,
            "published": [{"id": i, "name": NAMES.get(i, f"Synthetic {i}"),
                           "bits": (i * 2654435761) & 0x3FFFFFFF} for i in ids]}


def preset(ids):
    data = struct.pack(">III", 0, 0, len(ids))
    data += b"".join(struct.pack(">If", i, (n + 1) / 13) for n, i in enumerate(ids))
    return data


def strip(ids, other=True):
    effects = []
    if other:
        effects.append({"unit": {"type": 0x61756678, "subtype": 0x73707033,
                                 "manufacturer": 0x6170706C}, "displayname": "Synthetic spp3"})
    if ids is not None:
        effects.append({"unit": {"type": 0x61756678, "subtype": lsm2_fill.SUBTYPE,
                                 "manufacturer": 0x6170706C},
                        "displayname": "Synthetic lsm2",
                        "aupreset": {"type": 0x61756678, "subtype": lsm2_fill.SUBTYPE,
                                     "manufacturer": 0x6170706C, "version": 0,
                                     "name": "Synthetic", "data": preset(ids)}})
    return plistlib.dumps({"strips": [{"name": "Synthetic", "effects": effects}]},
                          fmt=plistlib.FMT_BINARY)


def mode(paths, spid=3):
    return {"Output": [{"Hardware": [{"Box": {"Path": p}} for p in paths]}],
            "UnderlyingDeviceProperties": [{"Selector": "spid", "Value": spid}]}


def entry(aid, speaker, headphone=("Common/Graphs/builtin_headphone_out.dspg",), extra=None):
    value = {"Built-in Speaker": {"48k - General": mode(speaker),
                                  "48k - Movie- SSI": mode(speaker[:1]),
                                  "48k - Dictation ": mode([]), "48k - Dictation": mode([])},
             "Built-in Headphone": {"48k - General": mode(list(headphone))}}
    value.update(extra or {})
    return value


# Every plist value type and the encoder's edge cases, outside the speaker
# device so it is carried but never followed.
TYPES = {
    "Synthetic types": {
        "reals": [0.1, 1e16, 1e15, 1e-05, 0.0001, -2.5, 3.0, 5e-324, 1.7976931348623157e308,
                  123456789.125, -0.0],
        "integers": [0, -7, 2**63 - 1, -2**63, 65535],
        "flags": [True, False],
        "date": datetime.datetime(2026, 11, 20, 1, 2, 3),
        "data": bytes(range(256)) * 2,
        "nested": [[{"data": b"\x00" * 60, "short": b"\x01"}]],
        "text": "a & b < c > d \r\n e \r f \t g",
        "unicode": "Ünïcødé ✓ \U0001F600 é",
        "empty dict": {}, "empty list": [], "empty data": b"", "empty string": "",
        "keys": {"b": 1, "B": 2, "_": 3, "é": 4, "é": 5, "\U0001F600": 6, "Z": 7},
    }
}


def files():
    """Relative path -> bytes (or ('link', target)) of the fixture root."""
    base = sorted(lsm2_fill.base_ids())
    t = TUNINGS + "/"
    s97 = ["AID97/DSP/Graphs/builtin_speaker_out.dspg",
           "AID97/DSP/Strips/builtin_speaker_out_general.austrip",
           "AID97/DSP/Strips/builtin_speaker_out_general.propstrip",
           "AID97/DSP/Strips/alias.plist",
           "Common/Strips/shared_speaker.austrip", "Common/Strips/empty.plist"]
    s98 = ["AID98/DSP/Strips/builtin_speaker_out_general.austrip"]
    s99 = ["AID99/DSP/Graphs/builtin_speaker_out.dspg"]
    out = {
        t + "DeviceDSPDatabase.plist": plistlib.dumps(
            {"AID97": entry("AID97", s97, extra=TYPES), "AID12": entry("AID12", []),
             "AID98": entry("AID98", [])}, fmt=plistlib.FMT_BINARY),
        t + "GenericDSPDatabase.plist": plistlib.dumps({"Generic": {}}),
        t + "Config/AID97.plist": plistlib.dumps({"Volume": {"Max": 0, "Min": -64.5}}),
        t + "Config/AID98.plist": plistlib.dumps({"Volume": {"Max": -3}}, fmt=plistlib.FMT_BINARY),
        t + "Config/AID99.plist": b"synthetic volume configuration\n",
        t + "Common/Strips/shared_speaker.austrip": b"synthetic shared strip",
        t + "Common/Strips/empty.plist": b"",
        t + "Common/Graphs/builtin_headphone_out.dspg": b"synthetic headphone graph",
        t + "DRC/loudness-manager.plist": plistlib.dumps(
            {"Format": {"Synthetic": 1.5}, "Supported_Hardware": ["AID44", "AID97"]}),
        t + "AID97/ADM/config.plist": plistlib.dumps({"Synthetic": True}),
        t + "AID97/ADM/.DS_Store": b"Bud1 synthetic finder data",
        t + "AID97/._ADM": b"\x00\x05\x16\x07 synthetic AppleDouble",
        t + "AID97/DSP/Graphs/builtin_speaker_out.dspg": b"synthetic graph 97",
        # Short: 58 base IDs missing, one saved append-map ID (21512).
        t + "AID97/DSP/Strips/builtin_speaker_out_general.austrip": strip(base[58:] + [21512]),
        t + "AID97/DSP/Strips/builtin_speaker_out_general.propstrip": plistlib.dumps(
            {"Boxes": [{"Name": "Synthetic lsm2",
                        "Properties": [{"Number": 64000, "UInt32": 1},
                                       {"PropertyID": 64001, "Scope": 0,
                                        "Path": "DSP/Strips/aid97-aufx-spp3-appl.plist"}]}]}),
        t + "AID97/DSP/Strips/aid97-aufx-spp3-appl.plist": plistlib.dumps({"Synthetic": [1, 2]}),
        t + "AID97/DSP/Strips/alias.plist": ("link", "aid97-aufx-spp3-appl.plist"),
        t + "AID97/DSP/empty.bin": b"",
        t + "AID98/DSP/DSPDatabase.plist": plistlib.dumps(
            {"AID98": entry("AID98", s98, extra=TYPES), "Version": 2}, fmt=plistlib.FMT_BINARY),
        t + "AID98/ADM/config.plist": b"synthetic adm 98",
        # Full: every base ID, so no fill.
        t + "AID98/DSP/Strips/builtin_speaker_out_general.austrip": strip(base),
        t + "AID99/DSP/DSPDatabase.plist": plistlib.dumps(
            {"AID99": entry("AID99", s99, headphone=())}, fmt=plistlib.FMT_BINARY),
        t + "AID99/DSP/Graphs/builtin_speaker_out.dspg": b"synthetic graph 99",
        t + "AID99/DSP/Strips/builtin_speaker_out_general.austrip": strip(None),
        lsm2_lattice.AUDIODSP: macho_fixtures.fat(
            macho_fixtures.thin(macho_fixtures.padded(macho_fixtures.synthetic_lattice()),
                                cpu=macho_fixtures.CPU_X86_64),
            macho_fixtures.thin(macho_fixtures.padded(macho_fixtures.synthetic_lattice()))),
    }
    return out


def build(root):
    root = pathlib.Path(root)
    for rel, data in files().items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(data, tuple):
            if path.is_symlink() or path.exists():
                path.unlink()
            os.symlink(data[1], path)
        else:
            path.write_bytes(data)


class Run(object):
    def __init__(self, returncode, stdout=b""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, b""


def fake_run(case):
    def run(argv, capture_output=True):
        if argv[:1] == ["ioreg"] and "acoustic-id" in argv:
            node = {"acoustic-id": case["acoustic"].to_bytes(4, "little")}
            if case["spts"] is not None:
                node["speaker-thiele-small"] = case["spts"]
            return Run(0, plistlib.dumps([node]))
        if argv[:1] == ["ioreg"] and "device-tree" in argv:
            if not case["identity"]:
                return Run(1)
            return Run(0, plistlib.dumps([{"target-type": TARGET, "serial-number": SERIAL}]))
        if argv[:1] == ["ioreg"] and "speakerID" in argv:
            services = [{"device UID": "Codec"}]
            if case["speaker"] is not None:
                services.append({"device UID": "Speaker", "speakerID": case["speaker"]})
            return Run(0, plistlib.dumps(services))
        if argv == ["sysctl", "-n", "kern.osversion"]:
            return Run(0, case["build"].encode() + b"\n")
        raise AssertionError(f"unexpected command {argv}")
    return run


def collect(root, name):
    """The Python collector's bundle for one case, relative path -> bytes."""
    root = pathlib.Path(root)
    case = CASES[name]
    with mock.patch.object(audio_tuning.sys, "platform", "darwin"), \
            mock.patch.object(lsm2_fill, "isolated_read_parameters", readback):
        collection = audio_tuning.AudioTuningFWCollection(
            tunings_root=str(root / TUNINGS), run=fake_run(case),
            audiodsp=str(root / lsm2_lattice.AUDIODSP))
    if not collection.bundle:
        raise RuntimeError(f"{name}: the Python collector wrote no bundle")
    return collection.bundle


def digests(bundle):
    return {rel: hashlib.sha256(data).hexdigest() for rel, data in sorted(bundle.items())}


def main(argv):
    if argv[:1] == ["build"] and len(argv) == 2:
        build(argv[1])
    elif argv[:1] == ["collect"] and len(argv) == 4:
        out = pathlib.Path(argv[3])
        for rel, data in collect(argv[1], argv[2]).items():
            (out / rel).parent.mkdir(parents=True, exist_ok=True)
            (out / rel).write_bytes(data)
    elif argv == ["golden"]:
        golden = {name: digests(collect(ROOT, name)) for name in sorted(CASES)}
        EXPECTED.write_text(json.dumps(golden, indent=2, sort_keys=True) + "\n")
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
