# Aurora native preview validation — 2026-10-13

This records the scope observed on Neo before the user returned it to Linux. It is evidence for the native UI and profile integration, not Fedora/ALARM image installation or a release package.

The native code starts from `aurora-silicon/omarchy-mac` revision `55c855ce3f8dbdbfc5393aa4d929352142a0d1dc`. The preview was compiled on physical Neo under macOS 26.6.2 (25G83), Apple Swift 6.4, with XcodeBuildMCP 2.7.0. The isolated build directory was `/Users/dj/Developer/aurora-installer-20261013/`.

| Check | Observed result |
| --- | --- |
| Shared installer and profile changes, native debug suite | 716 passed, 0 failed, 1 skipped |
| Shared installer and profile changes, native release suite | 702 passed, 0 failed, 1 skipped |
| Profile/catalog, channel and captured removal regression follow-up | 24 passed in debug and 24 in release |
| Final compact mockup preview (`preview12`) | Debug build passed; ad-hoc app signature verified by packager |
| Whole-card selection with real pointer clicks | GNOME, Minimal and KDE each reached review with the corresponding `Aurora Fedora Remix · <desktop>` label |
| Aurora Recovery template | Release build, strict configuration/baseline checks, signing and Springboard localized-name lookup passed |
| Portable engine checks | 41 passed |
| Portable engine-overlay checks | 307 ran; passed with 22 environment-dependent skips |
| Portable packaging/script Python checks | 44 passed |
| Portable branding and remaining packaging/publication fixtures | Passed |
| Complete portable runner | Does not pass the inherited production-identity check: this preview deliberately has no Developer ID team/signing identity configured |

The skipped Swift test requires a private M3 catalog fixture, which was not supplied. Tests initially caught stale identity/channel expectations after the Aurora rename; the expectations were updated and the relevant follow-up passed. Captured hardware fixtures retain their original Omarchy labels and bytes.

The large screenshots and two-screen selector were replaced after these full-suite runs. The final compact UI built successfully and its three desktop cards were tested through review using the explicit simulator. A final full-suite rerun was launched, but its terminal logs were not retrieved before the user rebooted into Linux. Its outcome is **unverified**; the earlier counts above must not be presented as results for that final rerun.

No new Fedora/ALARM/UEFI OS image or end-to-end disk installation was performed. Matching signed release profiles are required by the live adapter; no such Aurora payload catalogs are shipped here. The downloadable preview binary remains on Neo's macOS volume; this publication ships source and the reviewed screenshot, not an unverified final ZIP.

Local interaction evidence is preserved in `work/aurora-native-installer-20261013/selector-interaction.json` in the development workspace. The reviewed compact screenshot is checked into `Design/AuroraInstallerPreview.png`. The source's MIT attribution, engine source lock and historical fixture evidence remain preserved.
