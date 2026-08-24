import hashlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import osinstall
import windows


class Response(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def getcode(self):
        return self.status


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.urls = []

    def open(self, request, timeout=None):
        self.urls.append(request.full_url if hasattr(request, "full_url") else request)
        return Response(self.responses.pop(0))


class FakeDiskUtil:
    def __init__(self):
        self.calls = []

    def addPartition(self, after, partition_type, label, size):
        self.calls.append((after, partition_type, label, size))
        index = len(self.calls) + 2
        return SimpleNamespace(
            name=f"disk0s{index}",
            uuid=f"10000000-0000-0000-0000-{index:012d}",
        )


class FakeStageDiskUtil:
    def __init__(self, mounts):
        self.mounts = mounts
        self.disks = {
            "disk0": {"DiskUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"}
        }

    def mount(self, device):
        return str(self.mounts[device])

    def get(self, *args):
        raise AssertionError(f"unexpected diskutil fallback: {args}")


class MountedDirectory:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        return self.path

    def __exit__(self, *args):
        return False


def add_driver_package(root, directory, inf_name, payload_suffix):
    package = root / directory
    package.mkdir(parents=True, exist_ok=True)
    catalog = Path(inf_name).with_suffix(".cat").name
    (package / inf_name).write_text(
        f"[Version]\r\nSignature=\"$WINDOWS NT$\"\r\nCatalogFile={catalog}\r\n"
    )
    (package / catalog).write_bytes(b"test-signed-catalog")
    (package / Path(inf_name).with_suffix(payload_suffix).name).write_bytes(
        b"test-signed-binary"
    )
    return package


class WindowsDeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads((ROOT / "data" / "installer_data.json").read_text())
        cls.option = cls.data["os_list"][2]
        cls.pin = json.loads((ROOT / "data" / "windows-iso.json").read_text())

    def test_iso_pin_is_immutable_and_arm64(self):
        self.assertEqual("25H2", self.pin["release"])
        self.assertEqual("26200.8037", self.pin["build"])
        self.assertEqual("arm64", self.pin["architecture"])
        self.assertEqual(7994415104, self.pin["size"])
        self.assertEqual(
            "638aa2c88e94385b00f4f178d071e3df0b7d9e335577a83bd533b7f2eb65adf0",
            self.pin["sha256"],
        )

    def test_windows_layout_keeps_every_write_in_new_partitions(self):
        parts = self.option["partitions"]
        self.assertEqual(
            ["esp", "windows-media", "windows-msr", "windows-target"],
            [part["role"] for part in parts],
        )
        self.assertEqual("EFI", parts[0]["type"])
        self.assertEqual("exfat", parts[1]["format"])
        self.assertEqual("E3C9E316-0B5C-4DB8-817D-F92DF00215AE", parts[2]["type"])
        self.assertEqual("exfat", parts[3]["format"])
        self.assertTrue(parts[3]["expand"])

    @mock.patch("osinstall.subprocess.run")
    def test_upstream_partition_sequence_is_reused(self, run):
        dutil = FakeDiskUtil()
        installer = osinstall.OSInstaller(dutil, self.data, self.option)
        installer.partition_disk("disk0s2", installer.min_size)
        self.assertEqual("disk0s2", dutil.calls[0][0])
        self.assertEqual("%EFI%", dutil.calls[0][1])
        self.assertEqual("disk0s3", dutil.calls[1][0])
        self.assertEqual("%EBD0A0A2-B9E5-4433-87C0-68B6B72699C7%", dutil.calls[1][1])
        self.assertEqual("%E3C9E316-0B5C-4DB8-817D-F92DF00215AE%", dutil.calls[2][1])
        self.assertEqual("%EBD0A0A2-B9E5-4433-87C0-68B6B72699C7%", dutil.calls[3][1])
        self.assertEqual(4, len(dutil.calls))
        self.assertEqual(3, run.call_count)

    def test_winpe_verifies_identity_before_first_destructive_write(self):
        script = (ROOT / "data" / "windows" / "aurora-deploy.cmd").read_text()
        identity = script.index('if /I not "!DISKID!"=="{!disk_guid!}"')
        target = script.index('if not "!WINCOUNT!"=="1"')
        write_boundary = script.index("AURORA_WRITE_BOUNDARY_VERIFIED")
        format_target = script.index("format fs=ntfs quick label=Windows")
        apply_image = script.index("Dism.exe /Apply-Image")
        add_drivers = script.index("Dism.exe /Image:!WINVOL!\\ /Add-Driver")
        testsigning = script.index("{default} testsigning on")
        fallback = script.index('"!ESPVOL!\\EFI\\Microsoft\\Boot\\bootmgfw.efi" "!ESPVOL!\\EFI\\Boot\\bootaa64.efi"')
        self.assertLess(identity, target)
        self.assertLess(target, write_boundary)
        self.assertLess(write_boundary, format_target)
        self.assertLess(format_target, apply_image)
        self.assertLess(apply_image, add_drivers)
        self.assertLess(add_drivers, testsigning)
        self.assertLess(testsigning, fallback)
        self.assertIn("select volume !WINVOL:~0,1!", script)
        self.assertNotIn("assign letter=W", script)
        self.assertNotIn("nointegritychecks", script.lower())

        startnet = (ROOT / "data/windows/startnet.cmd").read_text()
        self.assertLess(startnet.index("AURORA_WINPE_DRVLOAD"), startnet.index("AURORA_DEPLOY="))
        bcd_helper = (ROOT / "tools/bcd-set-testsigning.c").read_text()
        self.assertIn('"16000049"', bcd_helper)
        self.assertIn("hivex_commit", bcd_helper)

    def test_microsoft_resolver_refuses_release_drift(self):
        sku = {
            "Skus": [
                {
                    "Id": self.pin["sku_id"],
                    "Language": self.pin["language"],
                    "ProductDisplayName": self.pin["product_display_name"],
                }
            ]
        }
        link = "https://software.download.prss.microsoft.com/dbazure/pinned.iso?token=short"
        links = {
            "ProductDownloadOptions": [
                {
                    "Uri": link,
                    "Language": self.pin["language"],
                    "ProductDisplayName": self.pin["product_display_name"],
                }
            ]
        }
        opener = FakeOpener(
            [
                b"page",
                b'window.dfp={url:"https://ov-df.microsoft.com/fingerprint"}',
                b"fingerprint",
                json.dumps(sku).encode(),
                json.dumps(links).encode(),
            ]
        )
        self.assertEqual(link, windows.resolve_microsoft_iso_url(self.pin, opener))
        self.assertIn("ProductEditionId=3324", opener.urls[3])
        self.assertIn("SKU=20086", opener.urls[4])

        drift = dict(sku)
        drift["Skus"] = [dict(sku["Skus"][0], ProductDisplayName="Windows 11 Arm64 26H1")]
        opener = FakeOpener(
            [
                b"page",
                b'window.dfp={url:"https://ov-df.microsoft.com/fingerprint"}',
                b"fingerprint",
                json.dumps(drift).encode(),
            ]
        )
        with self.assertRaisesRegex(windows.WindowsDeploymentError, "refusing"):
            windows.resolve_microsoft_iso_url(self.pin, opener)

    def test_microsoft_sentinel_rejection_has_verified_local_fallback(self):
        sku = {
            "Skus": [
                {
                    "Id": self.pin["sku_id"],
                    "Language": self.pin["language"],
                    "ProductDisplayName": self.pin["product_display_name"],
                }
            ]
        }
        rejected = {
            "Errors": [
                {
                    "Key": "ErrorSettings.SentinelReject",
                    "Value": "Sentinel marked this request as rejected.",
                }
            ]
        }
        opener = FakeOpener(
            [
                b"page",
                b'window.dfp={url:"https://ov-df.microsoft.com/fingerprint"}',
                b"fingerprint",
                json.dumps(sku).encode(),
                json.dumps(rejected).encode(),
            ]
        )
        with self.assertRaisesRegex(
            windows.WindowsDeploymentError, "AURORA_WINDOWS_ISO"
        ):
            windows.resolve_microsoft_iso_url(self.pin, opener)

    def test_iso_verification_checks_size_and_hash(self):
        payload = b"pinned-iso"
        pin = {"size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "windows.iso"
            path.write_bytes(payload)
            windows.verify_iso(path, pin)
            path.write_bytes(payload + b"drift")
            with self.assertRaisesRegex(windows.WindowsDeploymentError, "size mismatch"):
                windows.verify_iso(path, pin)

    def test_windows_staging_retains_replaceable_proxy_stage2(self):
        contract = json.loads((ROOT / "data" / "stage2.json").read_text())
        self.assertEqual("m1n1/boot.bin", contract["path"])
        self.assertEqual("proxy", contract["mode"])
        self.assertTrue(contract["replaceable"])
        self.assertEqual("proxy", self.option["windows_deployment"]["stage2_mode"])
        self.assertIn("Mu", self.option["windows_deployment"]["boot_method"])

    def test_user_driver_pack_is_snapshotted_before_partitioning(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            supplied = root / "supplied"
            add_driver_package(supplied, "AppleNvme", "AppleNvme.inf", ".sys")
            add_driver_package(
                supplied,
                "AicHal",
                "HalExtAppleInterruptController.inf",
                ".dll",
            )
            add_driver_package(
                supplied, "Input/AppleMtpHid", "AppleMtpHid.inf", ".sys"
            )
            manifest = json.loads((ROOT / "data/windows-driver-pack.json").read_text())
            package_path = root / "windows.zip"
            with zipfile.ZipFile(package_path, "w") as output:
                output.writestr("windows/driver-pack.json", json.dumps(manifest))
                output.writestr("windows/deploy/startnet.cmd", "wpeinit\r\n")
                output.writestr("windows/deploy/aurora-deploy.cmd", "deploy\r\n")
                output.writestr("windows/deploy/SetupComplete.cmd", "bcdedit\r\n")

            with (
                zipfile.ZipFile(package_path) as package,
                mock.patch.dict(
                    "os.environ", {"AURORA_WINDOWS_DRIVERS": str(supplied)}, clear=False
                ),
                mock.patch("windows._resolve_tool", side_effect=lambda name, *_: name),
                mock.patch("windows.obtain_iso", return_value=root / "pinned.iso"),
            ):
                stager = windows.WindowsStager(
                    FakeStageDiskUtil({}), package, self.option["windows_deployment"]
                )
                stager.prepare()

            self.assertNotEqual(supplied, stager.driver_root)
            self.assertEqual(["AppleNvme/AppleNvme.inf"], stager.driver_boot_infs)
            self.assertTrue((stager.driver_root / "Input/AppleMtpHid/AppleMtpHid.inf").is_file())
            self.assertTrue(stager.driver_sha256)
            supplied.joinpath("AppleNvme/AppleNvme.sys").write_bytes(b"changed")
            self.assertEqual(
                b"test-signed-binary",
                stager.driver_root.joinpath("AppleNvme/AppleNvme.sys").read_bytes(),
            )
            stager.driver_cache.cleanup()

    def test_every_supplied_inf_requires_its_generated_catalog(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            add_driver_package(root, "AppleNvme", "AppleNvme.inf", ".sys")
            add_driver_package(
                root, "AicHal", "HalExtAppleInterruptController.inf", ".dll"
            )
            optional = root / "Input/Keyboard"
            optional.mkdir(parents=True)
            (optional / "AppleKeyboard.inf").write_text("[Version]\r\n")
            manifest = json.loads((ROOT / "data/windows-driver-pack.json").read_text())
            with self.assertRaisesRegex(windows.WindowsDeploymentError, "CatalogFile"):
                windows._validate_driver_pack(root, manifest)

    @mock.patch("windows.subprocess.run")
    def test_boot_wim_verification_uses_wimlib_path_option(self, run):
        with tempfile.TemporaryDirectory() as tmp:
            boot_wim = Path(tmp) / "boot.wim"
            startnet = Path(tmp) / "startnet.cmd"
            drivers = Path(tmp) / "drivers"
            (drivers / "AppleNvme").mkdir(parents=True)
            boot_wim.write_bytes(b"wim")
            startnet.write_text("wpeinit\n")
            (drivers / "boot-drivers.txt").write_text("AppleNvme\\AppleNvme.inf\r\n")
            (drivers / "AppleNvme/AppleNvme.inf").write_text("inf")
            stager = object.__new__(windows.WindowsStager)
            stager.wimlib = "wimlib-imagex"
            stager.driver_boot_infs = ["AppleNvme/AppleNvme.inf"]
            stager._patch_boot_wim(boot_wim, startnet, drivers)

        updates = [call for call in run.call_args_list if call.args[0][1] == "update"]
        verifies = [call for call in run.call_args_list if call.args[0][1] == "dir"]
        self.assertEqual(2, len(updates))
        self.assertEqual(6, len(verifies))
        self.assertIn(b"/Aurora/BootDrivers/AppleNvme", updates[0].kwargs["input"])
        self.assertTrue(
            any("--path=/Aurora/BootDrivers/AppleNvme/AppleNvme.inf" in call.args[0] for call in verifies)
        )

    def test_stager_writes_only_its_three_new_filesystems(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            iso = root / "iso"
            esp = root / "esp"
            media = root / "media"
            target = root / "target"
            for path in (
                iso / "boot",
                iso / "efi/Microsoft/Boot",
                iso / "efi/Boot",
                iso / "sources",
                esp,
                media,
                target,
            ):
                path.mkdir(parents=True, exist_ok=True)
            (iso / "boot" / "bcd").write_bytes(b"setup-bcd")
            (iso / "efi/Microsoft/Boot/BCD").write_bytes(b"setup-bcd")
            (iso / "efi/Boot/bootaa64.efi").write_bytes(b"setup-loader")
            (iso / "sources" / "boot.wim").write_bytes(b"boot-wim")
            (iso / "sources" / "install.wim").write_bytes(b"install-wim")
            (esp / "m1n1").mkdir()
            (esp / "m1n1" / "boot.bin").write_bytes(b"proxy-stage2")

            driver_root = root / "drivers"
            add_driver_package(driver_root, "AppleNvme", "AppleNvme.inf", ".sys")
            add_driver_package(
                driver_root,
                "AicHal",
                "HalExtAppleInterruptController.inf",
                ".dll",
            )
            add_driver_package(
                driver_root,
                "Input/AppleMtpHid",
                "AppleMtpHid.inf",
                ".sys",
            )
            add_driver_package(
                driver_root,
                "Input/AppleKbdBacklight",
                "AppleKbdBacklight.inf",
                ".sys",
            )

            package_path = root / "windows.zip"
            with zipfile.ZipFile(package_path, "w") as output:
                output.writestr(
                    "windows/driver-pack.json",
                    json.dumps(
                        {
                            "schema": 1,
                            "source": "user-supplied",
                        }
                    ),
                )
                output.writestr("windows/deploy/startnet.cmd", "wpeinit\r\n")
                output.writestr("windows/deploy/aurora-deploy.cmd", "deploy\r\n")
                output.writestr("windows/deploy/SetupComplete.cmd", "bcdedit\r\n")

            infos = [
                SimpleNamespace(name="disk0s3", uuid="11111111-1111-1111-1111-111111111111"),
                SimpleNamespace(name="disk0s4", uuid="22222222-2222-2222-2222-222222222222"),
                SimpleNamespace(name="disk0s5", uuid="33333333-3333-3333-3333-333333333333"),
                SimpleNamespace(name="disk0s6", uuid="44444444-4444-4444-4444-444444444444"),
            ]
            mounts = {"disk0s3": esp, "disk0s4": media, "disk0s6": target}
            with zipfile.ZipFile(package_path) as package:
                stager = windows.WindowsStager(
                    FakeStageDiskUtil(mounts), package, self.option["windows_deployment"]
                )
                stager.iso_path = root / "pinned.iso"
                stager.wimlib = "wimlib-imagex"
                stager.bcd_tool = "bcd-set-testsigning"
                stager.driver_root = driver_root
                stager.driver_boot_infs = ["AppleNvme/AppleNvme.inf"]
                stager.driver_sha256 = "a" * 64
                stager.driver_bytes = 1234
                stager.driver_files = 12
                driver_cache = mock.Mock()
                stager.driver_cache = driver_cache
                with (
                    mock.patch("windows.mounted_iso", return_value=MountedDirectory(iso)),
                    mock.patch.object(stager, "_patch_boot_wim") as patch_wim,
                    mock.patch("windows.os.sync"),
                    mock.patch("windows.subprocess.run") as run,
                ):
                    stager.stage(self.option["partitions"], infos)

            media_token = (media / "AURORA-WINDOWS-MEDIA.TAG").read_text().strip()
            self.assertEqual(media_token, (esp / "AURORA-ESP.TAG").read_text().strip())
            self.assertEqual(
                media_token, (target / "AURORA-WINDOWS-TARGET.TAG").read_text().strip()
            )
            self.assertEqual(["AURORA-WINDOWS-TARGET.TAG"], [p.name for p in target.iterdir()])
            self.assertEqual(b"proxy-stage2", (esp / "m1n1" / "boot.bin").read_bytes())
            self.assertTrue((media / "sources" / "install.wim").is_file())
            self.assertTrue((media / "Aurora/Drivers/AicHal/HalExtAppleInterruptController.dll").is_file())
            self.assertTrue((media / "Aurora/Drivers/Input/AppleMtpHid/AppleMtpHid.sys").is_file())
            self.assertTrue((media / "Aurora/Drivers/Input/AppleKbdBacklight/AppleKbdBacklight.sys").is_file())
            cfg = (media / "Aurora" / "deploy.cfg").read_text()
            self.assertIn("disk_guid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", cfg)
            self.assertIn("image_name=Windows 11 Pro", cfg)
            patch_wim.assert_called_once_with(
                esp / "sources" / "boot.wim",
                media / "Aurora" / "startnet.cmd",
                media / "Aurora" / "Drivers",
            )
            run.assert_called_once_with(
                ["bcd-set-testsigning", str(esp / "efi/Microsoft/Boot/BCD")],
                check=True,
                stdout=windows.subprocess.PIPE,
            )
            driver_cache.cleanup.assert_called_once()


if __name__ == "__main__":
    unittest.main()
