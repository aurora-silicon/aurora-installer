#!/usr/bin/env python3
"""Public source-owner vectors from the locked Recovery bootstrap functions."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
from types import SimpleNamespace
import uuid

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Tests/OmarchyAppleInstallerTrustCoreTests/Fixtures/native-source-owner-vectors.json"


def uid(value):
    return str(uuid.UUID(int=value)).upper()


def generate():
    source = (ROOT / "Engine/overlay/src/omarchy_recovery.py").read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    lock = json.loads((ROOT / "Engine/source-lock.json").read_text())
    assert digest == next(item["sha256"] for item in lock["downstream_overlay"]["files"]
                          if item["path"] == "overlay/src/omarchy_recovery.py")
    nodes = [node for node in ast.parse(source).body if
             isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
             and node.targets[0].id == "UUID_PATTERN"
             or isinstance(node, ast.FunctionDef) and node.name in
             {"identifier", "source_system_volume", "source_bootstrap"}
             or isinstance(node, ast.ClassDef) and node.name == "RecoveryError"]
    scope = dict(re=re, uuid=uuid, Path=Path, plistlib=plistlib, os=os)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), "locked-source-bootstrap", "exec"), scope)
    cases = []
    for fault in ["good", "volume-owner", "numeric-owner", "wrong-guid", "wrong-user",
                  "missing", "preboot-uuid", "source-system", "duplicate-system", "root-group"]:
        with tempfile.TemporaryDirectory() as temporary:
            preboot = Path(temporary) / "Preboot"
            group, system, owner = uid(90), uid(10), uid(900)
            admins = {"mina": {"GeneratedUID": owner}}
            if fault == "wrong-guid": admins["mina"]["GeneratedUID"] = uid(901)
            if fault == "wrong-user": admins = {"other": {"GeneratedUID": owner}}
            admin_file = preboot / group / "var/db/AdminUserRecoveryInfo.plist"
            admin_file.parent.mkdir(parents=True)
            if fault != "missing": admin_file.write_bytes(plistlib.dumps(admins))
            class Disk:
                def get(self, *args):
                    if args == ("info", "-plist", "disk4s1s1"):
                        return dict(VolumeUUID=uid(777), APFSVolumeGroupID=uid(91) if fault == "root-group" else group)
                    if args == ("apfs", "list", "-plist"):
                        volumes = [dict(APFSVolumeUUID=system, Roles=["System"])]
                        if fault == "duplicate-system": volumes *= 2
                        return dict(Containers=[dict(Volumes=volumes)])
                    if args == ("info", "-plist", system):
                        return dict(VolumeUUID=uid(11) if fault == "source-system" else system, APFSVolumeGroupID=group)
                    if args == ("apfs", "listUsers", system, "-plist"):
                        flag = 1 if fault == "numeric-owner" else fault != "volume-owner"
                        return dict(Users=[dict(APFSCryptoUserUUID=owner, VolumeOwner=flag)])
                    if args == ("info", "-plist", str(preboot)):
                        return dict(VolumeUUID=uid(13) if fault == "preboot-uuid" else uid(12))
                    raise AssertionError("unexpected reference query")
            expected = None
            try:
                expected = scope["source_bootstrap"](Disk(), SimpleNamespace(
                    vgid=group, sys_volume="disk4s1s1", preboot=str(preboot), preboot_vgid=uid(12)), "mina")
            except scope["RecoveryError"]:
                pass
            cases.append(dict(fault=fault, expected=None if expected is None else
                              json.dumps(expected,sort_keys=True,separators=(",", ":"))))
    return dict(referenceSHA256=digest, vectors=cases)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    expected = generate()
    if args.write: FIXTURE.write_text(json.dumps(expected,sort_keys=True,separators=(",", ":")) + "\n")
    elif json.loads(FIXTURE.read_text()) != expected: raise SystemExit("stale native source-owner fixture")
    print(f"Verified {len(expected['vectors'])} source-owner bootstrap reference vectors")
