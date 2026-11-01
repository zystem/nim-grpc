# Roadmap (November 2026 to November 2027)

What the project intends to do and not do in the next year. It is a plan of one maintainer, not a promise; items move when a user's need or a security problem asks for it. Done work is in [CHANGELOG.md](../CHANGELOG.md).

## Intends to do

1. **Fuzzing** of the parsers that face the network: the Protobuf decoder, gRPC framing, gzip, the HTTP/2 glue. Run them in CI under the sanitizers.
2. **Limits**: a cap on concurrent streams per connection and a total buffer budget per connection, settable by the program.
3. **Interop breadth**: more cases against grpc-go and one more implementation (grpc-java or the C++ core); the remaining h2spec cases that can be met.
4. **Releases**: tag releases with notes, keep the changelog, publish to the nimble directory.
5. **Quality**: a regression test for every fixed bug; measure coverage if a tool for Nim becomes usable.
6. **A second maintainer and a second reviewer** (see [GOVERNANCE.md](../GOVERNANCE.md)).
7. **Badges**: the OpenSSF Best Practices badge at "passing", then as far as the project can honestly meet it.

## Considers (no date)

- Server reflection and health checking services.
- Per-call interceptors.
- HTTP/2 over a unix socket.

## Does not intend to do

- Being a gRPC-Web or HTTP/1.1 gateway.
- Authentication schemes beyond TLS, mTLS and metadata (the program decides).
- Pure-Nim replacements of nghttp2, BearSSL or zlib.
