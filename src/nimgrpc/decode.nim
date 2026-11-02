## Decoding a message for the typed APIs.

import ./status, ./protobuf

proc decodeMsg*[T](data: seq[byte]; code: StatusCode): T =
  ## Decodes `data`; malformed input becomes GrpcError(`code`).
  mixin decode
  var bad = ""
  try:
    result = decode(T, data)
  except ProtobufError as e:
    bad = e.msg
  if bad.len > 0: raise newGrpcError(code, "cannot decode " & $T & ": " & bad)
