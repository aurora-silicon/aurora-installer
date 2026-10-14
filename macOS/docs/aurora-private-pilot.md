# Private Aurora pilot integration

This plan predates the one image producer: the `image-builder/` paths below are the omarchy-iso-derived builder at #2's head, `5274846`, which this repository no longer holds (see [One image producer](image-producer.md)).

The Aurora package prototype lives in [omarchy-mac/omarchy-pkgs-aarch64 #67](https://github.com/omarchy-mac/omarchy-pkgs-aarch64/pull/67). Its kernel, headers and compatible m1n1 are independently rebuilt candidates. A successful build does not qualify them for installation. The tested Asahi/Limine build 25 remains the baseline; do not replace its product pins, branding manifest, tester bundle or instructions with unqualified Aurora output.

## Repository responsibilities

The package repository owns reusable recipes, pinned source inputs, native ARM builds, archive verification and retained build evidence. The installer repository owns authenticated consumption, image composition, the private product and installation qualification. Core changes that are generally applicable belong in `omacom/omarchy-mac` targeting `quattro-upstream`; Mac hardware behavior should remain in the hardware package wherever practical. Aurora release ownership and signing responsibilities still need agreement with Aurora. The prototype does not claim to be an official Aurora channel.

## Required image contract

Create a distinct private Aurora/Limine product. `image-builder/builder/products/omarchy-mx-mac-aurora.json` is the legacy product and is not a shortcut to the new pilot. The existing guards correctly reject Aurora with the schema-4 candidate path. Do not relax those guards before the complete new contract is in place.

The new path needs an explicit independently authenticated Aurora overlay containing exactly `linux-aurora`, `linux-aurora-headers` and `m1n1-aurora`. The unsigned CI manifest is review evidence, not an image admission credential. The release boundary must approve the retained complete set, verify its manifest digest and archives, and sign those exact bytes without rebuilding. Exercise the consumer with disposable keys before using the private development signing process; no production key or new installed-system trust is required for the prototype.

Authenticate the complete Asahi platform as today, then replace exactly `linux-asahi`, `linux-asahi-headers` and `m1n1` with the Aurora overlay. Preserve the schema-4 U-Boot replacement, Hyprland/Limine overlays, keyring and remaining platform inventory. Reject missing packages, duplicate names, unexpected replacement contracts and overlaps between desktop candidates, dependencies, platform packages and the Aurora overlay. Prove the offline package transaction resolves runtime dependencies and actually selects all three Aurora archives.

Freeze verified input copies before Docker starts and verify them again inside the builder. Include the approved Aurora manifest identity in the source/input graph, cache locks and final image evidence. The legacy Aurora cache path is tied to Marcelo's old snapshot and must not be reused for this product.

## Source integration points

All paths below are relative to `image-builder/`.

- `bin/omarchy-iso-make`: explicit overlay input, private product allowlist, input validation, frozen copies and Docker mounts.
- `builder/quattro-candidate-packages.sh` and `builder/build-asahi-os-package.sh`: explicit private product admission, preserving the existing Asahi contract.
- `builder/private-limine-qualification.py`: a separate Aurora contract requiring measured pins; never a general kernel-name bypass.
- `builder/quattro-dependencies.py` and `builder/quattro-dependencies.sh`: authenticated overlay composition, exact platform replacement and transaction evidence.
- `builder/asahi-stage-inputs.json` and `builder/checkpoint-verified-package-cache.sh`: source ownership and cache identities for the new verifier and snapshot.
- `builder/asahi-stages/finalized-boot.sh` and `builder/asahi-stages/sealed-release-package.sh`: select the new product's measured branding manifest. Selecting Limine currently chooses the Asahi private manifest, which is unsuitable for Aurora.

The new product and branding manifest must be derived from actual package bytes: Aurora m1n1, Aurora DTBs and the coordinated U-Boot candidate. Record the resulting boot binary digest and sizes. Neither the legacy Aurora hash nor the tested Asahi/Limine hash can stand in for this measurement.

## Qualification order

1. Retain the successful native build's exact source revision, three archive hashes, manifest digest, dependency inventory and toolchain evidence. Verify the retained set again outside the build job.
2. Exercise exact-set signing and consumer rejection tests using disposable keys. Missing or mixed overlays, the wrong signer, undeclared replacements and tampering must fail. The Asahi path must remain unchanged, and a changed overlay must invalidate cached image identity.
3. Resolve the complete offline package transaction. Check the installed kernel/header match and m1n1, DTB, U-Boot and Limine compatibility; derive the new boot measurements.
4. Build the separate private image with sufficient storage, then run image and VM checks. Review the packaged application UI on macOS. A green source test suite does not replace these checks.
5. With the owner present and explicitly authorizing the physical operation, repeat the full install on Scott's M3, encrypted reboot, recovery-key unlock and factory reset through a second owner setup. Chris's exact M3 Pro follows after model-specific admission and qualification; keep unsupported hardware fail-closed.

The first invited Aurora pilot is frozen and disposable: a failed trial may require Linux reinstallation. This does not change the future existing-quattro migration's data-preservation goal. No automatic tracking of Aurora branch heads, Mesa package, public update channel, merge or production release is included in this prototype.
