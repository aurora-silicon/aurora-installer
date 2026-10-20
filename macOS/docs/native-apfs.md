# Native APFS preparation

Fresh free-space and resize installations prepare the APFS stub in Swift. Replacement and repair retain their existing execution paths. Stub contents, ESP/Linux partition population and remaining firmware collection still use the authenticated backend; the native installation backend remains unfinished.

Before disk work, the helper verifies Recovery resources and the source volume owner, admits the payload and boot objects, converts Neo firmware inputs, and opens the selected restore archive through bounded HTTP ranges. It requires `nativeAPFSInput: helper-target-v1` from the authenticated execution bundle before entering the native mutation callback.

The native stage reuses the importer's exact request/identity schemas and bindings. It reconstructs the approved plan from fresh internal-disk/APFS facts, current allocation minimums and the selected firmware size. Ordinary free-space changes may update the safety minimum without changing the layout digest; the allocation must still fit. The original owner proof is checked again at the mutation boundary and retained privately for later attempts. Recovery-incompatible volume names are refused before intent.

A durable `apfs_preparation_started` precedes fixed `diskutil` resize/create commands addressed through freshly checked BSD/UUID identities. Resize results must have the requested size. The free extent must start at the approved offset and contain the complete allocation. Creation must add exactly one correctly sized APFS store and a new container while preserving unrelated partitions and containers. No whole-disk formatting fallback is admitted.

The exact target BSD identifier, UUID, offset and size are published durably before `apfs-target-prepared`. An interrupted initial header may be completed only when its saved bytes match the freshly reconstructed approved header. An intent without a checkpoint is ambiguous and never replayed automatically. A completed checkpoint resumes by checking the exact live target and original source owner, without another resize or create command.

The backend receives the checkpoint and original bootstrap identity, checks both in preflight, and rereads the target before stub writes. Its own APFS preparation entry point refuses a native target. A backend launch failure retains the package, journal and evidence and makes no unchanged-disk claim. Recovery handoff still requires both completed disk stages.

Command-recording fixtures cover free/resize execution, fresh minimums, changed identities/results, unrelated partitions, interrupted headers, ambiguous intents, checkpoints, owner changes, capability rejection and post-preparation launch failures. Physical resize/create, new-volume permissions, stub population and installation/reboot qualification remain required.
