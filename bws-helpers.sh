# shellcheck shell=bash
# bws-helpers.sh: keep secrets out of your AI agent's context.
#
# Thin helpers around the Bitwarden Secrets Manager CLI (bws). Source this file
# from ~/.bashrc or ~/.zshrc. Works in bash 3.2+ and zsh 5+, needs bws and
# python3 (for JSON).
#
# In a human's shell the helpers use the read-write token. In an agent's shell
# (CLAUDECODE=1, or BWS_AGENT_SHELL=1 for any other agent) they use the
# read-only token, refuse writes unless the command starts with BWS_AGENT_RW=1
# (which the agent's permission rules turn into a human prompt), and refuse to
# print a secret straight into the agent's output.
#
# Commands:
#   bws-get KEY          print the value, no trailing newline: "$(bws-get KEY)"
#   bws-check KEY        length and shape of the value, never the value
#   bws-ls               key names and ids
#   bws-add KEY [NOTE]   create; the value comes from a hidden prompt or stdin
#   bws-rot KEY          rotate; the value comes from a hidden prompt or stdin
#   bws-rm KEY           delete permanently, at a terminal only
#   bws-run [--] CMD...  run CMD with the project's secrets in its environment
#
# KEY is an exact name or a unique case-insensitive part of one.
#
# Settings (environment variables, all optional):
#   BWS_PROJECT_ID       project bws-add creates in (required by bws-add);
#                        bws-run scopes to it when set
#   BWS_KEYCHAIN_ITEM    keychain item holding the read-write token
#                        (default bws-admin; set it empty to never read one)
#   BWS_RO_TOKEN_FILE    file holding the read-only token
#                        (default ${XDG_CONFIG_HOME:-~/.config}/bws/readonly-token)
#   BWS_KEYS_CACHE       key-name cache for tab completion
#                        (default ${XDG_CACHE_HOME:-~/.cache}/bws-keys.cache)
#   BWS_KEYS_CACHE_TTL   cache lifetime in seconds (default 300)
#   BWS_AGENT_SHELL=1    mark a shell as an agent's shell
#   BWS_AGENT_RW=1       allow writes from an agent's shell, one command at a time
#   BWS_ALLOW_ODD=1      store a value with a whitespace or line-break warning
#                        unattended
#   BWS_ALLOW_STDOUT=1   let bws-get print into an agent's output
#   BWS_RETRY_SLEEP      seconds between retries (default 1 to 3, random)

_BWS_TAB=$'\t'
_BWS_NL=$'\n'
_BWS_CR=$'\r'
_BWS_RE_DIGITS='^[0-9]+$'
_BWS_RE_HEX='^[0-9a-fA-F]+$'
_BWS_RE_TOKEN='^[A-Za-z0-9+/=_.~-]+$'

# The Python snippets read bws JSON from stdin. Values stay inside them: they
# print ids, names, lengths and hashes, and only _BWS_PY_VALUE prints a value.

# argv[1] = KEY. Prints "id<TAB>name" of the one secret KEY names.
_BWS_PY_RESOLVE='
import json, sys
raw = sys.stdin.buffer.read()
if not raw.strip():
    sys.exit(1)
try:
    items = json.loads(raw.decode("utf-8"))
except ValueError:
    sys.stderr.write("bws returned something that is not JSON\n")
    sys.exit(1)
q = sys.argv[1]
hits = [s for s in items if s["key"] == q]
if len(hits) > 1:
    sys.stderr.write("%d secrets are named %r, so the name cannot pick one. "
                     "Resolve by id with bws directly.\n" % (len(hits), q))
    sys.exit(2)
if not hits:
    hits = [s for s in items if q.lower() in s["key"].lower()]
    if len(hits) > 1:
        sys.stderr.write("%d secrets match %r:\n" % (len(hits), q))
        for s in sorted(hits, key=lambda s: s["key"])[:20]:
            sys.stderr.write("  %s\n" % s["key"])
        sys.exit(2)
    if not hits:
        sys.stderr.write("no secret matching %r\n" % q)
        sys.exit(1)
    sys.stderr.write("resolved %r -> %s\n" % (q, hits[0]["key"]))
print("%s\t%s" % (hits[0]["id"], hits[0]["key"]))
'

# argv[1] = suffix. Prints the value of one secret, then the suffix.
_BWS_PY_VALUE='
import json, sys
try:
    v = json.loads(sys.stdin.buffer.read().decode("utf-8"))["value"]
except (ValueError, KeyError, TypeError):
    sys.exit(1)
sys.stdout.buffer.write((v + sys.argv[1]).encode("utf-8"))
'

# Prints "length sha256" of one secret value.
_BWS_PY_LENSHA='
import hashlib, json, sys
try:
    v = json.loads(sys.stdin.buffer.read().decode("utf-8"))["value"]
except (ValueError, KeyError, TypeError):
    sys.exit(1)
print("%d %s" % (len(v), hashlib.sha256(v.encode("utf-8")).hexdigest()))
'

_BWS_PY_SHA='
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
'

_BWS_PY_LS='
import json, sys
raw = sys.stdin.buffer.read()
if not raw.strip():
    sys.exit(1)
for s in sorted(json.loads(raw.decode("utf-8")), key=lambda s: s["key"]):
    print("%-32s %s" % (s["key"], s["id"]))
'

_BWS_PY_NAMES='
import json, sys
raw = sys.stdin.buffer.read()
if not raw.strip():
    sys.exit(1)
for k in sorted(set(s["key"] for s in json.loads(raw.decode("utf-8")))):
    print(k)
'

# argv[1] = KEY, argv[2] = `bws project list` JSON. Prints "name<TAB>project<TAB>id"
# for every secret whose name equals KEY ignoring case.
_BWS_PY_SAME='
import json, sys
raw = sys.stdin.buffer.read()
if not raw.strip():
    sys.exit(1)
names = dict((p["id"], p["name"]) for p in json.loads(sys.argv[2]))
q = sys.argv[1].lower()
for s in json.loads(raw.decode("utf-8")):
    if s["key"].lower() == q:
        print("%s\t%s\t%s" % (s["key"], names.get(s.get("projectId"), s.get("projectId")), s["id"]))
'

_bws_err() { printf '%s\n' "$*" >&2; }

_bws_is_agent() { [ -n "${CLAUDECODE:-}" ] || [ -n "${BWS_AGENT_SHELL:-}" ]; }

# Returns 3 when $1 would print a secret into the agent's own output: an agent's
# shell, and this call runs in the top-level shell rather than inside $(...) or a
# pipe. Call it as a plain command, never inside $(...), which adds the very
# subshell level it looks for.
_bws_stdout_guard() {
  _bws_is_agent || return 0
  [ -z "${BWS_ALLOW_STDOUT:-}" ] || return 0
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ] || [ "${ZSH_SUBSHELL:-0}" -gt 0 ]; then
    return 0
  fi
  _bws_err "$1: refusing to print a secret straight into an agent's output. Use it inside \$(...) or a pipe, or run bws-check KEY to see its shape."
  return 3
}

_bws_admin_token() {
  local item="${BWS_KEYCHAIN_ITEM-bws-admin}"
  _bws_stdout_guard _bws_admin_token || return $?
  if _bws_is_agent && [ -z "${BWS_AGENT_RW:-}" ]; then return 1; fi
  [ -n "$item" ] || return 1
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$item" -w 2>/dev/null
  elif command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service "$item" 2>/dev/null
  else
    return 1
  fi
}

_bws_ro_token_file() {
  printf '%s\n' "${BWS_RO_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/bws/readonly-token}"
}

# The file holds the bare token, or a BWS_ACCESS_TOKEN=... line (optionally with
# export and quotes), so an existing env file works as is.
_bws_ro_token() {
  local f="" line=""
  _bws_stdout_guard _bws_ro_token || return $?
  f=$(_bws_ro_token_file)
  [ -r "$f" ] || return 1
  line=$(grep -E '^(export )?BWS_ACCESS_TOKEN=' "$f" | head -n 1) || line=""
  if [ -n "$line" ]; then
    line=${line#export }
    line=${line#BWS_ACCESS_TOKEN=}
  else
    line=$(grep -v -E '^[[:space:]]*(#|$)' "$f" | head -n 1) || line=""
  fi
  line=${line%"$_BWS_CR"}
  line=${line#\"}
  line=${line%\"}
  line=${line#\'}
  line=${line%\'}
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# Token order: BWS_ACCESS_TOKEN from the environment, then the read-write token
# from the keychain (skipped in an agent's shell unless BWS_AGENT_RW is set),
# then the read-only token file.
_bws_token() {
  local tok=""
  _bws_stdout_guard _bws_token || return $?
  if [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
    printf '%s\n' "$BWS_ACCESS_TOKEN"
    return 0
  fi
  tok=$(_bws_admin_token) || tok=""
  [ -n "$tok" ] || tok=$(_bws_ro_token) || tok=""
  if [ -z "$tok" ]; then
    _bws_err "bws-helpers: no token. Set BWS_ACCESS_TOKEN, store the read-write token in keychain item '${BWS_KEYCHAIN_ITEM-bws-admin}', or put the read-only token in $(_bws_ro_token_file)"
    return 1
  fi
  printf '%s\n' "$tok"
}

_bws_need_rw() {
  _bws_is_agent || return 0
  [ -z "${BWS_AGENT_RW:-}" ] || return 0
  [ -z "${BWS_ACCESS_TOKEN:-}" ] || return 0
  _bws_err "agent shell: only the read-only token is available here. A write needs BWS_AGENT_RW=1 in front of the command, which a human approves at the prompt."
  return 1
}

# Runs bws with the right token. Retries quietly (the API rate-limits bursts),
# then makes one last call whose error is shown. An agent's shell gets reads only.
_bws_call() {
  local tok="" out="" n=0
  _bws_stdout_guard _bws_call || return $?
  if _bws_is_agent && [ -z "${BWS_AGENT_RW:-}" ]; then
    case "${1:-} ${2:-}" in
      "secret list"|"secret get"|"project list"|"project get") ;;
      *) _bws_err "_bws_call: reads only in an agent shell (got: ${1:-} ${2:-})"; return 1 ;;
    esac
  fi
  tok=$(_bws_token) || return 1
  while [ "$n" -lt 5 ]; do
    if out=$(BWS_ACCESS_TOKEN="$tok" bws "$@" 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
    n=$((n + 1))
    sleep "${BWS_RETRY_SLEEP:-$((1 + RANDOM % 3))}"
  done
  BWS_ACCESS_TOKEN="$tok" bws "$@"
}

_bws_resolve() {
  _bws_call secret list -o json | python3 -c "$_BWS_PY_RESOLVE" "$1"
}

_bws_same_key() {
  local projects=""
  projects=$(_bws_call project list -o json) || return 1
  _bws_call secret list -o json | python3 -c "$_BWS_PY_SAME" "$1" "$projects"
}

# Shape report on stderr: length, character class, known token prefix. Never the
# value. Returns 2 on a warning (whitespace at either end, a line break).
_bws_describe() {
  local v="$1" n=0 shape="" kind="" bytes="" rc=0 warn=""
  n=${#v}
  if [[ $v =~ $_BWS_RE_DIGITS ]]; then shape="digits"
  elif [[ $v =~ $_BWS_RE_HEX ]]; then shape="hex"
  elif [[ $v =~ $_BWS_RE_TOKEN ]]; then shape="token-safe"
  else shape="mixed"
  fi
  case "$v" in
    sk-ant-*) kind="sk-ant- (Anthropic)" ;;
    ghp_*|gho_*|github_pat_*) kind="GitHub token" ;;
    xox[bpasr]-*) kind="Slack token" ;;
    AKIA*) kind="AWS access key id" ;;
    lin_api_*) kind="Linear API key" ;;
    sk-*) kind="sk- (OpenAI style)" ;;
    eyJ*) kind="JWT" ;;
    0.*.*) kind="BWS access token" ;;
    -----BEGIN*) kind="PEM key material (base64 it first so it stays on one line)" ;;
  esac
  printf '  %s chars, %s%s\n' "$n" "$shape" "${kind:+, $kind}" >&2
  if printf '%s' "$v" | tr -d '\t\r\n' | LC_ALL=C grep -q '[^ -~]'; then
    bytes=$(printf '%s' "$v" | wc -c | tr -d ' ')
    printf '  note: characters outside printable ASCII (%s chars, %s bytes), a smart quote or dash from a paste?\n' "$n" "$bytes" >&2
  fi
  if [ "$n" -lt 8 ]; then
    printf '  note: unusually short for a secret\n' >&2
  fi
  case "$v" in
    [[:space:]]*|*[[:space:]]) warn="leading or trailing whitespace" ;;
  esac
  case "$v" in
    *"$_BWS_NL"*|*"$_BWS_CR"*) warn="${warn:+$warn, }embedded line break" ;;
  esac
  if [ -n "$warn" ]; then
    printf '  WARNING: %s\n' "$warn" >&2
    rc=2
  fi
  return "$rc"
}

# Asks at a terminal, Enter means yes. Unattended it says yes: the checks that
# must hold unattended live in _bws_gate.
_bws_confirm() {
  local ans=""
  [ -t 2 ] || return 0
  printf '%s [Y/n] ' "$1" >&2
  read -r ans </dev/tty || return 1
  case "$ans" in
    ""|[Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = key name, $2 = value about to be stored.
_bws_gate() {
  local rc=0
  _bws_describe "$2" || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -t 2 ] && [ -z "${BWS_ALLOW_ODD:-}" ]; then
    _bws_err "  refusing to store this value unattended, set BWS_ALLOW_ODD=1 to override"
    return 1
  fi
  if ! _bws_confirm "store as $1?"; then
    _bws_err "  aborted, nothing was written"
    return 1
  fi
}

# Reads a new value for $1 from a hidden prompt at a terminal, else from stdin
# (trailing newlines dropped). Prints it for $(...). Never takes it from argv,
# where the process list and shell history would see it.
_bws_read_value() {
  local v=""
  if [ -t 0 ]; then
    printf 'value for %s (input hidden): ' "$1" >&2
    IFS= read -rs v || v=""
    printf '\n' >&2
  else
    v=$(cat) || v=""
  fi
  printf '%s' "$v"
}

_bws_mtime() {
  if [ -z "${1:-}" ] || [ ! -e "$1" ]; then
    printf '0\n'
    return 0
  fi
  # `command` skips zsh's stat builtin (zsh/stat), which takes other flags.
  command stat -L -c %Y "$1" 2>/dev/null || command stat -L -f %m "$1" 2>/dev/null || printf '0\n'
}

# Reloads this file when it changed since the shell sourced it, so a long-lived
# shell never runs stale helpers. Returns 1 after a reload: the caller then calls
# itself again to run the new definition.
_bws_fresh() {
  local now=""
  [ -n "${_BWS_HELPERS_PATH:-}" ] || return 0
  now=$(_bws_mtime "$_BWS_HELPERS_PATH")
  [ "$now" != 0 ] || return 0
  [ "$now" != "${_BWS_HELPERS_MTIME:-0}" ] || return 0
  _bws_err "bws-helpers: $_BWS_HELPERS_PATH changed since this shell loaded it, reloading"
  _BWS_HELPERS_MTIME=$now
  # shellcheck source=/dev/null
  . "$_BWS_HELPERS_PATH" || return 0
  return 1
}

_bws_cache_file() {
  printf '%s\n' "${BWS_KEYS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bws-keys.cache}"
}

# Key names (never values) for tab completion, cached with mode 600.
_bws_cached_keys() {
  local cache="" now=0 mt=0
  cache=$(_bws_cache_file)
  now=$(date +%s)
  mt=$(_bws_mtime "$cache")
  if [ -s "$cache" ] && [ $((now - mt)) -lt "${BWS_KEYS_CACHE_TTL:-300}" ]; then
    cat "$cache"
    return 0
  fi
  if ( umask 077
       mkdir -p "${cache%/*}" &&
       _bws_call secret list -o json | python3 -c "$_BWS_PY_NAMES" >"$cache.$$" ); then
    mv -f "$cache.$$" "$cache" && cat "$cache"
  else
    rm -f "$cache.$$"
    return 1
  fi
}

bws-get() {
  local out="" id=""
  if [ $# -ne 1 ]; then
    _bws_err "usage: bws-get KEY   (prints the value with no trailing newline, use it as \"\$(bws-get KEY)\")"
    return 1
  fi
  _bws_stdout_guard bws-get || return $?
  _bws_fresh || { bws-get "$@"; return $?; }
  out=$(_bws_resolve "$1") || return $?
  id=${out%%"$_BWS_TAB"*}
  _bws_call secret get "$id" -o json | python3 -c "$_BWS_PY_VALUE" ""
}

bws-check() {
  local out="" id="" name="" v="" rc=0
  if [ $# -ne 1 ]; then
    _bws_err "usage: bws-check KEY   (length and shape of the value, never the value)"
    return 1
  fi
  _bws_fresh || { bws-check "$@"; return $?; }
  out=$(_bws_resolve "$1") || return $?
  id=${out%%"$_BWS_TAB"*}
  name=${out#*"$_BWS_TAB"}
  # The x keeps trailing newlines, which $(...) would strip, so the check sees them.
  v=$(_bws_call secret get "$id" -o json | python3 -c "$_BWS_PY_VALUE" x) || return 1
  v=${v%x}
  printf '%s:\n' "$name"
  _bws_describe "$v" 2>&1 || rc=$?
  return "$rc"
}

bws-ls() {
  _bws_fresh || { bws-ls "$@"; return $?; }
  _bws_call secret list -o json | python3 -c "$_BWS_PY_LS"
}

bws-add() {
  local key="${1:-}" note="${2:-}" same="" count=0 name="" rest="" proj="" sid="" v="" tok=""
  if [ -z "$key" ] || [ $# -gt 2 ]; then
    _bws_err "usage: bws-add KEY [NOTE]   (the value comes from a hidden prompt or stdin, never an argument)"
    return 1
  fi
  _bws_fresh || { bws-add "$@"; return $?; }
  _bws_need_rw || return 1
  if [ -z "${BWS_PROJECT_ID:-}" ]; then
    _bws_err "bws-add: set BWS_PROJECT_ID to the project new secrets go into"
    return 1
  fi
  # A second secret with the same name makes lookups by name ambiguous, so look
  # in every project the token can read, ignoring case, before asking for a value.
  same=$(_bws_same_key "$key") || {
    _bws_err "bws-add: could not list the existing secrets, nothing written"
    return 1
  }
  if [ -n "$same" ]; then
    count=$(printf '%s\n' "$same" | wc -l | tr -d ' ')
    if [ "$count" -gt 1 ]; then
      _bws_err "bws-add: $key already exists more than once:"
      printf '%s\n' "$same" | sed 's/^/  /' >&2
      _bws_err "  resolve by id with bws directly, nothing written"
      return 1
    fi
    name=${same%%"$_BWS_TAB"*}
    rest=${same#*"$_BWS_TAB"}
    proj=${rest%%"$_BWS_TAB"*}
    sid=${rest#*"$_BWS_TAB"}
    if [ "$name" = "$key" ]; then
      _bws_err "bws-add: $key already exists in project $proj (id $sid)"
    else
      _bws_err "bws-add: $key clashes with existing $name in project $proj (id $sid), names that differ only in case break lookups"
    fi
    if [ ! -t 2 ]; then
      _bws_err "  refusing to create a second copy unattended, run bws-rot $name"
      return 1
    fi
    if _bws_confirm "rotate $name with bws-rot instead?"; then
      bws-rot "$name"
      return $?
    fi
    _bws_err "  aborted, nothing was written"
    return 1
  fi
  v=$(_bws_read_value "$key")
  if [ -z "$v" ]; then
    _bws_err "empty value, aborting"
    return 1
  fi
  _bws_gate "$key" "$v" || return 1
  tok=$(_bws_token) || return 1
  # bws takes the value as an argument: it is briefly visible in the process list.
  if [ -n "$note" ]; then
    BWS_ACCESS_TOKEN="$tok" bws secret create "$key" "$v" "$BWS_PROJECT_ID" --note "$note" -o none || return 1
  else
    BWS_ACCESS_TOKEN="$tok" bws secret create "$key" "$v" "$BWS_PROJECT_ID" -o none || return 1
  fi
  rm -f "$(_bws_cache_file)"
  _bws_err "✓ $key added (${#v} chars)"
}

bws-rot() {
  local out="" id="" name="" old="" oldlen="" oldsha="" v="" tok=""
  if [ $# -ne 1 ]; then
    _bws_err "usage: bws-rot KEY   (the new value comes from a hidden prompt or stdin, never an argument)"
    return 1
  fi
  _bws_fresh || { bws-rot "$@"; return $?; }
  _bws_need_rw || return 1
  out=$(_bws_resolve "$1") || return $?
  id=${out%%"$_BWS_TAB"*}
  name=${out#*"$_BWS_TAB"}
  old=$(_bws_call secret get "$id" -o json | python3 -c "$_BWS_PY_LENSHA") || {
    _bws_err "bws-rot: could not read the current value, nothing rotated"
    return 1
  }
  oldlen=${old%% *}
  oldsha=${old#* }
  v=$(_bws_read_value "$name")
  if [ -z "$v" ]; then
    _bws_err "empty value, aborting"
    return 1
  fi
  # Pasting the old key back is the usual rotation mistake, and a length check
  # cannot see it.
  if [ "$(printf '%s' "$v" | python3 -c "$_BWS_PY_SHA")" = "$oldsha" ]; then
    _bws_err "bws-rot: new value is identical to the current one, nothing rotated"
    return 1
  fi
  _bws_err "  previous value was $oldlen chars"
  _bws_gate "$name" "$v" || return 1
  tok=$(_bws_token) || return 1
  BWS_ACCESS_TOKEN="$tok" bws secret edit "$id" --value "$v" -o none || return 1
  _bws_err "✓ $name rotated (${#v} chars)"
}

bws-rm() {
  local out="" id="" name="" ans="" tok=""
  if [ $# -ne 1 ]; then
    _bws_err "usage: bws-rm KEY   (deletes permanently, asks first)"
    return 1
  fi
  _bws_fresh || { bws-rm "$@"; return $?; }
  _bws_need_rw || return 1
  if [ ! -t 2 ]; then
    _bws_err "bws-rm: deletes permanently, so it only runs at a terminal where a human answers the prompt. Nothing deleted."
    return 1
  fi
  out=$(_bws_resolve "$1") || return $?
  id=${out%%"$_BWS_TAB"*}
  name=${out#*"$_BWS_TAB"}
  printf 'delete %s (id %s) permanently? [y/N] ' "$name" "$id" >&2
  read -r ans </dev/tty || ans=""
  case "$ans" in
    [Yy]*) ;;
    *) _bws_err "  aborted, nothing deleted"; return 1 ;;
  esac
  tok=$(_bws_token) || return 1
  BWS_ACCESS_TOKEN="$tok" bws secret delete "$id" -o none || return 1
  rm -f "$(_bws_cache_file)"
  _bws_err "✓ $name deleted"
}

# The child inherits the token bws ran with. In an agent's shell that is the
# read-only token, so a write from inside the child fails.
bws-run() {
  local tok=""
  [ "${1:-}" != "--" ] || shift
  if [ $# -eq 0 ]; then
    _bws_err "usage: bws-run [--] CMD [ARGS...]   (runs CMD with the project's secrets in its environment)"
    return 1
  fi
  _bws_fresh || { bws-run "$@"; return $?; }
  tok=$(_bws_token) || return 1
  if [ -n "${BWS_PROJECT_ID:-}" ]; then
    BWS_ACCESS_TOKEN="$tok" bws run --project-id "$BWS_PROJECT_ID" -- "$@"
  else
    BWS_ACCESS_TOKEN="$tok" bws run -- "$@"
  fi
}

_bws_complete_bash() {
  local cur="${COMP_WORDS[COMP_CWORD]}" k=""
  COMPREPLY=()
  while IFS= read -r k; do
    COMPREPLY+=("$k")
  done < <(_bws_cached_keys 2>/dev/null | grep -iF -- "$cur")
}

if [ -n "${BASH_VERSION:-}" ]; then
  _BWS_HELPERS_PATH="${BASH_SOURCE[0]:-}"
  case "$-" in
    *i*) complete -F _bws_complete_bash bws-get bws-check bws-rot bws-rm ;;
  esac
elif [ -n "${ZSH_VERSION:-}" ]; then
  # zsh-only syntax sits in eval so bash can still parse this file.
  eval '_BWS_HELPERS_PATH=${(%):-%x}'
  eval '_bws_complete_zsh() { compadd -U -- ${(f)"$(_bws_cached_keys 2>/dev/null | grep -iF -- "${PREFIX:-}")"}; }'
  eval 'if (( $+functions[compdef] )); then compdef _bws_complete_zsh bws-get bws-check bws-rot bws-rm; fi'
else
  _BWS_HELPERS_PATH=""
fi
case "$_BWS_HELPERS_PATH" in
  ""|/*) ;;
  *) _BWS_HELPERS_PATH="$PWD/$_BWS_HELPERS_PATH" ;;
esac
_BWS_HELPERS_MTIME=$(_bws_mtime "$_BWS_HELPERS_PATH")
