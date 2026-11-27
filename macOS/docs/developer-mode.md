# Developer mode

Developer mode shows options that regular users never need. Press **Command-D** in the installer window (or choose **Installation > Developer Mode**) to turn it on. Press Command-D again, or click **Turn Off** on the badge at the top of the window, to turn it off.

## What it shows

| Option | Regular | Developer mode |
| --- | --- | --- |
| Release channels | Stable, Nightly | Stable, Release candidate, Nightly, Edge |
| Edge as the launch default where the Mac is family-qualified (#176) | no | yes |
| Aurora, based on Debian testing (until its signed catalog is live) | hidden | shown |
| macOS stub override (Installation > macOS Stub) | hidden | shown when the policy knows more than one stub for this Mac |

## Rules

- It is a key chord in the window, not a key held at launch. Holding Command-D while opening the app from the Finder would duplicate the app instead.
- It lasts for this launch only and is never saved. Every launch starts in the regular mode.
- It can be turned on or off while choosing a system or reviewing a plan, never while an installation or removal runs.
- Turning it on changes nothing on screen; it only adds choices.
- Turning it off drops a developer-only channel, distribution or stub, and the plan on screen starts again with the regular defaults. An existing Edge installation is still reset or updated from Edge; the channel menu keeps showing the channel in use.
- The Installer Log records each change ("Developer mode is on." / "Developer mode is off.").
- It only chooses among channels and profiles already signed into the app. It never adds a source the app wasn't built to trust.

## macOS stub override

The default stub is the one the sealed firmware policy chooses for this Mac. Developer mode's **Installation > macOS Stub** menu lists every stub the policy knows for this Mac (`NativeStubOverride.candidates`, filled into `DeveloperMode.shared.stubOverrideCandidates` when Developer mode turns on; the menu is hidden when there are fewer than two). `DeveloperMode.shared.stubOverride` is the pick, always `nil` outside Developer mode. Picking one starts the plan again.

`--stub-version VERSION-OR-BUILD` (or `--stub-version=...`) on the command line sets the same override and works whether or not Developer mode is on. It wins over the menu. There is no environment variable.

How it flows:

1. `LiveInstallerEnvironment` resolves the request against this Mac's policy entries (`NativeStubOverride.resolve`). A build matches exactly; a version must name one entry. Anything else is refused on the plan ("This macOS stub can't be used on this Mac") with the known choices.
2. Inspection sizes the stub it installs, and the staging estimate and plan use `NativeFirmwareSelection.choose(..., stubOverride:)`, which only considers that one entry and still applies the release's `supported_fw` and the entry's boot firmware, macOS and Recovery minimums (the same messages as the default).
3. The handoff's `request.json` carries `stub_override` (`version`, `build`) for a fresh installation only; the helper refuses it on any other operation and every helper stage chooses with it against its own sealed policy. Pins, digests and signatures are checked as always.
4. The plan shows one caution line and the Installer Log records it once: `macOS stub override: 26.6 (25G72) instead of the default 26.6.2 (25G83); this combination is untested`. Naming the default stub is the same as no override.

Reset and Update Boot Loader never use an override.
