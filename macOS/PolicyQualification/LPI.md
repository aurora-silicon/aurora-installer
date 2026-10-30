# LPI table archives and runtime packages

`archiveLPIInputs` preserves the t-2862 unbound J7RP v3 archive API. Its
production path authenticates all six inputs and pins the 129-country v3
inventory before binding. No proprietary implementation or table bytes are
included in source.

`derive` also emits `mediatek/mt7932/policy-v4/CC.bin` for those LP countries,
with independent VLP sections where available. Version 4 changes only the
outer version halfword and 6GCL binding revision (1), retaining every class
record, permission mask and indoor requirement. The driver binds these data
to the clean 2026-10-31 SPEC's CID 0x5d class selector. SP is never serialized.
The independent Swift validator checks class ordering, masks, country, units,
record order, lengths and numeric primary data before publication.

All 244 v1 and 120 VLP v2 outputs are retained for older kernels and rollback.
Unbound v3 is not installed and remains rejected by runtime validation. Empty
legacy LP sections do not require a 6 GHz matrix or acquire LPI authority.

The kernel candidate still rejects finite AP TPE because the clean SPEC does
not identify J700 SISO/CDD/MIMO antenna gains. Installing v4 does not resolve
that gate or qualify RF operation. Do not claim ordinary LPI connectivity or
radiated-power compliance until a clean gain source and controller-approved
AP/power tests exist. No live firmware-input test was run for this task.

Synthetic qualification:

```sh
macOS/PolicyQualification/test.sh -c release
```

The focused suite covers unchanged legacy outputs, authenticated-source
rejection, class-specific masks, v3 rejection, v4 binding/data preservation,
malformed headers and package publication. Tests never use radio hardware.
