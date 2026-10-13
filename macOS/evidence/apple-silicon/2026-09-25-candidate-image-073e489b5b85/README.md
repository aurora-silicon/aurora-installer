# First image from the signed candidate set

Built 2026-09-25 (22:11–22:26 AEST) on the M1 Pro's Omarchy side by `image-builder/bin/build-mac-image` at `a04392d`, from the signed test candidate set `apple-test-073e489b5b85-20260925` (omacom/omarchy-mac#538: omarchy-mac `073e489b5`, signer `E11E851AF82E02AEF54C8794599A6024E3D35379`).

| | |
| --- | --- |
| Payload | `omarchy-2026.09.25-aarch64-apple-silicon-mac-edge-os-package.zip`, 3,575,510,011 bytes |
| sha256 | `5e2a293ae6e9584bf4e098acc24598f99f635e837901ff6439c116d8db1521af` |
| Location | `omarchy-m1-pro:/var/tmp/omarchy-images/apple-test-073e489b5b85-20260925/image/`, beside the inputs record, the candidate set and the package cache that rebuild it |
| Inspection | passed, 15 checks (`INSPECTION`) |
| `package_set_sha256` | `4d0dd5deda6f0e30685d41a545d0d0f6603687a2f2d816fe4f2dbcb8be4d91e3` (926 packages) |

Reproducibility: two builds at `ce7d415` from the same inputs record gave identical `IMAGE` input lines and identical records for all 926 packages. This build at `a04392d` has the same package set and records; its `IMAGE` differs only by the `builder_tree_clean` line that commit added. The zips differ, as expected: filesystem images are not byte-identical.

Not installed: `obs-studio`, which the pinned repositories do not carry for aarch64. Hardware setup ran during the build (`hardware_setup=build`): this runtime predates deferred hardware setup (omacom/omarchy-mac#528).

This is not boot qualification: install and first boot on the M2 Max and M1 Pro are tickets 25 and 26.
