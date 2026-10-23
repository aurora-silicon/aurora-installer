#!/bin/bash
set -euo pipefail
root=$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)
output="$root/../Tests/RestoreImageCoreTests/Fixtures"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
git clone --quiet https://github.com/erykwieliczko/macos-firmware-extract.git "$stage/reference"
git -C "$stage/reference" checkout --quiet --detach 71b413af680edec1808a709cb7addfbde5c21cfc
cp "$root"/*_test.go "$stage/reference/"
(cd "$stage/reference" && \
  SWIFT_VECTOR_PATH="$output/go-vectors.json" SWIFT_AEA_PATH="$output/go-aea.json" go test ./...)
