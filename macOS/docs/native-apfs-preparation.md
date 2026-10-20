# Native APFS preparation

Fresh installations prepare the physical store and its complete stub volume group in Swift. The backend continues at file population. Replacement and repair keep their existing execution contracts.

`NativeAPFSExecution` authenticates the imported plan, opens the selected restore archive, rechecks the source owner and live disk geometry, then records `apfs_preparation_started` before any mutation. It creates the target physical store and calls `NativeStubVolumes` before publishing `apfs-target-prepared`.

Volume creation converts the newly created roleless volume to Data, renames it, creates its paired System volume, and creates Preboot and Recovery only when absent. Every command revalidates the target physical-store identity and the volume UUID-to-BSD mapping. Every observed mutation must match its requested graph delta, with all unrelated storage unchanged. A diskutil mount error is accepted only when the exact requested volume creation demonstrably completed.

The protected `native-stub-volumes` evidence sidecar binds the plan digest, physical-store UUID, container UUID, label, and complete volume graph. Exactly one System and Data volume must share a nonzero group UUID. Exactly one Preboot and Recovery volume are required; an existing VM volume is preserved. The APFS checkpoint is written only after this evidence is durable. An interrupted APFS intent remains ambiguous and cannot automatically replay. A completed transaction revalidates the evidence and live volume graph without creating volumes again.

The authenticated runtime must advertise `nativeStubInput: helper-volumes-v1`. The helper supplies `OMARCHY_NATIVE_STUB_VOLUMES=helper-volumes-v1` only with native APFS preparation. The backend reads the protected sidecar, checks the live container, volume names, roles, UUIDs and volume-group membership, skips `prepare_volume`, and verifies the discovery result before `install_files`. BSD identifiers may change between attempts; continuation resolves current identifiers through the recorded UUIDs.

This stage does not yet replace backend stub-file copying, firmware packaging, or ESP and Linux partition population. Native source tests and CI results are separate from physical installation qualification.
