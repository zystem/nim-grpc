## Load probe for the chronos server: many connections, each with a call
## left open, or connection churn, from one client process.
##
##   asyncload server PORT [tls]
##   asyncload hold PORT CONNECTIONS [tls]          open CONNECTIONS calls, keep them until killed
##   asyncload churn PORT WORKERS SECONDS [tls]     WORKERS loops of dial, call, close, for SECONDS
##
## `hold` is the figure of docs/async.md (server RSS per connection). `churn`
## is for tools/soak.sh: the server's RSS and descriptors must settle, not
## grow. With `tls` both sides use the throw-away certificates of tests/certs.

import std/[os, strutils, options]
import pkg/chronos
import grpc/[asyncclient, asyncserver]

const certs = currentSourcePath.parentDir.parentDir / "tests" / "certs"
proc pem(name: string): string = readFile(certs / name)

proc clientTls(on: bool): TlsConfig =
  if on: tlsClientConfig(pem"ca.pem") else: nil


proc echoStream(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  while true:
    let m = await call.recv()
    if m.isNone: break
    await call.send(m.get)

proc hold(port, n: int; tls: bool) {.async.} =
  var chans: seq[AsyncChannel]
  var calls: seq[AsyncCall]
  for i in 0 ..< n:
    let ch = await dialAsync("127.0.0.1", port, clientTls(tls), "localhost")
    let call = await ch.newCall("/load.L/Echo")
    await call.send(@[byte(i mod 256)])
    discard await call.recv()
    chans.add ch
    calls.add call
  echo "open: ", n, " connections, one call each"
  await sleepAsync(1.hours)

proc worker(port: int; tls: bool; until: Moment; done: ref int) {.async.} =
  while Moment.now() < until:
    let ch = await dialAsync("127.0.0.1", port, clientTls(tls), "localhost")
    let call = await ch.newCall("/load.L/Echo")
    for k in 0 ..< 3:
      await call.send(@[byte(k)])
      discard await call.recv()
    call.close()
    await ch.close()
    inc done[]

proc churn(port, workers, seconds: int; tls: bool) {.async.} =
  let until = Moment.now() + seconds.seconds
  var done = new int
  var fs: seq[Future[void]]
  for w in 0 ..< workers: fs.add worker(port, tls, until, done)
  await allFutures(fs)
  echo "churn: ", done[], " connections opened and closed"

when isMainModule:
  let tls = paramStr(paramCount()) == "tls"
  let port = parseInt(paramStr(2))
  case paramStr(1)
  of "server":
    let t = if tls: tlsServerConfig(pem"server.pem", pem"server.key") else: nil
    let s = newAsyncGrpcServer(port, tls = t)
    s.addStreaming("/load.L/Echo", echoStream)
    s.start()
    echo "listening on ", s.port
    runForever()
  of "hold": waitFor hold(port, parseInt(paramStr(3)), tls)
  of "churn": waitFor churn(port, parseInt(paramStr(3)), parseInt(paramStr(4)), tls)
  else: quit "usage: see the top of tools/asyncload.nim"
