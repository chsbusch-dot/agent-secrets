#!/bin/bash
# Usage: scripts/scrub-check.sh PATTERNS_FILE CONTROL_FILE...
#
# Proves the repo is free of private strings before it goes public.
#
# Each line of PATTERNS_FILE (blank lines and # comments skipped) is a fixed string
# that must not appear in the repo: every tracked file, every untracked file that
# is not ignored, and every commit message and commit email on every branch.
# Matching ignores case.
#
# A zero count only means something if the same scan finds the pattern where it
# is known to exist, so every pattern must also match at least one CONTROL_FILE
# (for example the private original this repo was cut from). A pattern with no
# control hit fails as NO-CONTROL, which also catches a scanner that silently
# matches nothing.
#
# Keep PATTERNS_FILE outside the repo: it is the list of what must stay private.
# Exit status: 0 clean, 1 a leak or an unproven pattern, 2 usage error.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 PATTERNS_FILE CONTROL_FILE..." >&2
  exit 2
fi
patterns_file=$1
shift
for f in "$patterns_file" "$@"; do
  [ -r "$f" ] || { echo "$0: cannot read $f" >&2; exit 2; }
done

root=$(git rev-parse --show-toplevel)
cd "$root"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git ls-files -z -co --exclude-standard >"$work/files"
nfiles=$(tr -cd '\0' <"$work/files" | wc -c | tr -d ' ')
git log --all --format='%B%n%an <%ae>%n%cn <%ce>' >"$work/history" 2>/dev/null || : >"$work/history"
ncommits=$(git rev-list --all --count 2>/dev/null || echo 0)
if [ "$nfiles" -eq 0 ]; then
  echo "$0: found no files to scan in $root, refusing to report clean" >&2
  exit 1
fi

# count_in PATTERN FILE...: case-insensitive fixed-string occurrences across files.
count_in() {
  p=$1
  shift
  { grep -ioF -- "$p" "$@" 2>/dev/null || true; } | wc -l | tr -d ' '
}

count_repo() {
  in_files=$({ xargs -0 grep -ioFh -- "$1" <"$work/files" 2>/dev/null || true; } | wc -l | tr -d ' ')
  in_history=$(count_in "$1" "$work/history")
  echo $((in_files + in_history))
}

printf 'scanning %s files and %s commits in %s\n' "$nfiles" "$ncommits" "$root"
printf '%-36s %6s %8s  %s\n' PATTERN REPO CONTROL VERDICT
bad=0
total=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '' | '#'*) continue ;; esac
  total=$((total + 1))
  repo=$(count_repo "$line")
  ctrl=$(count_in "$line" "$@")
  if [ "$repo" -gt 0 ]; then
    verdict=LEAK
    bad=$((bad + 1))
  elif [ "$ctrl" -eq 0 ]; then
    verdict=NO-CONTROL
    bad=$((bad + 1))
  else
    verdict=ok
  fi
  printf '%-36s %6s %8s  %s\n' "$line" "$repo" "$ctrl" "$verdict"
done <"$patterns_file"

if [ "$total" -eq 0 ]; then
  echo "$0: $patterns_file holds no patterns" >&2
  exit 1
fi
if [ "$bad" -gt 0 ]; then
  printf '%d of %d patterns failed\n' "$bad" "$total"
  exit 1
fi
printf 'all %d patterns clean in the repo and proven against the controls\n' "$total"
