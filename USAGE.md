# Usage

## Quick start

    # Interactive setup (generates swarm.json).
    ./setup.sh

    # Or configure via CLI flags.
    ANTHROPIC_API_KEY="sk-ant-..." \
    ./launch.sh start --prompt path/to/prompt.md

    # Or configure via environment.
    ANTHROPIC_API_KEY="sk-ant-..." \
    SWARM_PROMPT="path/to/prompt.md" \
    ./launch.sh start

## Commands

    ./launch.sh start [OPTIONS]    # Launch agents.
    ./launch.sh stop               # Stop all agents.
    ./launch.sh status             # Show containers.
    ./launch.sh logs N             # Tail agent N logs.
    ./launch.sh wait               # Block, harvest, post-process.
    ./launch.sh post-process       # Run post-process agent.

Start options (override env vars; config file sets agents):

    --prompt FILE           Prompt file path.
    --model MODEL           Model name (default: claude-opus-4-6).
    --agents N              Agent count (default: 3).
    --max-idle N            Idle sessions before exit (default: 3).
    --effort LEVEL          Reasoning effort: low, medium, high.
    --setup SCRIPT          Setup script path.
    --no-inject-git-rules   Disable git coordination rules.
    --dashboard             Open the TUI dashboard after launch.

Priority: CLI flags > config file > environment variables.
Credentials stay as env vars (not in shell history).

## Dashboard

    ./dashboard.sh

Per-agent model, auth source, status, cost, tokens, cache,
turns, throughput, and duration.  Updates every 2-3s.  The
header shows a compact model summary on a single line.

| Key | Action |
|-----|--------|
| `q` | Quit. |
| `1`-`9` | Logs for agent N. |
| `h` | Harvest results. |
| `s` | Stop all agents. |
| `p` | Post-process. |

## Activity streaming

Agent activity streams to Docker logs in real time. Press
`[1-9]` in the dashboard (or `./launch.sh logs N`) to see
what an agent is doing:

    12:34:56 harness[1] session start at=abc123
    12:35:01   agent[1] Read src/main.ts
    12:35:03   agent[1] Edit src/main.ts
    12:35:08   agent[1] Shell: npm test
    12:35:12   agent[1] Shell: git add -A && git commit -m "fix tests"
    12:35:15   agent[1] Shell: git push origin agent-work
    12:35:18 harness[1] session end cost=$0.12 in=800 out=644 turns=6 time=19s

The filter (`lib/activity-filter.sh`) parses `stream-json`
events from the Claude CLI and prints one line per tool call.
The timestamp and agent ID are colored in ANSI yellow
(matching git's commit-hash color) for readability.

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
| `2-agents-context-bare` | 2 | 1 full + 1 bare |
| `2-agents-context-slim` | 2 | 1 full + 1 slim |
| `2-agents-per-prompt` | 2 | per-group prompt override |

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

## Context modes

Motivated by [Evaluating AGENTS.md](https://arxiv.org/abs/2602.11988)
(Gloaguen et al.), which found that repository-level context files
can reduce agent success rates while increasing inference cost by
over 20%. This feature enables A/B comparisons within a single
swarm.

Control how much of `.claude/` each agent group sees:

| Mode | Behavior |
|------|----------|
| `full` | Keep `.claude/` as-is (default). |
| `slim` | Keep only `.claude/CLAUDE.md`, strip agents/skills. |
| `none` | Remove entire `.claude/` directory (bare agent). |

Set per group in `swarm.json`:

```json
{
  "agents": [
    { "count": 2, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-opus-4-6", "context": "none" }
  ]
}
```

Bare agents do exploratory work unconstrained by repo context
while other agents use skills and rules for structured output.
Non-default modes appear in the dashboard Ctx column and in
commit trailers (`> Ctx: bare`, `> Ctx: slim`).

## Per-group prompts

Each agent group can run a different prompt file:

```json
{
  "prompt": "tasks/hunt.md",
  "agents": [
    { "count": 2, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-sonnet-4-6",
      "prompt": "tasks/review.md" }
  ]
}
```

Groups without `prompt` inherit the top-level value. Combined
with context modes, this enables divergent exploration: hunting
agents run one prompt with full skills, a reconciliation agent
runs a different prompt to validate and normalize findings.

## Auth modes

Three credential mechanisms serve different purposes:

- **`auth`** — Controls which host credential
  (`ANTHROPIC_API_KEY` vs `CLAUDE_CODE_OAUTH_TOKEN`) is
  forwarded to the container.  Use when both credentials are
  set on the host and you want per-group billing control
  (e.g. some agents on API, others on subscription).
  Values: `apikey`, `oauth`, or omit (pass both).

- **`api_key`** — Per-group API key for third-party endpoints
  (MiniMax, etc.).  Passed as `ANTHROPIC_API_KEY` inside the
  container.  Supports `$VAR` references to host env vars.

- **`auth_token`** — Per-group Bearer token for endpoints
  that use `ANTHROPIC_AUTH_TOKEN` (OpenRouter-style).  Clears
  `ANTHROPIC_API_KEY` so Claude Code enters third-party mode.
  Supports `$VAR` references.

Groups with `api_key` or `auth_token` ignore the `auth`
field; their custom credential is always used.  When neither
is set, `auth` determines which host credential to inject.

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

Dashboard columns:

- **Ctx** — context mode: `bare` (no `.claude/`), `slim`
  (only `CLAUDE.md`), or blank for full context.
- **Cost** — cumulative API cost in USD.
- **In/Out** — input and output tokens.
- **Cache** — prompt cache read tokens. Higher means the API
  is reusing cached context instead of reprocessing it,
  reducing cost and latency. Cache creation tokens (the
  one-time cost of populating the cache) are recorded in
  the TSV but not shown separately.
- **Turns** — number of assistant turns across all sessions.
- **Tok/s** — output tokens per second of API time.
- **Time** — cumulative wall-clock duration.

## Cleanup

    rm -rf /tmp/<project>-upstream.git

## Verify image

    docker run --rm --entrypoint bash \
        -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
        $(basename $(pwd))-agent \
        -c 'claude --dangerously-skip-permissions \
            -p "What model are you? Reply with model id only." \
            --model claude-opus-4-6 2>&1'
