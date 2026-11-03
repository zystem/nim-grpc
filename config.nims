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
# The standard variables of a build are honoured and only added to: a packager's
# CC, CFLAGS and LDFLAGS reach the C compiler and the linker (Nim itself reads
# them only with --cc:env).
if existsEnv("CC"):
  switch("gcc.exe", getEnv("CC"))
  switch("gcc.linkerexe", getEnv("CC"))
if existsEnv("CFLAGS"): switch("passC", getEnv("CFLAGS"))
if existsEnv("LDFLAGS"): switch("passL", getEnv("LDFLAGS"))
