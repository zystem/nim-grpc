#!/bin/sh
# Regenerates tests/gen, tests/proto/*.bin and src/grpc/wkt. Needs protoc and grpc-proto:
#   PROTOC=protoc GRPC_PROTO=path/to/grpc-proto tools/gen_test_protos.sh
set -e
cd "$(dirname "$0")/.."
PROTOC=${PROTOC:-protoc}
GRPC_PROTO=${GRPC_PROTO:?checkout of github.com/grpc/grpc-proto}
nim c -d:release --hints:off -o:tools/protoc-gen-nim src/protoc_gen_nim.nim
rm -rf tests/gen && mkdir -p tests/gen
$PROTOC --plugin=protoc-gen-nim=tools/protoc-gen-nim --nim_out=tests/gen -Itests/proto \
  codec.proto legacy.proto wkt_use.proto
$PROTOC --plugin=protoc-gen-nim=tools/protoc-gen-nim --nim_out=tests/gen -I"$GRPC_PROTO" \
  grpc/testing/empty.proto grpc/testing/messages.proto grpc/testing/test.proto
(cd tests/proto &&
 $PROTOC --encode=codec.test.Everything -I. codec.proto < fixture.txtpb > everything.bin &&
 $PROTOC --encode=codec.legacy.Legacy -I. legacy.proto < legacy.txtpb > legacy.bin &&
 $PROTOC --encode=codec.wkt.Event -I. wkt_use.proto < wkt.txtpb > wkt.bin)
# The well-known types shipped in the package:
rm -rf src/grpc/wkt/google && mkdir -p src/grpc/wkt
$PROTOC --plugin=protoc-gen-nim=tools/protoc-gen-nim --nim_out=src/grpc/wkt \
  google/protobuf/any.proto google/protobuf/duration.proto google/protobuf/empty.proto \
  google/protobuf/field_mask.proto google/protobuf/struct.proto \
  google/protobuf/timestamp.proto google/protobuf/wrappers.proto \
  google/protobuf/source_context.proto google/protobuf/type.proto google/protobuf/api.proto
