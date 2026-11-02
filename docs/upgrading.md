# Upgrading

The latest release is supported ([SECURITY.md](../SECURITY.md)). Read the notes below and in [CHANGELOG.md](../CHANGELOG.md) before upgrading.

General steps: update the package (`nimble install grpc@X.Y.Z` or the new commit); rebuild nghttp2 if [building.md](building.md) names a new version; regenerate the code of your `.proto` files with the new `protoc-gen-nim` (generated code and the library are versioned together); run your tests.

## Unreleased

## 0.0.2

- **Session resumption**: a `TlsConfig` now resumes TLS sessions for ten minutes (`setSessionLifetime`, 0 turns it off). A resumed session is not checked against the certificate again, so a revoked or expired certificate keeps working for a peer that holds a session until the lifetime ends. If revocation must take effect at once, set the lifetime to 0 or restart the server. Reuse one `TlsConfig` for the channels to one server to get the benefit.
- **HTTP/2 window**: every connection now announces 1 MiB per stream and per connection (before: 64 KiB). A peer can leave up to 1 MiB unread on a connection, about 5 MB more resident memory per busy process in our measurements; large messages are 20-40% faster.
- **Server and unfinished requests**: a chronos server resets a stream with NO_ERROR once its response is complete and the client is still sending; the client's `send` then raises the server's status instead of waiting.
- **`send` takes `sink`**: `send` of the async client, server and `AsyncH2Stream` moves its message when the caller does not use it again (no source change needed); keep a copy if you read the variable afterwards.

- **Cipher order**: TLS now prefers AES-GCM on a CPU with AES-NI and PCLMULQDQ and ChaCha20-Poly1305 elsewhere (before: ChaCha20 first everywhere), and a server's order wins over the client's. The set of suites is unchanged, so every peer that connected before still connects. Pin the old order with `cipherOrder = coChaChaFirst`.

- **Connect timeout**: `dial`, `dialAsync` and the reconnects of a channel give up on a server that does not accept the TCP connection after 20 seconds (`connectTimeoutMs`, UNAVAILABLE). Pass `connectTimeoutMs = -1` for the previous behaviour, or a smaller figure to fail faster. The name resolver is not bounded by it.
- **TLS suites and certificates**: the library now negotiates only TLS 1.2 with ECDHE and AES-GCM or ChaCha20-Poly1305, and verifies certificates with RSA keys of 2048 bits or more and no MD5 or SHA-1 signatures. A peer or certificate that does not meet this fails the handshake. Reissue such certificates (a SHA-256 or better signature, an RSA key of 2048 bits or an EC key).

- **Chronos adapter, flow control**: the peer's window now reopens only as a handler reads (`recvData`). A client that sends a large body and only then reads an answer from a peer that replies while it still receives can stall; send and read concurrently, as in `request` of `tests/tasynch2.nim`. The blocking adapter is unchanged.
