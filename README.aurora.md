# Aurora installer

Installs **Windows on Apple Silicon** Macs, starting from macOS. It is a fork of
the [Asahi Linux installer](https://github.com/AsahiLinux/asahi-installer)
(MIT, © 2021 The Asahi Linux contributors — see `LICENSE`, which is unchanged),
because the hard parts of putting a second OS on these machines are identical
whichever OS it is: carving partitions out of a live APFS disk, building a boot
stub, lowering the boot policy, and extracting device firmware from macOS.

Upstream's own `README.md` is kept as-is and still describes those mechanics.

## What this fork adds

Asahi installs one Linux partition. Windows needs more:

1. **Multiple partitions** — ESP + MSR + Windows, laid out as Mu expects, rather
   than a single Linux root.
2. **A staged Windows image on the SSD.** The installer places the install media
   on an SSD partition instead of a RAM disk. Measured on J813: the machine has
   16 GiB of RAM and `install.wim` alone is 7.07 GB, so a RAM-disk installer has
   no headroom. Staging to the SSD also runs at native speed rather than the
   ~6 MiB/s the m1n1 proxy manages.
3. **Driver injection.** `AppleNvme` must be in the *installed* image and must be
   built `mode=internal-boot` (service `Start=0`) plus a CriticalDeviceDatabase
   entry, or Windows cannot read its own boot volume and bugchecks
   `0x7B INACCESSIBLE_BOOT_DEVICE`. `AppleMtpHid` (keyboard/trackpad) is not
   boot-critical but needs its files, service and firmware present.
4. **Test-signing.** Both drivers carry the WDK OEM test chain, so the installed
   BCD needs testsigning enabled — not just WinPE's.

## Where Windows comes from

Microsoft publishes ARM64 ISOs at
<https://www.microsoft.com/en-us/software-download/windows11arm64>, so the
installer downloads Windows directly and never redistributes it.

**It cannot pin a URL.** That page requires selecting an edition and language,
which mints a per-session link that the page states expires *"24 hours from time
of creation."* So unlike upstream — which pins its own images in a release
manifest — this installer has to drive the selection flow at install time and
verify the result by **checksum**, not by URL. Expect that flow to need
maintenance whenever Microsoft changes the page.

## Firmware

Upstream's `asahi_firmware` already extracts what we need from macOS:
`multitouch.py` (trackpad), `wifi.py`, `bluetooth.py`. J813's wireless is Apple
"centauri", not Broadcom.

## Status

Early. The driver side is proven on J813 hardware — the Windows `AppleNvme`
driver reads and writes the internal SSD, verified with a GPT read off LBA 1 and
a full write/verify/restore round trip — but this installer does not yet carve
partitions or stage an image.

## Native Linux installer

The `macOS/` subtree adds the independent Aurora Linux GUI: Fedora Aurora Remix,
Aurora ALARM and Aurora NixOS, with KDE Plasma, GNOME and shell profiles.
Its signed profile contract, developer packaging, distribution producers and
qualification limits are documented in [macOS/README.md](macOS/README.md). The existing
Windows command-line installer above is preserved.

The [Fedora producer](fedora/README.md) prepares pinned KIWI descriptions with
Aurora package selections for KDE, GNOME and minimal. Distribution-specific packages, image production and physical installation tests are tracked in the distro repositories.
