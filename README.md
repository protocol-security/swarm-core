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
    { "count": 2, "model": "claude-opus-4-6", "effort": "high" },
    { "count": 1, "model": "claude-sonnet-4-6", "effort": "medium" },
    {
      "count": 3,
      "model": "openrouter/custom",
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "sk-or-..."
    }
  ],
  "inject_git_rules": true,
  "post_process": {
    "prompt": "prompts/review.md",
    "model": "claude-opus-4-6",
    "effort": "low"
  }
}
```

Agent groups without `api_key` use `ANTHROPIC_API_KEY` (or
`CLAUDE_CODE_OAUTH_TOKEN`) from the environment. Total agent
count is the sum of all `count` fields. Requires `jq` on the
host.

The `effort` field controls Claude's adaptive reasoning depth
(`low`, `medium`, `high`). Supported on Opus 4.6 and Sonnet 4.6.
Omit it to use the model's default (`high`).

By default, agents receive git coordination rules
(commit/push/rebase workflow) appended to their system
prompt. Set `"inject_git_rules": false` in the config to
disable this, e.g. when you want full control over the prompt.

### Environment variables (simple case)

| Variable | Default | Description |
|----------|---------|-------------|
| ANTHROPIC_API_KEY | | API key (required unless CLAUDE_CODE_OAUTH_TOKEN is set). |
| CLAUDE_CODE_OAUTH_TOKEN | | OAuth token from `claude setup-token`. Uses your subscription instead of API credits. |
| SWARM_PROMPT | (required) | Prompt file path. |
| SWARM_CONFIG | | Config file path. |
| SWARM_SETUP | | Setup script path. |
| SWARM_MODEL | claude-opus-4-6 | Model. |
| SWARM_NUM_AGENTS | 3 | Container count. |
| SWARM_MAX_IDLE | 3 | Idle sessions before exit. |
| SWARM_EFFORT | | Reasoning effort: low, medium, high. |
| SWARM_INJECT_GIT_RULES | true | Inject git coordination rules. |
| SWARM_GIT_USER_NAME | swarm-agent | Git author name. |
| SWARM_GIT_USER_EMAIL | agent@claude-swarm.local | Git email. |
| ANTHROPIC_BASE_URL | | Override API URL. |
| ANTHROPIC_AUTH_TOKEN | | Override auth token. |

Config file takes precedence over env vars when present.

### Third-party models

Any Anthropic-compatible endpoint works. Set `base_url` and
`api_key` per agent group, or use environment variables for
all agents:

```bash
ANTHROPIC_API_KEY="sk-..." \
ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic" \
SWARM_MODEL="MiniMax-M2.5" \
SWARM_PROMPT="tasks/task.md" \
./launch.sh start
```

The model name is passed through as-is to `claude --model`.

### Using a Claude subscription (Pro/Max/Teams/Enterprise)

Instead of an API key you can use your Claude subscription.
Generate an OAuth token on the host:

    claude setup-token

Then launch with the token instead of an API key:

```bash
CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..." \
SWARM_PROMPT="tasks/task.md" \
./launch.sh start
```

Both `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` can be
set simultaneously; the `claude` CLI decides which to use.
Per-agent `api_key` in `swarm.json` still works as before for
the API-key flow.

## Commands and usage

See [USAGE.md](USAGE.md) for the full command reference,
including dashboard shortcuts, testing, and post-processing.
