# Nim compiler notes

Two code generation problems in Nim (C backend, ORC, goto-based exceptions)
affect this library. Both are worked around in the code. Both bear on code
that uses the library too.

## 1. An exception passing through `finally`/`defer` can be lost

**Affected:** Nim 2.2.12 and 2.2.14. **Not affected:** 2.2.6. Not yet checked:
2.2.8, 2.2.10. nim-bearssl requires 2.2.12 or later, so every supported
compiler has the problem.

Reproduction (`tests/nimbug_finally.nim`):

```nim
proc cleanupQuiet() =
  try:
    discard
  except CatchableError:
    discard

proc viaDefer() =
  defer: cleanupQuiet()
  raise newException(ValueError, "outer")

viaDefer()   # returns normally on 2.2.12/2.2.14: the ValueError is gone
```

**Mechanism.** When a `finally` body (or `defer`) is inferred never to raise,
2.2.12+ no longer saves and clears the error flag around it; 2.2.6 did
(`oldNimErrFin`). The cleanup therefore runs with the flag still set. A
procedure in it that contains a `try/except` checks the flag right after its
`try` body, finds it set, and treats the pending exception as its own: it
handles it and clears the flag. The caller then continues as if nothing had
been raised. This is likely related to the newer "never raises" inference
(Nim commit 9534668, "compiler inference for sfNeverRaises").

**Where it bit us.** The interop helper `expectCode` raised from inside a
case that had `defer: call.close()`, and `close` contains a `try/except`. A
case that should have failed reported PASS. The library had the same pattern
in `unaryCall` and in `blocking.request`.

Report text: [nim-issue-finally.md](nim-issue-finally.md).

**Workaround.** `nimgrpc/cleanup.withCleanup` catches, runs the cleanup with no
exception pending, and re-raises. Every `finally` left in the library only
releases a lock (`pthread_mutex_unlock`, which has no exception handling of
its own). Tests use `withCleanup` instead of `defer` for anything that may
raise. Code using the library should do the same around `close`, `cancel`
and other cleanup, or check the results some other way.

## 2. A call through a generic proc type with a `raises` list lost its check

In `nimgrpc/typed`, a handler was called as `let resp = f(ctx, input)` where `f`
had the type `ClientStreamFn[Req, Resp]`, a generic proc type with
`raises: [CatchableError]`. The generated C had no error check after the call:
a handler that raised let execution continue, and the next `raise` on that
worker thread died with OverflowDefect (`nimInErrorMode` overflowed). A small
reproduction outside the library has not succeeded, so the trigger is not
pinned down.

**Workaround.** The handler types carry no `raises` list, and handler calls
are wrapped (`guarded` in `nimgrpc/typed`). The regression test is in
tests/tgrpc.nim, "a typed streaming handler that raises".
