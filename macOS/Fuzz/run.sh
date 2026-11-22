#!/bin/bash
# Runs one harness inside the swift:6.2 image with the lane's budgets:
#   run.sh <build-dir> <target> <seconds> [libFuzzer options...]
# The corpus grows in <build-dir>/corpus/<target>, seeded from
# <build-dir>/seeds/<target>; crashes land in <build-dir>/artifacts/<target>/.
set -euo pipefail
fuzz=$(cd "$(dirname "$0")" && pwd)
build=${1:?usage: run.sh <build-dir> <target> <seconds> [options...]}
target=${2:?missing target}
seconds=${3:?missing seconds}
shift 3
mkdir -p "$build/corpus/$target" "$build/artifacts/$target"
# Leak detection is off: the async harnesses release their input after the
# reader returns, which LeakSanitizer reports as a leak.
# docker runs the container outside the caller's cgroup: the container's own
# timeout and libFuzzer's total time bound the run, and --cpus 2 bounds it.
# A small ASan quarantine and periodic release keep the fuzzer's RSS, not
# just its live heap, inside the 1 GiB limit over a long run.
export ASAN_OPTIONS=${ASAN_OPTIONS:-quarantine_size_mb=64:allocator_release_to_os_interval_ms=1000:detect_leaks=0}
exec "$fuzz/run-docker.sh" timeout -k 30 "$((seconds + 120))" "$build/$target" \
  -max_total_time="$seconds" -rss_limit_mb=1024 -malloc_limit_mb=512 -timeout=10 \
  -detect_leaks=0 -artifact_prefix="$build/artifacts/$target/" -print_final_stats=1 "$@" \
  "$build/corpus/$target" "$build/seeds/$target"
