# Usage

## Quick start

    # Interactive setup (generates swarm.json).
    ./setup.sh

    # Or configure via environment.
    ANTHROPIC_API_KEY="sk-ant-..." \
    SWARM_PROMPT="path/to/prompt.md" \
    ./launch.sh start

## Commands

    ./launch.sh start              # Launch agents.
    ./launch.sh start --dashboard  # Launch + open TUI.
    ./launch.sh stop               # Stop all agents.
    ./launch.sh status             # Show containers.
    ./launch.sh logs N             # Tail agent N logs.
    ./launch.sh wait               # Block, harvest, post-process.
    ./launch.sh post-process       # Run post-process agent.

## Dashboard

    ./dashboard.sh

Per-agent model, auth source, status, cost, tokens, cache,
turns, and duration. Updates every 2s.

| Key | Action |
|-----|--------|
| `q` | Quit. |
| `1`-`9` | Logs for agent N. |
| `h` | Harvest results. |
| `s` | Stop all agents. |
| `p` | Post-process. |

## Testing

    ./tests/test.sh --help               # All options.
    ./tests/test.sh --unit               # Unit tests only.
    ./tests/test.sh                      # Single smoke test.
    ./tests/test.sh --all                # Full matrix.
    ./tests/test.sh --config swarm.json  # Custom config.
    ./tests/test.sh --no-inject          # Explicit git prompt.

Flags combine: `./tests/test.sh --config f.json --no-inject`.

The test harness uses its own built-in prompt (counting +
reasoning) regardless of config. The reasoning step exercises
adaptive thinking at different effort levels.

Integration matrix (`--all`):

| Case | Agents | Notes |
|------|--------|-------|
| `1-agent-env` | 1 | |
| `2-agents-env` | 2 | |
| `3-agents-env` | 3 | |
| `2-agents-no-inject` | 2 | `--no-inject` |
| `2-agents-sonnet` | 2 | sonnet model |
| `2-agents-config` | 2 | swarm.json |
| `3-agents-mixed` | 3 | opus + sonnet |
| `1-agent-effort-env` | 1 | effort via env |
| `2-agents-effort-cfg` | 2 | effort via config |
| `2-agents-postprocess` | 2 | + post-process |

Unit tests (no Docker or API key):

    ./tests/test.sh --unit         # All unit tests.
    ./tests/test_config.sh         # Config parsing.
    ./tests/test_format.sh         # Formatting helpers.
    ./tests/test_launch.sh         # Launch logic.
    ./tests/test_harness.sh        # Stat extraction.
    ./tests/test_costs.sh          # Cost aggregation.
    ./tests/test_harvest.sh        # Harvest git ops.
    ./tests/test_setup.sh          # Setup wizard.

## Post-processing

Add to `swarm.json`:

```json
{
  "post_process": {
    "prompt": "prompts/review.md",
    "model": "claude-opus-4-6",
    "effort": "low"
  }
}
```

Trigger via `[p]` in the dashboard, `./launch.sh post-process`,
or automatically via `./launch.sh wait`.

The post-process agent clones the same bare repo, sees all
commits on `agent-work`, runs its prompt, and pushes.

## Git coordination

Agents receive git rules (commit/push/rebase) via a system
prompt appendix. Your task prompt only needs to describe the
work.

Disable with `"inject_git_rules": false` in `swarm.json` or
`SWARM_INJECT_GIT_RULES=false`.

## Cost tracking

    ./costs.sh          # Table.
    ./costs.sh --json   # JSON.

Stats collected per session inside each container
(`agent_logs/stats_agent_*.tsv`), read on demand.

## Cleanup

    rm -rf /tmp/<project>-upstream.git

## Verify image

    docker run --rm --entrypoint bash \
        -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
        $(basename $(pwd))-agent \
        -c 'claude --dangerously-skip-permissions \
            -p "What model are you? Reply with model id only." \
            --model claude-opus-4-6 2>&1'
