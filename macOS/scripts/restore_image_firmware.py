# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""Records, for every restore image the sealed inspection policy admits, the
firmware classes each admitted Mac's build identity carries in that image.

Maintenance tool only: the app never reads its output. The output,
macOS/scripts/restore-image-firmware.json, is what the tests check the
installer's collection against (scripts/tests/test_restore_image_firmware.py
and NativeRestoreImageFirmwareTests.swift), so a Mac whose restore image
carries a firmware class the installer would not collect fails a test
instead of installing without it.

It holds no Apple data: per image, its build, URL and the SHA-256 of its
BuildManifest.plist; per Mac, the identity's chip ID, how many distinct N1
(`Wireless1,`) images the identity names and whether the image has the
Mac's N1 ticket in the stub's restore manifests
(Firmware/Manifests/restore/<variant>/centauri/centauri.<class>.im4m).

Each image is read by HTTP ranges (asahi_firmware/remotezip.py): its
BuildManifest and its central directory, a few MB. Run it again when the
policy admits another image or Mac:

    python3 -I macOS/scripts/restore_image_firmware.py \\
        > macOS/scripts/restore-image-firmware.json

`--manifest BUILD=PATH` uses a local BuildManifest.plist and
`--members BUILD=PATH` a local member list (one archive member name per
line) instead of the network, for offline runs.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
POLICY = REPO / "macOS/Sources/AuroraAppleInstaller/NativeInspectionPolicySource.swift"
BUILD = re.compile(r"_([0-9]{2}[A-Z][0-9]{1,5}[a-z]?)_Restore\.ipsw$")
MAC = re.compile(r"\A[jk][0-9]+[a-z]*ap\Z")


def sealed_policy():
    text = POLICY.read_text()
    start = text.index('#"""') + len('#"""')
    return json.loads(text[start:text.index('"""#', start)])


def layout(url):
    """(variant, restore behavior, member prefix) of the stub's restore source,
    as NativeRestoreSourceLayout reads it."""
    if url.endswith(".ipsw"):
        return "macOS Customer", "Erase", ""
    if url.endswith(".zip") and "/com_apple_MobileAsset_MacSoftwareUpdate/" in url:
        return "macOS Customer Software Update", "Update", "AssetData/boot/"
    raise SystemExit(f"{url}: not a restore source the installer admits")


def build_of(entry, manifest):
    match = BUILD.search(entry["sourceURL"])
    build = manifest.get("ProductBuildVersion")
    if match and match.group(1) != build:
        raise SystemExit(f"{entry['sourceURL']} holds {build}")
    return build


def identities(entry, manifest, members):
    variant, behavior, prefix = layout(entry["sourceURL"])
    models = entry["models"]
    out = {}
    for identity in manifest["BuildIdentities"]:
        info = identity.get("Info", {})
        device = info.get("DeviceClass", "")
        if info.get("Variant") != variant or info.get("RestoreBehavior") != behavior:
            continue
        if not MAC.match(device):
            continue
        machine = device[:-2]
        if models is not None and machine not in models:
            continue
        wireless = {
            component["Info"]["Path"]
            for key, component in identity["Manifest"].items()
            if key.startswith("Wireless1,")
        }
        ticket = f"{prefix}Firmware/Manifests/restore/{variant}/centauri/centauri.{device}.im4m"
        record = {"chip_id": identity["ApChipID"], "n1_images": len(wireless)}
        if wireless:
            record["n1_ticket"] = ticket in members
        if machine in out and out[machine] != record:
            raise SystemExit(f"{machine}: identities of one variant disagree")
        out[machine] = record
    if models is not None:
        missing = sorted(set(models) - set(out))
        if missing:
            raise SystemExit(f"{entry['sourceURL']}: no {variant} identity for {missing}")
    return dict(sorted(out.items()))


def remote(url, prefix):
    sys.path.insert(0, str(REPO))
    from asahi_firmware import remotezip

    z = remotezip.RemoteZip(url)
    return z.members[prefix + "BuildManifest.plist"].read(), set(z.members)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--manifest", action="append", default=[], metavar="BUILD=PATH")
    ap.add_argument("--members", action="append", default=[], metavar="BUILD=PATH")
    args = ap.parse_args(argv)
    local = dict(spec.split("=", 1) for spec in args.manifest)
    lists = dict(spec.split("=", 1) for spec in args.members)
    images = []
    for entry in sealed_policy()["firmware"]:
        url = entry["sourceURL"]
        prefix = layout(url)[2]
        match = BUILD.search(url)
        key = match.group(1) if match else None
        if key in local and key in lists:
            data = pathlib.Path(local[key]).read_bytes()
            members = set(pathlib.Path(lists[key]).read_text().split("\n"))
        else:
            data, members = remote(url, prefix)
        manifest = plistlib.loads(data)
        images.append({
            "build": build_of(entry, manifest),
            "url": url,
            "manifest_sha256": hashlib.sha256(data).hexdigest(),
            "identities": identities(entry, manifest, members),
        })
    doc = {"schema": 1, "kind": "aurora-restore-image-firmware", "images": images}
    sys.stdout.write(json.dumps(doc, indent=1) + "\n")


if __name__ == "__main__":
    main()
