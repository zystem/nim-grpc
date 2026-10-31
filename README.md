# nim-grpc

gRPC for Nim on top of [nghttp2](https://nghttp2.org).

**Status:** early. Unary gRPC calls work, client and server, over plaintext
HTTP/2. The unary interop cases pass against grpc-go in both directions
([docs/interop.md](docs/interop.md)). The HTTP/2 layer passes 134 of 146 h2spec
tests ([docs/h2spec.md](docs/h2spec.md)). Streaming, TLS and code generation
are next.

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

## Design

- **I/O-free core.** `grpc/h2/session` wraps nghttp2's memory API: bytes go in
  with `recv`, bytes to transmit come out of `takeOutput`, and stream events come
  out of `takeEvents`. The core never touches a socket, so the same code runs
  under blocking threads, chronos, or a test that pipes two sessions together.
- **Adapters on top.** `grpc/h2/blocking`: a reader and a writer thread per
  connection, the connection lock is never held during socket I/O, callers
  block on their own stream, with deadlines. Server handlers run on a worker
  pool outside the connection lock. A chronos adapter is planned. TLS with ALPN
  `h2` lives in the adapters.
- **ORC-safe FFI.** nghttp2 only ever sees raw `ptr` to objects the session owns;
  callbacks are `raises: []` and never let an exception reach C.

## Building

nghttp2 is linked statically. Build it once:

```sh
curl -LO https://github.com/nghttp2/nghttp2/releases/download/v1.68.0/nghttp2-1.68.0.tar.xz
tar xf nghttp2-1.68.0.tar.xz && cd nghttp2-1.68.0
cmake -S . -B build -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=/opt/nghttp2
cmake --build build -j && cmake --install build
```

A different prefix is passed with `-d:nghttp2Prefix=/path`.

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
4. Streaming calls (client, server, bidi)
5. TLS with ALPN `h2`, mTLS
6. chronos adapter
7. Code generation from `.proto`
8. Manual flow control for backpressure (`NO_AUTO_WINDOW_UPDATE`)
