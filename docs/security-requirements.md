# What a user can and cannot expect, in security

## Can expect

- **No memory unsafety from input in the library's own code**: Nim with `--mm:orc --panics:on`; the C parts (nghttp2, BearSSL, zlib) are well-known libraries; the test suite runs under AddressSanitizer and LeakSanitizer (`nimble asan`), and under ThreadSanitizer (`nimble tsan`).
- **Bounded messages**: a message larger than `maxMessage` (4 MiB by default, settable) is refused, before and after decompression.
- **Backpressure**: on the chronos adapter a reader that does not read stops its sender (HTTP/2 flow control), so buffers do not grow without bound.
- **TLS done by BearSSL**: ALPN `h2`; the client trusts only the CA certificates it is given and checks the server name; optional (required, if asked) client certificates on the server. No primitive of our own. TLS 1.2 only (BearSSL has no 1.3), with ECDHE and an AEAD cipher; peers that offer only static-RSA or CBC suites cannot connect. Certificate RSA keys must be 2048 bits or more, and MD5 and SHA-1 signatures are refused.
- **Malformed input ends a stream or a connection, not the process**: errors become a status, `RST_STREAM` or `GOAWAY`.
- **Source you can check**: tags are made by the maintainer from `main`; CI is green on the tagged commit ([security-policies.md](security-policies.md)).

## Cannot expect

- **Authentication or authorization of calls** beyond what TLS and metadata give; the program decides.
- **Protection from a compromised host** or from a program that picks plaintext HTTP/2 on an untrusted network.
- **Limits per client**: no rate limiting or connection quotas; set them in the program or in front of it.
- **Maturity**: the project is young (0.0.x), interop-tested against grpc-go on 18 cases and h2spec at 135 of 146, not run in large production.
- **A certified cryptographic module**: BearSSL is not certified, and no claim is made.
- **Fixes for old releases** beyond what [SECURITY.md](../SECURITY.md) says.
