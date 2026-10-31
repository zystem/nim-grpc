## Blocking HTTP/2 over TCP, with streams.
##
## Per connection: a reader thread and a writer thread.
## * The reader reads the socket, feeds the session and files events under the
##   stream they belong to; a server starts a handler for every new request
##   stream as soon as its HEADERS arrive.
## * The writer sends what the session produced, in order. At most
##   `maxOutQueue` bytes wait for the socket; the rest stays in nghttp2, and a
##   sender waits while its stream has more than `maxStreamBuffer` unsent bytes.
##   A slow peer therefore slows the sender down instead of growing memory.
## * The connection lock is never held during socket I/O or while a handler
##   runs.
##
## Lock order: a connection lock may be held while taking the server's job
## lock, never the other way round.
##
## Threads get `ptr`, never `ref`; a `ref` stays with its single owner (the
## caller for a client, the server for accepted connections), so no reference
## count is touched from two threads.

import std/[locks, net, tables, deques, os, posix, atomics]
import ./session

export session.Header, session.H2Error, net.Port

const
  readChunk = 16 * 1024
  maxOutQueue = 256 * 1024        ## bytes framed and waiting for the socket
  maxStreamBuffer = 256 * 1024    ## unsent body bytes per stream before send waits
  INTERNAL_ERROR = 2'u32
  CANCEL = 8'u32

type
  H2Timeout* = object of H2Error
    ## The deadline passed; the stream has been reset with CANCEL.

  H2StreamClosed* = object of H2Error
    ## The stream is gone (reset by the peer, or the connection closed).

  StreamState = object
    blocks: seq[seq[Header]]   ## HEADERS blocks received
    inbuf: seq[byte]           ## body bytes received and not yet taken
    inEnded: bool              ## END_STREAM received
    outEnded: bool             ## we sent END_STREAM (or trailers)
    responded: bool            ## server: response HEADERS submitted
    closed: bool               ## the stream is closed
    errorCode: uint32          ## RST_STREAM / GOAWAY code, 0 on a clean close
    handled: bool              ## server: a handler owns the stream

  ConnObj = object
    sock: Socket
    sess: H2Session
    lock: Lock
    cond: Cond            ## every waiter on this connection, and the writer
    outQ: Deque[seq[byte]]
    outQBytes: int
    streams: Table[int32, StreamState]
    server: ptr ServerObj ## nil for a client connection
    lastDispatched: int32 ## server: highest stream id handed to a handler
    pending: int          ## server: handlers still running for this connection
    closed: bool          ## no more reading or writing
    failure: string
    reader, writer: Thread[ptr ConnObj]
  Conn* = ref ConnObj

  # ---- server side

  ServerStream* = object
    ## The handler's view of one request stream. Valid only inside the handler.
    conn: ptr ConnObj
    id*: int32
    headers*: seq[Header]   ## the request HEADERS
    deadline: Timespec
    hasDeadline: bool

  StreamHandler* = proc (st: var ServerStream; userData: pointer)
    {.nimcall, gcsafe, raises: [].}
    ## Runs on a worker thread from the moment the request HEADERS arrive.
    ## If it returns without ending the response, the stream is reset with
    ## INTERNAL_ERROR.

  Job = object
    conn: ptr ConnObj
    id: int32
    headers: seq[Header]

  WorkerThread = ref object
    th: Thread[ptr ServerObj]

  ServerObj = object
    listener: Socket
    handler: StreamHandler
    userData: pointer
    conns: seq[Conn]      ## owned by the accept thread until it is joined
    stopping: Atomic[bool]
    acceptor: Thread[ptr ServerObj]
    jobLock: Lock
    jobCond: Cond
    jobs: Deque[Job]
    idle: int             ## workers waiting for a job
    maxWorkers: int
    workersDone: bool
    workers: seq[WorkerThread]
    simple: RequestHandler   ## set when built from a whole-request handler
    simpleData: pointer
  Server* = ref ServerObj

  # ---- whole-request convenience API

  Request* = object
    headers*: seq[Header]
    body*: seq[byte]

  Reply* = object
    headers*: seq[Header]
    body*: seq[byte]
    trailers*: seq[Header]
    headersOnly*: bool      ## send `headers` with END_STREAM and nothing else

  RequestHandler* = proc (req: Request; userData: pointer): Reply
    {.nimcall, gcsafe, raises: [].}

  Response* = object
    headers*: seq[Header]   ## the first HEADERS block (:status ...)
    body*: seq[byte]
    trailers*: seq[Header]  ## the trailing HEADERS block; empty for trailers-only
    errorCode*: uint32      ## non-zero if the stream was reset by the peer

  # ---- client side

  ClientStream* = object
    ## One request stream opened by `openStream`. Use from one thread; the
    ## connection must outlive it. It holds a `ptr`, not a `ref`: streams live
    ## on many threads, and ORC reference counts are not atomic.
    conn: ptr ConnObj
    id*: int32
    deadline: Timespec
    hasDeadline: bool
    released: bool

proc `=destroy`(c: ConnObj) =
  `=destroy`(c.sock.addr[])
  deinitLock(c.lock.addr[])
  deinitCond(c.cond.addr[])
  `=destroy`(c.sess.addr[])
  `=destroy`(c.outQ.addr[])
  `=destroy`(c.streams.addr[])
  `=destroy`(c.failure.addr[])

proc `=copy`(dst: var ConnObj; src: ConnObj) {.error.}

proc `=destroy`(s: ServerObj) =
  `=destroy`(s.listener.addr[])
  `=destroy`(s.conns.addr[])
  deinitLock(s.jobLock.addr[])
  deinitCond(s.jobCond.addr[])
  `=destroy`(s.jobs.addr[])
  `=destroy`(s.workers.addr[])

proc `=copy`(dst: var ServerObj; src: ServerObj) {.error.}

converter toPtr(c: Conn): ptr ConnObj = c[].addr
  ## Internal procs take `ptr ConnObj`; the owner's `ref` converts.

# ------------------------------------------------------------ time

proc deadlineIn*(ms: int): Timespec =
  ## An absolute CLOCK_REALTIME deadline `ms` from now.
  discard clock_gettime(CLOCK_REALTIME, result)
  let ns = result.tv_nsec.int + (ms mod 1000) * 1_000_000
  result.tv_sec = posix.Time(result.tv_sec.int + ms div 1000 + ns div 1_000_000_000)
  result.tv_nsec = ns mod 1_000_000_000

proc waitUntil(c: var Cond; l: var Lock; deadline: Timespec): bool =
  ## False once the deadline has passed.
  pthread_cond_timedwait(cast[ptr Pthread_cond](c.addr),
                         cast[ptr Pthread_mutex](l.addr), deadline.unsafeAddr) != ETIMEDOUT

template threadBody(body: untyped) =
  ## Frees ORC's per-thread cycle-root buffer when the thread ends; without
  ## it every thread that ever dropped a cyclic object (an exception, say)
  ## leaks that buffer. Also drops the thread's current-exception slot, which
  ## a `raise` inside an `except` block can leave pointing at a dead exception.
  try:
    body
  finally:
    setCurrentException(nil)
    GC_fullCollect()

# ------------------------------------------------------------ connection internals
# Procs ending in `Locked` expect `c.lock` to be held.

proc queueOutputLocked(c: ptr ConnObj) =
  if c.outQBytes >= maxOutQueue: return   # the writer pulls more as it drains
  let o = c.sess.takeOutput()
  if o.len > 0:
    c.outQBytes += o.len
    c.outQ.addLast o
  broadcast(c.cond)     # senders may now be under their buffer limit

proc failLocked(c: ptr ConnObj; why: string) =
  if not c.closed:
    c.closed = true
    if c.failure.len == 0: c.failure = why
    for st in c.streams.mvalues: st.closed = true
    broadcast(c.cond)

proc waitLocked(c: ptr ConnObj; hasDeadline: bool; deadline: Timespec): bool =
  ## One wait on the connection condition; false if the deadline passed.
  if hasDeadline: waitUntil(c.cond, c.lock, deadline)
  else:
    wait(c.cond, c.lock)
    true

proc streamPtr(c: ptr ConnObj; id: int32): ptr StreamState =
  ## nil if the stream is unknown. Never raises.
  c.streams.withValue(id, v):
    return v
  nil

proc workerLoop(s: ptr ServerObj) {.thread.}

proc dispatchLocked(c: ptr ConnObj; id: int32; headers: seq[Header]) =
  let s = c.server
  c.streamPtr(id).handled = true
  c.lastDispatched = id
  inc c.pending
  acquire(s.jobLock)
  s.jobs.addLast Job(conn: c, id: id, headers: headers)
  if s.jobs.len > s.idle and s.workers.len < s.maxWorkers:
    let w = WorkerThread()
    s.workers.add w
    createThread(w.th, workerLoop, s)
  signal(s.jobCond)
  release(s.jobLock)

proc handleEventsLocked(c: ptr ConnObj) =
  let isServer = c.server != nil
  for ev in c.sess.takeEvents():
    let known = ev.streamId in c.streams
    case ev.kind
    of evHeaders:
      if known:
        let st = c.streamPtr(ev.streamId)
        st.blocks.add ev.headers
        if ev.headersEndStream: st.inEnded = true
      elif isServer and ev.streamId > c.lastDispatched:
        c.streams[ev.streamId] = StreamState(blocks: @[ev.headers],
                                             inEnded: ev.headersEndStream)
        c.dispatchLocked(ev.streamId, ev.headers)
    of evData:
      if known:
        let st = c.streamPtr(ev.streamId)
        st.inbuf.add ev.data
        if ev.dataEndStream: st.inEnded = true
    of evStreamClosed:
      if known:
        let st = c.streamPtr(ev.streamId)
        st.closed = true
        st.errorCode = ev.errorCode
        if isServer and not st.handled: c.streams.del(ev.streamId)
  broadcast(c.cond)

proc readerLoop(c: ptr ConnObj) {.thread.} =
  threadBody:
    var buf = newSeq[byte](readChunk)
    while true:
      var n = 0
      try:
        n = c.sock.recv(buf[0].addr, buf.len)
      except CatchableError:
        n = -1
      acquire(c.lock)
      if n <= 0 or c.closed:
        c.failLocked(if n == 0: "connection closed by peer" else: "read error")
        release(c.lock)
        break
      try:
        c.sess.recv(buf.toOpenArray(0, n - 1))
        c.handleEventsLocked()
        c.queueOutputLocked()
        if not c.sess.wantRead() and not c.sess.wantWrite() and c.outQ.len == 0:
          c.failLocked("session finished")
      except CatchableError as e:
        # A connection error: nghttp2 has queued a GOAWAY; send it, then stop.
        try: c.queueOutputLocked()
        except CatchableError: discard
        c.failLocked(e.msg)
      let stop = c.closed
      release(c.lock)
      if stop: break

proc writerLoop(c: ptr ConnObj) {.thread.} =
  threadBody:
    while true:
      acquire(c.lock)
      while c.outQ.len == 0 and not c.closed:
        wait(c.cond, c.lock)
      if c.outQ.len == 0:           # closed and drained
        release(c.lock)
        break
      let chunk = c.outQ.popFirst()
      release(c.lock)
      var off = 0
      var ok = true
      while off < chunk.len:
        let k = try: c.sock.send(chunk[off].unsafeAddr, chunk.len - off)
                except CatchableError: -1
        if k <= 0:
          ok = false
          break
        off += k
      acquire(c.lock)
      c.outQBytes -= chunk.len
      if ok:
        try: c.queueOutputLocked()
        except CatchableError as e: c.failLocked(e.msg)
      else:
        c.failLocked("write error")
        c.outQ.clear()
        c.outQBytes = 0
      release(c.lock)
      if not ok: break
    # Unblocks the reader if the peer never closes.
    discard posix.shutdown(c.sock.getFd, SHUT_RDWR)

proc newConn(sock: Socket; sess: H2Session; server: ptr ServerObj): Conn =
  result = Conn(sock: sock, sess: sess, server: server)
  initLock(result.lock)
  initCond(result.cond)
  result.outQ = initDeque[seq[byte]]()

proc start(c: Conn) =
  acquire(c.lock)
  c.queueOutputLocked()     # client preface / SETTINGS
  release(c.lock)
  createThread(c.reader, readerLoop, c[].addr)
  createThread(c.writer, writerLoop, c[].addr)

proc stopThreads(c: Conn) =
  acquire(c.lock)
  if not c.closed:
    try:
      c.sess.goAway()
      c.outQBytes = 0                  # GOAWAY must get out
      c.queueOutputLocked()
    except CatchableError: discard
    c.closed = true
    for st in c.streams.mvalues: st.closed = true
    broadcast(c.cond)
  release(c.lock)
  joinThread(c.writer)            # drains the queue, then shuts the socket down
  joinThread(c.reader)

# ------------------------------------------------------------ shared stream I/O


proc closedError(c: ptr ConnObj; st: ptr StreamState; id: int32): ref H2StreamClosed =
  let why = if st != nil and st.errorCode != 0: "reset with error " & $st.errorCode
            elif c.failure.len > 0: c.failure
            else: "closed"
  newException(H2StreamClosed, "stream " & $id & ": " & why)

proc timeoutLocked(c: ptr ConnObj; id: int32): ref H2Timeout =
  if not c.closed and id in c.streams and not c.streamPtr(id).closed:
    try:
      c.sess.resetStream(id, CANCEL)
      c.queueOutputLocked()
    except CatchableError: discard
    c.streamPtr(id).closed = true
    c.streamPtr(id).errorCode = CANCEL
  newException(H2Timeout, "deadline exceeded on stream " & $id)

proc sendLocked(c: ptr ConnObj; id: int32; data: openArray[byte]; endStream: bool;
                hasDeadline: bool; deadline: Timespec) =
  ## Queues body bytes, waiting while the stream's unsent buffer is full.
  var off = 0
  while true:
    let s = c.streamPtr(id)          # re-read: the table may grow while we wait
    if s == nil or s.closed or c.closed: raise c.closedError(s, id)
    if s.outEnded: raise newException(H2Error, "stream " & $id & ": body already ended")
    let room = maxStreamBuffer - c.sess.buffered(id)
    let remaining = data.len - off
    if room > 0 or remaining == 0:
      let n = min(max(room, 0), remaining)
      let last = n == remaining
      if n > 0 or (last and endStream):
        c.sess.sendData(id, data.toOpenArray(off, off + n - 1),
                        endStream = last and endStream)
        off += n
        if last and endStream: s.outEnded = true
        c.queueOutputLocked()
      if last: return
    if not c.waitLocked(hasDeadline, deadline):
      raise c.timeoutLocked(id)

proc recvLocked(c: ptr ConnObj; id: int32; buf: var seq[byte];
                hasDeadline: bool; deadline: Timespec): bool =
  ## Moves received body bytes into `buf` (replacing its contents). False when
  ## the body has ended and everything has been taken.
  while true:
    if id notin c.streams:
      raise c.closedError(nil, id)
    let st = c.streamPtr(id)
    if st.inbuf.len > 0:
      buf = move st.inbuf
      st.inbuf = @[]
      return true
    if st.inEnded: return false
    if st.closed: raise c.closedError(st, id)
    if not c.waitLocked(hasDeadline, deadline):
      raise c.timeoutLocked(id)

# ------------------------------------------------------------ server streams

proc setTimeout*(st: var ServerStream; ms: int) =
  ## Bounds every later blocking call on this stream.
  if ms >= 0:
    st.deadline = deadlineIn(ms)
    st.hasDeadline = true

proc recvData*(st: var ServerStream; buf: var seq[byte]): bool =
  ## Blocks for the next part of the request body; false at its end.
  let c = st.conn
  acquire(c.lock)
  try:
    result = c.recvLocked(st.id, buf, st.hasDeadline, st.deadline)
  finally:
    release(c.lock)

proc isClosed*(st: ServerStream): bool =
  ## True once the stream is gone (for example the client cancelled).
  let c = st.conn
  acquire(c.lock)
  result = c.closed or st.id notin c.streams or c.streamPtr(st.id).closed
  release(c.lock)

proc sendHeaders*(st: var ServerStream; headers: openArray[Header]; endStream = false) =
  ## The response HEADERS. With `endStream` nothing else follows
  ## (a gRPC trailers-only response).
  let c = st.conn
  acquire(c.lock)
  try:
    if st.id notin c.streams or c.streamPtr(st.id).closed or c.closed:
      raise c.closedError(c.streamPtr(st.id), st.id)
    let s = c.streamPtr(st.id)
    if s.responded: raise newException(H2Error, "response HEADERS already sent")
    c.sess.submitResponse(st.id, headers, endStream)
    s.responded = true
    if endStream: s.outEnded = true
    c.queueOutputLocked()
  finally:
    release(c.lock)

proc sendData*(st: var ServerStream; data: openArray[byte]; endStream = false) =
  let c = st.conn
  acquire(c.lock)
  try:
    c.sendLocked(st.id, data, endStream, st.hasDeadline, st.deadline)
  finally:
    release(c.lock)

proc sendTrailers*(st: var ServerStream; trailers: openArray[Header]) =
  ## Ends the response with a trailing HEADERS block.
  let c = st.conn
  acquire(c.lock)
  try:
    if st.id notin c.streams or c.streamPtr(st.id).closed or c.closed:
      raise c.closedError(c.streamPtr(st.id), st.id)
    let s = c.streamPtr(st.id)
    if s.outEnded: raise newException(H2Error, "response already ended")
    c.sess.sendTrailers(st.id, trailers)
    s.outEnded = true
    c.queueOutputLocked()
  finally:
    release(c.lock)

proc reset*(st: var ServerStream; errorCode = CANCEL) =
  let c = st.conn
  acquire(c.lock)
  if st.id in c.streams and not c.streamPtr(st.id).closed and not c.closed:
    try:
      c.sess.resetStream(st.id, errorCode)
      c.queueOutputLocked()
    except CatchableError: discard
    c.streamPtr(st.id).outEnded = true
  release(c.lock)

proc finishHandlerLocked(c: ptr ConnObj; id: int32) =
  ## The handler for `id` has returned.
  if id in c.streams:
    let s = c.streamPtr(id)
    if not s.outEnded and not s.closed and not c.closed:
      try:
        c.sess.resetStream(id, INTERNAL_ERROR)
        c.queueOutputLocked()
      except CatchableError: discard
    c.streams.del(id)      # a late close event finds nothing and is ignored
  dec c.pending
  broadcast(c.cond)

proc workerLoop(s: ptr ServerObj) {.thread.} =
  threadBody:
    while true:
      acquire(s.jobLock)
      inc s.idle
      while s.jobs.len == 0 and not s.workersDone:
        wait(s.jobCond, s.jobLock)
      dec s.idle
      if s.jobs.len == 0:
        release(s.jobLock)
        break
      var job = s.jobs.popFirst()
      release(s.jobLock)
      var st = ServerStream(conn: job.conn, id: job.id, headers: move job.headers)
      s.handler(st, s.userData)
      let c = job.conn
      acquire(c.lock)
      c.finishHandlerLocked(job.id)
      release(c.lock)

# ------------------------------------------------------------ whole-request server API

proc readRequest*(st: var ServerStream): Request =
  ## Reads the whole request body.
  result.headers = st.headers
  var chunk: seq[byte]
  while st.recvData(chunk): result.body.add chunk

proc respond*(st: var ServerStream; rep: Reply) =
  if rep.headersOnly:
    st.sendHeaders(rep.headers, endStream = true)
  else:
    st.sendHeaders(rep.headers)
    st.sendData(rep.body, endStream = rep.trailers.len == 0)
    if rep.trailers.len > 0: st.sendTrailers(rep.trailers)

proc simpleTrampoline(st: var ServerStream; userData: pointer)
    {.nimcall, gcsafe, raises: [].} =
  let s = cast[ptr ServerObj](userData)
  try:
    let req = st.readRequest()
    st.respond(s.simple(req, s.simpleData))
  except CatchableError:
    discard          # the stream is gone; the worker resets it if needed

# ------------------------------------------------------------ server

proc newStreamServer*(handler: StreamHandler; userData: pointer = nil;
                      port = Port(0); address = "127.0.0.1";
                      maxWorkers = 256): Server =
  ## Every request stream gets a worker thread for as long as its handler
  ## runs; the pool grows on demand up to `maxWorkers` threads.
  result = Server(handler: handler, userData: userData, maxWorkers: maxWorkers)
  initLock(result.jobLock)
  initCond(result.jobCond)
  result.jobs = initDeque[Job]()
  result.listener = newSocket(buffered = false)
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(port, address)
  result.listener.listen()

proc newServer*(handler: RequestHandler; userData: pointer = nil; port = Port(0);
                address = "127.0.0.1"; maxWorkers = 256): Server =
  ## A server whose handler sees the whole request and returns the whole reply.
  result = newStreamServer(simpleTrampoline, nil, port, address, maxWorkers)
  result.userData = result[].addr
  result.simple = handler
  result.simpleData = userData

proc port*(s: Server): Port = s.listener.getLocalAddr()[1]

proc reap(s: ptr ServerObj) =
  ## Drops connections that are closed and have no handler running.
  var keep: seq[Conn]
  for c in s.conns:
    acquire(c.lock)
    let done = c.closed and c.pending == 0
    release(c.lock)
    if done:
      c.stopThreads()
      c.sock.close()
    else:
      keep.add c
  s.conns = keep

proc acceptLoop(s: ptr ServerObj) {.thread.} =
  threadBody:
    while true:
      var client: Socket
      try:
        s.listener.accept(client)
      except CatchableError:
        if s.stopping.load: break
        sleep(10)
        continue
      if s.stopping.load:
        client.close()
        break
      client.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
      s.reap()
      let c = newConn(client, newServerSession(), s)
      c.start()
      s.conns.add c

proc start*(s: Server) =
  ## Accepts connections on a background thread.
  createThread(s.acceptor, acceptLoop, s[].addr)

proc stop*(s: Server) =
  s.stopping.store(true)
  discard posix.shutdown(s.listener.getFd, SHUT_RDWR)
  joinThread(s.acceptor)
  s.listener.close()
  for c in s.conns: c.stopThreads()   # streams close; handlers see it and return
  acquire(s.jobLock)
  s.workersDone = true                # workers drain the queue, then exit
  broadcast(s.jobCond)
  release(s.jobLock)
  for w in s.workers: joinThread(w.th)
  for c in s.conns: c.sock.close()    # no worker can reach a connection now
  s.conns = @[]

# ------------------------------------------------------------ client

proc close*(c: Conn) =
  ## Sends GOAWAY, stops both threads and closes the socket.
  c.stopThreads()
  c.sock.close()

proc isClosed*(c: Conn): bool =
  acquire(c.lock)
  result = c.closed
  release(c.lock)

proc dial*(host: string; port: Port): Conn =
  ## Connects with HTTP/2 prior knowledge (h2c).
  let sock = newSocket(buffered = false)
  sock.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
  sock.connect(host, port)
  result = newConn(sock, newClientSession(), nil)
  result.start()

proc openStream*(c: Conn; headers: openArray[Header]; timeoutMs = -1): ClientStream =
  ## Sends the request HEADERS; the body follows with `send`. With
  ## `timeoutMs >= 0` every blocking call on the stream shares that deadline.
  result = ClientStream(conn: c[].addr)
  if timeoutMs >= 0:
    result.deadline = deadlineIn(timeoutMs)
    result.hasDeadline = true
  acquire(c.lock)
  try:
    if c.closed:
      raise newException(H2StreamClosed, "connection closed: " & c.failure)
    result.id = c.sess.submitRequest(headers)
    c.streams[result.id] = StreamState()
    c.queueOutputLocked()
  finally:
    release(c.lock)

proc send*(st: var ClientStream; data: openArray[byte]; endStream = false) =
  let c = st.conn
  acquire(c.lock)
  try:
    c.sendLocked(st.id, data, endStream, st.hasDeadline, st.deadline)
  finally:
    release(c.lock)

proc closeSend*(st: var ClientStream) =
  ## Ends the request body (half-close).
  st.send([], endStream = true)

proc recvHeaders*(st: var ClientStream): seq[Header] =
  ## Blocks for the response HEADERS.
  let c = st.conn
  acquire(c.lock)
  try:
    while true:
      if st.id notin c.streams: raise c.closedError(nil, st.id)
      let s = c.streamPtr(st.id)
      if s.blocks.len > 0: return s.blocks[0]
      if s.closed: raise c.closedError(s, st.id)
      if not c.waitLocked(st.hasDeadline, st.deadline):
        raise c.timeoutLocked(st.id)
  finally:
    release(c.lock)

proc recvData*(st: var ClientStream; buf: var seq[byte]): bool =
  ## Blocks for the next part of the response body; false at its end.
  let c = st.conn
  acquire(c.lock)
  try:
    result = c.recvLocked(st.id, buf, st.hasDeadline, st.deadline)
  finally:
    release(c.lock)

proc recvTrailers*(st: var ClientStream): seq[Header] =
  ## Blocks until the response has ended; the trailing HEADERS block, or empty
  ## for a trailers-only response. Raises H2StreamClosed if the stream was
  ## reset first.
  let c = st.conn
  acquire(c.lock)
  try:
    while true:
      let s = c.streamPtr(st.id)
      if s == nil: raise c.closedError(nil, st.id)
      if s.inEnded: return (if s.blocks.len > 1: s.blocks[^1] else: @[])
      if s.closed: raise c.closedError(s, st.id)
      if not c.waitLocked(st.hasDeadline, st.deadline):
        raise c.timeoutLocked(st.id)
  finally:
    release(c.lock)

proc errorCode*(st: ClientStream): uint32 =
  ## The RST_STREAM / GOAWAY code the stream ended with, 0 if none.
  let c = st.conn
  acquire(c.lock)
  let s = c.streamPtr(st.id)
  result = if s != nil: s.errorCode else: 0
  release(c.lock)

proc deadlinePassed*(st: ClientStream): bool =
  ## True if the stream has a deadline and it is now past.
  if not st.hasDeadline: return false
  var now: Timespec
  discard clock_gettime(CLOCK_REALTIME, now)
  now.tv_sec.int > st.deadline.tv_sec.int or
    (now.tv_sec.int == st.deadline.tv_sec.int and now.tv_nsec >= st.deadline.tv_nsec)

proc peerEnded*(st: ClientStream): bool =
  ## True once the server has ended its side (END_STREAM received).
  let c = st.conn
  acquire(c.lock)
  let s = c.streamPtr(st.id)
  result = s != nil and s.inEnded
  release(c.lock)

proc cancel*(st: var ClientStream) =
  ## Resets the stream with CANCEL.
  let c = st.conn
  acquire(c.lock)
  if st.id in c.streams and not c.streamPtr(st.id).closed and not c.closed:
    try:
      c.sess.resetStream(st.id, CANCEL)
      c.queueOutputLocked()
    except CatchableError: discard
    c.streamPtr(st.id).closed = true
    c.streamPtr(st.id).errorCode = CANCEL
  release(c.lock)

proc release*(st: var ClientStream) =
  ## Forgets the stream. A stream still open is cancelled first.
  if st.released: return
  st.released = true
  let c = st.conn
  acquire(c.lock)
  if st.id in c.streams:
    let s = c.streamPtr(st.id)
    if not s.closed and not (s.inEnded and s.outEnded) and not c.closed:
      try:
        c.sess.resetStream(st.id, CANCEL)
        c.queueOutputLocked()
      except CatchableError: discard
    c.streams.del(st.id)
  release(c.lock)

proc request*(c: Conn; headers: openArray[Header]; body: openArray[byte] = [];
              timeoutMs = -1): Response =
  ## Sends a whole request and blocks for the whole response. A stream reset
  ## by the peer is returned with `errorCode` set; a closed connection raises
  ## H2StreamClosed, a passed deadline H2Timeout.
  var st = c.openStream(headers, timeoutMs)
  var failure: ref H2StreamClosed
  try:
    st.send(body, endStream = true)
    result.headers = st.recvHeaders()
    var chunk: seq[byte]
    while st.recvData(chunk): result.body.add chunk
    result.trailers = st.recvTrailers()
  except H2StreamClosed as e:
    acquire(c.lock)
    let s = c.streamPtr(st.id)
    let resetByPeer = s != nil and s.errorCode != 0 and not c.closed
    if resetByPeer:
      result.errorCode = s.errorCode
      if result.headers.len == 0 and s.blocks.len > 0: result.headers = s.blocks[0]
    release(c.lock)
    if not resetByPeer: failure = e
  finally:
    st.release()
  if failure != nil: raise failure
