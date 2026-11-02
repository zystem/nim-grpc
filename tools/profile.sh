#!/bin/bash
# Heap profile of the chronos server with N connections held open, under heaptrack.
#
#   tools/profile.sh [--tls]
#
# Build the probe with symbols and the system allocator first:
#   nim c -d:release --debugger:native -d:useMalloc -o:/tmp/asyncload_prof tools/asyncload.nim
# Environment: PROBE (default /tmp/asyncload_prof), CONNS (default 1000), PORT, OUT (default profile-out).
# Writes $OUT/summary.txt (peak heap, per connection, the biggest consumers with the
# first line of our own code behind each) and keeps the raw heaptrack file.
set -eu
MODE=""; [ "${1:-}" = "--tls" ] && MODE="tls"
PROBE=${PROBE:-/tmp/asyncload_prof}
CONNS=${CONNS:-1000}
PORT=${PORT:-10080}
OUT=${OUT:-profile-out}
mkdir -p "$OUT"; rm -f "$OUT"/heaptrack.*
ulimit -n 65536 2>/dev/null || true

( cd "$OUT" && heaptrack "$PROBE" server $PORT $MODE > server.log 2>&1 ) &
sleep 3
"$PROBE" hold $PORT $CONNS $MODE > "$OUT/hold.log" 2>&1 & CLI=$!
for _ in $(seq 1 120); do grep -q "^open:" "$OUT/hold.log" 2>/dev/null && break; sleep 1; done
grep -q "^open:" "$OUT/hold.log" || { echo "client did not open $CONNS connections"; cat "$OUT/hold.log"; exit 1; }
sleep 2
kill $CLI 2>/dev/null || true
pkill -TERM -x "$(basename "$PROBE" | cut -c1-15)" || true
sleep 4

RAW=$(ls "$OUT"/heaptrack.*.zst | head -1)
heaptrack_print "$RAW" -n 12 -s 3 > "$OUT/report.txt" 2>/dev/null
peak=$(awk -F': ' '/peak heap memory consumption/ {print $2}' "$OUT/report.txt")
{
  echo "mode: ${MODE:-plain}, connections: $CONNS"
  echo "peak heap: $peak"
  echo "$peak" | awk -v n=$CONNS '{v=$1+0; u=substr($1,length($1)); m=(u=="M")?1024:(u=="K")?1:(u=="G")?1048576:1/1024; printf "heap per connection: %.1f KiB\n", v*m/n}'
  echo
  echo "biggest consumers at the peak (size, allocation calls, allocating function, first line of our code):"
  awk '/^PEAK MEMORY CONSUMERS/{f=1} f' "$OUT/report.txt" | awk '
    /peak memory consumed over/ { if (hdr!="") print "  " hdr " | " leaf " | " src; hdr=$0; sub(/ from$/,"",hdr); leaf=""; src=""; next }
    hdr!="" && leaf=="" && /^[A-Za-z_][^ ]*$/ { leaf=substr($0,1,48); next }
    /(nim-grpc|nimgrpc)\/(src|tools)/ && src=="" { sub(/^ *at .*(nim-grpc|nimgrpc)\//,""); src=$0 }
    END { if (hdr!="") print "  " hdr " | " leaf " | " src }' | head -12
} | tee "$OUT/summary.txt"
