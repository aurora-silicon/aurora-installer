# Installer release inputs

Aurora uses an independent Ed25519 catalog key. Only its raw 32-byte public key belongs in this directory. Trusted publication workflows receive the private key through the protected `INSTALLER_CATALOG_SIGNING_KEY` secret. Keep local signing credentials outside repositories and release artifacts.

`release.json` names the Stable, RC and Edge catalog URLs, default channel, trust-root fingerprint and helper identity. Regenerate it with `scripts/make-release-descriptor` when those inputs change. `test/all` checks consistency with `Packaging/identity.conf`.

Fedora Aurora Remix, Aurora ALARM and Aurora NixOS each have KDE, GNOME and minimal profiles. The app loads the selected profile from `Release/Profiles/<profile>/`. Public catalogs, signatures and descriptors are published by [aurora-distributions](https://github.com/aurora-silicon/aurora-distributions). Edge carries development candidates; Stable and RC currently contain authenticated empty catalogs. Image assembly evidence and physical qualification are recorded separately.

Prepare packaging resources from a verified delivery checkout:

```sh
python3 scripts/prepare-distribution-release.py \
  --profiles /path/to/aurora-distributions/site/installer/Profiles \
  --output /path/to/release-inputs
```

This verifies all nine catalog signatures and profile bindings before emitting any resources. Normal builds include descriptors and public keys and fetch current signed catalogs at runtime. Add `--sealed` for an explicit developer or offline build: it includes the exact verified catalog bytes and records their sequences and digests in `profile-manifest.json`. Sealed catalogs take precedence over network feeds.

Then pass that release directory to `Packaging/build-app.sh`. Developer packages use `AURORA_DEVELOPER_BUILD=1`, a sealed catalog and the dedicated local developer package builder; they do not imply Developer ID signing or notarization.

Device firmware and per-machine calibration are collected on the target Mac and never included in public payloads or package feeds. Model admission is governed by the signed catalog and `scripts/supported-models.json`; models awaiting a first hardware boot carry an explicit caution.

Every catalog must use schema 5 and select the built-in `native-v1` engine. Older catalogs that pin a downloaded engine archive are rejected. App and catalog updates must agree on the installation profile, payload contract and artifact hashes. App assembly, signing/notarization and physical installation/Recovery qualification remain separate release gates.
