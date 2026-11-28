# Fuzz harnesses for the installer's untrusted-input readers

libFuzzer harnesses for the readers that parse data the installer did not produce: restore-image archives, AEA ranges, compressed APFS storage, firmware records, the Recovery template container, an unmounted FAT32 ESP and the engine transcript. They build and run on Linux in the `swift:6.2` image. They are host-only tools: nothing here is part of the app, the helper or any package.

## What each target reads

| Target | Reader | Sources |
| --- | --- | --- |
| `ipsw_zip` | ZIP/ZIP64 directory admission, local records, stored/deflate prefix, full, streamed and link reads | `IPSWArchive.swift` |
| `update_image` | OTA `BXDIFF50`/PBZX whole-image decoder, fed in reads of 1 to 256 bytes | `UpdateArchiveImage.swift` |
| `aea_ranges` | AEA prefix metadata, root header, cluster segment table and segments | `Crypto.swift`, `Ranges.swift` |
| `range_recipe` | Strict firmware range recipe JSON, validation and network closure | `Recipe.swift`, `Ranges.swift` |
| `apfs_storage` | decmpfs attribute and resource fork, LZFSE block walk, LZVN payload | `Compression.swift` |
| `firmware_formats` | IM4P DER, ordered XML plist, kernel Mach-O ProRes scan, controller firmware, multitouch, Neo camera/radio/calibration, signed sensor records | `FirmwareImage.swift`, `FirmwareDER.swift`, `OrderedFirmwarePlist.swift`, `ProResInitFirmware.swift`, `MultitouchFirmware.swift`, `NeoFirmwareConversions.swift`, `SignedSensorInputs.swift` |
| `firmware_inputs` | Broadcom Wi-Fi/Bluetooth selection, vendor firmware package builder | `BroadcomFirmware.swift`, `FirmwarePackage.swift` |
| `recovery_template` | Recovery template JSON container, reconstruction and inventory | `NativeRecoveryTemplate.swift` |
| `fat_volume` | Unmounted FAT32 reader (boot sector, FAT chains, 8.3 and VFAT names), then `install.conf` | `AuroraRemovalFATVolume.swift`, `InstallConf.swift` |
| `engine_transcript` | Engine JSON-lines transcript read back from a journal | `EngineContract.swift` |

## How the build works

`build.sh` compiles `Sources/AuroraFirmware` unchanged, with testing enabled, into one static library, and each harness against it with `@testable import`. A harness that needs installer sources lists them in `Harness/<target>.sources`; a source wrapped in `#if os(macOS)` has only that outer gate removed in the build directory. The few installer types those sources name from the rest of their target are declared in the harness.

The sources import Darwin-only frameworks, so `Shims/` provides fuzz-only modules with the same names:

- `Darwin`: Glibc plus the Darwin-only rename calls, which fail.
- `CryptoKit`, `CommonCrypto`: no cryptography. Digests are constant zero, every MAC verifies, HKDF returns zeros and AES-CTR copies its input. A fuzzer can then reach the parsing after each authentication step; the input bytes are the plaintext. P-256/HPKE key unwrapping throws.
- `Compression`: a stand-in decoder that produces as many zero bytes as the little-endian UInt32 at byte 4 of its input says (an LZFSE block's raw size field), truncated to the buffer. Apple's LZFSE and LZMA decoders themselves are not fuzzed.
- `RecoveryAccountCore`: no-op tree flushes.
- `zlib`: the system zlib, which is real.

`Support/` adds Linux glue to the library: FoundationNetworking and FoundationXML re-exports, a `URLSession.bytes` that never connects, and an empty embedded recipe.

## Build and run

From a directory that contains this worktree and the build output, with Docker and the `swift:6.2` image:

```sh
export FUZZ_WORK=/path/holding/both
Fuzz/run-docker.sh bash Fuzz/build.sh "$FUZZ_WORK/build" [target...]
python3 Fuzz/make-seeds.py "$FUZZ_WORK/build/seeds"
Fuzz/run.sh "$FUZZ_WORK/build" ipsw_zip 1800 -jobs=2 -workers=2 -max_len=65536
```

`run.sh` uses `-rss_limit_mb=1024 -malloc_limit_mb=512 -timeout=10`, a small ASan quarantine, and no leak detection (the async harnesses release their input after the reader returns). The container gets `--cpus 2`. Set `FUZZ_DEBUG=1` to print why a reader refused each input, to check that seeds reach the code they are for.

`linux-tests.sh <build-dir> <Tests/...Tests.swift> [test-name...]` runs XCTest cases from `Tests/AuroraFirmwareTests` on Linux against the same shims, with AddressSanitizer. Only tests that do not compare digests, MACs or Apple-decoded output can pass there; it is a quick check for parser regressions, not a substitute for the macOS suite.

`make-seeds.py` writes synthetic seeds only: archives and images it builds itself and inputs from the package's synthetic test fixtures. Never add a seed derived from an Apple file here.

## What a finding means

A reader must refuse malformed input with a thrown error. A Swift trap (bounds, overflow, force unwrap, precondition), a sanitizer report, a hang past 10 s or an allocation past 512 MiB is a bug in the reader. Because the crypto and Compression shims are permissive, a finding that depends on a forged MAC or digest is still a parser bug, but one that only an input passing authentication could reach in the app.
