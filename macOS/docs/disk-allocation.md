# Disk allocation

Native inspection returns display geometry beside its authenticated inventory. Both come from one collected physical disk snapshot. Display geometry is not added to inventory or plan digests and grants no execution authority.

The allocation bar accounts for the entire physical disk: the booted macOS container, other allocated storage, usable unallocated extents, and the proposed Aurora allocation. Other storage includes other APFS containers, non-APFS partitions, system partitions, GPT space and gaps too small to allocate. Extra volumes inside one APFS container share its physical store and are not added again. The page is flat, with no enclosing card or metadata captions. A pencil beside the Aurora size opens a compact prompt for exact size entry; minimum/maximum bounds and validation appear only in that prompt.

For a macOS resize, the proposed allocation is subtracted from that container. For another container's resize, it is subtracted from other allocated storage while macOS keeps its size. For a free extent, both allocated totals stay fixed and only unallocated space decreases. The page names the selected source and renders an Other segment. Native inspection must supply physical geometry before the live environment prepares a plan.

The existing authenticated candidate bounds and live admission checks remain authoritative. Rendered storage totals are descriptive; moving the divider cannot authorize a disk operation.

Debug visual fixtures are `--preview-screen=allocation`, `--preview-screen=allocation-free`, `--preview-screen=allocation-other` and `--preview-screen=allocation-editing`. `--preview-compact` uses the minimum window height. They create no installer environment or disk activity. Fixtures and unit tests cover multiple containers, shared APFS volumes, system partitions, usable gaps and all three allocation sources.

Size checks use one session-owned preparation task at a time. A new committed size cancels the current read-only task, replaces the pending draft, and starts only after the previous task finishes its cleanup. Progress, success and failure from superseded generations are ignored. Beginning an edit also cancels an older check so a late result cannot reset the field or drag.

The controls remain usable during checking. Cancel check leaves the chosen draft visible and disables Install until Check size succeeds. Cancelling initial release preparation returns to Welcome. Approval is invalidated at once; the live environment independently verifies generation ownership before publishing its retained plan. These actions never cancel a helper-owned installation or Recovery operation.

Prefetch cancellation reserves a new generation without file I/O. An owned background retirement chain joins prior startup, cancels and joins its writer, and removes only captured private work directories. Successor startup and live host/release space checks await retirement; cancelled startup and stale file promotion are refused. Interactive cancellation returns immediately, while the explicit quit path drains retirement before allowing process exit.

Detached host probes forward cancellation. Read-only commands drain both output streams concurrently, retain bounded output, use a 120-second query deadline and terminate only their owned process on cancellation or timeout. Native inspection retains its separate mount-cleanup path, which finishes before a queued size check starts.

The `allocation-checking` visual fixture shows responsive sizing controls and the cancellation action. Regression tests include an intentionally cancellation-ignoring worker, late success and failure, latest-size queuing, approval invalidation, initial cancellation, output pressure and process termination.

Installer pages do not scroll. Activity and error details open bounded prompts with a full Copy details action. The removal sheet uses explicit review steps, with a page for each deletion, retained item and note before the final confirmation and credentials. The destructive action is unavailable on earlier pages.
