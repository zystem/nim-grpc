# Upgrading

The latest release is supported ([SECURITY.md](../SECURITY.md)). Read the notes below and in [CHANGELOG.md](../CHANGELOG.md) before upgrading.

General steps: update the package (`nimble install grpc@X.Y.Z` or the new commit); rebuild nghttp2 if [building.md](building.md) names a new version; regenerate the code of your `.proto` files with the new `protoc-gen-nim` (generated code and the library are versioned together); run your tests.

## Unreleased

- **TLS suites and certificates**: the library now negotiates only TLS 1.2 with ECDHE and AES-GCM or ChaCha20-Poly1305, and verifies certificates with RSA keys of 2048 bits or more and no MD5 or SHA-1 signatures. A peer or certificate that does not meet this fails the handshake. Reissue such certificates (a SHA-256 or better signature, an RSA key of 2048 bits or an EC key).

- **Chronos adapter, flow control**: the peer's window now reopens only as a handler reads (`recvData`). A client that sends a large body and only then reads an answer from a peer that replies while it still receives can stall; send and read concurrently, as in `request` of `tests/tasynch2.nim`. The blocking adapter is unchanged.
