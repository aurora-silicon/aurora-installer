# Developer mode

Developer mode shows options that regular users never need. Press **Command-D** in the installer window (or choose **Installation > Developer Mode**) to turn it on. Press Command-D again, or click **Turn Off** on the badge at the top of the window, to turn it off.

## What it shows

| Option | Regular | Developer mode |
| --- | --- | --- |
| Release channels | Stable, Nightly | Stable, Release candidate, Nightly, Edge |
| Edge as the launch default where the Mac is family-qualified (#176) | no | yes |
| Aurora, based on Debian testing (until its signed catalog is live) | hidden | shown |
| macOS stub override (Installation > macOS Stub) | hidden | shown once the engine offers choices for this Mac |

## Rules

- It is a key chord in the window, not a key held at launch. Holding Command-D while opening the app from the Finder would duplicate the app instead.
- It lasts for this launch only and is never saved. Every launch starts in the regular mode.
- It can be turned on or off while choosing a system or reviewing a plan, never while an installation or removal runs.
- Turning it on changes nothing on screen; it only adds choices.
- Turning it off drops a developer-only channel, distribution or stub, and the plan on screen starts again with the regular defaults. An existing Edge installation is still reset or updated from Edge; the channel menu keeps showing the channel in use.
- The Installer Log records each change ("Developer mode is on." / "Developer mode is off.").
- It only chooses among channels and profiles already signed into the app. It never adds a source the app wasn't built to trust.

## Stub override hook

`DeveloperMode.shared.stubOverrideCandidates` is the list of stubs the engine offers for this Mac (empty today, so the menu shows nothing). `DeveloperMode.shared.stubOverride` is the developer's pick, and is always `nil` outside Developer mode. The engine owns which stubs are offered, refuses any it doesn't know, and logs a warning that the stub is untested.
