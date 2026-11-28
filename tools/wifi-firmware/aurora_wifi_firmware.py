#!/usr/bin/python3 -I
# SPDX-License-Identifier: MIT
"""Keep an installed system's Wi-Fi and Bluetooth firmware on its stub firmware's release.

The radio firmware is per-model, per-version data, so it comes from one
source only: Apple's restore image (IPSW) of the macOS version this Mac's
stub firmware runs (the boot chain reports it as
/chosen/asahi,os-fw-version), for this Mac's board, read by HTTP ranges
(asahi_firmware.ipsw). Never from an installed macOS: a macOS install the
user updated, or none at all, changes nothing here. A Linux install keeps
the set its installer took; this tool converts the restore image's radio
firmware with this repository's asahi_firmware, and when the result
differs from the ESP's package it puts it in:

  Broadcom Wi-Fi       /usr/share/firmware/wifi -> brcm/brcmfmac*
  Broadcom Bluetooth   /usr/share/firmware/bluetooth -> brcm/brcmbt*
  MediaTek MT7932      AppleSunriseWLAN's IZUBA files and
                       /usr/share/firmware/bluetooth/MT7932* -> mediatek/...

  asahi/all_firmware.tar.gz  firmware/wifi/ and firmware/bluetooth/ become
                             the macOS trees (Broadcom), so a later rebuild
                             (asahi-fwupdate) gives the same set
  vendorfw/                  the converted files replace the old set; every
                             other file stays, by path, hash and mode

Both are backed up to /var/lib/aurora-rollback/ first. The new firmware is
used from the next boot; nothing is reloaded at runtime. The boot after a
change checks that the drivers came up with it and puts the previous files
back when they did not.

    aurora-wifi-firmware status
    aurora-wifi-firmware check           dry run: what update would do
    aurora-wifi-firmware update          (the boot service runs `boot`)
    aurora-wifi-firmware boot            verify a pending change, then update
    aurora-wifi-firmware revert          put the files from before the last change back

Exit codes: 0 done or nothing to do, 1 refused (nothing changed), 2 not now,
3 internal error.
"""
import argparse, contextlib, ctypes, errno, fcntl, gzip, hashlib, io, json, logging, os, pathlib, \
    plistlib, re, shutil, socket, struct, subprocess, sys, tarfile, tempfile, time, zlib

HERE = pathlib.Path(__file__).resolve().parent
for cand in (HERE, HERE.parents[1]):
    if (cand / "asahi_firmware" / "wifi.py").is_file():
        if str(cand) not in sys.path:
            sys.path.insert(0, str(cand))
        break
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from asahi_firmware import apfs_ro, centauri, ipsw, mt7932, remotezip  # noqa: E402
from asahi_firmware.bluetooth import BluetoothFWCollection  # noqa: E402
from asahi_firmware.core import FWFile, FWPackage  # noqa: E402
from asahi_firmware.wifi import WiFiFWCollection  # noqa: E402

log = logging.getLogger("aurora-wifi-firmware")

FIRMWARE = "usr/share/firmware"
WIFI = FIRMWARE + "/wifi"
BLUETOOTH = FIRMWARE + "/bluetooth"
SYSTEM_VERSION = "System/Library/CoreServices/SystemVersion.plist"
RAW_PREFIX = "firmware/wifi/"
RAW_BT_PREFIX = "firmware/bluetooth/"
PKG_PREFIX = "brcm/brcmfmac"
BT_PREFIX = "brcm/brcmbt"
DT = pathlib.Path("/proc/device-tree")
DT_ESP = "chosen/asahi,efi-system-partition"
SYS = pathlib.Path("/sys")
STATE_DIR = pathlib.Path("/var/lib/aurora-wifi-firmware")
BACKUP_ROOT = pathlib.Path("/var/lib/aurora-rollback")
BACKUP_PREFIX = "wifi-firmware-"
KEEP_BACKUPS = 2
MOUNTPOINT = "/run/aurora-wifi-firmware-esp"
# The ESP this tool mounts itself is readable by root only while mounted
# (vfat has no permissions of its own: they come from these options).
ESP_MOUNT_OPTIONS = "dmask=0077,fmask=0177,nodev,nosuid,noexec"
STAGE_BUDGET = 512 << 20
# How long the boot after a change waits for each required radio probe.
# The wait ends as soon as every required probe is up or a driver reports
# a failure; the limit only decides when a radio that never reported
# counts as down. Wi-Fi association (link:) can depend on NetworkManager
# reaching a known network, which is the slowest of the probes.
VERIFY_WAIT = 150
# brcmfmac's own words for a firmware that did not come up.
FAILED = ("Dongle setup failed", "brcmf_fw_crashed", "firmware: failed to load brcm/brcmfmac",
          "brcmf_pcie_download_fw_nvram: FW failed to initialize", "brcmf_pcie_setup: Dongle setup")
UP = re.compile(r"brcmf_c_preinit_dcmds: Firmware: (\S+) wl0: (.*?) version (\S+)")


class Refused(Exception):
    """A check failed; nothing was changed."""


class NoSpace(Refused):
    """The ESP lacks the free space a change needs; nothing was changed."""

    def __init__(self, need):
        super().__init__(f"not enough free space on the ESP: {need >> 20} MiB needed")
        self.need = need


class Transient(Refused):
    """A copy or the swap failed in a way the next try need not repeat (an
    I/O error, a copy that read back wrong, a .old in the way). A boot does
    not remember these: the next boot tries again."""


class NotNow(Exception):
    """Try again later; nothing was changed."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- this Mac

def dt_string(rel, dt=DT):
    try:
        return (dt / rel).read_bytes().split(b"\0", 1)[0].decode("ascii").strip() or None
    except (OSError, UnicodeDecodeError):
        return None


def wifi_board(dt=DT):
    """The Broadcom board aura passes Linux (brcm,board-type "apple,<board>"),
    or None on a Mac without a Broadcom Wi-Fi radio."""
    found = set()
    for root, dirs, files in os.walk(dt):
        if "brcm,board-type" in files:
            value = pathlib.Path(root, "brcm,board-type").read_bytes().split(b"\0", 1)[0]
            m = re.fullmatch(rb"apple,([a-z][a-z0-9]{0,31})", value)
            if m:
                found.add(m[1].decode())
    if len(found) > 1:
        raise Refused(f"the device tree names more than one Wi-Fi board: {sorted(found)}")
    return found.pop() if found else None


def mac_board(dt=DT):
    """This Mac's board (j413) from the device tree's first compatible
    ("apple,j413"), the name restore images list it under."""
    try:
        first = (dt / "compatible").read_bytes().split(b"\0", 1)[0]
    except OSError:
        return None
    m = re.fullmatch(rb"apple,([a-z][a-z0-9]{0,31})", first)
    return m[1].decode() if m else None


def has_n1(dt=DT):
    """Whether the device tree describes an Apple N1 (Centauri) radio: a
    node with apple,centauri-platform-id, a *-centauri-control compatible or
    an N1 firmware-name."""
    for root, dirs, files in os.walk(dt):
        if "apple,centauri-platform-id" in files:
            return True
        for name in ("compatible", "firmware-name"):
            if name not in files:
                continue
            try:
                values = pathlib.Path(root, name).read_bytes().split(b"\0")
            except OSError:
                continue
            for v in values:
                if v.endswith(b"-centauri-control") or centauri.owned(v.decode("ascii", "replace")):
                    return True
    return False


def mac_chip(dt=DT):
    """This Mac's SoC (0x6050) from the device tree's compatible
    ("apple,t6050"), or None."""
    try:
        values = (dt / "compatible").read_bytes().split(b"\0")
    except OSError:
        return None
    for v in values:
        m = re.fullmatch(rb"apple,t([0-9]{4})", v)
        if m:
            return int(m[1], 16)
    return None


def os_fw_version(dt=DT):
    """The macOS version of this Mac's stub (OS) firmware, as the boot chain
    reports it (/chosen/asahi,os-fw-version, e.g. 26.6.2)."""
    v = dt_string("chosen/asahi,os-fw-version", dt)
    return v if v and re.fullmatch(r"\d+(\.\d+){1,2}", v) else None


# ---------------------------------------------------------------- the macOS side

class MacOS:
    """The radio firmware's source: one restore image's System volume."""

    def __init__(self, device, volume, build, version, board=None, url=None):
        self.device, self.volume, self.build, self.version = device, volume, build, version
        self.board, self.url = board, url

    def describe(self):
        return f"macOS {self.version} ({self.build}) restore image {self.device}"


def restore_image(board=None, version=None, open_system=ipsw.open_system, images=ipsw.images_for_version):
    """[MacOS] of the restore image of this Mac's stub firmware version for
    its board. NotNow when the image cannot be reached; Refused when no
    known image fits."""
    board = board or mac_board()
    version = version or os_fw_version()
    if not board or not version:
        raise Refused("the device tree names no board or stub firmware version "
                      "(compatible, /chosen/asahi,os-fw-version)")
    try:
        vol, _, build, url = open_system(board, images(version), version)
    except (ipsw.IpswUnavailable, ipsw.aea_ro.AeaUnavailable, OSError) as e:
        raise NotNow(f"the macOS {version} restore image cannot be read now: {e}")
    except (ipsw.IpswError, apfs_ro.ApfsError) as e:
        raise Refused(f"no macOS {version} restore image for {board}: {e}")
    return [MacOS(url.rsplit("/", 1)[-1], vol, build, version, board, url)]


class Staged:
    """A file copied out of the macOS volume: its path, size and hash, so the
    tree is not held in memory."""

    def __init__(self, path, size, sha):
        self.path, self.size, self.sha = path, size, sha


def stage_tree(vol, path, dest, want=None):
    """Copies the volume's directory path to dest, links kept as links (the
    collections resolve them as macOS does); with want, only the entries
    want(rel) accepts. Returns {rel: Staged | ('link', target)}."""
    tree = {}
    total = 0

    def rec(ino, kind, rel):
        nonlocal total
        full = os.path.join(dest, rel) if rel else dest
        if kind == 4:
            os.makedirs(full, mode=0o700, exist_ok=True)
            for name, (cino, ck) in sorted(vol.children(ino).items()):
                if "/" in name or name in (".", "..") or "\0" in name:
                    continue
                rec(cino, ck, f"{rel}/{name}" if rel else name)
            return
        if want is not None and not want(rel):
            return
        if kind == 8:
            data = vol.read_file(ino)
            total += len(data)
            if total > STAGE_BUDGET:
                raise Refused(f"/{path} on the macOS volume is over the size budget")
            fd = os.open(full, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            tree[rel] = Staged(full, len(data), sha256(data))
        elif kind == 10:
            target = vol.readlink(ino)
            # Only links inside the tree, as the installer keeps them.
            if target.startswith("/") or ".." in target.split("/"):
                log.info(f"{rel}: link out of the tree ({target}), skipped")
                return
            os.symlink(target, full)
            tree[rel] = ("link", target)

    try:
        ino, kind = vol.resolve(path)
    except apfs_ro.ApfsError as e:
        raise Refused(f"/{path} is not on the macOS volume ({e})")
    if kind != 4:
        raise Refused(f"/{path} on the macOS volume is not a directory")
    rec(ino, kind, "")
    return tree


def stage_wifi(vol, dest):
    """The volume's Wi-Fi firmware tree (stage_tree of /usr/share/firmware/wifi)."""
    return stage_tree(vol, WIFI, dest)


def converted(raw_dir):
    """{vendorfw name: FWFile} of a raw Wi-Fi tree, as asahi_firmware.update
    packages it."""
    return dict(sorted(WiFiFWCollection(str(raw_dir)).files()))


# ---------------------------------------------------------------- the ESP side

def parse_manifest(text):
    """vendorfw manifest.txt -> {name: sha256}, LINK entries resolved."""
    out, links = {}, {}
    for n, line in enumerate(text.splitlines(), 1):
        parts = line.split()
        if len(parts) == 4 and parts[0] == "FILE" and parts[2] == "SHA256":
            out[parts[1]] = parts[3]
        elif len(parts) == 3 and parts[0] == "LINK":
            links[parts[1]] = parts[2]
        elif line.strip():
            raise Refused(f"unreadable vendorfw manifest line {n}: {line!r}")
    for name, target in links.items():
        if target not in out:
            raise Refused(f"vendorfw manifest: {name} links to unknown {target}")
        out[name] = out[target]
    return out


def wifi_in(manifest):
    return {k: v for k, v in manifest.items() if k.startswith(PKG_PREFIX)}


def radio_in(manifest):
    """The entries of every radio firmware set this tool follows."""
    return {k: v for k, v in manifest.items()
            if k.startswith(PKG_PREFIX) or k.startswith(BT_PREFIX) or mt7932.owned(k)}


def esp_wifi_digest(esp):
    """One hash over the ESP package's radio firmware entries (names and hashes)."""
    with contextlib.suppress(OSError, Refused):
        current = radio_in(parse_manifest((pathlib.Path(esp) / "vendorfw" / "manifest.txt")
                                          .read_text("ascii")))
        return sha256("".join(f"{k} {v}\n" for k, v in sorted(current.items())).encode())
    return None


def missing_for_board(files, board, chips):
    """Names this board needs, per chip revision it has today: firmware,
    regulatory data and at least one NVRAM file."""
    missing = []
    for chip in sorted(chips):
        stem = f"{PKG_PREFIX}{chip}-pcie.apple,{board}"
        for ext in (".bin", ".clm_blob"):
            if stem + ext not in files:
                missing.append(stem + ext)
        if not any(k.startswith(stem + "-") and k.endswith(".txt") or k == stem + ".txt"
                   for k in files):
            missing.append(stem + "-*.txt")
    return missing


def board_chips(files, board):
    """Chip revisions ('4387c2') that carry this board's firmware."""
    out = set()
    for k in files:
        m = re.fullmatch(re.escape(PKG_PREFIX) + r"([0-9]{4}[a-z][0-9])-pcie\.apple," +
                         re.escape(board) + r"\.bin", k)
        if m:
            out.add(m[1])
    return out


def bt_board_names(files, board):
    """This board's Broadcom Bluetooth names ('brcm/brcmbt4387c2-apple,<board>-u.bin')."""
    pat = re.compile(re.escape(BT_PREFIX) + r"[0-9]{4}[a-z][0-9]-apple," + re.escape(board)
                     + r"(?:-[a-z])?\.(?:bin|ptb)")
    return {k for k in files if pat.fullmatch(k)}


# ---------------------------------------------------------------- radio parts
#
# A part is one radio's firmware set: where it is on the macOS volume, how it
# is converted, which vendorfw names it replaces, what this Mac needs from it,
# and how the boot after a change tells that the driver came up with it.

class Part:
    key = ""
    label = ""
    sources = ()        # (macOS directory, all_firmware prefix or None, want or None)
    probes = ()         # driver checks for the boot after a change
    always = ()         # probes that must come up even if they were down before

    def owns(self, name):
        raise NotImplementedError

    def unavailable(self, macos):
        """Why macos cannot supply this part (shown to the user), or None."""
        gone = [src for src, _, _ in self.sources if not has_dir(macos.volume, src)]
        return f"no /{gone[0]}" if gone else None

    def stage(self, macos, src, dest, want):
        """Copies source src to dest; {rel: Staged | ('link', target)}."""
        return stage_tree(macos.volume, src, dest, want)

    def convert(self, staged):
        """staged: {macOS directory: local copy} -> {vendorfw name: FWFile}."""
        raise NotImplementedError

    def missing(self, new, current):
        return []

    def expect(self, new):
        """{name: sha} the unpacked firmware must match after the change."""
        return {}

    @staticmethod
    def failures():
        """(driver name or None, words): kernel log lines meaning it did not come up."""
        return ()


class BroadcomWiFi(Part):
    key, label = "wifi", "Broadcom Wi-Fi"
    sources = ((WIFI, RAW_PREFIX, None),)
    probes = ("brcmfmac", "link:brcmfmac")
    always = ("brcmfmac",)

    def __init__(self, board, chips):
        self.board, self.chips = board, chips

    def owns(self, name):
        return name.startswith(PKG_PREFIX)

    def convert(self, staged):
        return converted(staged[WIFI])

    def missing(self, new, current):
        return missing_for_board(new, self.board, self.chips)

    def stem(self):
        return f"{PKG_PREFIX}{sorted(self.chips)[0]}-pcie.apple,{self.board}.bin"

    def expect(self, new):
        return {self.stem(): new[self.stem()].sha} if self.stem() in new else {}

    @staticmethod
    def failures():
        return tuple((None, f) for f in FAILED)


class BroadcomBluetooth(Part):
    key, label = "bluetooth", "Broadcom Bluetooth"
    sources = ((BLUETOOTH, RAW_BT_PREFIX, None),)
    probes = ("hci:hci_bcm4377",)

    def __init__(self, board, names):
        self.board, self.names = board, names

    def owns(self, name):
        return name.startswith(BT_PREFIX)

    def convert(self, staged):
        return dict(sorted(BluetoothFWCollection(str(staged[BLUETOOTH])).files()))

    def missing(self, new, current):
        # Every name this board loads today (firmware and PTB, per vendor).
        return sorted(n for n in self.names if n not in new)

    def expect(self, new):
        return {n: new[n].sha for n in sorted(self.names) if n.endswith(".bin") and n in new}

    @staticmethod
    def failures():
        return (("hci_bcm4377", "Unable to load firmware"), ("hci_bcm4377", "failed to load PTB"),
                ("hci_bcm4377", "Failed to load firmware"))


class MediaTekMT7932(Part):
    key, label = "mt7932", "MediaTek MT7932 Wi-Fi and Bluetooth"
    sources = ((mt7932.WIFI_DIR, None, lambda rel: rel in mt7932.WIFI_SOURCES),
               (mt7932.BT_DIR, None, lambda rel: rel.startswith("MT7932")))
    probes = ("net:mt7932-fullmac", "link:mt7932-fullmac", "hci:mt7932_bt_pcie")

    def owns(self, name):
        return mt7932.owned(name)

    def convert(self, staged):
        try:
            return dict(mt7932.MT7932FWCollection(str(staged[mt7932.WIFI_DIR]),
                                                  str(staged[mt7932.BT_DIR])).files())
        except mt7932.Invalid as e:
            raise Refused(f"the macOS MT7932 firmware does not convert: {e}")

    def missing(self, new, current):
        # Every Wi-Fi name the ESP has today, and a Bluetooth image of each
        # kind it has today.
        out = [n for n in (mt7932.OUT_PATCH, mt7932.OUT_RAM, mt7932.OUT_PPR, mt7932.OUT_CONFIG)
               if n in current and n not in new]
        for kind in ("B0", "B1"):
            if any(re.fullmatch(rf"mediatek/MT7932{kind}_OS_TypeB_.*\.bin", k) for k in current) \
                    and not any(re.fullmatch(rf"mediatek/MT7932{kind}_OS_TypeB_.*\.bin", k)
                                for k in new):
                out.append(f"mediatek/MT7932{kind}_OS_TypeB_*.bin")
        return out

    def expect(self, new):
        return {n: new[n].sha for n in (mt7932.OUT_RAM, mt7932.ALIAS_B1) if n in new}

    @staticmethod
    def failures():
        return (("mt7932-fullmac", "FIRMWARE_GATE_FAILED"),
                ("mt7932-fullmac", "local input mediatek/mt7932/IZUBA"),
                ("mt7932-fullmac", "local input mediatek/mt7932/ppr.bin"),
                ("mt7932-fullmac", "local input mediatek/mt7932/config-original.bin"),
                ("mt7932_bt_pcie", "Direct firmware load for mediatek/"))


class CentauriN1(Part):
    """The Apple N1's one FTAB image for Wi-Fi and Bluetooth (M5 and later).
    Its inputs are restore image members, not System volume files: the image
    the build identity names for this board (macOS Customer variant) and the
    board's ticket beside it, as the native installer takes them from the
    stub's restore files. all_firmware keeps them under centauri/<model>/, so
    a rebuild (asahi-fwupdate) gives the same file."""
    key, label = "centauri", "Apple N1 Wi-Fi and Bluetooth"
    VARIANT = "macOS Customer"
    BEHAVIOR = "Erase"
    SOURCE = "centauri"
    PREFIX = "centauri/"
    # The N1's Wi-Fi interface, from the T8142/T8152 or the T6050 driver. It
    # must come up after a change even where it was down before: an install
    # without N1 firmware never had it.
    NET = "net:apple_centauri|apple_centauri_t6050"
    probes = (NET,)
    always = (NET,)

    def __init__(self, model, open_zip=None, chip=None):
        self.model, self.chip = model, chip
        self.sources = ((self.SOURCE, self.PREFIX, None),)
        self.open_zip = open_zip or remotezip.RemoteZip
        self._inputs = None

    def owns(self, name):
        return centauri.owned(name)

    def inputs(self, macos):
        """(image member, ticket member) of macos's restore image for this
        board, or a reason string."""
        if self._inputs is not None:
            return self._inputs
        if not macos.url:
            return "no restore image address"
        try:
            z = self.open_zip(macos.url)
            bm = ipsw._manifest(z)
        except (remotezip.RemoteZipUnavailable, OSError) as e:
            raise NotNow(f"the macOS {macos.build} restore image cannot be read now: {e}")
        except (ipsw.IpswError, remotezip.RemoteZipError, ValueError) as e:
            raise Refused(f"the macOS {macos.build} restore image does not read: {e}")
        if bm.get("ProductBuildVersion") != macos.build:
            raise Refused(f"the restore image is {bm.get('ProductBuildVersion')}, not {macos.build}")
        # The identity the native installer's stub plan selects
        # (NativeStubFilePlan): this board, its chip, an Erase restore of the
        # macOS Customer variant. The device tree carries no board ID, so the
        # board is its device class, which must name one board ID throughout
        # the manifest, and exactly one identity may match.
        device = f"{self.model}ap"
        d = lambda v: v if isinstance(v, dict) else {}  # noqa: E731
        identities = bm.get("BuildIdentities")
        identities = [bi for bi in identities if isinstance(bi, dict)] \
            if isinstance(identities, list) else []
        same = [bi for bi in identities if d(bi.get("Info")).get("DeviceClass") == device]
        valid = lambda b: isinstance(b, str) and re.fullmatch(r"0x[0-9a-fA-F]{1,8}", b)  # noqa: E731
        if not all(valid(bi.get("ApBoardID")) for bi in same):
            raise Refused(f"the restore image names {device} without a valid board ID")
        if len({int(bi["ApBoardID"], 16) for bi in same}) > 1:
            raise Refused(f"the restore image names {device} with more than one board ID")
        chosen = [bi for bi in same if d(bi.get("Info")).get("Variant") == self.VARIANT
                  and d(bi.get("Info")).get("RestoreBehavior") == self.BEHAVIOR]
        if not chosen:
            self._inputs = "no N1 image for this board"
            return self._inputs
        if len(chosen) > 1:
            raise Refused(f"the restore image has {len(chosen)} {self.VARIANT} identities for {device}")
        identity = chosen[0]
        chip = self.chip if self.chip is not None else mac_chip()
        got = identity.get("ApChipID")
        got_chip = int(got, 16) if valid(got) else None
        if chip is None or got_chip != chip:
            raise Refused(f"the restore image's {device} identity is chip {got!r}, "
                          f"not this Mac's ({'unknown' if chip is None else hex(chip)})")
        paths = set()
        for comp, entry in d(identity.get("Manifest")).items():
            path = d(d(entry).get("Info")).get("Path")
            if isinstance(comp, str) and comp.startswith("Wireless1,") \
                    and isinstance(path, str) and path:
                paths.add(path)
        if not paths:
            self._inputs = "no N1 image for this board"
            return self._inputs
        if len(paths) > 1:
            raise Refused(f"the build identity names {len(paths)} different N1 images")
        ticket = (f"Firmware/Manifests/restore/{self.VARIANT}/centauri/"
                  + centauri.ticket_name(self.model))
        image = paths.pop()
        for member in (image, ticket):
            if member not in z.members:
                raise Refused(f"the restore image has no {member}")
        self._inputs = (z, image, ticket)
        return self._inputs

    def unavailable(self, macos):
        got = self.inputs(macos)
        return got if isinstance(got, str) else None

    def stage(self, macos, src, dest, want):
        z, image, ticket = self.inputs(macos)
        directory = pathlib.Path(dest) / self.model
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        tree = {}
        for member, name, budget in ((image, centauri.IMAGE, centauri.BUDGET),
                                     (ticket, centauri.ticket_name(self.model),
                                      centauri.TICKET_BUDGET)):
            m = z.members[member]
            if m.usize > budget:
                raise Refused(f"{member} is over its size budget")
            data = m.read(budget)
            path = directory / name
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            tree[f"{self.model}/{name}"] = Staged(str(path), len(data), sha256(data))
        return tree

    def convert(self, staged):
        got = dict(centauri.CentauriFWCollection(str(staged[self.SOURCE])).files())
        name = centauri.firmware_name(self.model)
        if name not in got:
            raise Refused(f"the restore image's N1 files do not convert to {name}")
        return {name: got[name]}

    def missing(self, new, current):
        name = centauri.firmware_name(self.model)
        return [] if name in new else [name]

    def expect(self, new):
        return {n: new[n].sha for n in new if centauri.owned(n)}

    @staticmethod
    def failures():
        return ((None, "Direct firmware load for apple/centauri/"),
                (None, "required firmware apple/centauri/"))


def radio_parts(current, board, model=None, n1=None):
    """The parts this Mac's ESP package carries today, from its vendorfw
    names and the device tree's Broadcom board; the N1 also when the device
    tree describes one (an install from before the installer wrote its
    firmware has none on the ESP)."""
    parts = []
    if board:
        chips = board_chips(current, board)
        if not chips:
            raise Refused(f"the ESP's vendorfw has no Wi-Fi firmware for this Mac's board "
                          f"({board}); reinstall the firmware with the installer")
        parts.append(BroadcomWiFi(board, chips))
        bt = bt_board_names(current, board)
        if bt:
            parts.append(BroadcomBluetooth(board, bt))
    if mt7932.OUT_RAM in current:
        parts.append(MediaTekMT7932())
    if n1 is None:
        n1 = any(centauri.owned(k) for k in current) or has_n1()
    if n1:
        model = model or mac_board()
        if model and centauri.MODEL.fullmatch(model):
            parts.append(CentauriN1(model))
    return parts


def owned_in(manifest, parts):
    return {k: v for k, v in manifest.items() if any(p.owns(k) for p in parts)}



def others_can_read(options):
    """Whether a vfat mount's options (findmnt OPTIONS) let users other than
    root read its files: vfat takes file permissions from fmask (or umask)."""
    for opt in options.split(","):
        name, _, value = opt.partition("=")
        if name in ("fmask", "umask") and value:
            try:
                return not int(value, 8) & 0o004
            except ValueError:
                return False
    return False


def find_esp(run=subprocess.run, dt=DT, root="/"):
    """(path of the system ESP, the mountpoint when this tool mounted it).
    The device tree's ESP PARTUUID unless a .builder marker says otherwise,
    else /boot/efi or /boot holding m1n1, as mount_sys_esp in asahi-scripts."""
    r = pathlib.Path(root)
    uuid = dt_string(DT_ESP, dt) or ""
    builder = (r / "boot/efi/.builder").exists() or (r / "boot/.builder").exists()
    if uuid and not builder:
        dev = r / "dev/disk/by-partuuid" / uuid.lower()
        device = os.path.realpath(dev) if dev.exists() else None
        if device is None:
            p = run(["blkid", "-o", "device", "-t", f"PARTUUID={uuid}"], capture_output=True)
            out = p.stdout.decode().split() if p.returncode == 0 else []
            device = out[0] if out else None
        if device is None:
            raise Refused(f"the system ESP (PARTUUID {uuid}) was not found")
        p = run(["findmnt", "-n", "-r", "-o", "TARGET,OPTIONS", "--source", device],
                capture_output=True)
        lines = p.stdout.decode().splitlines() if p.returncode == 0 else []
        mounts = [ln.split(" ", 1) for ln in lines if ln.strip()]
        rw = [m for m in mounts if len(m) == 2 and "rw" in m[1].split(",")]
        if rw:
            if others_can_read(rw[0][1]):
                log.warning(f"The system ESP is mounted at {rw[0][0]} with files every user "
                            "can read; the firmware package written there is readable too")
            return pathlib.Path(rw[0][0]), None
        if mounts:
            raise NotNow(f"the system ESP {device} is mounted read only at {mounts[0][0]}")
        os.makedirs(MOUNTPOINT, mode=0o700, exist_ok=True)
        p = run(["mount", "-t", "vfat", "-o", ESP_MOUNT_OPTIONS, device, MOUNTPOINT],
                capture_output=True)
        if p.returncode != 0:
            raise NotNow(f"could not mount the system ESP {device}: {p.stderr.decode().strip()}")
        return pathlib.Path(MOUNTPOINT), MOUNTPOINT
    for cand in ("boot/efi", "boot"):
        if (r / cand / "m1n1").exists():
            log.warning(f"System ESP not identified in the device tree, using /{cand}")
            return r / cand, None
    raise Refused("the system ESP was not found: no asahi,efi-system-partition in the device "
                  "tree and no m1n1 under /boot/efi or /boot")


@contextlib.contextmanager
def system_esp(esp=None):
    if esp is not None:
        yield pathlib.Path(esp)
        return
    path, mounted = find_esp()
    try:
        yield path
    finally:
        if mounted:
            p = subprocess.run(["umount", mounted], capture_output=True)
            if p.returncode != 0:
                log.warning(f"could not unmount the system ESP at {mounted}: "
                            f"{p.stderr.decode().strip()}")


# ---------------------------------------------------------------- rebuild

def tar_entries(tree, prefix=RAW_PREFIX):
    """(TarInfo, file or None) for a raw firmware tree ({rel: bytes | Staged |
    ('link', target)}) under prefix (firmware/wifi/), directories first, as
    the installer writes them. Staged files are opened one at a time."""
    dirs = set()
    for rel in tree:
        parts = rel.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))

    def info(name, kind, mode):
        ti = tarfile.TarInfo(name)
        ti.type, ti.mode, ti.uname, ti.gname, ti.mtime = kind, mode, "root", "wheel", 0
        return ti
    yield info(prefix.rstrip("/"), tarfile.DIRTYPE, 0o755), None
    for d in sorted(dirs):
        yield info(prefix + d, tarfile.DIRTYPE, 0o755), None
    for rel in sorted(tree):
        v = tree[rel]
        if isinstance(v, tuple):
            ti = info(prefix + rel, tarfile.SYMTYPE, 0o755)
            ti.linkname = v[1]
            yield ti, None
        elif isinstance(v, Staged):
            ti = info(prefix + rel, tarfile.REGTYPE, 0o644)
            ti.size = v.size
            with open(v.path, "rb") as f:
                yield ti, f
        else:
            ti = info(prefix + rel, tarfile.REGTYPE, 0o644)
            ti.size = len(v)
            yield ti, io.BytesIO(v)


def rebuild_all_firmware(old, new, trees):
    """old all_firmware with each prefix's part replaced by its tree
    (trees: {prefix: tree}, or one tree for firmware/wifi/)."""
    if not isinstance(trees, dict) or not all(
            isinstance(k, str) and k.endswith("/")
            and (k.startswith("firmware/") or k == CentauriN1.PREFIX) for k in trees):
        trees = {RAW_PREFIX: trees}
    with tarfile.open(old, mode="r:gz") as src, tarfile.open(new, mode="w:gz") as dst:
        wrote = set()
        for m in src:
            name = m.name[2:] if m.name.startswith("./") else m.name
            prefix = next((p for p in trees
                           if name.rstrip("/") + "/" == p or name.startswith(p)), None)
            if prefix is not None:
                if prefix not in wrote:
                    for ti, fd in tar_entries(trees[prefix], prefix):
                        dst.addfile(ti, fd)
                    wrote.add(prefix)
                continue
            dst.addfile(m, src.extractfile(m) if m.isfile() else None)
        for prefix in trees:
            if prefix not in wrote:
                for ti, fd in tar_entries(trees[prefix], prefix):
                    dst.addfile(ti, fd)


def link_target(tar, m):
    """The regular file member a hard link member m names, or None.

    The target is the last member of that name before m, as tar resolves it.
    A chain of hard links is followed; a target that is missing, that is not
    a regular file (a directory, a device, a symbolic link) or that loops
    gives None."""
    seen = set()
    while m.islnk():
        want = os.path.normpath(m.linkname)
        if want in seen:
            return None
        seen.add(want)
        target = None
        for c in tar.members:
            if c is m:
                break
            if os.path.normpath(c.name) == want:
                target = c
        if target is None:
            return None
        m = target
    return m if m.isfile() else None


def member_data(tar, m):
    """The data of a file member of tar, or None. A hard link member (the
    installer writes the copies of a file as hard links) reads as its target,
    as tar extracts it; one whose target is not a regular file in the archive
    (missing, a directory or symbolic link, a loop) reads as None, a file the
    archive lacks."""
    if m.islnk():
        target = link_target(tar, m)
        if target is None:
            log.info(f"{m.name}: hard link to {m.linkname}, which is not a file in the archive")
            return None
        m = target
    if m.isfile():
        f = tar.extractfile(m)
        if f is not None:
            return f.read()
    return None


def raw_tree(all_fw, prefix):
    """{rel: sha256 | 'link:'+target} of all_firmware's prefix part."""
    out = {}
    with tarfile.open(all_fw, mode="r:gz") as tar:
        for m in tar:
            name = m.name[2:] if m.name.startswith("./") else m.name
            if not name.startswith(prefix) or m.isdir():
                continue
            rel = name[len(prefix):]
            if m.issym():
                out[rel] = "link:" + m.linkname
                continue
            data = member_data(tar, m)
            if data is not None:
                out[rel] = sha256(data)
    return out


def raw_extract(all_fw, prefix, dest):
    """Writes all_firmware's prefix part under dest as stage_tree lays out a
    macOS directory: files, and links that stay inside the tree. A hard link
    member is written as a regular copy of its target (member_data)."""
    dest = pathlib.Path(dest)
    dest.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tarfile.open(all_fw, mode="r:gz") as tar:
        for m in tar:
            name = m.name[2:] if m.name.startswith("./") else m.name
            if not name.startswith(prefix) or m.isdir():
                continue
            rel = name[len(prefix):].split("/")
            if any(c in ("", ".", "..") or "\0" in c for c in rel):
                continue
            path = dest.joinpath(*rel)
            if m.issym() and (m.linkname.startswith("/") or ".." in m.linkname.split("/")):
                continue
            data = None if m.issym() else member_data(tar, m)
            if not m.issym() and data is None:
                continue
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            # A later member of the same name wins, as tar extracts it.
            if path.is_symlink() or path.is_file():
                path.unlink()
            if m.issym():
                os.symlink(m.linkname, path)
            else:
                with open(path, "xb") as f:
                    f.write(data)


def raw_converts_to(all_fw, part, new, tmp):
    """Whether all_firmware's raw trees for part convert to new ({name: sha}).

    all_firmware holds the raw trees a later conversion on Linux rebuilds
    vendorfw from, so this is the property that matters, not byte equality
    with the macOS directory: the installer took its trees from the Recovery
    image, which leaves out files no converter reads (the UART and USB
    Bluetooth .hex/.dfu/.msf images, for one).

    A raw tree that does not read or convert (a damaged archive, a member
    the converter chokes on) does not give new either: False, and the
    update rebuilds all_firmware from the macOS tree, which did convert."""
    if not part.sources or not all(prefix for _, prefix, _ in part.sources):
        return True
    staged = {}
    try:
        for n, (src, prefix, _) in enumerate(part.sources):
            staged[src] = pathlib.Path(tmp) / f"raw-{part.key}-{n}"
            raw_extract(all_fw, prefix, staged[src])
    except (OSError, EOFError, tarfile.TarError, zlib.error) as e:
        log.info(f"all_firmware's raw {part.label} trees do not read: {e}")
        return False
    try:
        got = part.convert(staged)
    except Exception as e:
        # The converter took the macOS tree a moment ago, so whatever it
        # raises here is about all_firmware's copy.
        log.info(f"all_firmware's raw {part.label} trees do not convert: {e!r}")
        return False
    return {k: v.sha for k, v in got.items()} == new


def owned_bytes(vendorfw, owns):
    """Bytes of the owned files' data in vendorfw's firmware.tar (links are free)."""
    with tarfile.open(pathlib.Path(vendorfw) / "firmware.tar") as tar:
        return sum(m.size for m in tar.getmembers() if m.isreg() and owns(m.name))


def files_bytes(files):
    """Bytes of files' data as FWPackage stores it (one copy per content)."""
    return sum(len(f.data) for f in {f.sha: f for f in files.values()}.values())


def leftovers(esp):
    """The <path>.new copies an interrupted commit (or a cleanup that failed
    after the swap) left on the ESP. Only commit writes them, and the next
    commit replaces them, so their space is free for the next change."""
    esp = pathlib.Path(esp)
    return [p for p in (esp / "vendorfw.new", esp / "asahi" / "all_firmware.tar.gz.new")
            if os.path.lexists(p)]


def free_space(esp):
    """Free bytes on the ESP, counting the space leftovers hold."""
    st = os.statvfs(esp)
    return st.f_bavail * st.f_frsize + sum(
        tree_size(p) for p in leftovers(esp) if not p.is_symlink())


def require_space(esp, need):
    if free_space(esp) < need:
        raise NoSpace(need)


def raw_wifi(all_fw):
    """{rel: sha256 | 'link:'+target} of all_firmware's firmware/wifi/."""
    return raw_tree(all_fw, RAW_PREFIX)


def tree_digest(tree):
    return {rel: ("link:" + v[1]) if isinstance(v, tuple) else
            v.sha if isinstance(v, Staged) else sha256(v) for rel, v in tree.items()}


def rebuild_vendorfw(old_dir, new_dir, files, owns=None):
    """vendorfw with the names owns() accepts (brcm/brcmfmac* by default)
    replaced by files ({name: FWFile}) and every other file kept with its
    mode, in update_firmware's order (the radios first)."""
    owns = owns or (lambda name: name.startswith(PKG_PREFIX))
    kept = []
    with tarfile.open(pathlib.Path(old_dir) / "firmware.tar") as tar:
        for m in tar.getmembers():
            if m.isdir() or owns(m.name):
                continue
            src = m
            while src.islnk():
                src = tar.getmember(src.linkname)
            kept.append((m.name, FWFile(m.name, tar.extractfile(src).read()), src.mode))
    pkg = FWPackage(str(new_dir))
    pkg.add_files(files.items())
    for name, data, mode in kept:
        pkg.add_file(name, data, mode=mode)
    pkg.close()


def package_extras(vendorfw):
    """Files in vendorfw/ besides the package itself (u-boot/...): {rel: sha}."""
    out = {}
    for parent, _, names in os.walk(vendorfw):
        for n in names:
            full = os.path.join(parent, n)
            rel = os.path.relpath(full, vendorfw)
            if rel not in ("firmware.tar", "firmware.cpio", "manifest.txt"):
                out[rel] = file_sha256(full)
    return out


def tar_modes(path):
    with tarfile.open(path) as tar:
        out = {}
        for m in tar.getmembers():
            src = m
            while src.islnk():
                src = tar.getmember(src.linkname)
            if not m.isdir():
                out[m.name] = src.mode
        return out


def check_package(old_dir, new_dir, files, owns=None):
    """Refuse unless the new package keeps every old file outside the
    replaced set by path, hash and mode and holds exactly the new set."""
    owns = owns or (lambda name: name.startswith(PKG_PREFIX))
    old = parse_manifest((pathlib.Path(old_dir) / "manifest.txt").read_text("ascii"))
    new = parse_manifest((pathlib.Path(new_dir) / "manifest.txt").read_text("ascii"))
    lost = [k for k in sorted(old) if not owns(k) and new.get(k) != old[k]]
    old_m = tar_modes(pathlib.Path(old_dir) / "firmware.tar")
    new_m = tar_modes(pathlib.Path(new_dir) / "firmware.tar")
    lost += [k for k in sorted(old_m) if not owns(k) and k in old and new_m.get(k) != old_m[k]]
    old_x, new_x = package_extras(old_dir), package_extras(new_dir)
    lost += [k for k in sorted(old_x) if new_x.get(k) != old_x[k]]
    if lost:
        raise Refused(f"the rebuilt vendorfw would lose or change {len(lost)} other file(s): "
                      + ", ".join(lost[:6]) + (" ..." if len(lost) > 6 else ""))
    want = {k: v.sha for k, v in files.items()}
    if {k: v for k, v in new.items() if owns(k)} != want:
        raise Refused("the rebuilt vendorfw does not hold exactly the converted set")
    with tarfile.open(pathlib.Path(new_dir) / "firmware.tar") as tar:
        for name, digest in want.items():
            m = tar.getmember(name)
            while m.islnk():
                m = tar.getmember(m.linkname)
            if sha256(tar.extractfile(m).read()) != digest:
                raise Refused(f"firmware.tar disagrees with its manifest: {name}")
    if not (pathlib.Path(new_dir) / "firmware.cpio").is_file():
        raise Refused("the rebuilt vendorfw has no firmware.cpio")


# ---------------------------------------------------------------- commit

AT_FDCWD, RENAME_EXCHANGE = -100, 2


def exchange(a, b):
    """Atomically swap two paths on one filesystem; False when the kernel or
    filesystem cannot (nothing changed)."""
    if not sys.platform.startswith("linux"):
        return False
    try:
        fn = ctypes.CDLL(None, use_errno=True).renameat2
    except (OSError, AttributeError):
        return False
    fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    fn.restype = ctypes.c_int
    if fn(AT_FDCWD, os.fsencode(a), AT_FDCWD, os.fsencode(b), RENAME_EXCHANGE) == 0:
        return True
    e = ctypes.get_errno()
    if e in (errno.EINVAL, errno.ENOSYS, errno.EOPNOTSUPP, errno.ENOTSUP):
        return False
    raise OSError(e, os.strerror(e), str(a))


def swap_in(new, cur, swap=exchange):
    """Put new at cur; the old content ends at new. Returns an undo."""
    if swap(new, cur):
        return lambda: swap(new, cur) or (_ for _ in ()).throw(OSError("could not swap back"))
    old = pathlib.Path(str(cur) + ".old")
    if os.path.lexists(old):
        raise Transient(f"{old} is in the way; move it aside first")
    os.rename(cur, old)
    try:
        os.rename(new, cur)
    except BaseException:
        os.rename(old, cur)
        raise
    os.rename(old, new)

    def undo():
        os.rename(cur, old)
        os.rename(new, cur)
        os.rename(old, new)
    return undo


def fsync_tree(path):
    path = pathlib.Path(path)
    items = [path] if path.is_file() else \
        [pathlib.Path(p) / n for p, _, ns in os.walk(path) for n in ns]
    for f in items:
        fd = os.open(f, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def tree_hashes(path):
    path = pathlib.Path(path)
    if path.is_file():
        return {"": file_sha256(path)}
    return {os.path.relpath(os.path.join(p, n), path): file_sha256(os.path.join(p, n))
            for p, _, ns in os.walk(path) for n in ns}


def copy_verified(src, dst):
    src, dst = pathlib.Path(src), pathlib.Path(dst)
    if src.is_dir():
        # File data only: the ESP (vfat) refuses most metadata changes.
        for parent, _, names in os.walk(src):
            target = dst / os.path.relpath(parent, src)
            target.mkdir(parents=True, exist_ok=False)
            for name in names:
                shutil.copyfile(os.path.join(parent, name), target / name)
    else:
        shutil.copyfile(src, dst)
    fsync_tree(dst)
    if tree_hashes(src) != tree_hashes(dst):
        raise Transient(f"the copy at {dst} does not match {src}")


def remove(path):
    path = pathlib.Path(path)
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def tree_size(path):
    path = pathlib.Path(path)
    if path.is_file():
        return path.stat().st_size
    return sum(os.path.getsize(os.path.join(p, n)) for p, _, ns in os.walk(path) for n in ns)


def commit(esp, pairs, backup, swap=exchange):
    """pairs: [(staged source, ESP path)]. Copies each to <path>.new on the
    ESP, then swaps them in; on any failure the ESP is left as it was."""
    staging = [(src, pathlib.Path(str(cur) + ".new"), cur) for src, cur in pairs]
    undo = []
    try:
        for src, new, _ in staging:
            remove(new)
            copy_verified(src, new)
        os.sync()
        for _, new, cur in staging:
            undo.append(swap_in(new, cur, swap))
    except BaseException as e:
        failed = []
        for u in reversed(undo):
            try:
                u()
            except Exception as ue:
                failed.append(ue)
        if failed:
            raise Transient(f"the swap failed ({e}) and could not be undone ({failed[0]}); "
                            f"restore from {backup}") from e
        for _, new, _ in staging:
            with contextlib.suppress(OSError):
                remove(new)
        raise Transient(f"the swap failed and was undone, the ESP is unchanged: {e}") from e
    for _, new, _ in staging:
        try:
            remove(new)
        except OSError as e:
            log.warning(f"Could not remove the old copy at {new}: {e}")
    os.sync()


# ---------------------------------------------------------------- state

def read_state(state_dir=None):
    state_dir = state_dir or STATE_DIR
    with contextlib.suppress(OSError, ValueError):
        return json.loads((pathlib.Path(state_dir) / "state.json").read_text())
    return {}


def write_state(state, state_dir=None):
    d = pathlib.Path(state_dir or STATE_DIR)
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = d / "state.json.tmp"
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, d / "state.json")


def prune_backups(backup_root, keep=KEEP_BACKUPS):
    with contextlib.suppress(OSError):
        olds = sorted(p for p in pathlib.Path(backup_root).iterdir()
                      if p.name.startswith(BACKUP_PREFIX) and p.is_dir())
        for p in olds[:-keep] if keep else olds:
            shutil.rmtree(p, ignore_errors=True)


# ---------------------------------------------------------------- update

def plan(esp, macos=None, board=None, out=print):
    """What update would do: a dict with the chosen macOS and this Mac's
    radio parts. Raises Refused."""
    esp = pathlib.Path(esp)
    vendorfw, all_fw = esp / "vendorfw", esp / "asahi" / "all_firmware.tar.gz"
    for p in (vendorfw / "manifest.txt", vendorfw / "firmware.tar", vendorfw / "firmware.cpio"):
        if not p.is_file():
            raise Refused(f"{p} is missing; this does not look like an Aurora system ESP")
    manifest = parse_manifest((vendorfw / "manifest.txt").read_text("ascii"))
    parts = radio_parts(manifest, board)
    if not parts:
        raise Refused("the ESP's vendorfw has no radio firmware this tool follows")
    if macos is None:
        macos = restore_image()[0]
    out(f"Source: {macos.describe()}")
    return {"esp": esp, "vendorfw": vendorfw, "all_fw": all_fw, "macos": macos,
            "manifest": manifest, "parts": parts, "board": board,
            "current": owned_in(manifest, parts)}


def has_dir(vol, path):
    try:
        return vol.resolve(path)[1] == 4
    except apfs_ro.ApfsError:
        return False


def update(esp, macos=None, board=None, dry_run=False, backup_root=None,
           state_dir=None, out=print, swap=exchange, probe=None, log_text=None):
    """Returns "identical", "dry-run" or "updated", or raises Refused/NotNow."""
    backup_root = pathlib.Path(backup_root or BACKUP_ROOT)
    p = plan(esp, macos, board, out)
    esp, vendorfw, all_fw, macos = p["esp"], p["vendorfw"], p["all_fw"], p["macos"]
    with tempfile.TemporaryDirectory(prefix="aurora-wifi-firmware-") as tmp:
        tmp = pathlib.Path(tmp)
        parts, files, trees, raw_same = [], {}, {}, True
        has_raw = all_fw.is_file()
        for part in p["parts"]:
            gone = part.unavailable(macos)
            if gone:
                out(f"{part.label}: macOS {macos.build} has {gone}; "
                    f"the ESP's files stay")
                continue
            staged = {}
            for n, (src, prefix, want) in enumerate(part.sources):
                staged[src] = tmp / f"{part.key}-{n}"
                tree = part.stage(macos, src, staged[src], want)
                if prefix and has_raw:
                    trees[prefix] = tree
            new = part.convert(staged)
            missing = part.missing(new, p["current"])
            if missing:
                raise Refused(f"macOS {macos.build}'s {part.label} firmware lacks what this Mac "
                              f"loads: " + ", ".join(missing))
            cur = {k: v for k, v in p["current"].items() if part.owns(k)}
            same = cur == {k: v.sha for k, v in new.items()}
            out(f"{part.label}: ESP {len(cur)} files, macOS {len(new)} files"
                + (" (the same)" if same else ""))
            for name, fw in sorted(part.expect(new).items()):
                out(f"  {name}: ESP {p['current'].get(name, 'none')[:16]}  macOS {fw[:16]}")
            if has_raw and any(prefix for _, prefix, _ in part.sources):
                raw_same = raw_same and raw_converts_to(
                    all_fw, part, {k: v.sha for k, v in new.items()}, tmp)
            parts.append(part)
            files.update(sorted(new.items()))
        if not parts:
            raise Refused(f"macOS {macos.build} ships none of the radio firmware on the ESP")
        owns = lambda name: any(part.owns(name) for part in parts)  # noqa: E731
        current = {k: v for k, v in p["current"].items() if owns(k)}
        new = {k: v.sha for k, v in files.items()}
        if current == new and raw_same:
            out(f"The ESP already holds macOS {macos.build}'s radio firmware. Nothing to do.")
            return "identical"

        # A copy an earlier run left behind holds space this change needs;
        # commit would replace it anyway. (A dry run leaves it and counts it
        # as free.)
        if not dry_run:
            for stale in leftovers(esp):
                out(f"Removing {stale}, left by an earlier run that did not finish")
                remove(stale)

        # The ESP must take a second vendorfw (and all_firmware, when its raw
        # trees change) beside the current one before the swap. Refuse before
        # building anything when even the new vendorfw cannot fit: the current
        # package plus the converted set's growth in both firmware.tar and
        # firmware.cpio. all_firmware is left to the exact check below, as
        # its new size is only known once it is built (a newer macOS can ship
        # fewer files). This floor stays under that check's need: tar and cpio
        # headers move it by kilobytes, the check adds 4 MiB.
        growth = files_bytes(files) - owned_bytes(vendorfw, owns)
        require_space(esp, max(0, tree_size(vendorfw) + 2 * growth))

        staged = tmp / "vendorfw"
        staged.mkdir()
        rebuild_vendorfw(vendorfw, staged, files, owns)
        check_package(vendorfw, staged, files, owns)
        new_fw = tmp / "all_firmware.tar.gz"
        if not raw_same:
            try:
                rebuild_all_firmware(all_fw, new_fw, trees)
            except (EOFError, gzip.BadGzipFile, tarfile.TarError, zlib.error) as e:
                # Its other members (fud_firmware, ...) cannot be carried over.
                raise Refused(f"{all_fw} does not read ({e}); the ESP's files stay") from e
            for prefix, tree in trees.items():
                if raw_tree(new_fw, prefix) != tree_digest(tree):
                    raise Refused("the rebuilt all_firmware does not hold exactly the macOS tree")
        out("Check passed: the rebuilt vendorfw keeps every other file by path, hash and mode "
            "and holds exactly the converted set.")
        if dry_run:
            out(f"Dry run: would back up to {backup_root}/{BACKUP_PREFIX}<time>-<id> and replace "
                + ("" if raw_same else "asahi/all_firmware.tar.gz and ")
                + "vendorfw/. Nothing was changed.")
            return "dry-run"

        # The drivers that are up now must be up after the change.
        probe = probe or radio_probe
        optional = [x for part in parts for x in part.probes if x not in part.always]
        text = (log_text if log_text is not None else kernel_log()) if optional else ""
        required = sorted({x for part in parts for x in part.always}
                          | {x for x in optional if probe(x, text)})
        require_space(esp, tree_size(staged) + (0 if raw_same else new_fw.stat().st_size)
                      + (4 << 20))
        os.makedirs(backup_root, mode=0o700, exist_ok=True)
        backup = pathlib.Path(tempfile.mkdtemp(
            prefix=time.strftime(BACKUP_PREFIX + "%Y%m%d-%H%M%S-"), dir=backup_root))
        if not raw_same:
            copy_verified(all_fw, backup / "all_firmware.tar.gz")
        copy_verified(vendorfw, backup / "vendorfw")
        out(f"Backed up the ESP files to {backup}")
        pairs = ([] if raw_same else [(new_fw, all_fw)]) + [(staged, vendorfw)]
        commit(esp, pairs, backup, swap)
        expect = {}
        for part in parts:
            expect.update(part.expect(files))
        write_state({"build": macos.build, "version": macos.version, "board": macos.board,
                     "device": macos.device,
                     "volume": macos.volume.name, "result": "updated", "tool": tool_digest(),
                     "parts": [part.key for part in parts],
                     "pending": {"backup": str(backup), "expect": expect, "probes": required,
                                 "parts": [part.key for part in parts], "boot_id": boot_id()}},
                    state_dir)
        prune_backups(backup_root)
        out(f"Done: macOS {macos.build}'s radio firmware is on the ESP and loads at the next boot. "
            f"The previous files are in {backup}.")
        return "updated"


# ---------------------------------------------------------------- verify / revert

def boot_id():
    with contextlib.suppress(OSError):
        return pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    return None


def kernel_log(run=subprocess.run):
    for cmd in (["journalctl", "-k", "-b", "0", "--no-pager", "-o", "cat"], ["dmesg"]):
        try:
            p = run(cmd, capture_output=True, text=True, errors="replace")
        except OSError:
            continue
        if p.returncode == 0 and p.stdout:
            return p.stdout
    return ""


def unpacked(name, roots=("/run/aurora-firmware/vendorfw", "/lib/firmware/vendor",
                          "/usr/lib/firmware/vendor")):
    for r in roots:
        f = pathlib.Path(r) / name
        if f.is_file():
            return file_sha256(f)
    return None


HCIGETDEVINFO = 0x800448D3   # _IOR('H', 211, int)
HCI_UP = 1


def hci_up(index):
    """Whether HCI device index is up (setup done, firmware running); None
    when this Python cannot ask."""
    try:
        s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    except (AttributeError, OSError):
        return None
    with s:
        # struct hci_dev_info: dev_id u16, name[8], bdaddr[6], flags u32, ...
        buf = bytearray(struct.pack("<H", index) + bytes(126))
        try:
            fcntl.ioctl(s.fileno(), HCIGETDEVINFO, buf, True)
        except OSError:
            return None
        return bool(struct.unpack_from("<I", buf, 16)[0] & HCI_UP)


def radio_probe(name, text, sys_root=None, up=hci_up):
    """brcmfmac: it reported a running firmware. net:<driver>: a network
    interface of that driver exists (<driver> may list alternatives, a|b). link:<driver>: one is associated
    (operstate up). hci:<driver>: a Bluetooth controller of that driver is up."""
    if name == "brcmfmac":
        return UP.search(text) is not None
    kind, _, driver = name.partition(":")
    drivers = driver.split("|")     # any of these drivers
    root = pathlib.Path(sys_root or SYS) / "class" / {"net": "net", "link": "net",
                                                     "hci": "bluetooth"}[kind]
    with contextlib.suppress(OSError):
        for dev in sorted(root.iterdir()):
            if os.path.basename(os.path.realpath(dev / "device" / "driver")) not in drivers:
                continue
            if kind == "net":
                return True
            if kind == "link":
                with contextlib.suppress(OSError):
                    if (dev / "operstate").read_text().strip() == "up":
                        return True
                continue
            m = re.fullmatch(r"hci([0-9]+)", dev.name)
            if m:
                state = up(int(m[1]))
                return True if state is None else state
    return False


PART_TYPES = {cls.key: cls for cls in (BroadcomWiFi, BroadcomBluetooth, MediaTekMT7932, CentauriN1)}


def failure(text, keys):
    """The first kernel log words that say one of these parts did not come up."""
    lines = text.splitlines()
    for key in keys:
        for driver, words in PART_TYPES[key].failures():
            for line in lines:
                if words in line and (driver is None or driver in line):
                    return words
    return None


def verify(state, esp, out=print, log_text=None, wait=VERIFY_WAIT, sleep=time.sleep,
           unpacked_sha=unpacked, swap=exchange, state_dir=None, probe=None):
    """The first boot after a change: did the drivers come up with the new
    firmware? "ok", "reverted" or "waiting" (still the boot that changed it)."""
    pend = state.get("pending") or {}
    if not pend:
        return "ok"
    if pend.get("boot_id") and pend.get("boot_id") == boot_id():
        return "waiting"
    probe = probe or radio_probe
    expect = pend.get("expect") or {}
    if isinstance(expect, str):     # a change made by an earlier version: one Wi-Fi file
        expect = {pend["name"]: expect}
    required = pend.get("probes", ["brcmfmac"])
    keys = [k for k in pend.get("parts", ["wifi"]) if k in PART_TYPES]
    got = {name: unpacked_sha(name) for name in expect}
    deadline = time.monotonic() + wait
    while True:
        text = log_text() if callable(log_text) else (log_text if log_text is not None else kernel_log())
        bad = failure(text, keys)
        up = {x: probe(x, text) for x in required}
        if all(up.values()) or bad or time.monotonic() >= deadline:
            break
        sleep(3)
    down = [x for x, ok in up.items() if not ok]
    if got == expect and not down and not bad:
        fw = UP.search(text)
        out(f"The drivers came up with macOS {state.get('build')}'s firmware"
            + (f": {fw[1]} version {fw[3]}" if fw else f" ({', '.join(required)})"))
        state.pop("pending", None)
        state["result"] = "verified"
        if fw:
            state["firmware"] = fw[3]
        state["esp_wifi"] = esp_wifi_digest(esp)
        write_state(state, state_dir)
        return "ok"
    why = (f"the kernel reported '{bad}'" if bad else
           "the unpacked firmware is not the one put on the ESP" if got != expect else
           f"{', '.join(down)} did not come up within {wait} s")
    out(f"The new radio firmware did not come up ({why}); putting the previous files back.")
    revert(esp, pathlib.Path(pend["backup"]), out=out, swap=swap)
    state.pop("pending", None)
    state["result"] = "reverted"
    state["refused_build"] = state.get("build")
    state["refused_version"] = state.get("version")
    write_state(state, state_dir)
    return "reverted"


def revert(esp, backup=None, out=print, swap=exchange, backup_root=None):
    backup_root = backup_root or BACKUP_ROOT
    esp = pathlib.Path(esp)
    if backup is None:
        olds = sorted(p for p in pathlib.Path(backup_root).iterdir()
                      if p.name.startswith(BACKUP_PREFIX) and p.is_dir()) \
            if pathlib.Path(backup_root).is_dir() else []
        if not olds:
            raise Refused(f"no radio firmware backup in {backup_root}")
        backup = olds[-1]
    pairs = []
    if (backup / "all_firmware.tar.gz").is_file():
        pairs.append((backup / "all_firmware.tar.gz", esp / "asahi" / "all_firmware.tar.gz"))
    if not (backup / "vendorfw" / "manifest.txt").is_file():
        raise Refused(f"{backup} holds no vendorfw")
    pairs.append((backup / "vendorfw", esp / "vendorfw"))
    commit(esp, pairs, backup, swap)
    out(f"Restored the ESP's radio firmware files from {backup}; they load at the next boot.")
    return "reverted"


# ---------------------------------------------------------------- main

def status(esp, board, out=print):
    vendorfw = pathlib.Path(esp) / "vendorfw" / "manifest.txt"
    manifest = parse_manifest(vendorfw.read_text("ascii")) if vendorfw.is_file() else {}
    out(f"Broadcom board: {board or 'none'}")
    with contextlib.suppress(Refused):
        for part in radio_parts(manifest, board):
            names = sorted(k for k in manifest if part.owns(k))
            out(f"{part.label}: {len(names)} files on the ESP")
            shown = part.expect({k: FWFile(k, b"") for k in names}) or {}
            for name in sorted(shown):
                out(f"  {name}: ESP {manifest[name][:16]}; unpacked: "
                    f"{(unpacked(name) or 'none')[:16]}")
    text = kernel_log()
    up = UP.search(text)
    if board:
        out(f"Running Wi-Fi firmware: {up[1]} {up[3]} ({up[2]})" if up
            else "Running Wi-Fi firmware: not reported")
    for x in ("hci:hci_bcm4377", "net:mt7932-fullmac", "hci:mt7932_bt_pcie"):
        if radio_probe(x, text):
            out(f"Up: {x}")
    out(f"Source: the macOS {os_fw_version() or '(unknown)'} restore image for {mac_board() or '(unknown)'}")
    st = read_state()
    if st:
        out("Last run: " + json.dumps(st, sort_keys=True))


_TOOL = None


def tool_digest():
    """sha256 of the code that decides a refusal or a match: this file,
    apfs_ro and the asahi_firmware modules loaded, so a fixed or newer tool
    checks again."""
    global _TOOL
    if _TOOL is None:
        files = {"aurora_wifi_firmware": __file__, "restore-images.json": ipsw.CATALOG}
        files.update((n, m.__file__) for n, m in list(sys.modules.items())
                     if (n == "asahi_firmware" or n.startswith("asahi_firmware."))
                     and getattr(m, "__file__", None))
        h = hashlib.sha256()
        for name in sorted(files):
            h.update(f"{name} {file_sha256(files[name])}\n".encode())
        _TOOL = h.hexdigest()
    return _TOOL


def remembered(error):
    """Whether a boot remembers this refusal: only what the same inputs and
    the same tool give again. A copy or swap that failed (Transient) is
    tried again at the next boot."""
    return isinstance(error, Refused) and not isinstance(error, Transient)


def refusal(error, macos, esp):
    """What a refused boot remembers: the reason, and the inputs that decide
    it (the macOS build, the ESP's radio set and this tool's code) so an
    unchanged Mac does not read, convert and stage the same trees at every
    boot."""
    return {"build": macos.build, "device": macos.device, "board": macos.board, "version": macos.version,
            "esp_wifi": esp_wifi_digest(esp),
            "tool": tool_digest(), "reason": str(error), "need": getattr(error, "need", None)}


def source_key():
    """What decides the source, read without the network: this Mac's board
    and its stub firmware version. (None, None) when either is unknown."""
    board, version = mac_board(), os_fw_version()
    return (board, version) if board and version else (None, None)


def same_source(record, key):
    return bool(record) and key[0] is not None and (record.get("board"), record.get("version")) == key


def refusal_stands(refused, key, esp):
    """True while nothing a remembered refusal depended on has changed: the
    same board and stub firmware version (so the same restore image), the
    same ESP radio set, the same tool and,
    for a lack of space, still too little free space on the ESP (counting
    what an earlier run's leftovers hold, which the next try removes)."""
    if not same_source(refused, key) \
            or not refused.get("esp_wifi") or refused["esp_wifi"] != esp_wifi_digest(esp) \
            or refused.get("tool") != tool_digest():
        return False
    need = refused.get("need")
    if need is None:
        return True
    return free_space(esp) < need


def main(argv=None):
    ap = argparse.ArgumentParser(prog="aurora-wifi-firmware", description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", nargs="?", default="update",
                    choices=["status", "check", "update", "boot", "revert"])
    ap.add_argument("--esp", help="the system ESP (default: the one the device tree names)")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO if a.verbose else logging.WARNING,
                        format="%(name)s: %(message)s")
    if os.geteuid() != 0:
        print("aurora-wifi-firmware: run as root", file=sys.stderr)
        return 1
    try:
        board = wifi_board()
        with system_esp(a.esp) as esp:
            if a.cmd == "status":
                status(esp, board)
                return 0
            if a.cmd == "revert":
                revert(esp)
                # The boot unit leaves this macOS build alone from now on;
                # `update` (or a newer macOS) brings it back.
                st = read_state()
                write_state(dict(st, result="reverted by hand", pending=None,
                                 refused_build=st.get("build"), refused_version=st.get("version")))
                return 0
            state = read_state()
            if a.cmd == "boot":
                if verify(state, esp) == "waiting":
                    return 0
                state = read_state()
            manifest = esp / "vendorfw" / "manifest.txt"
            if manifest.is_file() and not radio_parts(
                    parse_manifest(manifest.read_text("ascii")), board):
                print("The ESP holds no Wi-Fi or Bluetooth firmware this tool follows; "
                      "nothing to do.")
                return 0
            # At boot, everything that decides the outcome is known without the
            # network: the source is the restore image of this board and stub
            # firmware version, so a pair already checked against this ESP
            # package by this tool (and its catalog) needs no second read. A
            # new stub firmware, ESP package or tool reads the image once.
            key = source_key()
            if a.cmd == "boot" and same_source(state, key) \
                    and state.get("result") in ("verified", "identical") \
                    and not state.get("pending") \
                    and state.get("esp_wifi") and state.get("esp_wifi") == esp_wifi_digest(esp) \
                    and state.get("tool") == tool_digest():
                print(f"The ESP holds the macOS {key[1]} restore image's radio firmware "
                      f"({state.get('build')}, checked before). Nothing to do.")
                return 0
            if a.cmd == "boot" and refusal_stands(state.get("refused"), key, esp):
                why = state["refused"].get("reason", "")
                print(f"The macOS {key[1]} restore image's radio firmware was refused for this ESP "
                      f"before ({why}); nothing changed since (run 'aurora-wifi-firmware update' "
                      f"to try again).")
                return 1
            if a.cmd == "boot" and same_source(state, key) and key[1] == state.get("refused_version"):
                why = "was put back by hand" if state.get("result") == "reverted by hand" \
                    else "did not come up here before"
                print(f"The macOS {key[1]} restore image's radio firmware {why}; keeping the current "
                      f"files (run 'aurora-wifi-firmware update' to use it).")
                return 0
            found = restore_image()
            try:
                r = update(esp, found[0], board, dry_run=a.cmd == "check")
            except Refused as e:
                if remembered(e) and a.cmd in ("boot", "update"):
                    write_state(dict(state, refused=refusal(e, found[0], esp)))
                raise
            if r == "identical" and a.cmd != "check":
                write_state(dict(state, build=found[0].build, version=found[0].version, board=found[0].board,
                                 device=found[0].device, volume=found[0].volume.name,
                                 result="verified" if state.get("result") == "verified"
                                 and state.get("build") == found[0].build else "identical",
                                 esp_wifi=esp_wifi_digest(esp), tool=tool_digest(),
                                 refused_build=None, refused_version=None, refused=None))
            return 0
    except Refused as e:
        print(f"Refused: {e}", file=sys.stderr)
        return 1
    except NotNow as e:
        print(f"Not now: {e}", file=sys.stderr)
        return 2
    except apfs_ro.ApfsError as e:
        print(f"Not now: the restore image's System volume could not be read: {e}", file=sys.stderr)
        return 2
    except (ipsw.IpswUnavailable, ipsw.aea_ro.AeaUnavailable, remotezip.RemoteZipUnavailable) as e:
        print(f"Not now: the restore image cannot be read now: {e}", file=sys.stderr)
        return 2
    except ipsw.aea_ro.AeaError as e:
        print(f"Refused: the restore image failed authentication: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception:
        logging.exception("internal error; nothing was changed unless a message above says so")
        sys.exit(3)
