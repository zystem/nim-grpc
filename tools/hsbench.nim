## Cost of a new TLS connection: dial, one empty call, close, N times.
##
##   hsbench [N] [mtls] [noresume]        Build with -d:release.
import std/[os, strutils, monotimes, times]
import nimgrpc

const certs = currentSourcePath.parentDir.parentDir / "tests" / "certs"
proc pem(name: string): string = readFile(certs / name)

let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 200
let mtls = "mtls" in commandLineParams()
let resume = "noresume" notin commandLineParams()

proc echo1(ctx: var ServerContext; request: seq[byte]): seq[byte] {.nimcall, gcsafe.} = request

let srv = newGrpcServer(tls = tlsServerConfig(pem"server.pem", pem"server.key",
                                              clientCaPem = (if mtls: pem"ca.pem" else: "")))
let cfg = if mtls: tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key")
          else: tlsClientConfig(pem"ca.pem")
if not resume:
  cfg.setSessionLifetime(0)
srv.addUnary("/b.B/Get", echo1)
srv.start()
proc once() =
  let ch = dial("127.0.0.1", srv.port.int, cfg, "localhost")
  discard ch.unaryCall("/b.B/Get", @[1'u8])
  ch.close()
for _ in 0 ..< 5: once()
let t0 = getMonoTime()
for _ in 0 ..< n: once()
let ms = (getMonoTime() - t0).inNanoseconds.float / 1e6 / n.float
echo (if mtls: "mtls" else: "tls"), (if resume: " resuming" else: " full handshake"), ": ", formatFloat(ms, ffDecimal, 2), " ms per new connection and first call"
srv.stop()
