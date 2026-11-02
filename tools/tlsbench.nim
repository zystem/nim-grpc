## Throughput of large replies over TLS, for comparing cipher orders.
##
##   tlsbench aes|chacha|auto|plain [MESSAGES] [KIB]     (plain: no TLS, the baseline)
##
## A server and a client in one process (so the figure is the cost of encrypting
## and decrypting together) exchange MESSAGES replies of KIB kibibytes each over
## loopback with the throw-away certificates of tests/certs. Build with -d:release.

import std/[os, strutils, monotimes, times]
import grpc

const certs = currentSourcePath.parentDir.parentDir / "tests" / "certs"
proc pem(name: string): string = readFile(certs / name)

let order =
  case paramStr(1)
  of "aes": coAesGcmFirst
  of "chacha": coChaChaFirst
  else: coAuto
let messages = if paramCount() >= 2: parseInt(paramStr(2)) else: 200
let kib = if paramCount() >= 3: parseInt(paramStr(3)) else: 1024

var payload = newSeq[byte](kib * 1024)
for i in 0 ..< payload.len: payload[i] = byte(i * 31)

proc reply(ctx: var ServerContext; request: seq[byte]): seq[byte] {.nimcall, gcsafe.} =
  {.cast(gcsafe).}: payload

let plain = paramStr(1) == "plain"
let srv = newGrpcServer(maxMessage = 8 * 1024 * 1024,
                        tls = (if plain: nil else: tlsServerConfig(pem"server.pem", pem"server.key", cipherOrder = order)))
srv.addUnary("/b.B/Get", reply)
srv.start()
let ch = dial("127.0.0.1", srv.port.int,
              (if plain: nil else: tlsClientConfig(pem"ca.pem", cipherOrder = order)), "localhost")
for _ in 0 ..< 5: discard ch.unaryCall("/b.B/Get", @[], maxMessage = 8 * 1024 * 1024)   # warm up
let t0 = getMonoTime()
var bytes = 0
for _ in 0 ..< messages:
  bytes += ch.unaryCall("/b.B/Get", @[], maxMessage = 8 * 1024 * 1024).message.len
let secs = (getMonoTime() - t0).inNanoseconds.float / 1e9
echo paramStr(1), ": ", formatFloat(bytes.float / secs / 1e6, ffDecimal, 1), " MB/s (",
     messages, " x ", kib, " KiB in ", formatFloat(secs, ffDecimal, 2), " s)"
ch.close()
srv.stop()
