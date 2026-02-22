# Usage

## Quick start

```bash
# Interactive setup (generates swarm.json).
./tools/claude-swarm/setup.sh

# Or configure via environment.
export ANTHROPIC_API_KEY="sk-ant-..."
export SWARM_PROMPT="path/to/prompt.md"
./tools/claude-swarm/launch.sh start
```

## Commands

```bash
./launch.sh start              # Launch agents.
./launch.sh start --dashboard  # Launch agents and open TUI.
./launch.sh stop               # Stop all agents.
./launch.sh status             # Show running containers.
./launch.sh logs N             # Tail logs for agent N.
./launch.sh wait               # Block until done, harvest,
                               # and post-process if configured.
./launch.sh post-process       # Run post-processing agent.
```

## Dashboard

```bash
./dashboard.sh                 # Attach to TUI dashboard.
```

Shows agent status, models, cost, token usage, agentic
turns, duration, and recent commits (with model
attribution). Stats update live as sessions complete.

Keyboard shortcuts:

| Key   | Action              |
|-------|---------------------|
| `q`   | Quit dashboard.     |
| `l N` | Logs for agent N.   |
| `h`   | Harvest results.    |
| `s`   | Stop all agents.    |
| `p`   | Post-process.       |

Re-run `./dashboard.sh` to re-attach while agents run.

## Testing

Basic smoke test (uses injected git rules):

```bash
ANTHROPIC_API_KEY="sk-..." ./test.sh
```

With a specific model:

```bash
ANTHROPIC_API_KEY="sk-..." SWARM_MODEL="claude-sonnet-4-6" \
    ./test.sh
```

With a config file (mixed models):

```bash
ANTHROPIC_API_KEY="sk-..." ./test.sh --config swarm.json
```

Backward compatibility (explicit git commands in prompt,
no git rule injection):

```bash
ANTHROPIC_API_KEY="sk-..." ./test.sh --no-inject
```

Flags combine freely: `./test.sh --config swarm.json --no-inject`.

`test.sh` always uses its own built-in prompt regardless of
what the config file specifies.

Full suite (unit tests then integration matrix):

```bash
ANTHROPIC_API_KEY="sk-..." ./test.sh --all
```

Unit tests only (no Docker or API key needed):

```bash
./test_config.sh     # Config parsing.
./test_format.sh     # Formatting helpers.
./test_launch.sh     # Launch logic.
./test_harness.sh    # Harness stat extraction.
./test_costs.sh      # Cost aggregation.
./test_harvest.sh    # Harvest git ops.
./test_setup.sh      # Setup wizard config.
```

## Post-processing

Add a `post_process` section to `swarm.json`:

```json
{
  "post_process": {
    "prompt": "prompts/review.md",
    "model": "claude-opus-4-6"
  }
}
```

Trigger via `[p]` in the dashboard, `./launch.sh post-process`,
or automatically through `./launch.sh wait`.

The post-process agent clones the same bare repo, sees all
agent commits on `agent-work`, runs its prompt, and pushes.

## Git coordination

Agents automatically receive git rules (commit, push, rebase
workflow) via a system prompt appendix. This means your task
prompt does not need to explain the git machinery -- just
describe the work.

To disable, set `"inject_git_rules": false` in `swarm.json`
or `SWARM_INJECT_GIT_RULES=false` as an env var.

## Cost tracking

The dashboard shows per-agent and total cost, tokens, and
duration in real time. For a non-interactive summary:

```bash
./costs.sh                     # Table output.
./costs.sh --json              # Machine-readable JSON.
```

Stats are collected per session inside each container
(`agent_logs/stats_agent_*.tsv`) and read on demand.

## Cleanup

Remove the bare repo after testing:

```bash
rm -rf /tmp/<project>-upstream.git
```

## Verify image

```bash
docker run --rm --entrypoint bash \
    -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
    $(basename $(pwd))-agent \
    -c 'claude --dangerously-skip-permissions \
        -p "What model are you? Reply with model id only." \
        --model claude-opus-4-6 2>&1'
```
