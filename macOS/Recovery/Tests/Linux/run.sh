#!/bin/bash
# Tests/RestoreImageKeyCheck.swift, the aurora-restore-key command line
# (Tests/RestoreImageKeyTool.sh), Tests/RestoreImageMemberCheck.swift and the
# restore image plan, archive and stub file checks on Linux, where neither
# CommonCrypto, Security.framework nor libcompression exists: this directory's
# shim puts the CommonCrypto calls and the ECDH on libcrypto 3,
# RestoreImageKeyAgreement.swift here stands in for
# Sources/RestoreImageKeyAgreement.swift, and lzfse/ (go-compressions/lzfse,
# built on the host with Go from its module cache, offline) for libcompression's
# LZFSE. Without Go, the shim's stand-in reads and writes stored LZFSE blocks
# only, and the archives that need a real decoder are skipped and counted.
# Everything else is the shipped source.
#
#   Tests/Linux/run.sh                 # runs in docker swift:6.2, no network
#   Tests/Linux/run.sh --in-container  # inside a Swift 6 toolchain with libcrypto.so.3
set -euo pipefail
recovery="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ ${1:-} != --in-container ]]; then
  lzfse="$(mktemp -d)"
  trap 'rm -rf "$lzfse"' EXIT
  if command -v go >/dev/null &&
    GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=1 go -C "$recovery/Tests/Linux/lzfse" build \
      -buildmode=c-archive -o "$lzfse/lzfse.a" . 2>"$lzfse/go.log"; then
    echo "LZFSE: go-compressions/lzfse"
  else
    echo "LZFSE: stand-in (stored blocks only; no Go or no go-compressions/lzfse in the module cache)"
  fi
  # Mount the whole macOS/ tree: the checks also read ../RestoreImage fixtures.
  docker run --rm --network none -v "$recovery/..:/src:ro" -v "$lzfse:/lzfse:ro" \
    -w /src/Recovery swift:6.2 bash Tests/Linux/run.sh --in-container
  exit
fi
cd "$recovery"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
lzfse=()
if [[ -f /lzfse/lzfse.a ]]; then
  clang -c -O1 -Wall -Wextra -Werror -DAURORA_LZFSE_GO Tests/Linux/shim.c -o "$build/shim.o"
  lzfse=(/lzfse/lzfse.a -Xlinker -lpthread)
else
  clang -c -O1 -Wall -Wextra -Werror Tests/Linux/shim.c -o "$build/shim.o"
  export AURORA_TEST_LZFSE=none
fi
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
archive=(Sources/Account/RecoveryDigest.swift Sources/RestoreImageKey.swift
  Tests/Linux/RestoreImageKeyAgreement.swift
  Sources/RestoreImageMember.swift Sources/RestoreImageDirectory.swift
  Sources/RestoreImageStream.swift Sources/RestoreImageArchive.swift
  Sources/RestoreImageResourceFork.swift)
swiftc -parse-as-library -I Tests/Linux -I Compression/include "${archive[@]}" \
  Sources/RestoreImageStubPlan.swift Sources/RestoreImageStubFiles.swift \
  Tests/RestoreImageArchiveCheck.swift "$build/shim.o" "${lzfse[@]}" \
  -Xlinker -l:libcrypto.so.3 -o "$build/restore-image-archive"
"$build/restore-image-archive"
swiftc -parse-as-library -I Tests/Linux -I Compression/include "${archive[@]}" \
  Sources/RestoreImageStubPlan.swift Sources/RestoreImageStubFiles.swift \
  Tests/RestoreImageStubFilesCheck.swift "$build/shim.o" "${lzfse[@]}" \
  -Xlinker -l:libcrypto.so.3 -o "$build/restore-image-stub-files"
"$build/restore-image-stub-files"
# The in-place startup firmware upgrade: the request and its checks, the
# network reader and archive keys (no network: a fake transport), and the
# in-place writer on a fake existing stub. RecoveryFileTransaction gets BSD
# file flags from DarwinFlags.swift.
upgrade=("${archive[@]}" Sources/RestoreImageStubPlan.swift Sources/RestoreImageStubFiles.swift
  Sources/RestoreImageRemote.swift Sources/StubUpgradeRequest.swift Sources/StubUpgradeCheck.swift
  Sources/RestoreImageStubUpgrade.swift Sources/RecoveryDirectorySwap.swift
  Sources/Account/RecoveryFileTransaction.swift Sources/Account/AuraStage1.swift
  Sources/RecoveryOwner.swift Tests/Linux/DarwinFlags.swift)
for check in StubUpgradeRequestCheck RestoreImageRemoteCheck RestoreImageStubUpgradeCheck; do
  swiftc -parse-as-library -I Tests/Linux -I Compression/include "${upgrade[@]}" \
    "Tests/$check.swift" "$build/shim.o" "${lzfse[@]}" \
    -Xlinker -l:libcrypto.so.3 -o "$build/$check"
  "$build/$check"
done
