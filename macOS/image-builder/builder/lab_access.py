"""Lab access for test images, and the scan that keeps it out of every other image.

A lab image lets the lab controller reach a freshly installed test Mac without
anyone at it: the controller's public SSH keys for one user, passwordless sudo
and polkit for that user, sshd enabled, SSH open in the firewall, and a fixed
Thunderbolt bridge address per test Mac model. It carries no secret: test
images are downloadable, so enrollment credentials (Tailscale) travel over SSH
after the first boot, never in the image.

`render` is the overlay the builder writes and a lab inspection expects byte
for byte. `findings` is content-based and does not trust the overlay's own
marker: it finds lab access however it got into a tree (renamed files, no
profile record), and a release inspection refuses any finding.

    lab_access.py validate DIR        prints user= and access_sha256= for DIR
    lab_access.py apply DIR ROOT      writes the overlay for DIR into ROOT
"""
from __future__ import annotations

import base64
import hashlib
import os
from pathlib import Path
import re
import stat
import sys

PROFILE = "etc/omarchy-lab/profile"
UNIT = "etc/systemd/system/omarchy-lab-access.service"
ENABLE_LINKS = {
    "etc/systemd/system/multi-user.target.wants/sshd.service": "/usr/lib/systemd/system/sshd.service",
    "etc/systemd/system/multi-user.target.wants/omarchy-lab-access.service": "/" + UNIT,
}
KEY_TYPES = ("ssh-ed25519", "sk-ssh-ed25519@openssh.com", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
             "ecdsa-sha2-nistp521", "sk-ecdsa-sha2-nistp256@openssh.com")
USER = re.compile(r"[a-z_][a-z0-9_-]{0,30}")
THUNDERBOLT = re.compile(r"([^|\n]+)\|(10\.\d{1,3}\.\d{1,3}\.\d{1,3}/(?:2[4-9]|30))")
# Credentials that must never be in any image, lab or not.
SECRET_MARKERS = (b"tskey-", b"PRIVATE KEY-----")
SECRET_SCAN_DIRS = ("etc", "root", "home", "var/lib", "var/log", "usr/local", "opt", "srv", "boot")
SECRET_SCAN_LIMIT = 1 << 20
SKIPPED = ("proc", "sys", "dev", "run", "tmp")

ACCESS_SCRIPT = """#!/bin/bash
# Lab test image only (omarchy-lab-access.service, every boot): keep SSH open
# in the firewall and give this Mac's Thunderbolt bridge its fixed lab address.
set -u
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null || echo "omarchy-lab-access: ufw allow 22/tcp failed" >&2
fi
model=$(tr -d '\\0' </proc/device-tree/model 2>/dev/null) || model=""
address=""
while IFS='|' read -r pattern candidate; do
  [[ -n $pattern && $model == $pattern ]] || continue
  address=$candidate
  break
done </etc/omarchy-lab/thunderbolt
profile=/etc/NetworkManager/system-connections/lab-thunderbolt.nmconnection
if [[ -n $address && ! -e $profile ]]; then
  (umask 077 && cat >"$profile") <<PROFILE
[connection]
id=lab-thunderbolt
type=ethernet
interface-name=thunderbolt0
autoconnect=true

[ipv4]
method=manual
address1=$address
never-default=true

[ipv6]
method=disabled
PROFILE
  nmcli connection reload 2>/dev/null || true
fi
exit 0
"""

UNIT_TEXT = """[Unit]
Description=Lab test image access (SSH in the firewall, Thunderbolt bridge address)
After=ufw.service NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/omarchy-lab-access

[Install]
WantedBy=multi-user.target
"""


class LabAccessError(ValueError):
    pass


def require(ok: bool, message: str) -> None:
    if not ok:
        raise LabAccessError(message)


def parse_keys(text: str) -> list[str]:
    """The authorized_keys lines: public keys only, no options, no secrets."""
    keys = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        require(len(fields) in (2, 3) and fields[0] in KEY_TYPES,
                f"not a public key line of an allowed type: {line[:40]}")
        try:
            blob = base64.b64decode(fields[1], validate=True)
        except ValueError:
            raise LabAccessError(f"not a base64 public key: {line[:40]}") from None
        require(blob[4:4 + len(fields[0])] == fields[0].encode(), f"the key blob is not {fields[0]}: {line[:40]}")
        keys.append(" ".join(fields))
    require(keys, "no public keys")
    require(len(set(keys)) == len(keys), "a key is listed twice")
    return keys


def parse_thunderbolt(text: str) -> list[tuple[str, str]]:
    entries = []
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        match = THUNDERBOLT.fullmatch(line.strip())
        require(match is not None, f"not a MODEL-GLOB|10.x.y.z/NN line: {line[:60]}")
        entries.append((match[1], match[2]))
    return entries


def load(directory: Path) -> dict:
    """The access a lab image grants, from DIR: authorized_keys, user, thunderbolt."""
    require(directory.is_dir(), f"{directory} is not a directory")
    for path in directory.iterdir():
        require(path.name in ("authorized_keys", "user", "thunderbolt"), f"{path.name} is not a lab access file")
        require(path.is_file() and not path.is_symlink(), f"{path.name} is not a regular file")
        body = path.read_bytes()
        require(not any(marker in body for marker in SECRET_MARKERS), f"{path.name} holds a secret")
    user = (directory / "user").read_text().strip() if (directory / "user").exists() else "maralc"
    require(USER.fullmatch(user) is not None and user != "root", f"not a lab user name: {user!r}")
    keys = parse_keys((directory / "authorized_keys").read_text())
    thunderbolt = parse_thunderbolt((directory / "thunderbolt").read_text()) \
        if (directory / "thunderbolt").exists() else []
    return {"user": user, "keys": keys, "thunderbolt": thunderbolt}


def render(access: dict) -> dict[str, tuple[int, bytes]]:
    """Every file of the overlay, by root-relative path: (mode, bytes)."""
    user = access["user"]
    keys = "".join(f"{key}\n" for key in access["keys"])
    thunderbolt = "".join(f"{pattern}|{address}\n" for pattern, address in access["thunderbolt"])
    files = {
        f"etc/omarchy-lab/authorized_keys/{user}": (0o644, keys.encode()),
        "etc/omarchy-lab/thunderbolt": (0o644, thunderbolt.encode()),
        "etc/ssh/sshd_config.d/40-omarchy-lab.conf": (
            0o644, b"AuthorizedKeysFile .ssh/authorized_keys /etc/omarchy-lab/authorized_keys/%u\n"),
        "etc/sudoers.d/omarchy-lab": (0o440, f"{user} ALL=(ALL) NOPASSWD: ALL\n".encode()),
        "etc/polkit-1/rules.d/49-omarchy-lab.rules": (0o644, (
            "polkit.addRule(function(action, subject) {\n"
            f'  if (subject.user == "{user}") {{\n'
            "    return polkit.Result.YES;\n"
            "  }\n"
            "});\n").encode()),
        "usr/local/libexec/omarchy-lab-access": (0o755, ACCESS_SCRIPT.encode()),
        UNIT: (0o644, UNIT_TEXT.encode()),
    }
    digest = access_sha256(files)
    files[PROFILE] = (0o644, f"format=1\nuser={user}\naccess_sha256={digest}\n".encode())
    return files


def access_sha256(files: dict[str, tuple[int, bytes]]) -> str:
    listing = "".join(f"{path}|{mode:o}|{hashlib.sha256(body).hexdigest()}\n"
                      for path, (mode, body) in sorted(files.items()) if path != PROFILE)
    return hashlib.sha256(listing.encode()).hexdigest()


def apply(access: dict, root: Path) -> str:
    """Writes the overlay into ROOT, root-owned; returns its access_sha256."""
    files = render(access)
    for relative, (mode, body) in files.items():
        path = root / relative
        for parent in reversed(path.relative_to(root).parents[:-1]):
            directory = root / parent
            if not directory.exists():
                directory.mkdir()
                os.chmod(directory, 0o755)
        require(not path.is_symlink(), f"/{relative} is a symlink")
        partial = path.with_name(f".{path.name}.partial")
        partial.write_bytes(body)
        os.chmod(partial, mode)
        os.replace(partial, path)
    for link, destination in ENABLE_LINKS.items():
        path = root / link
        require((root / destination.lstrip("/")).is_file(), f"{destination} is not in the image")
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink() or path.exists():
            path.unlink()
        path.symlink_to(destination)
    if os.geteuid() == 0:
        for relative in list(files) + list(ENABLE_LINKS):
            os.lchown(root / relative, 0, 0)
    return access_sha256(files)


# ── the scan ──────────────────────────────────────────────────────────────
def walk(root: Path, top: str = ""):
    """Every path below ROOT/TOP (not following symlinks), root-relative."""
    start = root / top
    if not start.is_dir() or start.is_symlink():
        return
    for directory, subdirectories, files in os.walk(start):
        relative = os.path.relpath(directory, root)
        if relative.split(os.sep)[0] in SKIPPED:
            subdirectories[:] = []
            continue
        for name in subdirectories + files:
            yield "" if relative == "." else relative, name


def read_small(path: Path) -> bytes:
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > SECRET_SCAN_LIMIT:
            return b""
        return path.read_bytes()
    except OSError:
        return b""


def config_lines(body: bytes) -> list[str]:
    return [line.strip() for line in body.decode(errors="replace").splitlines()
            if line.strip() and not line.strip().startswith("#")]


def findings(root: Path) -> list[tuple[str, str, bool]]:
    """Lab access and credentials in ROOT: (path, what, always_refused).

    Content-based and marker-independent. always_refused marks what no image,
    lab or not, may carry (credentials, disk key files)."""
    found: list[tuple[str, str, bool]] = []
    for relative, name in walk(root):
        path = f"{relative}/{name}" if relative else name
        lowered = name.lower()
        if "omarchy-lab" in lowered or "lab-thunderbolt" in lowered:
            found.append((path, "a lab file", False))
        if lowered.startswith("authorized_keys"):
            found.append((path, "an authorized_keys file", False))
        if relative.split(os.sep)[:2] == ["etc", "cryptsetup-keys.d"]:
            found.append((path, "a disk key file", True))
    ssh = root / "etc/ssh"
    for config in [ssh / "sshd_config", *sorted((ssh / "sshd_config.d").glob("*"))]:
        for line in config_lines(read_small(config)):
            words = line.split()
            key = words[0].lower()
            if key == "authorizedkeysfile" and words[1:] != [".ssh/authorized_keys"]:
                found.append((str(config.relative_to(root)), "an AuthorizedKeysFile override", False))
            if key == "authorizedkeyscommand" and words[1:] != ["/usr/bin/userdbctl", "ssh-authorized-keys", "%u"]:
                found.append((str(config.relative_to(root)), "an AuthorizedKeysCommand", False))
            if key in ("trustedusercakeys", "authorizedprincipalsfile", "authorizedprincipalscommand"):
                found.append((str(config.relative_to(root)), f"an sshd {words[0]}", False))
    sudoers = root / "etc"
    for config in [sudoers / "sudoers", *sorted((sudoers / "sudoers.d").glob("*"))]:
        for line in config_lines(read_small(config)):
            if re.search(r"NOPASSWD:(\s*[A-Z_]+:)*\s*ALL\s*$", line) or "!authenticate" in line:
                found.append((str(config.relative_to(root)), "a passwordless sudo grant for every command", False))
    # Packages ship group rules without an action (systemd's empower.rules);
    # a rule for one named user, or any local one, is lab access.
    for directory in ("etc/polkit-1/rules.d", "usr/share/polkit-1/rules.d"):
        for rules in sorted((root / directory).glob("*.rules")):
            body = read_small(rules)
            if (b"polkit.Result.YES" in body and b"action.id" not in body
                    and (directory.startswith("etc") or re.search(rb"\.user\s*===?", body))):
                found.append((str(rules.relative_to(root)), "a polkit rule granting every action", False))
    # sshd enabled any way: a .wants link (service, socket, template) or a preset.
    for directory in ("etc/systemd/system", "usr/lib/systemd/system"):
        for link in sorted((root / directory).glob("*.wants/sshd*")):
            found.append((str(link.relative_to(root)), "sshd enabled", False))
    for directory in ("etc/systemd/system-preset", "usr/lib/systemd/system-preset"):
        for preset in sorted((root / directory).glob("*.preset")):
            if any(re.fullmatch(r"enable\s+sshd\S*", line) for line in config_lines(read_small(preset))):
                found.append((str(preset.relative_to(root)), "sshd enabled by a preset", False))
    for mkinitcpio in [root / "etc/mkinitcpio.conf", *sorted((root / "etc/mkinitcpio.conf.d").glob("*"))]:
        for line in config_lines(read_small(mkinitcpio)):
            if line.startswith("FILES") and ".key" in line:
                found.append((str(mkinitcpio.relative_to(root)), "a key file in the initramfs", True))
    for top in SECRET_SCAN_DIRS:
        for relative, name in walk(root, top):
            path = f"{relative}/{name}"
            body = read_small(root / path)
            if body and any(marker in body for marker in SECRET_MARKERS):
                found.append((path, "a credential", True))
    return sorted(set(found))


def initramfs_findings(members: list[str], contents: bytes) -> list[tuple[str, str, bool]]:
    """Lab access, key files or credentials in an initramfs: its member paths and bytes."""
    found = []
    for member in members:
        name = member.rsplit("/", 1)[-1].lower()
        if name.startswith("authorized_keys") or "omarchy-lab" in member:
            found.append((member, "lab access in the initramfs", False))
        if "cryptsetup-keys.d/" in member or name.endswith(".key"):
            found.append((member, "a key file in the initramfs", True))
    for marker in SECRET_MARKERS:
        if marker in contents:
            found.append((marker.decode(), "a credential in the initramfs", True))
    return found


def check(root: Path, where: str, lab: bool) -> str:
    """Refuses lab access in a release tree (returns ""); in a lab tree, requires
    exactly the overlay and returns its access_sha256."""
    found = findings(root)
    if not lab:
        require(not found, f"{where} carries lab access or credentials: "
                + "; ".join(f"/{path} ({what})" for path, what, _ in found))
        return ""
    always = [f"/{path} ({what})" for path, what, refused in found if refused]
    require(not always, f"{where} carries credentials: " + "; ".join(always))
    profile = root / PROFILE
    require(profile.is_file() and not profile.is_symlink(), f"{where} has no /{PROFILE}")
    fields = dict(line.split("=", 1) for line in profile.read_text().splitlines() if "=" in line)
    user = fields.get("user", "")
    require(USER.fullmatch(user) is not None, f"{where} names no lab user")
    access = {
        "user": user,
        "keys": parse_keys((root / f"etc/omarchy-lab/authorized_keys/{user}").read_text()),
        "thunderbolt": parse_thunderbolt((root / "etc/omarchy-lab/thunderbolt").read_text()),
    }
    expected = render(access)
    for relative, (mode, body) in expected.items():
        path = root / relative
        require(path.is_file() and not path.is_symlink(), f"{where} lacks /{relative}")
        info = path.lstat()
        require(stat.S_IMODE(info.st_mode) == mode and path.read_bytes() == body,
                f"{where}'s /{relative} is not the lab overlay's")
        require(info.st_uid == 0 or os.geteuid() != 0, f"{where}'s /{relative} is not root-owned")
    for link, destination in ENABLE_LINKS.items():
        path = root / link
        require(path.is_symlink() and os.readlink(path) == destination, f"{where}'s /{link} is not the lab enable link")
    allowed = set(expected) | set(ENABLE_LINKS) | {"etc/omarchy-lab", "etc/omarchy-lab/authorized_keys"}
    extra = [f"/{path} ({what})" for path, what, _ in found if path not in allowed]
    require(not extra, f"{where} carries lab access outside the overlay: " + "; ".join(extra))
    digest = access_sha256(expected)
    require(fields.get("access_sha256") == digest, f"{where}'s lab profile records another access digest")
    return digest


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[1] == "validate":
            access = load(Path(argv[2]))
            print(f"user={access['user']}\naccess_sha256={access_sha256(render(access))}")
        elif len(argv) == 4 and argv[1] == "apply":
            print(apply(load(Path(argv[2])), Path(argv[3])))
        else:
            print(__doc__.split("\n\n")[-1], file=sys.stderr)
            return 64
    except (LabAccessError, OSError) as error:
        print(f"lab_access: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
