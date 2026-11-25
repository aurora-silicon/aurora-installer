# SPDX-License-Identifier: MIT
import copy, hashlib, json, os, pathlib, sys, tempfile, unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools" / "upgrade"))
import aurora_upgrade as au  # noqa: E402

POLICY = au.load_policy(REPO / "macOS/Sources/AuroraAppleInstaller/NativeInspectionPolicySource.swift")
QUAL = json.loads((REPO / "macOS/scripts/firmware-qualification.json").read_text())

# The lab M2 Air's partition table (4 KiB sectors), from sfdisk --json.
J413_TABLE = {"partitiontable": {"label": "gpt", "sectorsize": 4096, "firstlba": 6, "lastlba": 61279338,
    "partitions": [
        {"node": "/dev/nvme0n1p1", "start": 6, "size": 128000, "type": "69646961-6700-11AA-AA11-00306543ECAC"},
        {"node": "/dev/nvme0n1p2", "start": 128006, "size": 36913402, "type": au.APFS_TYPE},
        {"node": "/dev/nvme0n1p3", "start": 44100394, "size": 610304, "type": au.APFS_TYPE},
        {"node": "/dev/nvme0n1p4", "start": 44710698, "size": 128000, "type": "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"},
        {"node": "/dev/nvme0n1p5", "start": 44838698, "size": 262144, "type": "0FC63DAF-8483-4772-8E79-3D69D8477DE4"},
        {"node": "/dev/nvme0n1p6", "start": 45100842, "size": 14867712, "type": "0FC63DAF-8483-4772-8E79-3D69D8477DE4"},
        {"node": "/dev/nvme0n1p7", "start": 59968630, "size": 1310709, "type": "52637672-7900-11AA-AA11-00306543ECAC"}]}}

GROUP = "11111111-2222-4333-8444-555555555555"
INFO = """container
volume slot 0: Aurora - Data
  uuid         11111111-2222-4333-8444-555555555555
  group uuid   11111111-2222-4333-8444-555555555555
  role         data(0x0040)
  sealed       false
  encrypted    true
volume slot 1: Aurora
  uuid         66666666-2222-4333-8444-555555555555
  group uuid   11111111-2222-4333-8444-555555555555
  role         system(0x0001)
  sealed       false
  encrypted    false
volume slot 2: Preboot
  uuid         77777777-2222-4333-8444-555555555555
  role         preboot(0x0010)
  sealed       false
  encrypted    false
volume slot 3: Recovery
  uuid         88888888-2222-4333-8444-555555555555
  role         recovery(0x0004)
  sealed       false
  encrypted    false
"""
STUB_INFO = {"vgid": GROUP, "system_version": {"ProductBuildVersion": "22G74", "ProductVersion": "13.5"}}


def machine(**kw):
    base = dict(board="j413", chip=0x8112, system_firmware="mBoot-20457.41.3", os_firmware="13.5",
                stub_group=GROUP, esp_partuuid="99999999-2222-4333-8444-555555555555",
                stage1_version="1.0.0b10-g409b7e15")
    base.update(kw)
    return au.Machine(**base)


def admitted(board="j413"):
    """Policy and qualification with this board admitted to 26B123 as experimental."""
    p, q = copy.deepcopy(POLICY), copy.deepcopy(QUAL)
    entry = next(e for e in p["firmware"] if (e.get("pin") or {}).get("build") == "26B123")
    entry["models"] = sorted(set(entry["models"]) | {board})
    q["pins"]["26B123"]["experimental_boards"][board] = {"qualification": "not_hardware_qualified",
                                                         "caution": "The Neural Engine does not start yet."}
    return p, q


def stub():
    return au.Stub("/dev/nvme0n1p3", 44100394 * 4096, 610304 * 4096, au.parse_apfuse_info(INFO))


def plan(policy=None, qual=None, **kw):
    p, q = admitted() if policy is None else (policy, qual)
    args = dict(machine=machine(), stub_info=STUB_INFO, stubs=[stub()], extents=au.free_extents(J413_TABLE),
                policy=p, qualification=q, esp_free=275 << 20, system_free=1400 << 20,
                payload={"bytes": 40 << 20, "dir": "", "stage1": {"version": "1.0.0b17"}})
    args.update(kw)
    return au.make_plan(**args)


class Versions(unittest.TestCase):
    def test_boot_versions(self):
        self.assertTrue(au.version_at_least("mBoot-20457.41.3", "mBoot-20457.41.3"))
        self.assertTrue(au.version_at_least("mBoot-20457.41.3", "iBoot-8422.141.2"))
        self.assertFalse(au.version_at_least("iBoot-11881.140.96", "mBoot-20457.41.3"))
        self.assertTrue(au.version_at_least("27.2", "26.0"))
        self.assertFalse(au.version_at_least("13.5", "27.2"))


class Layout(unittest.TestCase):
    def test_j413_free_extent(self):
        ext = au.free_extents(J413_TABLE)
        big = [e for e in ext if e.size >= au.STUB_BYTES_LARGE]
        self.assertEqual(len(big), 1)
        self.assertEqual(big[0].start % au.ALIGN, 0)
        self.assertGreater(big[0].size, 28_000_000_000)

    def test_stub_recognised(self):
        vols = au.parse_apfuse_info(INFO)
        self.assertTrue(au.is_stub(vols))
        self.assertEqual(stub().system.slot, 1)
        self.assertEqual(stub().group, GROUP)

    def test_sealed_system_is_not_a_stub(self):
        self.assertFalse(au.is_stub(au.parse_apfuse_info(INFO.replace(
            "role         system(0x0001)\n  sealed       false", "role         system(0x0001)\n  sealed       true"))))


class Planning(unittest.TestCase):
    def test_j413_plan(self):
        pl = plan()
        self.assertEqual(pl.target.build, "26B123")
        self.assertEqual(pl.target.stub_bytes, au.STUB_BYTES_LARGE)
        self.assertEqual(pl.stub.device, "/dev/nvme0n1p3")
        self.assertIn("breaking change", au.warning_text(pl))
        self.assertIn("Neural Engine", au.warning_text(pl))
        self.assertEqual(pl.digest(), plan().digest())

    def test_board_not_admitted_is_refused(self):
        with self.assertRaisesRegex(au.Refused, "no pinned startup firmware"):
            plan(POLICY, QUAL)

    def test_old_system_firmware_is_refused(self):
        with self.assertRaisesRegex(au.Refused, "Update macOS"):
            plan(machine=machine(system_firmware="iBoot-11881.140.96"))

    def test_already_on_target(self):
        info = {"vgid": GROUP, "system_version": {"ProductBuildVersion": "26B123", "ProductVersion": "27.2"}}
        with self.assertRaisesRegex(au.Refused, "nothing to do"):
            plan(stub_info=info)

    def test_stub_info_must_name_the_booted_group(self):
        with self.assertRaisesRegex(au.Refused, "refusing to guess"):
            plan(stub_info={**STUB_INFO, "vgid": "11111111-2222-3333-4444-555555555555"})

    def test_no_free_space(self):
        with self.assertRaisesRegex(au.Refused, "free disk"):
            plan(extents=[au.Extent(0, 5 << 30)])

    def test_esp_floor(self):
        with self.assertRaisesRegex(au.Refused, "EFI partition"):
            plan(esp_free=50 << 20)

    def test_second_large_stub_is_refused(self):
        other = au.Stub("/dev/nvme0n1p8", 10 << 30, au.STUB_BYTES_LARGE, au.parse_apfuse_info(
            INFO.replace("11111111-2222-4333-8444-555555555555", "aaaaaaaa-2222-4333-8444-555555555555")))
        with self.assertRaisesRegex(au.Refused, "another startup volume"):
            plan(stubs=[stub(), other])


class Staging(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.root, self.esp, self.payload = t / "system", t / "esp", t / "payload"
        # An Asahi-made stub System volume, as on the lab M2 Air.
        (self.root / "System/Library/CoreServices").mkdir(parents=True)
        (self.root / au.SYSVER).write_bytes(b"<plist>13.5</plist>\n")
        (self.root / "IAPhysicalMedia-disabled.plist").write_bytes(b"<plist>Finish Installation.app</plist>\n")
        (self.root / "Finish Installation.app/Contents/Resources").mkdir(parents=True)
        (self.root / "Finish Installation.app/Contents/Resources/step2.sh").write_bytes(b"#!/bin/sh\n")
        os.symlink("/Volumes/Preboot/x/./Restore", self.root / "Restore")
        app = self.payload / "recovery" / au.APP / "Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "Info.plist").write_bytes(b"<plist/>")
        (app / "MacOS" / "OmarchyRecovery").write_bytes(b"\xcf\xfa\xed\xfe app")
        (self.payload / "stage1").mkdir()
        (self.payload / "stage1" / "aura-boot.macho").write_bytes(b"\xcf\xfa\xed\xfe stage1")
        (self.payload / "stage1" / "BUILD-INFO.json").write_text('{"version": "1.0.0b17"}')
        self.esp.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def snapshot(self):
        out = {}
        for p in sorted(self.root.rglob("*")):
            rel = p.relative_to(self.root).as_posix()
            if p.is_symlink():
                out[rel] = "L" + os.readlink(p)
            elif p.is_file():
                out[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
            else:
                out[rel] = "D"
        return out

    def staged_plan(self):
        return plan(payload=au.read_payload(self.payload))

    def test_stage_then_cancel_restores_exactly(self):
        before = self.snapshot()
        pl = self.staged_plan()
        j = au.Journal(self.esp)
        au.write_request(self.esp, pl)
        au.stage_system_volume(self.root, pl, j)
        self.assertEqual((self.root / ".IAPhysicalMedia").read_bytes(), au._plist(au.MARKER))
        self.assertFalse((self.root / au.SYSVER).exists())
        self.assertTrue((self.root / au.SYSVER_HIDDEN).exists())
        self.assertTrue((self.root / au.APP / "Contents/Info.plist").exists())
        cfg = json.loads((self.root / au.DATA_DIR / "upgrade-config.json").read_text())
        self.assertEqual(cfg["target"]["build"], "26B123")
        self.assertEqual(cfg["plan_sha256"], pl.digest())
        self.assertEqual(j.data["steps"][-1]["kind"], "staged")
        # Running it again changes nothing and adds no step but "staged".
        snap = self.snapshot()
        au.stage_system_volume(self.root, pl, j)
        self.assertEqual(self.snapshot(), snap)
        au.cancel_system_volume(self.root, au.Journal(self.esp).data["steps"])
        self.assertEqual(self.snapshot(), before)
        au.cancel_system_volume(self.root, au.Journal(self.esp).data["steps"])
        self.assertEqual(self.snapshot(), before)

    def test_older_app_is_kept_for_cancel(self):
        (self.root / au.APP / "Contents").mkdir(parents=True)
        (self.root / au.APP / "Contents/Info.plist").write_bytes(b"old")
        before = self.snapshot()
        pl = self.staged_plan()
        au.stage_system_volume(self.root, pl, au.Journal(self.esp))
        self.assertTrue((self.root / (au.APP + au.PREV)).exists())
        au.cancel_system_volume(self.root, au.Journal(self.esp).data["steps"])
        self.assertEqual(self.snapshot(), before)

    def test_foreign_marker_is_refused(self):
        (self.root / ".IAPhysicalMedia").write_bytes(b"someone else's")
        before = self.snapshot()
        with self.assertRaisesRegex(au.Refused, "isn't ours"):
            au.stage_system_volume(self.root, self.staged_plan(), au.Journal(self.esp))
        self.assertEqual(self.snapshot(), before)

    def test_other_plan_staged_is_refused(self):
        pl = self.staged_plan()
        au.write_request(self.esp, pl)
        other = plan(payload=au.read_payload(self.payload), system_free=1500 << 20,
                     machine=machine(stage1_version="x"))
        other.target.caution = "different"
        with self.assertRaisesRegex(au.Refused, "different plan"):
            au.write_request(self.esp, other)

    def test_power_loss_before_marker_resumes(self):
        pl = self.staged_plan()
        j = au.Journal(self.esp)
        real = au._write_new
        def boom(*a, **k):
            raise OSError("power")
        au._write_new = boom
        try:
            with self.assertRaises(OSError):
                au.stage_system_volume(self.root, pl, j)
        finally:
            au._write_new = real
        self.assertFalse((self.root / ".IAPhysicalMedia").exists())
        au.stage_system_volume(self.root, pl, au.Journal(self.esp))
        self.assertTrue((self.root / ".IAPhysicalMedia").exists())

    def test_write_without_hard_links(self):
        real = os.link
        def nolink(*a, **k):
            raise PermissionError(1, "Operation not permitted")
        os.link = nolink
        try:
            target = self.esp / "f.json"
            au._write_new(target, b"one")
            self.assertEqual(target.read_bytes(), b"one")
            with self.assertRaises(FileExistsError):
                au._write_new(target, b"two")
            self.assertEqual(target.read_bytes(), b"one")
            self.assertEqual(sorted(p.name for p in self.esp.iterdir()), ["f.json"])
        finally:
            os.link = real

    def test_payload_checksum(self):
        (self.payload / "stage1" / "SHA256SUMS").write_text("00" * 32 + "  aura-boot.macho\n")
        with self.assertRaisesRegex(au.Refused, "SHA256SUMS"):
            au.read_payload(self.payload)


class DeviceTree(unittest.TestCase):
    def test_read_machine(self):
        with tempfile.TemporaryDirectory() as t:
            dt = pathlib.Path(t)
            (dt / "chosen").mkdir()
            (dt / "compatible").write_bytes(b"apple,j413\0apple,t8112\0apple,arm-platform\0")
            for k, v in {"asahi,iboot1-version": "mBoot-20457.41.3", "asahi,os-fw-version": "13.5",
                         "apfs-preboot-uuid": GROUP.lower(),
                         "asahi,efi-system-partition": "99999999-2222-4333-8444-555555555555"}.items():
                (dt / "chosen" / k).write_bytes(v.encode() + b"\0")
            m = au.read_machine(dt)
            self.assertEqual((m.board, m.chip, m.stub_group), ("j413", 0x8112, GROUP))
            self.assertEqual(m.esp_partuuid, "99999999-2222-4333-8444-555555555555")

    def test_not_aurora(self):
        with tempfile.TemporaryDirectory() as t:
            (pathlib.Path(t) / "chosen").mkdir()
            (pathlib.Path(t) / "compatible").write_bytes(b"apple,j413\0apple,t8112\0")
            with self.assertRaises(au.Refused):
                au.read_machine(t)


if __name__ == "__main__":
    unittest.main()
