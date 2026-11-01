# Building, testing and dependencies

## Build

Requirements: Nim 2.2.12 or later (tested on 2.2.12 and 2.2.14), a C compiler, [nim-bearssl](https://github.com/status-im/nim-bearssl) (`nimble install bearssl`; BearSSL is compiled from source), zlib (`-lz`, or `-d:zlibStatic`), nghttp2 linked statically, and [chronos](https://github.com/status-im/nim-chronos) for the async API.

```sh
git clone https://github.com/zystem/nim-grpc && cd nim-grpc
nimble install -y --depsOnly
# nghttp2, once (the same steps as the CI, .github/workflows/ci.yml):
curl -LO https://github.com/nghttp2/nghttp2/releases/download/v1.68.0/nghttp2-1.68.0.tar.xz
tar xf nghttp2-1.68.0.tar.xz && cd nghttp2-1.68.0
cmake -S . -B build -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=/opt/nghttp2
cmake --build build -j && cmake --install build
cd .. && nimble test
```

A different prefix is passed with `-d:nghttp2Prefix=/path`. The README has the variant without nimble (`NIM_BEARSSL`, `NIM_PATHS`) and the footprint figures; a static musl build is in [static-build.md](static-build.md).

## Tests

`nimble test` runs every test file (`grpc.nimble` lists them); `nimble asan` and `nimble tsan` run the same under the sanitizers. Interop with grpc-go ([interop.md](interop.md)) and h2spec ([h2spec.md](h2spec.md)) need Go and the h2spec binary and are run by hand. What runs when: [CONTRIBUTING.md](../CONTRIBUTING.md).

## How dependencies are chosen, obtained and tracked

- **Choice**: few. TLS is BearSSL, HTTP/2 is nghttp2, gzip is zlib; the async API uses chronos. A new dependency is added only when nothing in the standard library or in those does the job, and it is named with the reason in the change.
- **Obtaining**: nimble packages from their repositories (`grpc.nimble` states the minimum versions); nghttp2 from its release tarball, built from source; no vendored binaries.
- **Tracking**: Dependabot proposes updates of the GitHub Actions each week; Dependency Review checks pull requests; the advisories of nghttp2, BearSSL and zlib are read at each release. The policy for findings is in [security-policies.md](security-policies.md).
