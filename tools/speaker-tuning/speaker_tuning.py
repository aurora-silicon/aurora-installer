# SPDX-License-Identifier: MIT
"""Speaker tuning for an existing install, without reinstalling.

`collect` runs on the Mac's own macOS and writes a tarball holding the
audio-tuning/ bundle (see macOS/docs/speaker-tuning.md). `install` runs on
the installed Linux system: it re-verifies that bundle, adds it to the ESP's
asahi/all_firmware.tar.gz, rebuilds vendorfw/ with asahi_firmware.update,
checks that the rebuild only adds to the old package, backs both up and swaps
them in. `verify` checks the unpacked bundle after the reboot.

The repository's own asahi_firmware is used, read only, ahead of any copy
installed system wide (which may lack the speaker tuning collection).
"""
import argparse, contextlib, ctypes, errno, fcntl, hashlib, io, json, logging, os, \
    pathlib, shutil, subprocess, sys, tarfile, tempfile, time

REPO = pathlib.Path(__file__).resolve().parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from asahi_firmware import audio_tuning  # noqa: E402
from asahi_firmware.audio_tuning import AudioTuningFWCollection, FALLBACK_DIR, MANIFEST  # noqa: E402

log = logging.getLogger("speaker-tuning")

INFO = "aurora-speaker-tuning.json"
INFO_KIND = "aurora-speaker-tuning-collection"
PREFIX = audio_tuning.PACKAGE_PREFIX            # apple/audio-tuning/
FW_DIR = FALLBACK_DIR + "/"                     # audio-tuning/ in all_firmware
PACKAGE_FILES = ("firmware.tar", "firmware.cpio", "manifest.txt")
MAX_INFO_BYTES = 64 << 10
DT_ESP = "/proc/device-tree/chosen/asahi,efi-system-partition"
DT_COMPATIBLE = "/proc/device-tree/compatible"
DT_SERIAL = "/proc/device-tree/serial-number"
DT_SPEAKER_ID = "/proc/device-tree/chosen/asahi,speaker-id"
RUNNING_BUNDLES = ("/lib/firmware/vendor/apple", "/run/aurora-firmware/vendorfw/apple")
BACKUP_ROOT = "/var/lib/aurora-rollback"
LOCK = "/run/aurora-speaker-tuning.lock"
MOUNTPOINT = "/run/aurora-speaker-tuning-esp"


class Refused(Exception):
    """A check failed; nothing on the ESP was changed."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def summary(bundle):
    meta = json.loads(bundle[MANIFEST])
    return {
        "aid": meta["aid"],
        "files": meta["source_file_count"],
        "calibration": meta.get("speaker_thiele_small") is not None,
        "speaker_id": meta.get("speaker_id"),
        "macos_build": meta.get("macos_build"),
        "database_source": meta.get("device_dsp_database_source") or audio_tuning.DATABASE,
        "shared": len(meta.get("shared_files") or []),
        "loudness": meta.get("loudness_manager") is not None,
        "lattice": meta.get("lsm2_mask_lattice") is not None,
    }


def describe(bundle):
    s = summary(bundle)
    spid = "unknown" if s["speaker_id"] is None else s["speaker_id"]
    extra = (f", {s['shared']} shared files" if s["shared"] else "") + \
        (", loudness manager" if s["loudness"] else "")
    return (f"{s['aid']}, {s['files']} tuning files{extra}, calibration "
            f"{'present' if s['calibration'] else 'absent'}, speaker ID {spid}, "
            f"macOS {s['macos_build']}, lsm2 masker lattice "
            f"{'present' if s['lattice'] else 'absent (collect again on macOS)'}")


def verified(path):
    """The bundle under path/audio-tuning/, re-verified against its manifest,
    or Refused. The collection logs why it refused one."""
    col = AudioTuningFWCollection(path=str(path))
    if not col.bundle:
        raise Refused(f"no complete, verified speaker tuning bundle in {path}/{FALLBACK_DIR}")
    return col.bundle


# ---------------------------------------------------------------- macOS side

def target_name(target):
    """The Linux device-tree compatible of a macOS hw.target: J413AP is
    apple,j413."""
    t = target.strip().lower()
    if t.endswith("ap"):
        t = t[:-2]
    if not t or not t.isalnum():
        return None
    return "apple," + t


def sysctl(name, run=subprocess.run):
    p = run(["sysctl", "-n", name], capture_output=True)
    value = p.stdout.decode("ascii", "replace").strip() if p.returncode == 0 else ""
    return value if value and len(value) <= 32 and all(c.isalnum() or c in ",._-" for c in value) \
        else None


def tar_add(tar, name, data=None, mtime=None):
    ti = tarfile.TarInfo(name)
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(time.time() if mtime is None else mtime)
    if data is None:
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        tar.addfile(ti)
    else:
        ti.type = tarfile.REGTYPE
        ti.mode = 0o600 if name.endswith("/lsm2-param-fill.bin") else 0o644
        ti.size = len(data)
        tar.addfile(ti, io.BytesIO(data))


def bundle_members(bundle, prefix):
    """(name, bytes or None for a directory) for one bundle under prefix,
    directories first."""
    dirs = set()
    for rel in bundle:
        parts = rel.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))
    out = [(prefix.rstrip("/") + "/", None)]
    out += [(prefix + d + "/", None) for d in sorted(dirs)]
    out += [(prefix + rel, bundle[rel]) for rel in sorted(bundle)]
    return out


def write_collection(bundle, info, out):
    """The tarball the user copies to Linux: aurora-speaker-tuning.json and
    audio-tuning/. Written next to out and renamed, mode 0600."""
    tmp = out.with_name(out.name + ".partial")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            with tarfile.open(fileobj=f, mode="w:gz") as tar:
                tar_add(tar, INFO, json.dumps(info, indent=2, sort_keys=True).encode() + b"\n")
                for name, data in bundle_members(bundle, FW_DIR):
                    tar_add(tar, name, data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, out)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def collect(out=None, tunings_root=audio_tuning.TUNINGS_ROOT, run=subprocess.run, offline=None,
            force_lsm2_fill=False):
    """Collect this Mac's bundle and write the tarball. Returns its path.
    offline: an audio_tuning.OfflineMac (collect-linux) instead of the
    running macOS."""
    col = AudioTuningFWCollection(tunings_root=tunings_root, run=run, offline=offline,
                                  force_lsm2_fill=force_lsm2_fill)
    if not col.bundle:
        raise Refused("this Mac's speaker tuning was not collected (see the messages above)")
    if force_lsm2_fill and audio_tuning.lsm2_fill.NAME not in col.bundle \
            and any(audio_tuning.lsm2_fill.presets(col.bundle)):
        raise Refused("requested lsm2 parameter readback was not collected (see the messages above)")
    with tempfile.TemporaryDirectory() as tmp:
        if not col.write_fallback(tmp):
            raise Refused("could not write the speaker tuning bundle")
        if verified(tmp) != col.bundle:
            raise Refused("the written bundle does not read back identically")
    s = summary(col.bundle)
    target = sysctl("hw.target", run) if offline is None else offline.target()
    info = {
        "kind": INFO_KIND,
        "schema": 1,
        "target": target,
        "compatible": target_name(target) if target else None,
        "model": sysctl("hw.model", run) if offline is None else offline.model(),
        "aid": s["aid"],
        "macos_build": s["macos_build"],
    }
    if out is None:
        name = f"aurora-speaker-tuning-{(target or 'mac').lower()}-{s['aid']}.tar.gz"
        out = pathlib.Path.home() / name
    out = pathlib.Path(out)
    write_collection(col.bundle, info, out)
    return out, col.bundle, info


def find_adt(proc_mtd="/proc/mtd"):
    """The read-only MTD device of the ADT partition aura exposes ("adt")."""
    try:
        with open(proc_mtd) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 4 and parts[3] == '"adt"' and parts[0].endswith(":"):
                    return f"/dev/{parts[0][:-1]}ro"
    except OSError:
        pass
    raise Refused("no ADT: this boot chain does not expose the Apple device tree "
                  "(no \"adt\" partition in /proc/mtd); pass --adt FILE or run collect-macos.sh on macOS")


def dt_speaker_id(path=DT_SPEAKER_ID):
    """The loader's /chosen/asahi,speaker-id (big-endian u32), or None."""
    try:
        raw = pathlib.Path(path).read_bytes()
    except OSError:
        return None
    return int.from_bytes(raw, "big") if len(raw) == 4 else None


def collect_linux(macos_root, adt_path=None, out=None):
    """Collect this Mac's bundle on Linux: its ADT and its own macOS system
    volume, mounted read-only at macos_root. The same bundle as collect on
    that macOS, except the speaker ID when the boot chain does not export it."""
    root = pathlib.Path(macos_root)
    if not (root / "System/Library/CoreServices/SystemVersion.plist").is_file():
        raise Refused(f"{root} is not a macOS system volume (no SystemVersion.plist)")
    adt_path = adt_path or find_adt()
    with open(adt_path, "rb") as f:
        adt_bytes = f.read()
    offline = audio_tuning.OfflineMac(adt_bytes, str(root), dt_speaker_id())
    board, unit = offline.identity()
    here = read_unit()
    if unit is not None and here is not None and unit != here:
        raise Refused("the ADT is not this Mac's (its unit is not the running device tree's)")
    if out is None:
        name = f"aurora-speaker-tuning-{(offline.target() or 'mac').lower()}-linux.tar.gz"
        out = pathlib.Path.home() / name
    return collect(out, offline=offline)


# ---------------------------------------------------------------- bundle input

def safe_extract(tarball, dest):
    """Extract only aurora-speaker-tuning.json and regular files and
    directories under audio-tuning/, within the bundle bounds. Returns the
    collection info, or None."""
    info = None
    total = 0
    count = 0
    with tarfile.open(tarball, mode="r:*") as tar:
        for m in tar:
            name = m.name[2:] if m.name.startswith("./") else m.name
            name = name.rstrip("/") if m.isdir() else name
            if name in ("", ".", FALLBACK_DIR) and m.isdir():
                continue
            if name == INFO and m.isfile():
                if m.size > MAX_INFO_BYTES:
                    raise Refused("collection info over budget")
                info = json.loads(tar.extractfile(m).read(MAX_INFO_BYTES))
                continue
            if not name.startswith(FW_DIR):
                raise Refused(f"unexpected entry in the bundle tarball: {m.name!r}")
            rel = name[len(FW_DIR):]
            if not audio_tuning.admitted(rel):
                parts = rel.split("/")
                if all(p not in ("", ".", "..") for p in parts) and not rel.startswith("/") \
                        and (parts[-1].startswith("._") or parts[-1] == ".DS_Store"):
                    continue    # Finder sidecars; never part of a bundle
                raise Refused(f"inadmissible path in the bundle tarball: {m.name!r}")
            target = os.path.join(dest, FALLBACK_DIR, rel)
            if m.isdir():
                os.makedirs(target, exist_ok=True)
                continue
            if not m.isfile():
                raise Refused(f"the bundle tarball holds a link or special file: {m.name!r}")
            count += 1
            total += m.size
            if count > audio_tuning.MAX_FILES + 8 or total > audio_tuning.MAX_BYTES + (1 << 20):
                raise Refused("bundle tarball over budget")
            os.makedirs(os.path.dirname(target), exist_ok=True)
            try:
                dst = open(target, "xb")
            except FileExistsError:
                raise Refused(f"duplicate entry in the bundle tarball: {m.name!r}")
            with tar.extractfile(m) as src, dst:
                shutil.copyfileobj(src, dst)
    if info is not None and (not isinstance(info, dict) or info.get("kind") != INFO_KIND):
        raise Refused("unknown collection info in the bundle tarball")
    return info


@contextlib.contextmanager
def opened_bundle(source):
    """(bundle, info or None) from a collect tarball, a directory holding
    audio-tuning/, or an audio-tuning/ directory itself."""
    source = pathlib.Path(source)
    if source.is_file():
        with tempfile.TemporaryDirectory() as tmp:
            info = safe_extract(source, tmp)
            yield verified(tmp), info
        return
    if source.is_dir():
        if (source / FALLBACK_DIR / MANIFEST).is_file():
            yield verified(source), None
            return
        if source.name == FALLBACK_DIR and (source / MANIFEST).is_file():
            yield verified(source.parent), None
            return
    raise Refused(f"{source} is neither a bundle tarball nor a directory with {FALLBACK_DIR}/")


# ---------------------------------------------------------------- ESP

def find_esp(run=subprocess.run, dt_esp=DT_ESP, root="/"):
    """(path of the system ESP, whether we mounted it). Follows
    mount_sys_esp in asahi-scripts: the device tree's ESP PARTUUID unless a
    .builder marker says otherwise, else /boot/efi or /boot holding m1n1."""
    r = pathlib.Path(root)
    uuid = ""
    with contextlib.suppress(OSError):
        uuid = pathlib.Path(dt_esp).read_bytes().replace(b"\0", b"").decode("ascii").strip()
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
            raise Refused(f"the system ESP {device} is mounted read only at {mounts[0][0]}")
        os.makedirs(MOUNTPOINT, mode=0o700, exist_ok=True)
        p = run(["mount", "-t", "vfat", device, MOUNTPOINT], capture_output=True)
        if p.returncode != 0:
            raise Refused(f"could not mount the system ESP {device}: "
                          f"{p.stderr.decode().strip()}")
        return pathlib.Path(MOUNTPOINT), MOUNTPOINT
    for cand in ("boot/efi", "boot"):
        if (r / cand / "m1n1").exists():
            log.warning(f"System ESP not identified in the device tree, using /{cand}")
            return r / cand, None
    raise Refused("the system ESP was not found: no asahi,efi-system-partition in the device "
                  "tree and no m1n1 under /boot/efi or /boot")


def kernelcache(asahi):
    """The kernelcache asahi_firmware.update would pick: the first directory
    entry starting with kernelcache."""
    for name in os.listdir(asahi):
        if name.startswith("kernelcache"):
            return asahi / name
    raise Refused(f"no kernelcache in {asahi}")


def parse_manifest(text):
    """vendorfw manifest.txt -> {name: sha256}, LINK entries resolved."""
    out = {}
    for n, line in enumerate(text.splitlines(), 1):
        f = line.split()
        if len(f) == 4 and f[0] == "FILE" and f[2] == "SHA256":
            out[f[1]] = f[3]
        elif len(f) == 3 and f[0] == "LINK" and f[2] in out:
            out[f[1]] = out[f[2]]
        elif f:
            raise Refused(f"unreadable vendorfw manifest line {n}: {line!r}")
    return out


def package_extras(vendorfw):
    """{relative path: sha256} of the package's files besides the archives
    and the manifest (the u-boot/ copies)."""
    out = {}
    for parent, _, names in os.walk(vendorfw):
        for name in names:
            full = os.path.join(parent, name)
            rel = os.path.relpath(full, vendorfw)
            if rel not in PACKAGE_FILES:
                out[rel] = file_sha256(full)
    return out


def tuning_in_package(entries):
    return {k[len(PREFIX):]: v for k, v in entries.items() if k.startswith(PREFIX)}


def bundle_hashes(bundle):
    return {rel: sha256(data) for rel, data in bundle.items()}


def raw_tuning(all_firmware):
    """(bundle verified from the audio-tuning/ part of all_firmware or None,
    number of unlisted extra files there)."""
    with tempfile.TemporaryDirectory() as tmp:
        names = []
        with tarfile.open(all_firmware, mode="r:gz") as tar:
            for m in tar:
                name = m.name[2:] if m.name.startswith("./") else m.name
                if not name.startswith(FW_DIR) or not m.isfile():
                    continue
                rel = name[len(FW_DIR):]
                if not audio_tuning.admitted(rel):
                    names.append(rel)
                    continue
                target = os.path.join(tmp, FALLBACK_DIR, rel)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with tar.extractfile(m) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                names.append(rel)
        if not names:
            return None, 0
        col = AudioTuningFWCollection(path=tmp)
        if not col.bundle:
            return None, len(names)
        return col.bundle, len([n for n in set(names) if n not in col.bundle])


def packaged_bundle(vendorfw):
    """(bundle verified from the apple/audio-tuning/ part of vendorfw's
    firmware.tar or None, number of unlisted extra files there)."""
    with tempfile.TemporaryDirectory() as tmp:
        names = []
        with tarfile.open(pathlib.Path(vendorfw) / "firmware.tar") as tar:
            for m in tar:
                if not m.name.startswith(PREFIX) or not (m.isfile() or m.islnk()):
                    continue
                rel = m.name[len(PREFIX):]
                names.append(rel)
                if not audio_tuning.admitted(rel):
                    continue
                src = m
                while src.islnk():
                    src = tar.getmember(src.linkname)
                target = os.path.join(tmp, FALLBACK_DIR, rel)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with tar.extractfile(src) as f, open(target, "wb") as dst:
                    shutil.copyfileobj(f, dst)
        if not names:
            return None, 0
        col = AudioTuningFWCollection(path=tmp)
        if not col.bundle:
            return None, len(names)
        return col.bundle, len([n for n in set(names) if n not in col.bundle])


def rebuild_tuning_only(bundle, work, dest):
    """vendorfw holding only this bundle, packaged as update_firmware
    packages speaker tuning (no other firmware, no kernelcache)."""
    from asahi_firmware.core import FWPackage
    root = pathlib.Path(work) / "tuning-only"
    for name, data in bundle_members(bundle, FW_DIR):
        path = root / name
        if data is None:
            path.mkdir(parents=True, exist_ok=True)
        else:
            path.write_bytes(data)
    col = AudioTuningFWCollection(path=str(root))
    if col.bundle != bundle:
        raise Refused("the bundle does not re-verify for packaging")
    pkg = FWPackage(pathlib.Path(dest))
    pkg.add_files(sorted(col.files()))
    pkg.close()


def rebuild_all_firmware(old, new, bundle):
    """old all_firmware with its audio-tuning/ part replaced by bundle."""
    with tarfile.open(old, mode="r:gz") as src, tarfile.open(new, mode="w:gz") as dst:
        for m in src:
            name = m.name[2:] if m.name.startswith("./") else m.name
            if name.rstrip("/") == FALLBACK_DIR or name.startswith(FW_DIR):
                continue
            dst.addfile(m, src.extractfile(m) if m.isfile() else None)
        for name, data in bundle_members(bundle, FW_DIR):
            tar_add(dst, name, data)


def check_package(old_dir, new_dir, bundle):
    """Refuse unless the new package keeps every old file outside the
    tuning, by path and hash, and holds exactly this bundle."""
    old = parse_manifest((old_dir / "manifest.txt").read_text("ascii"))
    new = parse_manifest((new_dir / "manifest.txt").read_text("ascii"))
    lost = [k for k in sorted(old) if not k.startswith(PREFIX) and new.get(k) != old[k]]
    old_x, new_x = package_extras(old_dir), package_extras(new_dir)
    lost += [k for k in sorted(old_x) if new_x.get(k) != old_x[k]]
    if lost:
        shown = ", ".join(lost[:8]) + (" ..." if len(lost) > 8 else "")
        raise Refused(f"the rebuilt vendorfw is not a superset of the current one; "
                      f"{len(lost)} file(s) would be lost or changed: {shown}")
    if tuning_in_package(new) != bundle_hashes(bundle):
        raise Refused("the rebuilt vendorfw does not hold exactly this speaker tuning bundle")
    with tarfile.open(new_dir / "firmware.tar") as tar:
        for rel, digest in bundle_hashes(bundle).items():
            m = tar.getmember(PREFIX + rel)
            while m.islnk():
                m = tar.getmember(m.linkname)
            if sha256(tar.extractfile(m).read()) != digest:
                raise Refused(f"firmware.tar disagrees with its manifest: {PREFIX + rel}")
    if not (new_dir / "firmware.cpio").is_file():
        raise Refused("the rebuilt vendorfw has no firmware.cpio")
    added = sorted(k for k in new if k not in old and not k.startswith(PREFIX))
    return len(added)


# ---------------------------------------------------------------- commit

def _renameat2():
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        fn = libc.renameat2
    except (OSError, AttributeError):
        return None
    fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    fn.restype = ctypes.c_int
    return fn


AT_FDCWD = -100
RENAME_EXCHANGE = 2


def exchange(a, b):
    """Atomically swap two paths on one filesystem. Returns True, or False
    when the kernel or filesystem cannot exchange (nothing changed)."""
    fn = _renameat2()
    if fn is None or not sys.platform.startswith("linux"):
        return False
    if fn(AT_FDCWD, os.fsencode(a), AT_FDCWD, os.fsencode(b), RENAME_EXCHANGE) == 0:
        return True
    e = ctypes.get_errno()
    if e in (errno.EINVAL, errno.ENOSYS, errno.EOPNOTSUPP, errno.ENOTSUP):
        return False
    raise OSError(e, os.strerror(e), str(a))


def swap_in(new, cur, swap=exchange):
    """Put new at cur; the old content ends at new. Returns an undo."""
    if swap(new, cur):
        return lambda: swap(new, cur) or _raise(OSError("could not swap back"))
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


def _raise(e):
    raise e


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


# ---------------------------------------------------------------- install

def rebuild_default(source, dest):
    """vendorfw from source (all_firmware.tar.gz and a kernelcache), as
    asahi-fwupdate builds it, but with this repository's asahi_firmware."""
    from asahi_firmware.update import update_firmware
    update_firmware(pathlib.Path(source), pathlib.Path(dest))


def bundle_unit(bundle):
    meta = json.loads(bundle[audio_tuning.MANIFEST])
    return meta.get("board"), meta.get("unit_id")


def unit_check(bundle, unit):
    """Refuse a bundle collected on another unit of this model: its speaker
    calibration is that unit's, and speakerguardd would refuse it anyway
    (the speakers would stay muted). --any-mac does not override this."""
    _, want = bundle_unit(bundle)
    if want is None:
        if audio_tuning.SPTS in bundle:
            log.warning("The bundle does not name the Mac it was collected on (collected before the "
                        "installer recorded it): speakerguardd runs the speakers without its "
                        "calibration (open loop). Collect it again with collect-macos.sh to use it.")
        return
    if unit is None:
        log.warning("This Mac's device-tree serial-number is unreadable: speakerguardd cannot "
                    "check the bundle's unit and runs the speakers without its calibration")
        return
    if want != unit:
        raise Refused("this bundle was collected on another Mac (its unit ID is not this Mac's): "
                      "its speaker calibration belongs to that Mac. Run collect-macos.sh on this "
                      "Mac's own macOS")


def machine_check(bundle, info, current, compatible, any_mac, unit=None):
    """Refuse a bundle that names another Mac, or replaces another AID."""
    unit_check(bundle, unit)
    if any_mac:
        return
    board, _ = bundle_unit(bundle)
    if board and compatible is not None and f"apple,{board}" not in compatible:
        here = ", ".join(c for c in compatible if c.startswith("apple,j")) or "another model"
        raise Refused(f"this bundle was collected on a {board}, but this Mac is {here}; "
                      f"pass --any-mac only if you are sure")
    aid = summary(bundle)["aid"]
    if info is not None:
        want = info.get("compatible")
        if want and compatible is not None and want not in compatible:
            here = ", ".join(c for c in compatible if c.startswith("apple,j")) or "another model"
            raise Refused(f"this bundle was collected on {info.get('target')} ({want}), but this "
                          f"Mac is {here}; pass --any-mac only if you are sure")
    else:
        log.warning("The bundle does not say which Mac it came from; its AID is not checked "
                    "against the model")
    if current is not None and summary(current)["aid"] != aid:
        raise Refused(f"the ESP already holds {summary(current)['aid']}, this bundle is {aid}; "
                      f"pass --any-mac only if you are sure")


def read_unit(path=DT_SERIAL):
    """This Mac's unit ID, from the device tree aura passes, or None."""
    try:
        return audio_tuning.unit_id(pathlib.Path(path).read_bytes())
    except OSError:
        return None


def read_compatible(path=DT_COMPATIBLE):
    try:
        return [c for c in pathlib.Path(path).read_bytes().decode("ascii", "replace").split("\0") if c]
    except OSError:
        return None


def install(source, esp, dry_run=False, backup_root=BACKUP_ROOT, any_mac=False,
            compatible=None, out=print, swap=exchange, rebuild=None, unit=None):
    """Returns "identical" (nothing to do), "dry-run" or "installed", or
    raises Refused. The ESP is left as it was on any failure."""
    esp = pathlib.Path(esp)
    asahi, vendorfw = esp / "asahi", esp / "vendorfw"
    all_fw = asahi / "all_firmware.tar.gz"
    # An ESP whose vendorfw/ carries only speaker tuning and that has no
    # asahi/ (a Mac set up without the Asahi installer's firmware step, such
    # as the J700): vendorfw is rebuilt from the bundle alone.
    tuning_only = not asahi.exists()
    need = (vendorfw / "manifest.txt", vendorfw / "firmware.cpio") + (() if tuning_only else (all_fw,))
    for p in need:
        if not p.is_file():
            raise Refused(f"{p} is missing; this does not look like an Aurora system ESP")
    if tuning_only:
        if rebuild is not None:
            raise Refused("a custom rebuild needs asahi/all_firmware.tar.gz")
        others = [k for k in parse_manifest((vendorfw / "manifest.txt").read_text("ascii"))
                  if not k.startswith(PREFIX)]
        if others:
            raise Refused(f"{esp} has no asahi/ but its vendorfw holds {len(others)} file(s) besides "
                          f"the speaker tuning ({others[0]}, ...); it cannot be rebuilt from the bundle alone")
        kernel = None
    else:
        if rebuild is None:
            rebuild = rebuild_default
        kernel = kernelcache(asahi)

    with opened_bundle(source) as (bundle, info):
        out(f"Bundle: {describe(bundle)}")
        if info is not None:
            out(f"Collected on: {info.get('target')} ({info.get('model')})")
        out(f"System ESP: {esp}")

        raw, extra = packaged_bundle(vendorfw) if tuning_only else raw_tuning(all_fw)
        old = parse_manifest((vendorfw / "manifest.txt").read_text("ascii"))
        packaged = tuning_in_package(old)
        machine_check(bundle, info, raw, compatible, any_mac, unit)

        raw_same = raw == bundle
        pkg_same = packaged == bundle_hashes(bundle)
        state = "identical bundle" if raw_same else \
            ("another bundle: " + describe(raw)) if raw else "no bundle"
        if raw_same and extra:
            state += f" ({extra} unlisted extra file(s) under {FW_DIR}, ignored)"
        if tuning_only:
            out(f"  no asahi/: vendorfw holds only speaker tuning and is rebuilt from the bundle alone")
            raw_same = True     # there is no all_firmware to replace
        else:
            out(f"  {all_fw.relative_to(esp)}: {state}")
        out(f"  {vendorfw.relative_to(esp)}: "
            f"{'identical bundle' if pkg_same else 'a different bundle' if packaged else 'no bundle'}")
        if raw_same and pkg_same:
            out("Speaker tuning already present, identical. Nothing to do.")
            return "identical"

        with tempfile.TemporaryDirectory(prefix="aurora-speaker-tuning-") as tmp:
            tmp = pathlib.Path(tmp)
            src = tmp / "source"
            src.mkdir()
            new_fw = src / "all_firmware.tar.gz"
            staged = tmp / "vendorfw"
            staged.mkdir()
            if tuning_only:
                out("Rebuilding vendorfw from the bundle alone ...")
                rebuild_tuning_only(bundle, src, staged)
            else:
                if raw_same:
                    os.symlink(all_fw, new_fw)
                else:
                    rebuild_all_firmware(all_fw, new_fw, bundle)
                os.symlink(kernel, src / kernel.name)
                out(f"Rebuilding vendorfw (kernelcache {kernel.name}) ...")
                rebuild(src, staged)
            added = check_package(vendorfw, staged, bundle)
            out(f"Check passed: the rebuilt vendorfw keeps all {len(old) - len(packaged)} "
                f"other files by path and hash"
                + (f" and adds {added} more from all_firmware" if added else "")
                + ", and holds exactly this bundle.")

            if dry_run:
                out(f"Dry run: would back up to {backup_root}/speaker-tuning-<time>-<id> and replace "
                    + ("" if raw_same else f"{all_fw.relative_to(esp)} and ")
                    + f"{vendorfw.relative_to(esp)}. Nothing was changed.")
                return "dry-run"

            need = tree_size(staged) + (0 if raw_same else new_fw.stat().st_size) + (4 << 20)
            st = os.statvfs(esp)
            if st.f_bavail * st.f_frsize < need:
                raise Refused(f"not enough free space on the ESP: {need >> 20} MiB needed")

            os.makedirs(backup_root, mode=0o700, exist_ok=True)
            backup = pathlib.Path(tempfile.mkdtemp(
                prefix=time.strftime("speaker-tuning-%Y%m%d-%H%M%S-"), dir=backup_root))
            if not tuning_only:
                copy_verified(all_fw, backup / "all_firmware.tar.gz")
            copy_verified(vendorfw, backup / "vendorfw")
            out(f"Backed up the ESP files to {backup}")

            staged_fw = asahi / "all_firmware.tar.gz.new"
            staged_pkg = esp / "vendorfw.new"
            undo = []
            try:
                for p in (staged_fw, staged_pkg):
                    remove(p)
                copy_verified(staged, staged_pkg)
                if not raw_same:
                    copy_verified(new_fw, staged_fw)
                os.sync()
                if not raw_same:
                    undo.append(swap_in(staged_fw, all_fw, swap))
                undo.append(swap_in(staged_pkg, vendorfw, swap))
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
                # Only the new copies are left at the staging names now.
                for p in (staged_fw, staged_pkg):
                    with contextlib.suppress(OSError):
                        remove(p)
                raise Refused(f"the swap failed and was undone, the ESP is unchanged: {e}") from e
            for p in (staged_fw, staged_pkg):
                try:
                    remove(p)
                except OSError as e:
                    log.warning(f"Could not remove the old copy at {p}: {e}")
            os.sync()
            out("Done: the speaker tuning is in vendorfw" + ("." if tuning_only else " and all_firmware."))
            out(f"The previous files are kept in {backup}.")
            return "installed"


def verify(roots=RUNNING_BUNDLES, esp=None, out=print, run=subprocess.run):
    """After the reboot: the unpacked bundle against its manifest, and
    against the ESP package when the ESP is given."""
    for root in roots:
        if (pathlib.Path(root) / FALLBACK_DIR / MANIFEST).is_file():
            break
    else:
        raise Refused("no speaker tuning bundle is unpacked (looked in "
                      + ", ".join(f"{r}/{FALLBACK_DIR}" for r in roots) + ")")
    bundle = verified(root)
    out(f"Unpacked bundle {root}/{FALLBACK_DIR}: {describe(bundle)}, every file matches "
        f"manifest.json")
    if esp is not None:
        pkg = tuning_in_package(parse_manifest(
            (pathlib.Path(esp) / "vendorfw" / "manifest.txt").read_text("ascii")))
        if pkg != bundle_hashes(bundle):
            raise Refused("the unpacked bundle differs from the ESP's vendorfw; reboot first")
        out("It matches the ESP's vendorfw.")
    if shutil.which("ausearch") and os.path.exists("/sys/fs/selinux/enforce"):
        # --input-logs: ausearch reads stdin instead of the logs when stdin
        # is not a terminal.
        try:
            p = run(["ausearch", "--input-logs", "-m", "AVC,USER_AVC", "-ts", "boot"],
                    capture_output=True, stdin=subprocess.DEVNULL, timeout=120)
        except subprocess.TimeoutExpired:
            p = None
        text = p.stdout.decode(errors="replace") if p is not None else ""
        if p is None or p.returncode not in (0, 1):
            out("SELinux denials since boot: could not be counted "
                "(run: sudo ausearch -m AVC,USER_AVC -ts boot)")
        else:
            n = text.count("type=AVC ") + text.count("type=USER_AVC ")
            out(f"SELinux denials since boot: {n}" + ("" if n == 0 else
                " (see: sudo ausearch -m AVC,USER_AVC -ts boot)"))
    return 0


# ---------------------------------------------------------------- CLI

@contextlib.contextmanager
def locked(path=LOCK):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise Refused("another speaker tuning install is running")
        yield
    finally:
        os.close(fd)


@contextlib.contextmanager
def system_esp(given):
    if given:
        yield pathlib.Path(given)
        return
    path, mounted = find_esp()
    try:
        yield path
    finally:
        if mounted:
            subprocess.run(["umount", mounted])


def main(argv=None):
    # The firmware package logs every file it adds at INFO on the root logger.
    logging.basicConfig(level=logging.WARNING, format="%(message)s")
    log.setLevel(logging.INFO)
    logging.getLogger("asahi_firmware.audio_tuning").setLevel(logging.INFO)
    ap = argparse.ArgumentParser(prog="speaker_tuning")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect", help="on macOS: write this Mac's speaker tuning tarball")
    c.add_argument("--lsm2-fill-readback", action="store_true",
                   help="also collect private parameter readback for full lsm2 presets (dry-run verification)")
    c.add_argument("-o", "--output",
                   help="tarball path (default ~/aurora-speaker-tuning-<mac>-AID<n>.tar.gz)")
    cl = sub.add_parser("collect-linux",
                        help="on Linux: collect from this Mac's ADT and its macOS volume mounted read-only")
    cl.add_argument("--macos-root", required=True,
                    help="the macOS system volume, mounted read-only (e.g. apfs-fuse -o ro)")
    cl.add_argument("--adt", help="ADT blob (default: the \"adt\" MTD partition aura exposes)")
    cl.add_argument("-o", "--output", required=True, help="tarball path")
    i = sub.add_parser("install", help="on Linux: add a bundle to the ESP firmware")
    i.add_argument("bundle", help="tarball from collect-macos.sh, or a directory holding audio-tuning/")
    i.add_argument("-n", "--dry-run", action="store_true", help="check and rebuild, change nothing")
    i.add_argument("--esp", help="system ESP mount point (default: found as asahi-fwupdate does)")
    i.add_argument("--backup-dir", default=BACKUP_ROOT, help=f"backup root (default {BACKUP_ROOT})")
    i.add_argument("--any-mac", action="store_true",
                   help="skip the check that the bundle came from this model and AID")
    v = sub.add_parser("verify", help="on Linux, after the reboot: check the unpacked bundle")
    v.add_argument("--esp", help="system ESP mount point")
    args = ap.parse_args(argv)
    try:
        if args.cmd in ("collect", "collect-linux"):
            if args.cmd == "collect":
                if sys.platform != "darwin":
                    raise Refused("collect runs on the Mac's own macOS (on Linux: collect-linux)")
                path, bundle, info = collect(args.output, force_lsm2_fill=args.lsm2_fill_readback)
            else:
                path, bundle, info = collect_linux(args.macos_root, args.adt, args.output)
            s = summary(bundle)
            print(f"AID: {s['aid']}")
            print(f"Files: {s['files']} tuning files ({len(bundle)} in the bundle)")
            print(f"Calibration (speaker-thiele-small): {'present' if s['calibration'] else 'absent'}")
            print(f"Speaker ID: {'unknown' if s['speaker_id'] is None else s['speaker_id']}")
            print(f"DSP database: {s['database_source']}")
            print("lsm2 masker lattice: read from AudioDSP (one per slice, identical)")
            if s["shared"] or s["loudness"]:
                print(f"Shared files: {s['shared']}, loudness manager: "
                      f"{'yes' if s['loudness'] else 'no'}")
            print(f"Mac: {info['target']} ({info['model']}), macOS {s['macos_build']}")
            print(f"Wrote {path}")
            print(f"SHA-256 {file_sha256(path)}")
            if args.cmd == "collect":
                print("Copy it to Linux on this Mac and run there:")
                print(f"  sudo tools/speaker-tuning/install-linux.sh {path.name}")
            else:
                print("Install it with:")
                print(f"  sudo tools/speaker-tuning/install-linux.sh {path}")
            return 0
        if not sys.platform.startswith("linux"):
            raise Refused(f"{args.cmd} runs on the installed Linux system")
        if os.geteuid() != 0:
            raise Refused(f"{args.cmd} needs root (the ESP is readable by root only)")
        if args.cmd == "verify":
            with system_esp(args.esp) as esp:
                return verify(esp=esp)
        with locked(), system_esp(args.esp) as esp:
            result = install(args.bundle, esp, dry_run=args.dry_run,
                             backup_root=args.backup_dir, any_mac=args.any_mac,
                             compatible=read_compatible(), unit=read_unit())
        if result == "installed":
            print("Next: reboot, then check the unpacked bundle with")
            print("  sudo tools/speaker-tuning/install-linux.sh --verify")
        return 0
    except Refused as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as e:
        print(f"error: {type(e).__name__}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
