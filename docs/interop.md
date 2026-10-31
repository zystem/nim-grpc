# Interop

The cases come from the gRPC interop suite (`doc/interop-test-descriptions.md`
in grpc/grpc) and run over the shared `grpc.testing.TestService`.

- **Nim peer:** `tests/interop/interop.nim`, both server and client.
- **Reference peer:** `tests/interop/gopeer/main.go`, built on grpc-go v1.76.0.

## Results, 2026-10-31

| Case | Nim → Nim | grpc-go → Nim | Nim → grpc-go |
|:---|:---:|:---:|:---:|
| empty_unary | pass | pass | pass |
| large_unary | pass | pass | pass |
| status_code_and_message (unary part) | pass | pass | pass |
| special_status_message | pass | pass | pass |
| unimplemented_method | pass | pass | pass |
| unimplemented_service | pass | pass | pass |
| custom_metadata (unary part) | pass | pass | pass |
| timeout_on_sleeping_server (unary variant) | pass | pass | pass |

Streaming cases (client_streaming, server_streaming, ping_pong,
cancel_after_begin, and the streaming halves of the cases above) come with
streaming support.

## Running

```sh
nim c -d:release tests/interop/interop.nim
tests/interop/interop server 10010 &
tests/interop/interop client 127.0.0.1 10010
```

To build the Go peer, place `tests/interop/gopeer/go.mod.example` as `go.mod`
and run `go build`. With module proxy access, delete the `replace` block and
run `go mod tidy`. Without it, as in the sandbox where these results were
produced, point the `replace` lines at local clones of grpc-go, x/net, x/sys,
x/text, protobuf-go and go-genproto (googleapis/rpc).

```sh
./peer -mode server -addr 127.0.0.1:10011 &
./peer -addr 127.0.0.1:10010              # grpc-go client against the Nim server
tests/interop/interop client 127.0.0.1 10011
```
