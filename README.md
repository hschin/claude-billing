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

## Uninstall

```sh
claude-billing uninstall
```

Removes `~/.claude-billing/`, `~/.claude-billing.conf`, and the source line from your shell RC file. Open a new shell to complete removal.

## Usage

```sh
claude-billing subscription  # switch to claude.ai subscription (Pro, Max, Teams, Enterprise)
claude-billing api           # switch to Anthropic API billing
claude-billing bedrock       # switch to AWS Bedrock
claude-billing status        # show current mode
claude-billing config        # reconfigure Bedrock region and model IDs
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

## Bedrock model IDs

Model IDs are saved to `~/.claude-billing.conf` during install (or `claude-billing config`). Re-run `claude-billing config` whenever new Claude models are released to pick up updated IDs.

A typical `~/.claude-billing.conf` looks like:

```sh
CLAUDE_BILLING_REGION="us-east-1"
CLAUDE_BILLING_SONNET="global.anthropic.claude-sonnet-4-6"
CLAUDE_BILLING_OPUS="global.anthropic.claude-opus-4-7"
CLAUDE_BILLING_HAIKU="global.anthropic.claude-haiku-4-5-20251001-v1:0"
```

The `global.` prefix uses [Bedrock's global inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html), which route requests across regions for higher availability — recommended over pinning to a specific region.

Model IDs vary by region and change as new versions are released — the interactive `claude-billing config` fetches the current list from your account automatically.

## AWS profile

AWS profile is not managed by this tool — set it via direnv, your shell, or `~/.claude/settings.json` before launching Claude Code. During `claude-billing config` you can run `aws configure [--profile name]` to set up credentials for a profile, but which profile is active is left to your environment.

## Notes

- Windows support requires Git Bash or WSL
