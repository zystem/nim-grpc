## gzip for gRPC message compression (zlib, see ggz.c).
##
## zlib is linked as `-lz`; with `-d:zlibStatic` the static library is used
## instead (`-d:zlibLib=/path/libz.a` to choose which).

import std/os
import ../status

{.compile: currentSourcePath.parentDir / "ggz.c".}
when defined(zlibStatic):
  const zlibLib {.strdefine.} = "/usr/lib/x86_64-linux-gnu/libz.a"
  {.passl: zlibLib.}
else:
  {.passl: "-lz".}

{.push importc, cdecl, raises: [], gcsafe.}
proc ggz_compress(src: ptr byte; len: csize_t; level: cint;
                  dst: ptr ptr byte; dstLen: ptr csize_t): cint
proc ggz_decompress(src: ptr byte; len: csize_t; max: csize_t;
                    dst: ptr ptr byte; dstLen: ptr csize_t): cint
proc ggz_free(p: pointer)
{.pop.}

proc take(p: ptr byte; n: csize_t): seq[byte] =
  result = newSeq[byte](n.int)
  if n > 0: copyMem(result[0].addr, p, n.int)
  ggz_free(p)

proc gzipCompress*(data: openArray[byte]; level = 6): seq[byte] =
  var p: ptr byte
  var n: csize_t
  let rc = ggz_compress(if data.len > 0: data[0].unsafeAddr else: nil,
                        data.len.csize_t, level.cint, p.addr, n.addr)
  if rc != 0: raise newGrpcError(scInternal, "gzip compression failed (" & $rc & ")")
  take(p, n)

proc gzipDecompress*(data: openArray[byte]; maxLen: int): seq[byte] =
  ## Raises GrpcError: RESOURCE_EXHAUSTED past `maxLen` bytes, INTERNAL if
  ## the data is not valid gzip.
  var p: ptr byte
  var n: csize_t
  let rc = ggz_decompress(if data.len > 0: data[0].unsafeAddr else: nil,
                          data.len.csize_t, maxLen.csize_t, p.addr, n.addr)
  case rc
  of 0: take(p, n)
  of -2: raise newGrpcError(scResourceExhausted,
                            "decompressed message exceeds the limit of " & $maxLen & " bytes")
  of -3: raise newGrpcError(scResourceExhausted, "out of memory decompressing a message")
  else: raise newGrpcError(scInternal, "invalid gzip data in a compressed message")
