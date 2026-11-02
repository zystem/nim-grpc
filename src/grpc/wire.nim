## The gRPC-over-HTTP/2 wire details (grpc/grpc doc/PROTOCOL-HTTP2.md):
## length-prefixed messages, grpc-timeout, grpc-message percent-encoding,
## binary metadata and the reserved header names.

import std/[base64, strutils]
import ./status, ./bytebuf

const
  defaultMaxMessage* = 4 * 1024 * 1024
  grpcContentType* = "application/grpc"

# ---------------------------------------------------------------- messages

proc encodeMessage*(msg: openArray[byte]; compressed = false): seq[byte] =
  ## One message frame: flag byte (1 if `msg` is already compressed), 4-byte
  ## big-endian length, payload.
  result = newSeqUninit[byte](5 + msg.len)
  result[0] = byte(ord(compressed))
  let n = msg.len.uint32
  result[1] = byte(n shr 24)
  result[2] = byte(n shr 16)
  result[3] = byte(n shr 8)
  result[4] = byte(n)
  if msg.len > 0: copyMem(result[5].addr, msg[0].unsafeAddr, msg.len)

proc decodeMessages*(body: openArray[byte]; maxLen = defaultMaxMessage): seq[seq[byte]] =
  ## Splits a complete body into messages. Raises GrpcError on a truncated
  ## frame (INTERNAL), a compressed one (UNIMPLEMENTED: no codec is
  ## negotiated) or one above `maxLen` (RESOURCE_EXHAUSTED).
  var i = 0
  while i < body.len:
    if body.len - i < 5:
      raise newGrpcError(scInternal, "truncated message header")
    let flag = body[i]
    let n = (body[i+1].int shl 24) or (body[i+2].int shl 16) or
            (body[i+3].int shl 8) or body[i+4].int
    if flag != 0:
      raise newGrpcError(scUnimplemented, "compressed message without grpc-encoding")
    if n > maxLen:
      raise newGrpcError(scResourceExhausted,
        "message of " & $n & " bytes exceeds the limit of " & $maxLen)
    if body.len - i - 5 < n:
      raise newGrpcError(scInternal, "truncated message")
    result.add @(body.toOpenArray(i + 5, i + 4 + n))
    i += 5 + n

proc takeFrame*(buf: var seq[byte]; pos: var int; maxLen: int;
                payload: var seq[byte]; compressed: var bool): bool =
  ## Takes the next complete message frame from `buf[pos..]`, if there is
  ## one, advancing `pos` and compacting `buf` once all of it is consumed.
  ## Raises GrpcError for a bad flag (INTERNAL) or a declared length above
  ## `maxLen` (RESOURCE_EXHAUSTED).
  let avail = buf.len - pos
  if avail < 5: return false
  let flag = buf[pos]
  if flag > 1: raise newGrpcError(scInternal, "invalid message flag " & $flag)
  let n = (buf[pos+1].int shl 24) or (buf[pos+2].int shl 16) or
          (buf[pos+3].int shl 8) or buf[pos+4].int
  if n > maxLen:
    raise newGrpcError(scResourceExhausted,
      "message of " & $n & " bytes exceeds the limit of " & $maxLen)
  if avail < 5 + n: return false
  payload = sliceBytes(buf, pos + 5, n)
  compressed = flag == 1
  pos += 5 + n
  if pos == buf.len:
    buf.setLen(0)
    pos = 0
  true

proc appendData*(buf: var seq[byte]; pos: var int; chunk: openArray[byte]) =
  ## Appends received bytes, dropping the consumed prefix first.
  if pos > 0:
    let rest = buf.len - pos
    moveMem(buf[0].addr, buf[pos].addr, rest)
    buf.setLen(rest)
    pos = 0
  buf.appendBytes chunk

const supportedEncodings* = ["identity", "gzip"]
const acceptEncodingHeader* = ("grpc-accept-encoding", "gzip")

# ---------------------------------------------------------------- grpc-timeout

proc encodeTimeout*(ms: int): string =
  ## At most 8 digits, as the spec requires.
  if ms < 0: return "0m"
  if ms < 100_000_000: return $ms & "m"
  let s = (ms + 999) div 1000
  if s < 100_000_000: return $s & "S"
  $min((s + 59) div 60, 99_999_999) & "M"

proc parseTimeout*(v: string): int {.raises: [].} =
  ## Milliseconds, rounded up; -1 if the value is malformed.
  if v.len < 2 or v.len > 9: return -1
  let digits = v[0 ..< v.high]
  for ch in digits:
    if ch notin Digits: return -1
  let n = try: parseBiggestInt(digits) except ValueError: return -1
  case v[^1]
  of 'H': int(n * 3_600_000)
  of 'M': int(n * 60_000)
  of 'S': int(n * 1000)
  of 'm': int(n)
  of 'u': int((n + 999) div 1000)
  of 'n': int((n + 999_999) div 1_000_000)
  else: -1

# ---------------------------------------------------------------- grpc-message

proc encodeStatusMessage*(msg: string): string =
  ## Percent-encodes everything outside printable ASCII, and '%' itself.
  for ch in msg:
    if ch >= ' ' and ch <= '~' and ch != '%': result.add ch
    else: result.add '%' & toHex(ord(ch), 2)

proc decodeStatusMessage*(v: string): string =
  ## Lenient: a malformed escape is kept as is.
  var i = 0
  while i < v.len:
    if v[i] == '%' and i + 2 <= v.high and
       v[i+1] in HexDigits and v[i+2] in HexDigits:
      result.add chr(parseHexInt(v[i+1 .. i+2]))
      i += 3
    else:
      result.add v[i]
      inc i

# ---------------------------------------------------------------- metadata

proc isReserved*(key: string): bool =
  ## Headers the library owns; they never appear in user metadata.
  key.len == 0 or key[0] == ':' or key in ["content-type", "te"] or
    (key.startsWith("grpc-") and key != "grpc-status-details-bin")

proc toWire*(md: Metadata): seq[(string, string)] =
  for (k, v) in md:
    let key = k.toLowerAscii
    if key.isReserved: continue
    result.add (key, if key.endsWith("-bin"): encode(v).strip(leading = false, chars = {'='})
                     else: v)

proc fromWire*(headers: openArray[(string, string)]): Metadata =
  for (k, v) in headers:
    if k.isReserved: continue
    if k.endsWith("-bin"):
      var padded = v
      while padded.len mod 4 != 0: padded.add '='
      try: result.add (k, decode(padded))
      except ValueError: discard     # undecodable binary metadata is dropped
    else:
      result.add (k, v)

proc httpToStatus*(httpStatus: string): StatusCode =
  ## The mapping a client uses when a response carries no grpc-status.
  case httpStatus
  of "400": scInternal
  of "401": scUnauthenticated
  of "403": scPermissionDenied
  of "404": scUnimplemented
  of "429", "502", "503", "504": scUnavailable
  else: scUnknown
