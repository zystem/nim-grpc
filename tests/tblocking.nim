## Blocking client and server over loopback TCP.

import std/[unittest, strutils, typedthreads]
import grpc/h2/blocking

proc toBytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))
proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(result[0].addr, b[0].unsafeAddr, b.len)

proc header(hs: seq[Header]; name: string): string =
  for (k, v) in hs:
    if k == name: return v

proc echoHandler(req: Request): Reply {.nimcall, gcsafe, raises: [].} =
  ## Echoes the body back, upper-cased, with the path in a trailer.
  var path = ""
  for (k, v) in req.headers:
    if k == ":path": path = v
  result.headers = @[(":status", "200"), ("content-type", "application/grpc")]
  result.body = req.body
  for b in result.body.mitems:
    if b >= 'a'.byte and b <= 'z'.byte: b -= 32
  result.trailers = @[("grpc-status", "0"), ("x-path", path)]

proc reqHeaders(port: Port; path: string): seq[Header] =
  @[(":method", "POST"), (":scheme", "http"),
    (":authority", "127.0.0.1:" & $port.int), (":path", path),
    ("content-type", "application/grpc"), ("te", "trailers")]

suite "blocking h2 over tcp":
  var srv: Server
  setup:
    srv = newServer(echoHandler)
    srv.start()
  teardown:
    srv.stop()

  test "one request":
    let c = dial("127.0.0.1", srv.port)
    let r = c.request(reqHeaders(srv.port, "/a.B/C"), "ping".toBytes)
    check r.headers.header(":status") == "200"
    check r.body.toStr == "PING"
    check r.trailers.header("grpc-status") == "0"
    check r.trailers.header("x-path") == "/a.B/C"
    c.close()

  test "bodies far larger than the windows, both ways":
    let c = dial("127.0.0.1", srv.port)
    let big = 'q'.repeat(3_000_000)
    let r = c.request(reqHeaders(srv.port, "/big"), big.toBytes)
    check r.body.len == big.len
    check r.body.toStr == 'Q'.repeat(3_000_000)
    c.close()

  test "many requests from several threads share one connection":
    let c = dial("127.0.0.1", srv.port)
    type Arg = tuple[c: ptr Conn; port: Port; id: int; ok: ptr int]
    proc worker(a: Arg) {.thread.} =
      for i in 0 ..< 50:
        let msg = "t" & $a.id & "m" & $i
        let r = a.c[].request(reqHeaders(a.port, "/w"), msg.toBytes)
        if r.body.toStr == msg.toUpperAscii: inc a.ok[]
    var ths: array[8, Thread[Arg]]
    var oks: array[8, int]
    for i in 0 ..< ths.len:
      createThread(ths[i], worker, (c.addr, srv.port, i, oks[i].addr))
    joinThreads(ths)
    var total = 0
    for k in oks: total += k
    check total == 8 * 50
    c.close()

  test "many connections open and close":
    for i in 0 ..< 200:
      let c = dial("127.0.0.1", srv.port)
      let r = c.request(reqHeaders(srv.port, "/x"), "a".toBytes)
      check r.body.toStr == "A"
      c.close()

  test "request after the server is gone fails cleanly":
    let c = dial("127.0.0.1", srv.port)
    discard c.request(reqHeaders(srv.port, "/x"), "a".toBytes)
    srv.stop()
    srv = newServer(echoHandler)   # teardown stops this one
    srv.start()
    expect H2Error:
      discard c.request(reqHeaders(srv.port, "/x"), "a".toBytes)
    c.close()
