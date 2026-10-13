# Private Limine installer qualification

This branch starts from frozen private plain app `ccf85c00db633a18f2d2776f1ea087ce14c6fc8e`. It preserves Chris's existing bundle and source worktree. The new `OmarchyPrivateLimineTest` signed bundle flag separates private state/channel isolation from the old plain-only capability. It allows the existing explicit Linux encryption choice, hides the release-channel menu, displays Limine in completion, and uses `~/Library/Application Support/com.omarchy.mx.installer.private-limine-20260922`. `OmarchyPrivatePlainTest=true` keeps its prior restriction and workspace; conflicting flags are rejected by packaging and retain the plain restriction at runtime. Standard builds retain their existing behavior.

The inspection/installation engine remains the exact `.17` archive, SHA-256 `ecb61645a9c75ba733425fb300b8b53b09f9dbc297a86acce1e0ee41f36e32e5`, 17,838,045 bytes. No engine rebuild, production key, public feed change or host-gate expansion is part of this profile. M4 remains a build host, never an installation target.

The app and helper still use the existing Mach-service/bundle identifiers. Each new ad-hoc bundle has its own exact code identity: the app pins its helper, the external daemon pins the newly sealed app, and postinstall pins both plus the daemon bytes. The encrypted-test package receipt identifier is `com.omarchy.mx.installer.private-limine-test.pkg`. Existing app/helper/system state is still refused before installation; this does not promise simultaneous installed coexistence with Chris's private app. No helper registration is needed for build or qualification.

## Required fresh inputs

Use a new isolated source/output/release directory on the M4, for example `/Users/scott/code/quattro-limine-app-validation-20260922/`. Never copy over `/Users/scott/code/quattro-catalog-validation/` or Chris's delivery directory. Populate the new source's `Engine/artifacts/` with the unchanged, hash-verified `.17` archive; this binary is intentionally untracked.

After the new ZIP exists and passes the archived `.17` full-OS contract check, prepare a new schema-4 private support catalog from its generated `installer_data.json`, product and ZIP. Keep the frozen engine pin; the inputs list every M1, M2 and M3 Mac in `scripts/supported-models.json` (the generator refuses an M3-only or other partial list); use a new evidence revision beginning `quattro-private-limine-`, the new metadata/payload filenames, exact sizes and SHA-256 hashes, and a fresh catalog sequence. The catalog schema is independent of the Linux candidate-package schema. Retain the existing private Ed25519 catalog signer on the M4; only public key/signature material belongs in the release directory. The package PGP qualification key is not the app catalog key.

Use `scripts/make-unsigned-catalog.py --base-url https://quattro-private-limine.invalid/assets --assets-dir NEW_ASSETS --inputs NEW_INPUTS.json --output NEW_RELEASE/catalog.json`, then the existing private catalog signing path and `scripts/catalog-signing.swift verify` on the M4. A sealed catalog supports verified local prestaging, so publication is unnecessary; `.invalid` URLs deliberately refuse missing downloads. Include `release.json` with distinct HTTPS channel URLs, the pinned private `trust-root.ed25519.pub`, `catalog.json` and `catalog.json.sig`. The private wrapper tightens the descriptor's initial ad-hoc helper requirement to the built helper's exact cdhash.

Before assembly, generate candidate-specific staging instructions and the assembly input receipt:

```bash
python3 Packaging/private-test/prepare-limine-assets.py --catalog NEW_RELEASE/catalog.json --product NEW_PRODUCT.json --assets-dir NEW_ASSETS --output-dir NEW_STAGING
cp NEW_STAGING/limine-inputs.json NEW_RELEASE/limine-inputs.json
```

This tool verifies all three whole-file catalog hashes/sizes, the frozen engine, the `linux-asahi` / `asahi-limine` product, matching metadata payload name, unique private evidence revision and shared assets across admitted models. It refuses stale plain revisions and unsafe names/symlinks. Its generated `Stage assets.command` uses only the new workspace and pins; ship the three public assets under sibling `limine-assets/`. It does not sign, upload, install or stage on the current host. App/package assembly rejects a changed catalog after this receipt is created. The original plain staging script and its pins remain unchanged.

## M4 build and verification

Run from the separately copied source, after supplying the fresh release inputs. Use a new output path; the wrapper refuses existing outputs. The following build number is a proposed new private iteration, not a modification of Chris's artifact:

```bash
xcrun swift-format format --in-place --recursive Sources Tests
xcrun swift-format lint --strict --recursive Sources Tests
xcrun swift test --filter 'InstallerBuildProfileTests|InstallerSessionTests|InstallerReleaseConfigurationTests|InstallConf'
xcrun swift test --configuration release --filter 'InstallerBuildProfileTests|InstallerSessionTests|InstallerReleaseConfigurationTests|InstallConf'
OMARCHY_PRIVATE_LIMINE_TEST=1 OMARCHY_APP_BUILD_NUMBER=25 bash Packaging/private-test/build-adhoc-app.sh /Users/scott/code/quattro-limine-app-validation-20260922/release /Users/scott/code/quattro-limine-app-validation-20260922/app-build-25
bash Packaging/private-test/build-tester-pkg.sh '/Users/scott/code/quattro-limine-app-validation-20260922/app-build-25/Omarchy MX Mac Installer.app' /Users/scott/code/quattro-limine-app-validation-20260922/Omarchy-M3-Limine-Private-25.pkg
bash test/macos-private-package.sh '/Users/scott/code/quattro-limine-app-validation-20260922/app-build-25/Omarchy MX Mac Installer.app' /Users/scott/code/quattro-limine-app-validation-20260922/Omarchy-M3-Limine-Private-25.pkg
```

Apply any formatting changes back to this branch and freeze a new commit before claiming an immutable build. The test entrypoints do not register the helper or mutate a disk. The real sealed-catalog trust path must additionally admit the selected M3 model and reject changed bytes/wrong signatures; the profile UI needs a separate visual check showing the encryption toggle, no channel menu, and Limine completion. Respect the single-review-instance rule. Package layout/code-signature/XPC tests, source tests and image contract checks are not proof of a physical encrypted installation.

The existing private package preflight/postinstall safety checks and M3 hardware list remain unchanged. Run the portable `./test/all` before remote assembly; macOS Swift compilation, debug/release tests, signing/package checks and visual verification remain separate evidence. No installer package is ready for sharing merely because source tests pass.
