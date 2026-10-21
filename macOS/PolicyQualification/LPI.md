# LPI archives are host data only

`NeoRegulatoryPolicy.archiveLPIInputs(_:)` authenticates the same six 25G83
text tables as `derive(_:)`, then builds 129 LPI country archives, including
the 120 countries with usable VLP data. Each result uses
`mediatek/mt7932/policy-v3/CC.bin`. SP is never serialized.

This API is opt-in for host qualification and future driver development.
**It does not enable or install LPI.** The MT7932 fullmac LPI command selector
and AP TPE binding have not been established. `derive(_:)` remains the
installation API, emitting 244 v1 and 120 VLP v2 packages. The runtime parser
rejects v3. Do not put these archives in either operational policy directory.

The independent MIT implementation follows the J7RP unbound v3 table-data
contract in `aurora-silicon/linux`,
`Documentation/networking/device_drivers/wifi/mt7932-neo.rst`. Archive sections
carry table records, not firmware command pages. Directory binding revision
zero means unbound; indoor-only LPI metadata is a requirement for a future
consumer, not a claim that indoor restrictions have been enforced on hardware.

The sorted relative-path inventory is pinned to
`cfa39308ebb199b15860bd75c828a3d558e09f814749b883819b09df75179278`,
matching the independent Python producer across all 129 countries.
Synthetic tests cover LP-only countries, class-specific eligibility, no-data
rejection, production authentication, unchanged deployment and runtime rejection.
The opt-in live test verifies the complete inventory and deterministic output:

```sh
AURORA_LIVE_POLICY_TEST=1 macOS/PolicyQualification/test.sh -c release
```

No Apple files or generated archives belong in this repository. A future LPI
deployment change needs an established fullmac class/TPE ABI, driver association
selection and indoor semantics, KUnit positive/negative selection tests, and an
approved Neo test with a 6 GHz AP that explicitly advertises LPI. A VLP phone
hotspot does not establish LPI operation. Keep the existing v1/v2 deployment and
rollback packages available throughout qualification.
