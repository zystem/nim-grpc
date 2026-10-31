## TLS and mutual TLS.

import std/[unittest, os, strutils]
import grpc
import ./interop/interop

const certs = currentSourcePath.parentDir / "certs"
proc pem(name: string): string = readFile(certs / name)

proc expectFailure(f: proc () {.raises: [CatchableError].}): string =
  ## The message of the GrpcError `f` raises; fails the test if it succeeds.
  try:
    f()
  except GrpcError as e:
    return $e.code & ": " & e.msg
  checkpoint "the call succeeded"
  fail()

proc echoOnce(ch: GrpcChannel) =
  let r = ch.unaryCall("/grpc.testing.TestService/EmptyCall", @[], timeoutMs = 5000)
  doAssert r.message.len == 0

suite "TLS":
  test "unary and streaming calls over TLS (EC key)":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    for name in allCases: ch.runCase(name)
    ch.close()
    srv.stop()

  test "RSA server key":
    let srv = newTestServer(tls = tlsServerConfig(pem"rsaserver.pem", pem"rsaserver.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    ch.echoOnce()
    ch.close()
    srv.stop()

  test "a server certificate from an untrusted CA is rejected":
    let srv = newTestServer(tls = tlsServerConfig(pem"rogue.pem", pem"rogue.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    let msg = expectFailure(proc () = ch.echoOnce())
    check "scUnavailable" in msg
    check "trusted CA" in msg
    ch.close()
    srv.stop()

  test "a server name that is not in the certificate is rejected":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "example.com")
    let msg = expectFailure(proc () = ch.echoOnce())
    check "server name" in msg
    ch.close()
    srv.stop()

  test "plaintext client against a TLS server fails":
    let srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key"))
    srv.start()
    let ch = dial("127.0.0.1", srv.port)
    discard expectFailure(proc () = ch.echoOnce())
    ch.close()
    srv.stop()

  test "TLS client against a plaintext server fails":
    let srv = newTestServer()
    srv.start()
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    discard expectFailure(proc () = ch.echoOnce())
    ch.close()
    srv.stop()

  test "bad PEM is reported when the config is built":
    expect TlsError:
      discard tlsServerConfig("not a certificate", pem"server.key")
    expect TlsError:
      discard tlsServerConfig(pem"server.pem", "not a key")
    expect TlsError:
      discard tlsClientConfig("")

suite "mutual TLS":
  var srv: GrpcServer
  setup:
    srv = newTestServer(tls = tlsServerConfig(pem"server.pem", pem"server.key",
                                               clientCaPem = pem"ca.pem"))
    srv.start()
  teardown:
    srv.stop()

  test "a client with a certificate from the trusted CA gets through":
    let ch = dial("127.0.0.1", srv.port,
                  tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key"),
                  "localhost")
    ch.echoOnce()
    ch.runCase("ping_pong")
    ch.close()

  test "a client without a certificate is refused":
    let ch = dial("127.0.0.1", srv.port, tlsClientConfig(pem"ca.pem"), "localhost")
    discard expectFailure(proc () = ch.echoOnce())
    ch.close()

  test "a client certificate from another CA is refused":
    let ch = dial("127.0.0.1", srv.port,
                  tlsClientConfig(pem"ca.pem", pem"rogue.pem", pem"rogue.key"),
                  "localhost")
    discard expectFailure(proc () = ch.echoOnce())
    ch.close()

  test "the server keeps serving after refusing clients":
    let ch = dial("127.0.0.1", srv.port,
                  tlsClientConfig(pem"ca.pem", pem"client.pem", pem"client.key"),
                  "localhost")
    for i in 0 ..< 20: ch.echoOnce()
    ch.close()
