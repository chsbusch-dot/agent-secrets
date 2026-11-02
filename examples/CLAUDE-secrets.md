## Secrets

Secrets live in Bitwarden Secrets Manager and reach commands through the
`bws-*` shell helpers. Everything you print lands in this conversation, so a
printed secret is a leaked secret.

- Never put a secret value in a file, in code, in a commit, in a message or in
  command output.
- Use a value inside the command that needs it: `KEY=$(bws-get KEY) ./tool`.
  Never run `bws-get` bare, and never `echo`, `env` or `printenv` a secret.
- To check a value, run `bws-check KEY`. It shows the length and shape, never
  the value. To see what exists, run `bws-ls`.
- This shell is read-only. A write needs `BWS_AGENT_RW=1` in front of the
  command, and the human approves it at the prompt.
  - A value you generate: pipe it in,
    `openssl rand -hex 32 | BWS_AGENT_RW=1 bws-add NAME "what it is for"`.
  - A value the human holds: ask them to run `bws-add NAME` in their own
    terminal. Never ask them to paste it into the chat.
- Never delete a secret. Ask the human to run `bws-rm NAME`.
- An empty result proves nothing on its own. Before concluding that a secret is
  missing or empty, read a key you know exists in the same command and compare.
- Never look for other tokens, and never read the keychain or the token files
  directly. If the read-only token cannot reach a secret, say so and ask the
  human to grant access.
