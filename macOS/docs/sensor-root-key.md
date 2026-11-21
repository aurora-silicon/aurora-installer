# Touch ID calibration and root key

Touch ID on Linux needs two pieces of this Mac's own factory data: the sensor's calibration and, on Macs whose enclave opens the sensor session with a signed root key, that root key. Both are per-device records written at manufacture. The installer copies them from this Mac at installation time; nothing is synthesized, nothing crosses machines, and no copy is ever published or shipped.

## The files the kernel loads

The sensor node's `firmware-name` names the files, keyed by the board the Mac reports (`j313`, `j414s`, `j700`, `j714s`, ...):

- `apple/mesacal-<board>.bin`: the calibration, on every Mac with the sensor.
- `apple/msrk-<board>.bin`: the root key, requested only where the enclave needs it (the Neo, M4 and M5 Macs). M1, M2 and M3 Macs need the calibration alone.
- `apple/mesa_calibration.bin`: the driver's default, which it loads when the node names no calibration. The M2 Pro and Max laptops' device trees name none, and neither does the node the driver creates when a device tree has no sensor node.

`NativeTouchIDFirmware` writes the calibration under both calibration names and the root key, when the Mac has one, under its board's name. It takes the board from the installation's own device identifier, so no list of models is involved. The Neo's peripheral snapshot and every other Mac's vendor firmware use the same code.

## Where the records come from

The factory cache (`/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata`) stores the pieces, not the layout the enclave loads:

- `MSRk-<sensor>`: an `IMG4` whose `IM4P` carries the root key, present only on Macs that use one. Its own factory manifest chains to a root the enclave does not trust, so the bare record is refused.
- `FSC2-<sensor>` or `FSCl-<sensor>`: the calibration, where the cache has it. Otherwise the calibration is carved from the iBoot System Container.
- `seal-<ECID>`: the FDR sealing manifest (`IM4M`).
- `trustobject-<sha256>`: the trust bundle. `trustobject-current` holds the bytes in use; a macOS update can leave older named bundles behind.

The enclave loads the records only in the combined layout macOS hands it:

`comb { fdrd: IMG4 { IM4P, [0] seal-<ECID> }, secb: trust bundle }`

`NativeSensorInputCollector` produces that layout:

- An FSCl calibration is already a `comb` record and is kept as it is. It needs no sealing records. This is the form an M2 Pro (J414s) enclave accepts.
- A standalone FSC2 `IMG4` is refused as it is (`LOAD_CALIBRATION` fails). Its `IM4P` is resealed under `seal-<ECID>` with the trust bundle as `secb`, as on the Neo.
- The root key is rebuilt from the `MSRk` record's `IM4P` the same way.

With a root key, the calibration record must carry the same sensor identifier. Without one, exactly one calibration record must be present. When any record needs resealing, exactly one `seal-*` record is required. The trust bundle is then the named `trustobject-<sha256>` whose digest and bytes match `trustobject-current`; without `trustobject-current`, exactly one named bundle must be present and match its name. `SignedSensorInputs.rootKey`, `SignedSensorInputs.sealedCalibration` and `SignedSensorInputs.preparedCalibration` admit the results structurally; they do not verify the certificate chain or the sensor binding.

On a Touch ID-equipped Neo (macOS 26.6.2, 25G83), the rebuilt root key is byte-identical to the 12,688-byte container macOS uses, and it enrols on Linux. The resealed calibration loads where the plain image is refused, and an enrolled finger matches after a reboot without re-enrolling. Those results come from records placed by hand. A fresh native install that writes them is still to be confirmed on each family.

## When the records are missing or invalid

Touch ID is optional. Macs without the sensor (`/arm-io/spi2` absent) skip this collection. On a Mac with the sensor, the records are read before the first disk change. If they are missing, ambiguous or do not validate, the installation continues without the Touch ID files, and the Installer Log says so in an error line that begins "Touch ID will not work on Linux". Only cancellation stops the installation at this step.

## Installations made before this collection

The vendor firmware on the ESP (`vendorfw/`) is written only by a fresh installation. Update Boot Loader stages Stage 1 and never writes the ESP, and a preserved reinstall replaces only the payload's own ESP members. An installation made by an installer that collected Touch ID only on the Neo therefore has no calibration on any other Mac. Its kernel log shows `calibration blob apple/mesacal-<board>.bin could not be loaded (ENOENT)` when enrolment starts. A fresh installation with this installer adds the files.

The Linux-side updater cannot rebuild them either. It converts only the raw firmware archive on the ESP (`asahi/all_firmware.tar.gz`), which has no Touch ID converter, and a calibration carved from the iBoot System Container is not in that archive.

## Permissions

Treat the root-key record as device-private: root-owned mode `0600` in staging and after installation, with private staging directories mode `0700`. Its archive writer and final installer must preserve that mode; ordinary world-readable firmware defaults are unsuitable.

`FirmwarePackageBuilder` writes every `apple/msrk-*.bin` with mode `0600` and uid and gid 0 in both `firmware.tar` and `firmware.cpio`, on every board, and never hard-links it to a file with another mode. Every other vendor firmware file stays `0644`.
