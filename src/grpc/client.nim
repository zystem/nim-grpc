## Blocking gRPC client.
##
## `unaryCall` covers the common case. `newCall` opens a stream for client-,
## server- and bidirectional streaming: `send` messages, `closeSend`, then
## `recv` until it returns false. A non-OK status is raised as GrpcError from
## whichever call observes the end of the stream.
##
## A `GrpcChannel` may be shared by many threads (pass a `ptr GrpcChannel`);
## each call is its own HTTP/2 stream. A `ClientCall` belongs to one thread
## and must not outlive its channel.

import std/strutils
import ./status, ./wire, ./h2/blocking, ./compress/gzip
export status, blocking.TlsConfig, blocking.tlsClientConfig, blocking.tlsServerConfig, blocking.TlsError

const userAgent = "grpc-nim/0.0.1"

type
  GrpcChannel* = object
    conn: Conn
    authority: string
    scheme: string

  ClientCall* = object
    st: ClientStream
    buf: seq[byte]          ## received bytes not yet decoded
    pos: int
    gotHeaders: bool
    rawHeaders: seq[Header]
    ended: bool             ## the status has been read
    cancelled: bool
    maxMessage: int
    gzipOut: bool           ## the call was opened with compression = "gzip"
    respEncoding: string    ## the server's grpc-encoding
    lastCompressed*: bool   ## whether the last message `recv` returned was compressed
    headers*: Metadata      ## initial metadata, once the first `recv` returned
    trailers*: Metadata     ## trailing metadata, once the call has ended

  UnaryResult* = object
    message*: seq[byte]
    headers*: Metadata
    trailers*: Metadata

proc dial*(host: string; port: int; tls: TlsConfig = nil; serverName = ""): GrpcChannel =
  ## Without `tls`: plaintext HTTP/2 (h2c) with prior knowledge. With it:
  ## TLS 1.2 with ALPN h2; the server certificate must match `serverName`
  ## (default `host`; DNS names only, so use a name such as "localhost"
  ## rather than an IP address). Raises GrpcError(UNAVAILABLE) if the server
  ## cannot be reached; a failed handshake is reported by the first call.
  var conn: Conn
  var why = ""
  try:
    conn = blocking.dial(host, Port(port), tls, serverName)
  except CatchableError as e:
    why = e.msg
  if why.len > 0: raise newGrpcError(scUnavailable, why)
  GrpcChannel(conn: conn, authority: (if serverName.len > 0: serverName else: host) & ":" & $port,
              scheme: if tls != nil: "https" else: "http")

proc close*(ch: GrpcChannel) = ch.conn.close()

proc rstToStatus(code: uint32): StatusCode =
  case code
  of 7: scUnavailable          # REFUSED_STREAM: safe to retry
  of 8: scCancelled            # CANCEL
  of 11: scResourceExhausted   # ENHANCE_YOUR_CALM
  of 12: scPermissionDenied    # INADEQUATE_SECURITY
  else: scInternal

proc newCall*(ch: GrpcChannel; path: string; metadata: Metadata = @[];
              timeoutMs = -1; maxMessage = defaultMaxMessage;
              compression = ""): ClientCall =
  ## Opens a call to `path` ("/package.Service/Method"). `timeoutMs` bounds
  ## the whole call. With `compression = "gzip"` messages are sent
  ## compressed (see `send`); compressed replies are always accepted, and
  ## `maxMessage` limits them after decompression.
  if compression notin ["", "identity", "gzip"]:
    raise newGrpcError(scInvalidArgument, "unsupported compression " & compression.escape)
  var headers = @[(":method", "POST"), (":scheme", ch.scheme), (":path", path),
                  (":authority", ch.authority), ("content-type", grpcContentType),
                  ("te", "trailers"), ("user-agent", userAgent), acceptEncodingHeader]
  if compression == "gzip": headers.add ("grpc-encoding", "gzip")
  if timeoutMs >= 0: headers.add ("grpc-timeout", encodeTimeout(timeoutMs))
  headers.add metadata.toWire
  result.maxMessage = maxMessage
  result.gzipOut = compression == "gzip"
  var why = ""
  try:
    result.st = ch.conn.openStream(headers, timeoutMs)
  except H2Error as e:
    why = e.msg
  if why.len > 0: raise newGrpcError(scUnavailable, why)

proc close*(call: var ClientCall) =
  ## Releases the stream; an unfinished call is cancelled.
  call.st.release()

proc cancel*(call: var ClientCall) =
  ## Resets the call; later `send` and `recv` raise CANCELLED.
  if not call.ended:
    call.st.cancel()
    call.cancelled = true
  call.ended = true
  call.st.release()

proc fail(call: var ClientCall; code: StatusCode; msg: string;
          trailers: Metadata = @[]) {.noreturn.} =
  call.ended = true
  call.st.release()
  raise newGrpcError(code, msg, trailers)

proc readHeaders(call: var ClientCall) =
  if call.gotHeaders: return
  let hs = call.st.recvHeaders()
  call.gotHeaders = true
  call.rawHeaders = hs
  var httpStatus, contentType = ""
  for (k, v) in hs:
    if k == ":status": httpStatus = v
    elif k == "content-type": contentType = v
    elif k == "grpc-encoding": call.respEncoding = v
  call.headers = fromWire(hs)
  if httpStatus != "200":
    call.fail(httpToStatus(httpStatus), "HTTP status " & httpStatus)
  if not contentType.startsWith(grpcContentType):
    call.fail(scUnknown, "unexpected content-type " & contentType.escape)

proc finish(call: var ClientCall) =
  ## Reads the status. Raises GrpcError unless it is OK.
  let tr = call.st.recvTrailers()
  # A trailers-only response carries the status in its only HEADERS block.
  let statusBlock = if tr.len > 0: tr else: call.rawHeaders
  var grpcStatus, grpcMessage = ""
  var have = false
  for (k, v) in statusBlock:
    if k == "grpc-status":
      grpcStatus = v
      have = true
    elif k == "grpc-message":
      grpcMessage = decodeStatusMessage(v)
  call.trailers = fromWire(statusBlock)
  call.ended = true
  call.st.release()
  if not have:
    raise newGrpcError(scInternal, "response without grpc-status", call.trailers)
  var code = scUnknown
  try: code = toStatusCode(parseInt(grpcStatus))
  except ValueError: discard
  if code != scOk:
    raise newGrpcError(code, grpcMessage, call.trailers)

proc raiseMapped(call: var ClientCall; e: ref H2Error) {.noreturn.} =
  if e of H2Timeout:
    call.fail(scDeadlineExceeded, "deadline exceeded")
  if e of H2StreamClosed:
    if call.st.peerEnded:
      # The server finished first (say, with an error status before reading
      # our messages); its status is the answer.
      call.readHeaders()
      call.finish()
      call.fail(scInternal, "server ended the call early with OK")
    let code = call.st.errorCode
    if code == 8 and call.st.deadlinePassed:
      # The server's copy of our deadline fired first and it reset the stream.
      call.fail(scDeadlineExceeded, "deadline exceeded")
    if code != 0: call.fail(rstToStatus(code), "stream reset with HTTP/2 error " & $code)
    call.fail(scUnavailable, e.msg)
  call.fail(scInternal, e.msg)

template mapErrors(call: var ClientCall; body: untyped) =
  ## Turns transport errors into GrpcError. The new error is raised after the
  ## `except` block: raising inside one leaves the thread's current-exception
  ## slot pointing at the old error for good.
  var h2err: ref H2Error
  try:
    body
  except H2Error as e:
    h2err = e
  if h2err != nil: call.raiseMapped(h2err)

proc send*(call: var ClientCall; msg: openArray[byte]; compressed: bool) =
  ## Sends one message, compressed or not. Compressing needs a call opened
  ## with `compression = "gzip"`. If the server has already ended the call,
  ## raises its status (GrpcError).
  if call.cancelled: raise newGrpcError(scCancelled, "call cancelled")
  if call.ended: raise newGrpcError(scInternal, "send after the call ended")
  if compressed and not call.gzipOut:
    raise newGrpcError(scInternal, "a compressed message needs compression = \"gzip\" on the call")
  let framed = if compressed: encodeMessage(gzipCompress(msg), compressed = true)
               else: encodeMessage(msg)
  call.mapErrors:
    call.st.send(framed)

proc send*(call: var ClientCall; msg: openArray[byte]) =
  ## Sends one message, compressed if the call was opened with compression.
  call.send(msg, call.gzipOut)

proc closeSend*(call: var ClientCall) =
  ## No more messages from the client.
  if call.ended: return
  call.mapErrors:
    call.st.closeSend()

proc recv*(call: var ClientCall; msg: var seq[byte]): bool =
  ## The next message from the server; false once the server has ended the
  ## call with OK. Any other status is raised as GrpcError.
  if call.cancelled: raise newGrpcError(scCancelled, "call cancelled")
  if call.ended: return false
  call.mapErrors:
    call.readHeaders()
    while true:
      var payload: seq[byte]
      var compressed = false
      var bad: ref GrpcError
      try:
        if takeFrame(call.buf, call.pos, call.maxMessage, payload, compressed):
          if compressed:
            if call.respEncoding != "gzip":
              raise newGrpcError(scInternal, "compressed message with grpc-encoding " &
                                 call.respEncoding.escape)
            msg = gzipDecompress(payload, call.maxMessage)
          else:
            msg = move payload
          call.lastCompressed = compressed
          return true
      except GrpcError as e:
        bad = e
      if bad != nil:
        call.cancel()
        raise bad
      var chunk: seq[byte]
      if call.st.recvData(chunk):
        call.buf.appendData(call.pos, chunk)
      else:
        if call.buf.len - call.pos > 0:
          call.fail(scInternal, "truncated message at end of stream")
        break
    call.finish()
    return false

proc unaryCall*(ch: GrpcChannel; path: string; request: openArray[byte];
                metadata: Metadata = @[]; timeoutMs = -1;
                maxMessage = defaultMaxMessage; compression = ""): UnaryResult =
  ## Sends one message and returns the one reply. Raises GrpcError for any
  ## status other than OK.
  var call = ch.newCall(path, metadata, timeoutMs, maxMessage, compression)
  try:
    call.send(request)
    call.closeSend()
    if not call.recv(result.message):
      raise newGrpcError(scInternal, "unary call ended without a response")
    var extra: seq[byte]
    if call.recv(extra):
      raise newGrpcError(scInternal, "unary call got more than one response")
    result.headers = call.headers
    result.trailers = call.trailers
  finally:
    call.close()
