version       = "0.0.1"
author        = "zystem"
description   = "gRPC for Nim on top of nghttp2"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.12", "bearssl >= 0.3.1"

const tests = ["tests/th2session.nim", "tests/tblocking.nim", "tests/tgrpc.nim",
               "tests/ttls.nim"]

proc runAll(flags, tag: string) =
  # A separate nimcache per flag set: Nim reuses C objects across --passC changes.
  for t in tests:
    exec "nim c -r --hints:off --nimcache:nimcache/" & tag & " " & flags & " " & t

task test, "Run the unit tests":
  runAll("", "plain")

task asan, "Run the tests under AddressSanitizer/LeakSanitizer":
  runAll("-d:useMalloc --debugger:native " &
         "--passC:-fsanitize=address --passL:-fsanitize=address", "asan")

task tsan, "Run the tests under ThreadSanitizer":
  runAll("-d:useMalloc --debugger:native " &
         "--passC:-fsanitize=thread --passL:-fsanitize=thread", "tsan")
