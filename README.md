# claude-swarm

N Claude Code instances in Docker, coordinating through git.
No orchestrator, no message passing.

Based on the agent-team pattern from
[Building a C Compiler with Large Language Models](https://www.anthropic.com/engineering/building-c-compiler).

## Prerequisites

- Docker
- bash, git, jq, bc
- An Anthropic API key, OAuth token, or compatible endpoint

## Setup

Add as a submodule:

```bash
git submodule add https://github.com/moodmosaic/claude-swarm.git tools/claude-swarm
```

Or clone standalone and run from your project directory:

```bash
./path/to/claude-swarm/launch.sh start --prompt tasks/task.md
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
run one Claude session, push. When one agent pushes, others
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
`inject_git_rules`. See [USAGE.md](USAGE.md) for field
reference, environment variables, auth modes, context modes,
and per-group prompts.

Priority: CLI flags > config file > environment variables.
