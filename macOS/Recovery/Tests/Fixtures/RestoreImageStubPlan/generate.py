#!/usr/bin/env python3
"""Regenerate the restore images and expected.json for RestoreImageStubPlanCheck.swift.

Each case is a small restore image laid out like UniversalMac_*_Restore.ipsw
(ZIP64, deflated property lists, links in the Bootability tree). expected.json
holds, for each image that admits a plan, the copies, links and restore
directory worked out here by a reference of the main installer's
NativeStubFilePlan selection written in Python, and "refuse" for the rest.
The main installer's NativeStubFileTests and Recovery's check both read it.
Deterministic. Usage (from this directory): python3 generate.py
"""
import json
import plistlib
import struct
import unicodedata
import warnings
import zipfile
import zlib

BOARD, CHIP, CLASS, VERSION, BUILD = 0x22, 0x6000, "j314sap", "26.6.2", "25G100"
VARIANT = "macOS Customer"
BOOT = "BootabilityBundle/Restore/Bootability"
SKIPPED = {"BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata", "RestoreRamDisk",
           "RestoreTrustCache"}


def identity(board, variant=VARIANT, behavior="Erase", device=CLASS, components=None):
    return {
        "ApBoardID": hex(board), "ApChipID": hex(CHIP),
        "Info": {"DeviceClass": device, "RestoreBehavior": behavior, "Variant": variant,
                 "BuildNumber": BUILD},
        "Manifest": {k: {"Info": {"Path": v}} for k, v in (components or {}).items()},
    }


COMPONENTS = {
    "BaseSystem": "090-00001-001.dmg",
    "OS": "090-00002-001.dmg",
    "RestoreRamDisk": "090-00003-001.dmg",
    "Cryptex1,SystemOS": "090-00004-001.dmg",
    "KernelCache": "kernelcache.release.mac14j",
    "LLB": "Firmware/all_flash/LLB.j314s.RELEASE.im4p",
    "iBoot": "Firmware/all_flash/iBoot.j314s.RELEASE.im4p",
    "DeviceTree": "Firmware/all_flash/DeviceTree.j314sap.im4p",
}


def base():
    """name -> (bytes, 'file'|'link'|'dir', deflate)"""
    m = {}
    def f(name, data, deflate=False):
        m[name] = (data, "file", deflate)
    f("BuildManifest.plist", plistlib.dumps({"BuildIdentities": [
        identity(0x24, components=COMPONENTS),
        identity(BOARD, variant="macOS Customer Software Update", behavior="Update",
                 components=COMPONENTS),
        identity(BOARD, components=COMPONENTS),
    ]}), True)
    f("usr/standalone/bootcaches.plist", plistlib.dumps({"bless2": {}}), True)
    f("SystemVersion.plist", plistlib.dumps(
        {"ProductVersion": VERSION, "ProductUserVisibleVersion": VERSION,
         "ProductBuildVersion": BUILD}), True)
    f("RestoreVersion.plist", plistlib.dumps({"ProductBuildVersion": BUILD}), True)
    f("PlatformSupport.plist", plistlib.dumps({"SupportedBoardIds": ["Mac-0"]}), True)
    m[BOOT + "/"] = (b"", "dir", False)
    f(BOOT + "/Bootability.plist", b"<plist/>" * 40, True)
    m[BOOT + "/Frameworks/Boot.framework/Versions/A/"] = (b"", "dir", False)
    f(BOOT + "/Frameworks/Boot.framework/Versions/A/Boot", b"\xcf\xfa\xed\xfe" + bytes(300))
    m[BOOT + "/Frameworks/Boot.framework/Versions/Current"] = (b"A", "link", False)
    m[BOOT + "/Frameworks/Boot.framework/Boot"] = (b"Versions/Current/Boot", "link", False)
    f("BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache", bytes(range(64)))
    f("Firmware/Manifests/restore/" + VARIANT + "/apticket.j314s.im4m", b"0\x82" + bytes(50))
    f("Firmware/Manifests/restore/macOS Customer Software Update/apticket.j314s.im4m", b"x")
    for key, path in COMPONENTS.items():
        f(path, key.encode() * 20, path.startswith("Firmware/"))
    f("Restore.plist", plistlib.dumps({}), True)
    return m


def write(path, members, duplicate=None):
    items = list(members.items())
    if duplicate:
        items.append((duplicate, members[duplicate]))
    with zipfile.ZipFile(path, "w") as archive:
        for name, (data, kind, deflate) in items:
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 23, 0, 0, 0))
            info.create_system = 3
            info.external_attr = {"file": 0o100644, "link": 0o120755, "dir": 0o040755}[kind] << 16
            info.compress_type = zipfile.ZIP_DEFLATED if deflate else zipfile.ZIP_STORED
            # Restore images are ZIP64 throughout.
            with archive.open(info, "w", force_zip64=kind != "dir") as out:
                out.write(data)


def raw_deflate(data):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def write_raw(path, members, raw):
    """A classic ZIP whose member `raw[0]` has the deflate stream `raw[1]`, which zipfile
    can't be made to write."""
    out, central = bytearray(), bytearray()
    for name, (data, kind, deflate) in members.items():
        body = raw[1] if name == raw[0] else raw_deflate(data) if deflate else data
        method = 8 if deflate or name == raw[0] else 0
        mode = {"file": 0o100644, "link": 0o120755, "dir": 0o040755}[kind]
        crc, encoded, at = zlib.crc32(data), name.encode(), len(out)
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, method, 0, 0x5B77, crc, len(body),
                           len(data), len(encoded), 0) + encoded + body
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 0x0314, 20, 0, method, 0, 0x5B77,
                               crc, len(body), len(data), len(encoded), 0, 0, 0, 0, mode << 16,
                               at) + encoded
    start = len(out)
    out += central + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(members), len(members),
                                 len(central), start, 0)
    open(path, "wb").write(out)


# Characters that join the character before them (grapheme extenders) or after them
# (prepend): either way a '/' next to one is not a Character of its own. This covers the
# marks these fixtures use; the Swift side asks String itself.
PREPEND = set("\u0600\u0601\u0602\u0603\u0604\u0605\u06dd\u070f\u0890\u0891\u08e2")


def separators_alone(path):
    for i, ch in enumerate(path):
        if ch != "/":
            continue
        after = path[i + 1] if i + 1 < len(path) else ""
        before = path[i - 1] if i else ""
        if after and (unicodedata.category(after) in ("Mn", "Mc", "Me")
                      or after == "\u200d" or "\ufe00" <= after <= "\ufe0f"):
            return False
        if before in PREPEND:
            return False
    return True


def safe(path):
    """The main installer's safeRelative: UTF-8 bytes, and every '/' a Character of its own."""
    b = path.encode()
    return (b != b"" and not any(c in b for c in b"\\\0\r\n")
            and all(p not in (b"", b".", b"..") for p in b.split(b"/"))
            and separators_alone(path))


def hexid(value):
    digits = value[2:] if value.startswith("0x") else ""
    return int(digits, 16) if digits and all(c in "0123456789abcdefABCDEF" for c in digits) else None


def plan(members):
    """The reference selection; None when the image is refused."""
    files = {n: v for n, v in members.items()}
    if "AssetData/boot/BuildManifest.plist" in files or "BuildManifest.plist" not in files:
        return None
    try:
        document = plistlib.loads(files["BuildManifest.plist"][0])
        caches = plistlib.loads(files["usr/standalone/bootcaches.plist"][0])
        version = plistlib.loads(files["SystemVersion.plist"][0])
    except Exception:
        return None
    raw = caches["bless2"].get("RestoreBundlePath", "./Restore")
    restore = raw[2:] if raw.startswith("./") else raw
    chosen = next((i for i in document["BuildIdentities"]
                   if hexid(i["ApBoardID"]) == BOARD and hexid(i["ApChipID"]) == CHIP
                   and i["Info"]["DeviceClass"] == CLASS and i["Info"]["Variant"] == VARIANT
                   and i["Info"]["RestoreBehavior"] == "Erase"), None)
    if chosen is None or not safe(restore) or version.get("ProductVersion") != VERSION:
        return None
    components = chosen["Manifest"]
    recovery = components["BaseSystem"]["Info"]["Path"]
    if recovery not in files or files[recovery][1] == "dir" or not files[recovery][0]:
        return None
    copies = []
    def add(member, role, path, data=None):
        entry = files.get(member)
        if not (safe(member) and safe(path) and entry and entry[1] != "dir" and entry[0]):
            raise ValueError(member)
        for c in copies:
            if c["role"] == role and c["path"] == path:
                if c["member"] != member:
                    raise ValueError(path)
                return
        copies.append({"member": member, "role": role, "path": path, "installerDataName": data})
    def tree(prefix, at):
        names = sorted(n for n, v in files.items() if n.startswith(prefix + "/") and v[1] != "dir")
        if not names:
            raise ValueError(prefix)
        for n in names:
            add(n, "Preboot", at + "/" + n[len(prefix) + 1:])
    try:
        add("usr/standalone/bootcaches.plist", "System", "usr/standalone/bootcaches.plist")
        add("PlatformSupport.plist", "System", "System/Library/CoreServices/PlatformSupport.plist")
        for n in ("SystemVersion.plist", "RestoreVersion.plist", "usr/standalone/bootcaches.plist"):
            add(n, "Preboot", restore + "/" + n, n if n == "RestoreVersion.plist" else None)
        tree(BOOT, restore + "/Bootability")
        add("BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache", "Preboot",
            restore + "/Bootability/Bootability.trustcache")
        tree("Firmware/Manifests/restore/" + VARIANT, restore)
        for key in sorted(components):
            if key in SKIPPED or key.startswith("Cryptex"):
                continue
            path = components[key]["Info"]["Path"]
            add(path, "Preboot", restore + "/" + path,
                path.split("/")[-1] if path.startswith("kernelcache.") else None)
    except ValueError:
        return None
    selected = {c["member"] for c in copies} | {recovery}
    links = {}
    for n in sorted(selected):
        if files[n][1] == "link":
            if not n.startswith(BOOT + "/") or any(s.startswith(n + "/") for s in selected):
                return None
            target = files[n][0].decode()
            if not safe(target):
                return None
            links[n] = target
    for n in links:
        target, visited = n, set()
        while True:
            parts = target.split("/")
            for count in range(1, len(parts) + 1):
                prefix = "/".join(parts[:count])
                if prefix in links:
                    if prefix in visited or len(visited) >= 40:
                        return None
                    visited.add(prefix)
                    target = "/".join(parts[:count - 1] + links[prefix].split("/") + parts[count:])
                    break
            else:
                break
        if target not in selected and not any(s.startswith(target + "/") for s in selected):
            return None
    return {"restorePath": restore, "recovery": recovery, "copies": copies, "links": links}


def case(name, change):
    m = base()
    change(m)
    return name, m


def manifest_with(**replace):
    comps = dict(COMPONENTS, **replace)
    return plistlib.dumps({"BuildIdentities": [identity(BOARD, components=comps)]})


cases = [
    case("ok", lambda m: None),
    case("ok-restore-path", lambda m: m.update({"usr/standalone/bootcaches.plist": (
        plistlib.dumps({"bless2": {"RestoreBundlePath": "./System/Restore"}}), "file", True)})),
    case("update-archive", lambda m: m.update(
        {"AssetData/boot/BuildManifest.plist": (b"<plist/>", "file", False)})),
    case("other-board", lambda m: m.update({"BuildManifest.plist": (plistlib.dumps(
        {"BuildIdentities": [identity(0x24, components=COMPONENTS)]}), "file", True)})),
    case("update-identity-only", lambda m: m.update({"BuildManifest.plist": (plistlib.dumps(
        {"BuildIdentities": [identity(BOARD, variant="macOS Customer Software Update",
                                      behavior="Update", components=COMPONENTS)]}),
        "file", True)})),
    case("variant-only-differs", lambda m: m.update({"BuildManifest.plist": (plistlib.dumps(
        {"BuildIdentities": [identity(BOARD, variant="macOS Customer Software Update",
                                      components=COMPONENTS)]}), "file", True)})),
    case("behavior-only-differs", lambda m: m.update({"BuildManifest.plist": (plistlib.dumps(
        {"BuildIdentities": [identity(BOARD, behavior="Update", components=COMPONENTS)]}),
        "file", True)})),
    # A combining mark after "0x": no hexadecimal board ID, whether judged by bytes or
    # Characters.
    case("board-combining", lambda m: m.update({"BuildManifest.plist": (plistlib.dumps(
        {"BuildIdentities": [dict(identity(BOARD, components=COMPONENTS),
                                  ApBoardID="0x\u0301" + hex(BOARD)[2:])]}), "file", True)})),
    # A component that starts with a combining mark hides its '/' from Character code
    # ("kernelcache.d/\u0301b" is one Character component): refused, as the main
    # installer's safeRelative refuses it (#203).
    case("kernelcache-leaf", lambda m: m.update({
        "BuildManifest.plist": (manifest_with(KernelCache="kernelcache.d/\u0301b"), "file", True),
        "kernelcache.d/\u0301b": (b"kernel" * 10, "file", False)})),
    case("other-version", lambda m: m.update({"SystemVersion.plist": (plistlib.dumps(
        {"ProductVersion": "26.6.1", "ProductUserVisibleVersion": "26.6.1"}), "file", True)})),
    case("restore-path-climbs", lambda m: m.update({"usr/standalone/bootcaches.plist": (
        plistlib.dumps({"bless2": {"RestoreBundlePath": "./../Restore"}}), "file", True)})),
    case("link-climbs", lambda m: m.update(
        {BOOT + "/Frameworks/Boot.framework/Boot": (b"../../../../x", "link", False)})),
    case("link-to-unselected", lambda m: m.update(
        {BOOT + "/Frameworks/Boot.framework/Boot": (b"Versions/B/Boot", "link", False)})),
    case("link-loop", lambda m: m.update({
        BOOT + "/Frameworks/Boot.framework/Versions/Current": (b"Current2", "link", False),
        BOOT + "/Frameworks/Boot.framework/Versions/Current2": (b"Current", "link", False)})),
    # Points at a selected file, so only the Bootability confinement refuses it.
    case("link-outside-tree", lambda m: m.update(
        {"kernelcache.release.mac14j": (b"PlatformSupport.plist", "link", False)})),
    case("link-with-children", lambda m: m.update(
        {BOOT + "/Frameworks/Boot.framework/Versions/Current/Extra": (b"x", "file", False)})),
    case("no-trust-cache", lambda m: m.pop(
        "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache")),
    case("empty-bootability", lambda m: [m.pop(n) for n in list(m)
                                         if n.startswith(BOOT + "/") and m[n][1] != "dir"]),
    case("empty-component", lambda m: m.update(
        {"Firmware/all_flash/LLB.j314s.RELEASE.im4p": (b"", "file", False)})),
    case("missing-component", lambda m: m.pop("Firmware/all_flash/iBoot.j314s.RELEASE.im4p")),
    case("no-recovery-image", lambda m: m.pop("090-00001-001.dmg")),
    case("path-taken", lambda m: m.update({"Firmware/Manifests/restore/" + VARIANT +
                                            "/SystemVersion.plist": (b"other", "file", False)})),
    case("component-climbs", lambda m: m.update({"BuildManifest.plist": (
        manifest_with(LLB="../LLB.im4p"), "file", True), "../LLB.im4p": (b"x", "file", False)})),
]
expected = {}
for name, members in cases:
    write(name + ".zip", members)
    result = plan(members)
    expected[name] = result if result is not None else "refuse"
# Archive faults the selection never sees: a name twice (zipfile warns).
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    write("duplicate-name.zip", base(), duplicate="Restore.plist")
expected["duplicate-name"] = "refuse"
# A link whose deflate stream runs past the 64 KiB the main installer allows a link body
# (empty stored blocks, then the target).
link = BOOT + "/Frameworks/Boot.framework/Boot"
padded = b"\x00\x00\x00\xff\xff" * 13200 + raw_deflate(b"Versions/Current/Boot")
assert zlib.decompress(padded, -15) == b"Versions/Current/Boot"
write_raw("link-big-compressed.zip", base(), (link, padded))
expected["link-big-compressed"] = "refuse"

# A Bootability member whose name starts with a combining mark: refused by both installers
# since #203 (it was Recovery-only while Recovery judged prefixes on bytes and the main
# installer on Characters). recovery_only stays for cases where they may differ.
recovery_only = {}
for name, members in [case("boot-combining-member", lambda m: m.update(
        {BOOT + "/\u0301x": (b"combining", "file", False)}))]:
    write(name + ".zip", members)
    expected[name] = plan(members) or "refuse"
    assert expected[name] == "refuse"
json.dump({"board": BOARD, "chip": CHIP, "device_class": CLASS, "version": VERSION,
           "build": BUILD, "cases": expected, "recovery_only": recovery_only},
          open("expected.json", "w"), indent=1,
          sort_keys=True)
