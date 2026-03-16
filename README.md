# swarm

N coding agents in Docker, coordinating through git.
No orchestrator, no message passing.  Agent-agnostic — supports
Claude Code, Gemini CLI, Codex CLI, and custom drivers.

Based on the agent-team pattern from
[Building a C Compiler with Large Language Models](https://www.anthropic.com/engineering/building-c-compiler).

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- bash (4.0+), git, jq, bc
- tput (ncurses) — used by the dashboard
- An API key, OAuth token, or compatible endpoint for your agent

Optional: `whiptail` for the interactive setup wizard TUI.
For development: `shellcheck` for linting.

## Setup

Add as a submodule:

```bash
git submodule add https://github.com/moodmosaic/claude-swarm.git tools/swarm
```

Or clone standalone and run from your project directory:

```bash
./path/to/swarm/launch.sh start --prompt tasks/task.md
```

## How it works

```
Host                         /tmp (bare repos)
~/project/ ── git clone ──>  project-upstream.git (rw)
               --bare        project-mirror-*.git (ro)
                                        |
                                        | docker volumes
                                        |
                 .-----------.----------+-----------.
                 |           |          |           |
           Container 1            Container 2       ...
           /upstream  (rw)        /upstream  (rw)
           /mirrors/* (ro)        /mirrors/* (ro)
                 |                      |
                 v                      v
           /workspace/            /workspace/
           (agent-work)           (agent-work)
```

All containers mount the same bare repo. Each runs
`lib/harness.sh` which loops: reset to `origin/agent-work`,
run one agent session, push. When one agent pushes, others
see the changes on the next fetch.

## Quick start

```bash
# Interactive setup (generates swarm.json).
./setup.sh

# Or launch directly.
ANTHROPIC_API_KEY="sk-ant-..." \
./launch.sh start --prompt tasks/task.md --agents 3

# Monitor.
./dashboard.sh
```

See [USAGE.md](USAGE.md) for all commands, CLI flags,
dashboard keys, and testing.

## Configuration

Place a `swarm.json` in your repo root:

```json
{
  "prompt": "prompts/task.md",
  "setup": "scripts/setup.sh",
  "max_idle": 3,
  "driver": "claude-code",
  "agents": [
    { "count": 2, "model": "claude-opus-4-6", "effort": "high" },
    { "count": 1, "model": "claude-opus-4-6", "context": "none" },
    { "count": 1, "model": "claude-sonnet-4-6", "prompt": "prompts/review.md" },
    {
      "count": 3,
      "model": "openrouter/custom",
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "sk-or-..."
    }
  ],
  "post_process": {
    "prompt": "prompts/review.md",
    "model": "claude-opus-4-6"
  }
}
```

Groups without `api_key` use `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_OAUTH_TOKEN` from the environment.

**Per-group fields:** `model`, `count`, `effort`, `context`,
`prompt`, `auth`, `api_key`, `auth_token`, `base_url`,
`driver`, `inject_git_rules`. See [USAGE.md](USAGE.md) for
field reference, environment variables, auth modes, context
modes, per-group prompts, and agent drivers.

## Drivers

Agent drivers decouple the harness from any specific CLI.
Each driver implements a fixed role interface:

| Function | Description |
| --- | --- |
| `agent_name` | Human-readable name (e.g. "Claude Code") |
| `agent_cmd` | CLI command (e.g. "claude") |
| `agent_version` | CLI version string |
| `agent_run` | Run one session, output JSONL |
| `agent_settings` | Write agent-specific settings |
| `agent_extract_stats` | Parse session stats from log |
| `agent_activity_jq` | jq filter for activity display |

Built-in drivers: `claude-code` (default), `fake` (test double).

To add a new agent, create `lib/drivers/<name>.sh` implementing
the interface above.  Then set `"driver": "<name>"` in your
config or `SWARM_DRIVER=<name>` in the environment.

Priority: CLI flags > config file > environment variables.
