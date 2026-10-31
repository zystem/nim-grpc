## Typed calls for generated service code.
##
## Generated modules provide, for every message type `T`,
## `proc encode(m: T): seq[byte]` and `proc decode(_: typedesc[T]; data: openArray[byte]): T`;
## the wrappers here only frame and unframe them.

import ./status, ./client, ./server, ./protobuf
export status, client, server

type
  ClientReader*[Resp] = object
    ## A server-streaming call: read responses until `recv` returns false.
    raw*: ClientCall

  ClientWriter*[Req, Resp] = object
    ## A client-streaming call: `send` requests, then `closeAndRecv`.
    raw*: ClientCall

  ClientBidi*[Req, Resp] = object
    ## A bidirectional call.
    raw*: ClientCall

  ServerReader*[Req] = object
    ## The request stream of a client-streaming method.
    raw*: ptr ServerCall

  ServerWriter*[Resp] = object
    ## The response stream of a server-streaming method.
    raw*: ptr ServerCall

  ServerBidi*[Req, Resp] = object
    raw*: ptr ServerCall

proc decodeMsg*[T](data: seq[byte]; code: StatusCode): T =
  ## Decodes `data`; malformed input becomes GrpcError(`code`).
  mixin decode
  var bad = ""
  try:
    result = decode(T, data)
  except ProtobufError as e:
    bad = e.msg
  if bad.len > 0: raise newGrpcError(code, "cannot decode " & $T & ": " & bad)

# ---------------------------------------------------------------- client

proc unaryCallTyped*[Req, Resp](ch: GrpcChannel; path: string; req: Req;
                                metadata: Metadata; timeoutMs: int;
                                compression = ""):
                                tuple[message: Resp, headers, trailers: Metadata] =
  mixin encode
  let r = ch.unaryCall(path, encode(req), metadata, timeoutMs, compression = compression)
  (decodeMsg[Resp](r.message, scInternal), r.headers, r.trailers)

proc recv*[Resp](c: var ClientReader[Resp]; msg: var Resp): bool =
  var raw: seq[byte]
  result = c.raw.recv(raw)
  if result: msg = decodeMsg[Resp](raw, scInternal)

proc recv*[Req, Resp](c: var ClientBidi[Req, Resp]; msg: var Resp): bool =
  var raw: seq[byte]
  result = c.raw.recv(raw)
  if result: msg = decodeMsg[Resp](raw, scInternal)

proc send*[Req, Resp](c: var ClientWriter[Req, Resp]; msg: Req) =
  mixin encode
  c.raw.send(encode(msg))

proc send*[Req, Resp](c: var ClientWriter[Req, Resp]; msg: Req; compressed: bool) =
  mixin encode
  c.raw.send(encode(msg), compressed)

proc send*[Req, Resp](c: var ClientBidi[Req, Resp]; msg: Req) =
  mixin encode
  c.raw.send(encode(msg))

proc send*[Req, Resp](c: var ClientBidi[Req, Resp]; msg: Req; compressed: bool) =
  mixin encode
  c.raw.send(encode(msg), compressed)

proc closeSend*[Req, Resp](c: var ClientBidi[Req, Resp]) = c.raw.closeSend()

proc closeAndRecv*[Req, Resp](c: var ClientWriter[Req, Resp]): Resp =
  ## Ends the request stream and returns the single response.
  c.raw.closeSend()
  var raw: seq[byte]
  if not c.raw.recv(raw):
    raise newGrpcError(scInternal, "client-streaming call ended without a response")
  result = decodeMsg[Resp](raw, scInternal)
  var extra: seq[byte]
  if c.raw.recv(extra):
    raise newGrpcError(scInternal, "client-streaming call got more than one response")

template forwardCallProcs(T: untyped) =
  proc close*(c: var T) = c.raw.close()
  proc cancel*(c: var T) = c.raw.cancel()
  proc headers*(c: T): Metadata = c.raw.headers
  proc trailers*(c: T): Metadata = c.raw.trailers
  proc lastCompressed*(c: T): bool = c.raw.lastCompressed

forwardCallProcs(ClientReader)
forwardCallProcs(ClientWriter)
forwardCallProcs(ClientBidi)

proc openReader*[Req, Resp](ch: GrpcChannel; path: string; req: Req;
                            metadata: Metadata; timeoutMs: int;
                            compression = ""): ClientReader[Resp] =
  mixin encode
  result.raw = ch.newCall(path, metadata, timeoutMs, compression = compression)
  result.raw.send(encode(req))
  result.raw.closeSend()

proc openWriter*[Req, Resp](ch: GrpcChannel; path: string;
                            metadata: Metadata; timeoutMs: int;
                            compression = ""): ClientWriter[Req, Resp] =
  result.raw = ch.newCall(path, metadata, timeoutMs, compression = compression)

proc openBidi*[Req, Resp](ch: GrpcChannel; path: string;
                          metadata: Metadata; timeoutMs: int;
                          compression = ""): ClientBidi[Req, Resp] =
  result.raw = ch.newCall(path, metadata, timeoutMs, compression = compression)

# ---------------------------------------------------------------- server

proc recv*[Req](c: var ServerReader[Req]; msg: var Req): bool =
  var raw: seq[byte]
  result = c.raw[].recv(raw)
  if result: msg = decodeMsg[Req](raw, scInternal)

proc recv*[Req, Resp](c: var ServerBidi[Req, Resp]; msg: var Req): bool =
  var raw: seq[byte]
  result = c.raw[].recv(raw)
  if result: msg = decodeMsg[Req](raw, scInternal)

proc send*[Resp](c: var ServerWriter[Resp]; msg: Resp) =
  mixin encode
  c.raw[].send(encode(msg))

proc send*[Resp](c: var ServerWriter[Resp]; msg: Resp; compressed: bool) =
  ## Compressed only if the response uses gzip (`ctx.responseCompression`).
  mixin encode
  c.raw[].send(encode(msg), compressed)

proc send*[Req, Resp](c: var ServerBidi[Req, Resp]; msg: Resp) =
  mixin encode
  c.raw[].send(encode(msg))

proc send*[Req, Resp](c: var ServerBidi[Req, Resp]; msg: Resp; compressed: bool) =
  mixin encode
  c.raw[].send(encode(msg), compressed)

proc isCancelled*[T](c: ServerReader[T] | ServerWriter[T]): bool = c.raw[].isCancelled
proc isCancelled*[Req, Resp](c: ServerBidi[Req, Resp]): bool = c.raw[].isCancelled

type
  # The handler types carry no `raises` list on purpose: with one, Nim
  # (2.2.14) sometimes treats a call through the instantiated generic proc
  # type as unable to raise and drops the error check after it, so a
  # handler's exception went unnoticed and the next `raise` on that thread
  # died with OverflowDefect. Without the list every call is checked; the
  # adapters below catch what the handler raises.
  UnaryFn*[Req, Resp] = proc (ctx: var ServerContext; req: Req): Resp
    {.nimcall, gcsafe.}
  ServerStreamFn*[Req, Resp] = proc (ctx: var ServerContext; req: Req;
                                     output: var ServerWriter[Resp])
    {.nimcall, gcsafe.}
  ClientStreamFn*[Req, Resp] = proc (ctx: var ServerContext;
                                     input: var ServerReader[Req]): Resp
    {.nimcall, gcsafe.}
  BidiFn*[Req, Resp] = proc (ctx: var ServerContext; call: var ServerBidi[Req, Resp])
    {.nimcall, gcsafe.}

template guarded(body: untyped) =
  ## Runs a user handler; whatever it raises is re-raised as CatchableError
  ## (GrpcError passes through unchanged) outside the except block.
  var err: ref CatchableError
  try:
    body
  except CatchableError as e:
    err = e
  except Exception as e:
    err = newGrpcError(scUnknown, e.msg)
  if err != nil: raise err

proc unaryAdapter[Req, Resp](ctx: var ServerContext; request: seq[byte];
                             userData: pointer): seq[byte]
    {.nimcall, gcsafe, raises: [CatchableError].} =
  mixin encode
  let f = cast[UnaryFn[Req, Resp]](userData)
  let req = decodeMsg[Req](request, scInternal)
  var resp: Resp
  guarded:
    resp = f(ctx, req)
  encode(resp)

proc serverStreamAdapter[Req, Resp](ctx: var ServerContext; call: var ServerCall;
                                    userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let f = cast[ServerStreamFn[Req, Resp]](userData)
  var raw: seq[byte]
  if not call.recv(raw):
    raise newGrpcError(scUnimplemented, "server-streaming call without a request message")
  let req = decodeMsg[Req](raw, scInternal)
  var extra: seq[byte]
  if call.recv(extra):
    raise newGrpcError(scUnimplemented, "server-streaming call with more than one request")
  var w = ServerWriter[Resp](raw: call.addr)
  guarded:
    f(ctx, req, w)

proc clientStreamAdapter[Req, Resp](ctx: var ServerContext; call: var ServerCall;
                                    userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  mixin encode
  let f = cast[ClientStreamFn[Req, Resp]](userData)
  var r = ServerReader[Req](raw: call.addr)
  var resp: Resp
  guarded:
    resp = f(ctx, r)
  call.send(encode(resp))

proc bidiAdapter[Req, Resp](ctx: var ServerContext; call: var ServerCall;
                            userData: pointer)
    {.nimcall, gcsafe, raises: [CatchableError].} =
  let f = cast[BidiFn[Req, Resp]](userData)
  var b = ServerBidi[Req, Resp](raw: call.addr)
  guarded:
    f(ctx, b)

proc addTypedUnary*[Req, Resp](s: GrpcServer; path: string; f: UnaryFn[Req, Resp]) =
  s.addUnaryRaw(path, unaryAdapter[Req, Resp], cast[pointer](f))

proc addTypedServerStream*[Req, Resp](s: GrpcServer; path: string;
                                      f: ServerStreamFn[Req, Resp]) =
  s.addStreamingRaw(path, serverStreamAdapter[Req, Resp], cast[pointer](f))

proc addTypedClientStream*[Req, Resp](s: GrpcServer; path: string;
                                      f: ClientStreamFn[Req, Resp]) =
  s.addStreamingRaw(path, clientStreamAdapter[Req, Resp], cast[pointer](f))

proc addTypedBidi*[Req, Resp](s: GrpcServer; path: string; f: BidiFn[Req, Resp]) =
  s.addStreamingRaw(path, bidiAdapter[Req, Resp], cast[pointer](f))
