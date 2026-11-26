# Aurora Installer

A native macOS app for installing Aurora Linux on Apple Silicon Macs.

Choose **Aurora Fedora Remix** (defaulting to **GNOME**), **Aurora ALARM** or **Aurora NixOS**, with **GNOME**, **KDE Plasma** or a **minimal shell** system.

The app and privileged helper use a built-in Swift engine for disk planning, partitioning, image writing, firmware extraction and Recovery setup. Installation runs without a Python runtime or a downloaded engine.

## Downloads

See [Aurora distributions](https://github.com/aurora-silicon/aurora-distributions) for current downloads, supported Macs and hardware validation. Follow the app's installation and Recovery instructions.

## Development

The app requires macOS 15+, Swift 6.2+ and XcodeBuildMCP. Build a simulation preview:

```sh
cd macOS
XCODEBUILDMCP=/path/to/xcodebuildmcp bash Packaging/build-aurora-preview.sh /absolute/output
open "/absolute/output/Aurora Installer.app" --args --simulate
```

The preview uses simulated data and does not change disks or register a helper. See [macOS development](macOS/README.md) for tests, packaging and the source layout.

An installed system boots with one picture on screen from power-on to the desktop; [flicker-free boot](https://github.com/aurora-silicon/aurora-distributions/blob/main/docs/flicker-free-boot.md) describes each boot stage, the branding a distribution or downstream configures, and how to verify it.

Existing Linux installations get speaker tuning from `aurora-speaker-upgrade` (speakerguardd), which takes it from the pinned macOS restore image, and keep their Wi-Fi and Bluetooth firmware on their stub firmware's restore image with [aurora-wifi-firmware](tools/wifi-firmware/README.md).

## Credits

Aurora Installer builds on work from the Asahi Linux contributors and the Omarchy macOS installer. Attribution and import history are retained in [provenance](macOS/docs/extraction.md) and the [firmware library notes](macOS/Sources/AuroraFirmware/PROVENANCE.md).

Licensed under [MIT](LICENSE); third-party notices remain with their sources.

## Release channels

A new installation opens on Edge when the selected distribution profile's signed, qualified Edge catalog (built from both Linux and Mesa `aurora-edge` sources) admits the Mac and lists it as family-qualified (its chip family passed the Edge rows on a named machine), and on Testing, shown as Nightly, otherwise. An Edge catalog that cannot be fetched or verified never falls back to Testing, Reset and Update Boot Loader keep the channel an installation came from, and a choice in the Release channel menu always wins.

New Edge catalogs use a separate endpoint from the legacy development URL. Signed channel identity, packaged source revisions/trees and detached qualification evidence separate Edge from Testing. Existing development rollback state is retained for Testing; Edge uses its own rollback floor. No existing Testing set is promoted to Edge by these changes.
