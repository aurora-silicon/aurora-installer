# Installer engine

The engine is this repository’s installer backend: the pinned Asahi installer, our Python integration, a bundled Python runtime and the Swift restore-image helper. The SwiftUI app invokes it. The Linux image and the native Recovery GUI are separate payloads.

The backend source, patches, helper source/binary and build recipes are tracked here. Its generated `installer-*.tar.gz` archive lives in `Engine/artifacts/` and is bundled at `Contents/Resources/Engine/artifacts/` in the app.

Produce the exact archive named by the app and source lock:

```sh
python3 Engine/prepare-engine.py --output Engine/artifacts
```

An existing clean Asahi checkout can be supplied with `--checkout PATH`. Otherwise the producer fetches the locked source and submodules. It downloads and verifies the published `.28` runtime base, checks source/helper identities, normalizes PAX timestamps across Python versions, performs two independent repacks, and requires their bytes, size, digest and modes to match the reviewed archive pin. Cached runtime bytes are verified on every use.

App-release CI uses that same producer and uploads the result as its engine build artifact. A current engine release asset is not a prerequisite for building the app. Publishing an installation catalog and its downloadable assets remains a release operation.

The `.28` base preserves the original authenticated runtime: all 78 Mach-O files and the bootloader match the older `.14` base byte-for-byte. The locked Python patch and current integration replace its older installer logic. This avoids relying on the historical preview download URL.

When the Swift helper changes, run its native debug/release tests and `Engine/RestoreImage/build.sh`, update its tracked binary/build record and source identity, then reproduce a new engine version and refresh the archive pins. The producer rejects a stale helper or archive.

The authenticated `.28` runtime is also retained independently in the Aurora Silicon release mirror. The producer tries the primary asset, then the mirror, and requires exactly the same size and SHA-256 from either. The engine `.50` archive is available in that mirror, but the release pipeline deliberately names the canonical omacom URL. A maintainer must make those exact bytes available there before catalog publication; the source/app builds do not require that publication. Release assets are runtime inputs, not replacement source trees.

Source revisions are repository-qualified: the integration revision belongs to `aurora-silicon/omarchy-mac`, as does `restore_image_source.repository` in the source lock. Preserve the fork source tags `engine-v0.9.2-omarchy.50` and `restore-image-source-7115941` when merging or squashing this PR; a squash does not change their immutable source identities. A future release revision should name the merged source commit and must reproduce its pinned engine before publication.
