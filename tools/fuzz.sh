#!/bin/bash
# Build the mutation fuzzer under AddressSanitizer and run it.
#   tools/fuzz.sh [SECONDS_PER_TARGET [TARGET]]   (default 60, all targets)
# Needs nghttp2 like the tests (NGHTTP2_PREFIX or -d:nghttp2Prefix in NIMFLAGS).
set -eu
SECS=${1:-60}
TARGET=${2:-all}
OUT=${OUT:-fuzz-out}
nim c -d:useMalloc --debugger:native --hints:off \
  --passC:-fsanitize=address --passL:-fsanitize=address \
  --nimcache:nimcache/fuzz ${NIMFLAGS:-} -o:"${FUZZ_BIN:-/tmp/fuzz}" tools/fuzz.nim
exec "${FUZZ_BIN:-/tmp/fuzz}" "$TARGET" "$SECS" "${SEED:-$RANDOM$RANDOM}" "$OUT"
