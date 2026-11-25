#!/usr/bin/python3 -I
# SPDX-License-Identifier: MIT
"""Move an installed Aurora system to newer startup firmware and Stage 1.

The startup firmware is the stub macOS that iBoot starts before Stage 1.
An installation keeps the stub its installer chose; this command moves it
to the newest pinned build the installer's policy admits for this Mac,
the installer's "startup firmware slot" (macOS/docs/startup-firmware-update.md):

  Linux (this command)   checks the Mac, shows the plan, and after the owner
                         types UPGRADE stages the upgrade: a request on the
                         EFI partition and, on the current stub's System
                         volume, the Aurora Installer, the release's Stage 1
                         and the install-media marker that makes Recovery
                         open the installer.
  Recovery, visit 1      (the current stub's own Recovery, power button)
                         makes the new startup volume from Apple's restore
                         image and approves it with the owner's password.
  Recovery, visit 2      (the new volume's Recovery) enrolls Stage 1.
  Linux, first boot      `finish`: checks the boot came from the new volume.

Nothing here writes macOS, Linux's partitions, the partition table, NVRAM,
Preboot, Recovery or a startup security policy. The current stub stays
bootable; it is the way back.

    aurora-upgrade plan            what would happen; writes nothing
    aurora-upgrade stage           ask, then stage (--yes skips the question)
    aurora-upgrade status          the staged request, if any
    aurora-upgrade cancel          put the current stub's files back
    aurora-upgrade finish          after the first boot on the new volume

Exit codes: 0 done or nothing to do, 1 refused (nothing changed), 2 not now,
3 internal error.
"""
import argparse, contextlib, dataclasses, errno, fcntl, hashlib, json, os, pathlib, re, secrets, shutil, \
    subprocess, sys, tempfile, time

EXIT_OK, EXIT_REFUSED, EXIT_NOT_NOW, EXIT_INTERNAL = 0, 1, 2, 3
SCHEMA = 1
STUB_BYTES_LARGE = 5_999_951_872  # NativeInspectionPolicy: a 26.0 or later stub
STUB_BYTES_SMALL = 2_499_805_184
ALIGN = 1 << 20
ESP_FLOOR = 100 << 20             # the EFI partition keeps at least 100 MB free
SYSTEM_FLOOR = 512 << 20          # room the stage needs on the stub System volume
APFS_TYPE = "7C3457EF-0000-11AA-AA11-00306543ECAC"
MARKER = {"AppName": "Aurora Installer.app", "ProductBuildVersion": "00A191", "ProductVersion": "12.1"}
APP = "Aurora Installer.app"
REQUEST_DIR = "aurora/upgrade"
DATA_DIR = "Aurora/Recovery/UpgradeData"
SYSVER = "System/Library/CoreServices/SystemVersion.plist"
SYSVER_HIDDEN = "System/Library/CoreServices/SystemVersion-disabled.plist"
PREV = ".aurora-upgrade-prev"


class Refused(Exception):
    """A state this command will not change. Nothing was written."""


class NotNow(Exception):
    """Try again later (busy, offline). Nothing was written."""


# --- Versions: the installer's NativeInspectionPolicy.Version, rule for rule ---

def _version_parts(value):
    if not value or len(value.encode()) > 128:
        raise Refused(f"unreadable firmware version {value!r}")
    parts = [int(p) if p.isdigit() else p for p in re.split(r"[-,. ]", value)]
    if len(parts) > 3 and parts[-2] == "beta":
        if not isinstance(parts[-3], int):
            raise Refused(f"unreadable firmware version {value!r}")
        parts[-3] -= 1
        parts[-2] = 99
    return parts


def version_at_least(lhs, rhs):
    left, right = _version_parts(lhs), _version_parts(rhs)
    for a, b in zip(left, right):
        if a == b:
            continue
        if type(a) is not type(b):
            raise Refused(f"can't compare firmware versions {lhs!r} and {rhs!r}")
        return a > b
    return len(left) >= len(right)


# --- The installer's sealed policy (one source: NativeInspectionPolicySource.swift) ---

def policy_from_swift(text):
    match = re.search(r'#"""\n(.*?)\n\s*"""#', text, re.S)
    if not match:
        raise Refused("the installer policy source has no policy table")
    return json.loads(match.group(1))


def load_policy(path):
    path = pathlib.Path(path)
    text = path.read_text()
    return policy_from_swift(text) if path.suffix == ".swift" else json.loads(text)


# --- What the Mac reports ---

@dataclasses.dataclass
class Machine:
    board: str                 # j413
    chip: int                  # 0x8112
    system_firmware: str       # /chosen/asahi,iboot1-version, e.g. mBoot-20457.41.3
    os_firmware: str           # /chosen/asahi,os-fw-version, e.g. 13.5
    stub_group: str            # /chosen/apfs-preboot-uuid (upper case)
    esp_partuuid: str          # /chosen/asahi,efi-system-partition (lower case)
    stage1_version: str = ""
    stage2_version: str = ""


def _prop(chosen, name):
    try:
        return (chosen / name).read_bytes().rstrip(b"\0").decode()
    except FileNotFoundError:
        return ""


def read_machine(dt_root="/proc/device-tree"):
    dt = pathlib.Path(dt_root)
    chosen = dt / "chosen"
    compat = (dt / "compatible").read_bytes().split(b"\0")
    compat = [c.decode() for c in compat if c]
    board = next((c.split(",", 1)[1] for c in compat if re.fullmatch(r"apple,j\d+[a-z]*", c)), "")
    chip = next((int(c[len("apple,t"):], 16) for c in compat if re.fullmatch(r"apple,t[0-9a-f]{4}", c)), 0)
    m = Machine(board=board, chip=chip,
                system_firmware=_prop(chosen, "asahi,iboot1-version"),
                os_firmware=_prop(chosen, "asahi,os-fw-version"),
                stub_group=_prop(chosen, "apfs-preboot-uuid").upper(),
                esp_partuuid=_prop(chosen, "asahi,efi-system-partition").lower(),
                stage1_version=_prop(chosen, "asahi,m1n1-stage1-version"),
                stage2_version=_prop(chosen, "asahi,m1n1-stage2-version"))
    if not (m.board and m.chip and m.system_firmware and m.stub_group and m.esp_partuuid):
        raise Refused("this is not an Aurora system started by Stage 1 (the boot chain's "
                      "device tree properties are missing)")
    return m


# --- Disk layout ---

@dataclasses.dataclass
class Extent:
    start: int   # bytes, 1 MiB aligned
    size: int    # bytes


def free_extents(table):
    """Free space between partitions, from `sfdisk --json`, aligned up to 1 MiB."""
    pt = table["partitiontable"]
    sector = pt.get("sectorsize", 512)
    first, last = pt["firstlba"] * sector, (pt["lastlba"] + 1) * sector
    parts = sorted((p["start"] * sector, (p["start"] + p["size"]) * sector) for p in pt["partitions"])
    out, cursor = [], first
    for start, end in parts + [(last, last)]:
        aligned = -(-cursor // ALIGN) * ALIGN
        if start > aligned:
            out.append(Extent(aligned, start - aligned))
        cursor = max(cursor, end)
    return out


def choose_extent(extents, need, after=None):
    """The installer's slot placement: the extent right after the installation, then the smallest that fits."""
    fits = [e for e in extents if e.size >= need]
    if after is not None:
        for e in fits:
            if e.start - after < ALIGN:
                return e
    return min(fits, key=lambda e: (e.size, e.start), default=None)


# --- APFS containers (read through apfs-linux-rs) ---

@dataclasses.dataclass
class Volume:
    slot: int
    name: str
    uuid: str
    group: str
    role: str
    sealed: bool
    encrypted: bool


def parse_apfuse_info(text):
    vols, cur = [], None
    for line in text.splitlines():
        m = re.match(r"volume slot (\d+): (.*)$", line)
        if m:
            cur = {"slot": int(m.group(1)), "name": m.group(2), "group": "", "role": "",
                   "sealed": False, "encrypted": False, "uuid": ""}
            vols.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"\s+(uuid|group uuid|role|sealed|encrypted)\s+(\S+)", line)
        if m:
            key, value = m.groups()
            if key == "role":
                cur["role"] = value.split("(")[0]
            elif key in ("sealed", "encrypted"):
                cur[key] = value == "true"
            else:
                cur["group" if key == "group uuid" else "uuid"] = value.upper()
    return [Volume(**v) for v in vols]


@dataclasses.dataclass
class Stub:
    device: str
    start: int
    size: int
    volumes: list

    @property
    def system(self):
        return next(v for v in self.volumes if v.role == "system")

    @property
    def group(self):
        return self.system.group


def is_stub(volumes):
    """A startup container: an unsealed, unencrypted System volume beside Preboot and Recovery.

    macOS's own System volume is sealed; a stub's never is."""
    roles = {v.role for v in volumes}
    systems = [v for v in volumes if v.role == "system"]
    return len(systems) == 1 and not systems[0].sealed and not systems[0].encrypted \
        and {"preboot", "recovery"} <= roles


# --- The plan ---

@dataclasses.dataclass
class Target:
    version: str
    build: str
    url: str
    source_bytes: int
    manifest_sha256: str
    minimum_boot: str
    stub_bytes: int
    caution: str = ""


def choose_target(policy, qualification, machine):
    """The installer's NativeFirmwareSelection for a running Linux: the last pinned entry
    that names this board and whose system firmware floor this Mac meets.

    Linux can't read macOS's version or the system Recovery's; the system
    firmware floor stands for them here, and Recovery checks the real values
    before it changes a disk."""
    chip_min = policy["chipMinimum"].get(str(machine.chip))
    device = policy["devices"].get(machine.board)
    if chip_min is None or device is None:
        raise Refused(f"the installer does not know this Mac ({machine.board}, chip {machine.chip:#x})")
    minimum = chip_min if version_at_least(chip_min, device["minimum"]) else device["minimum"]
    best = None
    for entry in policy["firmware"]:
        pin = entry.get("pin")
        if not pin or entry.get("expert") or not version_at_least(entry["version"], minimum):
            continue
        if machine.board not in (entry.get("models") or []):
            continue
        q = qualification["pins"].get(pin["build"], {})
        if machine.board not in q.get("boards", {}) and machine.board not in q.get("experimental_boards", {}):
            continue
        if not version_at_least(machine.system_firmware, entry["minimumBoot"]):
            raise Refused(f"macOS {entry['version']} startup firmware needs system firmware "
                          f"{entry['minimumBoot']} or later; this Mac has {machine.system_firmware}. "
                          f"Update macOS to {entry['version']} or later first.")
        board = q.get("boards", {}).get(machine.board) or q.get("experimental_boards", {}).get(machine.board)
        best = Target(version=entry["version"], build=pin["build"], url=entry["sourceURL"],
                      source_bytes=pin["sourceBytes"], manifest_sha256=pin["manifestSHA256"],
                      minimum_boot=entry["minimumBoot"],
                      stub_bytes=STUB_BYTES_LARGE if version_at_least(entry["version"], "26.0") else STUB_BYTES_SMALL,
                      caution=board.get("caution", "") if isinstance(board, dict) else "")
    if best is None:
        raise Refused(f"no pinned startup firmware is admitted for this Mac ({machine.board}) yet")
    return best


@dataclasses.dataclass
class Plan:
    machine: Machine
    target: Target
    current_build: str
    current_version: str
    stub: Stub
    other_stubs: list
    extent: Extent
    esp_free: int
    system_free: int
    payload: dict

    def digest(self):
        blob = json.dumps(self.to_json(include_digest=False), sort_keys=True).encode()
        return hashlib.sha256(blob).hexdigest()

    def to_json(self, include_digest=True):
        out = {
            "schema": SCHEMA,
            "board": self.machine.board, "chip": f"{self.machine.chip:#x}",
            "system_firmware": self.machine.system_firmware,
            "current": {"version": self.current_version, "build": self.current_build,
                        "group": self.stub.group, "device": self.stub.device},
            "target": dataclasses.asdict(self.target),
            "slot_extent": {"start": self.extent.start, "size": self.target.stub_bytes,
                            "free_extent_size": self.extent.size},
            "esp_partuuid": self.machine.esp_partuuid,
            "stage1": self.payload.get("stage1", {}),
        }
        if include_digest:
            out["plan_sha256"] = self.digest()
        return out


def make_plan(machine, stub_info, stubs, extents, policy, qualification, esp_free, system_free, payload):
    if stub_info.get("vgid", "").upper() != machine.stub_group:
        raise Refused("asahi/stub_info.json on the EFI partition does not name the startup volume "
                      "this Mac started from; refusing to guess which installation this is")
    current_build = stub_info.get("manifest_info", {}).get("build_number") or \
        stub_info.get("system_version", {}).get("ProductBuildVersion", "")
    current_version = stub_info.get("system_version", {}).get("ProductVersion", "")
    if not current_build or not current_version:
        raise Refused("asahi/stub_info.json does not say which startup firmware build is installed")
    target = choose_target(policy, qualification, machine)
    if current_build == target.build:
        raise Refused(f"the startup firmware is already macOS {target.version} ({target.build}); nothing to do")
    if not version_at_least(target.version, current_version):
        raise Refused(f"the installed startup firmware ({current_version}) is newer than the target; nothing to do")
    mine = [s for s in stubs if s.group == machine.stub_group]
    if len(mine) != 1:
        raise Refused("can't find the startup container this Mac started from")
    stub = mine[0]
    others = [s for s in stubs if s is not stub]
    if any(s.size >= target.stub_bytes for s in others):
        raise Refused("another startup volume already exists beside this one (an earlier upgrade "
                      "or a second installation); remove it or finish that upgrade first")
    extent = choose_extent(extents, target.stub_bytes, after=stub.start + stub.size)
    if extent is None:
        raise Refused(f"the new startup volume needs {target.stub_bytes / 1e9:.1f} GB of free disk "
                      "space outside every partition and there is none; free space in macOS "
                      "(or shrink Linux) first")
    if esp_free < ESP_FLOOR:
        raise Refused(f"the EFI partition has {esp_free >> 20} MB free; it keeps at least 100 MB")
    if system_free < SYSTEM_FLOOR + payload.get("bytes", 0):
        raise Refused("the current startup volume has no room for the installer")
    return Plan(machine, target, current_build, current_version, stub, others, extent, esp_free,
                system_free, payload)


WARNING = """\
This is a breaking change to how this Mac starts.

  Startup firmware   macOS {cur_v} ({cur_b})  ->  macOS {tgt_v} ({tgt_b})
  Stage 1            {s1_cur}  ->  {s1_new}
  New volume         {size:.1f} GB "Aurora {tgt_v}" made in free space at {start:.1f} GB

What happens:
  1. Now: this command puts the Aurora Installer and the new Stage 1 on the
     current startup volume. Nothing else on the disk changes.
  2. Shut down. Hold the power button until the startup options appear and
     choose the current Aurora volume. Join Wi-Fi when asked. Its Recovery
     makes the new volume from Apple's macOS {tgt_v} restore image and asks
     for the Mac owner's password (the macOS user who can unlock this Mac).
  3. When it shuts down, hold the power button again and choose
     "Aurora {tgt_v}". Type the owner's password again. It starts Linux.

Linux, your files and macOS are not changed. The current volume stays and
still starts this Linux: choose it in the startup options to go back.
After the upgrade, Linux runs on macOS {tgt_v} firmware. Some parts of a Mac
can work differently on new firmware until Aurora supports them there.
{caution}"""


def warning_text(plan):
    t = plan.target
    return WARNING.format(cur_v=plan.current_version, cur_b=plan.current_build, tgt_v=t.version,
                          tgt_b=t.build, s1_cur=plan.machine.stage1_version or "unknown",
                          s1_new=plan.payload.get("stage1", {}).get("version", "unknown"),
                          size=t.stub_bytes / 1e9, start=plan.extent.start / 1e9,
                          caution=(f"\nKnown for this Mac: {t.caution}\n" if t.caution else ""))


# --- The stage: files on the current stub's System volume ---

def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_new(path, data, mode=0o644):
    """Write beside, flush, then take the name only if it is free."""
    path = pathlib.Path(path)
    tmp = path.with_name(f".{path.name}.aurora-upgrade-{secrets.token_hex(4)}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        try:
            os.link(tmp, path)
        except OSError as e:
            # FAT (the EFI partition) has no hard links. The run holds the
            # command's lock, so checking the name and renaming is enough there.
            if e.errno not in (errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EMLINK):
                raise
            if path.exists():
                raise FileExistsError(errno.EEXIST, "already exists", str(path))
            os.rename(tmp, path)
    finally:
        if tmp.exists():
            os.unlink(tmp)
    _fsync_dir(path.parent)


def _plist(d):
    rows = "".join(f"\t<key>{k}</key>\n\t<string>{v}</string>\n" for k, v in d.items())
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            f'<plist version="1.0">\n<dict>\n{rows}</dict>\n</plist>\n').encode()


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _tree_digest(root):
    root = pathlib.Path(root)
    h = hashlib.sha256()
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root).as_posix().encode()
        if p.is_symlink():
            h.update(b"L" + rel + b"\0" + os.readlink(p).encode() + b"\0")
        elif p.is_file():
            h.update(b"F" + rel + b"\0" + _sha256(p).encode() + b"\0")
        elif p.is_dir():
            h.update(b"D" + rel + b"\0")
    return h.hexdigest()


def read_payload(payload_dir):
    """The release's Recovery app and unfilled Stage 1 object; Recovery fills it for this ESP."""
    d = pathlib.Path(payload_dir)
    app, obj = d / "recovery" / APP, d / "stage1" / "aura-boot.macho"
    if not (app / "Contents" / "Info.plist").is_file() or not obj.is_file():
        raise Refused(f"{d} is not an upgrade payload (needs recovery/{APP} and stage1/aura-boot.macho)")
    sums = d / "stage1" / "SHA256SUMS"
    digest = _sha256(obj)
    if sums.is_file():
        listed = {ln.split()[-1].lstrip("*"): ln.split()[0] for ln in sums.read_text().splitlines() if ln.strip()}
        if listed.get("aura-boot.macho") not in (None, digest):
            raise Refused("the release's Stage 1 does not match its SHA256SUMS")
    version = ""
    info = d / "stage1" / "BUILD-INFO.json"
    if info.is_file():
        version = json.loads(info.read_text()).get("version", "")
    size = sum(p.stat().st_size for p in app.rglob("*") if p.is_file() and not p.is_symlink()) + obj.stat().st_size
    return {"dir": str(d), "bytes": size, "app_sha256": _tree_digest(app),
            "stage1": {"path": "stage1/aura-boot.macho", "sha256": digest, "version": version}}


def stage_system_volume(root, plan, journal):
    """Stage on a mounted stub System volume. Every step is recorded before it is taken."""
    root = pathlib.Path(root)
    payload = pathlib.Path(plan.payload["dir"])
    marker, sysver, hidden = root / ".IAPhysicalMedia", root / SYSVER, root / SYSVER_HIDDEN
    if marker.exists() and marker.read_bytes() != _plist(MARKER):
        raise Refused("the current startup volume already has an install-media marker that isn't ours; "
                      "finish or remove that installation step first")
    if hidden.exists() and sysver.exists():
        raise Refused("the current startup volume has both a visible and a hidden SystemVersion.plist")

    # 1. Upgrade data (request copy + Stage 1), built beside and renamed in.
    data = root / DATA_DIR
    if not data.exists():
        data.parent.mkdir(parents=True, exist_ok=True)
        journal.step("data", path=DATA_DIR)
        tmp = data.with_name(f".UpgradeData-{secrets.token_hex(4)}")
        (tmp / "stage1").mkdir(parents=True)
        shutil.copyfile(payload / plan.payload["stage1"]["path"], tmp / "stage1" / "aura-boot.macho")
        if _sha256(tmp / "stage1" / "aura-boot.macho") != plan.payload["stage1"]["sha256"]:
            raise Refused("the Stage 1 copy on the startup volume does not read back")
        (tmp / "upgrade-config.json").write_text(json.dumps(plan.to_json(), indent=2, sort_keys=True) + "\n")
        for f in tmp.rglob("*"):
            if f.is_file():
                with open(f, "rb+") as fh:
                    os.fsync(fh.fileno())
        os.rename(tmp, data)
        _fsync_dir(data.parent)
    else:
        cfg = json.loads((data / "upgrade-config.json").read_text())
        if cfg.get("plan_sha256") != plan.digest():
            raise Refused("an upgrade for a different plan is already staged; run `aurora-upgrade cancel` first")

    # 2. The Recovery app, replacing an older copy by rename (kept beside for cancel).
    app = root / APP
    if not app.exists() or _tree_digest(app) != plan.payload["app_sha256"]:
        tmp = root / f".{APP}.aurora-upgrade-{secrets.token_hex(4)}"
        shutil.copytree(payload / "recovery" / APP, tmp, symlinks=True)
        if _tree_digest(tmp) != plan.payload["app_sha256"]:
            raise Refused("the Aurora Installer copy on the startup volume does not read back")
        if app.exists():
            prev = root / (APP + PREV)
            if prev.exists():
                raise Refused(f"{prev.name} is in the way; run `aurora-upgrade cancel` first")
            journal.step("app-prev", path=APP)
            os.rename(app, prev)
        journal.step("app", path=APP)
        os.rename(tmp, app)
        _fsync_dir(root)

    # 3. Hide SystemVersion.plist, as the installer's prepareForRecovery does.
    if sysver.exists():
        journal.step("sysver-hidden", path=SYSVER)
        os.rename(sysver, hidden)
        _fsync_dir(sysver.parent)

    # 4. The marker, last: from here Recovery opens the installer.
    if not marker.exists():
        journal.step("marker", path=".IAPhysicalMedia")
        _write_new(marker, _plist(MARKER))
    journal.step("staged")


def cancel_system_volume(root, steps):
    """Undo the recorded steps in reverse order. Identical results on a second run."""
    root = pathlib.Path(root)
    for step in reversed(steps):
        kind = step["kind"]
        if kind == "marker":
            m = root / ".IAPhysicalMedia"
            if m.exists() and m.read_bytes() == _plist(MARKER):
                m.unlink()
        elif kind == "sysver-hidden":
            hidden, sysver = root / SYSVER_HIDDEN, root / SYSVER
            if hidden.exists() and not sysver.exists():
                os.rename(hidden, sysver)
        elif kind == "app":
            app = root / APP
            if app.exists():
                shutil.rmtree(app)
        elif kind == "app-prev":
            prev, app = root / (APP + PREV), root / APP
            if prev.exists() and not app.exists():
                os.rename(prev, app)
        elif kind == "data":
            data = root / DATA_DIR
            if data.exists():
                shutil.rmtree(data)
            for parent in (data.parent, data.parent.parent):
                with contextlib.suppress(OSError):
                    parent.rmdir()
    _fsync_dir(root)


# --- The request and journal on the EFI partition ---

class Journal:
    def __init__(self, esp):
        self.dir = pathlib.Path(esp) / REQUEST_DIR
        self.path = self.dir / "journal.json"
        self.data = json.loads(self.path.read_text()) if self.path.exists() else {"schema": SCHEMA, "steps": []}

    def _save(self):
        self.dir.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(f".journal.{secrets.token_hex(4)}")
        tmp.write_text(json.dumps(self.data, indent=2) + "\n")
        with open(tmp, "rb+") as fh:
            os.fsync(fh.fileno())
        os.replace(tmp, self.path)
        _fsync_dir(self.dir)

    def step(self, kind, **kw):
        self.data["steps"].append({"kind": kind, "time": int(time.time()), **kw})
        self._save()

    def set(self, **kw):
        self.data.update(kw)
        self._save()


def write_request(esp, plan):
    d = pathlib.Path(esp) / REQUEST_DIR
    d.mkdir(parents=True, exist_ok=True)
    req = d / "request.json"
    body = (json.dumps(plan.to_json(), indent=2, sort_keys=True) + "\n").encode()
    if req.exists():
        if json.loads(req.read_text()).get("plan_sha256") != plan.digest():
            raise Refused("an upgrade for a different plan is already staged; run `aurora-upgrade cancel` first")
        return
    _write_new(req, body)


# --- Real system access (root) ---

def _run(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout


def esp_mountpoint(esp_partuuid):
    src = f"/dev/disk/by-partuuid/{esp_partuuid}"
    dev = os.path.realpath(src)
    for line in pathlib.Path("/proc/self/mounts").read_text().splitlines():
        f = line.split()
        if os.path.realpath(f[0]) == dev:
            return f[1].replace("\\040", " ")
    raise Refused(f"the EFI partition {esp_partuuid} is not mounted")


def disk_of(partdev):
    name = pathlib.Path(os.path.realpath(partdev)).name
    parent = pathlib.Path(f"/sys/class/block/{name}").resolve().parent.name
    return f"/dev/{parent}"


def scan_stubs(disk, table, apfuse):
    sector = table["partitiontable"].get("sectorsize", 512)
    out = []
    for p in table["partitiontable"]["partitions"]:
        if p["type"].upper() != APFS_TYPE:
            continue
        try:
            vols = parse_apfuse_info(_run(apfuse, "info", p["node"]))
        except subprocess.CalledProcessError:
            continue
        if is_stub(vols):
            out.append(Stub(p["node"], p["start"] * sector, p["size"] * sector, vols))
    return out


@contextlib.contextmanager
def mounted(device, slot, mount_tool, readonly):
    mnt = tempfile.mkdtemp(prefix="aurora-upgrade-", dir="/run")
    opts = f"volume={slot},foreground" + (",ro" if readonly else "")
    proc = subprocess.Popen([mount_tool, device, mnt, "-o", opts], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(100):
            if os.path.ismount(mnt):
                break
            if proc.poll() is not None:
                raise NotNow(f"the APFS driver could not mount the startup volume: {proc.stdout.read().strip()}")
            time.sleep(0.1)
        else:
            raise NotNow("the APFS driver did not mount the startup volume in 10 s")
        yield pathlib.Path(mnt)
    finally:
        if os.path.ismount(mnt):
            os.sync()
            subprocess.run(["umount", mnt], check=False)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
        with contextlib.suppress(OSError):
            os.rmdir(mnt)


def gather(args):
    machine = read_machine(args.device_tree)
    esp = args.esp or esp_mountpoint(machine.esp_partuuid)
    stub_info_path = pathlib.Path(esp) / "asahi" / "stub_info.json"
    if not stub_info_path.is_file():
        raise Refused("asahi/stub_info.json is missing on the EFI partition; can't tell which "
                      "startup firmware is installed")
    stub_info = json.loads(stub_info_path.read_text())
    disk = disk_of(f"/dev/disk/by-partuuid/{machine.esp_partuuid}")
    table = json.loads(_run("sfdisk", "--json", disk))
    stubs = scan_stubs(disk, table, args.apfuse)
    st = os.statvfs(esp)
    payload = read_payload(args.payload) if args.payload else {"bytes": 0}
    policy = load_policy(args.policy)
    qualification = json.loads(pathlib.Path(args.qualification).read_text())
    mine = [s for s in stubs if s.group == machine.stub_group]
    system_free = 0
    if len(mine) == 1:
        with mounted(mine[0].device, mine[0].system.slot, args.apfuse_mount, readonly=True) as root:
            sv = os.statvfs(root)
            system_free = sv.f_bavail * sv.f_frsize
    plan = make_plan(machine, stub_info, stubs, free_extents(table), policy, qualification,
                     st.f_bavail * st.f_frsize, system_free, payload)
    return plan, esp


def cmd_plan(args):
    plan, esp = gather(args)
    print(warning_text(plan))
    print(json.dumps(plan.to_json(), indent=2, sort_keys=True))
    print("\nDry run: nothing was written.")
    return EXIT_OK


def cmd_stage(args):
    if not args.payload:
        raise Refused("stage needs --payload (the release's recovery app and Stage 1)")
    plan, esp = gather(args)
    print(warning_text(plan))
    if not args.yes:
        if not sys.stdin.isatty():
            raise Refused("not confirmed (type UPGRADE on a terminal, or pass --yes)")
        if input("Type UPGRADE to continue: ").strip() != "UPGRADE":
            print("Nothing changed.")
            return EXIT_REFUSED
    journal = Journal(esp)
    write_request(esp, plan)
    journal.set(plan_sha256=plan.digest(), state="staging")
    with mounted(plan.stub.device, plan.stub.system.slot, args.apfuse_mount, readonly=False) as root:
        stage_system_volume(root, plan, journal)
    journal.set(state="staged")
    print("\nStaged. Shut down, then hold the power button and choose the current Aurora volume.")
    return EXIT_OK


def cmd_cancel(args):
    machine = read_machine(args.device_tree)
    esp = args.esp or esp_mountpoint(machine.esp_partuuid)
    journal = Journal(esp)
    if not journal.data["steps"]:
        print("No upgrade is staged.")
        return EXIT_OK
    req = json.loads((journal.dir / "request.json").read_text())
    disk = disk_of(f"/dev/disk/by-partuuid/{machine.esp_partuuid}")
    stubs = scan_stubs(disk, json.loads(_run("sfdisk", "--json", disk)), args.apfuse)
    mine = [s for s in stubs if s.group == req["current"]["group"]]
    if len(mine) != 1:
        raise Refused("can't find the startup container the upgrade was staged on")
    with mounted(mine[0].device, mine[0].system.slot, args.apfuse_mount, readonly=False) as root:
        cancel_system_volume(root, journal.data["steps"])
    shutil.rmtree(journal.dir)
    print("Cancelled: the startup volume is as it was.")
    return EXIT_OK


def cmd_status(args):
    machine = read_machine(args.device_tree)
    esp = args.esp or esp_mountpoint(machine.esp_partuuid)
    j = Journal(esp)
    print(json.dumps(j.data, indent=2) if j.data["steps"] else "No upgrade is staged.")
    return EXIT_OK


def cmd_finish(args):
    machine = read_machine(args.device_tree)
    esp = args.esp or esp_mountpoint(machine.esp_partuuid)
    j = Journal(esp)
    reqp = j.dir / "request.json"
    if not reqp.exists():
        return EXIT_OK
    req = json.loads(reqp.read_text())
    if machine.stub_group == req["current"]["group"]:
        print("This boot came from the old startup volume; the upgrade is still waiting.")
        return EXIT_NOT_NOW
    if not version_at_least(machine.os_firmware, req["target"]["version"]):
        raise Refused(f"this boot reports startup firmware {machine.os_firmware}, not {req['target']['version']}")
    j.set(state="done", new_group=machine.stub_group, finished=int(time.time()))
    print(f"Upgrade done: startup firmware {machine.os_firmware}, volume group {machine.stub_group}.")
    return EXIT_OK


def main(argv=None):
    share = os.environ.get("AURORA_UPGRADE_SHARE", "/usr/share/aurora-upgrade")
    ap = argparse.ArgumentParser(prog="aurora-upgrade", description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=["plan", "stage", "status", "cancel", "finish"])
    ap.add_argument("--payload", help="release payload dir: recovery/Aurora Installer.app, stage1/aura-boot.macho")
    ap.add_argument("--yes", action="store_true", help="don't ask (for scripted rows)")
    ap.add_argument("--esp", help=argparse.SUPPRESS)
    ap.add_argument("--device-tree", default="/proc/device-tree", help=argparse.SUPPRESS)
    ap.add_argument("--policy", default=f"{share}/native-policy.json", help=argparse.SUPPRESS)
    ap.add_argument("--qualification", default=f"{share}/firmware-qualification.json", help=argparse.SUPPRESS)
    ap.add_argument("--apfuse", default="apfuse", help=argparse.SUPPRESS)
    ap.add_argument("--apfuse-mount", default="apfuse-mount", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    if os.geteuid() != 0 and args.command != "plan":
        print("aurora-upgrade: run as root", file=sys.stderr)
        return EXIT_REFUSED
    lock = open("/run/aurora-upgrade.lock", "w") if os.access("/run", os.W_OK) else None
    try:
        if lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise NotNow("another aurora-upgrade is running")
        return {"plan": cmd_plan, "stage": cmd_stage, "status": cmd_status,
                "cancel": cmd_cancel, "finish": cmd_finish}[args.command](args)
    except Refused as e:
        print(f"aurora-upgrade: {e}", file=sys.stderr)
        return EXIT_REFUSED
    except NotNow as e:
        print(f"aurora-upgrade: not now: {e}", file=sys.stderr)
        return EXIT_NOT_NOW


if __name__ == "__main__":
    sys.exit(main())
