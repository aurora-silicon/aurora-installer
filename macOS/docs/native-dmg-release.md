# Native installer DMG

`.github/workflows/native-installer-dmg.yml` builds the native application on a hosted ARM Mac and attaches a signed, notarized DMG to a **draft** GitHub release. Dispatch it on the intended installer branch with `profiles-revision` set to an immutable `aurora-silicon/aurora-distributions` commit and a numeric marketing `version`.

The nine signed profile catalogs must name the exact runtime version, digest, filename and size in this source's engine lock. The workflow refuses an older catalog set before building. Catalog signatures are verified against the installer's retained trust root during release preparation. App inspection and planning remain native; unfinished installation execution work is not made complete by packaging.

The workflow runs the portable checks, strict Swift lint and native debug/release tests, builds Recovery and the app, and imports the existing Developer ID certificate into an isolated temporary keychain. The notarization API key is stored in that keychain and its temporary file is deleted before submission. The enclosing signing wrapper restores the original keychain search list and deletes the temporary keychain on success or failure. Only the DMG and build evidence are uploaded.

`Packaging/make-download-dmg.sh` requires a notarized, stapled app with matching release-team signatures. The app must be at most 32 MiB and contain no bundled execution runtime or OS artifacts. Packaging reserves 10 GiB free, copies the app with its icon and ticket, adds the Applications shortcut, signs and notarizes the compressed image, staples its ticket, verifies the image and runs Gatekeeper assessment. Existing output files are never replaced. This follows [the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The repository secrets are `APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, `APPLE_NOTARY_KEY_BASE64`, `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_ISSUER_ID`. The workflow never promotes its draft to a public release. Physical installation, update, reboot and hardware qualification must be recorded before public release approval.

Current boundary: the scripts and workflow need an actual macOS DMG/notarization run after the matching catalog set is prepared. Source checks and signing authentication probes do not prove that deliverable exists.
