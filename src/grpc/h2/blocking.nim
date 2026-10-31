## Blocking HTTP/2 over TCP.
##
## Per connection: a reader thread and a writer thread.
## * The reader reads the socket, feeds the session and hands events to waiting
##   callers (client) or, once a request is complete, queues it for the
##   server's worker pool.
## * The writer sends whatever the session produced, in order.
## * The connection lock is never held during socket I/O or while a handler
##   runs, so peers writing large bodies cannot deadlock on each other and a slow
##   handler does not stop the connection from reading.
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

const readChunk = 16 * 1024

type
  H2Timeout* = object of H2Error
    ## The deadline passed before the stream completed; it has been reset.

  Response* = object
    headers*: seq[Header]   ## the first HEADERS block (:status ...)
    body*: seq[byte]
    trailers*: seq[Header]  ## the trailing HEADERS block; empty for trailers-only
    errorCode*: uint32      ## non-zero if the stream was reset by the peer

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
    ## Runs on a worker thread. `userData` is what was given to `newServer`.

  StreamState = object
    blocks: seq[seq[Header]]
    body: seq[byte]
    closed: bool
    errorCode: uint32

  ConnObj = object
    sock: Socket
    sess: H2Session
    lock: Lock
    cond: Cond            ## callers waiting for their stream, and the writer
    outQ: Deque[seq[byte]]
    streams: Table[int32, StreamState]
    server: ptr ServerObj ## nil for a client connection
    pending: int          ## server: requests handed to workers, not yet answered
    closed: bool          ## no more reading or writing
    failure: string
    reader, writer: Thread[ptr ConnObj]
  Conn* = ref ConnObj

  Job = object
    conn: ptr ConnObj
    streamId: int32
    req: Request

  ServerObj = object
    listener: Socket
    handler: RequestHandler
    userData: pointer
    conns: seq[Conn]      ## owned by the accept thread until it is joined
    stopping: Atomic[bool]
    acceptor: Thread[ptr ServerObj]
    jobLock: Lock
    jobCond: Cond
    jobs: Deque[Job]
    workersDone: bool     ## guarded by jobLock
    workers: seq[Thread[ptr ServerObj]]
  Server* = ref ServerObj

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

# ------------------------------------------------------------ timed wait

proc deadlineIn(ms: int): Timespec =
  discard clock_gettime(CLOCK_REALTIME, result)
  let ns = result.tv_nsec.int + (ms mod 1000) * 1_000_000
  result.tv_sec = posix.Time(result.tv_sec.int + ms div 1000 + ns div 1_000_000_000)
  result.tv_nsec = ns mod 1_000_000_000

proc waitUntil(c: var Cond; l: var Lock; deadline: Timespec): bool =
  ## Returns false once the deadline has passed.
  let rv = pthread_cond_timedwait(cast[ptr Pthread_cond](c.addr),
                                  cast[ptr Pthread_mutex](l.addr), deadline.unsafeAddr)
  rv != ETIMEDOUT

# ------------------------------------------------------------ internals

template threadBody(body: untyped) =
  ## Frees ORC's per-thread cycle-root buffer when the thread ends; without
  ## it every thread that ever dropped a cyclic object (an exception, say)
  ## leaks that buffer.
  try:
    body
  finally:
    GC_fullCollect()

# Procs ending in `Locked` expect `c.lock` to be held.

proc queueOutputLocked(c: ptr ConnObj) =
  let o = c.sess.takeOutput()
  if o.len > 0:
    c.outQ.addLast o
    broadcast(c.cond)

proc failLocked(c: ptr ConnObj; why: string) =
  if not c.closed:
    c.closed = true
    if c.failure.len == 0: c.failure = why
    for st in c.streams.mvalues: st.closed = true
    broadcast(c.cond)

proc dispatchLocked(c: ptr ConnObj; id: int32) =
  ## Server: the request on `id` is complete; hand it to the worker pool.
  var st: StreamState
  discard c.streams.pop(id, st)
  let req = Request(headers: if st.blocks.len > 0: st.blocks[0] else: @[],
                    body: move st.body)
  inc c.pending
  let s = c.server
  acquire(s.jobLock)
  s.jobs.addLast Job(conn: c, streamId: id, req: req)
  signal(s.jobCond)
  release(s.jobLock)

proc handleEventsLocked(c: ptr ConnObj) =
  let isServer = c.server != nil
  for ev in c.sess.takeEvents():
    if not isServer and ev.streamId notin c.streams:
      continue                    # a stream the caller gave up on
    case ev.kind
    of evHeaders:
      var st = c.streams.mgetOrPut(ev.streamId, StreamState()).addr
      st.blocks.add ev.headers
      if isServer and ev.headersEndStream: c.dispatchLocked(ev.streamId)
    of evData:
      if ev.streamId notin c.streams: continue
      c.streams[ev.streamId].body.add ev.data
      if isServer and ev.dataEndStream: c.dispatchLocked(ev.streamId)
    of evStreamClosed:
      if isServer:
        c.streams.del(ev.streamId)
      else:
        c.streams[ev.streamId].closed = true
        c.streams[ev.streamId].errorCode = ev.errorCode
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
        return
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
      if stop: return

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
      if not ok:
        acquire(c.lock)
        c.failLocked("write error")
        c.outQ.clear()
        release(c.lock)
        break
    # Unblocks the reader if the peer never closes.
    discard posix.shutdown(c.sock.getFd, SHUT_RDWR)

proc newConn(sock: Socket; sess: H2Session; server: ptr ServerObj): Conn =
  result = Conn(sock: sock, sess: sess, server: server)
  initLock(result.lock)
  initCond(result.cond)
  result.outQ = initDeque[seq[byte]]()

proc start(c: Conn) =
  acquire(c.lock)
  c[].addr.queueOutputLocked()     # client preface / SETTINGS
  release(c.lock)
  createThread(c.reader, readerLoop, c[].addr)
  createThread(c.writer, writerLoop, c[].addr)

proc stopThreads(c: Conn) =
  acquire(c.lock)
  if not c.closed:
    try:
      c.sess.goAway()
      c[].addr.queueOutputLocked()
    except CatchableError: discard
    c.closed = true
    broadcast(c.cond)
  release(c.lock)
  joinThread(c.writer)            # drains the queue, then shuts the socket down
  joinThread(c.reader)

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

proc request*(c: Conn; headers: openArray[Header]; body: openArray[byte] = [];
              timeoutMs = -1): Response =
  ## Sends a request and blocks until its stream closes. With `timeoutMs >= 0`
  ## the stream is reset with CANCEL and H2Timeout raised when time runs out.
  let deadline = if timeoutMs >= 0: deadlineIn(timeoutMs) else: Timespec()
  acquire(c.lock)
  if c.closed:
    let why = c.failure
    release(c.lock)
    raise newException(H2Error, "connection closed: " & why)
  var id: int32
  try:
    id = c.sess.submitRequest(headers)
    c.streams[id] = StreamState()
    c.sess.sendData(id, body, endStream = true)
    c[].addr.queueOutputLocked()
  except CatchableError as e:
    release(c.lock)
    raise e
  var timedOut = false
  while not c.streams[id].closed:
    if timeoutMs < 0:
      wait(c.cond, c.lock)
    elif not waitUntil(c.cond, c.lock, deadline):
      timedOut = not c.streams[id].closed
      break
  var st: StreamState
  discard c.streams.pop(id, st)
  if timedOut and not c.closed:
    try:
      c.sess.resetStream(id)
      c[].addr.queueOutputLocked()
    except CatchableError: discard
  let failure = c.failure
  release(c.lock)
  if timedOut:
    raise newException(H2Timeout, "deadline exceeded on stream " & $id)
  if st.blocks.len == 0:
    raise newException(H2Error, "stream " & $id & " ended without a response" &
      (if failure.len > 0: ": " & failure else: ""))
  result.headers = st.blocks[0]
  if st.blocks.len > 1: result.trailers = st.blocks[^1]
  result.body = move st.body
  result.errorCode = st.errorCode

# ------------------------------------------------------------ server

proc workerLoop(s: ptr ServerObj) {.thread.} =
  threadBody:
    while true:
      acquire(s.jobLock)
      while s.jobs.len == 0 and not s.workersDone:
        wait(s.jobCond, s.jobLock)
      if s.jobs.len == 0:
        release(s.jobLock)
        return
      var job = s.jobs.popFirst()
      release(s.jobLock)
      let rep = s.handler(job.req, s.userData)
      let c = job.conn
      acquire(c.lock)
      if not c.closed:
        try:
          let id = job.streamId
          if rep.headersOnly:
            c.sess.submitResponse(id, rep.headers, endStream = true)
          else:
            c.sess.submitResponse(id, rep.headers)
            c.sess.sendData(id, rep.body, endStream = rep.trailers.len == 0)
            if rep.trailers.len > 0: c.sess.sendTrailers(id, rep.trailers)
          c.queueOutputLocked()
        except CatchableError:
          discard                   # the stream was reset meanwhile
      dec c.pending
      broadcast(c.cond)
      release(c.lock)

proc newServer*(handler: RequestHandler; userData: pointer = nil; port = Port(0);
                address = "127.0.0.1"; workers = 8): Server =
  result = Server(handler: handler, userData: userData)
  initLock(result.jobLock)
  initCond(result.jobCond)
  result.jobs = initDeque[Job]()
  result.workers = newSeq[Thread[ptr ServerObj]](workers)
  result.listener = newSocket(buffered = false)
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(port, address)
  result.listener.listen()

proc port*(s: Server): Port = s.listener.getLocalAddr()[1]

proc reap(s: ptr ServerObj) =
  ## Drops connections that are closed and have no request with a worker.
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
  ## Starts the worker pool and accepts connections on a background thread.
  for w in s.workers.mitems: createThread(w, workerLoop, s[].addr)
  createThread(s.acceptor, acceptLoop, s[].addr)

proc stop*(s: Server) =
  s.stopping.store(true)
  discard posix.shutdown(s.listener.getFd, SHUT_RDWR)
  joinThread(s.acceptor)
  s.listener.close()
  for c in s.conns: c.stopThreads()   # connections stop reading and writing
  acquire(s.jobLock)
  s.workersDone = true                # workers drain the queue, then exit
  broadcast(s.jobCond)
  release(s.jobLock)
  joinThreads(s.workers)
  for c in s.conns: c.sock.close()    # no worker can reach a connection now
  s.conns = @[]
