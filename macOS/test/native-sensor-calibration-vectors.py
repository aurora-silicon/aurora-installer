#!/usr/bin/env python3
"""Synthetic signed-calibration cases checked against the retained collector."""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Engine/overlay/src/omarchy_mesa.py"
OUTPUT = ROOT / "Tests/AuroraFirmwareTests/Fixtures/sensor-calibration.json"


def der(tag, body):
    if len(body) < 128:
        return bytes([tag, len(body)]) + body
    length = len(body).to_bytes((len(body).bit_length() + 7) // 8, "big")
    return bytes([tag, 128 | len(length)]) + length + body


def text(value):
    return der(0x16, value.encode())


def image(kind="FSC2", payload=b"CALB" + b"synthetic" * 40, manifest="IM4M"):
    im4p = der(0x30, text("IM4P") + text(kind) + text("fixture") + der(4, payload))
    return der(0x30, text("IMG4") + im4p + der(0xa0, der(0x30, text(manifest))))


def combined(blob=None):
    blob = image(kind="FSCl", manifest="IM4M FSCl") if blob is None else blob
    return der(0x30, text("comb") + der(0x30, text("fdrd") + der(4, blob)) + der(0x30, text("secb")))


def generate():
    spec = importlib.util.spec_from_file_location("sensor_reference", SOURCE)
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)
    standalone, wrapped = image(), combined()
    cases = [
        ("standalone", b"\0" * 4096 + standalone + b"\xff" * 4096),
        ("duplicate-copy", standalone + b"\0" * 512 + standalone),
        ("combined", wrapped), ("duplicate-combined", wrapped + wrapped),
        ("ambiguous-formats", standalone + wrapped),
        ("ambiguous-values", standalone + image(payload=b"CALB" + b"different" * 40)),
        ("unsigned", image(manifest="none")),
        ("wrong-payload", image(payload=b"no calibration")),
        ("wrong-image-type", image(kind="OTHER")),
        ("truncated", wrapped[:-1]),
        ("missing-security-record", wrapped.replace(b"secb", b"none")),
        ("missing-combined-manifest-type", combined(image(kind="FSCl"))),
        ("combined-without-calibration", combined(image(kind="FSCl", payload=b"none", manifest="IM4M FSCl"))),
        ("bounded-parent", wrapped[:5] + bytes([0]) + wrapped[6:]),
    ]
    vectors = []
    for name, data in cases:
        value = dict(name=name, input=base64.b64encode(data).decode())
        try:
            result = reference.calibration(data)
            value.update(accepted=True, expected=base64.b64encode(result).decode())
        except reference.MesaError:
            value.update(accepted=False)
        vectors.append(value)
    root_payload = der(0x30, text("IM4P") + text("MSRk") + text("1.0")
                       + der(4, b"synthetic sensor public-key payload"))
    root_manifest = der(0x30, text("IM4M") + der(2, b"\0") + der(0x31, b"")
                        + der(4, b"synthetic signature") + der(0x30, b""))
    root = der(0x30, text("IMG4") + root_payload + der(0xa0, root_manifest))
    overfull = der(0x30, text("IMG4") + root_payload + der(0xa0,
                   der(0x30, text("IM4M") + der(2, b"\0") + der(0x30, b"") * 1023)))
    bare = root
    def combined_root(blob=bare, security=b"synthetic trust bundle"):
        return der(0x30, text("comb") + der(0x30, text("fdrd") + der(4, blob))
                   + der(0x30, text("secb") + der(4, security)))
    root = combined_root()
    roots = [("complete-root", root, True), ("bare-root", bare, False),
             ("empty-trust-bundle", combined_root(security=b""), False),
             ("manifest-field-limit", combined_root(overfull), False),
             ("embedded-trailing-data", combined_root(bare + b"trailing"), False),
             ("truncated-root", root[:-1], False),
             ("trailing-root-data", root + b"unexpected", False),
             ("wrong-root-type", root.replace(b"MSRk", b"FSC2"), False),
             ("missing-root-manifest", root.replace(b"IM4M", b"none"), False),
             ("calibration-is-not-root", standalone, False), ("empty-root", b"", False)]
    root_vectors = [dict(name=name, input=base64.b64encode(data).decode(), accepted=accepted)
                    for name, data, accepted in roots]
    return dict(referenceSHA256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(), vectors=vectors,
                rootKeys=root_vectors,
                rootKeyProvenance="Synthetic combined root-key envelopes; no device key or certificate bytes. Structural checks only, not issuer validation.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    value = generate()
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    if args.write:
        OUTPUT.write_text(encoded)
    elif OUTPUT.read_text() != encoded:
        raise SystemExit("Stale sensor calibration reference vectors")
    print(f"Verified {len(value['vectors'])} calibration and {len(value['rootKeys'])} root-key structure vectors")
