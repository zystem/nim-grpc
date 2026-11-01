## Load probe for the chronos server: many connections, each with a call
## left open, from one client process.
##
##   asyncload server PORT
##   asyncload client PORT CONNECTIONS
##
## The client opens CONNECTIONS channels, starts a bidirectional call on each
## and exchanges one message, then keeps them all open until killed; read the
## server's RSS meanwhile (tools/memprobe.sh does the same for the blocking
## server).

import std/[os, strutils, options]
import pkg/chronos
import grpc/[asyncclient, asyncserver]

proc echoStream(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
  while true:
    let m = await call.recv()
    if m.isNone: break
    await call.send(m.get)

proc client(port, n: int) {.async.} =
  var chans: seq[AsyncChannel]
  var calls: seq[AsyncCall]
  for i in 0 ..< n:
    let ch = await dialAsync("127.0.0.1", port)
    let call = await ch.newCall("/load.L/Echo")
    await call.send(@[byte(i mod 256)])
    discard await call.recv()
    chans.add ch
    calls.add call
  echo "open: ", n, " connections, one call each"
  await sleepAsync(1.hours)

when isMainModule:
  let port = parseInt(paramStr(2))
  if paramStr(1) == "server":
    let s = newAsyncGrpcServer(port)
    s.addStreaming("/load.L/Echo", echoStream)
    s.start()
    echo "listening on ", s.port
    runForever()
  else:
    waitFor client(port, parseInt(paramStr(3)))
