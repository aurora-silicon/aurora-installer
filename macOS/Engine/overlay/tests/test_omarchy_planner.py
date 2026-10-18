# SPDX-License-Identifier: MIT
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest


class FakeOSInstaller:
    def __init__(self, dutil, data, template):
        self.min_recommended_size = template["minimum_size"]
        self.min_size = template.get("floor_size", template["minimum_size"])


sys.modules["osinstall"] = SimpleNamespace(OSInstaller=FakeOSInstaller)
sys.modules["util"] = SimpleNamespace(
    align_down=lambda value, alignment: value // alignment * alignment,
)
sys.path.insert(
    0,
    str(Path(__file__).resolve().parents[1] / "src"),
)

from omarchy_contract import Journal  # noqa: E402
from omarchy_execution import _select_candidate, ExecutionAdmissionError  # noqa: E402
from omarchy_planner import (  # noqa: E402
    PlanningError,
    collect_inventory,
    emit_inventory,
    emit_plan,
)


class PlannerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.journal = Journal(str(self.root / "engine.jsonl"))
        self.journal.inspection("apple,j314s", "supported")
        self.installer = FakeInstaller()
        self.free = [
            SimpleNamespace(
                name="disk0s3",
                offset=447_750_000_000,
                size=100 * 1024**3 + 123,
            )
        ]
        self.resize = [
            SimpleNamespace(
                name="disk0s2",
                offset=1_000_000_000,
                size=500 * 1024**3,
            )
        ]

    def tearDown(self):
        self.temporary.cleanup()

    def test_macOS_free_floor_is_38GB_on_every_disk_size(self):
        gb = 1_000_000_000
        unit = 1024**2
        for disk_gb in (128, 256, 512, 760, 1000):
            with self.subTest(disk_gb=disk_gb):
                total, used = 120 * gb, 60 * gb
                self.resize[0].size = total
                self.installer.dutil = SimpleNamespace(get_disk_size=lambda _: disk_gb * gb)
                self.installer.resize_bounds = {
                    "total_bytes": total, "free_bytes": total - used,
                    "minimum_size_bytes": used + 38 * gb,
                    "diskutil_minimum_bytes": used + gb,
                    "available_bytes": total - used - 38 * gb,
                }
                (candidate,) = collect_inventory(
                    self.installer, [], self.resize, 2 * gb, unit
                )["candidates"]
                expected = used + 38 * gb
                expected = (expected + unit - 1) // unit * unit
                self.assertEqual(candidate["minimum_container_bytes"], expected)

    def test_exhausted_reserve_is_reported_and_cannot_be_planned(self):
        self.resize[0].size = 200_000_000_000
        self.installer.dutil = SimpleNamespace(get_disk_size=lambda _: 256_000_000_000)
        self.installer.resize_bounds = {
            "total_bytes": 200_000_000_000, "free_bytes": 5_000_000_000,
            "diskutil_minimum_bytes": 196_000_000_000,
            "minimum_size_bytes": 233_000_000_000, "available_bytes": -33_000_000_000,
        }
        inventory = collect_inventory(self.installer, [], self.resize, 2_000_000_000, 1_048_576)
        candidate = inventory["candidates"][0]
        self.assertGreater(candidate["minimum_container_bytes"], candidate["length_bytes"])
        self.assertGreaterEqual(candidate["minimum_container_bytes"], 233_000_000_000)
        layout = self.journal.inventory("disk0", [candidate])
        with self.assertRaises(ValueError):
            self.journal.plan(device_identifier="apple,j314s", layout_digest=layout,
                candidate_kind="resize", source_identifier="disk0s2",
                requested_length_bytes=70 * 1024**3, engine_version="test",
                engine_digest="sha256:" + "d" * 64, metadata_digest="sha256:" + "e" * 64,
                payload_digest="sha256:" + "f" * 64, required_human_steps=["enterOneTrueRecovery", "authenticateMachineOwner"])

    def test_live_admission_enforces_floor_at_boundary_and_after_space_loss(self):
        gb, unit = 1_000_000_000, 1024**2
        self.resize[0].size = 240 * gb
        self.installer.dutil = SimpleNamespace(get_disk_size=lambda _: 256 * gb)
        self.installer.data["os_list"][0]["floor_size"] = 30 * gb
        self.installer.resize_bounds = {
            "total_bytes": 240 * gb, "free_bytes": 100 * gb,
            "minimum_size_bytes": 178 * gb, "diskutil_minimum_bytes": 141 * gb,
            "available_bytes": 62 * gb,
        }
        def candidate():
            return collect_inventory(self.installer, [], self.resize, 2 * gb, unit)["candidates"][0]
        live = candidate()
        length = (live["length_bytes"] - live["minimum_container_bytes"]) // unit * unit
        request = {"candidate_kind": "resize", "source_identifier": "disk0s2",
                   "length_bytes": length, "offset_bytes": live["offset_bytes"] + live["length_bytes"] - length}
        self.assertEqual(_select_candidate(request, [live]), live)
        larger = dict(request, length_bytes=length + unit, offset_bytes=request["offset_bytes"] - unit)
        with self.assertRaises(ExecutionAdmissionError):
            _select_candidate(larger, [live])
        self.installer.resize_bounds["free_bytes"] -= 2 * unit
        with self.assertRaises(ExecutionAdmissionError):
            _select_candidate(request, [candidate()])

    def test_invalid_resize_metrics_fail_closed(self):
        for value in (None, True, -1, 2**64, "256000000000"):
            with self.subTest(value=value):
                self.installer.dutil = SimpleNamespace(get_disk_size=lambda _: value)
                with self.assertRaises(PlanningError):
                    collect_inventory(self.installer, [], self.resize, 2 * 1024**3, 1024**2)

    def test_inventory_uses_asahi_minimums_and_resize_bounds(self):
        inventory = collect_inventory(
            self.installer,
            self.free,
            self.resize,
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )

        self.assertEqual(inventory["system_store_identifier"], "disk0")
        self.assertEqual(len(inventory["candidates"]), 2)
        free, resize = inventory["candidates"]
        self.assertEqual(free["kind"], "resize")
        self.assertEqual(
            free["minimum_install_bytes"],
            66 * 1024**3,
        )
        self.assertEqual(
            free["minimum_container_bytes"],
            320 * 1024**3,
        )
        self.assertEqual(resize["kind"], "free")
        self.assertEqual(resize["length_bytes"], 100 * 1024**3)

    def test_inventory_reports_a_container_too_tight_to_install(self):
        self.installer.resize_bounds = {
            "available_bytes": 40 * 1024**3,
            "minimum_size_bytes": 460 * 1024**3,
        }

        inventory = collect_inventory(
            self.installer,
            [],
            self.resize,
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )

        (resize,) = inventory["candidates"]
        self.assertEqual(resize["kind"], "resize")
        self.assertEqual(resize["minimum_install_bytes"], 66 * 1024**3)
        self.assertEqual(resize["minimum_container_bytes"], 460 * 1024**3)

    def test_tight_disk_installs_at_the_partition_floor(self):
        self.installer.data["os_list"][0]["floor_size"] = 30 * 1024**3
        self.installer.resize_bounds = {
            "available_bytes": 40 * 1024**3,
            "minimum_size_bytes": 460 * 1024**3,
        }

        inventory = collect_inventory(
            self.installer,
            [],
            self.resize,
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )

        (resize,) = inventory["candidates"]
        self.assertEqual(resize["minimum_install_bytes"], 32 * 1024**3)
        self.assertEqual(resize["minimum_container_bytes"], 460 * 1024**3)

    def test_macOS_reserve_is_not_relaxed_to_fit_partition_floor(self):
        # Asahi's 38GB reserve leaves less than the partition floor, but
        # diskutil's smaller minimum must not override the macOS reserve.
        self.installer.data["os_list"][0]["floor_size"] = 30 * 1024**3
        self.resize[0].size = 200 * 1024**3
        self.installer.resize_bounds = {
            "available_bytes": 20 * 1024**3,
            "minimum_size_bytes": 180 * 1024**3,
            "total_bytes": 200 * 1024**3,
            "diskutil_minimum_bytes": 150 * 1024**3,
        }

        inventory = collect_inventory(
            self.installer,
            [],
            self.resize,
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )

        (resize,) = inventory["candidates"]
        self.assertEqual(resize["minimum_install_bytes"], 32 * 1024**3)
        self.assertEqual(resize["minimum_container_bytes"], 180 * 1024**3)

    def test_stricter_diskutil_limit_is_never_relaxed(self):
        self.installer.data["os_list"][0]["floor_size"] = 30 * 1024**3
        self.resize[0].size = 200 * 1024**3
        self.installer.resize_bounds = {
            "available_bytes": 20 * 1024**3,
            "minimum_size_bytes": 180 * 1024**3,
            "diskutil_minimum_bytes": 190 * 1024**3,
        }

        inventory = collect_inventory(
            self.installer,
            [],
            self.resize,
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )

        (resize,) = inventory["candidates"]
        self.assertEqual(resize["minimum_install_bytes"], 32 * 1024**3)
        self.assertEqual(resize["minimum_container_bytes"], 190 * 1024**3)

    def test_resize_limits_do_not_jump_when_more_space_is_freed(self):
        gib = 1024**3
        self.installer.data["os_list"][0].update(
            floor_size=30 * gib, minimum_size=60 * gib
        )
        self.resize[0].size = 200 * gib
        previous_container = 200 * gib
        for available in (32, 41, 42, 61, 62, 71, 72):
            with self.subTest(available_gib=available):
                container = (200 - available) * gib
                self.installer.resize_bounds = {
                    "available_bytes": available * gib,
                    "minimum_size_bytes": container,
                    "diskutil_minimum_bytes": min(150 * gib, container),
                }
                inventory = collect_inventory(
                    self.installer, [], self.resize, 2 * gib, 1024**2
                )
                (resize,) = inventory["candidates"]
                self.assertEqual(resize["minimum_install_bytes"], 32 * gib)
                self.assertLessEqual(
                    resize["minimum_container_bytes"], previous_container
                )
                self.assertEqual(resize["recommended_install_bytes"], 62 * gib)
                self.assertGreaterEqual(resize["recommended_container_bytes"], container)
                previous_container = resize["minimum_container_bytes"]

                # The same plan remains admissible as Asahi crosses the
                # old fallback thresholds between inspect and plan.
                journal = Journal(str(self.root / f"space-{available}.jsonl"))
                journal.inspection("apple,j314s", "supported")
                layout = journal.inventory("disk0", [resize])
                journal.plan(
                    device_identifier="apple,j314s",
                    layout_digest=layout,
                    candidate_kind="resize",
                    source_identifier=resize["source_identifier"],
                    requested_length_bytes=32 * gib,
                    engine_version="test",
                    engine_digest="sha256:" + "d" * 64,
                    metadata_digest="sha256:" + "e" * 64,
                    payload_digest="sha256:" + "f" * 64,
                    required_human_steps=[
                        "enterOneTrueRecovery", "authenticateMachineOwner"
                    ],
                )

    def test_free_extent_between_floor_and_recommended_is_offered(self):
        self.installer.data["os_list"][0]["floor_size"] = 30 * 1024**3
        self.free[0].size = 40 * 1024**3

        inventory = collect_inventory(
            self.installer,
            self.free,
            [],
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )

        (free,) = inventory["candidates"]
        self.assertEqual(free["kind"], "free")
        self.assertEqual(free["minimum_install_bytes"], 32 * 1024**3)
        self.assertEqual(free["length_bytes"], 40 * 1024**3)

    def test_inventory_reports_a_container_with_nothing_to_give(self):
        self.installer.resize_bounds = {
            "available_bytes": 0,
            "minimum_size_bytes": 500 * 1024**3,
        }

        inventory = collect_inventory(
            self.installer,
            [],
            self.resize,
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )

        self.assertEqual(inventory["candidates"][0]["minimum_container_bytes"], 500 * 1024**3)

    def test_emit_inventory_and_plan_share_one_journal_contract(self):
        inventory = emit_inventory(
            self.installer,
            self.journal,
            self.free,
            [],
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )
        planning_request = {
            "schema_version": 1,
            "layout_digest": inventory["layout_digest"],
            "candidate_kind": "free",
            "source_identifier": "disk0s3",
            "requested_length_bytes": 80 * 1024**3,
        }
        identity = {
            "schema_version": 1,
            "engine_version": "v0.9.0-omarchy.2",
            "engine_digest": "sha256:" + "d" * 64,
            "metadata_digest": "sha256:" + "e" * 64,
            "payload_digest": "sha256:" + "f" * 64,
        }
        request_path = self._write("planning-request.json", planning_request)
        identity_path = self._write("planning-identity.json", identity)

        plan_digest = emit_plan(
            self.journal,
            str(request_path),
            str(identity_path),
            "apple,j314s",
            1024**2,
        )

        self.assertEqual(self.journal.sequence, 3)
        self.assertEqual(
            self.journal.plan_payload["plan_digest"],
            plan_digest,
        )
        self.assertEqual(
            self.journal.plan_payload["length_bytes"],
            80 * 1024**3,
        )

    def test_unknown_planning_field_is_rejected(self):
        inventory = emit_inventory(
            self.installer,
            self.journal,
            self.free,
            [],
            stub_size=2 * 1024**3,
            part_align=1024**2,
        )
        request = {
            "schema_version": 1,
            "layout_digest": inventory["layout_digest"],
            "candidate_kind": "free",
            "source_identifier": "disk0s3",
            "requested_length_bytes": 80 * 1024**3,
            "unexpected": True,
        }
        identity = {
            "schema_version": 1,
            "engine_version": "v0.9.0-omarchy.2",
            "engine_digest": "sha256:" + "d" * 64,
            "metadata_digest": "sha256:" + "e" * 64,
            "payload_digest": "sha256:" + "f" * 64,
        }
        request_path = self._write("planning-request.json", request)
        identity_path = self._write("planning-identity.json", identity)

        with self.assertRaisesRegex(
            PlanningError,
            "unexpected planning request fields",
        ):
            emit_plan(
                self.journal,
                str(request_path),
                str(identity_path),
                "apple,j314s",
                1024**2,
            )

    def test_repair_plan_uses_exact_extent_and_no_reinstall_recovery_step(self):
        candidate = {
            "kind": "repair",
            "source_identifier": "disk0s2",
            "offset_bytes": 857_747_943_424,
            "length_bytes": 137_438_953_472,
            "minimum_install_bytes": 137_438_953_472,
            "minimum_container_bytes": 0,
            "identity_digest": "sha256:" + "9" * 64,
        }
        inventory = self.journal.inventory("disk0", [candidate])
        request_path = self._write(
            "repair-request.json",
            {
                "schema_version": 1,
                "layout_digest": inventory,
                "candidate_kind": "repair",
                "source_identifier": "disk0s2",
                "requested_length_bytes": 137_438_953_472,
            },
        )
        identity_path = self._write(
            "repair-identity.json",
            {
                "schema_version": 1,
                "engine_version": "v0.9.0-omarchy.7",
                "engine_digest": "sha256:" + "d" * 64,
                "metadata_digest": "sha256:" + "e" * 64,
                "payload_digest": "sha256:" + "f" * 64,
                "repair_manifest_digest": "sha256:" + "7" * 64,
            },
        )

        emit_plan(
            self.journal,
            str(request_path),
            str(identity_path),
            "apple,j314s",
            1024**2,
        )

        self.assertEqual(
            self.journal.plan_payload["required_human_steps"],
            ["authenticateMachineOwner"],
        )
        self.assertEqual(
            self.journal.plan_payload["offset_bytes"],
            857_747_943_424,
        )
        self.assertEqual(
            self.journal.plan_payload["repair_manifest_digest"],
            "sha256:" + "7" * 64,
        )

    def test_multiple_omarchy_targets_are_rejected(self):
        self.installer.data["os_list"].append(
            dict(self.installer.data["os_list"][0])
        )

        with self.assertRaisesRegex(
            PlanningError,
            "exactly one Omarchy Apple full-OS target",
        ):
            collect_inventory(
                self.installer,
                self.free,
                [],
                stub_size=2 * 1024**3,
                part_align=1024**2,
            )

    def _write(self, name, value):
        path = self.root / name
        path.write_text(
            json.dumps(value, separators=(",", ":"), sort_keys=True),
            encoding="utf-8",
        )
        path.chmod(0o400)
        return path


class FakeInstaller:
    def __init__(self):
        self.data = {
            "os_list": [
                {
                    "omarchy_target": "apple-silicon-full-os",
                    "minimum_size": 64 * 1024**3,
                }
            ]
        }
        self.dutil = SimpleNamespace(get_disk_size=lambda _: 512 * 1024**3)
        self.sys_disk = "disk0"
        self.resize_bounds = {
            "available_bytes": 180 * 1024**3,
            "minimum_size_bytes": 320 * 1024**3,
        }

    def get_resize_bounds(self, part):
        bounds = dict(self.resize_bounds)
        bounds.setdefault("total_bytes", part.size)
        bounds.setdefault("free_bytes", part.size - bounds["minimum_size_bytes"] + 38_000_000_000)
        bounds.setdefault("diskutil_minimum_bytes", bounds["minimum_size_bytes"])
        return bounds


if __name__ == "__main__":
    unittest.main()
