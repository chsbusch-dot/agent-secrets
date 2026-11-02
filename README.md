# agent-secrets

**Keep secrets out of your agent's context.**

An AI coding agent works through a shell, and whatever a command prints lands in
the transcript. The transcript is the agent's context. It goes to the model, it
may be logged, cached or summarized, and it is one copy and paste away from a bug
report. A secret printed once is a secret shared.

These are small shell helpers around a secrets manager CLI. They let an agent
*use* a secret without *seeing* it. The reference backend is Bitwarden Secrets
Manager (`bws`). [A section below](#1password) maps the same pattern onto the
1Password CLI (`op`).

This is a guardrail layer for an agent that cooperates but makes mistakes. It
stops the common accidents: printing a key to "check" it, pasting one into a
command line, creating a second copy under a slightly different name, storing a
value with a trailing newline. It is not a sandbox. An agent that is set on
reading a value it is allowed to use can read it. The
[threat model](#threat-model) says exactly where the line is.

## The pattern

1. **The agent gets a read-only credential.** Your own shell uses a read-write
   token. The agent's shell only finds a read-only one, scoped to the projects
   the agent needs.
2. **Use a value, never show it.** `KEY=$(bws-get FORECAST_API_KEY) ./fetch.sh`
   puts the value into the command. Nothing prints it.
3. **Describe values instead of printing them.** `bws-check KEY` reports the
   length, the character set and the likely kind of token. That is usually what
   "let me look at the key" was after.
4. **New values never travel through argv or chat.** `bws-add` and `bws-rot`
   read the value from a hidden prompt or from stdin. A generated value is piped
   straight in. A value a human holds is typed by that human, in their own
   terminal.
5. **Check before every write.** Refuse a second secret whose name differs only
   in case. Refuse a rotation to the same value. Refuse a value with leading or
   trailing whitespace or a line break when nobody is watching.
6. **Deleting is for humans.** `bws-rm` only runs at a terminal where a person
   answers the prompt.
7. **The harness turns writes into prompts.** In an agent's shell a write needs
   `BWS_AGENT_RW=1` in front of the command, and the agent's permission rules
   turn that prefix into a question for you.

## What's in here

| File | What it is |
|---|---|
| `bws-helpers.sh` | The helpers. One file, sourced by bash 3.2+ or zsh 5+. Needs `bws` and `python3`. |
| `examples/claude-settings.json` | Claude Code permission rules that turn secret writes into prompts. |
| `examples/CLAUDE-secrets.md` | A "Secrets" section for the agent's `CLAUDE.md` (or `AGENTS.md`). |
| `tests/smoke.sh` | Runs every helper against mock `bws` and `security` CLIs in `tests/bin/`. Never touches a real vault. |
| `scripts/scrub-check.sh` | Proves a repo holds none of a private list of strings before it goes public. |
| `scripts/dash-check.sh` | Fails on any em or en dash, the style rule for the README. |

## Install

**1. Source the helpers** from `~/.bashrc` or `~/.zshrc`:

```bash
export BWS_PROJECT_ID=your-project-id   # where bws-add creates secrets
. ~/src/agent-secrets/bws-helpers.sh
```

**2. Create two machine accounts** in Bitwarden Secrets Manager, each with an
access token:

- **read-write**, for you: read and write on the projects you manage.
- **read-only**, for agents: "Can read" only, and only on the projects agents need.

**3. Put the read-write token in the OS keychain**, where an agent's shell will
not look for it:

```bash
# macOS: with -w last, security prompts for the token
security add-generic-password -s bws-admin -a "$USER" -w
```

```bash
# Linux (libsecret)
secret-tool store --label="bws read-write token" service bws-admin
```

**4. Put the read-only token in a file** only your user can read. Paste the
token and press Enter:

```bash
mkdir -p ~/.config/bws
( umask 077; IFS= read -rs t; printf '%s\n' "$t" > ~/.config/bws/readonly-token )
```

The file may also hold a `BWS_ACCESS_TOKEN=...` line, so an existing env file
works as it is.

**An agent needs a secret from another project?** Grant the read-only machine
account "Can read" on that project. Do not add a fallback to the read-write
token for reads: that quietly turns the read-only shell back into a read-write
one.

### Which token a call uses

1. `BWS_ACCESS_TOKEN` from the environment, if it is set. It wins everywhere,
   in an agent's shell too, so **never export a read-write token into an
   agent's environment**.
2. The read-write token from the keychain. Skipped in an agent's shell unless
   the command starts with `BWS_AGENT_RW=1`.
3. The read-only token file.

## Configuration

All optional, all environment variables.

| Variable | Default | What it does |
|---|---|---|
| `BWS_PROJECT_ID` | none | Project `bws-add` creates in (required by `bws-add`). `bws-run` scopes to it when set. |
| `BWS_KEYCHAIN_ITEM` | `bws-admin` | Keychain item holding the read-write token. Set it empty to never read one. |
| `BWS_RO_TOKEN_FILE` | `~/.config/bws/readonly-token` | File holding the read-only token (follows `XDG_CONFIG_HOME`). |
| `BWS_KEYS_CACHE` | `~/.cache/bws-keys.cache` | Key names for tab completion, mode 600, never values (follows `XDG_CACHE_HOME`). |
| `BWS_KEYS_CACHE_TTL` | `300` | Cache lifetime in seconds. |
| `BWS_AGENT_SHELL` | unset | Marks a shell as an agent's. Claude Code sets `CLAUDECODE`, which counts too. |
| `BWS_AGENT_RW` | unset | Allows writes from an agent's shell, one command at a time. |
| `BWS_ALLOW_ODD` | unset | Stores a value with a whitespace or line break warning unattended. |
| `BWS_ALLOW_STDOUT` | unset | Lets `bws-get` print into an agent's output. |
| `BWS_RETRY_SLEEP` | 1 to 3, random | Seconds between retries. The API rate-limits bursts. |

## Usage

| Command | What it does |
|---|---|
| `bws-get KEY` | Prints the value with no trailing newline, for use inside `$(...)`. |
| `bws-check KEY` | Length and shape of the value, never the value. |
| `bws-ls` | Key names and ids. |
| `bws-add KEY [NOTE]` | Creates a secret. The value comes from a hidden prompt or stdin. |
| `bws-rot KEY` | Rotates a secret. The value comes from a hidden prompt or stdin. |
| `bws-rm KEY` | Deletes permanently, and only at a terminal. |
| `bws-run [--] CMD...` | Runs CMD with the project's secrets in its environment. |

`KEY` is an exact name or a unique, case-insensitive part of one. The output
below comes from the mock vault in `tests/`.

```console
$ bws-check FORECAST_API_KEY
FORECAST_API_KEY:
  33 chars, token-safe, sk- (OpenAI style)

$ bws-check NEWLINE_KEY
NEWLINE_KEY:
  23 chars, mixed
  WARNING: leading or trailing whitespace, embedded line break

$ bws-ls
DUP_KEY                          s-dup1
DUP_KEY                          s-dup2
FORECAST_API_KEY                 s-forecast
NEWLINE_KEY                      s-newline
OTHER_PROJECT_TOKEN              s-other
PLACES_API_KEY                   s-places

$ bws-get api
2 secrets match 'api':
  FORECAST_API_KEY
  PLACES_API_KEY
```

Writes check before they store:

```console
$ printf 'abc-123-xyz-0000' | bws-add NEW_TOKEN
  16 chars, token-safe
✓ NEW_TOKEN added (16 chars)

$ printf x | bws-add forecast_api_key
bws-add: forecast_api_key clashes with existing FORECAST_API_KEY in project main (id s-forecast), names that differ only in case break lookups
  refusing to create a second copy unattended, run bws-rot FORECAST_API_KEY

$ bws-rot FORECAST_API_KEY < same-value.txt
bws-rot: new value is identical to the current one, nothing rotated

$ bws-rm PLACES_API_KEY < /dev/null
bws-rm: deletes permanently, so it only runs at a terminal where a human answers the prompt. Nothing deleted.
```

`bws-check` knows the shapes of Anthropic, OpenAI style, GitHub, Slack, Linear
and BWS tokens, AWS access key ids, JWTs and PEM key material. It also flags
non-ASCII characters and values under 8 characters.

## In an agent's shell

The helpers treat a shell as an agent's when `CLAUDECODE` is set (Claude Code
sets it) or `BWS_AGENT_SHELL` is set (set it for any other agent). There:

- Reads use the read-only token.
- `bws` calls are limited to `secret list`, `secret get`, `project list` and
  `project get`.
- A write without `BWS_AGENT_RW=1` refuses:

  ```console
  $ printf abc | bws-add NEW2
  agent shell: only the read-only token is available here. A write needs BWS_AGENT_RW=1 in front of the command, which a human approves at the prompt.
  ```

- A bare `bws-get` refuses to print, and the value still works inside `$(...)`:

  ```console
  $ bws-get FORECAST_API_KEY
  bws-get: refusing to print a secret straight into an agent's output. Use it inside $(...) or a pipe, or run bws-check KEY to see its shape.

  $ v=$(bws-get FORECAST_API_KEY); echo ${#v}
  33
  ```

Getting a new value into the vault from an agent's session:

- **A value the agent generates:** pipe it in, behind the prefix that asks you
  first.

  ```bash
  openssl rand -hex 32 | BWS_AGENT_RW=1 bws-add WEBHOOK_SECRET "signs deploy webhooks"
  ```

- **A value you hold**, such as a key from a vendor's dashboard: run
  `bws-add KEY` yourself, in your own terminal. Do not paste it into the chat.
  The chat is the agent's context.

## Claude Code setup

**1. Make sure the agent's shell has the helpers.** Claude Code builds its shell
from your shell profile. From inside a session, `type bws-get` should report a
function.

**2. Merge [`examples/claude-settings.json`](examples/claude-settings.json)**
into `~/.claude/settings.json` or a project's `.claude/settings.json`. Each
`ask` rule turns a matching command into a prompt:

| Rule | Catches |
|---|---|
| `Bash(*BWS_AGENT_RW*)` | the write prefix, so every write from the agent asks you |
| `Bash(*bws-add *)`, `Bash(*bws-rot *)`, `Bash(*bws-rm *)` | the write helpers, with or without the prefix |
| `Bash(*bws secret create*)`, `Bash(*bws secret edit*)`, `Bash(*bws secret delete*)` | writes through the raw CLI |
| `Bash(*security find-generic-password*)`, `Bash(*secret-tool lookup*)`, `Bash(*bws-admin*)` | reading the read-write token from the keychain directly |

The leading `*` lets a rule match when an environment assignment or another
command comes first, as in `BWS_AGENT_RW=1 bws-add ...` or `cd app && bws-rot ...`.

The optional `deny` rule, `Read(~/.config/bws/**)`, stops the file reading tool
from opening the token file. It does not stop `cat` in the shell, so treat it as
a speed bump for the file tools only.

Test the rules once they are in: ask the agent to run `BWS_AGENT_RW=1 bws-ls`
and check that you get a prompt. If you do not, your permission mode or your
Claude Code version matches commands differently, and the rules protect nothing.

**3. Add [`examples/CLAUDE-secrets.md`](examples/CLAUDE-secrets.md)** to your
`CLAUDE.md`, so the agent knows the rules before it runs into them.

## Threat model

What the helpers stop, and what they do not.

**The print guard is a speed bump.** `bws-get` refuses when it runs at the top
level of an agent's shell, because there its output goes straight into the
transcript. It cannot see what happens to output inside a subshell or a pipe.
Measured in bash 3.2, bash 5 and zsh 5.9:

| Command | Result |
|---|---|
| `bws-get KEY` | refused |
| `{ bws-get KEY; }` | refused |
| `bws-get KEY > file` | refused |
| `${ bws-get KEY; }` (bash 5.3) | refused |
| `true \| bws-get KEY` | prints in bash, refused in zsh |
| `bws-get KEY \| cat` | prints |
| `(bws-get KEY)` | prints |
| `echo "$(bws-get KEY)"` | prints |

So the guard catches the accident, not intent. The agent's instructions and your
review of what it runs do the rest.

**A value substituted into an argument sits in that process's argv.**
`curl -H "Authorization: Bearer $(bws-get KEY)" ...` keeps the value out of the
transcript, but while curl runs, other local users can see it with `ps`. Prefer
tools that read a secret from the environment or stdin:
`KEY=$(bws-get KEY) tool`, or `bws-get KEY | tool --password-stdin`.

**`bws secret create` and `bws secret edit` take the value as an argument.**
That is the `bws` CLI, and the helpers cannot avoid it. `bws-add` and `bws-rot`
keep the value out of your shell history and the transcript, but for the moment
the `bws` process runs, its argv holds the value. On Linux every local user can
read argv from `/proc` by default. On a single-user laptop the window is small.
On a shared machine it is not.

**`bws-run` hands the child every secret in the project, plus the token.**
`bws-run -- env` prints all of them into the transcript. Use `bws-run` to start
programs, never to inspect, and add `Bash(*bws-run *)` to the ask rules if the
agent should not start one unattended.

**The agent can read the read-only token.** The file is readable by your user,
and the agent runs as your user. So the read-only account's grants are the real
boundary: whatever it can read, the agent can read. Grant it only what agents
need.

**An environment `BWS_ACCESS_TOKEN` wins.** If a read-write token is exported
into the environment the agent inherits, every protection here is off.

**The keychain may not ask.** On macOS an item created with
`security add-generic-password` trusts the `security` tool, so
`security find-generic-password -w` returns the token without a dialog. The
helpers skip the keychain in an agent's shell, but they cannot stop the agent
from calling `security` itself. The ask rule for it is the guard. For a hard
stop, set the item's access control in Keychain Access to ask for your password,
or keep the read-write token off the machine.

**`bws-check` reveals length and kind.** That is its job. It never prints the
value.

**No temp files.** The helpers keep values in shell variables and pipes and never
write one to disk. The only file they write is the key name cache.

**When you need a real boundary.** If the agent must not be able to read a
secret at all, these helpers are the wrong tool. Reach for:

- a separate OS user, container or VM for the agent, with no access to your
  keychain or token files
- the read-write token off the machine, with writes done by a human elsewhere
- short-lived tokens that expire with the session
- the agent harness's own sandbox, which can block the files and network the
  agent does not need

## 1Password

Nothing here is specific to Bitwarden. The same pattern maps onto the 1Password
CLI (`op`):

| Here | With 1Password |
|---|---|
| `bws-get KEY` | `op read -n "op://Vault/Item/field"` behind the same print guard |
| `bws-run -- CMD` | `op run -- CMD`, which masks secrets in the output |
| `bws-add`, `bws-rot` | a wrapper that sends the value on stdin (sketch below) |
| read-only token for the agent | a service account with read access to one vault |
| `BWS_AGENT_RW=1` plus ask rules | ask rules on `op item create`, `edit` and `delete`, plus Touch ID |

### Reading

`op read` prints the value, so it gets the same speed bump as `bws-get`. `-n`
drops the trailing newline:

```bash
op-get() {
  if [ -n "${CLAUDECODE:-}${AGENT_SHELL:-}" ] \
    && [ "${BASH_SUBSHELL:-0}" = 0 ] && [ "${ZSH_SUBSHELL:-0}" = 0 ]; then
    echo "op-get: use it inside \$(...) or a pipe, never bare" >&2
    return 3
  fi
  op read -n "$1"
}
```

### Running

`op run` resolves `op://` references in the environment for one command. By
default it masks any secret value the command prints to stdout or stderr:

```bash
export FORECAST_KEY="op://Agents/Forecast API/credential"
op run -- ./fetch-forecast.sh
```

- Never pass `--no-masking` or set `OP_RUN_NO_MASKING`. Put both on the ask list.
- Masking only matches exact copies of a value. A value that is base64 encoded,
  split up or changed by one character passes through.
- Your shell expands `$FORECAST_KEY` before `op run` starts, so
  `op run -- echo "$FORECAST_KEY"` only ever sees the `op://` reference. To use
  the resolved value in a command line, let a shell inside `op run` expand it:
  `op run -- sh -c 'curl -H "Authorization: Bearer $FORECAST_KEY" ...'`. The
  argv caveat from the threat model applies.
- `op run -- env` shows `<concealed by 1Password>` for each secret, a quick way
  to check the setup.

### Writing

`op item create` and `op item edit` take field assignments on the command line,
which puts the value in argv and in your shell history. The 1Password docs warn
about exactly that. Both also accept a JSON item on stdin, and that is the way
in for a wrapper.

The sketch below follows the same steps as `bws-add`. It refuses a title that
already exists in the vault in any case (1Password does not require unique
titles), reads the value from a hidden prompt or stdin, refuses empty values and
values with whitespace, and hands the value to `op` inside the JSON on stdin. It
has been tested against a mock `op` only. Check the field ids your template uses
with `op item template get "API Credential"` before you rely on it.

```bash
# op-add TITLE VAULT: the value comes from a hidden prompt or stdin, never argv.
op-add() {
  local title=$1 vault=$2 list v
  # Titles are not unique in 1Password, so refuse any item with the same title
  # in any case. The list holds titles and ids, no values.
  list=$(op item list --vault "$vault" --format json) || return 1
  if printf '%s' "$list" | python3 -c '
import json, sys
t = sys.argv[1].lower()
sys.exit(0 if any(i.get("title", "").lower() == t for i in json.load(sys.stdin)) else 1)
' "$title"; then
    echo "op-add: $vault already has an item titled $title (in some case), rotate it instead" >&2
    return 1
  fi
  if [ -t 0 ]; then
    printf 'value for %s: ' "$title" >&2
    IFS= read -rs v
    echo >&2
  else
    v=$(cat)
  fi
  [ -n "$v" ] || { echo "op-add: empty value, nothing stored" >&2; return 1; }
  case "$v" in
    # API keys have no whitespace. Loosen this for passphrases.
    *[[:space:]]*) echo "op-add: the value contains whitespace or a line break, nothing stored" >&2; return 2 ;;
  esac
  printf 'op-add: %s chars\n' "${#v}" >&2
  # Python fetches the template (field names, no secret) and fills in the value
  # from stdin, so the value never touches argv or a temp file.
  printf '%s' "$v" | python3 -c '
import json, subprocess, sys
title = sys.argv[1]
item = json.loads(subprocess.run(
    ["op", "item", "template", "get", "API Credential"],
    check=True, capture_output=True).stdout)
item["title"] = title
fields = [f for f in item.get("fields", []) if f.get("id") == "credential"]
if not fields:
    sys.exit("op-add: the template has no field with id credential, check yours")
fields[0]["value"] = sys.stdin.read()
json.dump(item, sys.stdout)
' "$title" | op item create --vault "$vault" - >/dev/null || return 1
  echo "op-add: $title stored in $vault" >&2
}
```

A rotation wrapper takes the same route. Read the new value from a hidden prompt
or stdin. Compare its sha256 with the sha256 of `op read -n` of the current
value, both inside pipes, and stop if they match. Then fetch the item with
`op item get ITEM --format json`, set the field in Python, and pipe the JSON into
`op item edit ITEM`. Check `op item edit --help` on your version first: an edit
from JSON replaces the item as a whole, and the docs warn that it overwrites a
passkey stored on the item.

### Touch ID as the approval gate

With the 1Password desktop app integration turned on, `op` asks for Touch ID (or
an Apple Watch, or the device password) before the first command in a new
terminal window or tab. That is a good human gate, with limits:

- It approves a session, not a call. A session lasts 10 minutes after the last
  command, renews with every command, and ends after 12 hours, when 1Password
  locks, or on `op signout`.
- It covers the whole account, every vault you can see, for reads and writes
  alike.
- How an agent's non-interactive shell counts as a session depends on the
  harness. Test it: approve one `op` call from the agent, then see whether its
  next call inside ten minutes asks again.
- Keep the ask rules. Touch ID tells you that `op` wants in, not which command
  is about to run.

### Service accounts for agents

For an agent, a 1Password service account is the closer match to the read-only
machine account:

- Its token goes in `OP_SERVICE_ACCOUNT_TOKEN`.
- It is scoped per vault, read or read and write, and its permissions are fixed
  when you create it. To change them, revoke it and create a new one.
- It cannot see the Personal, Private or Employee vaults or the default Shared
  vault, so give agent secrets a vault of their own.

The caveat from the `bws` read-only token holds here too: the agent can read the
service account token, so its vault grants are the real boundary.

### Ask rules for `op`

```json
{
  "permissions": {
    "ask": [
      "Bash(*op item create*)",
      "Bash(*op item edit*)",
      "Bash(*op item delete*)",
      "Bash(*op-add *)",
      "Bash(*OP_SERVICE_ACCOUNT_TOKEN*)",
      "Bash(*--no-masking*)",
      "Bash(*OP_RUN_NO_MASKING*)"
    ]
  }
}
```

### Sources

- [`op run`](https://developer.1password.com/docs/cli/reference/commands/run/)
- [`op read`](https://developer.1password.com/docs/cli/reference/commands/read/)
- [Create items](https://developer.1password.com/docs/cli/item-create/) and [edit items](https://developer.1password.com/docs/cli/item-edit/)
- [`op item`](https://developer.1password.com/docs/cli/reference/management-commands/item/)
- [App integration security](https://developer.1password.com/docs/cli/app-integration-security/)
- [Service accounts: get started](https://developer.1password.com/docs/service-accounts/get-started/) and [security](https://developer.1password.com/docs/service-accounts/security/)

## Tests and CI

```bash
shellcheck -s bash bws-helpers.sh tests/smoke.sh tests/bin/security scripts/scrub-check.sh scripts/dash-check.sh
tests/smoke.sh /bin/bash
tests/smoke.sh /bin/zsh
scripts/dash-check.sh
```

The smoke test runs every helper against the mock `bws` and `security` CLIs in an
empty environment (`env -i`), so no real token is ever in reach. CI runs it under
bash and zsh on Linux and macOS, along with shellcheck and a check that no file
holds an em or en dash.

## Cutting a public repo from a private one

If you adapt these helpers from a private setup of your own,
`scripts/scrub-check.sh` checks the result before it goes public:

```bash
scripts/scrub-check.sh ~/private/scrub-patterns.txt ~/private/original-helpers.sh
```

Each line of the patterns file is a string that must not appear in the repo:
your name, host names, address ranges, key names, project names. The script
counts each one across tracked files, untracked files that are not ignored, and
every commit message and author email on every branch. A zero only counts if
the same scan finds the pattern in a control file where it is known to be, so a
pattern with no control hit fails too. Keep the patterns file outside the repo.

## License

No license yet. Until a `LICENSE` file lands, all rights are reserved.
