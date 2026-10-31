## Blocking gRPC server: unary methods on a worker pool.
##
## Register methods, then `start`. The method table is frozen once the server
## starts, so workers read it without a lock.

import std/[tables, strutils]
import ./status, ./wire, ./h2/blocking
export status

type
  ServerContext* = object
    path*: string
    metadata*: Metadata      ## from the client, reserved headers removed
    timeoutMs*: int          ## the client's grpc-timeout, or -1
    headers*: Metadata       ## initial metadata to send back
    trailers*: Metadata      ## trailing metadata to send back

  UnaryHandler* = proc (ctx: var ServerContext; request: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].}
    ## Raise GrpcError to answer with a status other than OK; any other
    ## CatchableError becomes UNKNOWN.

  Registry = object
    methods: Table[string, UnaryHandler]
    maxMessage: int

  GrpcServer* = ref object
    reg: Registry
    h2: Server
    started: bool

proc newGrpcServer*(port = 0; address = "127.0.0.1"; workers = 8;
                    maxMessage = defaultMaxMessage): GrpcServer

proc addUnary*(s: GrpcServer; path: string; handler: UnaryHandler) =
  ## `path` is "/package.Service/Method".
  doAssert not s.started, "methods must be registered before start"
  s.reg.methods[path] = handler

proc statusReply(code: StatusCode; msg: string; md: Metadata): Reply =
  ## Trailers-only: one HEADERS block with the status and END_STREAM.
  result.headersOnly = true
  result.headers = @[(":status", "200"), ("content-type", grpcContentType),
                     ("grpc-status", $ord(code))]
  if msg.len > 0: result.headers.add ("grpc-message", encodeStatusMessage(msg))
  result.headers.add md.toWire

proc handle(req: Request; userData: pointer): Reply {.nimcall, gcsafe, raises: [].} =
  let reg = cast[ptr Registry](userData)
  var ctx = ServerContext(timeoutMs: -1)
  var meth, contentType = ""
  for (k, v) in req.headers:
    case k
    of ":path": ctx.path = v
    of ":method": meth = v
    of "content-type": contentType = v
    of "grpc-timeout": ctx.timeoutMs = parseTimeout(v)
    else: discard
  if meth != "POST":
    return Reply(headersOnly: true, headers: @[(":status", "405")])
  if not contentType.startsWith(grpcContentType):
    return Reply(headersOnly: true, headers: @[(":status", "415")])
  let handler = reg.methods.getOrDefault(ctx.path)
  if handler == nil:
    return statusReply(scUnimplemented, "unknown method " & ctx.path, @[])
  ctx.metadata = fromWire(req.headers)

  var msgs: seq[seq[byte]]
  try:
    msgs = decodeMessages(req.body, reg.maxMessage)
  except GrpcError as e:
    return statusReply(e.code, e.msg, @[])
  if msgs.len != 1:
    return statusReply(scInternal, "unary request with " & $msgs.len & " messages", @[])

  var reply: seq[byte]
  try:
    reply = handler(ctx, msgs[0])
  except GrpcError as e:
    return statusReply(e.code, e.msg, ctx.headers & ctx.trailers & e.trailers)
  except CatchableError as e:
    return statusReply(scUnknown, e.msg, ctx.headers & ctx.trailers)

  result.headers = @[(":status", "200"), ("content-type", grpcContentType)]
  result.headers.add ctx.headers.toWire
  result.body = encodeMessage(reply)
  result.trailers = @[("grpc-status", "0")]
  result.trailers.add ctx.trailers.toWire

proc newGrpcServer*(port = 0; address = "127.0.0.1"; workers = 8;
                    maxMessage = defaultMaxMessage): GrpcServer =
  result = GrpcServer()
  result.reg.maxMessage = maxMessage
  result.h2 = newServer(handle, result.reg.addr, Port(port), address, workers)

proc port*(s: GrpcServer): int = s.h2.port.int

proc start*(s: GrpcServer) =
  s.started = true
  s.h2.start()

proc stop*(s: GrpcServer) = s.h2.stop()
