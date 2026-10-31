#!/bin/bash
# Server RSS and thread count over connection churn.
# usage: tools/memprobe.sh [--tls]   (build tests/interop/interop with -d:release first)
MODE=$1
INTEROP=${INTEROP:-tests/interop/interop}
$INTEROP server 10060 $MODE > /dev/null 2>&1 & P=$!
sleep 0.5
st() { echo "$1: $(grep VmRSS /proc/$P/status | awk '{print $2" KiB"}'), threads $(grep Threads /proc/$P/status | awk '{print $2}')"; }
st idle
$INTEROP client 127.0.0.1 10060 empty_unary $MODE > /dev/null; st "after 1 conn"
for i in $(seq 1 50); do $INTEROP client 127.0.0.1 10060 empty_unary $MODE > /dev/null; done; st "after 51 conns"
for i in $(seq 1 150); do $INTEROP client 127.0.0.1 10060 empty_unary $MODE > /dev/null; done; st "after 201 conns"
$INTEROP client 127.0.0.1 10060 "" $MODE > /dev/null; st "after full suite"
kill $P
