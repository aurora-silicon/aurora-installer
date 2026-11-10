# Standalone installer validation

## Candidate boundary

The standalone extraction validated at `3f1e30bb265e77da04ce03533be0a7dddaa8c84c` extracted source and adjusted repository-relative paths without altering the Swift runtime, Python engine overlay, source lock, release trust configuration or Linux payload. The local evidence below applies to that extraction revision. The provenance record identifies the original source; record `git rev-parse HEAD` whenever testing a candidate.

The subsequent CI integration adds a behavior-preserving Swift 6.2 compatibility change in `Sources/AuroraAppleInstallerApp/InstallerComponents.swift`: both disk-bar drag callbacks explicitly convert the `CGFloat` ratio to `Double` before calculating the Aurora fraction, resolving a compiler ambiguity. It also skips the live physical-Mac inspection test on `VirtualMac` hosts, as described below. These changes passed [CI run 35539039492](https://github.com/omacom/omarchy-mac-installer/actions/runs/35539039492) at merge revision `f2235e4ed823b31efd2c53306d7f9435ac1fd250`, separately from the earlier extraction validation.

The Linux source checks are `bash test/all`. They compile the build- and CI-only Python scripts, check shell syntax, run the catalog, payload and packaging unit tests, and exercise the package-plist, branding and publication scripts with fixtures. They do not qualify a macOS app bundle or physical installation. Since the Python engine was removed, the installer runs only its Swift engine; the sections below that mention an engine, engine tests or an inspection engine are historical extraction records.

## Continuous integration

[Native installer checks](../../.github/workflows/native-checks.yml) runs the portable checks on Ubuntu and strict Swift formatting, Debug/Release tests, preview assembly and code-identity fixtures on an ARM Mac. The workflow records its source revision and tool versions and retains failure logs with the run.

The read-only live physical-Mac inspection test skips `VirtualMac` hosts. Hosted CI cannot qualify a real Mac's disk, Recovery environment or hardware. Current device qualification is recorded in [aurora-distributions](https://github.com/aurora-silicon/aurora-distributions).

## Historical extraction evidence (September 2026)

The extraction was checked on 2026-09-20 as the non-root `scott` user on aarch64 Linux with Python 3.14.7. The portable suite passed: 37 engine tooling tests, 104 engine overlay tests and 17 catalog tests (158 Python tests), plus all existing preclean and three extracted packaging/publication shell tests. Python compilation and shell syntax checks passed.

The same source revision, `3f1e30bb265e77da04ce03533be0a7dddaa8c84c`, was then validated on Scott's M4 Pro (`Mac16,7`, arm64), running macOS 26.6.2 (25G83), Xcode 27.0 (27A266a) and Swift 6.4. XcodeBuildMCP 2.7.0 was staged inside the validation workspace from its official standalone archive, verified against the publisher's SHA-256 `bd724a2c0e6ffe027b3f46257e66d626149a64cd045f4867124bd683b3cf081a`.

| Check | Result |
| --- | --- |
| Strict Swift formatting | Passed |
| Debug Swift tests | 402 passed, 0 failed, 0 skipped |
| Release Swift tests | 396 passed, 0 failed, 0 skipped |
| Recorded journal fixture and blocked-host tests | Passed within both Swift suites |
| Development app assembly | Passed with the exact pinned inspection engine |
| Ad-hoc app and helper signatures | Deep/strict verification and reciprocal code requirements passed |
| Bundle structure | Executables, helper plist, release inputs and engine verified |
| Debug simulation launch | Scott confirmed the simulation window is visible |
| Successful installation → Recovery simulation | Scott completed the flow and shutdown confirmation; the app displayed “Simulation complete: shutdown would begin now. Your Mac stays on.” |

The app was assembled with a separate development copy of the release descriptor using an ad-hoc helper requirement. The tracked production descriptor, public key and source code were unchanged. No production signing credentials, helper registration or installation operation were used.

Swift 6.4 emits three capture warnings in inherited code: `PayloadPrefetch.swift:94`, `PayloadPrefetch.swift:523` and `InstallerSession.swift:635`. They concern inner weak captures inside an implicitly strong outer capture. They did not fail builds or tests, and the extraction does not change that runtime behavior.

The Python/shell suite was not repeated on macOS: its installed Python 3.9.6 and Bash 3.2 are below this runner's declared prerequisites. Its complete Linux result remains separately recorded. The successful-install visual path is confirmed. The remaining visual failure/recovery scenarios, complete native engine rebuild and physical installation qualification are still pending. Exact logs, app file hashes, isolated-copy results and transfer artifacts are retained alongside the local checkout in the extraction workspace's `evidence/` and `artifacts/` directories. These extraction results do not qualify subsequent implementation changes.

## macOS build handoff

Scott has an M3 Air and an M4 Pro available with macOS. Either can be the primary build machine. Build once against the recorded revision and use the second machine for a separate UI or host-support check when useful; do not run duplicate qualification jobs for the same inputs.

1. Copy or clone the standalone repository and check out the candidate revision. Record `git rev-parse HEAD`, `sw_vers`, `uname -m`, `xcodebuild -version` and `xcrun swift --version` with the results. The package requires macOS 15+ and Swift 6.2+; use an Xcode toolchain meeting those requirements and XcodeBuildMCP.
2. Run the portable suite with Bash 5 and its listed dependencies.
3. Lint with Xcode's bundled formatter, then run both Swift configurations:

```bash
xcrun swift-format lint --strict --recursive Package.swift Sources Plugins Tests
xcodebuildmcp swift-package test --package-path "$PWD" --configuration debug
xcodebuildmcp swift-package test --package-path "$PWD" --configuration release
```

4. If those pass, use the existing `Development/Run Simulation.command` launcher for a debug-only UI review. Keep one app instance on the review machine. Follow [the simulation scenario matrix](../Development/Simulation.md), including unsupported hosts, failed downloads, changed plans, interrupted execution and Recovery handoff. Simulation uses dummy credentials; it is not a live install or an inspection of that Mac's actual eligibility.
5. Record failures and the exact test counts/logs. Verify the imported journal fixture is exercised and unsupported models remain rejected. Mac hardware support needs a separate real host inspection against the native engine and intended signed catalog; simulation does not establish it.

These steps require no helper registration, real machine-owner credentials, production signing, disk changes or release publication. If a run asks to cross one of those boundaries, stop and review that as a separate operation.

## Before packaging or installation

Use the [native DMG workflow](native-dmg-release.md) with matching signed schema-5 catalogs. No inspection engine archive or Python runtime is required or accepted. Record the exact source revision, catalog revisions, test logs and signing/package results for the candidate.

Physical installation needs its own backup, recovery, image/package revision and authorization record. Qualification covers installation, Recovery boot, first boot, updates and encrypted-install behavior on the assembled stack. Passing source checks does not satisfy those checks.
