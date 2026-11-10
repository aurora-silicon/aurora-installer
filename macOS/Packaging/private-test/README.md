# Private packaging helpers

These helpers build ad-hoc review/test packages and verify exact app/helper code identities. They are also exercised by the packaging fixtures. They do not install or register the helper when building a package.

- `code-identity.sh` verifies private build profiles and derives code requirements.
- `render-identity.sh` fills identity placeholders from `Packaging/identity.conf`.
- `build-adhoc-app.sh` builds an app from explicit release inputs.
- `build-review-pkg.sh` and `build-tester-pkg.sh` assemble the corresponding private packages.
- `scripts/` contains package preinstall/postinstall checks; `Preflight.command` checks a private tester's host.

For current native installation testing, use the [local payload workflow](../../docs/private-local-payload-install.md). For normal developer packaging, see [Packaging](../README.md).
