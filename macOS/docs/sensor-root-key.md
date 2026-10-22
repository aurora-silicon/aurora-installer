# Touch ID root key and calibration

The Neo's enclave loads both sensor records only in the combined layout macOS hands it:

`comb { fdrd: IMG4 { IM4P, [0] seal-<ECID> }, secb: trust bundle }`

The factory cache (`/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata`) stores the pieces, not that layout:

- `MSRk-<sensor>`: an `IMG4` whose `IM4P` carries the root key. Its own factory manifest chains to a root the enclave does not trust, so the bare record is refused.
- `seal-<ECID>`: the FDR sealing manifest (`IM4M`).
- `trustobject-<sha256>`: the trust bundle. `trustobject-current` holds the bytes in use; a macOS update can leave older named bundles behind.

`NativeSensorInputCollector` rebuilds both records from these. It takes the `IM4P` of the factory `MSRk` record, uses `seal-<ECID>` as its manifest and adds the trust bundle as `secb`. The calibration is either a standalone FSC2 `IMG4`, from an `FSC2-<sensor>` factory record or carved from the iBoot System Container, or an FSCl `comb` record. The enclave refuses the plain FSC2 image (`LOAD_CALIBRATION` fails), so it is rebuilt the same way, with the same seal and trust bundle; an FSCl record already has the layout and is kept as it is.

Exactly one `seal-*` record is required. The trust bundle is the named `trustobject-<sha256>` whose digest and bytes match `trustobject-current`; without `trustobject-current`, exactly one named bundle must be present and match its name. Nothing is synthesized: every byte comes from this Mac's own records, and nothing crosses machines. `SignedSensorInputs.rootKey` and `SignedSensorInputs.sealedCalibration` admit the results structurally; they do not verify the certificate chain or the sensor binding.

On a Touch ID-equipped Neo (macOS 26.6.2, 25G83), the rebuilt root key is byte-identical to the 12,688-byte container macOS uses, and it enrols on Linux. The resealed calibration loads where the plain image is refused, and an enrolled finger matches after a reboot without re-enrolling. Those results come from records placed by hand; a fresh native install that writes them is still to be confirmed. Sensorless machines skip this collection.

Treat the root-key record as device-private: root-owned mode `0600` in staging and after installation, with private staging directories mode `0700`. Its archive writer and final installer must preserve that mode; ordinary world-readable firmware defaults are unsuitable.
