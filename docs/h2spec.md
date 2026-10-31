# h2spec results

h2spec 2.6.0 against `tools/h2specserver` (blocking adapter, h2c, nghttp2 1.68.0),
2026-10-31: **146 tests, 134 passed, 2 skipped, 10 failed.**

```sh
nim c -d:release tools/h2specserver.nim && tools/h2specserver 18080 &
h2spec -h 127.0.0.1 -p 18080
```

h2spec 2.6.0 is written against RFC 7540. nghttp2 follows RFC 9113, which
replaced it. All ten failures come from that difference or from the test server
answering every request at once. None points to a bug in the adapter so far.
Each one still has to be confirmed separately.

| Section | Test | Got | Why |
|:---|:---|:---|:---|
| 5.1 | half closed (remote): DATA | the response DATA | The server replies the moment the request ends, so the stream is already closed when the extra DATA arrives. |
| 5.1 | closed: DATA / HEADERS after RST_STREAM (8, 9) | timeout | nghttp2 silently ignores frames on recently closed streams, which RFC 9113 §5.1 allows. |
| 5.1 | closed: DATA / HEADERS (11, 12) | timeout | Same as above. |
| 5.1.1 | stream id smaller than previous | DATA, then GOAWAY | The reply to stream 5 is sent before the bad HEADERS arrives, and h2spec looks only at the first frame. |
| 5.3.1 | PRIORITY that depends on itself | timeout | RFC 9113 deprecates priorities, and nghttp2 ignores PRIORITY frames. |
| 5.4.1 | invalid PING: expects a bare close | GOAWAY, then close | The test wants the TCP connection closed with no frame before it. Sending GOAWAY first is what RFC 9113 §5.4.1 asks for. |
| 6.3 | PRIORITY on stream 0 | timeout | PRIORITY frames are ignored (see 5.3.1). |
| 6.9.1 | window above 2^31-1 on a stream | GOAWAY (FLOW_CONTROL_ERROR) | nghttp2 treats this as a connection error, not a stream error. The connection still gets FLOW_CONTROL_ERROR. |

Still to do: rerun with a server that delays its replies, so the timing
artefacts in 5.1 and 5.1.1 drop out.
