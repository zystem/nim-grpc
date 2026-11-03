## Server limits on the chronos server: streams per connection, connections.

import std/[unittest, atomics]
import pkg/chronos
import nimgrpc/h2/async

proc reqHeaders(port: Port; path: string): seq[Header] =
  @[(":method", "POST"), (":scheme", "http"),
    (":authority", "127.0.0.1:" & $port.int), (":path", path),
    ("content-type", "application/grpc"), ("te", "trailers")]

var running, peak: Atomic[int]
var okCount = 0
var refused, served = false

proc noteStart() =
  let now = running.fetchAdd(1) + 1
  var p = peak.load
  while now > p and not peak.compareExchange(p, now): discard

suite "limits of the chronos server":
  test "no more streams run at once than maxConcurrentStreams":
    running.store(0)
    peak.store(0)
    proc handler(st: AsyncH2Stream; ud: pointer): Future[void] {.async.} =
      noteStart()
      await sleepAsync(150.milliseconds)
      discard running.fetchSub(1)
      st.sendHeaders(@[(":status", "200")])
      st.sendTrailers(@[("grpc-status", "0")])
    let s = newAsyncStreamServer(handler, nil, limits = Limits(maxConcurrentStreams: 2))
    okCount = 0
    proc go(s: AsyncH2Server) {.async.} =
      let c = await dial("127.0.0.1", s.port)
      var fs: seq[Future[void]]
      proc one(c: AsyncH2Conn; port: Port) {.async.} =
        let st = c.openStream(reqHeaders(port, "/w"))
        await st.closeSend()
        discard await st.recvHeaders()
        discard await st.recvTrailers()
        st.release()
        inc okCount
      for i in 0 ..< 6: fs.add one(c, s.port)
      for f in fs: await f
      await c.close()
    waitFor go(s)
    check okCount == 6
    check peak.load <= 2
    waitFor s.stop()

  test "a connection past maxConnections is closed":
    proc handler(st: AsyncH2Stream; ud: pointer): Future[void] {.async.} =
      st.sendHeaders(@[(":status", "200")])
      st.sendTrailers(@[("grpc-status", "0")])
    let s = newAsyncStreamServer(handler, nil, limits = Limits(maxConnections: 1))
    refused = false
    served = false
    proc go(s: AsyncH2Server) {.async.} =
      let a = await dial("127.0.0.1", s.port)
      let st = a.openStream(reqHeaders(s.port, "/a"))
      await st.closeSend()
      discard await st.recvHeaders()
      discard await st.recvTrailers()
      st.release()
      served = true
      try:
        let b = await dial("127.0.0.1", s.port)
        let st2 = b.openStream(reqHeaders(s.port, "/b"))
        await st2.closeSend()
        discard await st2.recvHeaders()
        discard await st2.recvTrailers()
      except CatchableError:
        refused = true
      await a.close()
    waitFor go(s)
    check served
    check refused
    waitFor s.stop()
