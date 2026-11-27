# Firmware inventory check

Run `python3 tools/check-firmware-inventory.py INVENTORY ESP` from the repository root using Python 3.11 or newer with a read-only view of the installed ESP. The check exits unsuccessfully if an expected regular file is missing, empty, repeated or differs from the expected SHA-256. It reports counts without printing machine-specific record names or digests.

Prepare the inventory independently for the installation under test. Supply a JSON object with two maps, `local` and `vendor`. Each map uses archive-relative filenames as keys and lowercase SHA-256 digests as values.

- For `local`, use the machine's own Hardware FactoryData records under `com.apple.factorydata/` in `asahi/all_firmware.tar.gz`. Include camera `iCCl` records and local sealing or trust records where present. Keep the inventory and archive private.
- For `vendor`, use the expected output of the firmware conversion from the admitted matching IPSW, plus the expected output of any local calibration conversion. List the exact outputs required by the hardware under test in `vendorfw/firmware.tar`. Derive expectations from independent source inputs, never from the archives being checked.

Treat an unreadable or unverified source as an incomplete test row. A camera-equipped Mac can have no `iCCl` in its Hardware cache. Check the cache independently before recording that result. Hash matching verifies collection and conversion. Kernel calibration application and inputs handed through the device tree require separate runtime rows.
