# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""Writes the sealed range recipes the native installer reads a Mac's Wi-Fi
firmware with, from the System volume of the restore image of the stub it
installs.

Maintenance tool only, like speaker_tuning_recipes.py, whose image reader it
shares. A recipe holds offsets, sizes and SHA-256 digests, never Apple data.

The stub restore images and the models each one is admitted for come from
the installer's sealed inspection policy (NativeInspectionPolicySource.swift),
so this tool needs no list of its own: every restore image there whose root
file system is an Apple Encrypted Archive gets an entry, given a complete
local copy. For each admitted model the image's own device tree names the
Wi-Fi board (the `wlan` node's `module-instance`); the recipe for that board
holds every file under usr/share/firmware/wifi/ that belongs to it (a chip
directory entry named `<board>`, `<board>-<SKU>` or `P-<board>...`), a link
written as a copy of the file it names.

    python3 -I macOS/scripts/radio_firmware_recipes.py \\
        --speakerguardd ../speakerguardd/packaging/upgrade \\
        --output macOS/Sources/AuroraFirmware/Resources/radio-firmware \\
        --identity-cache identity.json BUILD=PATH...
"""
import argparse
import json
import os
import pathlib
import re
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import speaker_tuning_recipes as common  # noqa: E402

POLICY = (pathlib.Path(__file__).resolve().parents[1] / "Sources" / "AuroraAppleInstaller"
          / "NativeInspectionPolicySource.swift")
WIFI = "usr/share/firmware/wifi"
BOARD = re.compile(r"\A[a-z][a-z0-9]{0,31}\Z")


def policy_images():
    """[(url, models or None)] of the policy's restore images, in order."""
    text = POLICY.read_text()
    start = text.index('#"""') + 4
    doc = json.loads(text[start:text.index('"""#', start)])
    found = []

    def walk(node):
        if isinstance(node, dict):
            url = node.get("sourceURL")
            if isinstance(url, str) and url.endswith("_Restore.ipsw"):
                found.append((url, node.get("models")))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(doc)
    return found


class RadioImage(common.Image):
    def wifi_boards(self, adt, img4, models):
        """{DeviceClass: Wi-Fi board} for the admitted models whose device
        tree in this image has one `wlan` node with a `module-instance`."""
        out = {}
        for bi in self.manifest["BuildIdentities"]:
            device = bi["Info"]["DeviceClass"]
            if "OS" not in bi.get("Manifest", {}) or "DeviceTree" not in bi["Manifest"]:
                continue
            if models is not None and device[:-2] not in models:
                continue
            payload = img4.img4p_extract(self.zip.read(bi["Manifest"]["DeviceTree"]["Info"]["Path"]))
            if isinstance(payload, tuple):
                payload = payload[-1]
            found = []

            def walk(node):
                if node.name == "wlan" and "module-instance" in node.properties:
                    found.append(node.properties["module-instance"].split(b"\0", 1)[0].decode())
                for child in node.children:
                    walk(child)
            walk(adt.parse(payload))
            if not found:
                continue
            if len(set(found)) != 1 or not BOARD.match(found[0]):
                raise common.RecipeError(f"{device}: ambiguous Wi-Fi board")
            if out.get(device, found[0]) != found[0]:
                raise common.RecipeError(f"{device}: two Wi-Fi boards")
            out[device] = found[0]
        return out

    def board_files(self, board):
        """The board's files under usr/share/firmware/wifi/; a link (to a
        file in the same tree, at most 8 deep) is written as a copy."""
        top = self.lookup(WIFI)
        if top is None or top[1] != 4:
            raise common.RecipeError(f"{self.build}: no {WIFI}")
        own = re.compile(rf"\A(P-)?{re.escape(board)}([-_.]|\Z)")
        files = []

        def resolve(rel):
            path = f"{WIFI}/{rel}"
            for _ in range(8):
                hit = self.lookup(path)
                if hit is None:
                    raise common.RecipeError(f"{path}: dangling link")
                ino, kind = hit
                if kind == 8:
                    return ino
                if kind != 10:
                    raise common.RecipeError(f"{path}: not a file")
                dest = self.vol.readlink(ino)
                parts = path.rsplit("/", 1)[0].split("/") if not dest.startswith("/") else []
                for piece in dest.split("/"):
                    if piece == "..":
                        parts.pop()
                    elif piece not in ("", "."):
                        parts.append(piece)
                path = "/".join(parts)
                if not path.startswith(WIFI + "/"):
                    raise common.RecipeError(f"{rel}: link leaves {WIFI}")
            raise common.RecipeError(f"{rel}: link chain too long")

        def rec(ino, rel):
            for name, (child, kind) in sorted(self.vol.children(ino).items()):
                if kind == 4:
                    rec(child, rel + name + "/")
                elif kind in (8, 10) and own.match(name):
                    source = f"{WIFI}/{rel}{name}"
                    record, _ = self.file_record(source, source, resolve(rel + name))
                    files.append(record)
        rec(top[0], "")
        if len(files) > common.MAX_FILES:
            raise common.RecipeError(f"{board}: {len(files)} files")
        return files

    def radio_recipe(self, board, identity):
        self.recipe_files = lambda _aid: self.board_files(board)
        return self.recipe(board, identity)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--speakerguardd", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--identity-cache")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("images", nargs="+", help="BUILD=LOCAL-PATH")
    args = ap.parse_args(argv)
    sys.path.insert(0, os.path.abspath(args.speakerguardd))
    sys.path.insert(1, str(common.REPO))
    from aurora_speaker_upgrade import aea_ro, apfs_ro
    from asahi_firmware import adt, img4
    common._AEA = aea_ro
    cache = {}
    if args.identity_cache and os.path.exists(args.identity_cache):
        with open(args.identity_cache) as f:
            cache = json.load(f)
    local = dict(spec.split("=", 1) for spec in args.images)
    out = pathlib.Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    index = {"schema": 1, "kind": "aurora-radio-firmware-restore-images", "images": []}
    for url, models in policy_images():
        build = re.search(r"_([0-9A-Z]+)_Restore\.ipsw\Z", url).group(1)
        if build not in local:
            print(f"{build}: no local copy, skipped", file=sys.stderr)
            continue
        image = RadioImage(apfs_ro, aea_ro, local[build], url, build)
        if not image.member.endswith(".aea"):
            continue
        identity = image.identity(cache, args.jobs)
        if args.identity_cache:
            with open(args.identity_cache, "w") as f:
                json.dump(cache, f, indent=1, sort_keys=True)
        boards = image.wifi_boards(adt, img4, set(models) if models else None)
        recipes = {}
        for board in sorted(set(boards.values())):
            if not image.board_files(board):
                # Not a Broadcom board (the Neo's MT7932 has its own recipe).
                print(f"{build}: no Wi-Fi files for {board}, left out", file=sys.stderr)
                boards = {k: v for k, v in boards.items() if v != board}
                continue
            doc = common.encode(image.radio_recipe(board, identity))
            name = f"{build}-{board}.json"
            (out / name).write_bytes(doc)
            recipes[board] = common.sha(doc)
            print(f"{name}: {len(doc)} bytes", file=sys.stderr)
        index["images"].append({"build": build, "url": url, "size_bytes": image.size,
                                "sha256": identity["sha256"], "boards": boards,
                                "recipes": recipes})
    (out / "index.json").write_bytes(common.encode(index, pretty=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
