# Private installs from local payloads

Use this only for a clean-install acceptance test with unpublished payloads. The installer still verifies the sealed catalog signatures against its retained trust root, applies catalog admission and rollback checks, and checks the exact signed size and SHA-256 of both the payload and metadata. Local files cannot add a model, change an install plan, or replace a catalog. Normal ownership, helper, disk and boot-policy authorization remains required.

## Build the test DMG

1. In **Actions → Build native installer prerelease**, select the installer branch containing this feature.
2. Set `profiles-revision` to the full 40-character commit SHA from `aurora-silicon/aurora-distributions` containing the nine signed `site/installer/Profiles` catalogs. aurora-distributions signs catalogs only on `main` (its `catalog-signing` environment admits no other branch), so an unmerged branch carries only catalogs the key holder signed and committed there. The workflow reads that exact revision and verifies the signatures; it does not sign catalogs or download payloads.
3. Set `version` and `release-tag` to the values already pinned by those catalogs. The tag is only a catalog consistency check for this run; it does not need to exist on GitHub.
4. Set **test-local-payloads = true** and **publish-release = false**. The workflow rejects the combination of a local-source test build and publication, and the publication job independently excludes test builds.
5. Download the **test-local-payload-installer-dmg** CI artifact. It contains `Aurora-Installer-<version>-local-test.dmg`. Evidence, including the sealed profile manifest and compiled-source policy check, is in **native-dmg-evidence**. Artifacts expire after 14 days. This workflow mode creates no GitHub release.

The test app is Developer ID signed and notarized using the existing isolated CI signing workflow. It is a developer build with sealed catalogs and a debug-configuration binary optimized for packaging. Its Recovery template and helper keep their normal signature and authorization requirements. Do not distribute this test artifact as a public installer.

## Seed the cache on the target Mac's macOS

Copy the complete payload zip and metadata artifact for the intended profile onto the target Mac's macOS volume. Use the exact `payloadArtifact.fileName` and `metadataArtifact.fileName` from that profile's sealed catalog in the mounted application's `Contents/Resources/Release/Profiles/<profile>/catalog.json`. You can inspect the JSON with `plutil -p`. Obtain the files from the same distribution build that produced the signed catalogs; an arbitrary replacement will fail verification.

The fixed cache layout is:

```text
/Users/Shared/AuroraInstallerTestPayloads/
  <payload SHA-256 as 64 lowercase hex characters>/<payloadArtifact.fileName>
  <metadata SHA-256 as 64 lowercase hex characters>/<metadataArtifact.fileName>
```

Seed it in Terminal, replacing the two example source paths with the actual files, preserving their catalog filenames:

```sh
for file in /path/to/payload.zip /path/to/installer_data.json; do
  digest=$(shasum -a 256 "$file" | awk '{print $1}')
  directory="/Users/Shared/AuroraInstallerTestPayloads/$digest"
  mkdir -p "$directory"
  cp "$file" "$directory/$(basename "$file")"
done
```

The directory name does not confer trust: the installer independently hashes the source and staged copy and checks their size against the authenticated catalog. Different profiles can coexist because each artifact is addressed by digest. Files must be regular files, not symlinks. For catalogs with multipart download records, supply the complete assembled zip under the whole payload's signed filename and digest, not the individual `.part` files. The whole-file check is the same one used after downloaded parts are assembled.

## Run the install

Mount the test DMG, copy **Aurora Installer.app** to Applications and run it. Choose the profile whose payload and metadata you seeded, then follow the normal clean-install flow and owner authorization prompts. The app copies and verifies the local files into its private staging area before the normal handoff. It leaves the operator's cache files intact. Missing or corrupt local files fail the test install without falling back to the unpublished download URL. A fully verified file already in private staging can be reused after the same verification.

Keep the ordinary macOS staging and handoff free-space allowance in addition to space for the cache. Local payload staging does not wait for network availability; other install inputs, such as Apple's restore image, may still need network access. This is not a fully offline installation mode.

After the test, remove the test app and cache when they are no longer needed. Record physical installation and reboot evidence separately from CI; passing source tests does not prove installation on hardware.

## Release exclusion and CI

`AURORA_LOCAL_PAYLOAD_TEST_BUILD=1` is read by the Swift package manifest at build time only. It defines `AURORA_LOCAL_PAYLOAD_TEST_BUILD` only for debug configuration, and the policy additionally requires `DEBUG`. Default debug builds have the feature off. Every release-configuration build ignores the local source even with the build environment variable set. The installed app reads no environment variable, defaults key, command-line option or file to enable it. Existing `AuroraDeveloperBuild` and offline-bundle settings cannot enable this source in a release binary.

Native checks run release tests with the opt-in set, proving a populated local source is ignored, and run focused opted-in debug tests proving local verification and failure behavior. Packaging checks the exact app and helper executables for the compiled cache-path marker: release DMG builds require it absent; test DMG builds require it in the app. The test workflow also records this check before notarization and DMG creation.
