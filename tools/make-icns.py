#!/usr/bin/env python3
"""Wrap a 1024x1024 PNG in the minimal ICNS container used by the stub OS."""

import argparse
import struct
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def build_icns(png: bytes) -> bytes:
    if not png.startswith(PNG_SIGNATURE):
        raise ValueError("input is not a PNG file")
    element = b"ic10" + struct.pack(">I", len(png) + 8) + png
    return b"icns" + struct.pack(">I", len(element) + 8) + element


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(build_icns(args.input.read_bytes()))


if __name__ == "__main__":
    main()
