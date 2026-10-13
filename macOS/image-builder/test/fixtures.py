"""Offline fixtures: a signed candidate set and an image root built from it.

Never uses production secrets or host trust: every key is generated here, in a
temporary GnuPG home, and the trust directory the importer reads is written
beside it.
"""
from __future__ import annotations

import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "a" * 40
BOOT_SOURCE = "b" * 40
RELEASE = "7.0.0-1-ARCH"
MODELS = ("t6000-j314s", "t8103-j274")


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


candidate_set = load("candidate_set", "builder/candidate_set.py")
test_image_pin = load("test_image_pin", "builder/test_image_pin.py")
POLICY = json.loads((ROOT / "builder/candidate-trust/policy.json").read_text())

VERSIONS = {
    "omarchy": "4.0.0-1",
    "omarchy-settings": "4.0.0-1",
    "omarchy-mac": "0.1.0-1",
    "omarchy-mac-boot": "20260921-10",
    "linux-aurora": "7.0.0.aurora1-1",
    "linux-aurora-headers": "7.0.0.aurora1-1",
    "m1n1-aurora": "1.6.1.aurora1-1",
    "uboot-asahi": "2026.07.asahi2-1",
    "limine-mkinitcpio-hook": "1.39.0-2",
}


def dtb(model: str) -> bytes:
    body = f"device tree {model}".encode()
    return b"\xd0\x0d\xfe\xed" + struct.pack(">I", 8 + len(body)) + body


def default_contents() -> dict[str, dict[str, bytes]]:
    first_boot = b"#!/bin/bash\ncmp -s \"$steps\" <(printf '%s\\n' 'install/hardware/apple/limine-boot.sh')\n"
    contents = {
        "omarchy": {
            "usr/share/doc/omarchy/source-revision": (SOURCE + "\n").encode(),
            "usr/share/omarchy/install/omarchy-apple-silicon.packages": b"# Apple\nomarchy-mac\nomarchy-mac-boot\n",
            "usr/share/omarchy/install/omarchy-base.packages": b"hyprland\n",
        },
        "omarchy-settings": {
            "usr/share/doc/omarchy-settings/source-revision": (SOURCE + "\n").encode(),
            "usr/share/omarchy/default/limine/limine.conf": b"interface_branding: Omarchy Bootloader\n",
        },
        "omarchy-mac": {"usr/share/omarchy-mac/source-revision": (SOURCE + "\n").encode()},
        "omarchy-mac-boot": {
            "usr/share/omarchy-mac/boot-source-revision": (SOURCE + "\n").encode(),
            "usr/lib/omarchy/initcpio/omarchy-mac-encrypt": b"#!/bin/bash\n",
            "usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot": first_boot,
        },
        "linux-aurora": {
            f"usr/lib/modules/{RELEASE}/vmlinuz": b"MZ aurora kernel",
            f"usr/lib/modules/{RELEASE}/pkgbase": b"linux-aurora\n",
            **{f"usr/lib/modules/{RELEASE}/dtbs/{model}.dtb": dtb(model) for model in MODELS},
            f"usr/lib/modules/{RELEASE}/dtbs/s8000-n66.dtb": dtb("s8000-n66"),
        },
        "linux-aurora-headers": {f"usr/lib/modules/{RELEASE}/build/Makefile": b"# headers\n",
                                 f"usr/lib/modules/{RELEASE}/source": "build"},
        "m1n1-aurora": {"usr/lib/asahi-boot/m1n1.bin": b"m1n1 stage 1 payload"},
        "uboot-asahi": {
            "usr/lib/asahi-boot/u-boot-nodtb.bin": b"u-boot for apple silicon" * 8,
            **{f"usr/lib/asahi-boot/dtb/{model}.dtb": b"uboot " + model.encode() for model in MODELS},
        },
        "limine-mkinitcpio-hook": {"usr/share/libalpm/scripts/limine-apple-gate": b"#!/bin/bash\n"},
    }
    return contents


def depends(name: str, versions: dict[str, str]) -> list[str]:
    if name == "omarchy":
        return ["omarchy-settings=" + versions["omarchy-settings"].rsplit("-", 1)[0]]
    if name == "omarchy-mac-boot":
        return ["omarchy=" + versions["omarchy"]]
    return []


def write_archive(path: Path, name: str, version: str, files: dict[str, bytes], deps: list[str],
                  arch: str = "aarch64") -> None:
    pkginfo = "\n".join([f"pkgname = {name}", f"pkgver = {version}", f"arch = {arch}",
                         *[f"depend = {d}" for d in deps]]) + "\n"
    with tarfile.open(path, "w:xz") as archive:
        for member, data in {".PKGINFO": pkginfo.encode(), **files}.items():
            info = tarfile.TarInfo(member)
            if isinstance(data, str):
                # A symlink to TARGET.
                info.type, info.linkname = tarfile.SYMTYPE, data
                archive.addfile(info)
                continue
            info.size = len(data)
            info.mode = 0o755 if data.startswith(b"#!") else 0o644
            archive.addfile(info, io.BytesIO(data))


class Signer:
    """A throwaway signing key and the trust directory that pins it."""

    def __init__(self, base: Path, uid: str = "Candidate fixture <fixture@example.invalid>") -> None:
        # gpg-agent's socket lives in the home, and socket paths are short.
        self.home = Path(tempfile.mkdtemp(prefix="cg-", dir="/tmp"))
        base.mkdir(parents=True, exist_ok=True)
        self.gpg(["--quick-generate-key", uid, "ed25519", "sign", "1d"])
        self.fingerprint = self.gpg(["--with-colons", "--list-keys"]).decode().split("fpr:::::::::")[1].split(":")[0]
        self.trust = base / "trust"
        self.trust.mkdir()
        (self.trust / "public.asc").write_bytes(self.gpg(["--armor", "--export", self.fingerprint]))
        policy = dict(POLICY, primary_fingerprint=self.fingerprint, signing_fingerprint=self.fingerprint,
                      public_key_sha256=candidate_set.digest(self.trust / "public.asc"))
        (self.trust / "policy.json").write_text(json.dumps(policy))

    def gpg(self, args: list[str]) -> bytes:
        return subprocess.check_output(["gpg", "--homedir", str(self.home), "--batch", "--pinentry-mode", "loopback",
                                        "--passphrase", "", *args], stderr=subprocess.DEVNULL)

    def sign(self, path: Path) -> None:
        signature = Path(str(path) + ".sig")
        signature.unlink(missing_ok=True)
        self.gpg(["--local-user", self.fingerprint, "--detach-sign", "--no-armor", "-o", str(signature), str(path)])

    def close(self) -> None:
        subprocess.run(["gpgconf", "--homedir", str(self.home), "--kill", "gpg-agent"], check=False)
        shutil.rmtree(self.home, ignore_errors=True)


def channel_source(filename: str, lane: str = "edge") -> dict:
    """How the candidate-set tool records a package it took from an Omarchy channel."""
    return {"channel": f"omacom {lane} aarch64", "url": f"https://pkgs.omarchy.org/{lane}/aarch64/{filename}",
            "omacom_signature": "fixture"}


def make_set(directory: Path, signer: Signer, *, versions=None, contents=None, names=None,
             manifest_edit=None, key_signer: Signer | None = None, channel=(), arches=None) -> str:
    """Writes a signed set into DIRECTORY; returns its receipt's sha256. Packages
    named in CHANNEL, and any outside the plan (the closure), come from edge."""
    versions = dict(VERSIONS, **(versions or {}))
    contents = contents or default_contents()
    names = names or list(VERSIONS)
    arches = arches or {}
    directory.mkdir(parents=True)
    packages = []
    for name in names:
        version = versions[name]
        arch = arches.get(name, "aarch64")
        filename = f"{name}-{version.replace(':', '.')}-{arch}.pkg.tar.xz"
        write_archive(directory / filename, name, version, contents.get(name, {}), depends(name, versions), arch)
        runtime = name in POLICY["runtime_packages"]
        planned = runtime or name in POLICY["boot_packages"]
        if name in channel or not planned:
            source = channel_source(f"{name}-{version}-{arch}.pkg.tar.xz")
        else:
            source = {"repository": POLICY["source_repository"] if runtime else POLICY["boot_repository"],
                      "commit": SOURCE if runtime else BOOT_SOURCE}
        packages.append({
            "name": name, "version": version, "arch": arch, "filename": filename,
            "sha256": candidate_set.digest(directory / filename), "source": source,
        })
    manifest = {"schema": 1, "candidate_only": True, "set": "apple-test-fixture",
                "source": {"repository": POLICY["source_repository"], "commit": SOURCE}, "packages": packages}
    manifest["set_sha256"] = candidate_set.set_digest(manifest)
    if manifest_edit:
        manifest_edit(manifest)
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2))
    signing = key_signer or signer
    for package in packages:
        signing.sign(directory / package["filename"])
    receipt = {
        "schema": 1, "set": manifest["set"], "manifest_sha256": candidate_set.digest(directory / "manifest.json"),
        "set_sha256": manifest["set_sha256"],
        "signer": {"fingerprint": signing.fingerprint, "key": "candidate-signing-key.asc",
                   "key_sha256": candidate_set.digest(signing.trust / "public.asc")},
        "signatures": [{"file": p["filename"], "sha256": p["sha256"], "signature": p["filename"] + ".sig",
                        "signature_sha256": candidate_set.digest(directory / (p["filename"] + ".sig"))}
                       for p in packages],
    }
    (directory / "signing.json").write_text(json.dumps(receipt, indent=2))
    signing.sign(directory / "signing.json")
    shutil.copy(signing.trust / "public.asc", directory / "candidate-signing-key.asc")
    return candidate_set.digest(directory / "signing.json")


# ── image root ────────────────────────────────────────────────────────────
def pe_image(sections: dict[str, bytes]) -> bytes:
    """A minimal PE32+ ARM64 image holding SECTIONS, as a UKI lays them out."""
    optional_size = 240
    header_offset = 64
    table = header_offset + 24 + optional_size
    raw = table + 40 * len(sections)
    raw = (raw + 511) // 512 * 512
    header = bytearray(b"MZ" + b"\0" * 58 + struct.pack("<I", header_offset))
    header += b"PE\0\0" + struct.pack("<HHIIIHH", 0xAA64, len(sections), 0, 0, 0, optional_size, 0x22)
    header += struct.pack("<H", 0x20B) + b"\0" * (optional_size - 2)
    body = b""
    entries = b""
    for name, data in sections.items():
        entries += name.encode().ljust(8, b"\0") + struct.pack("<IIII", len(data), 0, len(data), raw + len(body))
        entries += b"\0" * 16
        body += data
    image = bytes(header) + entries
    return image.ljust(raw, b"\0") + body


def initramfs(members: dict[str, bytes | str]) -> bytes:
    """A newc cpio: bytes are files (executable), str are symlink targets."""
    with tempfile.TemporaryDirectory() as scratch:
        base = Path(scratch)
        for name, value in members.items():
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(value, str):
                path.symlink_to(value)
            else:
                path.write_bytes(value)
                path.chmod(0o755)
        names = sorted(members)
        return subprocess.run(["bsdtar", "--format", "newc", "-cf", "-", "-C", scratch, *names],
                              check=True, capture_output=True).stdout


PLYMOUTH_CONFIG = b"[Daemon]\nTheme=omarchy\n# Administrator customizations go in this file\n#[Daemon]\n#Theme=fade-in\n"
PLYMOUTH_DEFAULTS = b"# Distribution defaults.\n[Daemon]\nTheme=bgrt\nShowDelay=0\n"
SPLASH = "quiet splash loglevel=0 plymouth.ignore-serial-consoles"


def plymouth_members(config: bytes | None = PLYMOUTH_CONFIG, theme: bool = True) -> dict[str, bytes]:
    """What mkinitcpio's plymouth hook adds: the configuration, the packaged
    defaults and the chosen theme."""
    members = {"usr/share/plymouth/plymouthd.defaults": PLYMOUTH_DEFAULTS}
    if config is not None:
        members["etc/plymouth/plymouthd.conf"] = config
    if theme:
        members["usr/share/plymouth/themes/omarchy/omarchy.plymouth"] = b"[Plymouth Theme]\nModuleName=script\n"
    return members


def good_initramfs(plymouth: dict[str, bytes] | None = None) -> bytes:
    limine = load("apple_limine", "builder/apple_limine.py")
    members: dict[str, bytes | str] = {name: b"#!/bin/sh\n" for name in limine.INITRD_FILES}
    members.update(limine.INITRD_LINKS)
    members.update(plymouth_members() if plymouth is None else plymouth)
    return initramfs(members)


def write(root: Path, relative: str, data: bytes | str, mode: int = 0o644) -> Path:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())
    path.chmod(mode)
    return path


def local_package(root: Path, name: str, version: str, files: list[str]) -> None:
    entry = root / "var/lib/pacman/local" / f"{name}-{version}"
    entry.mkdir(parents=True, exist_ok=True)
    (entry / "desc").write_text(f"%NAME%\n{name}\n\n%VERSION%\n{version}\n\n")
    (entry / "files").write_text("%FILES%\n" + "".join(f + "\n" for f in files) + "\n")
    mtree = "#mtree\n" + "".join(
        f"./{f} time=1.0 size={(root / f).stat().st_size} "
        f"sha256digest={hashlib.sha256((root / f).read_bytes()).hexdigest()}\n"
        for f in files if (root / f).is_file())
    (entry / "mtree").write_bytes(gzip.compress(mtree.encode()))


def import_set(set_dir: Path, output: Path, signer: Signer, receipt: str) -> dict:
    return candidate_set.snapshot(set_dir, output, receipt, SOURCE, trust=signer.trust)


# The build identity build-mac-image appends to the image-target manifest.
PACKAGE_SET_SHA256 = "9" * 64
BUILT = "2026-09-28T03:04:05Z"


def image_target(summary: dict, profile: str = "test") -> str:
    """The image-target manifest build-mac-image writes for SUMMARY's set."""
    return (f"format=1\nplatform=apple-silicon\ncandidate_set={summary['set']}\n"
            f"candidate_source_commit={summary['source_commit']}\nbuilder_commit={'c' * 40}\n"
            f"builder_tree_clean=true\nimage_profile={profile}\n"
            f"package_set_sha256={PACKAGE_SET_SHA256}\nbuilt={BUILT}\n")


def make_root(root: Path, candidates: Path) -> None:
    """An image root that passes inspection against the imported set CANDIDATES."""
    summary = json.loads((candidates / "import.json").read_text())

    def member(name: str, path: str) -> bytes:
        archive = candidates / next(p["filename"] for p in summary["packages"] if p["name"] == name)
        return subprocess.check_output(["bsdtar", "-xOf", str(archive), path])

    # Every set package's files, as pacman installed them.
    root.mkdir(parents=True, exist_ok=True)
    for package in summary["packages"]:
        subprocess.run(["bsdtar", "-xf", str(candidates / package["filename"]), "-C", str(root),
                        "--exclude", ".PKGINFO"], check=True)
    uuid = "4f4d5801-524f-4f54-8000-000000000001"
    cmdline = f"root=UUID={uuid} rootflags=subvol=@ rw rootfstype=btrfs {SPLASH}"
    write(root, "etc/fstab", f"UUID={uuid} / btrfs noatime,subvol=@ 0 0\n")
    write(root, "etc/default/limine", f'KERNEL_CMDLINE[default]="{cmdline}"\n')
    write(root, "usr/lib/os-release", b'NAME="Arch Linux ARM"\nVERSION_ID=rolling\n')
    (root / "etc/os-release").symlink_to("../usr/lib/os-release")
    kernel = member("linux-aurora", f"usr/lib/modules/{RELEASE}/vmlinuz")
    for path in (f"usr/lib/modules/{RELEASE}/vmlinuz", f"usr/lib/modules/{RELEASE}/pkgbase",
                 *[f"usr/lib/modules/{RELEASE}/dtbs/{m}.dtb" for m in (*MODELS, "s8000-n66")]):
        write(root, path, member("linux-aurora", path))
    m1n1 = member("m1n1-aurora", "usr/lib/asahi-boot/m1n1.bin")
    uboot = member("uboot-asahi", "usr/lib/asahi-boot/u-boot-nodtb.bin")
    write(root, "usr/lib/asahi-boot/m1n1.bin", m1n1)
    write(root, "usr/lib/asahi-boot/u-boot-nodtb.bin", uboot)
    dtbs = sorted((f"{m}.dtb" for m in (*MODELS, "s8000-n66")), key=str.encode)
    stage2 = m1n1 + b"".join(dtb(name.removesuffix(".dtb")) for name in dtbs)
    compressor = zlib.compressobj(wbits=31)
    stage2 += compressor.compress(uboot) + compressor.flush() + b"chosen.asahi,efi-system-partition=EFI\n"
    write(root, "boot/efi/m1n1/boot.bin", stage2)
    write(root, "etc/m1n1.conf", "# m1n1 options\nchosen.asahi,efi-system-partition=EFI\nunknown=ignored\n")
    loader = pe_image({".text": b"Limine loader"})
    write(root, "usr/share/limine/BOOTAA64.EFI", loader)
    write(root, "boot/efi/EFI/BOOT/BOOTAA64.EFI", loader)
    osrel = b"VERSION_ID=" + RELEASE.encode() + b"\n" + b'NAME="Arch Linux ARM"\n'
    uki = pe_image({".osrel": osrel, ".cmdline": cmdline.encode() + b" \n\0", ".uname": RELEASE.encode(),
                    ".initrd": good_initramfs(), ".linux": kernel})
    write(root, "boot/efi/EFI/Linux/omarchy_linux-aurora.efi", uki)
    digest = hashlib.blake2b(uki).hexdigest()
    write(root, "boot/efi/limine.conf", "interface_branding: Omarchy Bootloader\n\n/+Omarchy\n//linux-aurora\n"
          f"    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-aurora.efi#{digest}\n")
    (root / "boot/efi/omarchy").mkdir(parents=True)
    limine = load("apple_limine", "builder/apple_limine.py")
    owners: dict[str, list[str]] = {}
    for rel, (owner, lines) in limine.MAINTENANCE_HOOKS.items():
        write(root, rel, "[Action]\n" + "\n".join(lines) + "\n")
        if owner:
            owners.setdefault(owner, []).append(rel)
    for rel, owner in limine.MAINTENANCE_HELPERS.items():
        write(root, rel, "#!/bin/bash\n", 0o755)
        owners.setdefault(owner, []).append(rel)
    owners.setdefault("limine", []).append("usr/share/limine/BOOTAA64.EFI")
    versions = {p["name"]: p["version"] for p in summary["packages"]}
    others = {name: "1.0-1" for name in ("limine", "limine-snapper-sync", "asahi-fwextract", "speakersafetyd",
                                         "alsa-ucm-conf-asahi", "asahi-audio", "vulkan-asahi", "asahi-bless", "iwd",
                                         "networkmanager", "bluez", "wireplumber")}
    for name, version in {**versions, **others}.items():
        local_package(root, name, version, owners.get(name, []))
    state = root / "var/lib/omarchy"
    write(root, "var/lib/omarchy/image/target", image_target(summary))
    (state / "image").chmod(0o755)
    write(root, "var/lib/omarchy/mac-first-boot/pending", b"")
    write(root, "var/lib/omarchy/mac-first-boot/deferred-steps", "install/hardware/apple/limine-boot.sh\n")
    write(root, "var/lib/omarchy/provisioning/pending", b"")
    write(root, "var/lib/omarchy/limine.enabled", b"")
    write(root, "usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot",
          member("omarchy-mac-boot", "usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot"), 0o755)
    wants = root / "etc/systemd/system/multi-user.target.wants"
    wants.mkdir(parents=True, exist_ok=True)
    for unit in ("omarchy-mac-first-boot.service", "omarchy-provision-owner.service"):
        (wants / unit).symlink_to(f"/usr/lib/systemd/system/{unit}")
    template = "[options]\nArchitecture = auto\n\n[asahi-alarm]\nServer = https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64\n"
    template += "".join(f"\n[{r}]\nInclude = /etc/pacman.d/mirrorlist\n" for r in ("core", "extra", "alarm", "aur"))
    template += "\n[omarchy]\nServer = https://pkgs.omarchy.org/edge/$arch\n"
    write(root, "usr/share/omarchy/default/pacman/aarch64/pacman-edge.conf", template)
    write(root, "usr/share/omarchy/default/pacman/aarch64/mirrorlist-edge", "Server = https://mirror.invalid/$arch/$repo\n")
    write(root, "etc/pacman.conf", test_image_pin.render(template.encode(), test_image_pin.pinned(summary)))
    write(root, "etc/pacman.d/mirrorlist", "Server = https://mirror.invalid/$arch/$repo\n")
    # What the installed-system checks read.
    write(root, "usr/lib/NetworkManager/conf.d/20-omarchy-mac-wifi.conf", "[device]\nwifi.backend=iwd\n")
    write(root, "etc/systemd/system/omarchy-vendor-firmware.service",
          "[Service]\nExecStart=/usr/bin/tar -xf /boot/efi/vendorfw/firmware.tar\n")
    for unit, where in (("NetworkManager.service", "/usr/lib/systemd/system/NetworkManager.service"),
                        ("omarchy-vendor-firmware.service", "/etc/systemd/system/omarchy-vendor-firmware.service"),
                        ("speakersafetyd.service", "/usr/lib/systemd/system/speakersafetyd.service")):
        (wants / unit).symlink_to(where)
    (root / "etc/systemd/system/dbus-org.bluez.service").symlink_to("/usr/lib/systemd/system/bluetooth.service")
    write(root, "usr/share/omarchy/version", "4.0.0\n")
    for rel, data in plymouth_members().items():
        write(root, rel, data)
    # Snapper's root configuration and its /.snapshots, which a real image
    # carries as a btrfs subvolume (the tests say which paths count as one).
    write(root, "etc/snapper/configs/root", 'SUBVOLUME="/"\nFSTYPE="btrfs"\n', 0o640)
    (root / ".snapshots").mkdir(mode=0o750)


def make_factory(factory: Path, root: Path, summary: dict) -> None:
    """The @factory a build seals from ROOT."""
    shutil.copytree(root, factory, symlinks=True)
    for rel in ("var/lib/omarchy/mac-first-boot", "var/lib/omarchy/provisioning/pending"):
        path = factory / rel
        shutil.rmtree(path) if path.is_dir() else path.unlink()
    write(factory, "var/lib/omarchy/factory-sealed",
          f"format=2\ncandidate_set={summary['set']}\ncandidate_source_commit={summary['source_commit']}\n")


def owner_uid() -> int:
    return os.geteuid()
