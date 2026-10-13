# SPDX-License-Identifier: MIT
"""Asahi-native inventory and candidate-bound planning."""

import hashlib
import json
import os
import stat

import osinstall
from util import align_down


TARGET = "apple-silicon-full-os"
MAX_INPUT_BYTES = 65_536
REPLACE_ESP_LABEL = "EFI - OMARC"
LINUX_PARTITION_TYPE = "Linux Filesystem"
APPLE_RESERVED_TYPES = ("Apple_APFS_Recovery", "Apple_APFS_ISC")
PLAN_REQUEST_KEYS = {
    "schema_version",
    "layout_digest",
    "candidate_kind",
    "source_identifier",
    "requested_length_bytes",
}
ENGINE_IDENTITY_KEYS = {
    "schema_version",
    "engine_version",
    "engine_digest",
    "metadata_digest",
    "payload_digest",
}
REPAIR_ENGINE_IDENTITY_KEYS = ENGINE_IDENTITY_KEYS | {
    "repair_manifest_digest"
}
REQUIRED_HUMAN_STEPS = [
    "enterOneTrueRecovery",
    "authenticateMachineOwner",
]
REPAIR_REQUIRED_HUMAN_STEPS = ["authenticateMachineOwner"]


class PlanningError(ValueError):
    pass


def _install_bounds(stub_size, os_installer):
    """Partition floor, then the larger size Asahi recommends for upgrades.

    An expandable root reports min_recommended_size as twice min_size. The
    floor is what the images actually fit in. Disks that cannot give up the
    doubled size can still install at the floor.
    """
    recommended = stub_size + os_installer.min_recommended_size
    floor = stub_size + getattr(
        os_installer, "min_size", os_installer.min_recommended_size
    )
    if (
        isinstance(floor, bool)
        or not isinstance(floor, int)
        or floor <= 0
        or floor > recommended
    ):
        floor = recommended
    return floor, recommended


def _minimum_that_fits(length, floor, recommended):
    if length >= recommended:
        return recommended
    return floor


MACOS_REQUIRED_FREE_BYTES = 38_000_000_000


def _resize_offer(installer, part, bounds, floor, part_align):
    """Keep an explicit macOS reserve as well as diskutil's APFS limit."""
    disk = installer.dutil.get_disk_size(installer.sys_disk)
    total = bounds.get("total_bytes")
    free = bounds.get("free_bytes")
    preferred = bounds.get("diskutil_minimum_bytes")
    values = (disk, total, free, preferred, part.size, part_align)
    if any(type(value) is not int or not 0 <= value < 2**64 for value in values):
        raise PlanningError("invalid macOS resize metrics")
    if not (
        0 < total == part.size <= disk
        and free <= total
        and 0 < preferred <= total
        and part_align > 0
    ):
        raise PlanningError("inconsistent macOS resize metrics")
    used = total - free
    value = used + MACOS_REQUIRED_FREE_BYTES
    aligned = (value + part_align - 1) // part_align * part_align
    if aligned >= 2**64:
        raise PlanningError("macOS resize floor overflow")
    minimum = max(preferred, aligned)

    # Report even an exhausted container: planning/admission will refuse it,
    # while Swift can account for the full reserve deficit in its shortfall.
    return floor, minimum, minimum


def collect_inventory(
    installer,
    free_parts,
    resizable_parts,
    stub_size,
    part_align,
):
    templates = [
        template
        for template in installer.data["os_list"]
        if template.get("omarchy_target") == TARGET
    ]
    if len(templates) != 1:
        raise PlanningError(
            "metadata must contain exactly one Omarchy Apple full-OS target"
        )

    os_installer = osinstall.OSInstaller(
        installer.dutil,
        installer.data,
        templates[0],
    )
    floor, recommended = _install_bounds(stub_size, os_installer)
    candidates = []
    for part in free_parts:
        length = align_down(part.size, part_align)
        if length >= floor:
            candidates.append(
                {
                    "kind": "free",
                    "source_identifier": part.name,
                    "offset_bytes": part.offset,
                    "length_bytes": length,
                    "minimum_install_bytes": _minimum_that_fits(
                        length, floor, recommended
                    ),
                    "minimum_container_bytes": 0,
                    "recommended_install_bytes": recommended,
                    "recommended_container_bytes": 0,
                }
            )
    for part in resizable_parts:
        bounds = installer.get_resize_bounds(part)
        # A container that cannot give up enough space is still reported, so
        # the installer can say how much is missing before it downloads
        # anything. Planning and execution reject it by the same minimums.
        minimum_install, minimum_container, recommended_container = _resize_offer(
            installer, part, bounds, floor, part_align
        )
        candidates.append(
            {
                "kind": "resize",
                "source_identifier": part.name,
                "offset_bytes": part.offset,
                "length_bytes": part.size,
                "minimum_install_bytes": minimum_install,
                "minimum_container_bytes": minimum_container,
                "recommended_install_bytes": recommended,
                "recommended_container_bytes": recommended_container,
            }
        )
    candidates.extend(
        collect_existing_installs(
            installer,
            templates[0].get("default_os_name"),
            floor,
            part_align,
            recommended,
        )
    )
    candidates.sort(
        key=lambda candidate: (
            candidate["offset_bytes"],
            candidate["kind"],
        )
    )
    return {
        "system_store_identifier": installer.sys_disk,
        "candidates": candidates,
    }


def collect_existing_installs(
    installer, os_label, minimum_install, part_align, recommended_install=None
):
    """Detect complete existing Omarchy installs as replace candidates.

    A complete install is exactly four consecutive partitions: the Omarchy
    APFS stub (holding a stub macOS whose volume label is the Omarchy OS
    name), the Omarchy ESP, and the boot and root Linux partitions. Free
    rows immediately before the stub or after the root are absorbed into
    the candidate extent so that removal leaves one free extent starting at
    the approved offset. Anything partial, reordered, or ambiguous is not
    offered for replacement.
    """
    if not isinstance(os_label, str) or not os_label:
        return []
    if recommended_install is None:
        recommended_install = minimum_install
    parts = list(getattr(installer, "parts", None) or [])
    candidates = []
    for index, part in enumerate(parts):
        if part.free or not (part.type or "").startswith("Apple_APFS"):
            continue
        if part.type in APPLE_RESERVED_TYPES:
            continue
        stubs = [
            os_info
            for os_info in (part.os or [])
            if getattr(os_info, "stub", False)
            and getattr(os_info, "label", None) == os_label
        ]
        if len(stubs) != 1:
            continue
        members = parts[index : index + 4]
        if len(members) != 4 or any(member.free for member in members):
            continue
        esp, boot, root = members[1:]
        # diskutil only fills Partition.label for APFS volumes; the ESP is a
        # FAT partition whose name arrives in the raw record as VolumeName.
        esp_label = esp.label or (getattr(esp, "info", None) or {}).get("VolumeName") or ""
        if (
            esp_label != REPLACE_ESP_LABEL
            or boot.type != LINUX_PARTITION_TYPE
            or root.type != LINUX_PARTITION_TYPE
            or any(not member.uuid for member in members)
        ):
            continue
        start = part.offset
        if index > 0 and parts[index - 1].free:
            start = parts[index - 1].offset
        end = root.offset + root.size
        if index + 4 < len(parts) and parts[index + 4].free:
            following = parts[index + 4]
            end = following.offset + following.size
        length = align_down(end - start, part_align)
        if length < minimum_install:
            continue
        replace_minimum = _minimum_that_fits(
            length, minimum_install, recommended_install
        )
        candidates.append(
            {
                "kind": "replace",
                "source_identifier": part.name,
                "offset_bytes": start,
                "length_bytes": length,
                "minimum_install_bytes": replace_minimum,
                "minimum_container_bytes": 0,
                "recommended_install_bytes": recommended_install,
                "recommended_container_bytes": 0,
                "identity_digest": replace_identity_digest(
                    members,
                    os_label,
                    getattr(stubs[0], "vgid", None),
                ),
            }
        )
    return candidates


def replace_identity_digest(members, os_label, vgid):
    """Digest binding the exact partitions an approved replace may remove."""
    fields = ["omarchy.apple.replace-identity", "1", os_label, vgid or ""]
    for part in members:
        fields.extend(
            (
                part.name,
                part.type or "",
                part.uuid or "",
                str(part.offset),
                str(part.size),
            )
        )
    canonical = "|".join(
        f"{len(field.encode('utf-8'))}:{field}" for field in fields
    )
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def emit_inventory(
    installer,
    journal,
    free_parts,
    resizable_parts,
    stub_size,
    part_align,
):
    inventory = collect_inventory(
        installer,
        free_parts,
        resizable_parts,
        stub_size,
        part_align,
    )
    journal.inventory(
        inventory["system_store_identifier"],
        inventory["candidates"],
    )
    return journal.inventory_payload


def emit_plan(
    journal,
    request_path,
    identity_path,
    device_identifier,
    part_align,
):
    request = _load_exact_json(
        request_path,
        PLAN_REQUEST_KEYS,
        "planning request",
    )
    identity_keys = (
        REPAIR_ENGINE_IDENTITY_KEYS
        if request["candidate_kind"] == "repair"
        else ENGINE_IDENTITY_KEYS
    )
    identity = _load_exact_json(
        identity_path,
        identity_keys,
        "planning identity",
    )
    requested = request["requested_length_bytes"]
    if (
        not isinstance(requested, int)
        or isinstance(requested, bool)
        or requested <= 0
        or requested % part_align != 0
    ):
        raise PlanningError(
            "requested length must be a positive aligned integer"
        )
    required_human_steps = (
        REPAIR_REQUIRED_HUMAN_STEPS
        if request["candidate_kind"] == "repair"
        else REQUIRED_HUMAN_STEPS
    )
    return journal.plan(
        device_identifier=device_identifier,
        layout_digest=request["layout_digest"],
        candidate_kind=request["candidate_kind"],
        source_identifier=request["source_identifier"],
        requested_length_bytes=requested,
        engine_version=identity["engine_version"],
        engine_digest=identity["engine_digest"],
        metadata_digest=identity["metadata_digest"],
        payload_digest=identity["payload_digest"],
        repair_manifest_digest=identity.get("repair_manifest_digest"),
        required_human_steps=required_human_steps,
    )


def _load_exact_json(path, keys, role):
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise PlanningError(f"unsafe {role}") from error
    try:
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_mode & 0o022
            or details.st_size <= 0
            or details.st_size > MAX_INPUT_BYTES
        ):
            raise PlanningError(f"unsafe {role}")
        data = os.read(descriptor, MAX_INPUT_BYTES + 1)
        if len(data) != details.st_size:
            raise PlanningError(f"unsafe {role}")
    finally:
        os.close(descriptor)
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PlanningError(f"invalid {role}") from error
    if (
        not isinstance(value, dict)
        or set(value) != keys
        or value["schema_version"] != 1
    ):
        raise PlanningError(f"unexpected {role} fields")
    return value
