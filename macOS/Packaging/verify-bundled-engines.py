#!/usr/bin/env python3
"""Verify optional execution engines in private and offline app bundles.

The ordinary on-demand app has none. Catalog-selected offline engines also
live in Resources/Artifacts, so both supported resource layouts are checked.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def regular(path):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= 67_108_864:
        raise ValueError("missing or unsafe bundled execution engine: " + str(path))
    return path


def engine_paths(app):
    if app.is_symlink() or not app.is_dir():
        raise ValueError("application must be a real directory")
    resources = app / "Contents/Resources"
    for relative in ("Contents", "Contents/Resources", "Contents/Resources/Release",
                     "Contents/Resources/Engine", "Contents/Resources/Engine/artifacts",
                     "Contents/Resources/Artifacts"):
        path = app / relative
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise ValueError("unsafe application resource directory: " + str(path))
    selected = set()
    engines = resources / "Engine/artifacts"
    if engines.exists():
        for path in engines.iterdir():
            if not path.name.endswith(".tar.gz"):
                raise ValueError("unexpected execution-engine resource: " + str(path))
            selected.add(regular(path))
    offline = resources / "Artifacts"
    if selected or offline.exists():
        catalog_path = resources / "Release/catalog.json"
        if catalog_path.is_symlink() or not catalog_path.is_file() or catalog_path.stat().st_size > 1_048_576:
            raise ValueError("bundled execution engines require a sealed catalog")
        catalog = json.loads(catalog_path.read_text())
        identities = {}
        for model in catalog["models"]:
            if model.get("status") != "enabled":
                continue
            artifact = model["engineArtifact"]
            name, size, digest = artifact["fileName"], artifact["sizeBytes"], model["engineDigest"]
            if (not isinstance(name, str) or not name or name in (".", "..")
                    or len(name.encode()) > 255 or Path(name).name != name or "\\" in name or "\0" in name
                    or type(size) is not int or not 0 < size <= 67_108_864
                    or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
                raise ValueError("invalid offline execution-engine descriptor")
            if name in identities and identities[name] != (size, digest):
                raise ValueError("conflicting offline execution-engine identity")
            identities[name] = (size, digest)
        if not identities:
            raise ValueError("offline catalog has no enabled execution engines")
        for path in selected:
            if path.name not in identities:
                raise ValueError("private execution engine is not named by the sealed catalog")
        required = set(selected)
        if offline.exists():
            required.update(regular(offline / name) for name in identities)
        for path in required:
            size, digest = identities[path.name]
            with path.open("rb") as stream:
                observed = "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()
            if path.stat().st_size != size or observed != digest:
                raise ValueError("bundled execution engine differs from its catalog")
            selected.add(path)
    return sorted(selected)


def verify(app, signatures=False):
    paths = engine_paths(app)
    if paths:
        subprocess.run([sys.executable, str(ROOT / "Engine/verify-engine-macho.py"),
                        *(["--signatures"] if signatures else []), *map(str, paths)], check=True)
    return len(paths)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--signatures", action="store_true")
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    print("Verified", verify(args.app, args.signatures), "bundled execution engine(s)")
