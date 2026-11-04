# Apple AVD firmware collection

Apple AVD MCPU firmware is an optional, machine-local installer input. Aurora does not distribute firmware bytes. The kernel requests `apple/avd-apple-<soc>.bin` and uses its open firmware when no Apple image is available. A collector must use the selected install identity; neither the refresh host's chip nor another SoC's image is a substitute.

The per-SoC tables in `asahi_firmware/avd.py` and `Sources/AuroraFirmware/AVDFirmware.swift` keep unmeasured layouts disabled. T6040 has an observed MCPU image size of 60,616 bytes and a macOS version property of `0x23f3b998`. The version property is independent of the hardware version register and is not a proved byte offset in the raw image. iBoot/IPCE preloads the image used by macOS on this SoC; the collected disk image is a reload copy.

Production source rules remain empty until a per-SoC file location and unwrap rule are established. The T6040 size/version entry alone does not identify a source component or IM4P tag. The native and Python installers have optional selected-component plumbing, and the refresh tool can preserve an already collected raw reload copy; this stage does not yet extract an AVD image from an unmodified macOS install. Synthetic component/tag names in tests are never production source rules.

The normal `FILE <name> SHA256 <digest>` or `LINK <name> <target>` manifest record is followed by `VERSION <name> 0x<version-word> SIZE <byte-count>` for a validated AVD image. Both `manifest.txt` and the CPIO `.vendorfw.manifest` include this record. Other firmware records retain their existing representation. The raw MCPU file has no added header or padding.

The device-local `all_firmware.tar.gz` fallback retains collected reload copies under their firmware-relative names. `asahi-fwextract SOURCE DEST` reads the chip identity from SOURCE's selected `BuildManifest.plist` or `stub_info.json` and collects only that SoC's copy. Conflicting identities are refused. Older fallback archives without AVD data remain usable and produce no AVD record. No runtime firmware download or cross-machine cache is involved.

Tests generate synthetic payloads and containers in temporary directories; no Apple code or firmware bytes are test fixtures. Source/ownership admission, boot policy, and firmware publication remain the responsibility of the existing installer transaction.
