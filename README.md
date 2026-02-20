# claude-swarm

N Claude Code instances in Docker, coordinating through git.
No orchestrator, no message passing.

Based on the agent-team pattern from
[Building a C Compiler with Large Language Models](https://www.anthropic.com/engineering/building-c-compiler).

## Setup

Add as a submodule:

    git submodule add <url> tools/claude-swarm

## Usage

Interactive setup (produces `swarm.json`):

    ./tools/claude-swarm/setup.sh

Or configure manually:

    export ANTHROPIC_API_KEY="sk-ant-..."
    export SWARM_PROMPT="path/to/prompt.md"
    ./tools/claude-swarm/launch.sh start
    ./tools/claude-swarm/launch.sh status
    ./tools/claude-swarm/launch.sh logs 1
    ./tools/claude-swarm/launch.sh wait
    ./tools/claude-swarm/launch.sh stop

SWARM_MODEL defaults to claude-opus-4-6.
SWARM_NUM_AGENTS defaults to 3.
SWARM_MAX_IDLE defaults to 3 (exit after N consecutive idle sessions).

## How it works

```
Host                             /tmp (bare repos)
~/project/ ── git clone ──>      project-upstream.git (rw)
               --bare            project-mirror-*.git (ro)
                                          |
                                          | docker volumes
                                          |
                 .-----------.------------+-----------.-----------.
                 |           |            |           |           |
           Container 1            Container 2            Container 3
           /upstream  (rw)        /upstream  (rw)        /upstream  (rw)
           /mirrors/* (ro)        /mirrors/* (ro)        /mirrors/* (ro)
                 |                      |                      |
                 v                      v                      v
           /workspace/            /workspace/            /workspace/
           (agent-work)           (agent-work)           (agent-work)
```

All containers mount the same bare repo. When one agent pushes,
others see the changes on the next fetch.

Each container runs `harness.sh`:

1. Clones `/upstream` to `/workspace`.
2. Points submodule URLs at local read-only mirrors.
3. Runs an optional setup hook (`SWARM_SETUP`).
4. Loops: reset to `origin/agent-work`, run one Claude session.

Agents stop after SWARM_MAX_IDLE consecutive sessions with no commits.

## Configuration

### Config file (recommended for mixed models)

Place a `swarm.json` in your repo root, or point to one with
`SWARM_CONFIG=/path/to/config.json`:

```json
{
  "prompt": "prompts/task.md",
  "setup": "scripts/setup.sh",
  "max_idle": 3,
  "git_user": { "name": "swarm-agent", "email": "agent@claude-swarm.local" },
  "agents": [
    { "count": 2, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-sonnet-4-5" },
    {
      "count": 3,
      "model": "openrouter/custom",
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "sk-or-..."
    }
  ]
}
```

Agent groups without `api_key` use `ANTHROPIC_API_KEY` from the
environment. Total agent count is the sum of all `count` fields.

Requires `jq` on the host.

### Environment variables (simple case)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| ANTHROPIC_API_KEY | yes | | API key. |
| SWARM_PROMPT | yes | | Path to prompt file (relative to repo root). |
| SWARM_CONFIG | no | | Path to config file (auto-detects swarm.json). |
| SWARM_SETUP | no | | Path to setup script (relative to repo root). |
| SWARM_MODEL | no | claude-opus-4-6 | Model for Claude Code. |
| SWARM_NUM_AGENTS | no | 3 | Number of containers. |
| SWARM_MAX_IDLE | no | 3 | Idle sessions before exit. |
| SWARM_GIT_USER_NAME | no | swarm-agent | Git author name for agent commits. |
| SWARM_GIT_USER_EMAIL | no | agent@claude-swarm.local | Git author email for agent commits. |
| ANTHROPIC_BASE_URL | no | | Override API URL (e.g. OpenRouter). |
| ANTHROPIC_AUTH_TOKEN | no | | Override auth token. |

When a config file is present it takes precedence over env vars.

## Dashboard

    ./tools/claude-swarm/dashboard.sh

Always-on TUI showing agent status, models, session counts, and
recent commits. Keyboard shortcuts: `q` quit, `1`-`9` show agent
logs, `h` harvest, `s` stop all, `p` post-process.

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

After all agents finish (or manually):

    ./tools/claude-swarm/launch.sh wait          # blocks until done, then post-processes + harvests
    ./tools/claude-swarm/launch.sh post-process   # run post-processing immediately

The `wait` command polls until all agents exit, then launches a
single post-processing agent with a different prompt against the
same bare repo.  The post-processing agent sees all agent commits
on `agent-work`, does its review/consolidation, and pushes.
Results are harvested automatically.

## Inspect and harvest results

    ./tools/claude-swarm/progress.sh
    ./tools/claude-swarm/harvest.sh --dry
    ./tools/claude-swarm/harvest.sh

## Smoke test

    ANTHROPIC_API_KEY="sk-ant-..." ./tools/claude-swarm/test.sh

Launches SWARM_NUM_AGENTS (default 2) agents with an embedded counting prompt,
verifies each agent writes deterministic output and pushes.

## Verify image

    docker run --rm --entrypoint bash \
        -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
        $(basename $(pwd))-agent \
        -c 'claude --dangerously-skip-permissions \
            -p "What model are you? Reply with the model id only." \
            --model claude-opus-4-6 2>&1'
