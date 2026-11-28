#!/bin/bash
# Builds the libFuzzer harnesses for the installer's untrusted-input readers on
# Linux. Run inside the swift:6.2 image (see README.md); output goes to $1.
set -euo pipefail

fuzz=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$fuzz")
out=${1:?usage: build.sh <output-dir> [target...]}
shift
mkdir -p "$out/shims" "$out/gen"
targets=("$@")
if ((${#targets[@]} == 0)); then
  targets=()
  for harness in "$fuzz"/Harness/*.swift; do
    targets+=("$(basename "$harness" .swift)")
  done
fi

flags=(-O -g -parse-as-library -swift-version 6 -sanitize=fuzzer,address
  -Xcc -I"$fuzz/Shims/zlib" -I "$out/shims" -module-cache-path "$out/module-cache")

# Shim modules: one Swift module per Darwin-only framework the sources import.
for shim in Darwin CryptoKit CommonCrypto Compression RecoveryAccountCore; do
  [[ "$out/shims/lib$shim.a" -nt "$fuzz/Shims/$shim/$shim.swift" ]] && continue
  swiftc "${flags[@]}" -emit-module -emit-library -static -module-name "$shim" \
    -emit-module-path "$out/shims/$shim.swiftmodule" -o "$out/shims/lib$shim.a" \
    "$fuzz/Shims/$shim/$shim.swift"
done

# The product identity the installer target gets from its build plugin.
if [[ ! -f "$out/gen/InstallerBuildConfiguration.swift" ]]; then
  swiftc -O -module-cache-path "$out/module-cache" -o "$out/identity-generator" \
    "$root/Sources/AuroraInstallerIdentityGenerator/main.swift"
  "$out/identity-generator" "$root/Packaging/identity.conf" \
    "$out/gen/InstallerBuildConfiguration.swift"
fi

# The AuroraFirmware module, compiled as is from Sources/ with testing enabled,
# plus the fuzz-only support files. Each harness imports it with @testable to
# reach the internal readers the way the unit tests do.
firmware=("$root"/Sources/AuroraFirmware/*.swift "$fuzz"/Support/*.swift)
stamp="$out/shims/libAuroraFirmware.a"
if [[ ! -f "$stamp" ]] || [[ -n "$(find "${firmware[@]}" -newer "$stamp")" ]]; then
  swiftc "${flags[@]}" -enable-testing -emit-module -emit-library -static \
    -module-name AuroraFirmware -emit-module-path "$out/shims/AuroraFirmware.swiftmodule" \
    -o "$stamp" "${firmware[@]}"
fi

for target in "${targets[@]}"; do
  extra=()
  if [[ -f "$fuzz/Harness/$target.sources" ]]; then
    while read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      source="$root/$line"
      if head -1 "$source" | grep -q '^#if os(macOS)$'; then
        # A macOS-gated installer file: drop only the outer gate.
        generated="$out/gen/$target-$(basename "$source")"
        sed '1d;$d' "$source" >"$generated"
        source=$generated
      fi
      extra+=("$source")
    done <"$fuzz/Harness/$target.sources"
    extra+=("$out/gen/InstallerBuildConfiguration.swift")
  fi
  swiftc "${flags[@]}" -module-name "Fuzz_$target" -o "$out/$target" \
    "$fuzz/Harness/$target.swift" "$fuzz"/Common/*.swift "${extra[@]}" \
    -L "$out/shims" -lAuroraFirmware -lDarwin -lCryptoKit -lCommonCrypto -lCompression -lRecoveryAccountCore -lz
done
