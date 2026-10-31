Test-only certificates. The CA keys were deleted after signing; never use
these anywhere but the test suite.

- `ca.pem` signs `server.pem`/`server.key` (EC P-256, SAN localhost and
  127.0.0.1), `rsaserver.pem`/`rsaserver.key` (RSA 2048, same SANs) and
  `client.pem`/`client.key` (clientAuth).
- `otherca.pem` signs `rogue.pem`/`rogue.key`, which must be rejected by
  anyone trusting only `ca.pem`.

Valid for 100 years from 2026-10-31.
