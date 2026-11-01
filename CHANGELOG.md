# Changelog

## Unreleased

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
