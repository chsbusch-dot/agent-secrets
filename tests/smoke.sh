#!/bin/bash
# shellcheck disable=SC2016  # snippets are single-quoted on purpose: the shell under test expands them
#
# Smoke test: bws-helpers.sh against a mock bws (tests/bin/bws) and a mock
# keychain (tests/bin/security). Every case runs in a fresh shell with an empty
# environment, so no real token or secret is ever in reach.
#
# Usage: tests/smoke.sh [SHELL]   (default bash; zsh, /bin/bash, ... work too)
set -euo pipefail

SH="${1:-bash}"
SH_BIN=$(command -v "$SH") || { echo "smoke: no shell named $SH" >&2; exit 2; }
PY_BIN=$(command -v python3) || { echo "smoke: python3 is required" >&2; exit 2; }
PY_DIR=$(dirname "$PY_BIN")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bws-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
H="$WORK/bws-helpers.sh"
CACHE="$WORK/home/.cache/bws-keys.cache"
mkdir -p "$WORK/home" "$WORK/keychain"

DS=sk-test-forecast-0123456789abcdef
GET_DS='v=$(bws-get FORECAST_API_KEY) || exit $?; [ "$v" = "sk-test-forecast-0123456789abcdef" ] && printf same'

PASS=0
FAIL=0
RC=0
OUT=""
ERR=""
LOG=""

# A fresh copy of the helpers, the vault, the keychain and the token file.
reset() {
  cp "$ROOT/bws-helpers.sh" "$H"
  cat >"$WORK/store.json" <<'EOF'
{"projects": [{"id": "p-main", "name": "main"}, {"id": "p-other", "name": "other"}],
 "tokens": {"tok-admin": {"kind": "admin", "projects": ["p-main", "p-other"]},
            "tok-ro": {"kind": "ro", "projects": ["p-main"]}},
 "secrets": [
  {"id": "s-forecast", "key": "FORECAST_API_KEY", "value": "sk-test-forecast-0123456789abcdef", "projectId": "p-main", "note": ""},
  {"id": "s-places", "key": "PLACES_API_KEY", "value": "sk-test-places-abcdef0123456789", "projectId": "p-main", "note": ""},
  {"id": "s-newline", "key": "NEWLINE_KEY", "value": "trailing-newline-value\n", "projectId": "p-main", "note": ""},
  {"id": "s-other", "key": "OTHER_PROJECT_TOKEN", "value": "other-project-value-42", "projectId": "p-other", "note": ""},
  {"id": "s-dup1", "key": "DUP_KEY", "value": "dup-one-value", "projectId": "p-main", "note": ""},
  {"id": "s-dup2", "key": "DUP_KEY", "value": "dup-two-value", "projectId": "p-other", "note": ""}
 ]}
EOF
  printf 'tok-admin' >"$WORK/keychain/bws-admin"
  printf 'BWS_ACCESS_TOKEN="tok-ro"\n' >"$WORK/ro-token"
  printf '0' >"$WORK/fail"
  : >"$WORK/log"
  rm -rf "$WORK/home/.cache"
}

# run SNIPPET [NAME=VALUE...]: runs SNIPPET in a fresh $SH that sourced the
# helpers, with the mocks first on PATH and stdin, stdout and stderr not a
# terminal. Sets RC, OUT, ERR and LOG (the mock's call log).
run() {
  local snippet="$1"
  shift
  RC=0
  env -i PATH="$ROOT/tests/bin:$PY_DIR:/usr/bin:/bin" HOME="$WORK/home" H="$H" W="$WORK" \
    MOCK_BWS_STORE="$WORK/store.json" MOCK_BWS_LOG="$WORK/log" \
    MOCK_BWS_FAIL_FILE="$WORK/fail" MOCK_KEYCHAIN_DIR="$WORK/keychain" \
    BWS_RO_TOKEN_FILE="$WORK/ro-token" BWS_PROJECT_ID=p-main BWS_RETRY_SLEEP=0 \
    ${1+"$@"} "$SH_BIN" -c "set -u; . \"\$H\"; $snippet" \
    </dev/null >"$WORK/out" 2>"$WORK/err" || RC=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
  LOG=$(cat "$WORK/log")
  : >"$WORK/log"
}

# check NAME TEST...: one assertion; TEST is a command such as has, lacks or [.
check() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s] %s\n  rc=%s\n  out: %s\n  err: %s\n  log: %s\n' \
      "$SH" "$name" "$RC" "$OUT" "$ERR" "$LOG" >&2
  fi
}
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$1" "$2"; }
count() { printf '%s\n' "$1" | grep -c -- "$2" || true; }

cat >"$WORK/showenv" <<'EOF'
#!/bin/sh
printf '%s%s' "${FORECAST_API_KEY:+main}" "${OTHER_PROJECT_TOKEN:+other}"
EOF
cat >"$WORK/nested-write" <<'EOF'
#!/bin/sh
bws secret create NESTED nested-value-0123 p-main -o none
EOF
chmod +x "$WORK/showenv" "$WORK/nested-write"
reset

# Tokens: a human gets the read-write token from the keychain; an agent gets
# the read-only token and never touches the keychain.
run "$GET_DS"
check "human: get returns the value" [ "$OUT" = same ]
check "human: read-write token from the keychain" has "$LOG" "keychain read bws-admin"
check "human: read with the read-write token" has "$LOG" "admin secret get FORECAST_API_KEY"

run "$GET_DS" CLAUDECODE=1
check "agent: get inside \$(...) returns the value" [ "$OUT" = same ]
check "agent: read with the read-only token" has "$LOG" "ro secret get FORECAST_API_KEY"
check "agent: keychain never read" lacks "$LOG" "keychain"

run "$GET_DS" BWS_AGENT_SHELL=1
check "BWS_AGENT_SHELL: read-only token" has "$LOG" "ro secret get FORECAST_API_KEY"
check "BWS_AGENT_SHELL: keychain never read" lacks "$LOG" "keychain"

run "$GET_DS" BWS_ACCESS_TOKEN=tok-ro
check "env token wins over the keychain" has "$LOG" "ro secret get FORECAST_API_KEY"
check "env token: keychain not read" lacks "$LOG" "keychain"

# Read-only token file formats.
printf 'tok-ro\n' >"$WORK/ro-token"
run "$GET_DS" CLAUDECODE=1
check "token file: bare token" [ "$OUT" = same ]
printf "export BWS_ACCESS_TOKEN='tok-ro'\n" >"$WORK/ro-token"
run "$GET_DS" CLAUDECODE=1
check "token file: export line with single quotes" [ "$OUT" = same ]
printf '# read-only token\n\ntok-ro\r\n' >"$WORK/ro-token"
run "$GET_DS" CLAUDECODE=1
check "token file: comment, blank line, CRLF" [ "$OUT" = same ]
reset

rm -f "$WORK/keychain/bws-admin" "$WORK/ro-token"
run 'bws-ls'
check "no token: fails" [ "$RC" -ne 0 ]
check "no token: names the env variable" has "$ERR" "BWS_ACCESS_TOKEN"
check "no token: names the keychain item" has "$ERR" "bws-admin"
check "no token: names the token file" has "$ERR" "$WORK/ro-token"
reset

# The read-only token sees fewer projects.
run 'v=$(bws-get OTHER_PROJECT_TOKEN) || exit $?; printf "%s" "${#v}"' CLAUDECODE=1
check "read-only token: other project invisible" has "$ERR" "no secret matching"
run 'v=$(bws-get OTHER_PROJECT_TOKEN) || exit $?; printf "%s" "${#v}"'
check "human control: other project visible" [ "$OUT" = 22 ]

# The print guard: in an agent's shell a bare bws-get would put the value into
# the agent's context, so it is refused before BWS is asked.
run 'bws-get FORECAST_API_KEY' CLAUDECODE=1
check "guard: bare get in an agent refused" [ "$RC" -eq 3 ]
check "guard: prints nothing" [ -z "$OUT" ]
check "guard: BWS never asked" [ -z "$LOG" ]
run 'bws-get FORECAST_API_KEY >"$W/leak"' CLAUDECODE=1
check "guard: redirect to a file refused too" [ "$RC" -eq 3 ]
run '_bws_token' CLAUDECODE=1
check "guard: bare token refused" [ "$RC" -eq 3 ]
check "guard: token not printed" lacks "$OUT" "tok-"
run '_bws_call secret list -o json' CLAUDECODE=1
check "guard: bare secret list refused" [ "$RC" -eq 3 ]
check "guard: values not printed" lacks "$OUT" "$DS"
run 'bws-get FORECAST_API_KEY | wc -c' CLAUDECODE=1
check "guard control: pipe from an agent allowed, no trailing newline" \
  [ "$(printf '%s' "$OUT" | tr -d ' ')" = 33 ]
run '{ bws-get FORECAST_API_KEY; }' CLAUDECODE=1
check "guard: brace group refused" [ "$RC" -eq 3 ]
# Known limit, kept in a test so the README stays true: the guard only sees a
# call made at the top of the shell. A subshell still prints in every shell.
run '(bws-get FORECAST_API_KEY)' CLAUDECODE=1
check "guard limit: a subshell prints (README threat model)" [ "$OUT" = "$DS" ]
run 'bws-get FORECAST_API_KEY'
check "guard control: human bare get prints" [ "$OUT" = "$DS" ]
run 'bws-get FORECAST_API_KEY' CLAUDECODE=1 BWS_ALLOW_STDOUT=1
check "guard control: BWS_ALLOW_STDOUT prints" [ "$OUT" = "$DS" ]

run 'x=$(_bws_call secret delete s-forecast -o none)' CLAUDECODE=1
check "agent _bws_call: delete refused" has "$ERR" "reads only in an agent shell"
check "agent _bws_call: BWS never asked" [ -z "$LOG" ]

# Writes from an agent's shell need BWS_AGENT_RW=1.
run 'printf "new-value-0123456789" | bws-add NEW_KEY' CLAUDECODE=1
check "agent add: refused" [ "$RC" -ne 0 ]
check "agent add: says why" has "$ERR" "only the read-only token"
check "agent add: nothing created" lacks "$LOG" "create"
run 'printf "new-value-0123456789" | bws-add NEW_KEY' CLAUDECODE=1 BWS_AGENT_RW=1
check "agent add with RW: succeeds" [ "$RC" -eq 0 ]
check "agent add with RW: read-write token" has "$LOG" "admin secret create NEW_KEY"
check "agent add with RW: reports the length" has "$ERR" "NEW_KEY added (20 chars)"
check "agent add with RW: value not echoed" lacks "$ERR$OUT" "new-value-0123456789"
run 'printf "noproj-value-0123" | bws-add NOPROJ' BWS_PROJECT_ID=
check "add without BWS_PROJECT_ID: refused" has "$ERR" "set BWS_PROJECT_ID"
check "add without BWS_PROJECT_ID: nothing created" lacks "$LOG" "create"
reset

# bws-run hands the child the token it ran with.
run 'bws-run -- "$W/showenv"' CLAUDECODE=1 BWS_PROJECT_ID=
check "agent run: sees what the read-only token sees" [ "$OUT" = main ]
check "agent run: read-only token" has "$LOG" "ro run"
run 'bws-run "$W/showenv"' BWS_PROJECT_ID=
check "human run control: sees every project" [ "$OUT" = mainother ]
run 'bws-run "$W/showenv"'
check "human run: BWS_PROJECT_ID scopes it" [ "$OUT" = main ]
run 'bws-run "$W/nested-write"' CLAUDECODE=1
check "agent run: a write from the child is refused" has "$ERR" "403 Forbidden"
check "agent run: nothing created" lacks "$(cat "$WORK/store.json")" "NESTED"

# Duplicate names.
run 'printf "dup-value-0123456789" | bws-add FORECAST_API_KEY'
check "dup exact: refused" [ "$RC" -ne 0 ]
check "dup exact: names the project" has "$ERR" "already exists in project main"
check "dup exact: points at bws-rot" has "$ERR" "run bws-rot FORECAST_API_KEY"
check "dup exact: nothing created" lacks "$LOG" "create"
run 'printf "dup-value-0123456789" | bws-add forecast_api_key'
check "dup case: refused" has "$ERR" "clashes with existing FORECAST_API_KEY"
check "dup case: nothing created" lacks "$LOG" "create"
run 'printf "dup-value-0123456789" | bws-add DUP_KEY'
check "dup twice: refused" has "$ERR" "already exists more than once"
check "dup twice: nothing created" lacks "$LOG" "create"
run 'v=$(bws-get DUP_KEY) || exit $?; printf "%s" "$v"'
check "dup get: fails" [ "$RC" -ne 0 ]
check "dup get: says why" has "$ERR" "2 secrets are named"
check "dup get: prints nothing" [ -z "$OUT" ]

# Fuzzy names.
run 'v=$(bws-get forecast) || exit $?; printf "%s" "${#v}"'
check "fuzzy: unique part resolves" [ "$OUT" = 33 ]
check "fuzzy: says what it resolved to" has "$ERR" "-> FORECAST_API_KEY"
run 'v=$(bws-get api_key) || exit $?; printf "%s" "${#v}"'
check "fuzzy: ambiguous part refused" [ "$RC" -eq 2 ]
check "fuzzy: lists the matches" has "$ERR" "2 secrets match"
check "fuzzy: prints nothing" [ -z "$OUT" ]

# Shape checks, never the value.
run 'bws-check FORECAST_API_KEY' CLAUDECODE=1
check "check: length and shape" has "$OUT" "33 chars, token-safe, sk- (OpenAI style)"
check "check: no value" lacks "$OUT$ERR" "$DS"
run 'bws-check NEWLINE_KEY' CLAUDECODE=1
check "check: sees a trailing newline" has "$OUT" "embedded line break"
check "check: warning exit code" [ "$RC" -eq 2 ]
check "check: no value" lacks "$OUT$ERR" "trailing-newline-value"
run 'printf " padded-value-0123 " | bws-add PADDED'
check "whitespace: refused unattended" has "$ERR" "refusing to store this value unattended"
check "whitespace: warning names it" has "$ERR" "leading or trailing whitespace"
check "whitespace: nothing created" lacks "$LOG" "create"
check "whitespace: value not echoed" lacks "$ERR" "padded-value-0123"
run 'printf " padded-value-0123 " | bws-add PADDED' BWS_ALLOW_ODD=1
check "whitespace with BWS_ALLOW_ODD: stored" has "$LOG" "admin secret create PADDED"
run 'printf "line-one\nline-two" | bws-add MULTI'
check "line break: refused unattended" has "$ERR" "embedded line break"
check "line break: nothing created" lacks "$LOG" "create"
reset

# Rotation.
run 'printf "sk-test-forecast-0123456789abcdef" | bws-rot FORECAST_API_KEY'
check "rot same value: refused" has "$ERR" "identical to the current one"
check "rot same value: nothing edited" lacks "$LOG" "edit"
run 'printf "sk-test-forecast-rotated-000111222" | bws-rot FORECAST_API_KEY'
check "rot: succeeds" [ "$RC" -eq 0 ]
check "rot: edits with the read-write token" has "$LOG" "admin secret edit FORECAST_API_KEY"
check "rot: reports the previous length" has "$ERR" "previous value was 33 chars"
check "rot: values not echoed" lacks "$ERR$OUT" "sk-test-forecast"
run 'v=$(bws-get FORECAST_API_KEY) || exit $?; [ "$v" = "sk-test-forecast-rotated-000111222" ] && printf rotated'
check "rot: new value stored" [ "$OUT" = rotated ]
reset

run 'bws-rm FORECAST_API_KEY'
check "rm unattended: refused" has "$ERR" "only runs at a terminal"
check "rm unattended: nothing deleted" lacks "$LOG" "delete"

# Rate limits.
printf '3' >"$WORK/fail"
run "$GET_DS"
check "retry: 3 rate-limited calls are absorbed" [ "$OUT" = same ]
check "retry: quietly" lacks "$ERR" "429"
printf '10' >"$WORK/fail"
run "$GET_DS"
check "retry: gives up" [ "$RC" -ne 0 ]
check "retry: shows the last error" has "$ERR" "429 Too Many Requests"
reset

# A changed helpers file is reloaded once; a deleted one is left alone.
run 'bws-ls >/dev/null
python3 -c "import os, sys; t = os.stat(sys.argv[1]).st_mtime + 10; os.utime(sys.argv[1], (t, t))" "$H"
printf "reloaded-value-0123" | bws-add RELOADED'
check "reload: noticed" has "$ERR" "reloading"
check "reload: one create, not two" [ "$(count "$LOG" "secret create RELOADED")" = 1 ]
reset
run 'rm -f "$H"; bws-ls'
check "deleted helpers file: still works" has "$OUT" "FORECAST_API_KEY"
check "deleted helpers file: no reload" lacks "$ERR" "reloading"
reset

# Listing and the completion cache hold names only.
run 'bws-ls' CLAUDECODE=1
check "ls: names" has "$OUT" "FORECAST_API_KEY"
check "ls: no values" lacks "$OUT" "sk-test"
run '_bws_cached_keys >/dev/null'
check "cache: written" [ -s "$CACHE" ]
check "cache: holds names" has "$(cat "$CACHE" 2>/dev/null)" "FORECAST_API_KEY"
check "cache: holds no values" lacks "$(cat "$CACHE" 2>/dev/null)" "sk-test"
check "cache: mode 600" [ -n "$(find "$CACHE" -type f -perm 0600 2>/dev/null)" ]

run 'bws-get'
check "get without a key: usage" has "$ERR" "usage: bws-get KEY"

printf '%s: %d passed, %d failed\n' "$SH" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
