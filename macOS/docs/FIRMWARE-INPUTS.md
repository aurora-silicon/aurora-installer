# Installer firmware inputs

Firmware preparation belongs to the installer and runs before partition changes. Fedora, ALARM and NixOS consume the same prepared vendor-firmware contract; individual distributions must not substitute calibration from another machine or silently omit required inputs.

| Input | Source | Admission and lifetime |
| --- | --- | --- |
| Neo camera setfiles | Recipe-pinned partial IPSW downloads | Verify source ranges and output digests; convert natively. Model-wide authenticated raw files may be reused for a retry. |
| Neo Wi-Fi and Bluetooth firmware | Same IPSW recipe | Verify raw digests and convert natively. Required outputs include Bluetooth PTX, calibration and this machine’s address. |
| Neo radio factory calibration | Hardware volume factory-data cache, `BWC2-*` | One protected local record; device-local converted outputs live only in the private install snapshot and installed firmware package. |
| Neo ALS calibration | This machine’s `exbright` LSCI registry property | Require one bounded record; convert natively and retain its digest in the private snapshot. |
| Neo regulatory policies | Six pinned text tables from the running macOS system volume, or authenticated 25G83 IPSW ranges as a complete fallback set | Require every version line and SHA-256. Derive and validate all 244 v1 packages and all 120 eligible v2 VLP packages; pin both inventories. Keep world-XZ v1. |
| Built-in Touch ID calibration | Matching `FSC2-*`/`FSCl-*` factory record, or the verified internal system container | Keep an FSCl `comb` record whole. Rebuild a standalone FSC2 `IMG4` in the combined layout the enclave loads, with this machine's `seal-*` and trust bundle (`docs/sensor-root-key.md`). Reject missing, ambiguous, malformed or mismatched records when the sensor is present. |
| Built-in Touch ID signed root key | This machine’s Hardware factory-data cache: `MSRk-*`, `seal-*`, `trustobject-current` and its named bundle | Rebuild the combined container from the record's `IM4P`, the FDR sealing manifest and the trust bundle (`docs/sensor-root-key.md`). Pair direct factory calibration and root-key records by identifier. Validate type and structure locally; the enclave verifies the chain. Never distribute a captured device’s container. |

The factory volume must belong to the selected internal disk’s first `Apple_APFS_ISC` partition. Check disk identity before and after collection. Sensor detection examines the built-in controller; an external keyboard is not evidence of an internal sensor. Failed detection is an error, rather than proof that hardware is absent.

Converted snapshots use fresh private directories and bind each output’s size and SHA-256 to the plan, payload, metadata and recipe. The backend adopts those exact bytes without recollecting device-local data. Cleanup runs after success, failure and cancellation. It checks the owned directory’s identity before removal, reports cleanup errors and preserves a replacement directory. Authenticated interrupted download ranges and required install journals are retained for retry; private converted snapshots are not a shared cache.

On a sensor-equipped Neo, the rebuilt root key matches macOS's working container byte for byte, and the resealed calibration loads where the plain FSC2 image is refused. A fresh native install that writes both still needs confirmation before this path is called hardware-qualified. Structural tests do not establish certificate-chain acceptance.

The remaining generic firmware collection and final Recovery staging still have compatibility backend paths. This document does not claim that the entire installer is already independent of those paths.

Policy packages retain firmware-relative paths `mediatek/mt7932/policy/` (v1) and `mediatek/mt7932/policy-v2/` (v2). The native peripheral snapshot and vendor archive writer preserve both paths: TAR installs them under the ordinary vendor firmware tree, and CPIO prefixes them with `vendorfw/`. Aurora’s existing initrd service exposes `/vendorfw` through `/lib/firmware/vendor`. Older kernels therefore continue finding only v1 at `policy/CC.bin`; newer kernels may prefer `policy-v2/CC.bin`. The boot gate requires `policy/world-XZ.bin`, without requiring any particular country package.

Only the exact pinned live revision is accepted. Missing files, version changes or digest mismatches discard the complete live set and retain the authenticated IPSW path. A matching live set removes only those files’ unneeded range dependencies before extraction; other firmware still uses its existing authenticated source. The private raw cache and per-attempt ownership, identity, cancellation and publication gates remain in force.
