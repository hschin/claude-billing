# claude-billing — Instant billing mode switching for Claude Code

[![CI](https://github.com/hschin/claude-billing/actions/workflows/ci.yml/badge.svg)](https://github.com/hschin/claude-billing/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](https://github.com/hschin/claude-billing#platform-support)
[![Shell](https://img.shields.io/badge/shell-bash%20%7C%20zsh-89E051?logo=gnubash)](https://github.com/hschin/claude-billing#notes)

A shell utility for switching [Claude Code](https://claude.ai/code) between billing modes without manually editing config files. Install once, switch instantly.

| Mode | Description |
|------|-------------|
| `subscription` | claude.ai subscription — Pro, Max, Teams, or Enterprise |
| `api` | Anthropic API key (pay-per-use) |
| `bedrock` | AWS Bedrock |

Each switch edits `~/.claude/settings.json` and handles credential backup and restore automatically.

## Requirements

| Dependency | macOS | Linux | Windows (Git Bash) |
|------------|-------|-------|--------------------|
| `jq` | `brew install jq` | `apt install jq` / `dnf install jq` | `winget install jqlang.jq` |
| Credential store | Keychain (built-in) | `apt install libsecret-tools` | `~/.claude-billing-credentials` (auto-created) |
| AWS CLI | [aws.amazon.com/cli](https://aws.amazon.com/cli/) | [aws.amazon.com/cli](https://aws.amazon.com/cli/) | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |

AWS CLI is only required for Bedrock.

## Platform support

The core Claude Code billing commands work across the supported shells on all three platforms. Desktop integration is currently available only on macOS.

| Feature | macOS | Linux | Windows (Git Bash or WSL) |
|---------|-------|-------|---------------------------|
| Subscription, Anthropic API, and Bedrock switching | Supported | Supported | Supported |
| Multiple subscription accounts | Supported | Supported | Supported |
| Prompt and statusline indicator | Supported | Supported | Supported |
| Claude Desktop account switching | Supported | Not yet supported | Not yet supported |
| Native menu bar or system tray app | Supported | Not yet supported | Not yet supported |

Contributions that add or improve Linux and Windows support—especially Claude Desktop account switching and native system tray integrations—are welcome.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/hschin/claude-billing/main/install.sh | bash
```

Re-running the installer updates the installed script atomically. If the download is interrupted or the downloaded script fails validation, the existing installation is left unchanged.

Then reload your shell:

```sh
source ~/.zshrc   # or ~/.bashrc
```

### What the installer asks

The installer walks through setup interactively. Everything is optional — you can skip any step and configure it later.

**1. Anthropic API key** *(optional)*
```
Do you want to save your Anthropic API key now? [y/N]:
```
Saves your key to the credential store (Keychain on macOS, GNOME Keyring on Linux, a chmod-600 file on Windows). Skip if you only use Bedrock or a subscription.

**2. Bedrock setup** *(optional)*
```
Set up Bedrock models now? [y/N]:
```
If you answer yes, you'll be walked through:

```
How should Claude Code choose the AWS profile for Bedrock?
  1) Inherit from shell / default AWS credential chain
  2) Set a specific AWS_PROFILE in Claude settings
Choose [1]:
```

Choose **1** if you use the default AWS profile or manage profiles via direnv / your shell. Choose **2** to pin a named profile directly into Claude Code's settings.

If you chose 2:
```
AWS profile name for Claude Code Bedrock calls: my-profile
Configure credentials for this profile now? [y/N]:
```

Then region and model IDs:
```
AWS region for Bedrock [us-east-1]: us-west-2

Fetching available Claude models in us-west-2...
  1) us.anthropic.claude-haiku-4-5-20251001-v1:0
  2) us.anthropic.claude-opus-4-7-20250514-v1:0
  3) us.anthropic.claude-sonnet-4-6-20250514-v1:0
  ...

Select Sonnet model number (or type an ID) []:
Select Opus model number (or type an ID) []:
Select Haiku model number (or type an ID) []:
```

If you skip Bedrock setup, a blank config is written and you can run `claude-billing config` at any time.

**3. claude.ai login** *(prompted only if no OAuth token is detected)*
```
No claude.ai login found. Log in to your subscription now? [y/N]:
```

## Usage

```sh
claude-billing subscription          # switch to claude.ai subscription (Pro, Max, Teams, Enterprise)
claude-billing api                   # switch to Anthropic API billing
claude-billing bedrock               # switch to AWS Bedrock
claude-billing status                # show current mode
claude-billing status --json         # machine-readable mode and account state
claude-billing accounts              # list registered subscription accounts
claude-billing add-account <name>    # register a claude.ai subscription account
claude-billing remove-account <name> # remove an account and its stored token
claude-billing desktop [name]        # show or switch the Claude.app desktop login (macOS)
claude-billing menubar install       # install the native menu bar app (macOS)
claude-billing menubar uninstall     # remove the native menu bar app (macOS)
claude-billing config                # reconfigure Bedrock region, models, and AWS profile
claude-billing add-key               # save or update your Anthropic API key
claude-billing login                 # log in to claude.ai
claude-billing uninstall             # remove claude-billing
```

Restart Claude Code after switching for changes to take effect.

## macOS menu bar app

The optional native menu bar app shows the current billing mode and lets you switch among registered subscription accounts, Anthropic API billing, and AWS Bedrock without opening a terminal. It requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). Install or update the command-line utility first, then run:

```sh
claude-billing menubar install
```

The menu bar uses a compact rounded monogram for the active mode: **S** for subscription, **A** for Anthropic API, and **B** for Bedrock. Hover over it for the active account or AWS profile. The dropdown labels this billing state as **Claude Code CLI**, uses native sections for subscription accounts and other billing providers, marks the current choice, and includes a restart reminder. A separate **Claude Desktop** section shows and switches the desktop app's account without changing the billing badge. While a switch is running, the badge becomes a progress indicator and other choices are temporarily disabled. It refreshes automatically and has a manual **Refresh** action. A billing switch updates the same Claude Code settings and prompt/statusline cache as the CLI; restart Claude Code afterward to apply it.

The **Manage Claude Code CLI** submenu can add and remove subscription accounts, configure AWS Bedrock, update the Anthropic API key, and start a Claude.ai login. Account names and removal confirmations use native dialogs. Authentication, secret entry, and Bedrock prompts continue in Terminal so the existing CLI remains responsible for credential handling and validation. Before changing the Claude Desktop account, the menu confirms that a running Claude Desktop will quit so its session files can be swapped safely, then reopen automatically. If that account has no saved desktop session yet, Claude Desktop reopens signed out; sign in once and later switches reuse it.

For Bedrock, an explicit configured AWS profile is deterministic and appears in the tooltip and current-mode row. A login item does not normally inherit a terminal's `AWS_PROFILE`, so inherited profile mode usually resolves to `default` when switched from the menu. Configure an explicit profile with `claude-billing config` if the menu should always select a particular AWS account.

The app starts automatically at login. Re-run the install command to update it. Remove only the menu bar app with:

```sh
claude-billing menubar uninstall
```

`claude-billing uninstall` also removes the menu bar app when it is installed.

## Multiple subscription accounts

If you have more than one claude.ai subscription (say, work and personal), register each as a named account and toggle between them:

```sh
# Register your current login under a name
claude-billing add-account work
# You're currently logged in to claude.ai. Save that login as 'work'? [Y/n]: y

# Register a second account — your current login is stashed, then a fresh login launches
claude-billing add-account personal

# Toggle between them (sub is a shorthand alias)
claude-billing subscription work
claude-billing sub personal
```

Switching stashes the outgoing account's OAuth token in the credential store and restores the incoming one, so you never re-authenticate once both are registered. Switching to `api` or `bedrock` stashes the active account's token the same way.

**Desktop app (macOS):** the Claude.app desktop login is managed separately from the CLI — the desktop app only ever uses a claude.ai subscription login (it has no API or Bedrock mode), so CLI billing switches never touch it. Move it explicitly:

```sh
claude-billing desktop          # show which account owns the desktop login
claude-billing desktop work     # switch Claude.app to 'work'
```

The app must quit for the swap (you'll be prompted), and each account's desktop session is stashed under `~/.claude-billing/desktop/<name>/` — the session cookies and token caches inside are encrypted with the app's own per-machine "Claude Safe Storage" key. If Claude.app was running before the switch, it reopens automatically afterward. The first switch asks which account currently owns the live desktop login so it can be stashed under the right name. Switching to an account with no stashed desktop session reopens Claude.app signed out; log in once and subsequent switches carry the login.

Once accounts are registered, `claude-billing subscription` requires the account name. Account names may contain letters, digits, `-`, and `_`.

```sh
claude-billing accounts
# Subscription accounts:
# * work (live login) [desktop]
#   personal (token stored)
```

`[desktop]` marks the account that owns the Claude.app desktop login (macOS).

## Prompt indicator

Every switch records the resulting mode in `~/.claude-billing-mode` (`sub:work`, `api`, `bedrock:work-aws`), so your shell prompt can show which billing you're on. Bedrock uses the configured explicit profile, the inherited `AWS_PROFILE`, or `default` when neither is set.

With [Starship](https://starship.rs), add to `~/.config/starship.toml`:

```toml
[custom.claude_billing]
command = "cat ~/.claude-billing-mode"
when = "test -s ~/.claude-billing-mode"
format = "[($output)]($style) "
style = "bold #DA7756"
shell = ["sh"]
```

For a plain zsh/bash prompt, the sourced script provides `claude_billing_prompt`, which prints the mode (empty before the first switch):

```sh
# zsh (.zshrc, after the claude-billing source line)
setopt PROMPT_SUBST
RPROMPT='%F{yellow}$(claude_billing_prompt)%f'

# bash (.bashrc)
PS1='$(claude_billing_prompt) '"$PS1"
```

The same file works in a [Claude Code status line](https://docs.claude.com/en/docs/claude-code/statusline). If you already have a `statusLine` command script, append the mode to its output:

```sh
billing=$(cat "$HOME/.claude-billing-mode" 2>/dev/null)
[ -n "$billing" ] && parts="$parts $billing"
```

Or for a minimal statusline from scratch, set in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "sh -c 'printf \"%s %s\" \"$(jq -r .model.display_name)\" \"$(cat ~/.claude-billing-mode 2>/dev/null)\"'"
}
```

The state file is only a cache — if you hand-edit `~/.claude/settings.json`, run `claude-billing status` to resync it.

## How it works

- Edits `~/.claude/settings.json` to set the correct env vars and model IDs for each mode
- Backs up and restores your claude.ai OAuth token to/from the credential store so you don't need to re-login when switching back to your subscription
- Named subscription accounts each get their own token slot in the credential store; a small registry file (`~/.claude-billing-accounts`) tracks which account owns the live token
- Bedrock model IDs are fetched live from `aws bedrock list-foundation-models` during setup so they're always valid for your region
- For API, Bedrock, and account-less subscription switches, a failed OAuth backup, restore, or login returns an error and restores the previous Claude Code settings

## Credential storage

| Platform | Store |
|----------|-------|
| macOS | Keychain via `security` CLI |
| Linux | GNOME Keyring via `secret-tool` |
| Windows (Git Bash) | `~/.claude-billing-credentials` (chmod 600) |

## Bedrock configuration

Model IDs and AWS profile settings are saved to `~/.claude-billing.conf` during install (or `claude-billing config`). Re-run `claude-billing config` whenever new Claude models are released to pick up updated IDs.

A typical `~/.claude-billing.conf`:

```sh
CLAUDE_BILLING_REGION="us-east-1"
CLAUDE_BILLING_SONNET="global.anthropic.claude-sonnet-4-6"
CLAUDE_BILLING_OPUS="global.anthropic.claude-opus-4-7"
CLAUDE_BILLING_HAIKU="global.anthropic.claude-haiku-4-5-20251001-v1:0"
CLAUDE_BILLING_AWS_PROFILE_MODE="inherit"
CLAUDE_BILLING_AWS_PROFILE=""
```

The `global.` prefix uses [Bedrock's global inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html), which route requests across regions for higher availability — recommended over pinning to a specific region.

Model IDs vary by region and change as new versions are released — `claude-billing config` fetches the current list from your account automatically.

### AWS profile

During `claude-billing config` you choose how Claude Code selects the AWS profile for Bedrock calls:

- **Inherit** (default): Claude Code uses whatever profile is active in your shell environment. Manage it via direnv, `AWS_PROFILE`, or `~/.aws/config`.
- **Explicit**: a specific `AWS_PROFILE` value is written to `~/.claude/settings.json` and always used when Claude Code is running, regardless of your shell environment.

Switching from explicit back to inherit removes `AWS_PROFILE` from `~/.claude/settings.json` so no stale value is left behind.

## Uninstall

```sh
claude-billing uninstall
```

Removes `~/.claude-billing/`, `~/.claude-billing.conf`, `~/.claude-billing-accounts`, and the exact source line from your shell RC file, and offers to delete stored secrets. Open a new shell to complete removal.

If the credential store rejects a requested secret deletion, uninstall finishes local cleanup but returns an error and identifies which credentials may remain. Resolve the credential-store issue and remove those entries manually using the service names below.

## Support boundaries

**Supported shells:** bash and zsh (the script is sourced, not executed, so it must be compatible with whichever shell you use).

**Supported platforms:** macOS, Linux, Windows via Git Bash or WSL.

**Files this tool reads and writes:**

| File | Purpose |
|------|---------|
| `~/.claude/settings.json` | Edited on every mode switch to set/remove env vars |
| `~/.claude/settings.json.bak` | Overwritten before each switch as a recovery backup |
| `~/.claude.json` | `oauthAccount` section swapped on account switch (backup in `~/.claude.json.bak`) |
| `~/.claude-billing.conf` | Stores your Bedrock region, model IDs, and AWS profile config |
| `~/.claude-billing-accounts` | Registry of named subscription accounts and which one is active |
| `~/.claude-billing-mode` | Current billing mode, for shell prompt indicators (resynced by `status`) |
| `~/.claude-billing/claude_billing.sh` | The installed script |
| `~/.claude-billing/desktop/<name>/` | Stashed Claude.app desktop logins (contents encrypted by Claude Safe Storage) |
| `~/Library/Application Support/Claude/` | Desktop app profile — `Cookies` and `config.json` swapped by `desktop <name>` (macOS) |
| `~/Applications/Claude Billing.app` | Optional native menu bar app (macOS) |
| `~/Library/LaunchAgents/com.hschin.claude-billing-menubar.plist` | Starts the optional menu bar app at login (macOS) |
| Your shell RC file (`.zshrc`, `.bashrc`, or `.profile`) | Source block added on install, removed on uninstall |

**Secrets stored (never written to disk unencrypted except on Windows):**

| Secret | Keychain service name |
|--------|-----------------------|
| Anthropic API key | `anthropic-api-key` |
| claude.ai OAuth token (live) | `Claude Code-credentials` |
| claude.ai OAuth token (backup) | `Claude Code-credentials-backup` |
| claude.ai OAuth token (named account) | `Claude Code-credentials-acct-<name>` |
| claude.ai account metadata (named account) | `Claude Code-oauthAccount-acct-<name>` |

On Windows (Git Bash), secrets are stored in `~/.claude-billing-credentials` with permissions `600`.

**Recovering from a bad switch:**

Those handled transition failures automatically restore the previous settings and return a non-zero status. If an unexpected interruption still leaves Claude Code in a broken state, restore the backup manually:
```sh
cp ~/.claude/settings.json.bak ~/.claude/settings.json
```

If your claude.ai OAuth token is missing after switching away from subscription:
```sh
claude-billing subscription   # triggers login if no backup is found
```

## Notes

- Windows support requires Git Bash or WSL
