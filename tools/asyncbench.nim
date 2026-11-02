## Throughput of large replies on the chronos server and client.
##
##   asyncbench plain|tls [MESSAGES] [KIB] [PAR]
##
## Like tlsbench, but on the event loop: the server and PAR concurrent callers
## share one thread, so the figure is what one core can do for both ends. With
## PAR > 1 the calls interleave on the connection. Build with -d:release.

import std/[os, strutils, monotimes, times]
import pkg/chronos
import grpc/[asyncclient, asyncserver]

const certs = currentSourcePath.parentDir.parentDir / "tests" / "certs"
proc pem(name: string): string = readFile(certs / name)

let tls = paramStr(1) == "tls"
let messages = if paramCount() >= 2: parseInt(paramStr(2)) else: 200
let kib = if paramCount() >= 3: parseInt(paramStr(3)) else: 1024
let par = if paramCount() >= 4: parseInt(paramStr(4)) else: 1
const big = 8 * 1024 * 1024

var payload = newSeq[byte](kib * 1024)
for i in 0 ..< payload.len: payload[i] = byte(i * 31)

proc reply(ctx: AsyncServerContext; request: seq[byte]): Future[seq[byte]] {.async.} =
  {.cast(gcsafe).}: return payload

proc caller(ch: AsyncChannel; n: int): Future[int] {.async.} =
  for _ in 0 ..< n:
    result += (await ch.unaryCall("/b.B/Get", @[], maxMessage = big)).message.len

proc main() {.async.} =
  let srv = newAsyncGrpcServer(maxMessage = big,
              tls = (if tls: tlsServerConfig(pem"server.pem", pem"server.key") else: nil))
  srv.addUnary("/b.B/Get", reply)
  srv.start()
  let ch = await dialAsync("127.0.0.1", srv.port,
                           (if tls: tlsClientConfig(pem"ca.pem") else: nil), "localhost")
  for _ in 0 ..< 5:
    let got = (await ch.unaryCall("/b.B/Get", @[], maxMessage = big)).message
    {.cast(gcsafe).}:
      if got != payload:
        quit "the reply differs from what the server sent"
  let t0 = getMonoTime()
  var fs: seq[Future[int]]
  for _ in 0 ..< par: fs.add caller(ch, messages div par)
  var bytes = 0
  for f in fs: bytes += await f
  let secs = (getMonoTime() - t0).inNanoseconds.float / 1e9
  echo paramStr(1), ": ", formatFloat(bytes.float / secs / 1e6, ffDecimal, 1), " MB/s (",
       messages div par * par, " x ", kib, " KiB, ", par, " at once, ", formatFloat(secs, ffDecimal, 2), " s)"
  await ch.close()
  await srv.stop()

waitFor main()
