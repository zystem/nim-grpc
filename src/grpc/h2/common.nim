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

proc dropPrefix*(s: var seq[byte]; n: int) =
  let rest = s.len - n
  if rest > 0: moveMem(s[0].addr, s[n].addr, rest)
  s.setLen(rest)
