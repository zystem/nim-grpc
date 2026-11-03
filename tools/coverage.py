#!/usr/bin/env python3
"""Statement (line) coverage of src/nimgrpc from the gcov data of a test run.

Usage: coverage.py OUTDIR [THRESHOLD]

OUTDIR holds one nimcache per test (nc_*), built with --lineDir:on and
--coverage and run. gcov reads the .gcda files and, because the generated C
carries #line directives, reports the lines of the .nim files. The lines of
all the runs are merged: a line counts as covered when any test ran it.
Exits 1 when the percentage is under THRESHOLD (default 80).
"""
import collections
import glob
import json
import os
import subprocess
import sys


def main():
    out = sys.argv[1]
    threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 80.0
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src", "nimgrpc")) + os.sep
    cov = collections.defaultdict(dict)
    for gcda in sorted(glob.glob(os.path.join(out, "nc_*", "*.gcda"))):
        d, b = os.path.split(gcda)
        res = subprocess.run(["gcov", "--json-format", "--stdout", b],
                             capture_output=True, text=True, cwd=d)
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                doc = json.loads(line)
            except ValueError:
                continue
            for f in doc.get("files", []):
                name = os.path.normpath(f["file"])
                if not name.startswith(root):
                    continue
                lines = cov[name]
                for l in f["lines"]:
                    n = l["line_number"]
                    lines[n] = max(lines.get(n, 0), l["count"])
    if not cov:
        sys.exit("coverage: no data (were the tests built with --coverage and run?)")
    rows = []
    for name, lines in cov.items():
        total = len(lines)
        hit = sum(1 for c in lines.values() if c > 0)
        rows.append((name[len(root):], hit, total))
    rows.sort(key=lambda r: r[1] / r[2])
    for name, hit, total in rows:
        print("%-40s %5d / %-5d %6.1f%%" % (name, hit, total, 100.0 * hit / total))
    hit = sum(r[1] for r in rows)
    total = sum(r[2] for r in rows)
    pct = 100.0 * hit / total
    print("\nstatement coverage of src/nimgrpc (Nim and C, generated code included): "
          "%d / %d lines = %.1f%% (threshold %.0f%%)" % (hit, total, pct, threshold))
    if pct < threshold:
        sys.exit(1)


main()
