#!/usr/bin/env python3
"""Prepare public staging pins from the new Limine product and exact catalog assets.

Does not sign, copy large assets, contact a host or change an installed cache.
Copy limine-inputs.json into the new sealed release directory before app assembly.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ENGINE_NAME = "installer-v0.9.2-omarchy.17.tar.gz"
ENGINE_SHA = "ecb61645a9c75ba733425fb300b8b53b09f9dbc297a86acce1e0ee41f36e32e5"
ENGINE_SIZE = 17838045
IDENTITY = Path(__file__).resolve().parents[1] / "identity.conf"


def configured(name):
    for line in IDENTITY.read_text().splitlines():
        match = re.fullmatch(name + r'="([^"\\$`]+)"', line)
        if match:
            return match.group(1)
    raise ValueError(f"{IDENTITY} does not define {name}")


APP_IDENTIFIER = configured("INSTALLER_APP_IDENTIFIER")
PLAIN_WORKSPACE = APP_IDENTIFIER + ".private-m3-20260922"
WORKSPACE = APP_IDENTIFIER + ".private-limine-20260922"


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or unsafe input: {path}")
    return path


def digest(path):
    result = hashlib.sha256()
    with regular(path).open("rb") as stream:
        while block := stream.read(8 * 1024 * 1024):
            result.update(block)
    return result.hexdigest()


def catalog_contract(catalog):
    models = catalog.get("models", [])
    if catalog.get("schemaVersion") != 4 or not models:
        raise ValueError("a schema-4 private catalog with admitted models is required")
    contracts = []
    for model in models:
        if model.get("status") != "enabled":
            raise ValueError("private catalog must contain only its admitted test models")
        evidence = model.get("evidenceRevision", "")
        if not re.fullmatch(r"quattro-private-limine-[a-z0-9.-]+", evidence):
            raise ValueError("new private Limine evidence revision is required")
        assets = {}
        for role in ("engine", "metadata", "payload"):
            artifact = model[role + "Artifact"]
            name = artifact["fileName"]
            size = artifact["sizeBytes"]
            sha = model[role + "Digest"]
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
                raise ValueError("unsafe artifact filename")
            if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
                raise ValueError("invalid artifact size")
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", sha):
                raise ValueError("invalid artifact digest")
            assets[role] = {"filename": name, "size_bytes": size, "sha256": sha[7:]}
        if assets["engine"] != {"filename": ENGINE_NAME, "size_bytes": ENGINE_SIZE, "sha256": ENGINE_SHA}:
            raise ValueError("frozen .17 engine changed")
        if model.get("engineVersion") != "v0.9.2-omarchy.17":
            raise ValueError("frozen .17 engine version changed")
        if len({a["filename"] for a in assets.values()}) != 3:
            raise ValueError("artifact filenames must be distinct")
        contracts.append({"evidence_revision": evidence, "assets": assets})
    if any(contract != contracts[0] for contract in contracts):
        raise ValueError("private models must share the exact candidate assets")
    return contracts[0]


def prepare(catalog_path, product_path, assets, output):
    catalog = json.loads(regular(catalog_path).read_text())
    contract = catalog_contract(catalog)
    product = json.loads(regular(product_path).read_text())
    if product.get("boot_backend") != "asahi-limine" or product.get("kernel_package") != "linux-asahi":
        raise ValueError("this private test requires the Asahi Limine image product")
    if product.get("package_filename") != contract["assets"]["payload"]["filename"]:
        raise ValueError("product and catalog name different payloads")
    for artifact in contract["assets"].values():
        path = regular(assets / artifact["filename"])
        if path.stat().st_size != artifact["size_bytes"] or digest(path) != artifact["sha256"]:
            raise ValueError(f"catalog asset differs: {artifact['filename']}")
    metadata = json.loads((assets / contract["assets"]["metadata"]["filename"]).read_text())
    targets = [t for t in metadata.get("os_list", []) if t.get("omarchy_target") == "apple-silicon-full-os"]
    if len(targets) != 1 or targets[0].get("package") != product["package_filename"]:
        raise ValueError("new metadata does not name the new full-OS payload")
    record = {"schema_version": 1, "profile": "private-limine", "workspace": WORKSPACE,
              "boot_backend": "asahi-limine", "kernel_package": "linux-asahi",
              "catalog_sha256": digest(catalog_path), "product_sha256": digest(product_path), **contract}
    template = (Path(__file__).parent / "Stage assets.command").read_text()
    template = template.replace("@APP_IDENTIFIER@.private-m3-20260922", WORKSPACE)
    template = template.replace("quattro-private-m3-family-1c595bb6030c-20260922", contract["evidence_revision"])
    template = template.replace("$bundle/baseline-assets/", "$bundle/limine-assets/")
    start = template.index("\n", template.index("done <<'PINS'")) + 1
    end = template.index("\nPINS", start)
    pins = "\n".join(f"{a['sha256']} {a['size_bytes']} {a['filename']}" for a in contract["assets"].values())
    template = template[:start] + pins + template[end:]
    output.mkdir(mode=0o700)
    (output / "limine-inputs.json").write_text(json.dumps(record, indent=2) + "\n")
    stage = output / "Stage assets.command"
    stage.write_text(template)
    stage.chmod(0o755)
    return record


def verify_release(release):
    record = json.loads(regular(release / "limine-inputs.json").read_text())
    catalog_path = regular(release / "catalog.json")
    expected = {"schema_version": 1, "profile": "private-limine", "workspace": WORKSPACE,
                "boot_backend": "asahi-limine", "kernel_package": "linux-asahi",
                "catalog_sha256": digest(catalog_path),
                "product_sha256": record.get("product_sha256"),
                **catalog_contract(json.loads(catalog_path.read_text()))}
    if record != expected or not re.fullmatch(r"[0-9a-f]{64}", record.get("product_sha256", "")):
        raise ValueError("private Limine input receipt differs from the sealed catalog")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-release", type=Path)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--product", type=Path)
    parser.add_argument("--assets-dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    if args.verify_release:
        if any((args.catalog, args.product, args.assets_dir, args.output_dir)):
            parser.error("verification does not accept preparation arguments")
        record = verify_release(args.verify_release)
    else:
        if not all((args.catalog, args.product, args.assets_dir, args.output_dir)):
            parser.error("preparation requires catalog, product, assets-dir and new output-dir")
        record = prepare(args.catalog, args.product, args.assets_dir, args.output_dir)
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
