version       = "0.0.1"
author        = "zystem"
description   = "gRPC for Nim on top of nghttp2"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.0"

const tests = ["tests/th2session.nim", "tests/tblocking.nim", "tests/tgrpc.nim"]

proc runAll(flags: string) =
  for t in tests:
    exec "nim c -r --hints:off " & flags & " " & t

task test, "Run the unit tests":
  runAll("")

task asan, "Run the tests under AddressSanitizer/LeakSanitizer":
  runAll("-d:useMalloc --debugger:native " &
         "--passC:-fsanitize=address --passL:-fsanitize=address")

task tsan, "Run the tests under ThreadSanitizer":
  runAll("-d:useMalloc --debugger:native " &
         "--passC:-fsanitize=thread --passL:-fsanitize=thread")
