#!/usr/bin/env python3
"""Verify distribution deliveries and assemble native packaging resources."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROFILES = tuple(f"{distribution}-{desktop}" for distribution in ("fedora", "arch", "nixos")
                 for desktop in ("kde", "gnome", "minimal"))
OMARCHY_PROFILE = "omarchy-hyprland"
# The development delivery lineage the app reads as Testing when a catalog
# declares no channel. This is ReleaseCatalogChannelPolicy.isLegacyDevelopment
# and the undeclared Testing rule in validate(); both are pinned to the same
# cases by Tests/AuroraAppleInstallerTrustCoreTests/Fixtures/
# legacy-testing-catalog-vectors.json.
LEGACY_REPOSITORIES = {"fedora": "fedora-aurora", "arch": "alarm-aurora",
                       "nixos": "nixos-aurora", "omarchy": "omarchy-aurora"}
LEGACY_EVIDENCE_PREFIX = "image-build-"


def is_legacy_development(model, profiles):
    if model.get("status") == "disabled":
        return True
    profile = model.get("installationProfile")
    evidence = model.get("evidenceRevision")
    artifact = model.get("payloadArtifact")
    if not (isinstance(profile, str) and isinstance(evidence, str)
            and evidence.startswith(LEGACY_EVIDENCE_PREFIX) and isinstance(artifact, dict)):
        return False
    file_name = artifact.get("fileName")
    source = artifact.get("sourceURL")
    if not (isinstance(file_name, str) and isinstance(source, str)
            and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", file_name)):
        return False
    run = evidence[len(LEGACY_EVIDENCE_PREFIX):]
    if not re.fullmatch(r"[1-9][0-9]*", run) or profile not in profiles:
        return False
    repository = LEGACY_REPOSITORIES.get(profile.split("-")[0])
    if repository is None:
        return False
    tag = f"payload-{profile}-{run}"
    return source in {f"https://github.com/aurora-silicon/{repository}/releases/download/{name}/{file_name}"
                      for name in (tag, tag + "-models58", tag + "-models65")}


def is_legacy_testing_catalog(catalog, profiles):
    """An undeclared catalog the app reads as Testing: it lists at least one
    Mac that is not disabled, and every model is of the delivery lineage."""
    models = catalog.get("models") if isinstance(catalog, dict) else None
    return (isinstance(models, list) and all(isinstance(model, dict) for model in models)
            and any(model.get("status") != "disabled" for model in models)
            and all(is_legacy_development(model, profiles) for model in models))


def check_bundled_default(catalog, default_channel, profiles, name):
    """The bundled catalog replaces the fetch for the default channel, so it
    must pass the channel policy the app applies to that channel."""
    if "channel" in catalog:
        if not isinstance(catalog["channel"], str) or catalog["channel"] != default_channel:
            raise ValueError(f"the bundled default catalog must declare {default_channel}: {name}")
    elif default_channel != "testing" or not is_legacy_testing_catalog(catalog, profiles):
        raise ValueError(f"an undeclared bundled catalog must be a Testing development delivery: {name}")


def prepare(source, output, sealed=False, signing_team=None, stable_release_tag=None):
    omarchy = os.environ.get("AURORA_ENABLE_OMARCHY", "0")
    if omarchy not in ("0", "1"):
        raise ValueError("AURORA_ENABLE_OMARCHY must be 0 or 1")
    profiles = PROFILES + ((OMARCHY_PROFILE,) if omarchy == "1" else ())
    if signing_team is not None and not re.fullmatch(r"[A-Z0-9]{10}", signing_team):
        raise ValueError("invalid release signing team")
    if stable_release_tag is not None and not re.fullmatch(
        r"v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[1-9][0-9]*", stable_release_tag
    ):
        raise ValueError("invalid Stable installer release tag")
    if stable_release_tag is not None and not sealed:
        raise ValueError("a Stable default requires sealed catalogs")
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
    floors = {}
    schema_versions = set()
    with tempfile.TemporaryDirectory(prefix="aurora-delivery-verify-") as temporary:
        key = Path(temporary) / "public.der"
        key.write_bytes(bytes.fromhex("302a300506032b6570032100") + trusted)
        for profile in profiles:
            directory = source / profile
            catalog_directory = directory / "channels/stable" if stable_release_tag is not None else directory
            if stable_release_tag is not None and (catalog_directory.is_symlink()
                                                   or catalog_directory.parent.is_symlink()):
                raise ValueError(f"unsafe Stable catalog directory: {profile}")
            names = ("release.json", "trust-root.ed25519.pub", "catalog.json", "catalog.json.sig")
            data = {}
            for name in names:
                path = (catalog_directory if name.startswith("catalog.") else directory) / name
                if path.is_symlink() or not path.is_file() or path.stat().st_size > 1048576:
                    raise ValueError(f"unsafe or missing {profile}/{name}")
                data[name] = path.read_bytes()
            if data["trust-root.ed25519.pub"] != trusted or len(data["catalog.json.sig"]) != 64:
                raise ValueError(f"untrusted delivery: {profile}")
            subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(key),
                            "-rawin", "-in", str(catalog_directory / "catalog.json"), "-sigfile",
                            str(catalog_directory / "catalog.json.sig")], check=True)
            catalog = json.loads(data["catalog.json"])
            if stable_release_tag is not None:
                envelope_path = catalog_directory / "catalog.signed.json"
                if (envelope_path.is_symlink() or not envelope_path.is_file()
                        or envelope_path.stat().st_size > 1500000):
                    raise ValueError(f"unsafe or missing Stable envelope: {profile}")
                envelope = json.loads(envelope_path.read_bytes())
                if (not isinstance(envelope, dict) or set(envelope) != {"schema_version", "catalog", "signature"}
                        or type(envelope["schema_version"]) is not int or envelope["schema_version"] != 1
                        or base64.b64decode(envelope["catalog"], validate=True) != data["catalog.json"]
                        or base64.b64decode(envelope["signature"], validate=True) != data["catalog.json.sig"]):
                    raise ValueError(f"Stable envelope differs from its detached catalog: {profile}")
                expected_url = "https://github.com/aurora-silicon/aurora-installer/releases/tag/" + stable_release_tag
                if catalog.get("installer", {}).get("downloadURL") != expected_url:
                    raise ValueError(f"Stable catalog names a different installer release: {profile}")
                if not any(model.get("status") == "enabled" for model in catalog["models"]):
                    raise ValueError(f"Stable catalog has no enabled models: {profile}")
            if catalog["schemaVersion"] != 5:
                raise ValueError(f"catalog is not a native-only schema 5 catalog: {profile}")
            sequence = catalog.get("sequence")
            if type(sequence) is not int or not 0 < sequence < 1 << 64:
                raise ValueError(f"catalog sequence is not a positive 64-bit integer: {profile}")
            if not catalog["models"] or any(
                model.get("installationProfile") != profile for model in catalog["models"]
                if model["status"] == "enabled" or model.get("installationProfile") is not None
            ):
                raise ValueError(f"catalog profile mismatch: {profile}")
            if any(
                any(field in model for field in ("engineVersion", "engineDigest", "engineArtifact",
                                                 "repairManifestDigest", "repairManifestArtifact"))
                for model in catalog["models"]
            ):
                raise ValueError(f"native-only catalog includes an execution archive: {profile}")
            schema_versions.add(catalog["schemaVersion"])
            descriptor = json.loads(data["release.json"])
            expected = "sha256:" + hashlib.sha256(trusted).hexdigest()
            if descriptor["schema_version"] != 3 or descriptor["trust_root_fingerprint"] != expected:
                raise ValueError(f"descriptor root mismatch: {profile}")
            base = public_base + "/" + stream + "/Profiles/" + profile
            for channel in descriptor["channels"]:
                if descriptor["channels"][channel]["catalog_url"] != base + "/channels/" + ("edge-alpha" if channel == "edge" and "testing" in descriptor["channels"] else channel) + "/catalog.signed.json":
                    raise ValueError(f"descriptor channel mismatch: {profile}")
            documents[profile] = data
            if stable_release_tag is None:
                floors[profile] = {"testing": sequence}
            else:
                # The sealed default is Stable; Testing is fetched, so its floor
                # comes from the delivery's own verified base catalog.
                floors[profile] = {"stable": sequence,
                                   "testing": testing_floor(directory, profile, key)}
            for channel, name in FETCHED_CHANNEL_DIRECTORIES.items():
                envelope = directory / "channels" / name / "catalog.signed.json"
                if not envelope.exists() and not envelope.is_symlink():
                    continue  # Absent: that channel gets no floor.
                floors[profile][channel] = channel_floor(envelope, channel, profile, key, temporary)
    if len(schema_versions) != 1:
        raise ValueError("mixed catalog schemas")
    def release_descriptor(content):
        descriptor = json.loads(content)
        channels = descriptor["channels"]
        legacy = set(channels) == {"stable", "rc", "edge"}
        if legacy:
            edge = channels["edge"]["catalog_url"]
            suffix = "/channels/edge/catalog.signed.json"
            if not edge.endswith(suffix):
                raise ValueError("legacy channel URL is not canonical")
            channels["testing"] = {"catalog_url": edge[:-len(suffix)] + "/channels/testing/catalog.signed.json"}
            channels["edge"] = {"catalog_url": edge[:-len(suffix)] + "/channels/edge-alpha/catalog.signed.json"}
            if descriptor.get("default_channel") == "edge":
                descriptor["default_channel"] = "testing"
        if set(channels) != {"stable", "rc", "testing", "edge"} or descriptor.get("default_channel") == "edge":
            raise ValueError("Edge is never the bundled default; all four channel endpoints are required")
        if stable_release_tag is not None:
            descriptor["default_channel"] = "stable"
        if signing_team is None:
            return (json.dumps(descriptor, indent=2) + "\n").encode()
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
    # Published development deliveries predate the channel field; an undeclared
    # one is accepted only where the app reads it as Testing.
    for profile, data in documents.items():
        check_bundled_default(json.loads(data["catalog.json"]),
                              json.loads(descriptors[profile]).get("default_channel"), set(profiles), profile)
    check_bundled_default(json.loads(documents["fedora-gnome"]["catalog.json"]),
                          json.loads(root_descriptor).get("default_channel"), set(profiles), "release.json")
    # Nothing is emitted until every requested profile has verified.
    output.mkdir(parents=True)
    for profile, data in documents.items():
        directory = output / "Profiles" / profile
        directory.mkdir(parents=True)
        for name, content in data.items():
            if sealed or name not in ("catalog.json", "catalog.json.sig"):
                (directory / name).write_bytes(descriptors[profile] if name == "release.json" else content)
        # The app refuses a catalog older than the one it was built with, on
        # a first run too, when no accepted catalog is stored yet: Testing from
        # the verified bundled delivery, every other channel from its verified
        # signed envelope in the same checkout.
        (directory / "catalog-floor.json").write_text(json.dumps({
            "schema_version": 1,
            "minimum_sequence": floors[profile],
        }, indent=2) + "\n")
    (output / "release.json").write_bytes(root_descriptor)
    shutil.copyfile(ROOT / "Release/trust-root.ed25519.pub", output / "trust-root.ed25519.pub")
    if sealed:
        for name in ("catalog.json", "catalog.json.sig"):
            (output / name).write_bytes(documents["fedora-gnome"][name])
    (output / "profile-manifest.json").write_text(json.dumps({
        "schema": 1, "sealed": sealed, "profiles": {
            profile: {"catalog_sha256": hashlib.sha256(data["catalog.json"]).hexdigest(),
                      "sequence": json.loads(data["catalog.json"])["sequence"]}
            for profile, data in documents.items()
        }}, indent=2) + "\n")


# The directory under Profiles/<profile>/channels/ each fetched channel's
# signed envelope lives in, as the shipped descriptor names it. Testing's floor
# comes from the verified bundled catalog.json (the sealed default), and the
# legacy channels/edge alias is read by no shipped descriptor.
FETCHED_CHANNEL_DIRECTORIES = {"stable": "stable", "rc": "rc", "edge": "edge-alpha"}


def testing_floor(directory, profile, key):
    """The sequence of the delivery's verified base (Testing) catalog."""
    paths = [directory / name for name in ("catalog.json", "catalog.json.sig")]
    if any(path.is_symlink() or not path.is_file() or path.stat().st_size > 1048576 for path in paths):
        raise ValueError(f"unsafe or missing {profile} Testing catalog")
    if paths[1].stat().st_size != 64:
        raise ValueError(f"untrusted delivery: {profile}")
    subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(key),
                    "-rawin", "-in", str(paths[0]), "-sigfile", str(paths[1])], check=True)
    catalog = json.loads(paths[0].read_bytes())
    sequence = catalog.get("sequence") if type(catalog) is dict else None
    if type(sequence) is not int or not 0 < sequence < 1 << 64:
        raise ValueError(f"Testing catalog sequence is not a positive 64-bit integer: {profile}")
    return sequence


def channel_floor(path, channel, profile, key, temporary):
    """The sequence of one verified channel envelope.

    The envelope is what the app fetches for `channel`: its catalog must verify
    with the app's trust root, declare no other channel, list only `profile`
    and carry a positive 64-bit sequence.
    """
    # The app's own envelope limit (InstallerReleaseCatalogFetcher).
    if (any(part.is_symlink() for part in (path, path.parent, path.parent.parent))
            or not path.is_file() or path.stat().st_size > 1572864):
        raise ValueError(f"unsafe {profile}/{channel} channel catalog")
    try:
        envelope = json.loads(path.read_bytes())
        if (type(envelope) is not dict or set(envelope) != {"schema_version", "catalog", "signature"}
                or type(envelope["schema_version"]) is not int or envelope["schema_version"] != 1):
            raise ValueError
        payload = base64.b64decode(envelope["catalog"], validate=True)
        signature = base64.b64decode(envelope["signature"], validate=True)
    except (ValueError, TypeError):
        raise ValueError(f"malformed {profile}/{channel} channel catalog envelope") from None
    if not payload or len(payload) > 1048576 or len(signature) != 64:
        raise ValueError(f"malformed {profile}/{channel} channel catalog envelope")
    payload_path = Path(temporary) / "channel-catalog.json"
    signature_path = Path(temporary) / "channel-catalog.json.sig"
    payload_path.write_bytes(payload)
    signature_path.write_bytes(signature)
    subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(key),
                    "-rawin", "-in", str(payload_path), "-sigfile", str(signature_path)], check=True)
    catalog = json.loads(payload)
    models = catalog.get("models") if type(catalog) is dict else None
    if (type(catalog) is not dict or catalog.get("schemaVersion") != 5 or type(models) is not list
            or not all(type(model) is dict for model in models)):
        raise ValueError(f"channel catalog is not a native-only schema 5 catalog: {profile}/{channel}")
    if catalog.get("channel", channel) != channel:
        raise ValueError(f"channel catalog declares another channel: {profile}/{channel}")
    if any(model.get("installationProfile") != profile for model in models
           if model.get("status") == "enabled" or model.get("installationProfile") is not None):
        raise ValueError(f"channel catalog profile mismatch: {profile}/{channel}")
    sequence = catalog.get("sequence")
    if type(sequence) is not int or not 0 < sequence < 1 << 64:
        raise ValueError(f"channel catalog sequence is not a positive 64-bit integer: {profile}/{channel}")
    return sequence


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", type=Path, required=True,
                        help="aurora-distributions/site/installer/Profiles from a verified checkout")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sealed", action="store_true", help="seal exact signed catalogs for a developer/offline build")
    parser.add_argument("--signing-team", help="bind the root and all profile descriptors to this named-signing team")
    parser.add_argument("--stable-release-tag", help="seal the signed Stable catalogs for this published installer tag")
    args = parser.parse_args()
    prepare(args.profiles, args.output, args.sealed, args.signing_team, args.stable_release_tag)
