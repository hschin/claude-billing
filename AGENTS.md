# claude-billing agent guide

This repository contains a sourced shell utility for switching Claude Code among claude.ai subscriptions, Anthropic API billing, and AWS Bedrock. Changes must preserve user credentials and work in both Bash and zsh.

## Repository map

- `claude_billing.sh` contains the shell helpers, credential abstraction, account registry, Desktop-session switching, and `claude_billing()` dispatcher.
- `install.sh` installs or updates the sourced utility and the macOS menu-bar helper.
- `platform/macos/install-menubar.sh` builds, installs, and removes the optional native macOS menu-bar app.
- `menubar/` contains the AppKit app and Swift package tests.
- `test/run.sh` contains behavioral regression tests that run under both supported shells.
- `README.md` is the user-facing guide; `CLAUDE.md` contains additional maintainer context.

## Architecture and invariants

- The main script is sourced, not executed. Keep it compatible with Bash and zsh, including shells using `set -u`.
- Claude Code settings live in `~/.claude/settings.json`. Treat that file as the source of truth; `~/.claude-billing-mode` is only a prompt/statusline cache.
- Credential operations use macOS Keychain, GNOME Keyring, or the permission-restricted Windows fallback. Never log or persist plaintext secrets outside the established abstraction.
- Move credentials with store-before-delete ordering. Do not remove a live or stashed token until its replacement has been written successfully.
- Named subscription accounts use the registry in `~/.claude-billing-accounts`; the active account owns the live OAuth token.
- Bedrock profile resolution is explicit settings first, inherited `AWS_PROFILE` second, and `default` last. Indicators use `bedrock:<profile>`.
- Claude Desktop login ownership is independent of Claude Code billing. Desktop sessions are stashed per account, and the app must quit before session files are swapped. An explicit failed or cancelled `desktop <name>` command returns an error without changing ownership.
- API, Bedrock, and legacy subscription transitions roll back Claude Code settings when OAuth backup, restore, or login fails. Do not update the mode cache or print success before the transition completes.
- The menu-bar app consumes `status --json` and delegates switches and account management back to the shell utility. Do not duplicate credential or settings transition logic in Swift. Pass account names as separate process arguments, and keep interactive authentication, secret entry, and Bedrock configuration in the CLI.
- AWS SSO expiry is read-only: parse `~/.aws/config` for sessions/profiles and `~/.aws/sso/cache/*.json` for `expiresAt`. Group sessions by start URL, never write to the cache, and delegate refreshes to `aws sso login` via `sso-login <session>`. SSO state must not change the menu-bar badge.
- The menu-bar badge maps subscription, API, and Bedrock to `S`, `A`, and `B`. Claude Desktop state belongs in its separate dropdown section and does not affect the billing badge.

## Editing guidelines

- Guard optional positional parameters with `${n:-}`.
- Remember that zsh does not word-split ordinary unquoted variables; use established command-substitution iteration patterns.
- Preserve unrelated shell configuration when installing or uninstalling. Match managed marker blocks and legacy source lines exactly.
- Keep account names restricted to letters, digits, `-`, and `_`.
- Keep installer replacement atomic: download and validate temporary files before replacing installed copies.
- Preserve existing user changes and untracked files. Do not stage or commit unrelated work.
- Update tests and user documentation with every observable behavior change.
- Bump `_CB_VERSION` only as a separate release chore.

## Verification

Run all checks before claiming completion or committing:

```sh
bash -n claude_billing.sh install.sh platform/macos/install-menubar.sh test/run.sh
zsh -n claude_billing.sh install.sh test/run.sh
shellcheck claude_billing.sh install.sh platform/macos/install-menubar.sh test/run.sh
bash test/run.sh
zsh test/run.sh
swift test --package-path menubar   # macOS
git diff --check
```

Behavioral tests use isolated fake home directories and the Windows file-backed credential store. Never point tests at real user credentials or live Claude configuration.
