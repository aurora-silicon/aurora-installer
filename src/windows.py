# SPDX-License-Identifier: MIT
"""Pinned Windows media download and Aurora-owned partition staging."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import uuid
import zipfile

from util import (
    input_prompt,
    p_error,
    p_info,
    p_message,
    p_plain,
    p_progress,
    p_question,
    p_warning,
    ssize,
)


MICROSOFT_CONNECTOR = "https://www.microsoft.com/software-download-connector/api/"
MICROSOFT_DOWNLOAD_HOST = "software.download.prss.microsoft.com"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)


class WindowsDeploymentError(RuntimeError):
    pass


def _resource_path(relative: str) -> Path:
    override = os.environ.get("AURORA_DATA_DIR")
    candidates = []
    if override:
        candidates.append(Path(override) / relative)
    module = Path(__file__).resolve()
    candidates.extend(
        (
            module.parent.parent / "data" / relative,
            module.parent / relative,
            Path.cwd() / relative,
        )
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise WindowsDeploymentError(f"installer resource is missing: {relative}")


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def load_iso_pin(relative: str = "windows-iso.json") -> dict:
    pin = load_json(_resource_path(relative))
    required = {
        "schema",
        "release",
        "build",
        "architecture",
        "language",
        "locale",
        "image_name",
        "product_edition_id",
        "sku_id",
        "product_display_name",
        "filename",
        "size",
        "sha256",
        "official_page",
        "connector_profile",
        "sentinel_instance_id",
        "sentinel_page_id",
    }
    missing = required - pin.keys()
    if pin.get("schema") != 1 or missing:
        raise WindowsDeploymentError(
            f"invalid Windows ISO pin (missing: {', '.join(sorted(missing))})"
        )
    if pin["architecture"].lower() != "arm64":
        raise WindowsDeploymentError("the pinned Windows ISO is not ARM64")
    if not re.fullmatch(r"[0-9a-f]{64}", pin["sha256"]):
        raise WindowsDeploymentError("the pinned Windows ISO SHA-256 is invalid")
    return pin


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(16 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_iso(path: Path, pin: dict) -> None:
    try:
        size = path.stat().st_size
    except FileNotFoundError as exc:
        raise WindowsDeploymentError(f"Windows ISO does not exist: {path}") from exc
    if size != pin["size"]:
        raise WindowsDeploymentError(
            f"Windows ISO size mismatch: expected {pin['size']}, got {size}"
        )
    actual = sha256_file(path)
    if actual != pin["sha256"]:
        raise WindowsDeploymentError(
            f"Windows ISO SHA-256 mismatch: expected {pin['sha256']}, got {actual}"
        )


def _json_request(opener, url: str) -> dict:
    with opener.open(url, timeout=60) as response:
        return json.load(response)


def resolve_microsoft_iso_url(pin: dict, opener=None) -> str:
    """Resolve Microsoft's expiring URL while refusing any release drift."""
    if opener is None:
        cookies = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(cookies)
        )
        opener.addheaders = [
            ("User-Agent", USER_AGENT),
            ("Referer", pin["official_page"]),
        ]

    with opener.open(pin["official_page"], timeout=60) as response:
        response.read()

    session_id = str(uuid.uuid4())
    sentinel_query = urllib.parse.urlencode(
        {
            "instanceId": pin["sentinel_instance_id"],
            "pageId": pin["sentinel_page_id"],
            "session_id": session_id,
        }
    )
    sentinel_js_url = f"https://ov-df.microsoft.com/mdt.js?{sentinel_query}"
    with opener.open(sentinel_js_url, timeout=60) as response:
        sentinel_js = response.read().decode("utf-8", "replace")
    match = re.search(r'window\.dfp=\{[^}]*?url:"([^"]+)"', sentinel_js)
    if not match:
        raise WindowsDeploymentError("Microsoft download attestation did not initialize")
    with opener.open(match.group(1).replace("&amp;", "&"), timeout=60) as response:
        response.read()

    common = {
        "profile": pin["connector_profile"],
        "SKU": "",
        "friendlyFileName": "",
        "Locale": pin["locale"],
        "sessionID": session_id,
    }
    sku_query = urllib.parse.urlencode(
        {**common, "ProductEditionId": pin["product_edition_id"]}
    )
    sku_data = _json_request(
        opener, f"{MICROSOFT_CONNECTOR}getskuinformationbyproductedition?{sku_query}"
    )
    candidates = [
        sku
        for sku in sku_data.get("Skus", [])
        if sku.get("Id") == pin["sku_id"]
        and sku.get("Language") == pin["language"]
        and sku.get("ProductDisplayName") == pin["product_display_name"]
    ]
    if len(candidates) != 1:
        raise WindowsDeploymentError(
            "Microsoft no longer offers the exact pinned Windows ARM64 SKU; "
            "refusing to download a different build"
        )

    links_query = urllib.parse.urlencode(
        {
            **common,
            "ProductEditionId": "",
            "SKU": pin["sku_id"],
        }
    )
    links = _json_request(
        opener, f"{MICROSOFT_CONNECTOR}GetProductDownloadLinksBySku?{links_query}"
    )
    options = [
        option
        for option in links.get("ProductDownloadOptions", [])
        if option.get("ProductDisplayName") == pin["product_display_name"]
        and option.get("Language") == pin["language"]
    ]
    if len(options) != 1:
        errors = links.get("Errors") or links.get("ValidationContainer", {}).get("Errors")
        if any(
            error.get("Key") == "ErrorSettings.SentinelReject"
            for error in (errors or [])
            if isinstance(error, dict)
        ):
            raise WindowsDeploymentError(
                "Microsoft rejected automatic ISO link creation. Download the exact "
                f"pinned ISO from {pin['official_page']} and rerun with "
                "AURORA_WINDOWS_ISO=/absolute/path/to/iso; Aurora will still verify "
                "its size and SHA-256 before partitioning"
            )
        raise WindowsDeploymentError(
            f"Microsoft did not return the exact pinned ISO download: {errors or links}"
        )
    url = options[0].get("Uri", "")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != MICROSOFT_DOWNLOAD_HOST:
        raise WindowsDeploymentError("Microsoft returned an unexpected ISO download host")
    return url


def download_iso(url: str, destination: Path, pin: dict, opener=None) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    if destination.exists():
        p_progress("Verifying cached Windows ISO...")
        verify_iso(destination, pin)
        return destination

    if opener is None:
        opener = urllib.request.build_opener()
        opener.addheaders = [("User-Agent", USER_AGENT)]

    offset = partial.stat().st_size if partial.exists() else 0
    headers = {"Range": f"bytes={offset}-"} if offset else {}
    request = urllib.request.Request(url, headers=headers)
    with opener.open(request, timeout=120) as response:
        status = getattr(response, "status", response.getcode())
        if offset and status != 206:
            offset = 0
            mode = "wb"
        else:
            mode = "ab" if offset else "wb"
        p_message(
            f"Downloading pinned Windows 11 {pin['release']} ARM64 "
            f"(build {pin['build']}, {ssize(pin['size'])})..."
        )
        received = offset
        with partial.open(mode) as stream:
            while True:
                chunk = response.read(8 * 1024 * 1024)
                if not chunk:
                    break
                stream.write(chunk)
                received += len(chunk)
                progress = min(100.0, received * 100.0 / pin["size"])
                sys.stdout.write(f"\r  {progress:6.2f}% ({ssize(received)})")
                sys.stdout.flush()
        print()
    verify_iso(partial, pin)
    os.replace(partial, destination)
    return destination


def obtain_iso(pin: dict) -> Path:
    local = os.environ.get("AURORA_WINDOWS_ISO")
    if local:
        path = Path(local).expanduser().resolve()
        p_progress(f"Verifying pinned Windows ISO: {path}")
        verify_iso(path, pin)
        return path

    cache = Path(
        os.environ.get("AURORA_WINDOWS_CACHE", "/private/tmp/aurora-windows-cache")
    )
    destination = cache / pin["filename"]
    if destination.exists():
        p_progress(f"Using cached Windows ISO: {destination}")
        verify_iso(destination, pin)
        return destination

    override_url = os.environ.get("AURORA_WINDOWS_ISO_URL")
    if override_url:
        url = override_url
    else:
        p_progress("Requesting the pinned ISO from Microsoft...")
        url = resolve_microsoft_iso_url(pin)
    return download_iso(url, destination, pin)


def _resolve_tool(name: str, env_name: str, candidates: tuple[str, ...]) -> str:
    override = os.environ.get(env_name)
    if override and os.access(override, os.X_OK):
        return override
    found = shutil.which(name)
    if found:
        return found
    for candidate in candidates:
        if os.access(candidate, os.X_OK):
            return candidate
    raise WindowsDeploymentError(
        f"{name} is required before partitioning; install it or set {env_name}"
    )


@contextmanager
def mounted_iso(path: Path):
    result = subprocess.run(
        ["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(path)],
        check=True,
        stdout=subprocess.PIPE,
    )
    data = plistlib.loads(result.stdout)
    entities = data.get("system-entities", [])
    mounted = [entity for entity in entities if entity.get("mount-point")]
    if not mounted:
        raise WindowsDeploymentError("hdiutil mounted the ISO without a filesystem")
    entity = mounted[-1]
    try:
        yield Path(entity["mount-point"])
    finally:
        subprocess.run(
            ["hdiutil", "detach", entity["dev-entry"]],
            check=True,
            stdout=subprocess.PIPE,
        )


def _child_casefold(parent: Path, name: str) -> Path:
    wanted = name.casefold()
    for child in parent.iterdir():
        if child.name.casefold() == wanted:
            return child
    raise WindowsDeploymentError(f"pinned ISO is missing {parent.name}/{name}")


def _copy_tree(source: Path, destination: Path) -> None:
    shutil.copytree(source, destination, dirs_exist_ok=True, copy_function=shutil.copy2)


def _driver_inventory(root: Path, max_bytes: int) -> tuple[list[tuple[str, int, str]], str, int]:
    rows = []
    total = 0
    invalid = set('<>:"\\|?*')
    try:
        entries = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
    except OSError as exc:
        raise WindowsDeploymentError(f"unable to enumerate driver pack: {exc}") from exc
    for entry in entries:
        relative = entry.relative_to(root)
        if entry.is_symlink():
            raise WindowsDeploymentError(f"driver pack may not contain symlinks: {relative}")
        if ".git" in relative.parts:
            raise WindowsDeploymentError("select an assembled driver pack, not a Git checkout")
        if entry.is_dir():
            continue
        if not entry.is_file():
            raise WindowsDeploymentError(f"unsupported driver-pack entry: {relative}")
        for part in relative.parts:
            if (
                not part
                or part.endswith((" ", "."))
                or any(ord(char) < 0x20 or char in invalid for char in part)
            ):
                raise WindowsDeploymentError(f"driver-pack path is not Windows-safe: {relative}")
        size = entry.stat().st_size
        total += size
        if total > max_bytes:
            raise WindowsDeploymentError(
                f"driver pack exceeds its {ssize(max_bytes)} staging limit"
            )
        rows.append((relative.as_posix(), size, sha256_file(entry)))
    if not rows:
        raise WindowsDeploymentError("driver pack is empty")
    encoded = json.dumps(rows, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return rows, hashlib.sha256(encoded).hexdigest(), total


def _validate_driver_pack(root: Path, manifest: dict) -> list[str]:
    requirements = manifest.get("required_infs")
    if not isinstance(requirements, list) or not requirements:
        raise WindowsDeploymentError("driver-pack manifest has no required INF contracts")
    infs = [path for path in root.rglob("*") if path.is_file() and path.suffix.casefold() == ".inf"]
    for inf in infs:
        raw = inf.read_bytes()
        text = None
        encodings = ("utf-16",) if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else ("utf-8-sig", "cp1252")
        for encoding in encodings:
            try:
                text = raw.decode(encoding)
                break
            except UnicodeError:
                continue
        if text is None:
            raise WindowsDeploymentError(f"unable to decode driver INF: {inf.relative_to(root)}")
        catalogs = re.findall(
            r"(?im)^\s*CatalogFile(?:\.[^=\s]+)?\s*=\s*([^;\r\n]+)", text
        )
        if not catalogs:
            raise WindowsDeploymentError(
                f"driver INF has no CatalogFile directive: {inf.relative_to(root)}"
            )
        siblings = {path.name.casefold() for path in inf.parent.iterdir() if path.is_file()}
        for catalog in catalogs:
            filename = catalog.strip().strip('"')
            if not filename.casefold().endswith(".cat") or filename.casefold() not in siblings:
                raise WindowsDeploymentError(
                    f"driver INF is missing catalog {filename}: {inf.relative_to(root)}"
                )
    boot_infs = []
    for requirement in requirements:
        filename = requirement.get("filename", "")
        role = requirement.get("role", "")
        companions = requirement.get("companion_suffixes", [])
        matches = [path for path in infs if path.name.casefold() == filename.casefold()]
        if len(matches) != 1:
            raise WindowsDeploymentError(
                f"driver pack must contain exactly one {filename}; found {len(matches)}"
            )
        sibling_suffixes = {
            path.suffix.casefold()
            for path in matches[0].parent.iterdir()
            if path.is_file()
        }
        for companion in companions:
            if companion.casefold() not in sibling_suffixes:
                raise WindowsDeploymentError(
                    f"{filename} is missing its {companion} payload in the same directory"
                )
        if role == "boot":
            boot_infs.append(matches[0].relative_to(root).as_posix())
        elif role != "hal-extension":
            raise WindowsDeploymentError(f"unsupported required INF role: {role}")
    if not boot_infs:
        raise WindowsDeploymentError("driver pack has no boot-critical INF")
    return boot_infs


def _driver_pack_source(manifest: dict) -> Path:
    environment = manifest.get("environment", "AURORA_WINDOWS_DRIVERS")
    configured = os.environ.get(environment)
    if not configured:
        p_question("Provide the Aurora AIC HAL extension and Windows driver pack")
        p_message("Enter the path to an assembled driver-pack directory.")
        p_message("It must contain AppleNvme.inf and HalExtAppleInterruptController.inf.")
        configured = input_prompt("Driver pack directory: ").strip()
    if not configured:
        raise WindowsDeploymentError("an Aurora AIC HAL extension and driver pack is required")
    source = Path(configured).expanduser().resolve()
    if not source.is_dir():
        raise WindowsDeploymentError(f"driver pack is not a directory: {source}")
    return source


def _partition_number(device: str) -> tuple[int, int]:
    match = re.fullmatch(r"disk(\d+)s(\d+)", device)
    if not match:
        raise WindowsDeploymentError(f"unexpected partition identifier: {device}")
    return int(match.group(1)), int(match.group(2))


def _zip_extract_prefix(package: zipfile.ZipFile, prefix: str, destination: Path) -> None:
    prefix = prefix.rstrip("/") + "/"
    found = False
    for info in package.infolist():
        if not info.filename.startswith(prefix) or info.is_dir():
            continue
        member = info.filename[len(prefix):]
        relative = Path(member)
        if (
            not relative.parts
            or relative.is_absolute()
            or ".." in relative.parts
            or "\\" in member
            or "\x00" in member
        ):
            raise WindowsDeploymentError(f"unsafe Windows package path: {info.filename}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with package.open(info) as source, target.open("wb") as output:
            shutil.copyfileobj(source, output)
        found = True
    if not found:
        raise WindowsDeploymentError(f"Windows package has no {prefix} payload")


def _zip_json(package: zipfile.ZipFile, name: str) -> dict:
    try:
        with package.open(name) as stream:
            return json.load(stream)
    except KeyError as exc:
        raise WindowsDeploymentError(f"Windows package is missing {name}") from exc


@dataclass
class WindowsStager:
    dutil: object
    package: zipfile.ZipFile
    deployment: dict

    def __post_init__(self):
        self.iso_pin = load_iso_pin(self.deployment.get("iso_manifest", "windows-iso.json"))
        self.iso_path: Path | None = None
        self.wimlib: str | None = None
        self.bcd_tool: str | None = None
        self.driver_cache = None
        self.driver_root: Path | None = None
        self.driver_boot_infs: list[str] = []
        self.driver_sha256: str | None = None
        self.driver_bytes = 0
        self.driver_files = 0

    def prepare(self) -> None:
        """Finish every fallible asset check before the partition map changes."""
        driver_manifest = _zip_json(self.package, "windows/driver-pack.json")
        if driver_manifest.get("schema") != 1 or driver_manifest.get("source") != "user-supplied":
            raise WindowsDeploymentError("unsupported Aurora driver-pack manifest")
        names = set(self.package.namelist())
        for required in (
            "windows/deploy/aurora-deploy.cmd",
            "windows/deploy/SetupComplete.cmd",
            "windows/deploy/startnet.cmd",
        ):
            if required not in names:
                raise WindowsDeploymentError(f"Windows package is missing {required}")
        self.wimlib = _resolve_tool(
            "wimlib-imagex",
            "WIMLIB_IMAGEX",
            (
                str(Path(__file__).resolve().parent / "bin" / "wimlib-imagex"),
                "/opt/homebrew/bin/wimlib-imagex",
                "/usr/local/bin/wimlib-imagex",
            ),
        )
        self.bcd_tool = _resolve_tool(
            "bcd-set-testsigning",
            "AURORA_BCD_TOOL",
            (
                str(Path(__file__).resolve().parent / "bin" / "bcd-set-testsigning"),
            ),
        )
        source = _driver_pack_source(driver_manifest)
        max_bytes = driver_manifest.get("max_bytes")
        if not isinstance(max_bytes, int) or max_bytes <= 0:
            raise WindowsDeploymentError("driver-pack manifest has an invalid size limit")
        source_rows, source_digest, source_bytes = _driver_inventory(source, max_bytes)
        _validate_driver_pack(source, driver_manifest)
        self.driver_cache = tempfile.TemporaryDirectory(prefix="aurora-windows-drivers.")
        self.driver_root = Path(self.driver_cache.name) / "Drivers"
        try:
            _copy_tree(source, self.driver_root)
            cached_rows, cached_digest, cached_bytes = _driver_inventory(
                self.driver_root, max_bytes
            )
            self.driver_boot_infs = _validate_driver_pack(
                self.driver_root, driver_manifest
            )
        except Exception:
            self.driver_cache.cleanup()
            self.driver_cache = None
            self.driver_root = None
            raise
        if (source_rows, source_digest, source_bytes) != (
            cached_rows,
            cached_digest,
            cached_bytes,
        ):
            self.driver_cache.cleanup()
            self.driver_cache = None
            self.driver_root = None
            raise WindowsDeploymentError("driver pack changed while it was being snapshotted")
        self.driver_sha256 = cached_digest
        self.driver_bytes = cached_bytes
        self.driver_files = len(cached_rows)
        p_info(
            f"  Driver/HAL pack: {self.driver_files} files, {ssize(self.driver_bytes)} "
            f"({self.driver_sha256[:16]}...)"
        )
        self.iso_path = obtain_iso(self.iso_pin)
        p_info(
            f"  Windows ISO pin: {self.iso_pin['release']} build "
            f"{self.iso_pin['build']} ({self.iso_pin['sha256'][:16]}...)"
        )

    def _role(self, partitions: list[dict], infos: list[object], role: str):
        matches = [info for part, info in zip(partitions, infos) if part.get("role") == role]
        if len(matches) != 1:
            raise WindowsDeploymentError(f"expected exactly one {role} partition")
        return matches[0]

    def _patch_boot_wim(self, boot_wim: Path, startnet: Path, drivers: Path) -> None:
        boot_wim.chmod(boot_wim.stat().st_mode | stat.S_IWUSR)
        commands = [
            f'add "{startnet}" "/Windows/System32/startnet.cmd"',
            f'add "{drivers / "boot-drivers.txt"}" "/Aurora/BootDrivers/boot-drivers.txt"',
        ]
        verify_paths = [
            "/Windows/System32/startnet.cmd",
            "/Aurora/BootDrivers/boot-drivers.txt",
        ]
        for relative in self.driver_boot_infs:
            source = drivers / Path(relative).parent
            destination = "/Aurora/BootDrivers/" + Path(relative).parent.as_posix()
            commands.append(f'add "{source}" "{destination}"')
            verify_paths.append("/Aurora/BootDrivers/" + relative)
        command = ("\n".join(commands) + "\n").encode("utf-8")
        for index in (1, 2):
            subprocess.run(
                [self.wimlib, "update", str(boot_wim), str(index)],
                input=command,
                check=True,
                stdout=subprocess.PIPE,
            )
            for path in verify_paths:
                subprocess.run(
                    [self.wimlib, "dir", str(boot_wim), str(index), f"--path={path}"],
                    check=True,
                    stdout=subprocess.PIPE,
                )

    def stage(self, partitions: list[dict], infos: list[object]) -> None:
        if (
            self.iso_path is None
            or self.wimlib is None
            or self.bcd_tool is None
            or self.driver_root is None
            or self.driver_sha256 is None
        ):
            raise WindowsDeploymentError("Windows staging was not prepared")

        esp = self._role(partitions, infos, "esp")
        media = self._role(partitions, infos, "windows-media")
        target = self._role(partitions, infos, "windows-target")
        disk_number, esp_number = _partition_number(esp.name)
        target_disk, _ = _partition_number(target.name)
        media_disk, _ = _partition_number(media.name)
        if len({disk_number, target_disk, media_disk}) != 1:
            raise WindowsDeploymentError("Aurora Windows partitions are not on one disk")

        whole_disk = f"disk{disk_number}"
        disk_info = self.dutil.disks.get(whole_disk) or {}
        disk_guid = disk_info.get("DiskUUID")
        if not disk_guid:
            disk_info = self.dutil.get("info", "-plist", whole_disk)
            disk_guid = disk_info.get("DiskUUID")
        if not disk_guid:
            raise WindowsDeploymentError("unable to read target GPT disk GUID")
        disk_guid = disk_guid.strip("{}").upper()
        if not re.fullmatch(
            r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
            disk_guid,
        ):
            raise WindowsDeploymentError("target GPT disk GUID is malformed")

        token = str(uuid.uuid4()).upper()
        p_progress("Staging the pinned Windows ISO onto Aurora-owned partitions...")
        media_mount = Path(self.dutil.mount(media.name))
        esp_mount = Path(self.dutil.mount(esp.name))
        target_mount = Path(self.dutil.mount(target.name))

        (media_mount / "AURORA-WINDOWS-MEDIA.TAG").write_text(token + "\r\n")
        (esp_mount / "AURORA-ESP.TAG").write_text(token + "\r\n")
        (target_mount / "AURORA-WINDOWS-TARGET.TAG").write_text(token + "\r\n")

        with mounted_iso(self.iso_path) as iso:
            _copy_tree(iso, media_mount)
            boot_dir = _child_casefold(iso, "boot")
            efi_dir = _child_casefold(iso, "efi")
            sources_dir = _child_casefold(iso, "sources")
            _copy_tree(boot_dir, esp_mount / "boot")
            _copy_tree(efi_dir, esp_mount / "efi")
            for root_name in ("bootmgr", "bootmgr.efi"):
                try:
                    source = _child_casefold(iso, root_name)
                except WindowsDeploymentError:
                    continue
                shutil.copy2(source, esp_mount / source.name)
            source_boot_wim = _child_casefold(sources_dir, "boot.wim")
            esp_sources = esp_mount / "sources"
            esp_sources.mkdir(exist_ok=True)
            shutil.copy2(source_boot_wim, esp_sources / "boot.wim")

        efi = _child_casefold(esp_mount, "efi")
        microsoft = _child_casefold(efi, "microsoft")
        boot = _child_casefold(microsoft, "boot")
        setup_bcd = _child_casefold(boot, "bcd")
        subprocess.run(
            [self.bcd_tool, str(setup_bcd)],
            check=True,
            stdout=subprocess.PIPE,
        )

        aurora = media_mount / "Aurora"
        drivers = aurora / "Drivers"
        aurora.mkdir(exist_ok=True)
        _copy_tree(self.driver_root, drivers)
        _zip_extract_prefix(self.package, "windows/deploy", aurora)

        boot_list = "".join(
            path.replace("/", "\\") + "\r\n" for path in self.driver_boot_infs
        )
        (drivers / "boot-drivers.txt").write_text(boot_list, newline="")
        (aurora / "driver-pack.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "source": "user-supplied",
                    "files": self.driver_files,
                    "bytes": self.driver_bytes,
                    "sha256": self.driver_sha256,
                    "boot_infs": self.driver_boot_infs,
                },
                indent=4,
            )
            + "\n",
            encoding="utf-8",
        )

        deploy = {
            "schema": "1",
            "token": token,
            "disk_number": str(disk_number),
            "disk_guid": disk_guid,
            "esp_partition_number": str(esp_number),
            "esp_partition_guid": esp.uuid.upper(),
            "target_partition_guid": target.uuid.upper(),
            "windows_build": self.iso_pin["build"],
            "image_name": self.deployment.get("image_name", self.iso_pin["image_name"]),
            "iso_sha256": self.iso_pin["sha256"],
            "driver_pack_sha256": self.driver_sha256,
        }
        cfg = "".join(f"{key}={value}\r\n" for key, value in deploy.items())
        (aurora / "deploy.cfg").write_text(cfg, newline="")
        manifest = {
            **deploy,
            "schema": 1,
            "iso": {
                key: self.iso_pin[key]
                for key in ("release", "build", "filename", "size", "sha256")
            },
            "test_signing": True,
            "winpe_test_signing": True,
            "write_boundary": "installer-created partitions only",
        }
        aurora_dir = esp_mount / "aurora"
        aurora_dir.mkdir(exist_ok=True)
        (aurora_dir / "windows-deployment.json").write_text(
            json.dumps(manifest, indent=4) + "\n", encoding="utf-8"
        )

        self._patch_boot_wim(
            esp_mount / "sources" / "boot.wim", aurora / "startnet.cmd", drivers
        )
        os.sync()
        self.driver_cache.cleanup()
        self.driver_cache = None
        self.driver_root = None
        p_plain("  Windows Setup media, Aurora drivers, and test-signing deployment policy staged.")
