# Usage

## Quick start

```bash
# Interactive setup (generates swarm.json).
./setup.sh

# Or create a swarmfile manually and launch.
SWARM_CONFIG=swarm.json ./launch.sh start --dashboard
```

All configuration lives in the swarmfile (JSON).  Place a
`swarm.json` in your repo root or point to it with `SWARM_CONFIG`.

## Commands

```bash
./launch.sh start [--dashboard]   # Launch agents.
./launch.sh stop                  # Stop all agents.
./launch.sh status                # Show containers.
./launch.sh logs N                # Tail agent N logs.
./launch.sh wait                  # Block, harvest, post-process.
./launch.sh post-process          # Run post-process agent.
```

## Environment variables

Credentials stay as env vars (not in shell history).

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | | API key (or use `CLAUDE_CODE_OAUTH_TOKEN`). |
| `CLAUDE_CODE_OAUTH_TOKEN` | | OAuth token via `claude setup-token`. |
| `SWARM_CONFIG` | | Path to swarmfile (or place `swarm.json` in repo root). |
| `SWARM_TITLE` | | Dashboard title override. |
| `SWARM_SKIP_DEP_CHECK` | | Set to `1` to silence dependency version warnings. |

Per-group credentials (`api_key`, `auth_token`, `base_url`)
are set in the swarmfile.  Use `$VAR` references to pull
values from the host environment without hardcoding secrets.

## Config file fields

Per-group fields in `swarm.json` `agents` array:

| Field | Values | Notes |
|-------|--------|-------|
| `model` | model name | Required. |
| `count` | integer | Number of agents in this group. |
| `effort` | `low`, `medium`, `high` | Adaptive reasoning depth. |
| `context` | `full`, `slim`, `none` | How much of `.claude/` to keep (default: `full`). |
| `prompt` | file path | Per-group prompt override (default: top-level). |
| `auth` | `apikey`, `oauth`, omit | Which host credential to inject (see [Auth modes](#auth-modes)). |
| `api_key` | key or `$VAR` | Per-group API key for third-party endpoints. |
| `auth_token` | key or `$VAR` | Per-group Bearer token (OpenRouter-style). |
| `base_url` | URL | Per-group API endpoint. |
| `inject_git_rules` | `true`, `false` | Append git coordination rules to system prompt. |
| `driver` | driver name | Agent driver override (default: top-level or `claude-code`). |

Top-level fields: `prompt`, `setup`, `max_idle`, `driver`,
`inject_git_rules`, `claude_code_version`, `title`, `pricing`,
`post_process`.

The top-level `prompt` is optional when every agent group specifies its
own `prompt`.  When omitted, each group **must** provide one.

## Dashboard

```bash
./dashboard.sh
```

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

```
12:34:56 harness[1] session start at=abc123
12:35:01   agent[1] Read src/main.ts
12:35:03   agent[1] Edit src/main.ts
12:35:08   agent[1] Shell: npm test
12:35:12   agent[1] Shell: git add -A && git commit -m "fix tests"
12:35:15   agent[1] Shell: git push origin agent-work
12:35:18 harness[1] session end cost=$0.12 in=800 out=644 turns=6 time=19s
```

The filter (`lib/activity-filter.sh`) parses stream-json
events from the agent CLI and prints one line per tool call.
The timestamp and agent ID are colored in ANSI yellow
(matching git's commit-hash color) for readability.

## Testing

```bash
./tests/test.sh --help               # All options.
./tests/test.sh --unit               # Unit tests only.
./tests/test.sh                      # Single smoke test.
./tests/test.sh --all                # Full matrix.
./tests/test.sh --config swarm.json  # Custom config.
./tests/test.sh --no-inject          # Explicit git prompt.
```

Flags combine: `./tests/test.sh --config f.json --no-inject`.

The test harness uses its own built-in prompt (counting +
reasoning) regardless of config. The reasoning step exercises
adaptive thinking at different effort levels.

Unit tests (no Docker or API key):

```bash
./tests/test.sh --unit         # All unit tests.
./tests/test_config.sh         # Config parsing.
./tests/test_drivers.sh        # Agent driver interface.
./tests/test_format.sh         # Formatting helpers.
./tests/test_launch.sh         # Launch logic.
./tests/test_harness.sh        # Stat extraction.
./tests/test_costs.sh          # Cost aggregation.
./tests/test_harvest.sh        # Harvest git ops.
./tests/test_setup.sh          # Setup wizard.
```

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

Groups without `prompt` inherit the top-level value.  When every
group specifies its own prompt, the top-level `prompt` can be
omitted entirely:

```json
{
  "agents": [
    { "count": 2, "model": "claude-opus-4-6",
      "prompt": "tasks/hunt.md" },
    { "count": 1, "model": "claude-sonnet-4-6",
      "prompt": "tasks/review.md" }
  ]
}
```

Combined with context modes, this enables divergent exploration:
hunting agents run one prompt with full skills, a reconciliation
agent runs a different prompt to validate and normalize findings.

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

For subscription auth (Pro/Max/Teams/Enterprise), generate
an OAuth token with `claude setup-token` and export
`CLAUDE_CODE_OAUTH_TOKEN`.

Groups with `api_key` or `auth_token` ignore the `auth`
field; their custom credential is always used.  When neither
is set, `auth` determines which host credential to inject.

The dashboard **Auth** column reflects the actual credential
source: `key`, `oauth`, `token`, or `auto` (see Dashboard
columns).

## Git coordination

Agents receive git rules (commit/push/rebase) via a system
prompt appendix. Your task prompt only needs to describe the
work.

Disable with `"inject_git_rules": false` in the swarmfile.

## Cost tracking

```bash
./costs.sh          # Table.
./costs.sh --json   # JSON.
```

Stats collected per session inside each container
(`agent_logs/stats_agent_*.tsv`), read on demand.

Dashboard columns:

- **Auth** — credential source: `key` (API key), `oauth`
  (subscription token), `token` (Bearer / OpenRouter-style),
  `auto` (both key + OAuth present, CLI decides).
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

## Drivers

Agent drivers decouple the harness from any specific CLI tool.
Each driver (`lib/drivers/<name>.sh`) implements a fixed role
interface so the harness can run, monitor, and parse stats from
any supported agent.  Today only `claude-code` is production-
ready; the interface is designed to accommodate additional
agents in the future.

Built-in drivers:

| Driver | CLI | Default |
|--------|-----|---------|
| `claude-code` | `claude` | Yes |
| `gemini-cli` | `gemini` | |
| `fake` | (none) | Test double for unit testing |

Set the driver globally in `swarm.json`:

```json
{ "driver": "claude-code" }
```

Or per agent group:

```json
{
  "agents": [
    { "count": 2, "model": "claude-opus-4-6" },
    { "count": 1, "model": "other-model", "driver": "other-driver" }
  ]
}
```

Per-agent drivers inherit the top-level `driver` field, which
defaults to `claude-code`.

### Pinning Claude Code version

By default the Docker image installs the latest Claude Code CLI.
To pin a specific version, set `claude_code_version` in the
swarmfile:

```json
{ "claude_code_version": "1.0.30" }
```

### Writing a new driver

Create `lib/drivers/<name>.sh` implementing these functions:

```bash
agent_name()            # Human-readable name for commit trailers
agent_cmd()             # CLI command name
agent_version()         # Print version string to stdout
agent_run()             # Run one session (model, prompt, logfile, append_file)
agent_settings()        # Write agent config files into workspace
agent_extract_stats()   # Parse stats from log file (TSV output)
agent_detect_fatal()    # Detect fatal errors from log + exit code
agent_activity_jq()     # Return jq filter for activity streaming
agent_docker_env()      # Print -e flags for agent-specific env vars
agent_install_cmd()     # Dockerfile fragment to install the CLI
```

See `lib/drivers/claude-code.sh` for the reference implementation
and `lib/drivers/fake.sh` for a minimal test double.

### Dry-run with the fake driver

Use the `fake` driver to validate setup scripts, prompt paths, and
config without spending tokens or requiring API keys.  Create a
swarmfile that sets `"driver": "fake"`:

```json
{
  "prompt": "your-prompt.md",
  "setup": "your-setup.sh",
  "driver": "fake",
  "agents": [
    { "count": 1, "model": "fake" }
  ]
}
```

Then run it:

```bash
SWARM_CONFIG=dry-run.json ./launch.sh start --dashboard
```

The fake driver runs the full harness loop — cloning, setup script
execution, git hooks — but replaces the agent session with a
synthetic JSONL stream that completes instantly.  This catches
path errors, missing dependencies, and config issues before any
real agent run.

Clean up afterwards:

```bash
PROJECT=$(basename $(pwd))
docker rm -f ${PROJECT}-agent-1 2>/dev/null
rm -rf /tmp/${PROJECT}-upstream.git
```

## Cleanup

After a swarm run, the following artifacts remain on disk:

| Artifact | Path |
|----------|------|
| Bare repo | `/tmp/<project>-upstream.git` |
| Submodule mirrors | `/tmp/<project>-mirror-*.git` |
| Agent containers | `<project>-agent-N` |
| State file | `/tmp/<project>-swarm.env` |
| Agent config | `/tmp/<project>-agents.cfg` |

Remove everything for a fresh start:

```bash
PROJECT=$(basename $(pwd))
docker rm -f $(docker ps -aq --filter "name=${PROJECT}-agent-") 2>/dev/null
rm -rf /tmp/${PROJECT}-upstream.git /tmp/${PROJECT}-mirror-*.git
rm -f  /tmp/${PROJECT}-swarm.env /tmp/${PROJECT}-agents.cfg
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
