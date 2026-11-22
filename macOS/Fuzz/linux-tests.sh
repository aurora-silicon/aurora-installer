#!/bin/bash
# Runs AuroraFirmware XCTest files on Linux against the same shims as the
# harnesses, built with AddressSanitizer and without fuzzer instrumentation.
#   linux-tests.sh <output-dir> <Tests/...Tests.swift> [test-name...]
# With test names, only those run; otherwise every `func test...` in the file.
# Tests that compare digests, MACs or Apple-decoded bytes cannot pass against
# the shims, so run only the ones that do not depend on them.
set -euo pipefail
fuzz=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$fuzz")
out=${1:?usage: linux-tests.sh <output-dir> <test-file> [test-name...]}/tests
file=$root/${2:?missing test file}
shift 2
mkdir -p "$out/shims"
flags=(-Onone -g -swift-version 6 -sanitize=address -Xcc -I"$fuzz/Shims/zlib"
  -I "$out/shims" -module-cache-path "$out/module-cache")
for shim in Darwin CryptoKit CommonCrypto Compression; do
  [[ "$out/shims/lib$shim.a" -nt "$fuzz/Shims/$shim/$shim.swift" ]] && continue
  swiftc "${flags[@]}" -parse-as-library -emit-module -emit-library -static -module-name "$shim" \
    -emit-module-path "$out/shims/$shim.swiftmodule" -o "$out/shims/lib$shim.a" \
    "$fuzz/Shims/$shim/$shim.swift"
done
# Always rebuilt, so a before/after comparison sees the current sources.
swiftc "${flags[@]}" -parse-as-library -enable-testing -emit-module -emit-library -static \
  -module-name AuroraFirmware -emit-module-path "$out/shims/AuroraFirmware.swiftmodule" \
  -o "$out/shims/libAuroraFirmware.a" "$root"/Sources/AuroraFirmware/*.swift "$fuzz"/Support/*.swift

class=$(grep -m1 -oE 'final class [A-Za-z0-9_]+: XCTestCase' "$file" | awk '{print $3}' | tr -d :)
names=("$@")
if ((${#names[@]} == 0)); then
  mapfile -t names < <(grep -oE '^  func test[A-Za-z0-9_]+\(\)' "$file" | sed 's/  func //; s/()//')
fi
{
  echo "import XCTest"
  echo "@testable import AuroraFirmware"
  # SwiftPM's resource accessor, for files that name their fixtures.
  echo "extension Foundation.Bundle {"
  echo "  static let module = Bundle(path: \"$(dirname "$file")\")!"
  echo "}"
  echo "extension $class {"
  echo "  nonisolated(unsafe) static let linuxTests: [(String, ($class) -> () throws -> Void)] = ["
  for name in "${names[@]}"; do
    if grep -qE "^  func $name\(\) async" "$file"; then
      echo "    (\"$name\", asyncTest($name)),"
    else
      echo "    (\"$name\", $name),"
    fi
  done
  echo "  ]"
  echo "}"
  echo "XCTMain([testCase($class.linuxTests)])"
} >"$out/main.swift"
swiftc "${flags[@]}" -module-name LinuxTests -o "$out/$class" "$file" "$out/main.swift" \
  -L "$out/shims" -lAuroraFirmware -lDarwin -lCryptoKit -lCommonCrypto -lCompression -lz
# XCTMain exits without releasing its own bookkeeping, which LeakSanitizer
# would report as a failure of a run whose tests all passed.
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0} SWIFT_BACKTRACE=enable=no "$out/$class"
