#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Check installed firmware archives against an independently prepared inventory."""

import argparse
import hashlib
import json
import re
import tarfile
from pathlib import Path


def check_archive(path, expected):
    if not isinstance(expected, dict) or not expected:
        raise ValueError("each archive needs an expected file inventory")
    if any(not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
           for digest in expected.values()):
        raise ValueError("expected SHA-256 digests must be lowercase hex")
    seen = set()
    invalid = 0
    with tarfile.open(path, "r:*") as archive:
        for member in archive:
            name = member.name.removeprefix("./")
            if name not in expected:
                continue
            if name in seen or not member.isfile() or member.size == 0:
                invalid += 1
            else:
                with archive.extractfile(member) as stream:
                    if hashlib.file_digest(stream, "sha256").hexdigest() != expected[name]:
                        invalid += 1
            seen.add(name)
    return len(expected.keys() - seen), invalid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("esp", type=Path, help="read-only root of the installed ESP")
    args = parser.parse_args()
    archives = {
        "local": "asahi/all_firmware.tar.gz",
        "vendor": "vendorfw/firmware.tar",
    }
    try:
        inventory = json.loads(args.inventory.read_text())
        if not isinstance(inventory, dict) or inventory.keys() != archives.keys():
            raise ValueError("inventory requires local and vendor file maps")
    except (OSError, ValueError):
        parser.exit(1, "Could not read a valid firmware inventory.\n")

    failed = False
    for kind, relative in archives.items():
        try:
            missing, invalid = check_archive(args.esp / relative, inventory[kind])
        except (OSError, EOFError, tarfile.TarError, ValueError):
            print(f"{kind}: invalid inventory or unreadable archive")
            failed = True
            continue
        print(f"{kind}: {len(inventory[kind])} expected, {missing} missing, {invalid} invalid")
        failed |= bool(missing or invalid)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
