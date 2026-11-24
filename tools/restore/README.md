# aurora-restore

Puts macOS back on an Apple silicon Mac from a running Aurora system: pick a version, and Apple's own installer installs it from Recovery. The reverse of [aurora-whole-disk](../whole-disk/README.md).

```sh
aurora-restore list                       # versions Apple offers for this Mac
sudo aurora-restore plan 27.2.1           # dry run: every change, in Aurora and in Recovery
sudo aurora-restore apply 27.2.1          # prepare it (typed confirmation)
sudo aurora-restore plan 27.2.1 --replace # give macOS Aurora's Linux space instead
sudo aurora-restore cancel                # remove a prepared request
aurora-restore dfu-help                   # restore from a second computer (erases everything)
```

## Why it works this way

A Mac starts only a macOS that Apple's installer set up. The installer creates the APFS volume group, has Apple's signing server personalize the boot files for this Mac, and asks a machine owner to approve the new startup policy, which the Secure Enclave then signs. Linux can't do any of that. So the work is split:

- **In Aurora** the tool reads this Mac's board from the device tree (the first `compatible` entry, `apple,<target-type>`). It looks up that board in each full installer's `supportedDeviceIDs` in Apple's Software Update catalog, and checks the installer's own BuildManifest on Apple's server with a few range requests (about 9 MB). It then plans the disk and writes `aurora/restore/request.json` and a generated `restore.sh` to Aurora's EFI partition. In the default `alongside` mode it first shrinks the btrfs root online (file system, then partition) to leave a free gap before Apple's System Recovery. If the disk already has a large enough gap, nothing is shrunk.
- **In Recovery** (hold the power button, Options, Terminal) the user runs the one line `apply` prints. `restore.sh` has every value written in. It checks each partition is where the plan put it, the partition count and the network, and stops with no change if anything differs. It asks for the confirmation phrase again, and with `--replace` it deletes exactly the listed Linux partitions. It then creates the APFS container (`diskutil addPartition`), downloads `InstallAssistant.pkg` from Apple (resumable, size checked), installs it with `installer` (Apple's signature check) and starts the installer app. `restore.sh --check` runs only the checks. Every value from the disk or Apple's catalog that goes into `restore.sh` is refused if it holds a control character and is written single-quoted (numbers and identifiers must match a strict pattern), so a volume name or title can't add commands.

`restore.sh` is an unsigned script that Recovery runs as root from Aurora's EFI partition: its trust rests on nobody else having write access to that partition.

The tool never writes APFS, the startup security policy, NVRAM or the boot loader. `list`, `plan` and `apply --dry-run` write nothing.

Space: the installer package size twice (package and installed app) plus 35 GB for macOS, about 66 GiB for 27.2.1. With `--replace`, Aurora's small startup container stays until macOS is installed, because its recovery account is the owner that approves the new macOS. Remove it afterwards from macOS with Aurora Installer.

It refuses: a board Apple's catalog doesn't list for the version; an older build than the newest of its major (Apple usually won't personalize those) unless `--older` is given; a root that isn't a single plain btrfs partition followed by System Recovery (`alongside`); a shrink that would leave Linux under its used size plus 10 GiB; and a Mac with no macOS and no recovery account, where nobody can approve a new macOS. In that last case it points to `dfu-help`.

## Development

`make check` (unprivileged; needs `sfdisk` and `unshare` for the Recovery-script tests, which run `restore.sh` in a user and mount namespace against stand-ins for `diskutil`, `curl` and `installer`). `sudo make image-test DIR=<scratch> LOGS=<dir>` runs the real `plan`/`apply`/`cancel`/`apply --replace` on a loop device with 4096-byte sectors, synthetic Apple containers and a 100 GiB sparse btrfs root. It reads Apple's catalog, so it needs the network.

`make install DESTDIR=... PREFIX=/usr` installs the tool with `apple_remote.py` (range reads: HTTP, xar, UDIF, GPT, HFS+), WHOLE-DISK's disk rules (`aurora_whole_disk.py`) and `apfs_ro.py`. Runtime: Python 3, util-linux (`sfdisk`, `partx`, `findmnt`, `lsblk`, `blockdev`), btrfs-progs.
