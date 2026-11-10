# Native installer DMG

`.github/workflows/native-installer-dmg.yml` builds the native application on a hosted ARM Mac and uploads a signed, notarized DMG as a CI artifact. With `publish-release=true`, it can also publish a GitHub prerelease. Dispatch it on the intended installer branch with `profiles-revision` set to an immutable `aurora-silicon/aurora-distributions` commit and a numeric marketing `version`.

The nine signed schema-5 profile catalogs must select the built-in `native-v1` engine and match the intended installer release. The workflow refuses an older catalog set before building. Catalog signatures are verified against the installer's retained trust root during release preparation. The app and helper execute the native Swift engine; no engine archive or Python runtime is packaged.

The workflow runs the portable checks, strict Swift lint and native debug/release tests, builds Recovery and the app, and imports the existing Developer ID certificate into an isolated temporary keychain. The notarization API key is stored in that keychain and its temporary file is deleted before submission. The enclosing signing wrapper restores the original keychain search list and deletes the temporary keychain on success or failure. Only the DMG and build evidence are uploaded.

`Packaging/make-download-dmg.sh` requires a notarized, stapled app with matching release-team signatures. The app must be at most 32 MiB and contain no bundled execution runtime or OS artifacts. Packaging reserves 10 GiB free, copies the app with its icon and ticket, adds the Applications shortcut, signs and notarizes the compressed image, staples its ticket, verifies the image and runs Gatekeeper assessment. Existing output files are never replaced. This follows [the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The repository secrets are `APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, `APPLE_NOTARY_KEY_BASE64`, `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_ISSUER_ID`. For artifact-only builds, explicitly set `publish-release=false`. Physical installation, update, reboot and hardware qualification must be recorded before public release approval.

Record the actual DMG/notarization result for each candidate alongside its source and catalog revisions. Source checks and signing authentication probes alone do not qualify a deliverable.

For unpublished payloads, use the artifact-only [private local-payload test build](private-local-payload-install.md). Release-configuration binaries always exclude that local source.
