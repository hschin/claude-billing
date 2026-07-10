# claude-billing

Shell utility (sourced, not executed — must work in bash AND zsh) that switches Claude Code between billing modes by editing `~/.claude/settings.json` and shuffling OAuth tokens in the platform credential store.

## Files

- `claude_billing.sh` — everything: helpers, credential abstraction, account registry, `claude_billing()` dispatcher, `claude-billing` alias
- `install.sh` — curl-pipe installer; adds `# >>> claude-billing >>>` block to RC file
- Installed to `~/.claude-billing/`; version in `_CB_VERSION` (bump on release, separate chore commit)

## Architecture

- Credential store per platform: macOS Keychain (`security`), Linux GNOME Keyring (`secret-tool`), Windows Git Bash `~/.claude-billing-credentials` (chmod 600). Abstracted via `_cb_cred_store/retrieve/delete`.
- Live OAuth token: keychain service `Claude Code-credentials`. Legacy single backup: `Claude Code-credentials-backup`. Named subscription accounts (v1.1.0+): `Claude Code-credentials-acct-<name>`.
- Account registry: `~/.claude-billing-accounts` (keys `CLAUDE_BILLING_ACCOUNTS` space-separated, `CLAUDE_BILLING_ACTIVE`). Active account's token is always the live one; inactive accounts hold stashed tokens. `_claude_billing_backup_oauth` stashes into the active account's slot (or legacy backup if none) and clears active.
- Once accounts are registered, `subscription`/`sub` requires a name; account-less usage keeps legacy single-backup behavior (backward compat).
- Bedrock config: `~/.claude-billing.conf` (region, model IDs incl. Fable, AWS profile mode).

## Gotchas

- zsh does NOT word-split unquoted variables — iterate lists via `$(command substitution)` (zsh splits those). This bit us once.
- Guard positional params with `${2:-}` (users may have `set -u`).
- Store-before-delete ordering for all token moves — never delete a token until its copy is confirmed written.
- `_cb_read` reads from `/dev/tty` when readable (curl-pipe installs).
- macOS `security add-generic-password -w` exposes value briefly in ps; no stdin option exists.

## Testing

- `shellcheck -s bash claude_billing.sh` (CI runs this) + `bash -n` / `zsh -n`
- Functional testing: source script with fake `$HOME`, force `_CB_PLATFORM="windows"` (file-based cred store), stub `claude()` and `_cb_read()`. Run tests in BOTH bash and zsh.
