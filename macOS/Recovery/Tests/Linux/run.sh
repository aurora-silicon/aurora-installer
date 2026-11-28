#!/bin/bash
# Tests/RestoreImageKeyCheck.swift, the aurora-restore-key command line
# (Tests/RestoreImageKeyTool.sh) and Tests/RestoreImageMemberCheck.swift on
# Linux, where neither CommonCrypto nor
# Security.framework exists: this directory's shim puts the CommonCrypto calls
# and the ECDH on libcrypto 3, and RestoreImageKeyAgreement.swift here stands in
# for Sources/RestoreImageKeyAgreement.swift. Everything else is the shipped source.
#
#   Tests/Linux/run.sh                 # runs in docker swift:6.2, no network
#   Tests/Linux/run.sh --in-container  # inside a Swift 6 toolchain with libcrypto.so.3
set -euo pipefail
recovery="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ ${1:-} != --in-container ]]; then
  # Mount the whole macOS/ tree: the check also reads ../RestoreImage fixtures.
  exec docker run --rm --network none -v "$recovery/..:/src:ro" -w /src/Recovery swift:6.2 \
    bash Tests/Linux/run.sh --in-container
fi
cd "$recovery"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
clang -c -O1 -Wall -Wextra -Werror Tests/Linux/shim.c -o "$build/shim.o"
swiftc -parse-as-library -I Tests/Linux Sources/RestoreImageKey.swift \
  Tests/Linux/RestoreImageKeyAgreement.swift Tests/RestoreImageKeyCheck.swift "$build/shim.o" \
  -Xlinker -l:libcrypto.so.3 -o "$build/restore-image-key"
"$build/restore-image-key"
swiftc -parse-as-library -I Tests/Linux Sources/RestoreImageKey.swift \
  Tests/Linux/RestoreImageKeyAgreement.swift Sources/RestoreImageMember.swift \
  Tools/RestoreImageKeyTool.swift "$build/shim.o" \
  -Xlinker -l:libcrypto.so.3 -o "$build/aurora-restore-key"
Tests/RestoreImageKeyTool.sh "$build/aurora-restore-key"
swiftc -parse-as-library Sources/RestoreImageMember.swift Tests/RestoreImageMemberCheck.swift \
  -o "$build/restore-image-member"
"$build/restore-image-member"
swiftc -parse-as-library -I Tests/Linux Sources/Account/RecoveryDigest.swift \
  Sources/RestoreImageMember.swift Sources/RestoreImageDirectory.swift \
  Sources/RestoreImageStubPlan.swift Tests/RestoreImageStubPlanCheck.swift "$build/shim.o" \
  -Xlinker -l:libcrypto.so.3 -o "$build/restore-image-stub-plan"
"$build/restore-image-stub-plan"
