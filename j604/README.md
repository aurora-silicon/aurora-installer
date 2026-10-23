# J604 Fedora installer

This directory is the complete standalone installer repository content. It can
be distributed separately from the private hardware kit. No private patches,
credentials, target firmware or operating system images are bundled here.
All hardware patches and image-building logic are fetched from the pinned
private kit after GitHub sign-in. This public launcher contains neither.

On a J604 / Mac16,1 running Apple Silicon macOS:

```sh
bash build.sh
bash dist/j604-installer/install.sh
```

Or run `bash install.sh` directly. GNOME is the default; use `--desktop kde`
for Plasma. Use `--build-only` to prepare the installable image without opening
the disk installer, then `--install-only` to install the verified output.

For a fresh end-to-end rehearsal, run `bash install.sh --fresh`. It removes only
this launcher's cached private checkout, its build outputs and its matching
disposable VM, then fetches and builds again. It preserves GitHub sign-in,
shared tools, other VMs and personal files, and refuses to erase local source
edits. It does not remove any installed OS or select disk partitions for you.

The command downloads a checksum-pinned GitHub CLI if needed, opens GitHub's
device sign-in flow if you are not signed in, checks access to the private
`shirty445/j604-remix` repository, and fetches its pinned revision. An existing
GitHub CLI login is reused. GitHub manages credentials; this installer never
requests or prints your token and never passes one into the build VM.

It then prepares an isolated Fedora build VM, fetches and verifies pinned
sources, applies the J604 kernel, Aura and all eight U-Boot patches, and compiles
those components and their matching userspace drivers. It downloads a pinned
Fedora Asahi Remix image and customizes that existing filesystem with the
compiled components. It does not build Fedora from an empty filesystem.

Source trees, downloads and compiled objects are retained between attempts.
Rerun the same command after a network interruption. Allow at least 70 GiB free
for the build. Expect a substantial first build; this is not just an image copy.

All preparation runs before requesting administrator authentication for Aurora's
interactive disk installer. You select the disk space and size yourself and
complete Apple's Recovery boot-policy step by following the on-screen
instructions. Building a valid image does not establish hardware boot success.
This remains an experimental J604 installation.

Before disk installation, successful output verification triggers deletion of
this installer's build VM (including source trees and compiler outputs), its
base-image downloads and its local Lima tools. The final image, boot artifacts
and installer runtime are retained for installation and retrying `--install-only`.
`--build-only` retains build inputs until installation is requested. Shared tools,
other VMs and personal files are outside the cleanup scope.

Inside Linux, use `sudo j604-update` for normal Fedora updates. It checks the
J604 files and update protections before and after the transaction. Packages
that own replaced hardware files, generic kernels and bootloaders are excluded
from ordinary DNF updates and protected against removal. The boot updater also
checks integrity before rebuilding the boot chain. This deliberately holds back
hardware-related packages, including their fixes; moving them forward requires
a tested J604 kit release. Administrative overrides such as `rpm --force`,
disabling DNF exclusions, or a distribution upgrade can bypass these protections.

To validate the distributed launcher without signing in or changing disks:

```sh
bash install.sh --check
```
