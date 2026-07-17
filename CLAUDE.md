# claude-billing

Shell utility (sourced, not executed — must work in bash AND zsh) that switches Claude Code between billing modes by editing `~/.claude/settings.json` and shuffling OAuth tokens in the platform credential store.

## Files

- `claude_billing.sh` — everything: helpers, credential abstraction, account registry, `claude_billing()` dispatcher, `claude-billing` alias
- `install.sh` — curl-pipe installer; adds `# >>> claude-billing >>>` block to RC file
- Installed to `~/.claude-billing/`; version in `_CB_VERSION` (bump on release, separate chore commit)

## Architecture

- Credential store per platform: macOS Keychain (`security`), Linux GNOME Keyring (`secret-tool`), Windows Git Bash `~/.claude-billing-credentials` (chmod 600). Abstracted via `_cb_cred_store/retrieve/delete`.
- Live OAuth token: keychain service `Claude Code-credentials`. Legacy single backup: `Claude Code-credentials-backup`. Named subscription accounts (v1.1.0+): `Claude Code-credentials-acct-<name>`.
- Account identity metadata: Claude Code stores the logged-in account's identity (`oauthAccount`: account/org UUIDs, subscription type) in `~/.claude.json` — if it doesn't match the live token, Claude Code forces re-login. Per-account stash: `Claude Code-oauthAccount-acct-<name>`; swapped into `~/.claude.json` on restore via jq (`_cb_acct_meta_backup/_restore`). Best-effort: failures warn but don't abort the switch. Legacy (account-less) flow never swaps it — same account, still matches.
- Account registry: `~/.claude-billing-accounts` (keys `CLAUDE_BILLING_ACCOUNTS` space-separated, `CLAUDE_BILLING_ACTIVE`). Active account's token is always the live one; inactive accounts hold stashed tokens. `_claude_billing_backup_oauth` stashes into the active account's slot (or legacy backup if none) and clears active.
- Once accounts are registered, `subscription`/`sub` requires a name; account-less usage keeps legacy single-backup behavior (backward compat).
- Bedrock config: `~/.claude-billing.conf` (region, model IDs incl. Fable, AWS profile mode).
- Desktop app (Claude.app, macOS): login = `Cookies` SQLite (sessionKey, values encrypted by per-machine "Claude Safe Storage" keychain key — swappable between accounts) + `oauth:tokenCache`/`oauth:tokenCacheV2`/`lastKnownAccountUuid` in the app's `config.json`. Stashed per account in `~/.claude-billing/desktop/<name>/`; owner tracked in `desktop/.active`, fully independent of `CLAUDE_BILLING_ACTIVE` (v1.2.0+): the desktop only ever holds a subscription login, so it's switched ONLY by the explicit `desktop <name>` command — CLI billing switches never touch it (`subscription` prints a hint when desktop owner differs). First `desktop` switch prompts for who owns the live login (seeds `.active`); unknown owner → safety copy in `desktop/.unclaimed`. App must be quit before swap (Chromium rewrites cookies on exit); `_cb_desktop_quit` prompts + osascript. All desktop failures warn but never fail the switch.
- Prompt indicator: every switch writes the mode (`sub`, `sub:<name>`, `api`, `bedrock`) to `~/.claude-billing-mode`; `claude_billing_prompt` prints it for shell prompts, and `status` resyncs the file from settings.json (source of truth). User's machine wires it via a `[custom.claude_billing]` module in `~/.config/starship.toml` (not in repo).

## Gotchas

- zsh does NOT word-split unquoted variables — iterate lists via `$(command substitution)` (zsh splits those). This bit us once.
- Guard positional params with `${2:-}` (users may have `set -u`).
- Store-before-delete ordering for all token moves — never delete a token until its copy is confirmed written.
- `_cb_read` reads from `/dev/tty` when readable (curl-pipe installs).
- macOS `security add-generic-password -w` exposes value briefly in ps; no stdin option exists.

## Testing

- `shellcheck -s bash claude_billing.sh` (CI runs this) + `bash -n` / `zsh -n`
- Functional testing: source script with fake `$HOME`, force `_CB_PLATFORM="windows"` (file-based cred store), stub `claude()` and `_cb_read()`. Run tests in BOTH bash and zsh.
