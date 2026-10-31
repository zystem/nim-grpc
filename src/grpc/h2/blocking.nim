## Blocking HTTP/2 over TCP: one reader and one writer thread per connection.
##
## * The reader thread reads the socket, feeds the session, hands events to
##   waiting callers (client) or to the request handler (server).
## * The writer thread sends whatever the session produced. Output is queued
##   under the connection lock in the order the session produced it.
## * The connection lock is never held during socket I/O, so two peers that
##   both write large bodies cannot deadlock on each other.
##
## Threads get a `ptr ConnObj`; the `ref` stays with the owner (the caller for a
## client, the server for accepted connections), so no reference count is ever
## touched from two threads.

import std/[locks, net, tables, deques, os, posix, atomics]
import ./session

export session.Header, session.H2Error, net.Port

const readChunk = 16 * 1024

type
  Response* = object
    headers*: seq[Header]   ## the first HEADERS block (:status ...)
    body*: seq[byte]
    trailers*: seq[Header]  ## the trailing HEADERS block, if any
    errorCode*: uint32      ## non-zero if the stream was reset

  Request* = object
    headers*: seq[Header]
    body*: seq[byte]

  Reply* = object
    headers*: seq[Header]
    body*: seq[byte]
    trailers*: seq[Header]

  RequestHandler* = proc (req: Request): Reply {.nimcall, gcsafe, raises: [].}

  StreamState = object
    blocks: seq[seq[Header]]
    body: seq[byte]
    closed: bool
    errorCode: uint32

  ConnObj = object
    sock: Socket
    sess: H2Session
    lock: Lock
    cond: Cond            ## callers waiting for their stream; the writer
    outQ: Deque[seq[byte]]
    streams: Table[int32, StreamState]
    handler: RequestHandler
    closed: bool          ## no more reading or writing
    failure: string
    reader, writer: Thread[ptr ConnObj]
  Conn* = ref ConnObj

proc `=destroy`(c: ConnObj) =
  `=destroy`(c.sock.addr[])
  deinitLock(c.lock.addr[])
  deinitCond(c.cond.addr[])
  `=destroy`(c.sess.addr[])
  `=destroy`(c.outQ.addr[])
  `=destroy`(c.streams.addr[])
  `=destroy`(c.failure.addr[])

proc `=copy`(dst: var ConnObj; src: ConnObj) {.error.}

# ------------------------------------------------------------ internals
# Every proc below whose name ends in `Locked` expects `c.lock` to be held.

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

proc respondLocked(c: ptr ConnObj; id: int32) =
  ## Server: the request on `id` is complete; run the handler and reply.
  var st: StreamState
  discard c.streams.pop(id, st)
  let req = Request(headers: if st.blocks.len > 0: st.blocks[0] else: @[],
                    body: move st.body)
  let rep = c.handler(req)
  c.sess.submitResponse(id, rep.headers)
  c.sess.sendData(id, rep.body, endStream = rep.trailers.len == 0)
  if rep.trailers.len > 0: c.sess.sendTrailers(id, rep.trailers)

proc handleEventsLocked(c: ptr ConnObj) =
  for ev in c.sess.takeEvents():
    var st = c.streams.mgetOrPut(ev.streamId, StreamState()).addr
    case ev.kind
    of evHeaders:
      st.blocks.add ev.headers
      if c.handler != nil and ev.headersEndStream:
        c.respondLocked(ev.streamId)
    of evData:
      st.body.add ev.data
      if c.handler != nil and ev.dataEndStream:
        c.respondLocked(ev.streamId)
    of evStreamClosed:
      if c.handler != nil:
        c.streams.del(ev.streamId)
      else:
        st.closed = true
        st.errorCode = ev.errorCode
  broadcast(c.cond)

proc readerLoop(c: ptr ConnObj) {.thread.} =
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
      c.closed = true
      if c.failure.len == 0: c.failure = e.msg
      for st in c.streams.mvalues: st.closed = true
      broadcast(c.cond)
    let stop = c.closed
    release(c.lock)
    if stop: return

proc writerLoop(c: ptr ConnObj) {.thread.} =
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

proc start(c: Conn) =
  acquire(c.lock)
  c[].addr.queueOutputLocked()     # client preface / SETTINGS
  release(c.lock)
  createThread(c.reader, readerLoop, c[].addr)
  createThread(c.writer, writerLoop, c[].addr)

proc newConn(sock: Socket; sess: H2Session; handler: RequestHandler): Conn =
  result = Conn(sock: sock, sess: sess, handler: handler)
  initLock(result.lock)
  initCond(result.cond)
  result.outQ = initDeque[seq[byte]]()

# ------------------------------------------------------------ public API

proc close*(c: Conn) =
  ## Sends GOAWAY, stops both threads and closes the socket.
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

proc request*(c: Conn; headers: openArray[Header]; body: openArray[byte] = []): Response =
  ## Sends a request and blocks until its stream closes.
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
  while not c.streams[id].closed:
    wait(c.cond, c.lock)
  var st: StreamState
  discard c.streams.pop(id, st)
  let failure = c.failure
  release(c.lock)
  if st.blocks.len == 0:
    raise newException(H2Error, "stream " & $id & " ended without a response" &
      (if failure.len > 0: ": " & failure else: ""))
  result.headers = st.blocks[0]
  if st.blocks.len > 1: result.trailers = st.blocks[^1]
  result.body = move st.body
  result.errorCode = st.errorCode

# ------------------------------------------------------------ server

type
  ServerObj = object
    listener: Socket
    handler: RequestHandler
    conns: seq[Conn]      ## touched only by the accept thread until it is joined
    stopping: Atomic[bool]
    acceptor: Thread[ptr ServerObj]
  Server* = ref ServerObj

proc newServer*(handler: RequestHandler; port = Port(0);
                address = "127.0.0.1"): Server =
  result = Server(handler: handler)
  result.listener = newSocket(buffered = false)
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(port, address)
  result.listener.listen()

proc port*(s: Server): Port = s.listener.getLocalAddr()[1]

proc reap(s: ptr ServerObj) =
  var keep: seq[Conn]
  for c in s.conns:
    if c.isClosed:
      joinThread(c.writer)
      joinThread(c.reader)
      c.sock.close()
    else:
      keep.add c
  s.conns = keep

proc acceptLoop(s: ptr ServerObj) {.thread.} =
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
    let c = newConn(client, newServerSession(), s.handler)
    c.start()
    s.conns.add c

proc start*(s: Server) =
  ## Accepts connections on a background thread until `stop`.
  createThread(s.acceptor, acceptLoop, s[].addr)

proc stop*(s: Server) =
  s.stopping.store(true)
  discard posix.shutdown(s.listener.getFd, SHUT_RDWR)
  joinThread(s.acceptor)
  s.listener.close()
  for c in s.conns: c.close()
  s.conns = @[]
