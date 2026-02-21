# claude-swarm

N Claude Code instances in Docker, coordinating through git.
No orchestrator, no message passing.

Based on the agent-team pattern from
[Building a C Compiler with Large Language Models](https://www.anthropic.com/engineering/building-c-compiler).

## Setup

Add as a submodule:

    git submodule add <url> tools/claude-swarm

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

All containers mount the same bare repo. When one agent
pushes, others see the changes on the next fetch.

Each container runs `harness.sh`:

1. Clones `/upstream` to `/workspace`.
2. Points submodule URLs at local read-only mirrors.
3. Runs an optional setup hook (`SWARM_SETUP`).
4. Loops: reset to `origin/agent-work`, run one Claude
   session.

Agents stop after `SWARM_MAX_IDLE` consecutive sessions
with no commits.

A session is one `claude` invocation. After it exits the
harness checks whether `agent-work` advanced. If not, the
idle counter increments. Any push by any agent resets it.

## Configuration

### Config file (recommended for mixed models)

Place a `swarm.json` in your repo root, or point to one
with `SWARM_CONFIG=/path/to/config.json`:

```json
{
  "prompt": "prompts/task.md",
  "setup": "scripts/setup.sh",
  "max_idle": 3,
  "agents": [
    { "count": 2, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-sonnet-4-5" },
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

Agent groups without `api_key` use `ANTHROPIC_API_KEY` from
the environment. Total agent count is the sum of all `count`
fields. Requires `jq` on the host.

### Environment variables (simple case)

| Variable | Default | Description |
|----------|---------|-------------|
| ANTHROPIC_API_KEY | (required) | API key. |
| SWARM_PROMPT | (required) | Prompt file path. |
| SWARM_CONFIG | | Config file path. |
| SWARM_SETUP | | Setup script path. |
| SWARM_MODEL | claude-opus-4-6 | Model. |
| SWARM_NUM_AGENTS | 3 | Container count. |
| SWARM_MAX_IDLE | 3 | Idle sessions before exit. |
| SWARM_GIT_USER_NAME | swarm-agent | Git author name. |
| SWARM_GIT_USER_EMAIL | agent@claude-swarm.local | Git email. |
| ANTHROPIC_BASE_URL | | Override API URL. |
| ANTHROPIC_AUTH_TOKEN | | Override auth token. |

Config file takes precedence over env vars when present.

## Commands and usage

See [USAGE.md](USAGE.md) for the full command reference,
including dashboard shortcuts, testing, and post-processing.
