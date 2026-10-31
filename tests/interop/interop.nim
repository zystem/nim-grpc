## Interop peer in Nim: a grpc.testing.TestService server (unary methods) and
## a client running the unary interop cases from grpc/grpc
## doc/interop-test-descriptions.md against any server.
##
##   interop server 10000
##   interop client 127.0.0.1 10000 [case,case,...]

import std/[os, strutils, times]
import grpc
import ./testpb

const
  svc = "/grpc.testing.TestService/"
  initialKey = "x-grpc-test-echo-initial"
  trailingKey = "x-grpc-test-echo-trailing-bin"

proc toBytes(s: string): seq[byte] = @(s.toOpenArrayByte(0, s.high))

# ---------------------------------------------------------------- server

proc echoMetadata(ctx: var ServerContext) =
  let a = ctx.metadata.get(initialKey)
  if a.len > 0: ctx.headers.add (initialKey, a)
  let b = ctx.metadata.get(trailingKey)
  if b.len > 0: ctx.trailers.add (trailingKey, b)

proc emptyCall(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  @[]

proc unaryCall(ctx: var ServerContext; req: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ctx.echoMetadata()
  let r = decodeSimpleRequest(req)
  if r.hasResponseStatus and r.responseStatus.code != 0:
    raise newGrpcError(toStatusCode(r.responseStatus.code), r.responseStatus.message)
  SimpleResponse(payload: Payload(body: newSeq[byte](r.responseSize))).encode

proc streamingOutputCall(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var raw: seq[byte]
  if not call.recv(raw): raise newGrpcError(scInvalidArgument, "no request")
  let req = decodeStreamingOutputCallRequest(raw)
  for p in req.responseParameters:
    if p.intervalUs > 0: sleep(p.intervalUs div 1000)
    call.send(StreamingOutputCallResponse(
      payload: Payload(body: newSeq[byte](p.size))).encode)

proc streamingInputCall(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  var raw: seq[byte]
  var total = 0
  while call.recv(raw):
    total += decodeStreamingInputCallRequest(raw).payload.body.len
  call.send(StreamingInputCallResponse(aggregatedPayloadSize: total.int32).encode)

proc fullDuplexCall(ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  ctx.echoMetadata()
  var raw: seq[byte]
  while call.recv(raw):
    let req = decodeStreamingOutputCallRequest(raw)
    if req.hasResponseStatus and req.responseStatus.code != 0:
      raise newGrpcError(toStatusCode(req.responseStatus.code), req.responseStatus.message)
    for p in req.responseParameters:
      if p.intervalUs > 0: sleep(p.intervalUs div 1000)
      call.send(StreamingOutputCallResponse(
        payload: Payload(body: newSeq[byte](p.size))).encode)

proc newTestServer*(port = 0): GrpcServer =
  result = newGrpcServer(port)
  result.addUnary(svc & "EmptyCall", emptyCall)
  result.addUnary(svc & "UnaryCall", unaryCall)
  result.addStreaming(svc & "StreamingOutputCall", streamingOutputCall)
  result.addStreaming(svc & "StreamingInputCall", streamingInputCall)
  result.addStreaming(svc & "FullDuplexCall", fullDuplexCall)

# ---------------------------------------------------------------- client

proc expectCode(f: proc () {.raises: [CatchableError].}; want: StatusCode;
                wantMsg = "") =
  try:
    f()
  except GrpcError as e:
    if e.code != want:
      raise newException(ValueError, "code " & $e.code & " (" & e.msg & "), want " & $want)
    if wantMsg.len > 0 and e.msg != wantMsg:
      raise newException(ValueError, "message " & e.msg.escape & ", want " & wantMsg.escape)
    return
  raise newException(ValueError, "call succeeded, want " & $want)

proc outReq(respSizes: openArray[int32]; payload = 0;
            status = EchoStatus(); hasStatus = false): seq[byte] =
  var r = StreamingOutputCallRequest(payload: Payload(body: newSeq[byte](payload)),
                                     responseStatus: status, hasResponseStatus: hasStatus)
  for n in respSizes: r.responseParameters.add ResponseParameters(size: n)
  r.encode

proc check(cond: bool; what: string) =
  if not cond: raise newException(ValueError, what)

proc respSize(raw: seq[byte]): int =
  decodeStreamingOutputCallResponse(raw).payload.body.len

const
  reqSizes = [27182, 8, 1828, 45904]
  respSizes = [31415'i32, 9, 2653, 58979]

proc runCase*(ch: GrpcChannel; name: string) =
  ## Raises on failure.
  var raw: seq[byte]
  case name
  of "empty_unary":
    let r = ch.unaryCall(svc & "EmptyCall", @[], timeoutMs = 10_000)
    check r.message.len == 0, "non-empty reply"
  of "large_unary":
    let req = SimpleRequest(responseSize: 314159,
                            payload: Payload(body: newSeq[byte](271828)))
    let r = ch.unaryCall(svc & "UnaryCall", req.encode, timeoutMs = 10_000)
    let n = decodeSimpleResponse(r.message).payload.body.len
    check n == 314159, "payload " & $n & " bytes"
  of "status_code_and_message", "special_status_message":
    let msg = if name == "status_code_and_message": "test status message"
              else: "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
    let req = SimpleRequest(hasResponseStatus: true,
                            responseStatus: EchoStatus(code: 2, message: msg))
    expectCode(proc () = discard ch.unaryCall(svc & "UnaryCall", req.encode),
               scUnknown, msg)
    if name == "status_code_and_message":
      expectCode(proc () =
        var call = ch.newCall(svc & "FullDuplexCall", timeoutMs = 10_000)
        defer: call.close()
        call.send(outReq([], status = EchoStatus(code: 2, message: msg), hasStatus = true))
        call.closeSend()
        var m: seq[byte]
        while call.recv(m): discard, scUnknown, msg)
  of "unimplemented_method":
    expectCode(proc () = discard ch.unaryCall(svc & "UnimplementedCall", @[]),
               scUnimplemented)
  of "unimplemented_service":
    expectCode(proc () = discard ch.unaryCall(
                 "/grpc.testing.UnimplementedService/UnimplementedCall", @[]),
               scUnimplemented)
  of "custom_metadata":
    let bin = "\xab\xab\xab"
    let md = @[(initialKey, "test_initial_metadata_value"), (trailingKey, bin)]
    let req = SimpleRequest(responseSize: 314159,
                            payload: Payload(body: newSeq[byte](271828)))
    let r = ch.unaryCall(svc & "UnaryCall", req.encode, md, timeoutMs = 10_000)
    check r.headers.get(initialKey) == "test_initial_metadata_value",
          "unary initial metadata " & $r.headers
    check r.trailers.get(trailingKey) == bin, "unary trailing metadata " & $r.trailers
    var call = ch.newCall(svc & "FullDuplexCall", md, timeoutMs = 10_000)
    defer: call.close()
    call.send(outReq([314159'i32], payload = 271828))
    call.closeSend()
    check call.recv(raw), "no duplex response"
    check raw.respSize == 314159, "duplex payload size"
    check not call.recv(raw), "extra duplex response"
    check call.headers.get(initialKey) == "test_initial_metadata_value",
          "duplex initial metadata " & $call.headers
    check call.trailers.get(trailingKey) == bin, "duplex trailing metadata"
  of "client_streaming":
    var call = ch.newCall(svc & "StreamingInputCall", timeoutMs = 10_000)
    defer: call.close()
    for n in reqSizes:
      call.send(StreamingInputCallRequest(payload: Payload(body: newSeq[byte](n))).encode)
    call.closeSend()
    check call.recv(raw), "no response"
    let total = decodeStreamingInputCallResponse(raw).aggregatedPayloadSize
    check total == 74922, "aggregated " & $total
    check not call.recv(raw), "extra response"
  of "server_streaming":
    var call = ch.newCall(svc & "StreamingOutputCall", timeoutMs = 10_000)
    defer: call.close()
    call.send(outReq(respSizes))
    call.closeSend()
    for n in respSizes:
      check call.recv(raw), "stream ended early"
      check raw.respSize == n, "size " & $raw.respSize & ", want " & $n
    check not call.recv(raw), "extra response"
  of "ping_pong":
    var call = ch.newCall(svc & "FullDuplexCall", timeoutMs = 10_000)
    defer: call.close()
    for i in 0 ..< reqSizes.len:
      call.send(outReq([respSizes[i]], payload = reqSizes[i]))
      check call.recv(raw), "no response to request " & $i
      check raw.respSize == respSizes[i], "size " & $raw.respSize
    call.closeSend()
    check not call.recv(raw), "extra response"
  of "empty_stream":
    var call = ch.newCall(svc & "FullDuplexCall", timeoutMs = 10_000)
    defer: call.close()
    call.closeSend()
    check not call.recv(raw), "response on an empty stream"
  of "cancel_after_begin":
    var call = ch.newCall(svc & "StreamingInputCall", timeoutMs = 10_000)
    call.cancel()
    expectCode(proc () = discard call.recv(raw), scCancelled)
  of "cancel_after_first_response":
    var call = ch.newCall(svc & "FullDuplexCall", timeoutMs = 10_000)
    call.send(outReq([31415'i32], payload = 27182))
    check call.recv(raw), "no first response"
    call.cancel()
    expectCode(proc () = discard call.recv(raw), scCancelled)
  of "timeout_on_sleeping_server":
    var call = ch.newCall(svc & "FullDuplexCall", timeoutMs = 1)
    defer: call.close()
    expectCode(proc () =
      call.send(outReq([], payload = 27182))
      while call.recv(raw): discard, scDeadlineExceeded)
  else:
    raise newException(ValueError, "unknown case " & name)

const allCases* = ["empty_unary", "large_unary", "client_streaming",
                   "server_streaming", "ping_pong", "empty_stream",
                   "cancel_after_begin", "cancel_after_first_response",
                   "timeout_on_sleeping_server", "status_code_and_message",
                   "special_status_message", "unimplemented_method",
                   "unimplemented_service", "custom_metadata"]

proc runClient*(host: string; port: int; only: seq[string] = @[]): int =
  ## Returns the number of failed cases.
  let ch = dial(host, port)
  for name in allCases:
    if only.len > 0 and name notin only: continue
    try:
      ch.runCase(name)
      echo "PASS ", name
    except CatchableError as e:
      echo "FAIL ", name, ": ", e.msg
      inc result
  ch.close()

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: "client"
  if mode == "server":
    let s = newTestServer(if paramCount() >= 2: parseInt(paramStr(2)) else: 10000)
    s.start()
    echo "listening on ", s.port
    while true: sleep(1000)
  else:
    let host = if paramCount() >= 2: paramStr(2) else: "127.0.0.1"
    let port = if paramCount() >= 3: parseInt(paramStr(3)) else: 10000
    let only = if paramCount() >= 4: paramStr(4).split(',') else: @[]
    quit(runClient(host, port, only))
