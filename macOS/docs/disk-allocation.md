# Disk allocation

Native inspection returns display geometry beside its authenticated inventory. Both come from one collected physical disk snapshot. Display geometry is not added to inventory or plan digests and grants no execution authority.

The allocation bar accounts for the entire physical disk: the booted macOS container, other allocated storage, usable unallocated extents, and the proposed Aurora allocation. Other storage includes other APFS containers, non-APFS partitions, system partitions, GPT space and gaps too small to allocate. Extra volumes inside one APFS container share its physical store and are not added again. The page is flat, with no enclosing card or metadata captions. A pencil beside the Aurora size opens a compact prompt for exact size entry; minimum/maximum bounds and validation appear only in that prompt.

For a macOS resize, the proposed allocation is subtracted from that container. For another container's resize, it is subtracted from other allocated storage while macOS keeps its size. For a free extent, both allocated totals stay fixed and only unallocated space decreases. The page names the selected source and renders an Other segment. Native inspection must supply physical geometry before the live environment prepares a plan.

A chosen free extent is fixed: the recommendation's minimum, maximum and requested size are all the whole aligned extent, and the page shows no pencil and no draggable divider. It shows the breakdown read-only, with a line saying Aurora uses all of the free space and macOS keeps its size. Only a resize has a size to choose.

## Erase on the Partitions screen

Every row except macOS offers Erase: Aurora installations, other installers' Linux, lone startup containers and EFI or Linux partitions, partitions with other file systems, and APFS containers without a system. Erase deletes exactly the row's partitions and leaves their extent unallocated. macOS is never resized, so the freed extent, joined with the free space on either side, is offered next as a free-space target.

`NativePartitionErase` is the one rule for what may go, applied by the screen and again by the helper to its own scan:

- Never Apple's system container or Recovery partition, nor the running macOS. Apple's partitions are recognized by position too: the first partition, the last, and anything before the running macOS.
- Never a container with a full system: a system volume with a `Library` folder, or an Update volume, as every macOS has. A VM volume says nothing, since a startup container may keep one. A container `diskutil apfs list` doesn't list is refused too. Another macOS is never offered.
- Never an EFI partition that the bootloader of a startup container that stays still names. Inspection records each startup container's chainloaded EFI partitions from its `boot.bin`; a boot object that can't be read is unknown, not an inspection failure, and while any kept startup container's is unknown no EFI partition is erased. The row says which container to erase first or with it.

The helper's erase review (`AuroraRemovalPlan(erasing:)`) lists every partition it deletes, with type and volumes, and the merged free extent it leaves. The app shows the ticket only when it names exactly the row's partitions. Execution keeps the removal journal model:

- the private journal is written before each deletion;
- the layout must equal the approved one minus what was already removed at every step;
- the row and the erase rule are checked again before the first deletion;
- containers are deleted first, with no force unmount;
- an interrupted erase blocks all later disk changes until reviewed.

Before the first record, the row's mounted volumes are unmounted without force. A volume in use refuses, naming it; whenever execution stops before a record, what was unmounted is mounted again, and a volume that didn't mount again is named. If a deletion fails and a fresh scan shows the disk as reviewed minus what was already removed, the record ends `stopped`, which doesn't block later work: a fresh review plans what is left. Any other outcome keeps the record for review.

macOS is set as the startup disk first only when the row holds the startup disk or a one-time startup choice, or either can't be told and the row has a container. An erase ticket runs only as the erase it was reviewed for. Only the installer journals whose planned extent overlaps the erased space are moved aside; other installations keep theirs. Returning space to macOS still moves them all aside, as before.

The existing authenticated candidate bounds and live admission checks remain authoritative. Rendered storage totals are descriptive; moving the divider cannot authorize a disk operation.

Debug visual fixtures are `--preview-screen=allocation`, `--preview-screen=allocation-free`, `--preview-screen=allocation-other` and `--preview-screen=allocation-editing`. `--preview-compact` uses the minimum window height. They create no installer environment or disk activity. Fixtures and unit tests cover multiple containers, shared APFS volumes, system partitions, usable gaps and all three allocation sources.

Size checks use one session-owned preparation task at a time. A new committed size cancels the current read-only task, replaces the pending draft, and starts only after the previous task finishes its cleanup. Progress, success and failure from superseded generations are ignored. Beginning an edit also cancels an older check so a late result cannot reset the field or drag.

The controls remain usable during checking. Stop checking leaves the chosen draft visible and disables Install until Check size succeeds. Cancelling initial release preparation returns to Welcome. Approval is invalidated at once; the live environment independently verifies generation ownership before publishing its retained plan. These actions never cancel a helper-owned installation or Recovery operation.

Prefetch cancellation reserves a new generation without file I/O. An owned background retirement chain joins prior startup, cancels and joins its writer, and removes only captured private work directories. Successor startup and live host/release space checks await retirement; cancelled startup and stale file promotion are refused. Interactive cancellation returns immediately, while the explicit quit path drains retirement before allowing process exit.

Detached host probes forward cancellation. Read-only commands drain both output streams concurrently, retain bounded output, use a 120-second query deadline and terminate only their owned process on cancellation or timeout. Native inspection retains its separate mount-cleanup path, which finishes before a queued size check starts.

The `allocation-checking` visual fixture shows responsive sizing controls and the cancellation action. Regression tests include an intentionally cancellation-ignoring worker, late success and failure, latest-size queuing, approval invalidation, initial cancellation, output pressure and process termination.

Installer pages do not scroll. Activity and error details open bounded prompts with a full Copy action. The removal sheet uses explicit review steps, with a page for each deletion, retained item and note before the final confirmation and credentials. The destructive action is unavailable on earlier pages.
