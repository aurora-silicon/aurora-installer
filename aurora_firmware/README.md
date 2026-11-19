# Standalone firmware tools

This Asahi-derived Python library supports firmware updates and the [speaker-tuning recovery tools](../tools/speaker-tuning/README.md) for existing Linux installations. It is not part of the native macOS installer's execution path or app bundle.

The macOS installer uses the Swift implementations in [`AuroraFirmware`](../macOS/Sources/AuroraFirmware) and [`AuroraAppleInstaller`](../macOS/Sources/AuroraAppleInstaller).

Run the Python firmware and speaker-tool tests from the repository root:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Original copyright and third-party notices remain in the source files. See the repository's [MIT license](../LICENSE).
