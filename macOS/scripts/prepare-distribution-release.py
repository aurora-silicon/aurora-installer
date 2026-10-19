#!/usr/bin/env python3
"""Verify distribution deliveries and assemble native packaging resources."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROFILES = tuple(f"{distribution}-{desktop}" for distribution in ("fedora", "arch", "nixos")
                 for desktop in ("kde", "gnome", "minimal"))


def prepare(source, output, sealed=False, signing_team=None):
    if signing_team is not None and not re.fullmatch(r"[A-Z0-9]{10}", signing_team):
        raise ValueError("invalid release signing team")
    identity = {}
    for line in (ROOT / "Packaging/identity.conf").read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r'(INSTALLER_[A-Z0-9_]+)="([^"\\$`]+)"', line)
        if not match or match[1] in identity:
            raise ValueError("invalid or duplicate installer identity assignment")
        identity[match[1]] = match[2]
    public_base = identity["INSTALLER_PUBLIC_BASE"].rstrip("/")
    stream = identity["INSTALLER_STREAM_PATH"].strip("/")
    trusted = (ROOT / "Release/trust-root.ed25519.pub").read_bytes()
    if len(trusted) != 32 or output.exists():
        raise ValueError("expected a 32-byte app trust root and a new output directory")
    documents = {}
    with tempfile.TemporaryDirectory(prefix="aurora-delivery-verify-") as temporary:
        key = Path(temporary) / "public.der"
        key.write_bytes(bytes.fromhex("302a300506032b6570032100") + trusted)
        for profile in PROFILES:
            directory = source / profile
            names = ("release.json", "trust-root.ed25519.pub", "catalog.json", "catalog.json.sig")
            data = {}
            for name in names:
                path = directory / name
                if path.is_symlink() or not path.is_file() or path.stat().st_size > 1048576:
                    raise ValueError(f"unsafe or missing {profile}/{name}")
                data[name] = path.read_bytes()
            if data["trust-root.ed25519.pub"] != trusted or len(data["catalog.json.sig"]) != 64:
                raise ValueError(f"untrusted delivery: {profile}")
            subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(key),
                            "-rawin", "-in", str(directory / "catalog.json"), "-sigfile",
                            str(directory / "catalog.json.sig")], check=True)
            catalog = json.loads(data["catalog.json"])
            if catalog["schemaVersion"] != 4 or not catalog["models"] or any(
                model.get("installationProfile") != profile for model in catalog["models"]
                if model["status"] == "enabled"
            ):
                raise ValueError(f"catalog profile mismatch: {profile}")
            descriptor = json.loads(data["release.json"])
            expected = "sha256:" + hashlib.sha256(trusted).hexdigest()
            if descriptor["schema_version"] != 3 or descriptor["trust_root_fingerprint"] != expected:
                raise ValueError(f"descriptor root mismatch: {profile}")
            base = public_base + "/" + stream + "/Profiles/" + profile
            for channel in ("stable", "rc", "edge"):
                if descriptor["channels"][channel]["catalog_url"] != base + "/channels/" + channel + "/catalog.signed.json":
                    raise ValueError(f"descriptor channel mismatch: {profile}")
            documents[profile] = data
    def release_descriptor(content):
        if signing_team is None:
            return content
        descriptor = json.loads(content)
        helper = identity["INSTALLER_HELPER_IDENTIFIER"]
        expected_fingerprint = "sha256:" + hashlib.sha256(trusted).hexdigest()
        if (not re.fullmatch(r"[A-Za-z0-9.-]+", helper)
                or descriptor.get("schema_version") != 3
                or descriptor.get("helper_mach_service_name") != helper
                or descriptor.get("trust_root_fingerprint") != expected_fingerprint):
            raise ValueError("release descriptor does not match the configured helper and root")
        descriptor["helper_code_signing_requirement"] = (
            f'anchor apple generic and identifier "{helper}" '
            f'and certificate leaf[subject.OU] = "{signing_team}"'
        )
        return (json.dumps(descriptor, indent=2) + "\n").encode()
    descriptors = {profile: release_descriptor(data["release.json"]) for profile, data in documents.items()}
    root_descriptor = release_descriptor((ROOT / "Release/release.json").read_bytes())
    # Nothing is emitted until the entire nine-profile set has verified.
    output.mkdir(parents=True)
    for profile, data in documents.items():
        directory = output / "Profiles" / profile
        directory.mkdir(parents=True)
        for name, content in data.items():
            if sealed or name not in ("catalog.json", "catalog.json.sig"):
                (directory / name).write_bytes(descriptors[profile] if name == "release.json" else content)
    (output / "release.json").write_bytes(root_descriptor)
    shutil.copyfile(ROOT / "Release/trust-root.ed25519.pub", output / "trust-root.ed25519.pub")
    if sealed:
        for name in ("catalog.json", "catalog.json.sig"):
            (output / name).write_bytes(documents["fedora-kde"][name])
    (output / "profile-manifest.json").write_text(json.dumps({
        "schema": 1, "sealed": sealed, "profiles": {
            profile: {"catalog_sha256": hashlib.sha256(data["catalog.json"]).hexdigest(),
                      "sequence": json.loads(data["catalog.json"])["sequence"]}
            for profile, data in documents.items()
        }}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", type=Path, required=True,
                        help="aurora-distributions/site/installer/Profiles from a verified checkout")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sealed", action="store_true", help="seal exact signed catalogs for a developer/offline build")
    parser.add_argument("--signing-team", help="bind the root and all profile descriptors to this named-signing team")
    args = parser.parse_args()
    prepare(args.profiles, args.output, args.sealed, args.signing_team)
