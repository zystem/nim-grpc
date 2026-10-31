## gRPC wire helpers, and the unary interop cases run in-process.

import std/[unittest, strutils]
import grpc, grpc/wire
import ./interop/interop
import ./gen/grpc/testing/test_pb

suite "wire":
  test "message framing round trip":
    let body = encodeMessage([1'u8, 2, 3]) & encodeMessage([]) & encodeMessage([9'u8])
    check decodeMessages(body) == @[@[1'u8, 2, 3], @[], @[9'u8]]

  test "framing errors map to status codes":
    template code(body: seq[byte]; maxLen = 100): StatusCode =
      var c = scOk
      try: discard decodeMessages(body, maxLen)
      except GrpcError as e: c = e.code
      c
    check code(@[0'u8, 0, 0]) == scInternal                        # short header
    check code(@[0'u8, 0, 0, 0, 5, 1]) == scInternal               # short payload
    check code(@[1'u8, 0, 0, 0, 0]) == scUnimplemented             # compressed
    check code(encodeMessage(newSeq[byte](101))) == scResourceExhausted

  test "grpc-timeout":
    check encodeTimeout(250) == "250m"
    check encodeTimeout(100_000_000) == "100000S"
    check parseTimeout("250m") == 250
    check parseTimeout("2S") == 2000
    check parseTimeout("1H") == 3_600_000
    check parseTimeout("1500u") == 2       # rounded up
    check parseTimeout("1n") == 1
    check parseTimeout("123456789m") == -1 # more than 8 digits
    check parseTimeout("12x") == -1
    check parseTimeout("m") == -1

  test "grpc-message percent-encoding":
    let msg = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n 100%"
    let enc = encodeStatusMessage(msg)
    for ch in enc: check ch in {' ' .. '~'}
    check decodeStatusMessage(enc) == msg
    check decodeStatusMessage("bad %zz and %4") == "bad %zz and %4"

  test "binary metadata is base64 on the wire, reserved keys are dropped":
    let md: Metadata = @[("X-Bin", "\xab\x00\xff"), ("plain", "v"),
                         ("grpc-timeout", "1S"), ("content-type", "x"), (":path", "/")]
    let wire = md.toWire
    check wire == @[("x-bin", "qwD/"), ("plain", "v")]
    check fromWire(wire) == @[("x-bin", "\xab\x00\xff"), ("plain", "v")]

suite "unary interop, Nim client and Nim server":
  var srv: GrpcServer
  var ch: GrpcChannel
  setup:
    srv = newTestServer()
    srv.start()
    ch = dial("127.0.0.1", srv.port)
  teardown:
    ch.close()
    srv.stop()

  for name in allCases:
    test name:
      ch.runCase(name)

  test "an undecodable request is INTERNAL":
    var code = scOk
    try:
      discard ch.unaryCall("/grpc.testing.TestService/UnaryCall",
                           @[0xff'u8, 0xff, 0xff])
    except GrpcError as e:
      code = e.code
    check code == scInternal

proc abortingInput(ctx: var ServerContext;
                   input: var ServerReader[StreamingInputCallRequest]):
                   StreamingInputCallResponse {.nimcall, gcsafe, raises: [CatchableError].} =
  var req: StreamingInputCallRequest
  discard input.recv(req)
  raise newGrpcError(scAborted, "typed handler gave up")

proc failing(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  raise newException(ValueError, "not a gRPC error")

suite "handler errors":
  test "an unexpected exception becomes UNKNOWN and the server keeps going":
    let srv = newGrpcServer()
    srv.addUnary("/t.T/Fail", failing)
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    for i in 0 ..< 50:      # many times on the same workers
      var code = scOk
      var msg = ""
      try:
        discard ch.unaryCall("/t.T/Fail", @[])
      except GrpcError as e:
        code = e.code
        msg = e.msg
      check code == scUnknown
      check msg == "not a gRPC error"
    ch.close()
    srv.stop()

  test "a typed streaming handler that raises, many times on the same workers":
    # Regression: the call through the generic handler type once lost its
    # error check, and the next raise on that worker died with OverflowDefect.
    let srv = newGrpcServer()
    srv.registerTestService(TestServiceHandlers(streamingInputCall: abortingInput))
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    let svc = newTestServiceClient(ch)
    for i in 0 ..< 50:
      var call = svc.streamingInputCall(timeoutMs = 5000)
      call.send StreamingInputCallRequest()
      var code = scOk
      try:
        discard call.closeAndRecv()
      except GrpcError as e:
        code = e.code
      call.close()
      check code == scAborted
    ch.close()
    srv.stop()
