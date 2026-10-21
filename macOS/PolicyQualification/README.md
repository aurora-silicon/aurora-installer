# Native policy qualification

This focused Swift Testing package compiles the production AuroraFirmware sources and the same policy tests included by the main macOS package. It supports Command Line Tools installations that do not include XCTest; it does not replace the full installer XCTest suite on Xcode hosts.

```sh
macOS/PolicyQualification/test.sh
macOS/PolicyQualification/test.sh -c release
AURORA_LIVE_POLICY_TEST=1 macOS/PolicyQualification/test.sh -c release
```

The opt-in live test reads the six pinned tables from the running macOS, derives 244 v1 and 120 v2 packages in memory, and verifies both inventories. It writes no Apple tables or generated policy packages. The regular tests use synthetic data and a recording modprobe; they never probe hardware.
