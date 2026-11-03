#!/bin/sh
# Statement coverage of the library: every test file is built with gcov
# instrumentation (the Nim compiler's #line directives make gcov report the
# lines of the .nim files), run, and the data merged by tools/coverage.py.
#   tools/coverage.sh            # prints the table, fails under 80%
#   THRESHOLD=85 OUT=/tmp/cov NIMGRPC_FLAGS=-d:nghttp2Prefix=/path tools/coverage.sh
# Needs gcc with gcov (9 or later) and python3.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-coverage-out}
THRESHOLD=${THRESHOLD:-80}
rm -rf "$OUT"
mkdir -p "$OUT"
for f in tests/t*.nim; do
  t=$(basename "$f" .nim)
  nim c --hints:off --warnings:off --lineDir:on --debugger:native \
    --passC:--coverage --passL:--coverage $NIMGRPC_FLAGS \
    --nimcache:"$OUT/nc_$t" -o:"$OUT/bin_$t" "$f" > "$OUT/build_$t.log" 2>&1 \
    || { cat "$OUT/build_$t.log"; exit 1; }
  "$OUT/bin_$t" > "$OUT/run_$t.log" 2>&1 || { cat "$OUT/run_$t.log"; echo "coverage: $t failed" >&2; exit 1; }
  echo "$t: $(grep -c '\[OK\]' "$OUT/run_$t.log") tests ok"
done
python3 tools/coverage.py "$OUT" "$THRESHOLD"
