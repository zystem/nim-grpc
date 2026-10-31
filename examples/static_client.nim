## A shim-sized client: mTLS, keepalive, gzip, one unary call and one
## client-streaming call, both through generated code.
import std/[os, strutils]
import grpc
import grpc/testing/test_pb

let certs = paramStr(1)
let ch = dial("127.0.0.1", parseInt(paramStr(2)),
              tlsClientConfig(readFile(certs / "ca.pem"), readFile(certs / "client.pem"),
                              readFile(certs / "client.key")),
              serverName = "localhost",
              keepalive = Keepalive(timeMs: 10_000, timeoutMs: 2000))
let svc = newTestServiceClient(ch)
let r = svc.unaryCall(SimpleRequest(responseSize: 10, payload: Payload(body: newSeq[byte](1000))),
                      timeoutMs = 5000, compression = "gzip")
var w = svc.streamingInputCall(timeoutMs = 5000)
for i in 0 ..< 3: w.send StreamingInputCallRequest(payload: Payload(body: newSeq[byte](100)))
let total = w.closeAndRecv().aggregatedPayloadSize
w.close()
for l in readFile("/proc/self/status").splitLines:
  if l.startsWith("VmRSS"): echo "RSS ", l.splitWhitespace()[1], " KiB"
echo "ok ", r.payload.body.len, " ", total
ch.close()
