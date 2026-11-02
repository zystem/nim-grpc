## Types shared by the blocking and the chronos HTTP/2 adapters.

import ./session

type
  H2Timeout* = object of H2Error
    ## The deadline passed; the stream has been reset with CANCEL.

  H2StreamClosed* = object of H2Error
    ## The stream is gone (reset by the peer, or the connection closed).

  Keepalive* = object
    ## Connection health checks with HTTP/2 PING (gRPC's keepalive).
    timeMs*: int
      ## Send a PING after this long without receiving anything; 0 turns
      ## keepalive off.
    timeoutMs*: int
      ## Close the connection if the PING is not acknowledged within this
      ## time (default 20 s when 0).
    withoutCalls*: bool
      ## Client: ping also while no call is in progress.

  PingPolicy* = object
    ## Server: what clients may do with PINGs (gRPC's enforcement policy).
    minIntervalMs*: int
      ## Pings closer together than this count as strikes; after more than
      ## two the connection gets GOAWAY ENHANCE_YOUR_CALM "too_many_pings".
      ## 0 turns enforcement off.
    permitWithoutCalls*: bool
      ## Pings while no call is in progress are allowed (else they are strikes).

const
  readChunk* = 16 * 1024
  maxOutQueue* = 256 * 1024        ## bytes framed and waiting for the socket
  maxStreamBuffer* = 256 * 1024    ## unsent body bytes per stream before send waits
  INTERNAL_ERROR* = 2'u32
  CANCEL* = 8'u32
  ENHANCE_YOUR_CALM* = 11'u32
  defaultPingTimeoutMs* = 20_000

proc consumed*(s: var seq[byte]; pos: var int; n: int) =
  ## Marks `n` more bytes at the front of `s` as used. The buffer is only
  ## emptied once all of it is used (or, for a long one, half of it is), so
  ## taking it a record at a time does not shift the rest each time.
  pos += n
  if pos >= s.len:
    s.setLen(0)
    pos = 0
  elif pos >= 65536 and pos * 2 >= s.len:
    let rest = s.len - pos
    moveMem(s[0].addr, s[pos].addr, rest)
    s.setLen(rest)
    pos = 0

proc dropPrefix*(s: var seq[byte]; n: int) =
  let rest = s.len - n
  if rest > 0: moveMem(s[0].addr, s[n].addr, rest)
  s.setLen(rest)
