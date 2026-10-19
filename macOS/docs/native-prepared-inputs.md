# Native prepared inputs

The privileged helper prepares Recovery and the Neo's model-wide firmware before launching disk installation. Paths and signing requirements come from the helper, never from GUI request fields.

- The GUI supplies a bounded flat container of its signed Recovery template. The root importer checks size and digest, reconstructs regular files, verifies the helper's signing policy, and durably publishes a template for later account and shutdown operations. The original authenticated source-owner identity is checked before mutation and again when staging.
- Neo firmware uses the compile-embedded, authenticated J700 range recipe through `AuroraFirmware`. A private namespace per recipe retains verified HTTP ranges across interruption. Published outputs are validated again by the extractor on reuse. Other boards keep their existing preparation path until a native recipe is qualified for them.
- The engine consumes those prepared model files for radios and camera. Factory radio calibration, Bluetooth address and ALS calibration remain specific to the running Mac. Radio, camera and ALS validation occurs before partition changes, and the admitted bytes are reused during firmware packaging.
- The runtime advertises `helper-template-v1` and `helper-raw-v1`. An incompatible engine fails before execution rather than silently ignoring native inputs.

An initial, terminal failure with a helper-attested absence of disk changes may clear only its matching GUI lookup hint and allow a newly reviewed plan. Recovery retries, interrupted workers and failures after mutation retain their original context. A Recovery authorization retry reuses the original package and does not restart firmware downloads.

Account preparation and shutdown handoff send the authenticated app's current flat Recovery container with the existing target ticket. After revalidating that target, the helper verifies the container against its own current signature policy and durably refreshes the retained template under the same job gate as the target update. Installing a newer app can therefore update Recovery without a new disk plan or replaying installation. Inspection and finalization reject unexpected template inputs; a missing or invalid update cannot replace the retained copy.

The disk-installation backend still uses the existing engine adapter. Native country-policy generation, the remaining firmware collectors and the full Swift disk backend remain unfinished. Existing signed policy inputs are validated during preflight; missing policy is not bypassed. Fresh-install and Recovery hardware qualification remains separate from native component tests.
