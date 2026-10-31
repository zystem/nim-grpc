#!/bin/sh
# Regenerates tests/gen and tests/proto/*.bin. Needs protoc and grpc-proto:
#   PROTOC=protoc GRPC_PROTO=path/to/grpc-proto tools/gen_test_protos.sh
set -e
cd "$(dirname "$0")/.."
PROTOC=${PROTOC:-protoc}
GRPC_PROTO=${GRPC_PROTO:?checkout of github.com/grpc/grpc-proto}
nim c -d:release --hints:off -o:tools/protoc-gen-nim src/protoc_gen_nim.nim
rm -rf tests/gen && mkdir -p tests/gen
$PROTOC --plugin=protoc-gen-nim=tools/protoc-gen-nim --nim_out=tests/gen -Itests/proto \
  codec.proto legacy.proto
$PROTOC --plugin=protoc-gen-nim=tools/protoc-gen-nim --nim_out=tests/gen -I"$GRPC_PROTO" \
  grpc/testing/empty.proto grpc/testing/messages.proto grpc/testing/test.proto
(cd tests/proto &&
 $PROTOC --encode=codec.test.Everything -I. codec.proto < fixture.txtpb > everything.bin &&
 $PROTOC --encode=codec.legacy.Legacy -I. legacy.proto < legacy.txtpb > legacy.bin)
