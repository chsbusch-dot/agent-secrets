# agent-secrets

Shell helpers that let an AI coding agent use secrets from a secrets manager without
the secret values ever landing in the agent's context. The reference backend is
Bitwarden Secrets Manager (`bws`); the README shows how the same pattern maps onto
1Password (`op`).

## Layout

- `bws-helpers.sh`: the helpers. One file, sourced by bash 3.2+ or zsh 5+.
- `tests/smoke.sh SHELL`: the smoke test. Runs every helper against the mock CLIs in
  `tests/bin/` (a fake `bws` and a fake macOS `security`), never a real vault.
- `scripts/scrub-check.sh`: checks the repo against a private list of strings that
  must never appear in it, each proven against a control file where it does appear.
- `examples/`: Claude Code settings and a CLAUDE.md section to copy.

## Gate (run before every push)

```bash
shellcheck -s bash bws-helpers.sh tests/smoke.sh tests/bin/security scripts/scrub-check.sh scripts/dash-check.sh
for s in /bin/bash /bin/zsh; do tests/smoke.sh "$s"; done
scripts/dash-check.sh
```

CI runs the same checks: shellcheck and the dash check on Linux, the smoke test under bash
and zsh on Linux and macOS.

## Rules

- **Never print a secret value**, not even a test fixture from the real vault. Tool
  output is the agent's context. Show a value by its length or its shape (`bws-check`).
- **Tests use the mocks only.** Never point the smoke test or any example at a real
  token. Fixture values in `tests/smoke.sh` are fake and say so.
- **One file, two shells.** Every change to `bws-helpers.sh` must pass the smoke test
  under bash 3.2 (macOS `/bin/bash`), a current bash and zsh. Keep to the portable
  subset: no arrays, regexes held in variables, zsh-only syntax inside `eval`, and no
  variable named `path`, `status`, `match`, `argv`, `options` or `functions`.
- **Values never go through argv inside the helpers** except where the `bws` CLI
  itself requires it (create and edit). The README's threat model says so; keep it true.
- **No em or en dashes anywhere in the repo.** The README is public copy and CI
  greps every file.
- **Before the repo goes public**, run `scripts/scrub-check.sh` with the private
  pattern list (kept outside the repo) and work through the before-public checklist in the
  repo's first pull request. Only the owner changes repo visibility.
