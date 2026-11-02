## A plain HTTP/2 (h2c) server for running h2spec against the chronos adapter.
##   nim c -d:release tools/h2specasync.nim && tools/h2specasync 8081 &
##   h2spec -h 127.0.0.1 -p 8081

import std/[os, strutils]
import pkg/chronos
import nimgrpc/h2/async

proc handler(st: AsyncH2Stream; ud: pointer): Future[void] {.async.} =
  while (await st.recvData()).len > 0: discard     # read the whole request
  st.sendHeaders(@[(":status", "200"), ("content-type", "text/plain")])
  await st.send(@[byte('o'), byte('k')], endStream = true)

let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8081
let srv = newAsyncStreamServer(handler, port = Port(port))
echo "listening on ", port
runForever()
