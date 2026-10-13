#!/usr/bin/env python3
"""TEST IMAGES ONLY: keep a candidate set's runtime through a pacman -Syu.

A test candidate set's runtime is built from one omarchy-mac commit and
versioned 4.0.0.alpha..., which sorts below the channel's omarchy (4.0.2 on
edge), so a pacman -Syu on the installed Mac would replace it with the
channel's. An image built from a test set (candidate_only, which is every set
the importer accepts) therefore ignores upgrades of the packages built from the
set's source commit, or from the commit the set declares for a platform
package, in a marked block of /etc/pacman.conf's [options]. A set package taken
from the channel (the boot package, the closure) keeps following it. The runtime's own pacman templates carry no pin, and nothing else in the
image changes. Keep the marked lines until the channel carries qualified Mac
packages: without them a pacman -Syu can downgrade and break the Mac.

  test_image_pin.py names IMPORT_JSON              prints the pinned packages
  test_image_pin.py render TEMPLATE IMPORT_JSON    prints the installed pacman.conf
"""
import json
from pathlib import Path
import sys

MARK = "# Test image only (omarchy-mac-installer image-builder): keeps the candidate set's runtime,"
REASON = "# whose version sorts below the channel's. Keep these three lines: the channel has no Mac packages yet, so removing them can downgrade and break this Mac."


def pinned(summary: dict) -> list[str]:
    if summary.get("candidate_only") is not True:
        return []
    return sorted(p["name"] for p in summary["packages"]
                  if p.get("origin") == "commit" or p.get("origin", "").startswith("platform "))


def render(template: bytes, names: list[str]) -> bytes:
    """TEMPLATE with the pin as the first lines of its [options] section."""
    if not names:
        return template
    lines = template.decode().splitlines(keepends=True)
    options = [i for i, line in enumerate(lines) if line.strip() == "[options]"]
    if len(options) != 1:
        raise ValueError("the pacman template has no single [options] section")
    block = f"{MARK}\n{REASON}\nIgnorePkg = {' '.join(names)}\n"
    return "".join(lines[:options[0] + 1] + [block] + lines[options[0] + 1:]).encode()


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "names":
        print(" ".join(pinned(json.loads(Path(argv[1]).read_text()))))
        return 0
    if len(argv) == 3 and argv[0] == "render":
        names = pinned(json.loads(Path(argv[2]).read_text()))
        sys.stdout.buffer.write(render(Path(argv[1]).read_bytes(), names))
        return 0
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
