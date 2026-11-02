# J614s Wi-Fi firmware investigation

Aurora installer main was `b0aaf0b04a620f67a2abdb322b9b4895a202c69f` on 2 November 2026. [Aurora PR #84](https://github.com/aurora-silicon/aurora-installer/pull/84) already admits J614s; this work concerns Wi-Fi firmware. Aurora and Asahi excluded the BCM4388 C2 directory after broken data was observed in an older image.

## Recovery source

The installed macOS 27.0.1 (26A434) Recovery image contains the complete Mriya set under `System/Library/DriverExtensions/com.apple.DriverKit-AppleBCMWLAN.dext/Firmware/C-4388__s-C2`. Its `mriya.trx` and `mriya.sig` point to sibling Guam files. The Mriya binary, signature, CLM, transmit-cap, both board NVRAM variants and the X3 files requested by this Mac's macOS driver match the corresponding full macOS 27.0.1 files byte for byte. These findings record no firmware or calibration content.

An earlier inspection of the 26.6.2 (25G83) and 27.0 (26A428) images checked only `usr/share/firmware/wifi`; it did not check the DriverKit bundle. Claims that those images lack Mriya firmware image-wide were incorrect. The installer-selected 26.6.2 image was subsequently retrieved from Apple's UniversalMac restore: the J614s BuildManifest selects `022-22048-093.dmg.aea`. Its downloaded member matched the ZIP size and CRC, and its AEA decryption authenticated successfully. Its Recovery system version identifies build 25G83, and the DriverKit C2 tree contains the complete Mriya set. The 27.0 DriverKit tree has not been rechecked.

## Candidate and validation

For J614s the native installer selects the C2 directory as one set from the authenticated, read-only Recovery image's DriverKit bundle. It discards any partial shared-tree C2 inputs, follows sibling aliases within that directory, includes the selected raw set in the fallback archive, and refuses publication unless converted Mriya binary, signature, CLM, transmit-cap and at least one board NVRAM output are nonempty. Other C2 boards remain excluded from conversion. No source files are borrowed from the running macOS volume.

The real 27.0.1 and 26.6.2 Recovery images passed the production read-only snapshot and conversion path in the focused native check. Their Mriya binary, signature, CLM and transmit-cap outputs matched their respective source bytes, both board NVRAM outputs were present, and tar and cpio packages were generated. The 26.6.2 binary, signature, CLM and transmit-cap differ from the full 27.0.1 macOS files; both NVRAM variants match.

On 2 November 2026 the J614s booted a one-shot Linux trial with the converted 26.6.2 files. All six runtime firmware hashes matched the converted output; `brcmfmac` initialized BCM4388/6 with firmware `23.50.20.2.41.51.209` (FWID `01-fa2c3dc1`), NetworkManager reported Wi-Fi connected, and an HTTPS request returned HTTP 301. The owner confirmed Wi-Fi operation. The normal boot and firmware were restored afterward. An earlier PCI rebind attempt did not initialize the device and was not treated as a valid test. This qualifies the firmware on this machine, not installer ESP publication or a fresh installation.

A physical installation test remains separate: preserve the existing installation and its recovery path, install to a separate target, record the selected source and image versions, and verify first-boot Wi-Fi and driver logs. The current J614s installation's working Wi-Fi followed manual provisioning from full macOS; its installed recovery firmware archive is root-only and was not compared here. The initial installation used unencrypted Btrfs; conversion after interruption was not qualified.
