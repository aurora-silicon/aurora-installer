# Refactor scope: installer

This branch is a placeholder with a survey. The installer is the last of the
four repos to touch, because everything it does is a consequence of decisions
the other three have not finished making.

## Where it stands

One commit on top of Asahi's tree: `6b1c8a5 aurora: fork asahi-installer as the
Aurora installer`, which is a README. `README.aurora.md` describes what the fork
needs to add. None of it is built.

`neo/j700-tethered` is nine commits ahead and is where the real work is: AEA
BaseSystem decryption for modern macOS images (`tools/aea-key.swift`, 179 lines),
keyless restore-bundle metadata, bounded whole-disk probes, packaging on modern
macOS hosts, and an expert-only MacBook Neo target. It also deletes
`README.aurora.md`. That branch should merge before anything else happens here.

## What it is blocked on

**A driver packaging contract.** The installer has to put drivers where Windows
Setup finds them, and `AppleNvme` has to be in the *installed* image built
`mode=internal-boot` with a CriticalDeviceDatabase entry, or Windows bugchecks
`0x7B INACCESSIBLE_BOOT_DEVICE` on its own boot volume. Today that packaging
lives in 11 hand-written `build-j414s-*-winpe.sh` scripts in the drivers repo,
totalling 1,927 lines, two of which have diverged by 341 lines. The installer
cannot consume that. It needs one artifact with a manifest, which is a drivers
repo change.

**A machine list that is not one machine.** Every layer is currently pinned to
J414s: mu has one working platform package, m1n1 gates its handoffs on an exact
board compatible string, the drivers repo names J414s in most of its tooling.
The installer's whole value is choosing the right thing for the Mac it is
running on, which needs mu's device-family work first. `Docs/FORK.md` in mu
covers what that costs.

**A boot artifact that is not hand-sealed.** m1n1's `build-windows-unified.py`
refused to run outside three hardcoded branch names and has been removed. mu's
`Tools/mu_profile_manifest.py` hardcodes `BRANCH = "main"` and is still there
only because auroradbg reads it from target config. Both should end up in
auroradbg producing one signed, versioned bundle the installer downloads. Right
now there is nothing for an installer to fetch.

## What it does not need

A rewrite of the parts inherited from Asahi. Carving partitions out of a live
APFS volume, building a boot stub, lowering boot policy, extracting firmware
from macOS — those are the hard parts and upstream already solved them for a
second OS in general, not for Linux in particular. `asahi_firmware` extracts
trackpad, WiFi and Bluetooth firmware and works as-is.

The fork should stay a thin layer: a different partition layout, a staged
Windows image on the SSD rather than a RAM disk (J813 has 16 GiB of RAM and
`install.wim` alone is 7.07 GB), driver injection, and test-signing in the
installed BCD.

## The one thing worth doing now

Windows ARM64 ISO URLs cannot be pinned. Microsoft's download page mints a
per-session link that expires 24 hours after creation, so unlike upstream, which
pins images in a release manifest, this installer has to drive the selection
flow at install time and verify by checksum. That flow will break whenever
Microsoft changes the page, and it is independent of everything above. It can be
written and tested today.
