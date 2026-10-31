## `withCleanup`: try/finally for code paths where an exception must not be
## lost.
##
## Nim 2.2.14 (a regression; 2.2.6 is fine) can drop an exception that is on
## its way through a `finally` or `defer`: when the cleanup code is inferred
## never to raise, the error flag is not saved around it, and a proc in it
## that contains its own `try/except` takes the pending exception for one of
## its own and swallows it. See docs/nim-compiler-notes.md.

template withCleanup*(body, cleanup: untyped) =
  ## Runs `body`, then `cleanup` whether or not `body` raised, then re-raises.
  ## Unlike `finally`, `cleanup` runs with no exception pending. A `return`
  ## in `body` skips `cleanup`: do not use one.
  var pendingErr: ref CatchableError
  try:
    body
  except CatchableError as e:
    pendingErr = e
  cleanup
  if pendingErr != nil: raise pendingErr
