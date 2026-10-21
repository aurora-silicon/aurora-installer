#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
flags=()
# CLT ships Swift Testing outside SwiftPM's framework/runtime search paths.
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
runtime="$(xcode-select -p)/Library/Developer/usr/lib"
if [[ -d "$frameworks/Testing.framework" ]]; then
  flags+=(-Xswiftc "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
  flags+=(-Xlinker -rpath -Xlinker "$runtime")
fi
exec swift test --package-path "$root" -j 8 "${flags[@]}" "$@"
