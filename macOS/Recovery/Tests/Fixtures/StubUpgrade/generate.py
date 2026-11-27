#!/usr/bin/env python3
"""Regenerate the upgrade-config.json fixtures for StubUpgradeCheck.swift with aurora-upgrade itself.

The request is what `aurora-upgrade stage` writes to Aurora/Recovery/UpgradeData/upgrade-config.json
and aurora/upgrade/request.json (Plan.to_json, with its plan_sha256), for a made-up M2 MacBook Air
moving its 13.5 stub to 27.2 in place; caution.json is the same with a board caution that holds
non-ASCII text, so the Swift digest must escape it as Python's json.dumps does; grow.json is an
"in-place-grow" plan (the EFI partition moved from right after the 2.5 GB container into the free
space before it, the container to grow into its old place); slot.json a plan for a second
startup volume, which Recovery refuses. Nothing here is from a real Mac. Usage (from this directory):
python3 generate.py PATH/TO/tools/upgrade/aurora_upgrade.py
"""
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("aurora_upgrade", sys.argv[1])
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)

machine = up.Machine(board="j413", chip=0x8112, system_firmware="iBoot-13822.41.1",
                     os_firmware="13.5", stub_group="6A1E2B3C-4D5E-4F60-8172-8394A5B6C7D8",
                     esp_partuuid="1b2c3d4e-5f60-4172-8394-a5b6c7d8e9f0",
                     stage1_version="1.0.0b10", stage2_version="1.0.0b17")
volumes = [up.Volume(slot=i, name=n, uuid=u, group=machine.stub_group, role=r, sealed=False,
                     encrypted=False)
           for i, (n, u, r) in enumerate([
               ("Aurora", "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1", "system"),
               ("Preboot", "1F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1", "preboot"),
               ("Recovery", "2F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1", "recovery")])]
stub = up.Stub(device="/dev/nvme0n1p3", start=500 << 30, size=2_499_805_184, volumes=volumes)
target = up.Target(version="27.2", build="26B123",
                   url="https://updates.cdn-apple.com/fixture/UniversalMac_27.2_26B123_Restore.ipsw",
                   source_bytes=19_000_000_000,
                   manifest_sha256="sha256:" + "ab" * 32, minimum_boot="iBoot-13822.41.1",
                   stub_bytes=up.STUB_BYTES_LARGE, minimum_recovery="26.2.123.0.0,0")
space = up.Space(container=2_499_805_184, used=1_050_000_000, recovery_image=810_000_000,
                 preboot=220_000_000, new_recovery_image=1_310_000_000,
                 new_boot_files=120_000_000)
payload = {"dir": "/nonexistent", "bytes": 40_000_000, "app_sha256": "cd" * 32,
           "stage1": {"path": "stage1/aura-boot.macho", "sha256": "ef" * 32, "version": "1.0.0b17"}}


def write(name, plan):
    with open(name, "w") as f:
        f.write(json.dumps(plan.to_json(), indent=2, sort_keys=True) + "\n")


write("upgrade-config.json", up.Plan(machine, target, "20G75", "13.5", stub, [], "in-place", space,
                                     None, 200 << 20, 600 << 20, payload))
esp_size = 524_288_000
move = up.EspMove(partno=4, old_start=stub.start + stub.size, new_start=stub.start - esp_size,
                  size=esp_size)
write("grow.json", up.Plan(machine, target, "20G75", "13.5", stub, [], "in-place-grow", space,
                           None, 200 << 20, 600 << 20, payload, move))
write("slot.json", up.Plan(machine, target, "20G75", "13.5", stub, [], "slot", space,
                           up.Extent(start=800 << 30, size=10 << 30), 200 << 20, 600 << 20, payload))
target.caution = "Touch ID — not yet on 27.2 \U0001F512 \"quoted\" \\ tab\there"
write("caution.json", up.Plan(machine, target, "20G75", "13.5", stub, [], "in-place", space,
                              None, 200 << 20, 600 << 20, payload))
