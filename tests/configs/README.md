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
export GEMINI_API_KEY="AI..."
```

Verify they're set:

```bash
for v in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENROUTER_API_KEY MINIMAX_API_KEY GEMINI_API_KEY; do
  printf "%-30s %s\n" "$v" "${!v:+(set)}"
done
```

## Configs

| Config | Agents | Driver | Required keys |
|---|---|---|---|
| `mixed-effort-auth.json` | 2x Opus + 1x Sonnet | claude-code | `ANTHROPIC_API_KEY` + `CLAUDE_CODE_OAUTH_TOKEN` |
| `mixed-context.json` | 3x Opus (full/none/slim) | claude-code | `CLAUDE_CODE_OAUTH_TOKEN` |
| `mixed-providers.json` | Opus + GPT-5.4 + MiniMax-M2.5 | claude-code | `CLAUDE_CODE_OAUTH_TOKEN` + `OPENROUTER_API_KEY` + `MINIMAX_API_KEY` |
| `kitchen-sink.json` | 4x Opus + Sonnet + MiniMax-M2.7 | claude-code | `ANTHROPIC_API_KEY` + `CLAUDE_CODE_OAUTH_TOKEN` + `OPENROUTER_API_KEY` + `MINIMAX_API_KEY` |
| `no-tags.json` | 2x Opus + 1x Sonnet, no tags | claude-code | `ANTHROPIC_API_KEY` + `CLAUDE_CODE_OAUTH_TOKEN` |
| `gemini-only.json` | 2x gemini-2.5-pro | gemini-cli | `GEMINI_API_KEY` |
| `mixed-drivers.json` | 2x Opus + 1x gemini-2.5-pro | mixed | `CLAUDE_CODE_OAUTH_TOKEN` + `GEMINI_API_KEY` |
| `driver-inheritance.json` | gemini-2.5-pro + gemini-2.5-flash | gemini-cli | `GEMINI_API_KEY` |
| `driver-post-process.json` | 2x gemini-2.5-pro (+ flash PP) | gemini-cli | `GEMINI_API_KEY` |
| `heterogeneous-kitchen-sink.json` | Opus + 5x Gemini + Sonnet (+ PP) | mixed | `CLAUDE_CODE_OAUTH_TOKEN` + `ANTHROPIC_API_KEY` + `GEMINI_API_KEY` |

## Usage

```bash
./tests/test.sh --config tests/configs/mixed-effort-auth.json
./tests/test.sh --config tests/configs/mixed-context.json
./tests/test.sh --config tests/configs/mixed-providers.json
./tests/test.sh --config tests/configs/kitchen-sink.json
./tests/test.sh --config tests/configs/no-tags.json
./tests/test.sh --config tests/configs/gemini-only.json
./tests/test.sh --config tests/configs/mixed-drivers.json
./tests/test.sh --config tests/configs/driver-inheritance.json
./tests/test.sh --config tests/configs/driver-post-process.json
./tests/test.sh --config tests/configs/heterogeneous-kitchen-sink.json
```

The test runner injects its own prompt and setup script into the config,
so the `"prompt": "unused"` field is overwritten at runtime.
