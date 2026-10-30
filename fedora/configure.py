#!/usr/bin/env python3
"""Prepare an Aurora-owned KIWI description from a pinned Fedora base."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
PROFILES = {
    "fedora-kde": "Workstation-KDE",
    "fedora-gnome": "Workstation-GNOME",
    "fedora-minimal": "Minimal",
}
# The RPM producer must implement these Fedora-native package contracts.
PACKAGES = {
    "components/boot.xml": ("BootCore", [
        "kernel-aurora", "kernel-aurora-modules-extra", "aura", "uboot-aurora",
    ]),
    "components/base.xml": ("Common", [
        "aurora-release", "aurora-logos", "aurora-platform", "aurora-remix-scripts",
        "aurora-firmware", "alsa-ucm-conf-aurora", "aurora-audio", "speakerguardd",
    ]),
    "components/desktop-environments.xml": ("DesktopCommon", [
        "mesa-aurora-dri-drivers", "mesa-aurora-vulkan-drivers",
    ]),
}
REPLACED = {
    "kernel-16k", "kernel-16k-modules-extra", "uboot-images-armv8",
    "asahi-platform-metapackage", "asahi-repos", "fedora-asahi-remix-scripts",
    "alsa-ucm-asahi", "mesa-dri-drivers", "mesa-vulkan-drivers",
    "fedora-release", "fedora-release-workstation", "fedora-release-kde",
}


def git(source, *args):
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def signing_fingerprint(key):
    with tempfile.TemporaryDirectory(prefix="aurora-rpm-key-") as home:
        output = subprocess.check_output([
            "gpg", "--no-options", "--homedir", home, "--batch", "--with-colons",
            "--show-keys", str(Path(key).resolve()),
        ], stderr=subprocess.PIPE, text=True)
    fingerprints = [line.split(":")[9] for line in output.splitlines()
                    if line.startswith("fpr:")]
    if not fingerprints:
        raise ValueError("the repository signing key contains no OpenPGP fingerprint")
    return fingerprints[0]


def write_xml(tree, path):
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def prepare(source, destination, profile, repository_url, key, fingerprint, lock):
    source, destination, key = map(Path, (source, destination, key))
    if profile not in PROFILES:
        raise ValueError("unknown Fedora installation profile")
    if destination.exists():
        raise ValueError("output already exists; use a fresh description directory")
    if source.resolve() in destination.resolve().parents:
        raise ValueError("output must be outside the upstream checkout")
    if git(source, "rev-parse", "HEAD") != lock["commit"]:
        raise ValueError("upstream checkout does not match the pinned commit")
    if git(source, "status", "--porcelain"):
        raise ValueError("upstream checkout is not clean")
    url = urllib.parse.urlsplit(repository_url)
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.query or url.fragment or any(c.isspace() for c in repository_url)):
        raise ValueError("repository URL must be an HTTPS base URL without credentials or query")
    if not key.is_file() or key.is_symlink():
        raise ValueError("repository signing key must be a regular file")
    fingerprint = fingerprint.upper()
    if not re.fullmatch(r"(?:[0-9A-F]{40}|[0-9A-F]{64})", fingerprint):
        raise ValueError("invalid repository signing-key fingerprint")
    if signing_fingerprint(key) != fingerprint:
        raise ValueError("repository signing-key fingerprint does not match")

    destination.mkdir(parents=True)
    for name in ("components", "platforms", "repositories", "root"):
        shutil.copytree(source / name, destination / name)
    for name in ("config.xml", "config.sh", "post_bootstrap.sh", "pre_disk_sync.sh", "COPYING"):
        shutil.copy2(source / name, destination / name)

    # No Asahi kernel, bootloader or branding repository can replace Aurora RPMs.
    (destination / "repositories/asahi.xml").unlink()
    for path in destination.rglob("*.xml"):
        tree = ET.parse(path)
        for parent in tree.iter():
            if parent.tag == "type" and parent.get("image") == "oem":
                parent.set("rootfs_label", "AURORA_ROOT")
            if parent.tag == "systemdisk":
                parent.set("name", "aurora")
            for node in list(parent):
                if node.tag == "package" and node.get("name") in REPLACED:
                    parent.remove(node)
                if node.tag == "ignore" and node.get("name") in {"generic-release*", "generic-logos*"}:
                    parent.remove(node)
        write_xml(tree, path)

    tree = ET.parse(destination / "config.xml")
    image = tree.getroot()
    image.set("name", "Fedora-Aurora-Remix")
    image.set("displayname", "Fedora Aurora Remix")
    image.find("description/author").text = "Aurora Silicon"
    image.find("description/contact").text = "https://github.com/aurora-silicon/aurora-installer"
    image.find("description/specification").text = "Fedora Aurora Remix for Apple Silicon"
    image.find("preferences/release-version").text = lock["fedora_release"]
    for node in image.findall("include"):
        if node.get("from") == "this://./repositories/asahi.xml":
            node.set("from", "this://./repositories/aurora.xml")
    write_xml(tree, destination / "config.xml")

    for name, (selected_profile, packages) in PACKAGES.items():
        path = destination / name
        tree = ET.parse(path)
        group = ET.SubElement(tree.getroot(), "packages", {
            "type": "image", "profiles": selected_profile,
        })
        for package in packages:
            ET.SubElement(group, "package", {"name": package})
        write_xml(tree, path)

    key_bytes = key.read_bytes()
    key_name = "RPM-GPG-KEY-aurora"
    key_dir = destination / "root/etc/pki/rpm-gpg"
    key_dir.mkdir(parents=True, exist_ok=True)
    (key_dir / key_name).write_bytes(key_bytes)
    # KIWI resolves description-local signing keys before the root filesystem exists.
    (destination / key_name).write_bytes(key_bytes)
    repository = ET.Element("image")
    node = ET.SubElement(repository, "repository", {
        "type": "rpm-md", "alias": "aurora", "sourcetype": "baseurl", "priority": "1",
    })
    origin = ET.SubElement(node, "source", {"path": repository_url.rstrip("/")})
    ET.SubElement(origin, "signing", {"key": "this://" + key_name})
    write_xml(ET.ElementTree(repository), destination / "repositories/aurora.xml")
    repo_dir = destination / "root/etc/yum.repos.d"
    repo_dir.mkdir(parents=True, exist_ok=True)
    (repo_dir / "aurora.repo").write_text(
        "[aurora]\nname=Aurora Silicon for Fedora\n"
        f"baseurl={repository_url.rstrip('/')}\nenabled=1\n"
        f"gpgcheck=1\nrepo_gpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/{key_name}\npriority=1\n"
    )
    # Sleep/restore quirk: re-commit panel state and keyboard backlight across
    # suspend on Apple Silicon Macs (J616s post-wake brightness/contrast
    # desync; keyboard backlight lit during Sleep). Generic: Apple-gated,
    # sysfs-driven, no machine-specific values.
    hook_dir = destination / "root/usr/lib/systemd/system-sleep"
    hook_dir.mkdir(parents=True, exist_ok=True)
    hook_path = hook_dir / "aurora-display-restore"
    hook_path.write_text((HERE / "files" / "aurora-sleep-restore").read_text())
    hook_path.chmod(0o755)
    config = destination / "config.sh"
    text = config.read_text()
    if "kernel-16k-core" not in text:
        raise ValueError("upstream kernel selection changed; review the integration")
    config.write_text(text.replace("kernel-16k-core", "kernel-aurora-core"))
    receipt = {
        "schema": 1, "distribution": "Fedora Aurora Remix",
        "fedora_release": lock["fedora_release"], "architecture": "aarch64",
        "installation_profile": profile, "kiwi_profile": PROFILES[profile],
        "upstream": lock, "repository_url": repository_url.rstrip("/"),
        "signing_key_fingerprint": fingerprint,
        "signing_key_sha256": hashlib.sha256(key_bytes).hexdigest(),
        "layout": {"kind": "fedora-btrfs-v1", "partitions": ["esp", "boot", "root"],
                   "boot_filesystem": "ext4", "root_filesystem": "btrfs",
                   "root_label": "AURORA_ROOT",
                   "root_subvolume": "root", "home_subvolume": "home",
                   "boot_manager": "grub2", "initramfs": "dracut"},
        "packages": {name: packages for name, (_, packages) in PACKAGES.items()},
        "build_command": ["kiwi-ng", "--target-arch=aarch64", "--type=oem", f"--profile={PROFILES[profile]}",
                          "system", "build", "--description", str(destination.resolve()),
                          "--target-dir", str(destination.resolve().with_name(destination.name + "-image"))],
        "image_built": False,
    }
    (destination / "aurora-image.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=PROFILES, default="fedora-kde")
    parser.add_argument("--repository-url", required=True)
    parser.add_argument("--signing-key", type=Path, required=True)
    parser.add_argument("--signing-key-fingerprint", required=True)
    args = parser.parse_args()
    try:
        receipt = prepare(args.upstream, args.output, args.profile, args.repository_url,
                          args.signing_key, args.signing_key_fingerprint,
                          json.loads((HERE / "upstream.json").read_text()))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
