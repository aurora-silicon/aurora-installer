# Aurora Recovery

The Aurora-branded native Recovery interface lives alongside the main installer. It has two explicit build modes, targeting macOS 13 independently of the main installer's macOS 15 requirement.

Older Recovery stubs can omit frameworks available in full macOS despite the same deployment version. The Recovery interface is programmatic AppKit and uses no SwiftUI or Combine. Recovery computes its SHA-256 checks with CommonCrypto in libSystem. The app build refuses direct SwiftUI, Combine, CryptoKit or CryptoTokenKit linkage, and any required Swift library beyond `libswiftCore`, `libswiftDarwin`, `libswiftDispatch`, `libswiftObjectiveC` and `libswift_Concurrency`, the only ones the macOS 13.5 Recovery stub provides. It has no Swift AppKit overlay, so overlay-only calls such as `NSSound.beep()` stop the app launching there; weak-linked libraries remain allowed. The deployment target and link check still need a boot test in the affected Recovery stub before claiming that launch is qualified.

## Preview

On macOS with Xcode and XcodeBuildMCP installed:

```sh
cd Recovery
./build-preview.sh
open "build/Aurora Installer.app" --args --preview
```

Use `--recovery-preview` to preview repair. This build always defines `AURORA_STEP2_PREVIEW` and cannot enroll or modify startup software even when launched in Recovery. Keep only one review app instance open. Previewing does not implement the main installer's proposed new Recovery-account creation flow. Preview builds can simulate the environment check and tool preparation, so their waits and failures can be reviewed; Recovery builds ignore these options. `--preview-check-seconds=N` (0 to 30) sets how long each step takes, `--preview-recheck=owner-changed|fail` sets how checks after the first end, and `--preview-tools=pass|fail` simulates preparing the Recovery tools.

## Actual Recovery build

```sh
cd Recovery
./build-recovery.sh
```

This explicitly defines `AURORA_STEP2_RECOVERY`, emits `build-recovery/Aurora Installer.app` and `build-recovery/omarchy-recovery-app.json`, and verifies the executable's `--build-mode`, ad-hoc signature and localized bundle name. The template has no target UUIDs, credentials or boot payloads. It cannot enroll by itself: the engine must populate validated configuration and the target's actual startup files.

Put the app and adjacent manifest in the OS ZIP under `esp/aurora/recovery/`. The OS template should declare `"recovery_gui": "omarchy-native-v1"`; this requires the app and verifies its entire content inventory before partitioning. Older payloads without this contract or app retain their existing shell Step 2. After creating the target and finalizing Stage 1 and `m1n1/boot.bin`, `aurora_recovery.stage` copies the signed app unchanged to the stub System volume. It separately publishes `Aurora/Recovery/InstallData/install-config.json` and `Aurora/Recovery/InstallData/AuraPayloads/` with the finalized Stage 1, Stage 2 and device firmware. Both inventories are checked before changing `.IAPhysicalMedia` to launch the app. The signed `OmarchyRecoveryDataLayout=external-install-data-v1` marker is required during payload preflight, staging and app packaging; an older embedded-data binary is refused before partitioning.

Configuration schema 2 includes `volumeName`, `systemUUID`, `groupUUID`, `prebootUUID`, `espUUID`, `bootMode`, `stage2Path` and `bootstrap`. `bootMode` is `raw` or `macho`, and `stage2Path` follows it (see below). The installer picks the mode from the Mac's chip and exposes no boot-mode control. Runtime target discovery uses the app's containing volume, verified against the configured APFS identity; it does not rely on `/Volumes/Omarchy` or a fixed disk number.

The legacy `Finish Installation.app/Contents/Resources/boot.bin` remains for upstream resume detection; its `step2.sh` becomes a relative launcher for `Aurora Installer.app`. The new app remains on the stub after completion removes `.IAPhysicalMedia`, and the `aura` command opens its actual executable or invokes recovery actions. The localized `CFBundleDisplayName` must remain present: Recovery's Springboard requires it for this direct native launch contract.

Enrollment rechecks root, the configured target volume and paired power-button 1TR, then resolves a real target volume owner from APFS and target Preboot metadata. When no eligible target owner exists, the explicitly configured `source-volume-owner` bootstrap can use the original macOS owner. That path binds the original System volume and APFS group UUIDs, requires the volume still exists, and intersects copied target administrator metadata with both the specifically authorized source owner UUID recorded by Stage 1 and its current APFS VolumeOwner list. Ambiguous or unmatched owners are rejected. The recorded recovery account takes precedence once APFS reports it as a volume owner; a finalized account that loses ownership is rejected. Existing bputil/kmutil prompt handling stays in the native PTY backend. Normal macOS is rejected before writes. The app retains persistent attempt logs and bounded UI log rendering.

The bootstrap System UUID names the underlying System-role APFS volume, not the boot snapshot mounted at `/`. For older configurations that recorded a snapshot UUID, Recovery resolves the unique System volume in the recorded source group and verifies that the recorded snapshot belongs to it before querying ownership. Snapshot enumeration can require mounting that source volume read-only. A missing snapshot, changed group, ambiguous System volume, or unregistered owner remains an error.

## Boot mode

Macs with an M4-generation chip or later (T8132, T6040/T6041, T8140, T8142, T605x and later chips) enroll aura's Mach-O boot object as Stage 1, always padded for a 128 MiB code window. M1 to M3 keep the raw image, enrolled as before. `AuraStage1Format.usesMachO(chipID:)` is the one predicate for this, applied to the chip ID that the main installer reads from `IODeviceTree:/chosen`. There is no control for the mode or the padding, and no fallback on these chips: the installer refuses a payload that lacks `esp/aurora/stage1.macho` (aura's `build/aura-boot.macho`), lacks a confined Stage 2, or isn't qualified on the selected firmware, and it refuses an object that does not carry that exact raw Stage 1 at the start of `__TEXT_EXEC`. Recovery refuses a configuration whose mode doesn't match this Mac's chip, or when it can't read the chip. Payload metadata from `scripts/assemble-distribution-payload.py` declares these files in `aurora_macho_boot`, so the installer refuses a Mac it can't start while planning, before the restore image downloads, and says that this release doesn't support it yet. The assembler checks the files only where a payload has them, because one payload serves every Mac. A reset of a Mach-O installation whose Stage 1 still loads `m1n1/boot.bin` is refused with a message to update its boot loader first (see Updating Stage 1).

## Stage 2 paths

| Stage 1 | Chainloads | Updated by packages on Mach-O chips |
| --- | --- | --- |
| Raw image, on M1 to M3 | `m1n1/boot.bin` | not a Mach-O chip |
| Mach-O, padded | `m1n1/boot-ctxr.bin` | yes |

A fresh installation on a Mach-O chip gets both files on its ESP. The payload supplies `m1n1/boot-ctxr.bin` from `esp/m1n1/boot-ctxr-<board>.bin` if it has one, otherwise from `esp/m1n1/boot-ctxr.bin`; other chips never receive it. A reset on a Mach-O chip writes the same files as a fresh installation.

`install-config.json` and the manifest's `modes` name the path, `stage2Path` and `espPath`. The Recovery payload keeps that one Stage 2 as `raw/boot.bin` in either mode, beside `macho/aura-boot.macho` and `raw/aura-raw.bin`. `defaultMode` and `bootMode` name the chip's mode.

Before any change, Recovery checks the object's layout, rejecting any non-empty `__TEXT_BOOT_EXEC`, checks that this Mac's chip uses Mach-O, and checks that the object chainloads the configured path. A Mach-O configuration that names `m1n1/boot.bin` is refused when Recovery reads it.

## Updating Stage 1

An existing installation can get a newer Stage 1 without being erased: M1 to M3 a newer raw image, M4 and later the padded Mach-O object, including installations an earlier installer enrolled unpadded and loading `m1n1/boot.bin`. Stage 2 on the ESP is left to the distributions, and Linux and its partitions are not touched.

In the macOS app, the Partitions screen's ⋯ menu offers Update Boot Loader… on every row that Reset accepts. It prepares Reset's plan for that installation, downloads and verifies the release, and asks for an administrator's password. The helper receives that package with the `update-stage1` operation, which only a Reset package may use. It plans the reinstall candidate again from the current disk and requires the approved plan, recognizes the installation with Reset's own checks, and requires `install-config.json` to name the recognized System, Preboot and EFI partitions and this Mac's boot mode. It fills the release's Stage 1 for this ESP with the code a fresh installation uses, rejects anything over 64 MiB, a Stage 1 Recovery wouldn't accept, a startup container without room for the padded object, and an ESP without the Stage 2 the new Stage 1 loads. If the enrolled Stage 1 is already this one, nothing changes. Otherwise it builds a new `InstallData` beside the old one, holding the new Stage 1, the manifest, `install-config.json`'s `stage2Path` and, when that path changes, the release's Stage 2 as Recovery's copy. It swaps that in with one rename, then updates the Recovery app, chooses the installation as the startup disk and arms its Recovery launcher. Nothing on the ESP is written, and the update keeps no installer job or execution journal.

Recovery then opens on Update startup software instead of Restore. Update runs setup's environment and owner checks, verifies the staged object's checksum and layout, that it chainloads this installation's ESP and `stage2Path`, and that the ESP holds that file, then pads and checks the object as setup does. After the owner's password it runs the same `bputil` and `kmutil configure-boot` commands. Only after enrollment succeeds does it record the new Stage 1 in the receipt, update the stub's `Finish Installation.app` copies that a later Reset compares, and disarm the launcher. A failure before then changes nothing Recovery records, so opening Recovery again offers the update again. Restart after an update doesn't compare the ESP's Stage 2 with Recovery's copy, because the distribution may have updated it. While an update waits, `aura recover` refuses, since Recovery's Stage 2 belongs to the Stage 1 not yet enrolled.

## Code window

On T8140 and later, iBoot confines each secondary core's EL2 execution to a locked window, CTXR_D, which nothing at runtime can move. Across 161 recorded boots of one J700 Stage 1, the window started at the device tree's physical address and was exactly the device tree, the static trust cache and kmutil's `kcrz` long. `kcrz` runs from the object's load address to the end of `__TEXT_EXEC`, so the way to a larger window is a larger `kcrz`. A probe of a 256 MiB padded object on a J700 found the window ending exactly where `kcrz` predicts.

`kmutil` derives `kcrz` from file offsets. A `__TEXT_EXEC` grown only in vmsize leaves it unchanged, so the padding has to be in the file. `MachOBootObject.expandExecuteWindow` pads `__TEXT_EXEC` with zeros to hold aura's 16 MiB slot and a 2 MiB-aligned 128 MiB region at any load address, and moves the later segments up in both file and memory. aura's code keeps its bytes and addresses. The object is about 146 MiB long (153 MB) but is written as a sparse file that takes what the original object takes on APFS, and `kmutil configure-boot --compress` stores it in Preboot with LZFSE.

The main installer refuses, before partitioning, a Mach-O plan whose object can't be padded or whose restored stub, Recovery data and padded object wouldn't fit the startup container. For Apple's 26.6.2 restore image that comes to about 2.1 GB on a J700 and 1.9 GB on a J616s, in a 6 GB container. Recovery then requires free space for the object's whole 146 MiB on the target's volume, because `kmutil` reads all of it and where it works isn't documented. It requires that its own `kmutil` offers `--compress` and that `kmutil inspect` reports `kcbz : 0` and exactly the expected `kcrz` for the padded file, and enrolls that file with `--compress`. If `kmutil inspect` fails, or reports no such region, Recovery refuses and nothing changes. macOS 26.6.2 (25G83) and 27.2 both print `kcrz`. If a `kmutil` prints none, an exact `kcwf`, the first writable offset, is accepted instead and logged. No Recovery `kmutil` has been sampled on a padded object yet.

The journal and receipt record `executeWindowSize`, and `stage1SHA256` stays the hash of the unpadded payload, so `aura recover` is unaffected. A resumed setup that is past enrollment doesn't pad the object again. Compression can take minutes on an older Recovery, so the progress text says so, and `kmutil configure-boot --compress` alone may run for 30 minutes where other authorized commands stop at 5. A command that reaches its limit is killed, which leaves the enrollment ambiguous: setup keeps its journal and enrolls again on the next attempt.

The kernel reserves the window, so its 128 MiB isn't available to the rest of Linux. A 256 MiB object enrolled with `--compress` has booted on a J700. This 128 MiB size has not been booted yet.

`Tools/ExecuteWindowTool.swift` is the same padding as a command, for inspecting the result or enrolling by hand. It writes to a temporary file unless given `-o`:

```sh
xcrun swiftc Sources/Account/AuraStage1.swift Tools/ExecuteWindowTool.swift -o aura-execute-window
./aura-execute-window macho/aura-boot.macho
```

## Validation and limits

The strict configuration fixture, original enrollment/owner/boot-selection fixtures, native prompt fixture, Python staging/checksum/target-identity fixtures and source formatting are tested. `swift test` runs window-level state tests against the preview build's simulated flow: waiting buttons, the password prompt with a passing, failing or owner-changing repeated check, tool-preparation failures and the Installer Log window. The Recovery CI workflow runs these, the builds and strict lint on pull requests and pushes to main that touch Recovery. Both real and preview builds compile and pass signing and localized-name checks. The normal-macOS CLI rejection is tested. These are build and fixture results, not a completed fresh-install or Recovery boot qualification.

The main installer ends with shutdown instructions. Its authenticated helper verifies the completed installation and updates that target’s Recovery app before requesting shutdown. It does not create an account in macOS.

Step 2 enrolls startup software using the explicitly bound existing macOS owner, then asks for a new recovery username, password and confirmation. Account creation uses the existing native implementation: immutable target identity checks, empty-database/APFS-user guards, native password verification and a resumable, password-free receipt. The account form is the penultimate screen; successful creation leads to the final Startup Disk handoff. If interrupted after enrollment but before account creation finishes, reopening Step 2 resumes the form. Older repair receipts do not force a new account.

While authorization is pending, the final Restart button opens Apple’s Recovery Startup Disk application. The user selects the new OS and completes Apple’s authorization prompt there. With no authorization pending, Restart checks the selected default volume, the completed installation and its startup bundle, then the default volume again, and restarts directly; if another volume is the default, it opens Startup Disk instead of stopping with an error. Restart stays disabled while a restart is in progress. Once APFS reports the recorded account as a volume owner, subsequent enrollment uses that account and can complete its existing metadata finalization. The full new ordering and subsequent paired-Recovery login still require a fresh hardware test; creating an ordinary account is not proof of native ownership or a working Recovery login.

Account preparation now invokes the existing conditional finalizer before the Startup Disk handoff. A matching APFS credential must pass password verification before missing SecureToken metadata can be reconciled; the native record must finish saving without changing its UUID or password hash. Returning from Startup Disk or reopening Recovery resumes prepared and awaiting-ownership accounts. The UI reports authorization as pending until finalization and current ownership readback succeed.

The first-stage engine reads back the selected APFS volume group after `bless`. The macOS shutdown handoff also verifies that the target group remains selected. A successful process exit without the expected selection cannot complete the handoff.

The welcome screen retains a small text attribution without an Aurora logo. The Aurora banner and Kanagawa volume artwork are independent. AppKit owns the outer rounding with hidden title bar and standard window controls; Command-Q quits.

## Per-install firmware recovery baseline

The stager requires the actual finalized ESP `vendorfw/firmware.tar`, `vendorfw/firmware.cpio` and `vendorfw/manifest.txt`. It also retains `vendorfw/u-boot/asmedia/asm2214a-apple.bin` when present. These files are read from this installation’s ESP and stored in `Aurora/Recovery/InstallData/AuraPayloads` beside the signed app; they are never inserted into either app bundle. The original signature, hardened runtime and entitlements remain unchanged. All are nonempty, with 256 MiB limits for the archive files, 1 MiB for the manifest, and 16 MiB for the optional U-Boot firmware. Missing required inputs stop staging.

`aura recover` validates the baseline’s file names, sizes and SHA256 hashes, then restores Stage 2 and the retained firmware as one transaction. It backs up every existing destination before the first ESP write and records which files were absent. A failed write restores all attempted destinations, removing only new files that were originally absent. It continues rollback if one restoration fails and reports the retained backup location and affected file names. Files outside the explicit baseline are not copied or deleted.

Focused native tests cover checksum, empty-file and path rejection, optional firmware, successful restoration, failure after a partial replacement, restoration of missing-file state, backup failures before mutation, and incomplete rollback reporting.

## Review policy and interruption handling

The native GUI is selected only by the authenticated template's `recovery_gui: omarchy-native-v1` declaration. A common raw Stage 1 additionally needs `aurora_stage1: {kind: common-raw-v1, qualified_machines: {j700ap: [26.6.2]}}` with the actual qualified firmware versions; asset presence does not qualify another board or firmware. Optional Neo radio or Touch ID extraction becomes mandatory only for entries explicitly listed in `required_neo_peripherals` (`radio`, `touch-id`). Radio model files come from the authenticated pinned 25G83 input recipe, so the running macOS point release does not select a guessed PTX filename.

The recovery account remains an explicit part of the requested workflow. It belongs to the stub's System/Data group, and its native token and volume-owner checks must pass before independent authorization is offered. It is not an account on the user's existing macOS installation. The macOS helper exposes inspection and handoff only; account creation/finalization runs in verified paired Recovery. Enrollment uses `bputil -nc` for the target volume. Neo explicitly opts in to `-nca` for Aura custom boot arguments; both the GUI and shell authorization prompts disclose that this includes USB proxy mode. Existing macOS installations’ policies are not changed. The Neo target policy is an explicit owner requirement.

File snapshots preserve original bytes, absence, ownership, permissions and flags. UUID-bound records can remap the same selected files when Recovery assigns different mount names. Saved bytes are verified before the first restore write. Pre-enrollment failure restores files; an authorized LocalPolicy or enclave change is not undone by file recovery. After `kmutil` starts, a timeout may have occurred after enrollment: retain the matching Stage 2 and resume the exact recorded build rather than replacing it with an older bundle. Version metadata and the installed receipt are persisted before disabling autolaunch. The iSC `var` tree is replaced as a whole with a sibling rollback directory instead of merging stale metadata.

The macOS CI job builds the enrollment app, runs `Recovery/test-all.sh <output>`, verifies its bundle, and builds the preview variant. Run the same fixture script on macOS locally. It runs the existing pure fixtures plus file snapshots, directory-swap interruption checks and the injected installation phase runner. It never enrolls a boot object or creates a live account. Debug/release package and Recovery builds remain separate native validation gates.

The GUI clears password state on completion/dismissal and blanks the native password fields on Skip, Cancel and failures, and owned native command buffers are wiped before release. AppKit field editing and Swift String/Data copies cannot be guaranteed to have no allocator or framework copies; this is a bounded best-effort lifetime policy, not a claim of complete process-memory erasure.

An empty authorization password keeps its sheet open. Return and Tab move through the recovery account fields, and Return in the last one creates the account. Below the fields, one line says why Create Account is unavailable once something has been typed: a username outside the account rules, a password with line breaks, or a retyped password that differs (not while it is still a matching prefix). The account installer's own checks still decide what is accepted. Sheets grow to fit long messages, and a failure raised while another sheet closes stays dismissible.

## Installer Log

Window → Installer Log (Command-L) opens the log in a window of its own, beside the installer and any sheet, as the Installer Log of Apple's Install macOS app does; Command-L again closes it, and the menu item is checked while it is open. A failure's sheet offers Show Log. The window has a filter (Show Errors Only, Show Errors and Progress, Show All Logs; remembered), a search field that highlights matches, Save…, which writes the lines shown with full dates (saying so when the window has dropped older lines), and Save Full Log…, which writes every line of every attempt this session from their files, including an attempt that failed before it was saved with the installation. If the save panel can't be shown, both write beside the current attempt's file and log where. Lines are monospaced with time, source and message, errors in red; the view follows new lines unless you scroll up, and the footer names commands still running.

Each command logs its command line (the value after an account or credential flag withheld), its output as detail lines, and how it ended; a failure repeats its last three output lines as errors. Output split across reads, inside a CRLF or a multi-byte character, continues the line rather than repeating earlier ones. Every line is redacted before it is stored: the authorization password wherever it appears, anything after a credential-named key, bearer tokens, terminal escapes, control characters and invisible format characters. The window keeps the newest 5,000 lines of the session; each attempt's file keeps that attempt in full, one line per entry with its time, level and source, and is saved with the installation as before.

Preview builds write simulated lines for their checks and setup steps. `--render-log=DIRECTORY` (preview builds only) draws the window offscreen while a command runs and after a failure, at each filter level and with search, and shows no window.

## Waiting

Setup starts the environment check as soon as the window opens: Recovery, root, the configured target volume, its paired boot policy (`bputil -d -v`) and the owner who authorizes enrollment (a series of `diskutil` queries). Continue waits for that check. After it passes, Continue opens the password prompt at once and repeats the same check in the background while the password is typed. Install waits for that repeated check if it is still running; a different owner reopens the prompt for that owner, and a failure closes the prompt and shows the issue. Installation then repeats the check before its first write, as before. After any failure, Continue runs the check again before asking.

Whenever a step's primary button (Continue, Restore, Create Account or Restart) waits, it is disabled with a small spinner to its left, keeps its title, and does not move: the spinner's slot is always reserved, and mirrored so the button stays centred. VoiceOver announces what is being waited for. The password prompt shows the same spinner left of its buttons. Reading the firmware's Aura flags and installing the `aura` command run off the main thread after a passing launch check. Continue, Restore, Enable Debug and Enable Proxy wait for them, so a failure there is shown before setup or repair can start.

On Create Recovery Account, **Skip, Restart Now** restarts directly only after checking the completed installation, its startup bundle, and the selected default volume both before saving and immediately before restarting. A different default stops the action with Startup Disk guidance. It does not open Startup Disk, create an account, or mark ownership complete. The receipt records the deferral while keeping `recoveryAccountRequired` intact, so opening the installer in paired Recovery still offers account setup. Preview builds show a simulated restart alert.

A deferred receipt remains visible to the macOS installer’s Recovery handoff. That handoff re-enables the saved Recovery launch marker for the same configured target. Successful account ownership finalization clears the deferral. Copied iSC metadata files and directories are flushed before publication; all committed files, including newly created metadata, and their parents are flushed before the transaction is marked committed. Successful installation removes the iSC sibling backup only after the committed journal is durable. These are tested write-ordering guarantees, not a claim of physical power-loss qualification.

The recovery account deliberately remains the stub’s only admin account (uid 501); it must become a verified volume/machine owner to authorize future Linux boot changes independently. Its password is validated by macOS account creation and authentication, without an extra installer-specific length rule. This is an explicit owner requirement, not a completed maintainer approval.

Recovery app updates retain the external data directory. A previously installed app with embedded inputs is migrated once after checking the target UUIDs and every payload hash. The old signed bundle remains unchanged during migration and rollback; immutable app backups carry their target binding in an adjacent JSON record. Existing account state and journals under `Aurora/Recovery/State` are preserved.

Installation-specific data under `Aurora/Recovery/InstallData` is not code-signed. Its target identities, file inventory, sizes and hashes are checked separately; this preserves the previous stub-data trust level. The application bundle retains its original signature unchanged.
