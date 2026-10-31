## Blocking gRPC server.
##
## Every call runs on its own worker thread from the moment its HEADERS
## arrive. Register methods, then `start`; the method table is frozen once the
## server starts, so workers read it without a lock.
##
## * `addUnary`: one request message in, one reply out.
## * `addStreaming`: the handler gets a `ServerCall` and may `recv` and `send`
##   any number of messages in any order; this covers client-, server- and
##   bidirectional streaming.
##
## A handler ends the call by returning (status OK) or by raising GrpcError
## (any other status). Any other CatchableError becomes UNKNOWN.

import std/[tables, strutils]
import ./status, ./wire, ./h2/blocking, ./compress/gzip
export status, blocking.TlsConfig, blocking.tlsClientConfig, blocking.tlsServerConfig, blocking.TlsError

type
  ServerContext* = object
    path*: string
    metadata*: Metadata      ## from the client, reserved headers removed
    timeoutMs*: int          ## the client's grpc-timeout, or -1
    headers*: Metadata       ## initial metadata to send back (before the first message)
    trailers*: Metadata      ## trailing metadata to send back
    requestCompressed*: bool ## whether the last request message was compressed
    responseCompression*: string
      ## "gzip" to compress responses; set before the first message is sent.
      ## Ignored if the client does not accept gzip.

  ServerCall* = object
    st: ptr ServerStream
    ctx: ptr ServerContext
    buf: seq[byte]
    pos: int
    inEnded: bool
    headersSent: bool
    maxMessage: int
    reqEncoding: string      ## the client's grpc-encoding
    clientAcceptsGzip: bool
    gzipOut: bool            ## responses carry grpc-encoding: gzip

  UnaryHandler* = proc (ctx: var ServerContext; request: seq[byte]): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].}

  StreamingHandler* = proc (ctx: var ServerContext; call: var ServerCall)
    {.nimcall, gcsafe, raises: [CatchableError].}

  RawUnaryHandler* = proc (ctx: var ServerContext; request: seq[byte];
                           userData: pointer): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].}
    ## Like UnaryHandler, plus the pointer given at registration (used by
    ## generated code to reach the typed handler).

  RawStreamingHandler* = proc (ctx: var ServerContext; call: var ServerCall;
                               userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].}

  MethodKind = enum mkUnary, mkStreaming
  Method = object
    userData: pointer
    case kind: MethodKind
    of mkUnary: unary: RawUnaryHandler
    of mkStreaming: streaming: RawStreamingHandler

  Registry = object
    methods: Table[string, Method]
    maxMessage: int

  GrpcServer* = ref object
    reg: Registry
    h2: Server
    started: bool

# ---------------------------------------------------------------- ServerCall

proc toGrpc(e: ref H2Error): ref GrpcError =
  if e of H2Timeout: newGrpcError(scDeadlineExceeded, "deadline exceeded")
  else: newGrpcError(scCancelled, "call cancelled: " & e.msg)

proc recv*(call: var ServerCall; msg: var seq[byte]): bool =
  ## The next message from the client; false once the client has half-closed.
  ## Raises GrpcError (CANCELLED, DEADLINE_EXCEEDED, ...) if the call is gone.
  while true:
    var payload: seq[byte]
    var compressed = false
    if takeFrame(call.buf, call.pos, call.maxMessage, payload, compressed):
      if compressed:
        if call.reqEncoding != "gzip":
          raise newGrpcError(scInternal, "compressed message with grpc-encoding " &
                             call.reqEncoding.escape)
        msg = gzipDecompress(payload, call.maxMessage)
      else:
        msg = move payload
      call.ctx.requestCompressed = compressed
      return true
    if call.inEnded:
      if call.buf.len - call.pos > 0:
        raise newGrpcError(scInternal, "truncated message at end of stream")
      return false
    var chunk: seq[byte]
    var more: bool
    var err: ref GrpcError
    try:
      more = call.st[].recvData(chunk)
    except H2Error as e:
      err = e.toGrpc       # raised outside the except block (see threadBody)
    if err != nil: raise err
    if more: call.buf.appendData(call.pos, chunk)
    else: call.inEnded = true

proc sendResponseHeaders(call: var ServerCall) =
  if call.headersSent: return
  var hs = @[(":status", "200"), ("content-type", grpcContentType), acceptEncodingHeader]
  if call.ctx.responseCompression == "gzip" and call.clientAcceptsGzip:
    hs.add ("grpc-encoding", "gzip")
    call.gzipOut = true
  hs.add call.ctx.headers.toWire
  var err: ref GrpcError
  try:
    call.st[].sendHeaders(hs)
  except H2Error as e:
    err = e.toGrpc
  if err != nil: raise err
  call.headersSent = true

proc send*(call: var ServerCall; msg: openArray[byte]; compressed: bool) =
  ## Sends one message, compressed if `compressed` and the response uses gzip
  ## (`ctx.responseCompression`, accepted by the client); otherwise plain.
  call.sendResponseHeaders()
  let framed = if compressed and call.gzipOut:
                 encodeMessage(gzipCompress(msg), compressed = true)
               else: encodeMessage(msg)
  var err: ref GrpcError
  try:
    call.st[].sendData(framed)
  except H2Error as e:
    err = e.toGrpc
  if err != nil: raise err

proc send*(call: var ServerCall; msg: openArray[byte]) =
  ## Sends one message; the initial metadata (`ctx.headers`) goes out first.
  ## Compressed when the response uses gzip (see `ctx.responseCompression`).
  call.sendResponseHeaders()
  call.send(msg, call.gzipOut)

proc isCancelled*(call: ServerCall): bool =
  ## True once the client has gone away or reset the call.
  call.st[].isClosed

proc finishCall(call: var ServerCall; code: StatusCode; msg: string; md: Metadata) =
  ## Ends the call with a status: trailers after a response, or trailers-only.
  var hs: seq[Header]
  if not call.headersSent:
    hs = @[(":status", "200"), ("content-type", grpcContentType), acceptEncodingHeader]
  hs.add ("grpc-status", $ord(code))
  if msg.len > 0: hs.add ("grpc-message", encodeStatusMessage(msg))
  hs.add md.toWire
  try:
    if call.headersSent: call.st[].sendTrailers(hs)
    else: call.st[].sendHeaders(hs, endStream = true)
  except H2Error:
    discard     # the client is gone; nothing left to tell it

# ---------------------------------------------------------------- dispatch

proc handle(st: var ServerStream; userData: pointer) {.nimcall, gcsafe, raises: [].} =
  let reg = cast[ptr Registry](userData)
  var ctx = ServerContext(timeoutMs: -1)
  var meth, contentType, encoding = ""
  var acceptsGzip = false
  for (k, v) in st.headers:
    case k
    of ":path": ctx.path = v
    of ":method": meth = v
    of "content-type": contentType = v
    of "grpc-timeout": ctx.timeoutMs = parseTimeout(v)
    of "grpc-encoding": encoding = v
    of "grpc-accept-encoding":
      for e in v.split(','):
        if e.strip == "gzip": acceptsGzip = true
    else: discard
  try:
    if meth != "POST":
      st.sendHeaders(@[(":status", "405")], endStream = true)
      return
    if not contentType.startsWith(grpcContentType):
      st.sendHeaders(@[(":status", "415")], endStream = true)
      return
  except H2Error:
    return
  st.setTimeout(ctx.timeoutMs)
  ctx.metadata = fromWire(st.headers)
  var call = ServerCall(st: st.addr, ctx: ctx.addr, maxMessage: reg.maxMessage,
                        reqEncoding: encoding, clientAcceptsGzip: acceptsGzip)

  if encoding.len > 0 and encoding notin supportedEncodings:
    call.finishCall(scUnimplemented, "grpc-encoding " & encoding.escape &
                    " is not supported", @[])
    return
  if ctx.path notin reg.methods:
    call.finishCall(scUnimplemented, "unknown method " & ctx.path, @[])
    return
  let m = reg.methods.getOrDefault(ctx.path)
  try:
    case m.kind
    of mkUnary:
      var req: seq[byte]
      if not call.recv(req):
        raise newGrpcError(scUnimplemented, "unary call without a request message")
      var extra: seq[byte]
      if call.recv(extra):
        raise newGrpcError(scUnimplemented, "unary call with more than one request message")
      let reply = m.unary(ctx, req, m.userData)
      call.send(reply)
    of mkStreaming:
      m.streaming(ctx, call, m.userData)
    call.finishCall(scOk, "", ctx.trailers)
  except GrpcError as e:
    call.finishCall(e.code, e.msg, ctx.trailers & e.trailers)
  except CatchableError as e:
    call.finishCall(scUnknown, e.msg, ctx.trailers)

# ---------------------------------------------------------------- server

proc newGrpcServer*(port = 0; address = "127.0.0.1"; maxWorkers = 256;
                    maxMessage = defaultMaxMessage; tls: TlsConfig = nil): GrpcServer =
  ## At most `maxWorkers` calls run at once; more wait for a free worker.
  ## With `tls` (see `tlsServerConfig`) clients must use TLS 1.2 with ALPN h2.
  result = GrpcServer()
  result.reg.maxMessage = maxMessage
  result.h2 = newStreamServer(handle, result.reg.addr, Port(port), address,
                              maxWorkers, tls)

proc addUnaryRaw*(s: GrpcServer; path: string; handler: RawUnaryHandler;
                  userData: pointer) =
  doAssert not s.started, "methods must be registered before start"
  s.reg.methods[path] = Method(kind: mkUnary, unary: handler, userData: userData)

proc addStreamingRaw*(s: GrpcServer; path: string; handler: RawStreamingHandler;
                      userData: pointer) =
  doAssert not s.started, "methods must be registered before start"
  s.reg.methods[path] = Method(kind: mkStreaming, streaming: handler, userData: userData)

proc callUnary(ctx: var ServerContext; request: seq[byte]; userData: pointer): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  cast[UnaryHandler](userData)(ctx, request)

proc callStreaming(ctx: var ServerContext; call: var ServerCall; userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  cast[StreamingHandler](userData)(ctx, call)

proc addUnary*(s: GrpcServer; path: string; handler: UnaryHandler) =
  ## `path` is "/package.Service/Method".
  s.addUnaryRaw(path, callUnary, cast[pointer](handler))

proc addStreaming*(s: GrpcServer; path: string; handler: StreamingHandler) =
  s.addStreamingRaw(path, callStreaming, cast[pointer](handler))

proc port*(s: GrpcServer): int = s.h2.port.int

proc start*(s: GrpcServer) =
  s.started = true
  s.h2.start()

proc stop*(s: GrpcServer) = s.h2.stop()
