# Native firmware library

The cryptographic, sparse-range, decompression and file-verification implementation was adopted from `Engine/RestoreImage/Sources/RestoreImageCore` at Aurora installer commit `6dca86b6faf5a5387b09d6df1aad887266837bc6`. That MIT implementation credits Eryk Wieliczko’s `macos-firmware-extract`. The authenticated interoperability vectors and transport rejection fixtures retain their original bytes.

This library removes the decoder-process and full-image fallback paths. Its Swift API admits a sealed model/build recipe, publishes typed measured-range progress, checks output storage, and verifies previously published firmware before reuse. It does not launch Python or other executables. The current recipe covers J700 model-wide files from Apple’s 25G83 restore image. Per-machine calibration and complete installation orchestration remain separate work.

The original engine and CLI sources remain intact for the currently qualified installer and rollback. Remove that legacy copy when the native engine replaces every production path; it is not a second production implementation to maintain indefinitely. Current installer releases still use the old engine until that migration is qualified.
