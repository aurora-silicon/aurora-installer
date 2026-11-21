# aurora-whole-disk

The Linux half of removing macOS so Aurora gets the whole internal disk. The deletion itself runs in the installation's paired Recovery (`aura remove-macos`), after its recovery account is proven to be a working owner. Design: [macOS/docs/whole-disk.md](../../macOS/docs/whole-disk.md).

```sh
sudo aurora-whole-disk plan                 # dry run: what Recovery would delete and keep
sudo aurora-whole-disk claim --dry-run      # after the removal: what Linux would add
sudo aurora-whole-disk claim                # add the freed space to the btrfs root
```

`aurora-whole-disk-claim.service` runs `claim --yes` at boot when Recovery's record (`aurora/whole-disk/removed.json` on the EFI partition) exists; otherwise it does nothing.

It decides from the disk (GPT types, APFS volume roles and groups read with `apfs_ro.py`, read-only) and from the device tree the firmware hands over (`chosen/apfs-preboot-uuid`, `chosen/asahi,efi-system-partition`). `plan` and `--dry-run` write nothing. `claim` writes the GPT (one new partition in the freed extent, checked to be free and to match Recovery's record), clears old signatures on that partition only, and runs `btrfs device add`. It refuses a non-btrfs root and a root on dm-crypt.

Install: `make install DESTDIR=... PREFIX=/usr` (tool, `apfs_ro.py`, unit). Tests: `make check` (unprivileged) and `sudo make image-test DIR=<scratch>` (loop devices, 15 GB sparse image).
