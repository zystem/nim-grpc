## Hand-written Protobuf codec for the grpc.testing messages the unary interop
## cases use (src/proto/grpc/testing/messages.proto in grpc/grpc). Unknown
## fields are skipped. Code generation will replace this.

type
  Payload* = object
    body*: seq[byte]
  EchoStatus* = object
    code*: int32
    message*: string
  SimpleRequest* = object
    responseSize*: int32
    payload*: Payload
    responseStatus*: EchoStatus
    hasResponseStatus*: bool
  SimpleResponse* = object
    payload*: Payload

  PbError* = object of CatchableError

# ---------------------------------------------------------------- primitives

proc putVarint(b: var seq[byte]; v: uint64) =
  var x = v
  while x >= 0x80:
    b.add byte(x and 0x7f or 0x80)
    x = x shr 7
  b.add byte(x)

proc putTag(b: var seq[byte]; field, wire: int) = b.putVarint(uint64(field shl 3 or wire))

proc putBytes(b: var seq[byte]; field: int; data: openArray[byte]) =
  b.putTag(field, 2)
  b.putVarint(data.len.uint64)
  b.add data

proc putInt(b: var seq[byte]; field: int; v: int64) =
  if v != 0:
    b.putTag(field, 0)
    b.putVarint(cast[uint64](v))

type Reader = object
  data: seq[byte]
  pos: int

proc getVarint(r: var Reader): uint64 =
  var shift = 0
  while true:
    if r.pos >= r.data.len or shift > 63: raise newException(PbError, "bad varint")
    let b = r.data[r.pos]
    inc r.pos
    result = result or (uint64(b and 0x7f) shl shift)
    if b < 0x80: return
    shift += 7

proc getLen(r: var Reader): seq[byte] =
  let n = r.getVarint().int
  if n < 0 or r.pos + n > r.data.len: raise newException(PbError, "bad length")
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

proc skip(r: var Reader; wire: int) =
  case wire
  of 0: discard r.getVarint()
  of 1: r.pos += 8
  of 2: discard r.getLen()
  of 5: r.pos += 4
  else: raise newException(PbError, "bad wire type " & $wire)
  if r.pos > r.data.len: raise newException(PbError, "truncated")

iterator fields(data: seq[byte]): (int, int, ptr Reader) =
  var r = Reader(data: data)
  while r.pos < r.data.len:
    let tag = r.getVarint()
    yield (int(tag shr 3), int(tag and 7), r.addr)

proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(result[0].addr, b[0].unsafeAddr, b.len)

# ---------------------------------------------------------------- messages

proc encode*(m: Payload): seq[byte] =
  if m.body.len > 0: result.putBytes(2, m.body)

proc decodePayload*(data: seq[byte]): Payload =
  for (f, w, r) in fields(data):
    if f == 2 and w == 2: result.body = r[].getLen()
    else: r[].skip(w)

proc encode*(m: EchoStatus): seq[byte] =
  result.putInt(1, m.code)
  if m.message.len > 0: result.putBytes(2, m.message.toOpenArrayByte(0, m.message.high))

proc decodeEchoStatus*(data: seq[byte]): EchoStatus =
  for (f, w, r) in fields(data):
    if f == 1 and w == 0: result.code = cast[int32](r[].getVarint())
    elif f == 2 and w == 2: result.message = r[].getLen().toStr
    else: r[].skip(w)

proc encode*(m: SimpleRequest): seq[byte] =
  result.putInt(2, m.responseSize)
  result.putBytes(3, m.payload.encode)
  if m.hasResponseStatus: result.putBytes(7, m.responseStatus.encode)

proc decodeSimpleRequest*(data: seq[byte]): SimpleRequest =
  for (f, w, r) in fields(data):
    if f == 2 and w == 0: result.responseSize = cast[int32](r[].getVarint())
    elif f == 3 and w == 2: result.payload = decodePayload(r[].getLen())
    elif f == 7 and w == 2:
      result.responseStatus = decodeEchoStatus(r[].getLen())
      result.hasResponseStatus = true
    else: r[].skip(w)

proc encode*(m: SimpleResponse): seq[byte] =
  result.putBytes(1, m.payload.encode)

proc decodeSimpleResponse*(data: seq[byte]): SimpleResponse =
  for (f, w, r) in fields(data):
    if f == 1 and w == 2: result.payload = decodePayload(r[].getLen())
    else: r[].skip(w)

# ---------------------------------------------------------------- streaming messages

type
  ResponseParameters* = object
    size*: int32
    intervalUs*: int32
  StreamingOutputCallRequest* = object
    responseParameters*: seq[ResponseParameters]
    payload*: Payload
    responseStatus*: EchoStatus
    hasResponseStatus*: bool
  StreamingOutputCallResponse* = object
    payload*: Payload
  StreamingInputCallRequest* = object
    payload*: Payload
  StreamingInputCallResponse* = object
    aggregatedPayloadSize*: int32

proc encode*(m: ResponseParameters): seq[byte] =
  result.putInt(1, m.size)
  result.putInt(2, m.intervalUs)

proc decodeResponseParameters*(data: seq[byte]): ResponseParameters =
  for (f, w, r) in fields(data):
    if f == 1 and w == 0: result.size = cast[int32](r[].getVarint())
    elif f == 2 and w == 0: result.intervalUs = cast[int32](r[].getVarint())
    else: r[].skip(w)

proc encode*(m: StreamingOutputCallRequest): seq[byte] =
  for p in m.responseParameters: result.putBytes(2, p.encode)
  if m.payload.body.len > 0: result.putBytes(3, m.payload.encode)
  if m.hasResponseStatus: result.putBytes(7, m.responseStatus.encode)

proc decodeStreamingOutputCallRequest*(data: seq[byte]): StreamingOutputCallRequest =
  for (f, w, r) in fields(data):
    if f == 2 and w == 2: result.responseParameters.add decodeResponseParameters(r[].getLen())
    elif f == 3 and w == 2: result.payload = decodePayload(r[].getLen())
    elif f == 7 and w == 2:
      result.responseStatus = decodeEchoStatus(r[].getLen())
      result.hasResponseStatus = true
    else: r[].skip(w)

proc encode*(m: StreamingOutputCallResponse): seq[byte] =
  result.putBytes(1, m.payload.encode)

proc decodeStreamingOutputCallResponse*(data: seq[byte]): StreamingOutputCallResponse =
  for (f, w, r) in fields(data):
    if f == 1 and w == 2: result.payload = decodePayload(r[].getLen())
    else: r[].skip(w)

proc encode*(m: StreamingInputCallRequest): seq[byte] =
  result.putBytes(1, m.payload.encode)

proc decodeStreamingInputCallRequest*(data: seq[byte]): StreamingInputCallRequest =
  for (f, w, r) in fields(data):
    if f == 1 and w == 2: result.payload = decodePayload(r[].getLen())
    else: r[].skip(w)

proc encode*(m: StreamingInputCallResponse): seq[byte] =
  result.putInt(1, m.aggregatedPayloadSize)

proc decodeStreamingInputCallResponse*(data: seq[byte]): StreamingInputCallResponse =
  for (f, w, r) in fields(data):
    if f == 1 and w == 0: result.aggregatedPayloadSize = cast[int32](r[].getVarint())
    else: r[].skip(w)
