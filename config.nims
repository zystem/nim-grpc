import std/strutils
switch("path", thisDir() & "/src")
switch("mm", "orc")
switch("panics", "on")
# Dependencies outside nimble's reach (e.g. a sandbox): point at checkouts.
if existsEnv("NIM_BEARSSL"): switch("path", getEnv("NIM_BEARSSL"))
# Extra checkouts (chronos and its deps), separated by ':'.
if existsEnv("NIM_PATHS"):
  for p in getEnv("NIM_PATHS").split(':'):
    if p.len > 0: switch("path", p)
# Hardening of what this repository builds (the C parts and the generated C of
# a release build); a program that links the library passes the same flags.
when defined(release) or defined(danger):
  switch("passC", "-fstack-protector-strong -D_FORTIFY_SOURCE=2")
