# Test configs for mixed-model smoke tests

These configs are used with `./tests/test.sh --config <file>` to run
integration tests against multiple providers and agent configurations.

## Setup

Export the API keys needed by your chosen config:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
export OPENROUTER_API_KEY="sk-or-v1-..."
export MINIMAX_API_KEY="sk-api-..."
```

Verify they're set:

```bash
for v in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENROUTER_API_KEY MINIMAX_API_KEY; do
  printf "%-30s %s\n" "$v" "${!v:+(set)}"
done
```

## Configs

| Config | Agents | Required keys |
|---|---|---|
| `mixed-effort-auth.json` | 2x Opus + 1x Sonnet | `ANTHROPIC_API_KEY` + `CLAUDE_CODE_OAUTH_TOKEN` |
| `mixed-context.json` | 3x Opus (full/none/slim) | `CLAUDE_CODE_OAUTH_TOKEN` |
| `mixed-providers.json` | Opus + GPT-5.4 + MiniMax | `CLAUDE_CODE_OAUTH_TOKEN` + `OPENROUTER_API_KEY` + `MINIMAX_API_KEY` |
| `kitchen-sink.json` | All 6 variants | All four keys |
| `no-tags.json` | 2x Opus + 1x Sonnet, no tags | `ANTHROPIC_API_KEY` + `CLAUDE_CODE_OAUTH_TOKEN` |

## Usage

```bash
./tests/test.sh --config tests/configs/mixed-effort-auth.json
./tests/test.sh --config tests/configs/mixed-context.json
./tests/test.sh --config tests/configs/mixed-providers.json
./tests/test.sh --config tests/configs/kitchen-sink.json
./tests/test.sh --config tests/configs/no-tags.json
```

The test runner injects its own prompt and setup script into the config,
so the `"prompt": "unused"` field is overwritten at runtime.
