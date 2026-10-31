# nim-grpc

gRPC for Nim on top of [nghttp2](https://nghttp2.org).

**Status:** early. Unary and streaming calls (client-, server- and
bidirectional) work, client and server, over plaintext HTTP/2, TLS and mutual
TLS. 14 interop cases pass against grpc-go in both directions in each mode
([docs/interop.md](docs/interop.md)). The HTTP/2 layer passes 135 of 146 h2spec
tests ([docs/h2spec.md](docs/h2spec.md)). Code generation from `.proto` is
next.

```nim
import grpc

proc sayHello(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  if req.len == 0: raise newGrpcError(scInvalidArgument, "empty name")
  ctx.trailers.add ("x-served-by", "nim")
  req

let srv = newGrpcServer(port = 50051)
srv.addUnary("/helloworld.Greeter/SayHello", sayHello)
srv.start()

let ch = dial("127.0.0.1", 50051)
let r = ch.unaryCall("/helloworld.Greeter/SayHello", @[1'u8, 2, 3], timeoutMs = 1000)
```

TLS and mutual TLS (BearSSL, TLS 1.2, ALPN `h2`; RSA or EC keys in PEM):

```nim
let srv = newGrpcServer(port = 50051,
  tls = tlsServerConfig(readFile("server.pem"), readFile("server.key"),
                        clientCaPem = readFile("ca.pem")))   # omit for plain TLS
let ch = dial("10.0.0.5", 50051,
  tlsClientConfig(readFile("ca.pem"), readFile("client.pem"), readFile("client.key")),
  serverName = "api.internal")   # checked against the certificate's DNS names
```

Streaming: the server handler gets a `ServerCall`, the client opens a
`ClientCall`.

```nim
proc chat(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var msg: seq[byte]
  while call.recv(msg):        # until the client half-closes
    call.send(msg)             # echo each message back

srv.addStreaming("/demo.Chat/Talk", chat)   # before srv.start()

var call = ch.newCall("/demo.Chat/Talk", timeoutMs = 5000)
call.send(@[1'u8])
call.closeSend()
var reply: seq[byte]
while call.recv(reply): discard  # raises GrpcError on a non-OK status
call.close()
```

## Design

- **I/O-free core.** `grpc/h2/session` wraps nghttp2's memory API: bytes go in
  with `recv`, bytes to transmit come out of `takeOutput`, and stream events come
  out of `takeEvents`. The core never touches a socket, so the same code runs
  under blocking threads, chronos, or a test that pipes two sessions together.
- **Adapters on top.** `grpc/h2/blocking`: a reader and a writer thread per
  connection, the connection lock is never held during socket I/O, callers
  block on their own stream, with deadlines. A server handler starts when its
  request HEADERS arrive and runs on its own worker thread from a pool that
  grows on demand. Output is bounded per connection and per stream, so a slow
  peer slows the sender down. A chronos adapter is planned. TLS with ALPN
  `h2` lives in the adapters.
- **TLS without I/O either.** BearSSL's engine is driven through four buffers
  under the connection lock (`grpc/tls`), so TLS fits the same threading model.
  TLS 1.2 only: BearSSL has no TLS 1.3.
- **ORC-safe FFI.** nghttp2 only ever sees raw `ptr` to objects the session owns;
  callbacks are `raises: []` and never let an exception reach C.

## Building

Dependencies: Nim 2.2.12 or later, [nim-bearssl](https://github.com/status-im/nim-bearssl)
(`nimble install bearssl`; BearSSL is compiled from source, nothing to install)
and nghttp2, linked statically. Build nghttp2 once:

```sh
curl -LO https://github.com/nghttp2/nghttp2/releases/download/v1.68.0/nghttp2-1.68.0.tar.xz
tar xf nghttp2-1.68.0.tar.xz && cd nghttp2-1.68.0
cmake -S . -B build -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=/opt/nghttp2
cmake --build build -j && cmake --install build
```

A different prefix is passed with `-d:nghttp2Prefix=/path`. Without nimble,
point `NIM_BEARSSL` at a checkout of nim-bearssl (with its submodule).

```sh
nimble test   # unit tests
nimble asan   # the same under AddressSanitizer/LeakSanitizer
nimble tsan   # the same under ThreadSanitizer
```

## Roadmap

1. HTTP/2 session over nghttp2 — done
2. Blocking adapter over TCP; h2spec conformance — done
3. gRPC unary calls: message framing, `grpc-timeout`, status in trailers,
   metadata; interop tests against grpc-go — done
4. Streaming calls (client, server, bidi) — done
5. TLS with ALPN `h2`, mTLS — done
6. chronos adapter
7. Code generation from `.proto`
8. Manual flow control for backpressure (`NO_AUTO_WINDOW_UPDATE`)

## Footprint

Measured on Linux x86-64, glibc, `-d:release`:

- A minimal TLS client, stripped: about 600 KB, with nghttp2 and BearSSL
  linked in. It needs only libc.
- Client RSS: 2.9 MiB after the first call over TLS, still 2.9 MiB after 1,000
  more calls, and 3.2 MiB after another 200 TLS connect/close cycles.
