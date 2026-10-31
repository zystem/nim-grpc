## A plain HTTP/2 (h2c) server for running h2spec against the blocking adapter.
##   nim c -d:release tools/h2specserver.nim && tools/h2specserver 8080 &
##   h2spec -h 127.0.0.1 -p 8080

import std/[os, strutils]
import grpc/h2/blocking

proc handler(req: Request): Reply {.nimcall, gcsafe, raises: [].} =
  result.headers = @[(":status", "200"), ("content-type", "text/plain")]
  result.body = @[byte('o'), byte('k')]

let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8080
let srv = newServer(handler, Port(port))
srv.start()
echo "listening on ", port
while true: sleep(1000)
