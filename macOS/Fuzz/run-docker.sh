#!/bin/bash
# Runs a command in the swift:6.2 image with this worktree and the build
# directory mounted at their own paths, as the calling user.
set -euo pipefail
work=${FUZZ_WORK:?set FUZZ_WORK to a directory that holds the worktree and the build output}
cpus=${FUZZ_CPUS:-2}
exec docker run --rm --init --cpus "$cpus" --memory "${FUZZ_MEMORY:-3g}" \
  --user "$(id -u):$(id -g)" -e HOME="$work/.fuzz-home" -e ASAN_OPTIONS -e FUZZ_DEBUG \
  -v "$work:$work" -w "$PWD" "${FUZZ_IMAGE:-swift:6.2}" "$@"
