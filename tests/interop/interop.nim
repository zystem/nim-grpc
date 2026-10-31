## Interop peer in Nim: a grpc.testing.TestService server (unary methods) and
## a client running the unary interop cases from grpc/grpc
## doc/interop-test-descriptions.md against any server.
##
##   interop server 10000
##   interop client 127.0.0.1 10000 [case,case,...]

import std/[os, strutils]
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

proc newTestServer*(port = 0): GrpcServer =
  result = newGrpcServer(port)
  result.addUnary(svc & "EmptyCall", emptyCall)
  result.addUnary(svc & "UnaryCall", unaryCall)

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

proc runCase*(ch: GrpcChannel; name: string) =
  ## Raises on failure.
  case name
  of "empty_unary":
    let r = ch.unaryCall(svc & "EmptyCall", @[], timeoutMs = 10_000)
    if r.message.len != 0: raise newException(ValueError, "non-empty reply")
  of "large_unary":
    let req = SimpleRequest(responseSize: 314159,
                            payload: Payload(body: newSeq[byte](271828)))
    let r = ch.unaryCall(svc & "UnaryCall", req.encode, timeoutMs = 10_000)
    let n = decodeSimpleResponse(r.message).payload.body.len
    if n != 314159: raise newException(ValueError, "payload " & $n & " bytes")
  of "status_code_and_message", "special_status_message":
    let msg = if name == "status_code_and_message": "test status message"
              else: "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
    let req = SimpleRequest(hasResponseStatus: true,
                            responseStatus: EchoStatus(code: 2, message: msg))
    expectCode(proc () = discard ch.unaryCall(svc & "UnaryCall", req.encode),
               scUnknown, msg)
  of "unimplemented_method":
    expectCode(proc () = discard ch.unaryCall(svc & "UnimplementedCall", @[]),
               scUnimplemented)
  of "unimplemented_service":
    expectCode(proc () = discard ch.unaryCall(
                 "/grpc.testing.UnimplementedService/UnimplementedCall", @[]),
               scUnimplemented)
  of "custom_metadata":
    let req = SimpleRequest(responseSize: 314159,
                            payload: Payload(body: newSeq[byte](271828)))
    let bin = "\xab\xab\xab"
    let r = ch.unaryCall(svc & "UnaryCall", req.encode,
                         @[(initialKey, "test_initial_metadata_value"),
                           (trailingKey, bin)], timeoutMs = 10_000)
    if r.headers.get(initialKey) != "test_initial_metadata_value":
      raise newException(ValueError, "initial metadata " & $r.headers)
    if r.trailers.get(trailingKey) != bin:
      raise newException(ValueError, "trailing metadata " & $r.trailers)
  of "timeout_on_sleeping_server":
    # As in the Go peer: a 1 ms unary call is DEADLINE_EXCEEDED or OK.
    let req = SimpleRequest(responseSize: 31415,
                            payload: Payload(body: newSeq[byte](27182)))
    try:
      discard ch.unaryCall(svc & "UnaryCall", req.encode, timeoutMs = 1)
    except GrpcError as e:
      if e.code != scDeadlineExceeded:
        raise newException(ValueError, "code " & $e.code)
  else:
    raise newException(ValueError, "unknown case " & name)

const allCases* = ["empty_unary", "large_unary", "status_code_and_message",
                   "special_status_message", "unimplemented_method",
                   "unimplemented_service", "custom_metadata",
                   "timeout_on_sleeping_server"]

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
