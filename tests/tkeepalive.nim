## Keepalive, ping enforcement, graceful shutdown and reconnecting channels.

import std/[unittest, net, os, times, typedthreads]
import grpc
import ./gen/grpc/testing/test_pb

proc slowUnary(ctx: var ServerContext; req: SimpleRequest): SimpleResponse
    {.nimcall, gcsafe.} =
  ## Sleeps `responseSize` ms, then answers.
  sleep(req.responseSize)
  SimpleResponse(payload: Payload(body: @[1'u8]))

proc echoBidi(ctx: var ServerContext;
              call: var ServerBidi[StreamingOutputCallRequest, StreamingOutputCallResponse])
    {.nimcall, gcsafe.} =
  var req: StreamingOutputCallRequest
  while call.recv(req): call.send StreamingOutputCallResponse()

proc newSlowServer(port = 0; policy = PingPolicy()): GrpcServer =
  result = newGrpcServer(port, pingPolicy = policy)
  result.registerTestService(TestServiceHandlers(unaryCall: slowUnary, fullDuplexCall: echoBidi))
  result.start()

proc codeOf(f: proc () {.raises: [CatchableError].}): StatusCode =
  try:
    f()
    scOk
  except GrpcError as e:
    e.code

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = s.getLocalAddr()[1].int
  s.close()

suite "keepalive":
  test "a healthy connection stays up while pinging":
    let srv = newSlowServer()
    let ch = dial("127.0.0.1", srv.port,
                  keepalive = Keepalive(timeMs: 50, timeoutMs: 500, withoutCalls: true))
    let svc = newTestServiceClient(ch)
    sleep(600)                                   # ~10 pings, all acknowledged
    check svc.unaryCall(SimpleRequest(responseSize: 0)).payload.body == @[1'u8]
    ch.close()
    srv.stop()

  test "an unresponsive peer is detected instead of hanging":
    # A TCP server that accepts and then says nothing at all.
    let silent = newSocket()
    silent.setSockOpt(OptReuseAddr, true)
    silent.bindAddr(Port(0), "127.0.0.1")
    silent.listen()
    let port = silent.getLocalAddr()[1].int
    let ch = dial("127.0.0.1", port,
                  keepalive = Keepalive(timeMs: 100, timeoutMs: 300))
    var client: Socket
    silent.accept(client)
    let t0 = epochTime()
    let code = codeOf(proc () =
      discard newTestServiceClient(ch).unaryCall(SimpleRequest()))   # no deadline
    check code == scUnavailable
    check epochTime() - t0 < 2.0
    ch.close()
    client.close()
    silent.close()

  test "a client that pings too often gets GOAWAY, and the channel recovers":
    let srv = newSlowServer(policy = PingPolicy(minIntervalMs: 10_000))
    let ch = dial("127.0.0.1", srv.port,
                  keepalive = Keepalive(timeMs: 20, timeoutMs: 1000))
    let svc = newTestServiceClient(ch)
    # A quiet call: nothing to read, so the client pings every 20 ms and the
    # server, which allows one ping per 10 s, gives up after three strikes.
    var call = svc.fullDuplexCall(timeoutMs = 5000)
    let t0 = epochTime()
    let code = codeOf(proc () =
      var resp: StreamingOutputCallResponse
      discard call.recv(resp))
    call.close()
    check code == scUnavailable
    check epochTime() - t0 < 2.0
    # The next call goes over a new connection.
    check svc.unaryCall(SimpleRequest(responseSize: 0)).payload.body == @[1'u8]
    ch.close()
    srv.stop()

suite "graceful shutdown and reconnect":
  test "a running call finishes during a graceful stop":
    let srv = newSlowServer()
    let ch = dial("127.0.0.1", srv.port)
    type Arg = tuple[ch: ptr GrpcChannel; code: ptr StatusCode]
    proc caller(a: Arg) {.thread.} =
      try:
        discard newTestServiceClient(a.ch[]).unaryCall(SimpleRequest(responseSize: 300))
        a.code[] = scOk
      except GrpcError as e:
        a.code[] = e.code
      GC_fullCollect()   # ORC keeps a per-thread buffer otherwise
    var code = scUnknown
    var th: Thread[Arg]
    createThread(th, caller, (ch.addr, code.addr))
    sleep(50)
    let t0 = epochTime()
    srv.stop(graceMs = 3000)
    joinThread(th)
    check code == scOk
    check epochTime() - t0 < 1.5                 # returned when the call ended
    ch.close()

  test "the grace period ends: calls still running are cut off":
    let srv = newSlowServer()
    let ch = dial("127.0.0.1", srv.port)
    type Arg = tuple[ch: ptr GrpcChannel; code: ptr StatusCode; failedAt: ptr float]
    proc caller(a: Arg) {.thread.} =
      try:
        discard newTestServiceClient(a.ch[]).unaryCall(SimpleRequest(responseSize: 2000))
        a.code[] = scOk
      except GrpcError as e:
        a.code[] = e.code
      a.failedAt[] = epochTime()
      GC_fullCollect()   # ORC keeps a per-thread buffer otherwise
    var code = scOk
    var failedAt = 0.0
    var th: Thread[Arg]
    createThread(th, caller, (ch.addr, code.addr, failedAt.addr))
    sleep(50)
    let t0 = epochTime()
    # `stop` itself also waits for the handler to return (a thread cannot be
    # interrupted); the client is cut off when the grace period ends.
    srv.stop(graceMs = 200)
    joinThread(th)
    check code == scUnavailable
    check failedAt - t0 < 1.0
    ch.close()

  test "the channel reconnects after the server restarts":
    let port = freePort()
    var srv = newSlowServer(port)
    let ch = dial("127.0.0.1", port)
    let svc = newTestServiceClient(ch)
    check svc.unaryCall(SimpleRequest()).payload.body == @[1'u8]
    srv.stop(graceMs = 1000)
    check codeOf(proc () = discard svc.unaryCall(SimpleRequest())) == scUnavailable
    srv = newSlowServer(port)
    check svc.unaryCall(SimpleRequest()).payload.body == @[1'u8]
    ch.close()
    srv.stop()
