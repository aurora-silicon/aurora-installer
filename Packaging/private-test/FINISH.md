# Private M3 delivery

The user explicitly chose a private test without Developer ID signing or notarization. `README.md` contains the tester instructions, including macOS's per-item Open Anyway approval. Do not disable Gatekeeper or clear quarantine. Normal signed distribution can be added later using the existing production scripts and an authorized publisher's credentials.

Build the private app and package on an arm64 Mac with Xcode, using the same pinned engine and sealed public release inputs from the maintainer handoff:

```bash
OMARCHY_APP_BUILD_NUMBER=24 bash Packaging/private-test/build-adhoc-app.sh /absolute/release-inputs /absolute/new-app-directory
bash Packaging/private-test/build-tester-pkg.sh '/absolute/new-app-directory/Omarchy Installer.app' /absolute/new-package.pkg
bash test/macos-private-package.sh '/absolute/new-app-directory/Omarchy Installer.app' /absolute/new-package.pkg
```

These scripts do not install or register anything. `build-adhoc-app.sh` pins the helper's exact cdhash in the app, disables the embedded daemon path with `never`, and seals the app. `build-tester-pkg.sh` requires that profile, installs the helper under `/Library/PrivilegedHelperTools`, derives the exact app pin only after signing, and binds the entire daemon plist hash into postinstall. The generic and earlier review package builders do not provide this private delivery contract.

The native test checks package layout, exact payloads and authentication, rejects independently signed same-identifier impostors and changed resources, and exercises the same macOS XPC pin enforcement in an unprivileged ping-only fixture. A wrong listener-side client pin prevents handler invocation. A wrong client-side server pin rejects the ping reply with signing error 4102; the initial harmless ping may reach the server. The production coordinator requires a successful ping before submitting credentials or operations.

No actual root helper registration or downloaded-package Gatekeeper approval has been performed during preparation. Those are part of the first authorized physical test. The app's earlier simulation remains open on the M4 and was not terminated; the new private profile has not had a separate visual preview. Its plain-only session tests and release build passed; first-run instructions explicitly require checking the unencrypted-install notice.

The package refuses existing app/helper/state, an already registered service, macOS below 15 and hardware outside the eleven admitted M3 boards. The first Linux boot on the 16-inch M3 Pro remains unqualified. The image is unchanged from the tested 13-inch Air baseline: Asahi, GRUB, software rendering, no Linux encryption. Aurora and encryption/Limine integration are separate.

`Preflight.command` and `Stage assets.command` carry identity placeholders; write the copies that go into the tester folder with `bash Packaging/private-test/render-identity.sh SOURCE NEW_DEST`, which fills them from `Packaging/identity.conf`. Create the tester ZIP from the package, the three baseline assets, README.md, Feedback.md, Preflight.command, Stage assets.command, manifest.json and SHA256SUMS. Include no signing keys, credentials, source checkouts or old review packages. Verify the final archive and provide its checksum separately. Do not publish/upload on the user's behalf without their instruction.

## Separate Limine candidate

The encryption-capable private candidate uses the separately documented [Limine profile](../../docs/private-limine-packaging.md), `OMARCHY_PRIVATE_LIMINE_TEST=1`, a fresh sealed catalog/input receipt, and new outputs. It must not use this page's baseline staging pins, unencrypted instructions or Chris's existing bundle. The plain commands above retain their behavior.
