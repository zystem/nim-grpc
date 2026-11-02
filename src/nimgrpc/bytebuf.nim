## Byte-buffer helpers for the hot paths. The stdlib `add(openArray)` and
## `setLen` run element by element and zero what they grow; for bulk data
## that dominated the CPU profile, so these use one `copyMem` and leave
## the new space uninitialised until it is overwritten.

proc appendBytes*(dst: var seq[byte]; src: openArray[byte]) =
  ## Appends `src` to `dst` with a single copy.
  if src.len == 0: return
  let start = dst.len
  dst.setLenUninit(start + src.len)
  copyMem(dst[start].addr, src[0].unsafeAddr, src.len)

proc appendBytes*(dst: var seq[byte]; src: pointer; n: int) =
  ## Appends `n` bytes read from `src`.
  if n <= 0: return
  let start = dst.len
  dst.setLenUninit(start + n)
  copyMem(dst[start].addr, src, n)

proc sliceBytes*(src: openArray[byte]; first, len: int): seq[byte] =
  ## A copy of `src[first ..< first + len]`.
  result = newSeqUninit[byte](len)
  if len > 0: copyMem(result[0].addr, src[first].unsafeAddr, len)
