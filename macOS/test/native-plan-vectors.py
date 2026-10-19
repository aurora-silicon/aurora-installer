#!/usr/bin/env python3
"""Verify Swift planner fixtures against the retained engine contract.

Run with --write only when deliberately regenerating the public synthetic vectors.
This utility is a source test and is never bundled in the installer.
"""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Engine/overlay/src"))
import omarchy_contract as contract


def vectors():
    unit = 1_048_576
    result = []
    for name in ("free", "resize", "repair", "replace", "unicode", "maximum-end", "recommendations"):
        kind = name if name in ("resize", "repair", "replace") else "free"
        candidate = {"kind": kind, "source_identifier": "disk0s3", "offset_bytes": 128 * unit,
                     "length_bytes": 512 * unit if kind == "resize" else 128 * unit,
                     "minimum_install_bytes": 64 * unit, "minimum_container_bytes": 256 * unit if kind == "resize" else 0}
        if kind == "repair":
            candidate["minimum_install_bytes"] = candidate["length_bytes"]
        if kind in ("repair", "replace"):
            candidate["identity_digest"] = "sha256:" + "9" * 64
        if name == "maximum-end":
            candidate["offset_bytes"] = 2**64 - 1 - candidate["length_bytes"]
        if name == "recommendations":
            candidate.update(recommended_install_bytes=96 * unit, recommended_container_bytes=0)
        inventory = contract.normalized_inventory("disk0", [candidate])
        requested = candidate["length_bytes"] if kind in ("repair", "replace") else 96 * unit
        identity = {"engine_version": "v0.9.2-aurora.4-β" if name == "unicode" else "v0.9.2-aurora.4",
                    "engine_digest": "sha256:" + "d" * 64,
                    "metadata_digest": "sha256:" + "e" * 64,
                    "payload_digest": "sha256:" + "f" * 64}
        if kind == "repair":
            identity["repair_manifest_digest"] = "sha256:" + "7" * 64
        plan = contract._plan_payload(
            inventory=inventory, device_identifier="apple,j314s", layout_digest=inventory["layout_digest"],
            candidate_kind=kind, source_identifier=candidate["source_identifier"],
            requested_length_bytes=requested, engine_version=identity["engine_version"],
            engine_digest=identity["engine_digest"], metadata_digest=identity["metadata_digest"],
            payload_digest=identity["payload_digest"], repair_manifest_digest=identity.get("repair_manifest_digest"),
            required_human_steps=["authenticateMachineOwner"] if kind == "repair" else ["enterOneTrueRecovery", "authenticateMachineOwner"])
        records = [{"schema_version": 1, "sequence": index + 1, "type": role, "payload": payload}
                   for index, (role, payload) in enumerate([
                       ("inspection", {"device_identifier": "apple,j314s", "support": "supported"}),
                       ("inventory", inventory)])]
        inspection = "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in records)
        result.append({"name": name, "inspection": inspection, "requested": requested,
                       "identity": identity, "expected_plan": plan})
    return {"schema": 1, "provenance": "Synthetic vectors generated with omarchy_contract._plan_payload", "vectors": result}


if __name__ == "__main__":
    path = ROOT / "Tests/OmarchyAppleInstallerTrustCoreTests/Fixtures/native-plan-vectors.json"
    expected = vectors()
    if sys.argv[1:] == ["--write"]:
        path.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n")
    elif sys.argv[1:]:
        raise SystemExit("usage: native-plan-vectors.py [--write]")
    elif json.loads(path.read_text()) != expected:
        raise SystemExit("Native plan fixtures differ from the retained reference contract")
    print(f"Verified {len(expected['vectors'])} independent native plan vectors")
