# Contributing

- **Bugs and ideas**: open an issue. **Security problems**: not in an issue; see [SECURITY.md](SECURITY.md).
- **Build and test**: [docs/building.md](docs/building.md). In short: `nimble test`, and `nimble asan` / `nimble tsan` for the sanitizers.
- **Coding standard**: the [Nim style guide (NEP-1)](https://nim-lang.org/docs/nep1.html) and the style of the surrounding code: two-space indent, `camelCase` procs, comments that say why and not what. The code compiles with `--mm:orc --panics:on` (see `config.nims`) and the compiler's warnings are not left in. CI builds and runs every test file on every pull request; a pull request that does not build or whose tests fail is not merged.
- **Tests**: a change of behaviour comes with a test that fails without it; a parser of input (HTTP/2 frames, gRPC framing, Protobuf, gzip) comes with a test of malformed input. Tests are in `tests/` and listed in `grpc.nimble`.
- **Compiler workarounds**: Nim 2.2.12 and 2.2.14 can lose an exception passing through `finally` or `defer`; read [docs/nim-compiler-notes.md](docs/nim-compiler-notes.md) before writing cleanup code.
- **Cryptography**: no primitive of our own. TLS is BearSSL, HTTP/2 is nghttp2, gzip is zlib.
- **Commits**: a short subject saying what changed and why; [CHANGELOG.md](CHANGELOG.md) is kept for user-visible changes.
- **Conduct**: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). **Governance and roles**: [GOVERNANCE.md](GOVERNANCE.md). **Roadmap**: [docs/roadmap.md](docs/roadmap.md).
- **Sign-off (DCO)**: every commit carries a `Signed-off-by: Name <email>` line (`git commit -s`), which says that you have the right to submit the work under the project's license, as in [DCO.md](DCO.md). The `DCO` workflow checks every commit of a pull request (bots are exempt) and a commit without the line fails it.
- **License**: by contributing you agree that your work is under the MIT license of the project.

## When and how the tests run

- **By you, before a pull request**: `nimble test`; for code that touches memory or threads also `nimble asan` and `nimble tsan`. Interop with grpc-go and h2spec need extra tools and are run by hand ([docs/interop.md](docs/interop.md), [docs/h2spec.md](docs/h2spec.md)).
- **Automatically**: on every push to `main` and every pull request, `.github/workflows/ci.yml` builds nghttp2 and runs all test files plainly and under AddressSanitizer/LeakSanitizer; Dependency Review runs on pull requests; Scorecard runs on its own schedule; Dependabot proposes updates of the actions. Weekly, `soak.yml` runs `tools/soak.sh`: server memory per connection (plain and TLS) and no growth of memory or descriptors under connection churn; a breach opens an issue.
- **A change of behaviour** (a fix, a feature) adds or updates a test in the automatic suite; a pull request without one is asked to add it.
