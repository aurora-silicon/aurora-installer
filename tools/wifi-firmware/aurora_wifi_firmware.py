#!/usr/bin/python3 -I
# SPDX-License-Identifier: MIT
"""Keep an installed system's Broadcom Wi-Fi firmware on the installed macOS's.

macOS loads the Wi-Fi firmware its own system volume ships, so a macOS update
brings new Wi-Fi firmware. A Linux install keeps the set its installer took:
the Asahi installer's from its stub's Recovery image (macOS 13.5 for most
installs), the Aurora installer's from the macOS that ran it. This tool reads
/usr/share/firmware/wifi from the installed macOS's System volume, from Linux
and read only (apfs_ro: the System volume is not encrypted, with or without
FileVault), converts it with this repository's asahi_firmware, and when the
result differs from the ESP's package it puts it in:

  asahi/all_firmware.tar.gz  firmware/wifi/ becomes the macOS tree, so a
                             later rebuild (asahi-fwupdate) gives the same set
  vendorfw/                  brcm/brcmfmac* becomes the converted set; every
                             other file stays, by path and hash

Both are backed up to /var/lib/aurora-rollback/ first. The new firmware is
used from the next boot; nothing is reloaded at runtime. The boot after a
change checks that brcmfmac came up with it and puts the previous files back
when it did not.

    aurora-wifi-firmware status
    aurora-wifi-firmware check           dry run: what update would do
    aurora-wifi-firmware update          (the boot service runs `boot`)
    aurora-wifi-firmware boot            verify a pending change, then update
    aurora-wifi-firmware revert          put the files from before the last change back

Exit codes: 0 done or nothing to do, 1 refused (nothing changed), 2 not now,
3 internal error.
"""
import argparse, contextlib, ctypes, errno, hashlib, io, json, logging, os, pathlib, \
    plistlib, re, shutil, subprocess, sys, tarfile, tempfile, time

HERE = pathlib.Path(__file__).resolve().parent
for cand in (HERE, HERE.parents[1]):
    if (cand / "asahi_firmware" / "wifi.py").is_file():
        if str(cand) not in sys.path:
            sys.path.insert(0, str(cand))
        break
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import apfs_ro  # noqa: E402
from asahi_firmware.core import FWFile, FWPackage  # noqa: E402
from asahi_firmware.wifi import WiFiFWCollection  # noqa: E402

log = logging.getLogger("aurora-wifi-firmware")

WIFI = "usr/share/firmware/wifi"
SYSTEM_VERSION = "System/Library/CoreServices/SystemVersion.plist"
RAW_PREFIX = "firmware/wifi/"
PKG_PREFIX = "brcm/brcmfmac"
APFS_GUID = "7c3457ef-0000-11aa-aa11-00306543ecac"
DT = pathlib.Path("/proc/device-tree")
DT_ESP = "chosen/asahi,efi-system-partition"
STATE_DIR = pathlib.Path("/var/lib/aurora-wifi-firmware")
BACKUP_ROOT = pathlib.Path("/var/lib/aurora-rollback")
BACKUP_PREFIX = "wifi-firmware-"
KEEP_BACKUPS = 2
MOUNTPOINT = "/run/aurora-wifi-firmware-esp"
STAGE_BUDGET = 512 << 20
VERIFY_WAIT = 90
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
    """Every readable macOS System volume that ships Wi-Fi firmware, the
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
                v.resolve(WIFI)
            except (apfs_ro.ApfsError, ValueError, plistlib.InvalidFileException) as e:
                log.info(f"{dev} '{v.name}': no Wi-Fi firmware ({e})")
                continue
            found.append(MacOS(dev, v, info.get("ProductBuildVersion"), info.get("ProductVersion")))
    found.sort(key=lambda m: build_key(m.build), reverse=True)
    return found


def stage_wifi(vol, dest):
    """Copies the volume's Wi-Fi firmware tree to dest, links kept as links
    (the collection resolves them as macOS does). Returns {rel: bytes|link}."""
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
        elif kind == 8:
            data = vol.read_file(ino)
            total += len(data)
            if total > STAGE_BUDGET:
                raise Refused("the macOS Wi-Fi firmware tree is over the size budget")
            fd = os.open(full, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            tree[rel] = data
        elif kind == 10:
            target = vol.readlink(ino)
            # Only links inside the tree, as the installer keeps them.
            if target.startswith("/") or ".." in target.split("/"):
                log.info(f"{rel}: link out of the tree ({target}), skipped")
                return
            os.symlink(target, full)
            tree[rel] = ("link", target)

    ino, kind = vol.resolve(WIFI)
    if kind != 4:
        raise Refused(f"/{WIFI} on the macOS volume is not a directory")
    rec(ino, kind, "")
    return tree


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

def tar_entries(tree):
    """tarfile members for a raw Wi-Fi tree ({rel: bytes|('link', target)}),
    under firmware/wifi/, directories first, as the installer writes them."""
    dirs = set()
    for rel in tree:
        parts = rel.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))
    out = []
    root = tarfile.TarInfo(RAW_PREFIX.rstrip("/"))
    root.type, root.mode = tarfile.DIRTYPE, 0o755
    out.append((root, None))
    for d in sorted(dirs):
        ti = tarfile.TarInfo(RAW_PREFIX + d)
        ti.type, ti.mode = tarfile.DIRTYPE, 0o755
        out.append((ti, None))
    for rel in sorted(tree):
        v = tree[rel]
        ti = tarfile.TarInfo(RAW_PREFIX + rel)
        if isinstance(v, tuple):
            ti.type, ti.linkname, ti.mode = tarfile.SYMTYPE, v[1], 0o755
            out.append((ti, None))
        else:
            ti.type, ti.size, ti.mode = tarfile.REGTYPE, len(v), 0o644
            out.append((ti, io.BytesIO(v)))
    for ti, _ in out:
        ti.uname, ti.gname, ti.mtime = "root", "wheel", 0
    return out


def rebuild_all_firmware(old, new, tree):
    """old all_firmware with its firmware/wifi/ part replaced by tree."""
    with tarfile.open(old, mode="r:gz") as src, tarfile.open(new, mode="w:gz") as dst:
        wrote = False
        for m in src:
            name = m.name[2:] if m.name.startswith("./") else m.name
            if name.rstrip("/") + "/" == RAW_PREFIX or name.startswith(RAW_PREFIX):
                if not wrote:
                    for ti, fd in tar_entries(tree):
                        dst.addfile(ti, fd)
                    wrote = True
                continue
            dst.addfile(m, src.extractfile(m) if m.isfile() else None)
        if not wrote:
            for ti, fd in tar_entries(tree):
                dst.addfile(ti, fd)


def raw_wifi(all_fw):
    """{rel: sha256 | 'link:'+target} of all_firmware's firmware/wifi/."""
    out = {}
    with tarfile.open(all_fw, mode="r:gz") as tar:
        for m in tar:
            name = m.name[2:] if m.name.startswith("./") else m.name
            if not name.startswith(RAW_PREFIX) or m.isdir():
                continue
            rel = name[len(RAW_PREFIX):]
            if m.issym():
                out[rel] = "link:" + m.linkname
            elif m.isfile():
                out[rel] = sha256(tar.extractfile(m).read())
    return out


def tree_digest(tree):
    return {rel: ("link:" + v[1]) if isinstance(v, tuple) else sha256(v) for rel, v in tree.items()}


def rebuild_vendorfw(old_dir, new_dir, wifi):
    """vendorfw with brcm/brcmfmac* replaced by wifi ({name: FWFile}) and
    every other file kept, in update_firmware's order (Wi-Fi first)."""
    kept = []
    with tarfile.open(pathlib.Path(old_dir) / "firmware.tar") as tar:
        for m in tar.getmembers():
            if m.isdir() or m.name.startswith(PKG_PREFIX):
                continue
            src = m
            while src.islnk():
                src = tar.getmember(src.linkname)
            kept.append((m.name, FWFile(m.name, tar.extractfile(src).read())))
    pkg = FWPackage(str(new_dir))
    pkg.add_files(sorted(wifi.items()))
    pkg.add_files(kept)
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


def check_package(old_dir, new_dir, wifi):
    """Refuse unless the new package keeps every old file outside Wi-Fi by
    path and hash and holds exactly this Wi-Fi set."""
    old = parse_manifest((pathlib.Path(old_dir) / "manifest.txt").read_text("ascii"))
    new = parse_manifest((pathlib.Path(new_dir) / "manifest.txt").read_text("ascii"))
    lost = [k for k in sorted(old) if not k.startswith(PKG_PREFIX) and new.get(k) != old[k]]
    old_x, new_x = package_extras(old_dir), package_extras(new_dir)
    lost += [k for k in sorted(old_x) if new_x.get(k) != old_x[k]]
    if lost:
        raise Refused(f"the rebuilt vendorfw would lose or change {len(lost)} other file(s): "
                      + ", ".join(lost[:6]) + (" ..." if len(lost) > 6 else ""))
    want = {k: v.sha for k, v in wifi.items()}
    if wifi_in(new) != want:
        raise Refused("the rebuilt vendorfw does not hold exactly the converted Wi-Fi set")
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

def read_state(state_dir=STATE_DIR):
    with contextlib.suppress(OSError, ValueError):
        return json.loads((pathlib.Path(state_dir) / "state.json").read_text())
    return {}


def write_state(state, state_dir=STATE_DIR):
    d = pathlib.Path(state_dir)
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
    """What update would do: a dict with the chosen macOS, the converted
    set and whether the ESP already holds it. Raises Refused."""
    esp = pathlib.Path(esp)
    vendorfw, all_fw = esp / "vendorfw", esp / "asahi" / "all_firmware.tar.gz"
    for p in (vendorfw / "manifest.txt", vendorfw / "firmware.tar", vendorfw / "firmware.cpio"):
        if not p.is_file():
            raise Refused(f"{p} is missing; this does not look like an Aurora system ESP")
    current = wifi_in(parse_manifest((vendorfw / "manifest.txt").read_text("ascii")))
    chips = board_chips(current, board)
    if not chips:
        raise Refused(f"the ESP's vendorfw has no Wi-Fi firmware for this Mac's board ({board}); "
                      f"reinstall the firmware with the installer")
    if macos is None:
        found = installed_macos(esp)
        if not found:
            raise NotNow("no installed macOS System volume with Wi-Fi firmware was readable")
        macos = found[0]
        if len(found) > 1:
            out("Installed macOS: " + "; ".join(m.describe() for m in found) + " (newest used)")
    out(f"Source: {macos.describe()}")
    return {"esp": esp, "vendorfw": vendorfw, "all_fw": all_fw, "macos": macos,
            "current": current, "chips": chips, "board": board}


def update(esp, macos=None, board=None, dry_run=False, backup_root=BACKUP_ROOT,
           state_dir=STATE_DIR, out=print, swap=exchange):
    """Returns "identical", "dry-run" or "updated", or raises Refused/NotNow."""
    p = plan(esp, macos, board, out)
    esp, vendorfw, all_fw, macos = p["esp"], p["vendorfw"], p["all_fw"], p["macos"]
    with tempfile.TemporaryDirectory(prefix="aurora-wifi-firmware-") as tmp:
        tmp = pathlib.Path(tmp)
        raw = tmp / "wifi"
        tree = stage_wifi(macos.volume, raw)
        wifi = converted(raw)
        missing = missing_for_board(wifi, board, p["chips"])
        if missing:
            raise Refused(f"macOS {macos.build}'s Wi-Fi firmware lacks this Mac's board: "
                          + ", ".join(missing))
        new = {k: v.sha for k, v in wifi.items()}
        raw_same = not all_fw.is_file() or raw_wifi(all_fw) == tree_digest(tree)
        pkg_same = p["current"] == new
        stem = f"{PKG_PREFIX}{sorted(p['chips'])[0]}-pcie.apple,{board}.bin"
        out(f"Board {board} ({', '.join(sorted(p['chips']))}): {stem}")
        out(f"  ESP:   {p['current'].get(stem, 'none')[:16]}  ({len(p['current'])} Wi-Fi files)")
        out(f"  macOS: {new.get(stem, 'none')[:16]}  ({len(new)} Wi-Fi files)")
        if pkg_same and raw_same:
            out(f"The ESP already holds macOS {macos.build}'s Wi-Fi firmware. Nothing to do.")
            return "identical"

        staged = tmp / "vendorfw"
        staged.mkdir()
        rebuild_vendorfw(vendorfw, staged, wifi)
        check_package(vendorfw, staged, wifi)
        new_fw = tmp / "all_firmware.tar.gz"
        if not raw_same:
            rebuild_all_firmware(all_fw, new_fw, tree)
            if raw_wifi(new_fw) != tree_digest(tree):
                raise Refused("the rebuilt all_firmware does not hold exactly the macOS tree")
        out("Check passed: the rebuilt vendorfw keeps every other file by path and hash and "
            "holds exactly the converted set.")
        if dry_run:
            out(f"Dry run: would back up to {backup_root}/{BACKUP_PREFIX}<time>-<id> and replace "
                + ("" if raw_same else "asahi/all_firmware.tar.gz and ")
                + "vendorfw/. Nothing was changed.")
            return "dry-run"

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
        write_state({"build": macos.build, "version": macos.version, "device": macos.device,
                     "volume": macos.volume.name, "result": "updated",
                     "pending": {"backup": str(backup), "expect": new.get(stem),
                                 "name": stem, "boot_id": boot_id()}},
                    state_dir)
        prune_backups(backup_root)
        out(f"Done: macOS {macos.build}'s Wi-Fi firmware is on the ESP and loads at the next boot. "
            f"The previous files are in {backup}.")
        return "updated"


# ---------------------------------------------------------------- verify / revert

def boot_id():
    with contextlib.suppress(OSError):
        return pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    return None


def kernel_log(run=subprocess.run):
    p = run(["journalctl", "-k", "-b", "0", "--no-pager", "-o", "cat"],
            capture_output=True, text=True, errors="replace")
    if p.returncode == 0 and p.stdout:
        return p.stdout
    p = run(["dmesg"], capture_output=True, text=True, errors="replace")
    return p.stdout if p.returncode == 0 else ""


def unpacked(name, roots=("/run/aurora-firmware/vendorfw", "/lib/firmware/vendor",
                          "/usr/lib/firmware/vendor")):
    for r in roots:
        f = pathlib.Path(r) / name
        if f.is_file():
            return file_sha256(f)
    return None


def verify(state, esp, out=print, log_text=None, wait=VERIFY_WAIT, sleep=time.sleep,
           unpacked_sha=unpacked, swap=exchange, state_dir=STATE_DIR):
    """The first boot after a change: did brcmfmac come up with the new
    firmware? "ok", "reverted" or "waiting" (still the boot that changed it)."""
    pend = state.get("pending") or {}
    if not pend:
        return "ok"
    if pend.get("boot_id") and pend.get("boot_id") == boot_id():
        return "waiting"
    got = unpacked_sha(pend["name"])
    deadline = time.monotonic() + wait
    while True:
        text = log_text() if callable(log_text) else (log_text if log_text is not None else kernel_log())
        up = UP.search(text)
        bad = next((f for f in FAILED if f in text), None)
        if up or bad or time.monotonic() >= deadline:
            break
        sleep(3)
    if got == pend.get("expect") and up and not bad:
        out(f"brcmfmac came up with macOS {state.get('build')}'s firmware: {up[1]} version {up[3]}")
        state.pop("pending", None)
        state["result"] = "verified"
        state["firmware"] = up[3]
        write_state(state, state_dir)
        return "ok"
    why = (f"brcmfmac reported '{bad}'" if bad else
           "the unpacked firmware is not the one put on the ESP" if got != pend.get("expect") else
           f"brcmfmac did not report a running firmware within {wait} s")
    out(f"The new Wi-Fi firmware did not come up ({why}); putting the previous files back.")
    revert(esp, pathlib.Path(pend["backup"]), out=out, swap=swap)
    state.pop("pending", None)
    state["result"] = "reverted"
    state["refused_build"] = state.get("build")
    write_state(state, state_dir)
    return "reverted"


def revert(esp, backup=None, out=print, swap=exchange, backup_root=BACKUP_ROOT):
    esp = pathlib.Path(esp)
    if backup is None:
        olds = sorted(p for p in pathlib.Path(backup_root).iterdir()
                      if p.name.startswith(BACKUP_PREFIX) and p.is_dir()) \
            if pathlib.Path(backup_root).is_dir() else []
        if not olds:
            raise Refused(f"no Wi-Fi firmware backup in {backup_root}")
        backup = olds[-1]
    pairs = []
    if (backup / "all_firmware.tar.gz").is_file():
        pairs.append((backup / "all_firmware.tar.gz", esp / "asahi" / "all_firmware.tar.gz"))
    if not (backup / "vendorfw" / "manifest.txt").is_file():
        raise Refused(f"{backup} holds no vendorfw")
    pairs.append((backup / "vendorfw", esp / "vendorfw"))
    commit(esp, pairs, backup, swap)
    out(f"Restored the ESP's Wi-Fi firmware files from {backup}; they load at the next boot.")
    return "reverted"


# ---------------------------------------------------------------- main

def status(esp, board, out=print):
    vendorfw = pathlib.Path(esp) / "vendorfw" / "manifest.txt"
    current = wifi_in(parse_manifest(vendorfw.read_text("ascii"))) if vendorfw.is_file() else {}
    out(f"Wi-Fi board: {board}")
    for chip in sorted(board_chips(current, board)):
        name = f"{PKG_PREFIX}{chip}-pcie.apple,{board}.bin"
        out(f"ESP firmware {name}: {current[name][:16]}; unpacked: {(unpacked(name) or 'none')[:16]}")
    up = UP.search(kernel_log())
    out(f"Running firmware: {up[1]} {up[3]} ({up[2]})" if up else "Running firmware: not reported")
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
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO if a.verbose else logging.WARNING,
                        format="%(name)s: %(message)s")
    if os.geteuid() != 0:
        print("aurora-wifi-firmware: run as root", file=sys.stderr)
        return 1
    try:
        board = wifi_board()
        if board is None:
            print("This Mac has no Broadcom Wi-Fi board in its device tree; nothing to do.")
            return 0
        with system_esp(a.esp) as esp:
            if a.cmd == "status":
                status(esp, board)
                return 0
            if a.cmd == "revert":
                revert(esp)
                write_state(dict(read_state(), result="reverted by hand", pending=None))
                return 0
            state = read_state()
            if a.cmd == "boot":
                if verify(state, esp) == "waiting":
                    return 0
                state = read_state()
            found = installed_macos(esp)
            if not found:
                raise NotNow("no installed macOS System volume with Wi-Fi firmware was readable")
            if a.cmd == "boot" and found[0].build == state.get("refused_build"):
                print(f"macOS {found[0].build}'s Wi-Fi firmware did not come up here before; "
                      f"keeping the current files (run 'aurora-wifi-firmware update' to retry).")
                return 0
            r = update(esp, found[0], board, dry_run=a.cmd == "check")
            if r == "identical" and a.cmd != "check":
                write_state(dict(state, build=found[0].build, version=found[0].version,
                                 result=state.get("result") or "identical"))
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
