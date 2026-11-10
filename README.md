# Aurora Installer

A native macOS app for installing Aurora Linux on Apple Silicon Macs.

Choose **Fedora Aurora Remix**, **Aurora ALARM** or **Aurora NixOS**, with **KDE Plasma**, **GNOME** or a **minimal shell** system.

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

Standalone [speaker-tuning tools](tools/speaker-tuning/README.md) and their Python firmware library remain available for existing Linux installations.

## Credits

Aurora Installer builds on work from the Asahi Linux contributors and the Omarchy macOS installer. Attribution and import history are retained in [provenance](macOS/docs/extraction.md) and the [firmware library notes](macOS/Sources/AuroraFirmware/PROVENANCE.md).

Licensed under [MIT](LICENSE); third-party notices remain with their sources.
