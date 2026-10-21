# SPDX-License-Identifier: MIT
"""Read a private helper-converted Neo snapshot; never collect or convert it."""
import hashlib
import json
import os
import re
import stat

import omarchy_mt7932


class NativePeripheralError(ValueError):
    pass


CAMERA = {"apple/isp_" + name + ".dat" for name in (
    "1820_01XX", "1822_02XX", "8720_01XX", "8723_01XX", "1921_01XX", "1922_02XX", "1925_03XX")}
REQUIRED_CAMERA = {"apple/isp_" + name + ".dat" for name in ("1921_01XX", "1922_02XX", "1925_03XX")}
RADIO = {"mediatek/mt7932/" + name for name in (
    omarchy_mt7932.WIFI_PATCH, omarchy_mt7932.WIFI_RAM, "ppr.bin", "oca2.bin", "wcal.bin", "config-original.bin")}
RADIO |= {"mediatek/" + name for name in (*omarchy_mt7932.BT_FIRMWARE, omarchy_mt7932.BT_PTX)}
RADIO |= {"mediatek/j700-mt7932-btcal.bin", "mediatek/j700-mt7932-bdaddr.bin"}
ALS = "apple/j700-aop-als-cal.bin"
LSCI = "fallback/lsci.bin"
SENSOR = "apple/mesacal-j700.bin"
SENSOR_ROOT_KEY = "apple/msrk-j700.bin"
HASH = re.compile(r"[0-9a-f]{64}\Z")


def _require(value, message):
    if not value:
        raise NativePeripheralError(message)


def _safe(name):
    return (isinstance(name, str) and 0 < len(name.encode()) <= 4096
            and "\\" not in name and "\0" not in name
            and all(part not in ("", ".", "..") for part in name.split("/")))


def load(path, *, device, binding, plan, metadata, payload, recipe):
    _require(device == "apple,j700" and isinstance(path, str) and os.path.isabs(path), "invalid native peripheral location")
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    root = os.open(path, flags | os.O_DIRECTORY)
    try:
        root_info = os.fstat(root)
        _require(root_info.st_uid == os.geteuid() and not root_info.st_mode & 0o077, "unsafe native peripheral root")

        def checked(fd, directory=False):
            info = os.fstat(fd)
            _require(info.st_uid == os.geteuid() and not info.st_mode & 0o022
                     and (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
                          and info.st_nlink == 1), "unsafe native peripheral entry")
            return info

        def read(name, maximum):
            _require(_safe(name), "unsafe native peripheral name")
            parent = os.dup(root)
            try:
                parts = name.split("/")
                for component in parts[:-1]:
                    child = os.open(component, flags | os.O_DIRECTORY, dir_fd=parent)
                    try:
                        checked(child, True)
                    except BaseException:
                        os.close(child)
                        raise
                    os.close(parent)
                    parent = child
                fd = os.open(parts[-1], flags | os.O_NONBLOCK, dir_fd=parent)
                try:
                    before = checked(fd)
                    _require(0 < before.st_size <= maximum, "native peripheral size exceeds its budget")
                    chunks = []
                    remaining = before.st_size
                    while remaining:
                        chunk = os.read(fd, min(remaining, 65536))
                        _require(chunk, "truncated native peripheral input")
                        chunks.append(chunk)
                        remaining -= len(chunk)
                    after = checked(fd)
                    _require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                             == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                             "native peripheral input changed")
                    return b"".join(chunks)
                finally:
                    os.close(fd)
            finally:
                os.close(parent)

        def unique(pairs):
            values = {}
            for key, value in pairs:
                _require(key not in values, "duplicate native peripheral manifest key")
                values[key] = value
            return values

        manifest = json.loads(read("manifest.json", 1 << 20), object_pairs_hook=unique)
        keys = {"schema", "converter", "device_identifier", "binding_digest", "plan_digest", "metadata_digest",
                "payload_digest", "recipe_sha256", "local_inputs", "files"}
        _require(isinstance(manifest, dict) and set(manifest) == keys and type(manifest["schema"]) is int
                 and manifest["schema"] == 1 and manifest["converter"] == "neo-v1", "invalid native peripheral contract")
        for key, expected in (("device_identifier", device), ("binding_digest", binding), ("plan_digest", plan),
                              ("metadata_digest", metadata), ("payload_digest", payload), ("recipe_sha256", recipe)):
            _require(manifest[key] == expected, "native peripheral identity mismatch")
        _require(isinstance(recipe, str) and HASH.fullmatch(recipe), "invalid native peripheral recipe")
        _require(isinstance(plan, str) and HASH.fullmatch(plan), "invalid native peripheral plan")
        _require(all(isinstance(value, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value)
                     for value in (binding, metadata, payload)), "invalid native peripheral binding")
        local = manifest["local_inputs"]
        _require(isinstance(local, dict) and set(local) in ({"factory", "lsci", "address"}, {"factory", "lsci", "address", "sensorCalibration", "sensorRootKey"})
                 and all(isinstance(value, str) and HASH.fullmatch(value) for value in local.values()),
                 "invalid native local-input identity")
        files = manifest["files"]
        _require(isinstance(files, dict) and 17 <= len(files) <= 512, "invalid native peripheral inventory")
        result = {role: {} for role in ("camera", "radio", "als", "lsci", "policy", "sensor")}
        expected_files = {"manifest.json"}
        expected_dirs = set()
        total = 0
        for name, record in files.items():
            _require(_safe(name) and isinstance(record, dict) and set(record) == {"role", "bytes", "sha256"},
                     "invalid native peripheral record")
            role = record["role"]
            _require(isinstance(role, str) and role in result and type(record["bytes"]) is int and 0 < record["bytes"] <= 16 << 20
                     and isinstance(record["sha256"], str) and HASH.fullmatch(record["sha256"]), "invalid native peripheral size or digest")
            allowed = (role == "camera" and name in CAMERA or role == "radio" and name in RADIO
                       or role == "als" and name == ALS or role == "lsci" and name == LSCI
                       or role == "sensor" and name in (SENSOR, SENSOR_ROOT_KEY)
                       or role == "policy" and re.fullmatch(r"mediatek/mt7932/(?:policy/(?:world-XZ|[A-Z]{2})|policy-v2/[A-Z]{2})\.bin", name))
            _require(allowed, "unknown native peripheral output")
            if role == "als": _require(record["bytes"] == 80, "invalid native ALS size")
            if role == "lsci": _require(record["bytes"] == 156, "invalid native LSCI size")
            if role == "policy":
                version = 2 if "/policy-v2/" in name else 1
                _require(16 <= record["bytes"] <= (65536 if version == 2 else 16384),
                         "invalid native policy size")
            total += record["bytes"]
            _require(total <= 64 << 20, "native peripheral snapshot exceeds its budget")
            relative = "files/" + name
            data = read(relative, record["bytes"])
            _require(len(data) == record["bytes"] and hashlib.sha256(data).hexdigest() == record["sha256"],
                     "native peripheral digest mismatch")
            if role == "policy":
                country = "XZ" if name.endswith("/world-XZ.bin") else name.rsplit("/", 1)[1][:-4]
                _require(data[:4] == b"J7RP" and int.from_bytes(data[4:6], "little") == version
                         and data[6:8] == country.encode("ascii"), "native policy directory/version mismatch")
            result[role][name] = data
            expected_files.add(relative)
            pieces = relative.split("/")
            expected_dirs.update("/".join(pieces[:index]) for index in range(1, len(pieces)))
        _require(REQUIRED_CAMERA <= result["camera"].keys() and set(result["radio"]) == RADIO
                 and set(result["als"]) == {ALS} and set(result["lsci"]) == {LSCI}
                 and "mediatek/mt7932/policy/world-XZ.bin" in result["policy"], "incomplete native peripheral snapshot")
        _require(hashlib.sha256(result["lsci"][LSCI]).hexdigest() == local["lsci"]
                 and hashlib.sha256(result["radio"]["mediatek/j700-mt7932-bdaddr.bin"]).hexdigest() == local["address"],
                 "native local-input snapshot changed")
        if "sensorCalibration" in local:
            _require(set(result["sensor"]) == {SENSOR, SENSOR_ROOT_KEY}
                     and hashlib.sha256(result["sensor"][SENSOR]).hexdigest() == local["sensorCalibration"]
                     and hashlib.sha256(result["sensor"][SENSOR_ROOT_KEY]).hexdigest() == local["sensorRootKey"],
                     "native sensor calibration is missing or changed")
        else:
            _require(not result["sensor"], "unexpected native sensor calibration")
        observed_files, observed_dirs = set(), set()
        pending = [(os.dup(root), "", 0)]
        try:
            while pending:
                directory, prefix, depth = pending.pop()
                try:
                    _require(depth <= 8, "native peripheral nesting exceeds its budget")
                    for name in os.listdir(directory):
                        _require(_safe(name) and "/" not in name, "unsafe native peripheral entry")
                        relative = prefix + name
                        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
                        if stat.S_ISDIR(info.st_mode):
                            child = os.open(name, flags | os.O_DIRECTORY, dir_fd=directory)
                            try: checked(child, True)
                            except BaseException:
                                os.close(child)
                                raise
                            observed_dirs.add(relative)
                            pending.append((child, relative + "/", depth + 1))
                        else:
                            _require(stat.S_ISREG(info.st_mode), "unsafe native peripheral file type")
                            observed_files.add(relative)
                        _require(len(observed_files) + len(observed_dirs) <= 1024, "too many native peripheral entries")
                finally:
                    os.close(directory)
        finally:
            for directory, _, _ in pending: os.close(directory)
        _require(observed_files == expected_files and observed_dirs == expected_dirs, "native peripheral inventory changed")
        return result
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NativePeripheralError("native peripheral snapshot is unavailable") from error
    finally:
        os.close(root)
