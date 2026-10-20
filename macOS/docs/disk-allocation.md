# Disk allocation

Native inspection returns display geometry beside its authenticated inventory. Both come from one collected physical disk snapshot. Display geometry is not added to inventory or plan digests and grants no execution authority.

The allocation page accounts for the entire physical disk: the booted macOS container, other allocated storage, usable unallocated extents, and the proposed Aurora allocation. Other storage includes other APFS containers, non-APFS partitions, system partitions, GPT space and gaps too small to allocate. Extra volumes inside one APFS container share its physical store and are not added again.

For a macOS resize, the proposed allocation is subtracted from that container. For another container's resize, it is subtracted from other allocated storage while macOS keeps its size. For a free extent, both allocated totals stay fixed and only unallocated space decreases. The page names the selected source and renders an Other segment. Native inspection must supply physical geometry before the live environment prepares a plan.

The existing authenticated candidate bounds and live admission checks remain authoritative. Rendered storage totals are descriptive; moving the divider cannot authorize a disk operation.

Debug visual fixtures are `--preview-screen=allocation`, `--preview-screen=allocation-free` and `--preview-screen=allocation-other`. They create no installer environment or disk activity. Fixtures and unit tests cover multiple containers, shared APFS volumes, system partitions, usable gaps and all three allocation sources.

Size checks use one session-owned preparation task at a time. A new committed size cancels the current read-only task, replaces the pending draft, and starts only after the previous task finishes its cleanup. Progress, success and failure from superseded generations are ignored. Beginning an edit also cancels an older check so a late result cannot reset the field or drag.

The controls remain usable during checking. Cancel check leaves the chosen draft visible and disables Install until Check size succeeds. Cancelling initial release preparation returns to Welcome. Approval is invalidated at once; the live environment independently verifies generation ownership before publishing its retained plan. These actions never cancel a helper-owned installation or Recovery operation.

Detached host probes forward cancellation. Read-only commands drain both output streams concurrently, retain bounded output, use a 120-second query deadline and terminate only their owned process on cancellation or timeout. Native inspection retains its separate mount-cleanup path, which finishes before a queued size check starts.

The `allocation-checking` visual fixture shows responsive sizing controls and the cancellation action. Regression tests include an intentionally cancellation-ignoring worker, late success and failure, latest-size queuing, approval invalidation, initial cancellation, output pressure and process termination.
