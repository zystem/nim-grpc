version       = "0.0.1"
author        = "zystem"
description   = "gRPC for Nim on top of nghttp2"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.0"

task test, "Run the unit tests":
  exec "nim c -r --hints:off tests/th2session.nim"

task asan, "Run the unit tests under AddressSanitizer/LeakSanitizer":
  exec "nim c -r --hints:off -d:useMalloc --debugger:native " &
       "--passC:-fsanitize=address --passL:-fsanitize=address " &
       "tests/th2session.nim"
