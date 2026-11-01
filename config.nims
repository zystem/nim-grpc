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
