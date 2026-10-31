switch("path", thisDir() & "/src")
switch("mm", "orc")
switch("panics", "on")
# Dependencies outside nimble's reach (e.g. a sandbox): point at checkouts.
if existsEnv("NIM_BEARSSL"): switch("path", getEnv("NIM_BEARSSL"))
