# claude-swarm

N Claude Code instances in Docker, coordinating through git.
No orchestrator, no message passing.

Based on the agent-team pattern from
[Building a C Compiler with Large Language Models](https://www.anthropic.com/engineering/building-c-compiler).

## Setup

Add as a submodule:

    git submodule add <url> tools/claude-swarm

## Usage

    export ANTHROPIC_API_KEY="sk-ant-..."
    export AGENT_PROMPT="path/to/prompt.md"
    ./tools/claude-swarm/launch.sh start
    ./tools/claude-swarm/launch.sh status
    ./tools/claude-swarm/launch.sh logs 1
    ./tools/claude-swarm/launch.sh stop

CLAUDE_MODEL defaults to claude-opus-4-6.
NUM_AGENTS defaults to 3.
MAX_IDLE defaults to 3 (exit after N consecutive idle sessions).

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
3. Runs an optional setup hook (`AGENT_SETUP`).
4. Loops: reset to `origin/agent-work`, run one Claude session.

Agents stop after MAX_IDLE consecutive sessions with no commits.

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| ANTHROPIC_API_KEY | yes | | API key. |
| AGENT_PROMPT | yes | | Path to prompt file (relative to repo root). |
| AGENT_SETUP | no | | Path to setup script (relative to repo root). |
| CLAUDE_MODEL | no | claude-opus-4-6 | Model for Claude Code. |
| NUM_AGENTS | no | 3 | Number of containers. |
| MAX_IDLE | no | 3 | Idle sessions before exit. |
| GIT_USER_NAME | no | swarm-agent | Git author name for agent commits. |
| GIT_USER_EMAIL | no | agent@claude-swarm.local | Git author email for agent commits. |
| ANTHROPIC_BASE_URL | no | | Override API URL (e.g. OpenRouter). |
| ANTHROPIC_AUTH_TOKEN | no | | Override auth token. |

## Inspect and harvest results

    ./tools/claude-swarm/progress.sh
    ./tools/claude-swarm/harvest.sh --dry
    ./tools/claude-swarm/harvest.sh

## Smoke test

    ANTHROPIC_API_KEY="sk-ant-..." ./tools/claude-swarm/test.sh

Launches NUM_AGENTS (default 2) with an embedded counting prompt,
verifies each agent writes deterministic output and pushes.

## Verify image

    docker run --rm --entrypoint bash \
        -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
        $(basename $(pwd))-agent \
        -c 'claude --dangerously-skip-permissions \
            -p "What model are you? Reply with the model id only." \
            --model claude-opus-4-6 2>&1'
