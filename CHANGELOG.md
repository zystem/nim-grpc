# Changelog

## Unreleased

### Added
- Manual HTTP/2 flow control on the chronos adapter: the peer's window reopens only as handlers read, so a slow reader backpressures the sender instead of buffering without bound.
- Project documents for the OpenSSF Best Practices levels: [security policy](SECURITY.md), [governance](GOVERNANCE.md), [contributing](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md), DCO sign-off with a check of pull requests, [threat model](docs/threat-model.md), [architecture](docs/architecture.md), [assurance case](docs/assurance-case.md), [security requirements](docs/security-requirements.md), [security policies](docs/security-policies.md), [building](docs/building.md), [roadmap](docs/roadmap.md), [upgrading](docs/upgrading.md).
- CI: all tests plainly and under AddressSanitizer on every push and pull request; Dependency Review, Scorecard, secret scanning configuration, Dependabot for the actions.

## 0.0.1

First public state: unary and streaming gRPC over HTTP/2 (plaintext, TLS, mTLS) on a blocking API and on chronos, code generation from `.proto`, gzip, keepalive, graceful shutdown, reconnecting channels, well-known types.
