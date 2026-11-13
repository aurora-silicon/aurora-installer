#!/usr/bin/python3 -I
# SPDX-License-Identifier: MIT
"""Keep an installed system's Wi-Fi and Bluetooth firmware on the installed macOS's.

macOS loads the radio firmware its own system volume ships, so a macOS
update brings new Wi-Fi and Bluetooth firmware. A Linux install keeps the set
its installer took: the Asahi installer's from its stub's Recovery image
(macOS 13.5 for most installs), the Aurora installer's from the macOS that
ran it. This tool reads the installed macOS's System volume from Linux, read
only (apfs_ro: the System volume is not encrypted, with or without
FileVault), converts the radio firmware with this repository's
asahi_firmware, and when the result differs from the ESP's package it puts
it in:

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
back when they did not. MT7932 radios are then restarted with the previous
files, so that boot keeps its Wi-Fi.

    aurora-wifi-firmware status
    aurora-wifi-firmware check           dry run: what update would do
    aurora-wifi-firmware update          (the boot service runs `boot`)
    aurora-wifi-firmware boot            verify a pending change, then update
    aurora-wifi-firmware revert          put the files from before the last change back

Exit codes: 0 done or nothing to do, 1 refused (nothing changed), 2 not now,
3 internal error.
"""
import argparse, contextlib, ctypes, errno, fcntl, hashlib, io, json, logging, os, pathlib, \
    plistlib, re, shutil, socket, struct, subprocess, sys, tarfile, tempfile, time

HERE = pathlib.Path(__file__).resolve().parent
for cand in (HERE, HERE.parents[1]):
    if (cand / "asahi_firmware" / "wifi.py").is_file():
        if str(cand) not in sys.path:
            sys.path.insert(0, str(cand))
        break
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import apfs_ro  # noqa: E402
from asahi_firmware import mt7932  # noqa: E402
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
APFS_GUID = "7c3457ef-0000-11aa-aa11-00306543ecac"
DT = pathlib.Path("/proc/device-tree")
DT_ESP = "chosen/asahi,efi-system-partition"
SYS = pathlib.Path("/sys")
STATE_DIR = pathlib.Path("/var/lib/aurora-wifi-firmware")
BACKUP_ROOT = pathlib.Path("/var/lib/aurora-rollback")
BACKUP_PREFIX = "wifi-firmware-"
KEEP_BACKUPS = 2
MOUNTPOINT = "/run/aurora-wifi-firmware-esp"
STAGE_BUDGET = 512 << 20
VERIFY_WAIT = 150
# brcmfmac's own words for a firmware that did not come up.
FAILED = ("Dongle setup failed", "brcmf_fw_crashed", "firmware: failed to load brcm/brcmfmac",
          "brcmf_pcie_download_fw_nvram: FW failed to initialize", "brcmf_pcie_setup: Dongle setup")
UP = re.compile(r"brcmf_c_preinit_dcmds: Firmware: (\S+) wl0: (.*?) version (\S+)")


class Refused(Exception):
    """A check failed; nothing was changed."""


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


def build_key(build):
    """25C56 -> (25, 'C', 56, ''): newer macOS builds sort later."""
    m = re.match(r"\A(\d+)([A-Z])(\d+)([a-z]?)\Z", build or "")
    return (int(m[1]), m[2], int(m[3]), m[4]) if m else (0, "", 0, build or "")


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


# ---------------------------------------------------------------- the macOS side

def apfs_partitions(run=subprocess.run):
    p = run(["lsblk", "-J", "-p", "-o", "PATH,PARTTYPE"], capture_output=True, text=True)
    if p.returncode != 0:
        return []
    out = []

    def walk(devs):
        for d in devs:
            if (d.get("parttype") or "").lower() == APFS_GUID:
                out.append(d["path"])
            walk(d.get("children") or [])
    walk(json.loads(p.stdout).get("blockdevices", []))
    return out


def stub_groups(esp):
    """Volume groups of the stub macOS this Linux install boots through
    (asahi/stub_info.json "vgid"): a boot stub, not an installed macOS."""
    with contextlib.suppress(OSError, ValueError, AttributeError):
        vgid = json.loads((pathlib.Path(esp) / "asahi" / "stub_info.json").read_text())["vgid"]
        return {str(vgid).lower()}
    return set()


class MacOS:
    """One installed macOS: its System volume and build."""

    def __init__(self, device, volume, build, version):
        self.device, self.volume, self.build, self.version = device, volume, build, version

    @property
    def group(self):
        return self.volume.group

    def describe(self):
        return f"macOS {self.version} ({self.build}), '{self.volume.name}' on {self.device}"


def installed_macos(esp, devices=None, opener=apfs_ro.Container):
    """Every readable macOS System volume that ships radio firmware, the
    stub's left out, newest build first."""
    skip = stub_groups(esp)
    found = []
    for dev in devices if devices is not None else apfs_partitions():
        try:
            vols = [v for v in opener(dev).volumes()
                    if v.role == apfs_ro.ROLE_SYSTEM and not v.encrypted]
        except (OSError, apfs_ro.ApfsError) as e:
            log.info(f"{dev}: not readable as APFS ({e})")
            continue
        for v in vols:
            if v.group in skip:
                log.info(f"{dev} '{v.name}': the boot stub's volume group, skipped")
                continue
            try:
                info = plistlib.loads(v.read_file(v.resolve(SYSTEM_VERSION)[0]))
                v.resolve(FIRMWARE)
            except (apfs_ro.ApfsError, ValueError, plistlib.InvalidFileException) as e:
                log.info(f"{dev} '{v.name}': no radio firmware ({e})")
                continue
            found.append(MacOS(dev, v, info.get("ProductBuildVersion"), info.get("ProductVersion")))
    found.sort(key=lambda m: build_key(m.build), reverse=True)
    return found


class DirVolume:
    """A macOS root copied or mounted somewhere (--macos DIR), with the
    apfs_ro volume calls the tool uses. Read only, nothing outside root."""
    role, encrypted, group = apfs_ro.ROLE_SYSTEM, False, None

    def __init__(self, root):
        self.root = pathlib.Path(root).resolve()
        self.name = str(self.root)
        self.paths = {}

    def _ino(self, path):
        ino = len(self.paths) + 2
        self.paths[ino] = path
        return ino

    @staticmethod
    def _kind(path):
        return 10 if path.is_symlink() else 4 if path.is_dir() else 8

    def resolve(self, path):
        parts = [x for x in path.split("/") if x]
        full = self.root
        for n, part in enumerate(parts):
            if part in (".", ".."):
                raise apfs_ro.ApfsError(f"{path}: unsupported component")
            full = full / part
            if not os.path.lexists(full):
                raise apfs_ro.ApfsError(f"{path}: {part} not found")
            if full.is_symlink() and n < len(parts) - 1:
                raise apfs_ro.ApfsError(f"{path}: {part} is a link")
        return self._ino(full), self._kind(full)

    def children(self, ino):
        d = self.paths[ino]
        return {e.name: (self._ino(pathlib.Path(e.path)), self._kind(pathlib.Path(e.path)))
                for e in os.scandir(d)}

    def read_file(self, ino):
        return self.paths[ino].read_bytes()

    def readlink(self, ino):
        return os.readlink(self.paths[ino])


def macos_at(root):
    """The macOS whose root is the directory root (its SystemVersion.plist)."""
    vol = DirVolume(root)
    try:
        info = plistlib.loads(vol.read_file(vol.resolve(SYSTEM_VERSION)[0]))
    except (OSError, apfs_ro.ApfsError, ValueError, plistlib.InvalidFileException) as e:
        raise Refused(f"{root} is not a macOS root: {e}")
    return MacOS(str(vol.root), vol, info.get("ProductBuildVersion"), info.get("ProductVersion"))


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


def radio_parts(current, board):
    """The parts this Mac's ESP package carries today, from its vendorfw
    names and the device tree's Broadcom board."""
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
    return parts


def owned_in(manifest, parts):
    return {k: v for k, v in manifest.items() if any(p.owns(k) for p in parts)}


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
        rw = [m[0] for m in mounts if len(m) == 2 and "rw" in m[1].split(",")]
        if rw:
            return pathlib.Path(rw[0]), None
        if mounts:
            raise NotNow(f"the system ESP {device} is mounted read only at {mounts[0][0]}")
        os.makedirs(MOUNTPOINT, mode=0o700, exist_ok=True)
        p = run(["mount", "-t", "vfat", device, MOUNTPOINT], capture_output=True)
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
            subprocess.run(["umount", mounted], capture_output=True)


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
    if not isinstance(trees, dict) or not all(isinstance(k, str) and k.endswith("/")
                                              and k.startswith("firmware/") for k in trees):
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
            elif m.isfile():
                out[rel] = sha256(tar.extractfile(m).read())
    return out


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
        raise Refused(f"{old} is in the way; move it aside first")
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
        raise Refused(f"the copy at {dst} does not match {src}")


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
            raise Refused(f"the swap failed ({e}) and could not be undone ({failed[0]}); "
                          f"restore from {backup}") from e
        for _, new, _ in staging:
            with contextlib.suppress(OSError):
                remove(new)
        raise Refused(f"the swap failed and was undone, the ESP is unchanged: {e}") from e
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
        found = installed_macos(esp)
        if not found:
            raise NotNow("no installed macOS System volume with radio firmware was readable")
        macos = found[0]
        if len(found) > 1:
            out("Installed macOS: " + "; ".join(m.describe() for m in found) + " (newest used)")
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
        for part in p["parts"]:
            gone = [src for src, _, _ in part.sources if not has_dir(macos.volume, src)]
            if gone:
                out(f"{part.label}: macOS {macos.build} has no /{gone[0]}; "
                    f"the ESP's files stay")
                continue
            staged = {}
            for n, (src, prefix, want) in enumerate(part.sources):
                staged[src] = tmp / f"{part.key}-{n}"
                tree = stage_tree(macos.volume, src, staged[src], want)
                if prefix and all_fw.is_file():
                    trees[prefix] = tree
                    raw_same = raw_same and raw_tree(all_fw, prefix) == tree_digest(tree)
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

        staged = tmp / "vendorfw"
        staged.mkdir()
        rebuild_vendorfw(vendorfw, staged, files, owns)
        check_package(vendorfw, staged, files, owns)
        new_fw = tmp / "all_firmware.tar.gz"
        if not raw_same:
            rebuild_all_firmware(all_fw, new_fw, trees)
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
        need = tree_size(staged) + (0 if raw_same else new_fw.stat().st_size) + (4 << 20)
        st = os.statvfs(esp)
        if st.f_bavail * st.f_frsize < need:
            raise Refused(f"not enough free space on the ESP: {need >> 20} MiB needed")
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
        write_state({"build": macos.build, "version": macos.version, "device": macos.device,
                     "volume": macos.volume.name, "result": "updated",
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


UNPACKED_ROOTS = ("/run/aurora-firmware/vendorfw", "/lib/firmware/vendor",
                  "/usr/lib/firmware/vendor")


def unpacked(name, roots=UNPACKED_ROOTS):
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
    interface of that driver exists. link:<driver>: one is associated
    (operstate up). hci:<driver>: a Bluetooth controller of that driver is up."""
    if name == "brcmfmac":
        return UP.search(text) is not None
    kind, _, driver = name.partition(":")
    root = pathlib.Path(sys_root or SYS) / "class" / {"net": "net", "link": "net",
                                                     "hci": "bluetooth"}[kind]
    with contextlib.suppress(OSError):
        for dev in sorted(root.iterdir()):
            if os.path.basename(os.path.realpath(dev / "device" / "driver")) != driver:
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


PART_TYPES = {cls.key: cls for cls in (BroadcomWiFi, BroadcomBluetooth, MediaTekMT7932)}

# MT7932 PCI functions, Bluetooth first: the Wi-Fi function's reset needs the
# Bluetooth one gone, as in the kernel's own radio restart after a sleep.
MT7932_FUNCTIONS = (("0x14c3", "0x793b"), ("0x14c3", "0x7932"))
RELOAD_WAIT = 90


def restore_unpacked(vendorfw, owns, roots=UNPACKED_ROOTS):
    """Write vendorfw's files that owns() accepts over the copies this boot
    unpacked, where the drivers load them from. Returns the names changed."""
    changed = []
    with tarfile.open(pathlib.Path(vendorfw) / "firmware.tar") as tar:
        for m in tar.getmembers():
            if m.isdir() or not owns(m.name) or ".." in m.name.split("/") \
                    or m.name.startswith("/"):
                continue
            src = m
            while src.islnk():
                src = tar.getmember(src.linkname)
            data = tar.extractfile(src).read()
            for r in roots:
                f = pathlib.Path(r) / m.name
                if not f.is_file():
                    continue
                if file_sha256(f) != sha256(data):
                    tmp = f.with_name(f".{f.name}.aurora-wifi-firmware")
                    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
                                 src.mode & 0o777)
                    with os.fdopen(fd, "wb") as out:
                        out.write(data)
                        out.flush()
                        os.fsync(out.fileno())
                    os.chmod(tmp, src.mode & 0o777)
                    os.replace(tmp, f)
                    changed.append(m.name)
                break
    return changed


def sysfs_write(path, run=subprocess.run, timeout=60):
    """Write 1 to a sysfs attribute in a child, so that a removal the kernel
    holds up cannot hang this tool."""
    try:
        p = run(["/bin/sh", "-c", 'echo 1 > "$1"', "sh", str(path)], timeout=timeout,
                capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        return f"{path} did not return within {timeout} s"
    return None if p.returncode == 0 else f"{path}: {(p.stderr or '').strip() or p.returncode}"


def mt7932_functions(sys_root=None):
    """[(vendor, device, sysfs device dir)] of the MT7932 functions present,
    in MT7932_FUNCTIONS order."""
    base = pathlib.Path(sys_root or SYS) / "bus" / "pci" / "devices"
    found = {}
    with contextlib.suppress(OSError):
        for dev in sorted(base.iterdir()):
            with contextlib.suppress(OSError):
                ids = ((dev / "vendor").read_text().strip(), (dev / "device").read_text().strip())
                if ids in MT7932_FUNCTIONS and ids not in found:
                    found[ids] = dev
    return [(v, d, found[(v, d)]) for v, d in MT7932_FUNCTIONS if (v, d) in found]


def reload_mt7932(vendorfw, probes, out=print, sys_root=None, roots=UNPACKED_ROOTS,
                  write=sysfs_write, probe=None, log_text=None, wait=RELOAD_WAIT,
                  sleep=time.sleep):
    """After the previous files went back on the ESP: put them over this
    boot's unpacked copies and restart the MT7932 functions (remove both,
    rescan their bridge), so the drivers load them again now. "reloaded",
    "partly" (the functions came back, not every probe is up) or "failed"."""
    probe = probe or radio_probe
    try:
        changed = restore_unpacked(vendorfw, mt7932.owned, roots)
    except (OSError, tarfile.TarError, KeyError) as e:
        out(f"Could not restore the unpacked MT7932 firmware ({e}); it loads at the next boot.")
        return "failed"
    fns = mt7932_functions(sys_root)
    if not fns:
        out("No MT7932 PCI function found; the previous firmware loads at the next boot.")
        return "failed"
    bridge = fns[0][2].resolve().parent
    for _, _, dev in fns:
        err = write(dev / "remove")
        if err:
            out(f"Could not restart the MT7932 radios ({err}); "
                "the previous firmware loads at the next boot.")
            return "failed"
    err = write(bridge / "rescan")
    if err:
        out(f"The MT7932 radios were removed but not found again ({err}); "
            "they come back at the next boot.")
        return "failed"
    deadline = time.monotonic() + wait
    while True:
        text = log_text() if callable(log_text) else (log_text if log_text is not None else "")
        up = {x: probe(x, text) for x in probes}
        if all(up.values()) or time.monotonic() >= deadline:
            break
        sleep(3)
    down = [x for x, ok in up.items() if not ok]
    out(f"Restarted the MT7932 radios with the previous firmware ({len(changed)} unpacked "
        f"file(s) restored)" + (f"; {', '.join(down)} not up within {wait} s." if down else
                               f"; {', '.join(probes)} up again."))
    return "partly" if down else "reloaded"


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
           unpacked_sha=unpacked, swap=exchange, state_dir=None, probe=None, reload=None):
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
    write_state(state, state_dir)
    # The new MT7932 firmware is still running and the Neo may have no other
    # network: load the previous files now instead of at the next boot.
    if "mt7932" in keys:
        state["reload"] = (reload or reload_mt7932)(
            pathlib.Path(pend["backup"]) / "vendorfw",
            [x for x in required if x.endswith(("mt7932-fullmac", "mt7932_bt_pcie"))],
            out=out)
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
    for m in installed_macos(esp):
        out(f"Installed: {m.describe()}")
    st = read_state()
    if st:
        out("Last run: " + json.dumps(st, sort_keys=True))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="aurora-wifi-firmware", description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", nargs="?", default="update",
                    choices=["status", "check", "update", "boot", "revert"])
    ap.add_argument("--esp", help="the system ESP (default: the one the device tree names)")
    ap.add_argument("--macos", metavar="DIR",
                    help="take the firmware from this macOS root (a mounted or copied System "
                         "volume) instead of the installed macOS; check and update only")
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
                                 refused_build=st.get("build")))
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
            if a.macos:
                if a.cmd not in ("check", "update"):
                    raise Refused("--macos goes with check or update")
                found = [macos_at(a.macos)]
            else:
                found = installed_macos(esp)
            if not found:
                raise NotNow("no installed macOS System volume with radio firmware was readable")
            # At boot, a macOS build already checked against this ESP package
            # needs no second read of its tree.
            if a.cmd == "boot" and found[0].build == state.get("build") \
                    and found[0].device == state.get("device", found[0].device) \
                    and state.get("result") in ("verified", "identical") \
                    and not state.get("pending") \
                    and state.get("esp_wifi") and state.get("esp_wifi") == esp_wifi_digest(esp):
                print(f"The ESP holds macOS {found[0].build}'s radio firmware (checked before). "
                      f"Nothing to do.")
                return 0
            if a.cmd == "boot" and found[0].build == state.get("refused_build"):
                why = "was put back by hand" if state.get("result") == "reverted by hand" \
                    else "did not come up here before"
                print(f"macOS {found[0].build}'s radio firmware {why}; keeping the current files "
                      f"(run 'aurora-wifi-firmware update' to use it).")
                return 0
            r = update(esp, found[0], board, dry_run=a.cmd == "check")
            if r == "identical" and a.cmd != "check":
                write_state(dict(state, build=found[0].build, version=found[0].version,
                                 device=found[0].device, volume=found[0].volume.name,
                                 result="verified" if state.get("result") == "verified"
                                 and state.get("build") == found[0].build else "identical",
                                 esp_wifi=esp_wifi_digest(esp), refused_build=None))
            return 0
    except Refused as e:
        print(f"Refused: {e}", file=sys.stderr)
        return 1
    except NotNow as e:
        print(f"Not now: {e}", file=sys.stderr)
        return 2
    except apfs_ro.ApfsError as e:
        print(f"Not now: the macOS volume could not be read: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception:
        logging.exception("internal error; nothing was changed unless a message above says so")
        sys.exit(3)
