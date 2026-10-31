## Blocking gRPC client: unary calls over one HTTP/2 connection.
##
## A `GrpcChannel` may be shared by many threads (pass a `ptr GrpcChannel`); each call
## is its own HTTP/2 stream.

import std/strutils
import ./status, ./wire, ./h2/blocking
export status

const userAgent = "grpc-nim/0.0.1"

type
  GrpcChannel* = object
    conn: Conn
    authority: string

  UnaryResult* = object
    message*: seq[byte]
    headers*: Metadata    ## initial metadata from the server
    trailers*: Metadata   ## trailing metadata from the server

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

proc unaryCall*(ch: GrpcChannel; path: string; request: openArray[byte];
                metadata: Metadata = @[]; timeoutMs = -1;
                maxMessage = defaultMaxMessage): UnaryResult =
  ## Sends one message to `path` ("/package.Service/Method") and returns the
  ## reply. Raises GrpcError for any status other than OK, including
  ## DEADLINE_EXCEEDED when `timeoutMs` runs out and UNAVAILABLE when the
  ## connection fails.
  var headers = @[(":method", "POST"), (":scheme", "http"), (":path", path),
                  (":authority", ch.authority), ("content-type", grpcContentType),
                  ("te", "trailers"), ("user-agent", userAgent)]
  if timeoutMs >= 0: headers.add ("grpc-timeout", encodeTimeout(timeoutMs))
  headers.add metadata.toWire

  var resp: Response
  try:
    resp = ch.conn.request(headers, encodeMessage(request), timeoutMs)
  except H2Timeout:
    raise newGrpcError(scDeadlineExceeded, "deadline exceeded")
  except H2Error as e:
    raise newGrpcError(scUnavailable, e.msg)

  # A trailers-only response carries the status in its only HEADERS block.
  let statusBlock = if resp.trailers.len > 0: resp.trailers else: resp.headers
  var httpStatus, grpcStatus, grpcMessage = ""
  var haveStatus = false
  for (k, v) in resp.headers:
    if k == ":status": httpStatus = v
  for (k, v) in statusBlock:
    case k
    of "grpc-status":
      grpcStatus = v
      haveStatus = true
    of "grpc-message": grpcMessage = decodeStatusMessage(v)
    else: discard
  let trailers = fromWire(if resp.trailers.len > 0: resp.trailers else: @[])
  result.headers = fromWire(resp.headers)
  result.trailers = trailers

  if httpStatus != "200":
    raise newGrpcError(httpToStatus(httpStatus), "HTTP status " & httpStatus, trailers)
  if not haveStatus:
    if resp.errorCode != 0:
      raise newGrpcError(rstToStatus(resp.errorCode),
                         "stream reset with HTTP/2 error " & $resp.errorCode)
    raise newGrpcError(scInternal, "response without grpc-status", trailers)
  var code = scUnknown
  try: code = toStatusCode(parseInt(grpcStatus))
  except ValueError: discard
  if code != scOk:
    raise newGrpcError(code, grpcMessage,
                       if resp.trailers.len > 0: trailers else: fromWire(resp.headers))

  let msgs = decodeMessages(resp.body, maxMessage)
  if msgs.len != 1:
    raise newGrpcError(scInternal, "unary response with " & $msgs.len & " messages")
  result.message = msgs[0]

