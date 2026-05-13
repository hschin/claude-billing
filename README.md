# claude-billing — Instant billing mode switching for Claude Code

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

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/hschin/claude-billing/main/install.sh | bash
```

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
claude-billing subscription  # switch to claude.ai subscription (Pro, Max, Teams, Enterprise)
claude-billing api           # switch to Anthropic API billing
claude-billing bedrock       # switch to AWS Bedrock
claude-billing status        # show current mode
claude-billing config        # reconfigure Bedrock region, models, and AWS profile
claude-billing add-key       # save or update your Anthropic API key
claude-billing login         # log in to claude.ai
claude-billing uninstall     # remove claude-billing
```

Restart Claude Code after switching for changes to take effect.

## How it works

- Edits `~/.claude/settings.json` to set the correct env vars and model IDs for each mode
- Backs up and restores your claude.ai OAuth token to/from the credential store so you don't need to re-login when switching back to your subscription
- Bedrock model IDs are fetched live from `aws bedrock list-foundation-models` during setup so they're always valid for your region

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

Removes `~/.claude-billing/`, `~/.claude-billing.conf`, and the source line from your shell RC file. Open a new shell to complete removal.

## Support boundaries

**Supported shells:** bash and zsh (the script is sourced, not executed, so it must be compatible with whichever shell you use).

**Supported platforms:** macOS, Linux, Windows via Git Bash or WSL.

**Files this tool reads and writes:**

| File | Purpose |
|------|---------|
| `~/.claude/settings.json` | Edited on every mode switch to set/remove env vars |
| `~/.claude/settings.json.bak` | Overwritten before each switch as a recovery backup |
| `~/.claude-billing.conf` | Stores your Bedrock region, model IDs, and AWS profile config |
| `~/.claude-billing/claude_billing.sh` | The installed script |
| Your shell RC file (`.zshrc`, `.bashrc`, or `.profile`) | Source block added on install, removed on uninstall |

**Secrets stored (never written to disk unencrypted except on Windows):**

| Secret | Keychain service name |
|--------|-----------------------|
| Anthropic API key | `anthropic-api-key` |
| claude.ai OAuth token (live) | `Claude Code-credentials` |
| claude.ai OAuth token (backup) | `Claude Code-credentials-backup` |

On Windows (Git Bash), secrets are stored in `~/.claude-billing-credentials` with permissions `600`.

**Recovering from a bad switch:**

If a switch leaves Claude Code in a broken state, restore the previous settings:
```sh
cp ~/.claude/settings.json.bak ~/.claude/settings.json
```

If your claude.ai OAuth token is missing after switching away from subscription:
```sh
claude-billing subscription   # triggers login if no backup is found
```

## Notes

- Windows support requires Git Bash or WSL
