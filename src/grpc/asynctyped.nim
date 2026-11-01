## Typed calls on chronos, for generated service code (the async twin of
## `grpc/typed`). Message types provide `encode` and `decode` as for the
## blocking API.

import pkg/chronos
import ./status, ./asyncclient, ./asyncserver, ./decode
export status, asyncclient, asyncserver, decode

type
  AsyncClientReader*[Resp] = object
    ## A server-streaming call: `recv` responses until it returns `none`.
    raw*: AsyncCall

  AsyncClientWriter*[Req, Resp] = object
    ## A client-streaming call: `send` requests, then `closeAndRecv`.
    raw*: AsyncCall

  AsyncClientBidi*[Req, Resp] = object
    raw*: AsyncCall

  AsyncServerReader*[Req] = object
    ## The request stream of a client-streaming method.
    raw*: AsyncServerCall

  AsyncServerWriter*[Resp] = object
    ## The response stream of a server-streaming method.
    raw*: AsyncServerCall

  AsyncServerBidi*[Req, Resp] = object
    raw*: AsyncServerCall

# ---------------------------------------------------------------- client

proc unaryCallTyped*[Req, Resp](ch: AsyncChannel; path: string; req: Req;
                                metadata: Metadata; timeoutMs: int;
                                compression = ""):
                                Future[tuple[message: Resp, headers, trailers: Metadata]] {.async.} =
  mixin encode
  let r = await ch.unaryCall(path, encode(req), metadata, timeoutMs, compression = compression)
  return (decodeMsg[Resp](r.message, scInternal), r.headers, r.trailers)

proc recvTyped[T](call: AsyncCall): Future[Option[T]] {.async.} =
  let raw = await call.recv()
  if raw.isSome: return some(decodeMsg[T](raw.get, scInternal))
  return none(T)

proc recv*[Resp](c: AsyncClientReader[Resp]): Future[Option[Resp]] =
  recvTyped[Resp](c.raw)

proc recv*[Req, Resp](c: AsyncClientBidi[Req, Resp]): Future[Option[Resp]] =
  recvTyped[Resp](c.raw)

proc send*[Req, Resp](c: AsyncClientWriter[Req, Resp] | AsyncClientBidi[Req, Resp];
                      msg: Req): Future[void] =
  mixin encode
  c.raw.send(encode(msg))

proc send*[Req, Resp](c: AsyncClientWriter[Req, Resp] | AsyncClientBidi[Req, Resp];
                      msg: Req; compressed: bool): Future[void] =
  mixin encode
  c.raw.send(encode(msg), compressed)

proc closeSend*[Req, Resp](c: AsyncClientBidi[Req, Resp]): Future[void] = c.raw.closeSend()

proc closeAndRecv*[Req, Resp](c: AsyncClientWriter[Req, Resp]): Future[Resp] {.async.} =
  ## Ends the request stream and returns the single response.
  await c.raw.closeSend()
  let raw = await c.raw.recv()
  if raw.isNone:
    raise newGrpcError(scInternal, "client-streaming call ended without a response")
  if (await c.raw.recv()).isSome:
    raise newGrpcError(scInternal, "client-streaming call got more than one response")
  return decodeMsg[Resp](raw.get, scInternal)

template forwardCallProcs(T: untyped) =
  proc close*(c: T) = c.raw.close()
  proc cancel*(c: T) = c.raw.cancel()
  proc headers*(c: T): Metadata = c.raw.headers
  proc trailers*(c: T): Metadata = c.raw.trailers
  proc lastCompressed*(c: T): bool = c.raw.lastCompressed

forwardCallProcs(AsyncClientReader)
forwardCallProcs(AsyncClientWriter)
forwardCallProcs(AsyncClientBidi)

proc openReader*[Req, Resp](ch: AsyncChannel; path: string; req: Req;
                            metadata: Metadata; timeoutMs: int;
                            compression = ""): Future[AsyncClientReader[Resp]] {.async.} =
  mixin encode
  let call = await ch.newCall(path, metadata, timeoutMs, compression = compression)
  await call.send(encode(req))
  await call.closeSend()
  return AsyncClientReader[Resp](raw: call)

proc openWriter*[Req, Resp](ch: AsyncChannel; path: string;
                            metadata: Metadata; timeoutMs: int;
                            compression = ""): Future[AsyncClientWriter[Req, Resp]] {.async.} =
  return AsyncClientWriter[Req, Resp](
    raw: await ch.newCall(path, metadata, timeoutMs, compression = compression))

proc openBidi*[Req, Resp](ch: AsyncChannel; path: string;
                          metadata: Metadata; timeoutMs: int;
                          compression = ""): Future[AsyncClientBidi[Req, Resp]] {.async.} =
  return AsyncClientBidi[Req, Resp](
    raw: await ch.newCall(path, metadata, timeoutMs, compression = compression))

# ---------------------------------------------------------------- server

proc recvReq[T](call: AsyncServerCall): Future[Option[T]] {.async.} =
  let raw = await call.recv()
  if raw.isSome: return some(decodeMsg[T](raw.get, scInternal))
  return none(T)

proc recv*[Req](c: AsyncServerReader[Req]): Future[Option[Req]] = recvReq[Req](c.raw)
proc recv*[Req, Resp](c: AsyncServerBidi[Req, Resp]): Future[Option[Req]] = recvReq[Req](c.raw)

proc send*[Resp](c: AsyncServerWriter[Resp]; msg: Resp): Future[void] =
  mixin encode
  c.raw.send(encode(msg))

proc send*[Resp](c: AsyncServerWriter[Resp]; msg: Resp; compressed: bool): Future[void] =
  ## Compressed only if the response uses gzip (`ctx.responseCompression`).
  mixin encode
  c.raw.send(encode(msg), compressed)

proc send*[Req, Resp](c: AsyncServerBidi[Req, Resp]; msg: Resp): Future[void] =
  mixin encode
  c.raw.send(encode(msg))

proc send*[Req, Resp](c: AsyncServerBidi[Req, Resp]; msg: Resp; compressed: bool): Future[void] =
  mixin encode
  c.raw.send(encode(msg), compressed)

proc isCancelled*[T](c: AsyncServerReader[T] | AsyncServerWriter[T]): bool = c.raw.isCancelled
proc isCancelled*[Req, Resp](c: AsyncServerBidi[Req, Resp]): bool = c.raw.isCancelled

type
  AsyncUnaryFn*[Req, Resp] = proc (ctx: AsyncServerContext; req: Req): Future[Resp]
    {.gcsafe, raises: [].}
  AsyncServerStreamFn*[Req, Resp] = proc (ctx: AsyncServerContext; req: Req;
                                          output: AsyncServerWriter[Resp]): Future[void]
    {.gcsafe, raises: [].}
  AsyncClientStreamFn*[Req, Resp] = proc (ctx: AsyncServerContext;
                                          input: AsyncServerReader[Req]): Future[Resp]
    {.gcsafe, raises: [].}
  AsyncBidiFn*[Req, Resp] = proc (ctx: AsyncServerContext;
                                  call: AsyncServerBidi[Req, Resp]): Future[void]
    {.gcsafe, raises: [].}

proc oneRequest[Req](call: AsyncServerCall): Future[Req] {.async.} =
  let raw = await call.recv()
  if raw.isNone:
    raise newGrpcError(scUnimplemented, "server-streaming call without a request message")
  if (await call.recv()).isSome:
    raise newGrpcError(scUnimplemented, "server-streaming call with more than one request")
  return decodeMsg[Req](raw.get, scInternal)

proc addTypedUnary*[Req, Resp](s: AsyncGrpcServer; path: string; f: AsyncUnaryFn[Req, Resp]) =
  proc adapter(ctx: AsyncServerContext; request: seq[byte]): Future[seq[byte]] {.async.} =
    mixin encode
    let req = decodeMsg[Req](request, scInternal)
    return encode(await f(ctx, req))
  s.addUnary(path, adapter)

proc addTypedServerStream*[Req, Resp](s: AsyncGrpcServer; path: string;
                                      f: AsyncServerStreamFn[Req, Resp]) =
  proc adapter(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
    let req = await oneRequest[Req](call)
    await f(ctx, req, AsyncServerWriter[Resp](raw: call))
  s.addStreaming(path, adapter)

proc addTypedClientStream*[Req, Resp](s: AsyncGrpcServer; path: string;
                                      f: AsyncClientStreamFn[Req, Resp]) =
  proc adapter(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
    mixin encode
    let resp = await f(ctx, AsyncServerReader[Req](raw: call))
    await call.send(encode(resp))
  s.addStreaming(path, adapter)

proc addTypedBidi*[Req, Resp](s: AsyncGrpcServer; path: string; f: AsyncBidiFn[Req, Resp]) =
  proc adapter(ctx: AsyncServerContext; call: AsyncServerCall) {.async.} =
    await f(ctx, AsyncServerBidi[Req, Resp](raw: call))
  s.addStreaming(path, adapter)
