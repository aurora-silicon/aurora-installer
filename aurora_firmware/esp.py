# SPDX-License-Identifier: MIT
"""Names the boot chain uses on the ESP and in /chosen.

Current names come first. The second entry of each pair is the name that
installers and boot loaders used before the aurora rename; it is read only so
that existing installations keep working.
LEGACY-ASAHI(2027-02-28): drop the legacy names after that date.
"""
import pathlib

STATE_DIR = "aurora"
LEGACY_STATE_DIR = "asahi"          # LEGACY-ASAHI(2027-02-28)
STATE_DIRS = (STATE_DIR, LEGACY_STATE_DIR)

STAGE2_DIR = "aurora"
LEGACY_STAGE2_DIR = "m1n1"          # LEGACY-ASAHI(2027-02-28)
STAGE2_DIRS = (STAGE2_DIR, LEGACY_STAGE2_DIR)

CHOSEN = "/proc/device-tree/chosen"
CHOSEN_PREFIX = "aurora,"
LEGACY_CHOSEN_PREFIX = "asahi,"     # LEGACY-ASAHI(2027-02-28)


STATE_FILES = ("all_firmware.tar.gz", "stub_info.json")


def state_dir(esp):
    """The ESP's installer state directory: the first of aurora/ and the legacy
    one that holds all_firmware.tar.gz or stub_info.json, else None. aurora/
    also holds Stage 2, so the directory alone proves nothing."""
    esp = pathlib.Path(esp)
    for name in STATE_DIRS:
        if any((esp / name / f).is_file() for f in STATE_FILES):
            return esp / name
    return None


def chosen_names(name):
    """The /chosen property names for `name` (e.g. "speaker-id"), current first."""
    return tuple(prefix + name for prefix in (CHOSEN_PREFIX, LEGACY_CHOSEN_PREFIX))


def chosen_paths(name, chosen=CHOSEN):
    """The /chosen property paths for `name`, current first."""
    return tuple(pathlib.Path(chosen) / n for n in chosen_names(name))


def read_chosen(name, chosen=CHOSEN):
    """The raw bytes of /chosen/aurora,<name>, else of the legacy name, else None."""
    for path in chosen_paths(name, chosen):
        try:
            return path.read_bytes()
        except OSError:
            continue
    return None
