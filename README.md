# claude-billing

Switch [Claude Code](https://claude.ai/code) between billing modes from the terminal.

| Mode | Description |
|------|-------------|
| `pro` | Claude Pro / Max subscription (claude.ai login) |
| `api` | Anthropic API key (pay-per-use) |
| `bedrock` | AWS Bedrock |

## Requirements

- macOS (credentials stored in Keychain)
- [jq](https://jqlang.github.io/jq/) — `brew install jq`
- AWS CLI — required for Bedrock only

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
claude-billing pro      # switch to Claude Pro / Max
claude-billing api      # switch to Anthropic API billing
claude-billing bedrock  # switch to AWS Bedrock
claude-billing status   # show current mode
claude-billing config   # reconfigure Bedrock region and model IDs
```

Restart Claude Code after switching for changes to take effect.

## How it works

- Edits `~/.claude/settings.json` to set the correct env vars and model IDs for each mode
- Backs up and restores your claude.ai OAuth token to/from Keychain so you don't need to re-login when switching back to Pro
- Bedrock model IDs are fetched live from `aws bedrock list-foundation-models` during setup so they're always valid for your region

## Bedrock model IDs

Model IDs are saved to `~/.claude-billing.conf` during install (or `claude-billing config`). Re-run `claude-billing config` whenever new Claude models are released to pick up updated IDs.

## Notes

- AWS profile is **not** managed by this tool — set it via your shell, direnv, or AWS config before launching Claude Code
- Currently macOS only due to Keychain dependency
