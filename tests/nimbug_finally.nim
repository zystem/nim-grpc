proc cleanupQuiet() =
  try:
    discard
  except CatchableError:
    discard

proc viaFinally() =
  try:
    raise newException(ValueError, "outer")
  finally:
    cleanupQuiet()

proc viaDefer() =
  defer: cleanupQuiet()
  raise newException(ValueError, "outer")

for (name, p) in [("finally", viaFinally), ("defer", viaDefer)]:
  try:
    p()
    echo name, ": BUG, outer exception lost"
  except ValueError:
    echo name, ": ok"
