# Standalone firmware tools

This Asahi-derived Python library supports firmware updates for existing Linux installations: [aurora-wifi-firmware](../tools/wifi-firmware/README.md), and speakerguardd's `aurora-speaker-upgrade`, which vendors it. Per-model firmware comes only from Apple's restore images (`ipsw.py`: `aea_ro`, `udif_ro`, `apfs_ro`, `remotezip`, by HTTP ranges); only per-unit values come from the Mac. It is not part of the native macOS installer's execution path or app bundle.

The macOS installer uses the Swift implementations in [`AuroraFirmware`](../macOS/Sources/AuroraFirmware) and [`AuroraAppleInstaller`](../macOS/Sources/AuroraAppleInstaller).

Run the Python firmware and speaker-tool tests from the repository root:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Original copyright and third-party notices remain in the source files. See the repository's [MIT license](../LICENSE).
