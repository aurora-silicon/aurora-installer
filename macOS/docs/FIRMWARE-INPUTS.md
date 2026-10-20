# Installer firmware inputs

Firmware preparation belongs to the installer and runs before partition changes. Fedora, ALARM and NixOS consume the same prepared vendor-firmware contract; individual distributions must not substitute calibration from another machine or silently omit required inputs.

| Input | Source | Admission and lifetime |
| --- | --- | --- |
| Neo camera setfiles | Recipe-pinned partial IPSW downloads | Verify source ranges and output digests; convert natively. Model-wide authenticated raw files may be reused for a retry. |
| Neo Wi-Fi and Bluetooth firmware | Same IPSW recipe | Verify raw digests and convert natively. Required outputs include Bluetooth PTX, calibration and this machine’s address. |
| Neo radio factory calibration | Hardware volume factory-data cache, `BWC2-*` | One protected local record; device-local converted outputs live only in the private install snapshot and installed firmware package. |
| Neo ALS calibration | This machine’s `exbright` LSCI registry property | Require one bounded record; convert natively and retain its digest in the private snapshot. |
| Neo regulatory policies | Authenticated payload members under `installer-inputs/mt7932-policy/` | Require the declared world policy and validate every declared country policy. Never infer successful Wi-Fi firmware preparation from the radio firmware alone. Native generation from the IPSW datasets is separate work and is not yet promoted. |
| Built-in Touch ID calibration | Matching `FSC2-*`/`FSCl-*` factory record, or the verified internal system container | Preserve the complete supported signed envelope. Reject missing, ambiguous, malformed or mismatched records when the sensor is present. |
| Built-in Touch ID signed root key | This machine’s Hardware factory-data cache, `MSRk-*` | Preserve the complete IMG4/IM4P and manifest, including its certificate chain. Pair direct factory calibration and root-key records by identifier. Validate type and structure locally; the enclave verifies the chain. Never distribute a captured device’s container. |

The factory volume must belong to the selected internal disk’s first `Apple_APFS_ISC` partition. Check disk identity before and after collection. Sensor detection examines the built-in controller; an external keyboard is not evidence of an internal sensor. Failed detection is an error, rather than proof that hardware is absent.

Converted snapshots use fresh private directories and bind each output’s size and SHA-256 to the plan, payload, metadata and recipe. The backend adopts those exact bytes without recollecting device-local data. Cleanup runs after success, failure and cancellation. It checks the owned directory’s identity before removal, reports cleanup errors and preserves a replacement directory. Authenticated interrupted download ranges and required install journals are retained for retry; private converted snapshots are not a shared cache.

The root-key source and envelope shape have retained evidence from a sensor-equipped M5. The currently available Neo reports no built-in sensor and has no sensor factory records. A sensor-equipped Neo still needs comparison with its known working container and enclave acceptance before this path is called hardware-qualified. Structural tests do not establish certificate-chain acceptance.

The remaining generic firmware collection and final Recovery staging still have compatibility backend paths. This document does not claim that the entire installer is already independent of those paths.
