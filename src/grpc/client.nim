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
import ./status, ./wire, ./h2/blocking
export status

const userAgent = "grpc-nim/0.0.1"

type
  GrpcChannel* = object
    conn: Conn
    authority: string

  ClientCall* = object
    st: ClientStream
    buf: seq[byte]          ## received bytes not yet decoded
    pos: int
    gotHeaders: bool
    rawHeaders: seq[Header]
    ended: bool             ## the status has been read
    cancelled: bool
    maxMessage: int
    headers*: Metadata      ## initial metadata, once the first `recv` returned
    trailers*: Metadata     ## trailing metadata, once the call has ended

  UnaryResult* = object
    message*: seq[byte]
    headers*: Metadata
    trailers*: Metadata

proc dial*(host: string; port: int): GrpcChannel =
  ## Plaintext HTTP/2 (h2c) with prior knowledge.
  GrpcChannel(conn: blocking.dial(host, Port(port)), authority: host & ":" & $port)

proc close*(ch: GrpcChannel) = ch.conn.close()

proc rstToStatus(code: uint32): StatusCode =
  case code
  of 7: scUnavailable          # REFUSED_STREAM: safe to retry
  of 8: scCancelled            # CANCEL
  of 11: scResourceExhausted   # ENHANCE_YOUR_CALM
  of 12: scPermissionDenied    # INADEQUATE_SECURITY
  else: scInternal

proc newCall*(ch: GrpcChannel; path: string; metadata: Metadata = @[];
              timeoutMs = -1; maxMessage = defaultMaxMessage): ClientCall =
  ## Opens a call to `path` ("/package.Service/Method"). `timeoutMs` bounds
  ## the whole call.
  var headers = @[(":method", "POST"), (":scheme", "http"), (":path", path),
                  (":authority", ch.authority), ("content-type", grpcContentType),
                  ("te", "trailers"), ("user-agent", userAgent)]
  if timeoutMs >= 0: headers.add ("grpc-timeout", encodeTimeout(timeoutMs))
  headers.add metadata.toWire
  result.maxMessage = maxMessage
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

proc send*(call: var ClientCall; msg: openArray[byte]) =
  ## Sends one message. If the server has already ended the call, raises its
  ## status (GrpcError).
  if call.cancelled: raise newGrpcError(scCancelled, "call cancelled")
  if call.ended: raise newGrpcError(scInternal, "send after the call ended")
  let framed = encodeMessage(msg)
  call.mapErrors:
    call.st.send(framed)

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
      let avail = call.buf.len - call.pos
      if avail >= 5:
        let b = call.buf
        let p = call.pos
        if b[p] != 0:
          call.fail(scUnimplemented, "compressed message without grpc-encoding")
        let n = (b[p+1].int shl 24) or (b[p+2].int shl 16) or
                (b[p+3].int shl 8) or b[p+4].int
        if n > call.maxMessage:
          call.cancel()
          raise newGrpcError(scResourceExhausted, "message of " & $n &
                             " bytes exceeds the limit of " & $call.maxMessage)
        if avail >= 5 + n:
          msg = call.buf[p + 5 ..< p + 5 + n]
          call.pos += 5 + n
          if call.pos == call.buf.len:
            call.buf.setLen(0)
            call.pos = 0
          return true
      var chunk: seq[byte]
      if call.st.recvData(chunk):
        if call.pos > 0:
          call.buf = call.buf[call.pos .. ^1]
          call.pos = 0
        call.buf.add chunk
      else:
        if call.buf.len - call.pos > 0:
          call.fail(scInternal, "truncated message at end of stream")
        break
    call.finish()
    return false

proc unaryCall*(ch: GrpcChannel; path: string; request: openArray[byte];
                metadata: Metadata = @[]; timeoutMs = -1;
                maxMessage = defaultMaxMessage): UnaryResult =
  ## Sends one message and returns the one reply. Raises GrpcError for any
  ## status other than OK.
  var call = ch.newCall(path, metadata, timeoutMs, maxMessage)
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
