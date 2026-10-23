# SPDX-License-Identifier: MIT
"""Native Recovery app inventory for distribution payloads.

Payload assembly runs on the release host: it never ships in the installer
app. The installer verifies the same inventory natively before any disk change.
"""

import hashlib
import json
from pathlib import Path
import plistlib

APP_NAME = "Aurora Installer.app"
PAYLOAD_DIRECTORY = "aurora/recovery"
MANIFEST_NAME = "omarchy-recovery-app.json"


class RecoveryError(ValueError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def app_inventory(app):
    """Byte inventory, independent of FAT's synthesized permission bits."""
    app = Path(app)
    if not app.is_dir() or app.is_symlink():
        raise RecoveryError("native Recovery app template is missing")
    files = {}
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise RecoveryError("native Recovery app contains a non-regular entry")
        if path.is_file():
            data = path.read_bytes()
            files[path.relative_to(app).as_posix()] = {
                "sha256": digest(data), "bytes": len(data),
            }
    return {"schema": 1, "buildMode": "recovery", "files": files}


def validate_payload(package):
    """Validate native app bytes in the authenticated OS ZIP before any erase."""
    prefix = "esp/" + PAYLOAD_DIRECTORY + "/"
    try:
        manifest = json.loads(package.read(prefix + MANIFEST_NAME))
        if (set(manifest) != {"schema", "buildMode", "files"}
                or manifest["schema"] != 1 or manifest["buildMode"] != "recovery"
                or not isinstance(manifest["files"], dict) or not manifest["files"]):
            raise RecoveryError("invalid native Recovery payload manifest")
        app_prefix = prefix + APP_NAME + "/"
        actual = {n[len(app_prefix):] for n in package.namelist()
                  if n.startswith(app_prefix) and not n.endswith("/")}
        if actual != set(manifest["files"]):
            raise RecoveryError("native Recovery app files differ from the payload manifest")
        for name, expected in manifest["files"].items():
            if any(part in ("", ".", "..") for part in name.split("/")):
                raise RecoveryError("invalid native Recovery payload path")
            info = package.getinfo(app_prefix + name)
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                raise RecoveryError("native Recovery payload contains a symbolic link")
            data = package.read(app_prefix + name)
            if expected != {"sha256": digest(data), "bytes": len(data)}:
                raise RecoveryError("native Recovery payload checksum mismatch")
        info = plistlib.loads(package.read(app_prefix + "Contents/Info.plist"))
        if (info.get("OmarchyRecoveryBuildMode") != "recovery"
                or info.get("CFBundleExecutable") != "OmarchyRecovery"):
            raise RecoveryError("native Recovery payload must be a real recovery build")
        if info.get("OmarchyRecoveryDataLayout") != "external-install-data-v1":
            raise RecoveryError("native Recovery payload uses an unsupported installation data layout")
        if "Contents/MacOS/OmarchyRecovery" not in actual:
            raise RecoveryError("native Recovery executable is missing")
    except (OSError, KeyError, TypeError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        raise RecoveryError("native Recovery payload is incomplete") from error
    return manifest


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 3:
        raise SystemExit("usage: recovery_payload.py RECOVERY_APP OUTPUT_JSON")
    Path(sys.argv[2]).write_text(json.dumps(app_inventory(Path(sys.argv[1])), sort_keys=True, indent=2) + "\n")
