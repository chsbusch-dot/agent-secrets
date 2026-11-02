#!/bin/bash
# Usage: scripts/dash-check.sh
#
# Fails when a tracked file, or an untracked file that is not ignored, holds an
# em or en dash. The README is public copy written without them. Python does the
# matching, so the check behaves the same with GNU grep, BSD grep or neither.
# Exit status: 0 clean, 1 a dash found or nothing scanned.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git ls-files -z -co --exclude-standard | python3 -c '
import sys
dashes = (chr(0x2014), chr(0x2013))
names = [n for n in sys.stdin.buffer.read().decode("utf-8").split("\0") if n]
if not names:
    sys.exit("dash-check: no files to scan, refusing to report clean")
bad = 0
for name in names:
    try:
        with open(name, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        sys.exit("dash-check: cannot read %s as text (%s)" % (name, e))
    for i, line in enumerate(lines, 1):
        if any(d in line for d in dashes):
            print("%s:%d: %s" % (name, i, line.strip()[:100]))
            bad += 1
print("dash-check: %d files, %d lines with an em or en dash" % (len(names), bad), file=sys.stderr)
sys.exit(1 if bad else 0)
'
