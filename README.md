# claude-billing

Switch [Claude Code](https://claude.ai/code) between billing modes from the terminal.

| Mode | Description |
|------|-------------|
| `subscription` | claude.ai subscription — Pro, Max, Teams, or Enterprise |
| `api` | Anthropic API key (pay-per-use) |
| `bedrock` | AWS Bedrock |

## Requirements

| Dependency | macOS | Linux | Windows (Git Bash) |
|------------|-------|-------|--------------------|
| `jq` | `brew install jq` | `apt install jq` / `dnf install jq` | `winget install jqlang.jq` |
| Credential store | Keychain (built-in) | `apt install libsecret-tools` | `~/.claude-billing-credentials` (auto-created) |
| AWS CLI | [aws.amazon.com/cli](https://aws.amazon.com/cli/) | [aws.amazon.com/cli](https://aws.amazon.com/cli/) | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |

AWS CLI is only required for Bedrock.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/hschin/claude-billing/main/install.sh | sh
```

Then reload your shell:

```sh
source ~/.zshrc   # or ~/.bashrc
```

## Usage

```sh
claude-billing subscription  # switch to claude.ai subscription (Pro, Max, Teams, Enterprise)
claude-billing api           # switch to Anthropic API billing
claude-billing bedrock       # switch to AWS Bedrock
claude-billing status        # show current mode
claude-billing config        # reconfigure Bedrock region and model IDs
claude-billing add-key       # save or update your Anthropic API key
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

## Notes

- AWS profile is **not** managed by this tool — set it via your shell, direnv, or AWS config before launching Claude Code
- Windows support requires Git Bash or WSL
