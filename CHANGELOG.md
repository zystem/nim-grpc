# Changelog

## Unreleased

### Changed
- Cipher order of TLS: the same six suites (ECDHE with AES-128/256-GCM or ChaCha20-Poly1305), now ordered by the CPU. With AES-NI and PCLMULQDQ AES-GCM comes first, which was about 30% faster on large replies in `tools/tlsbench.nim` (33.5 MB/s with ChaCha20, 42-47 MB/s with AES-GCM, loopback, both ends in one process); otherwise ChaCha20 stays first, as BearSSL's portable AES is slow. A server now enforces its own order instead of following the client's. Choose with `cipherOrder` of `tlsServerConfig` / `tlsClientConfig` (`coAuto`, `coAesGcmFirst`, `coChaChaFirst`) or `setCipherOrder`.

### Added
- TLS session resumption (session ids), on by default for one hour: `setSessionLifetime(config, seconds)`, 0 to turn it off. A reconnect of a channel with the same `TlsConfig` and server name skips the public-key work: new connection plus first call (`tools/hsbench.nim`) 4.9 ms to 0.9 ms with TLS and 6.9 ms to 0.6 ms with mutual TLS. The server keeps only sessions of peers that were authenticated as required, and drops its cache as a whole when the lifetime has passed. A resumed session is not checked against the certificate again, so a revoked or expired certificate keeps working for a peer that holds a session until the lifetime ends (see `docs/security-requirements.md`).

### Fixed
- A new TLS connection took about twice as long as it had to: BearSSL's "full" profiles verify certificate signatures with the generic prime_i31 code, which was about 60% of a handshake. Certificates and the handshake now use the fast P-256 code (m64 where the CPU has 64x64->128 multiplication, m31 otherwise). New connection plus first call, `tools/hsbench.nim`: TLS 7.7 to 4.2 ms, mutual TLS 9.5 to 5.7 ms.
- The blocking transport woke every thread of a connection on each change (one condition variable for the writer, the senders and the receivers) and sent each piece of output with its own `send`. The writer now has its own condition, wakes happen only when someone waits, and what is ready is sent in one `send`. For a 1 KiB unary call: `futex` calls 60 to 26, `sendto` 6 to 2.3 and `recvfrom` 4.7 to 2.3.
- Bulk data was copied byte by byte, which a profile of a 900 KB echo over TLS showed to be about 72% of the CPU time (AES-GCM itself was about 4%). Appending to the connection, stream and TLS buffers, taking messages out of them and reading TLS plaintext now use one `copyMem` and no longer zero the space they grow into (`src/grpc/bytebuf.nim`). The TLS pumps also stopped shifting the whole pending buffer after every 16 KiB record (quadratic in the message size) and drop two more copies per message (`takeOutputInto`, reading BearSSL output straight into the buffer). In `tools/tlsbench.nim` (1 MiB replies, loopback) TLS went from about 48 MB/s to 136-194 MB/s and plaintext from 108-153 to 237-293 MB/s.
- `dial` and `dialAsync` blocked on connect for as long as the system's TCP timeout (minutes), with no way to bound it. Each connection attempt now gets `connectTimeoutMs`, 20 seconds by default; past it the call fails with UNAVAILABLE. A negative value keeps the old behaviour. Resolving the host name is not covered by the timeout.

### Changed
- CI tests on Nim 2.2.12 (the floor of `grpc.nimble`) and 2.2.14; the soak test runs on 2.2.14. Renovate proposes new Nim versions (`renovate.json`), which Dependabot cannot see.

### Added
- Scheduled long checks: a weekly mutation fuzzer over the parsers (`tools/fuzz.nim`, `fuzz.yml`), a nightly ThreadSanitizer run of the whole suite (`tsan.yml`) and a weekly heap profile of the server with its summary (`tools/profile.sh`, `profile.yml`). A shared setup action (`.github/actions/setup`) builds nghttp2 and Nim for them.
- Weekly soak test of the chronos server (`tools/soak.sh`, `.github/workflows/soak.yml`): memory per connection and no growth under churn, plain and TLS. `tools/asyncload.nim` gained `hold`, `churn` and `tls` modes.

## 0.0.1 — 2026-11-02

### Security
- TLS is narrowed to what is safe: only ECDHE key agreement with AES-GCM or ChaCha20-Poly1305 (BearSSL's "full" profile also offered static RSA, CBC and 3DES), RSA certificate keys of 2048 bits or more (the default admitted 1017), and no MD5 or SHA-1 certificate signatures. A peer that supports nothing better cannot connect any more; see [docs/upgrading.md](docs/upgrading.md).

### Added
- Manual HTTP/2 flow control on the chronos adapter: the peer's window reopens only as handlers read, so a slow reader backpressures the sender instead of buffering without bound.
- Project documents for the OpenSSF Best Practices levels: [security policy](SECURITY.md), [governance](GOVERNANCE.md), [contributing](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md), DCO sign-off with a check of pull requests, [threat model](docs/threat-model.md), [architecture](docs/architecture.md), [assurance case](docs/assurance-case.md), [security requirements](docs/security-requirements.md), [security policies](docs/security-policies.md), [building](docs/building.md), [roadmap](docs/roadmap.md), [upgrading](docs/upgrading.md).
- CI: all tests plainly and under AddressSanitizer on every push and pull request; Dependency Review, Scorecard, secret scanning configuration, Dependabot for the actions.

## Before 0.0.1

First public state: unary and streaming gRPC over HTTP/2 (plaintext, TLS, mTLS) on a blocking API and on chronos, code generation from `.proto`, gzip, keepalive, graceful shutdown, reconnecting channels, well-known types.
