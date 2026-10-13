# Installer release inputs

Production packaging reads this directory and copies its contents into
`Omarchy Installer.app/Contents/Resources/Release/`:

- `release.json` — schema version 3 descriptor naming the stable, rc and edge
  channel catalog URLs, the default channel, the expected Ed25519 trust-root
  fingerprint, the helper Mach service name, and the helper code-signing
  requirement. Generate it with `scripts/make-release-descriptor`.
- `trust-root.ed25519.pub` — exactly 32 raw Ed25519 public-key bytes matching
  the descriptor fingerprint.

Both files are the same for every build. The trust root changes only when the
signing key is rotated; the descriptor also changes when the default channel
does. The private key lives in the operator's login keychain under the
service `omarchy-channel-signing-key` and must never appear here or anywhere
else on disk; see
[`docs/apple-silicon-distribution-channels.md`](https://github.com/maralcbr/omarchy-mx-mac/blob/92a9054f4565b37739ac3bd4f0fb4fcf8bd48625/docs/apple-silicon-distribution-channels.md).

The default channel is `edge`. The channels match Omarchy's (stable, rc, edge; dev is a developer choice made after installation), and today only edge has a Mac release. Stable and rc serve signed empty catalogs (`scripts/publish-channels empty-catalog`), which the app shows as "No Mac release yet", never as a channel it cannot reach or verify.

The catalog URLs sit under the release stream path (`INSTALLER_STREAM_PATH` in `Packaging/identity.conf`). The MX Mac installer's feeds at the root of the same host are a separate stream: this repository never publishes to, reads or prunes them, and the app keeps its accepted catalog sequences in stream-named state files so the two installers' rollback floors never meet.

The descriptor names every channel because the app is signed once: a channel absent from the descriptor
cannot be opened later without shipping another signed app.

The app rejects missing, symlinked, group- or world-writable, oversized,
unknown, or mismatched release inputs, and `build-app.sh` refuses a descriptor
whose schema, helper identity, fingerprint, or channel URLs do not match the
product it is building.

For a private or offline build the directory may also contain a signed
`catalog.json` and `catalog.json.sig` pair. The app then verifies that sealed
catalog with the same trust root instead of fetching a channel. Production
builds omit the pair so the app reads its channel at run time.

The helper identity, team and catalog host in `release.json` come from `Packaging/identity.conf`; `test/all` fails when the descriptor no longer matches it.
