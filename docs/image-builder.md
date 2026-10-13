# Linux image builder

`image-builder/` holds the one Apple Silicon image producer: mx-mac's `build-mac-image`, adapted to build from a signed candidate set, with #2's candidate importer, Limine contract and installed-system checks beside it. [One image producer](image-producer.md) records the decision and where each part comes from; [image-builder/README.md](../image-builder/README.md) is how to run it.

The installer application and its image producer are reviewed in this repository. Runtime changes remain in `omacom/omarchy-mac:quattro-upstream`, and package recipes in `omacom/omarchy-pkgs`.

## Checks and entrypoints

Run `bash test/all` for portable installer checks and `bash image-builder/test/all` for the producer's source checks. The latter needs Bash 5, Python 3.11 or newer, GnuPG, jq and bsdtar; it needs no container, network or root.

Building an image needs an aarch64 Linux host with Docker and loop devices: `image-builder/bin/mac-image-inputs resolve`, then `image-builder/bin/build-mac-image`. Building, signing, booting a VM and publishing are separate operations and are not part of the ordinary PR source-check job.

## Qualification boundary

An image is inspected against its candidate set before it is packaged, but inspection is not boot qualification: install, first boot, encryption and second boot on a Mac or a VM remain the hardware gate. No merge or production release is authorized by source-check success.
