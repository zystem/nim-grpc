### Nim Version

Nim Compiler Version 2.2.14 [Linux: amd64], also 2.2.12 (both built from the release tags).
Works correctly with 2.2.6.

### Description

With the C backend and goto-based exceptions (the default with ORC), an exception that is on its way through a `finally` or `defer` is lost if the cleanup code calls a proc that contains its own `try/except`, and the cleanup is inferred never to raise. The caller then returns normally.

```nim
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
```

### Current Output

```
finally: BUG, outer exception lost
defer: BUG, outer exception lost
```

### Expected Output

```
finally: ok
defer: ok
```

### Known Workarounds

Catch the exception, run the cleanup with no exception pending, then re-raise:

```nim
var pending: ref CatchableError
try:
  body
except CatchableError as e:
  pending = e
cleanup()
if pending != nil: raise pending
```

Giving the cleanup proc a real (even unreachable) `raise` path also helps. An explicit `{.raises: [CatchableError].}` annotation does not.

### Additional Information

The difference in the generated C for `viaFinally`:

2.2.6 saves and clears the error flag around the `finally` body:

```c
oldNimErrFin1_ = *nimErr_; *nimErr_ = NIM_FALSE;
cleanupQuiet__exc4_u1();
if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
*nimErr_ = oldNimErrFin1_;
```

2.2.14 takes the `not bodyCanRaise` branch in `genTryGoto` and calls the cleanup with the flag still set:

```c
{
    cleanupQuiet__exc4_u1();
}
```

`cleanupQuiet` itself is compiled the same way by both versions. Its `try` body cannot raise, so the check of the flag comes right at its start:

```c
if (NIM_UNLIKELY(*nimErr_)) {
    LA1_:;
    if (isObjDisplayCheck(nimBorrowCurrentException()->Sup.m_type, 2, ...)) {
        *nimErr_ = NIM_FALSE;
        popCurrentException();
```

It therefore treats the pending `ValueError` as its own, handles it and clears the flag.

So the "finally body cannot raise" optimization has become unsound now that calls to such procs are inferred never to raise. Possibly related to #26059 ("compiler inference for `sfNeverRaises`", fixes #26036), which landed on version-2-2 after 2.2.6. Any proc whose `try/except` catches everything is inferred never to raise, yet it still reads `*nimErr_`.

Found in practice: a gRPC library where `defer: call.close()` (with `close` containing a `try/except`) silently turned a failing call into a successful return.
