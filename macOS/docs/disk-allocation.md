# Disk allocation

Native inspection returns display geometry beside its authenticated inventory. Both come from one collected physical disk snapshot. Display geometry is not added to inventory or plan digests and grants no execution authority.

The allocation page accounts for the entire physical disk: the booted macOS container, other allocated storage, usable unallocated extents, and the proposed Aurora allocation. Other storage includes other APFS containers, non-APFS partitions, system partitions, GPT space and gaps too small to allocate. Extra volumes inside one APFS container share its physical store and are not added again.

For a macOS resize, the proposed allocation is subtracted from that container. For another container's resize, it is subtracted from other allocated storage while macOS keeps its size. For a free extent, both allocated totals stay fixed and only unallocated space decreases. The page names the selected source and renders an Other segment. Native inspection must supply physical geometry before the live environment prepares a plan.

The existing authenticated candidate bounds and live admission checks remain authoritative. Rendered storage totals are descriptive; moving the divider cannot authorize a disk operation.

Debug visual fixtures are `--preview-screen=allocation`, `--preview-screen=allocation-free` and `--preview-screen=allocation-other`. They create no installer environment or disk activity. Fixtures and unit tests cover multiple containers, shared APFS volumes, system partitions, usable gaps and all three allocation sources.

Read-only checks still need serialized cancellation with latest-draft ownership. This accounting change does not claim to implement that interaction.
