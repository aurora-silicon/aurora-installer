# aurora-whole-disk

The Linux half of removing macOS so Aurora gets the whole internal disk. The deletion itself runs in the installation's paired Recovery (`aura remove-macos`), after its recovery account is proven to be a working owner. Design: [macOS/docs/whole-disk.md](../../macOS/docs/whole-disk.md).

```sh
sudo aurora-whole-disk plan                 # dry run: what Recovery would delete and keep
sudo aurora-whole-disk claim --dry-run      # after the removal: what Linux would add
sudo aurora-whole-disk claim                # add the freed space to the btrfs root
```

Two boot units do the work after Recovery removed macOS. `aurora-whole-disk-move.service` runs `move --yes` before any local file system is mounted: it copies the startup container, the EFI partition and /boot, one at a time, to the low end of the space macOS had and points their GPT entries there (same GPT UUID, type, name and attributes). `aurora-whole-disk-claim.service` runs `claim --yes` after the mounts when Recovery's record (`aurora/whole-disk/removed.json` on the EFI partition) exists: it moves the btrfs root onto a new partition in the space now in front of it, removes the old root's entry, gives the new one the old one's GPT UUID, name and end, and grows the file system. The result is the normal layout with one root partition: iSC, startup container, EFI partition, /boot, root, System Recovery. If `move` didn't run or refused (the space isn't directly before the startup container, other partitions in between, the root named by PARTUUID, PARTLABEL or kernel name, the root data doesn't fit, a partition in use, a copy that doesn't match), `claim` adds the space as a second btrfs device instead. Both pick up where a restart stopped them.

It decides from the disk (GPT types, APFS volume roles and groups read with `apfs_ro.py`, read-only) and from the device tree the firmware hands over (`chosen/apfs-preboot-uuid`, `chosen/asahi,efi-system-partition`). `plan` and `--dry-run` write nothing. `move` writes partition contents only into free space and changes the GPT only after the copy and its sha256 check (it edits the GPT itself, keeping every other byte of every entry, and checks both copies); `claim` writes the GPT, clears old signatures on the new partition only, and runs `btrfs device add` (and `device remove`, `filesystem resize` after a move). Both refuse a non-btrfs root and a root on dm-crypt; then the space stays free.

Install: `make install DESTDIR=... PREFIX=/usr` (tool, `apfs_ro.py`, both units; enable both to use them). Tests: `make check` (unprivileged) and `sudo make image-test DIR=<scratch> MODE=<mode>` (loop devices, 15 GB sparse image; modes `fresh`, `interrupted`, `v2`, `v2-interrupted`, `v2-refuse`, `v2-j473`, `v2-remove-fails`; `v2-j473` needs a 251 GB sparse file).
