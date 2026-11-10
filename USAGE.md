# Usage

## Quick start

```bash
# Create a swarmfile and launch numbered agents.
SWARM_CONFIG=swarm.json ./launch.sh start --dashboard

# Later, after agents are running or have exited:
SWARM_CONFIG=swarm.json ./launch.sh wait

# Then delete the engagement before the next start:
./launch.sh cleanup
```

All configuration lives in the swarmfile (JSON).  Place a
`swarm.json` in your repo root or point to it with `SWARM_CONFIG`.

## Upgrading from claude-swarm

The project is now named `swarm-core`. Script names, `swarm.json`,
`SWARM_*` variables, drivers, dashboard controls, and Git branch/tag
names are unchanged. The `Tools: swarm` commit trailer is unchanged.

After the GitHub repository has been renamed, update a standalone
checkout's remote from inside that checkout (use your actual remote
name if it is not `origin`):

```bash
git remote set-url origin \
  https://github.com/protocol-security/swarm-core.git
```

For an existing submodule at `tools/claude-swarm`, run this from the
parent repository and commit the resulting `.gitmodules` change:

```bash
git submodule set-url tools/claude-swarm \
  https://github.com/protocol-security/swarm-core.git
```

Use your actual submodule path. SSH users can use
`git@github.com:protocol-security/swarm-core.git` instead of HTTPS.
Keep existing checkout/submodule directories and script paths; moving
or re-adding them is not required.

Docker image/container names and the runtime directory still derive
from the target repository's sanitized directory name (or
`SWARM_PROJECT`), not this tool's name. State that older releases left
in `/tmp` is not reused; see
[Upgrading from `/tmp` state](#upgrading-from-tmp-state).
Do not rename or move a target checkout during an active run. Finish
and harvest the run first: changing its directory name changes resource
names, and existing bind mounts still refer to their original paths.

## Commands

```bash
./launch.sh start [--dashboard]   # Start an engagement: launch
                                  # numbered agents.
./launch.sh stop [--numbered]     # Stop this engagement's
                                  # containers (or only the
                                  # numbered agents).
./launch.sh status                # Show containers.
./launch.sh logs N                # Tail agent N logs.
./launch.sh wait                  # Wait for already-started
                                  # numbered agents, then
                                  # post-process and harvest.
                                  # Does not start agents.
./launch.sh post-process          # Run only post-process, then
                                  # harvest.
./launch.sh interactive hunter    # Start a human-guided driver
                                  # session from agents[].name.
./launch.sh shell --agent hunter  # Start a shell in that profile.
./launch.sh retire                # Remove stopped containers.
./launch.sh cleanup               # Keep what Git had as recovery
                                  # refs, then delete the
                                  # engagement.
```

A program that drives engagements runs them through `control.sh`
instead (see [Control interface](#control-interface)).

## Environment variables

Credentials stay as env vars (not in shell history).

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | | API key (or use `CLAUDE_CODE_OAUTH_TOKEN`). |
| `CLAUDE_CODE_OAUTH_TOKEN` | | OAuth token via `claude setup-token`. |
| `OPENAI_API_KEY` | | OpenAI API key (for Codex CLI driver). |
| `CODEX_AUTH_JSON` | `~/.codex/auth.json` | Path to Codex auth file (ChatGPT subscription). |
| `GEMINI_API_KEY` | | Google API key (for Gemini CLI driver). |
| `PI_API_KEY` | | Pi key for the selected provider; explicit group `api_key` takes precedence. |
| `PI_AUTH_DIR` | | Dedicated writable Pi home for `auth: "chatgpt"`; contains only Codex OAuth credentials. |
| `ANTHROPIC_OAUTH_TOKEN` | | Pi Anthropic OAuth token; falls back to `CLAUDE_CODE_OAUTH_TOKEN`. |
| `PI_HTTP_IDLE_TIMEOUT_MS` | `300000` | Pi driver: `httpIdleTimeoutMs` written to the container's Pi settings. Bounds the wait for response headers and stream data; `0` disables. See [Pi timeouts](#pi-timeouts-and-retries). |
| `PI_MAX_RETRIES` | `0` | Pi driver: enable Pi's in-session request retry with this many attempts. `0` leaves retries to the harness. |
| `PI_COMPACTION_RESERVE_TOKENS` | Pi's (`16384`) | Pi driver: `compaction.reserveTokens` written to the container's Pi settings. See [Pi timeouts](#pi-timeouts-and-retries). |
| `SWARM_CONFIG` | | Path to swarmfile (or place `swarm.json` in repo root). |
| `SWARM_TITLE` | | Dashboard title override. |
| `SWARM_RUNTIME_DIR` | | See [Runtime directory](#runtime-directory). |
| `SWARM_PROJECT` | | See [Project identity](#project-identity). |
| `SWARM_ENGAGEMENT_ID` | | See [Engagements](#engagements). |
| `SWARM_ENGAGEMENT_TOKEN` | | See [Engagements](#engagements). |
| `SWARM_LOCK_FD` | | See [Engagement lock](#engagement-lock). |
| `TARGET_REPO`, `TARGET_REV` | | The engagement's audit target. See [Target](#target). |
| `TARGET_REV_BASE`, `TARGET_REV_BASE_REPO` | | A base for the target. See [Target](#target). |
| `SWARM_TARGET_TIMEOUT` | `300` | Seconds each network Git command of a target's resolution may take. |
| `SWARM_TARGET_VERIFY_TIMEOUT` | `600` | Seconds each local Git command on a target's snapshot may take. |
| `SWARM_SKIP_DEP_CHECK` | | Set to `1` to silence dependency version warnings. |
| `SWARM_ACTIVITY_TIMEOUT` | `0` | Seconds of logfile silence before the in-container watchdog SIGTERMs the agent CLI's process group.  `0` disables.  See [Activity watchdog](#activity-watchdog). |
| `SWARM_ACTIVITY_POLL` | `10` | Watchdog mtime-poll interval, in seconds.  Rarely needs tuning. |
| `SWARM_WATCHDOG_GRACE` | `10` | Grace window between watchdog SIGTERM and SIGKILL.  Rarely needs tuning. |
| `SWARM_STOP_TIMEOUT` | `60` | Seconds `./launch.sh stop` passes to `docker stop -t`, so the harness's SIGTERM trap has time to ship any in-flight local commits via `_session_end_push` before SIGKILL hits.  Also how long `stop` waits for the engagement lock.  See [Stopping the swarm](#stopping-the-swarm). |
| `SWARM_WAIT_POLL` | `10` | Seconds between the checks of `./launch.sh wait`. |
| `SWARM_RETIRE_LAYER_LIMIT_MB` | `100` | The most, in megabytes, that the Git checkouts a container has outside its workspace volume may take as bundles for retire to keep them. |
| `SWARM_HELPER_OUTPUT_LIMIT_MB` | `16384` | The most, in megabytes, that a helper container of retire or cleanup may write to any one file on the host (its output, its errors, a scan archive). |

Per-group credentials (`api_key`, `auth_token`, `base_url`)
are set in the swarmfile.  Use `$VAR` references to pull
values from the host environment without hardcoding secrets.

## Config file fields

Per-group fields in `swarm.json` `agents` array:

| Field | Values | Notes |
|-------|--------|-------|
| `name` | string | Optional profile name for `interactive`, `chat`, and `shell`. |
| `model` | model name | Required. |
| `count` | integer | Numbered agents in this group (default: `0`). |
| `effort` | string | Reasoning depth (see below). |
| `context` | `full`, `slim`, `none` | How much of `.claude/` to keep (default: `full`). |
| `prompt` | file path | Per-group prompt override (default: top-level). |
| `auth` | `apikey`, `oauth`, `chatgpt`, omit | Which host credential to inject (see [Auth modes](#auth-modes)). |
| `api_key` | key or `$VAR` | Per-group API key for third-party endpoints. |
| `auth_token` | key or `$VAR` | Per-group Bearer token (OpenRouter-style). |
| `base_url` | URL | Per-group API endpoint. Registers the provider (built-in or custom) with full model metadata; tune via `PI_API_KIND`, `PI_CONTEXT_WINDOW`, `PI_MAX_TOKENS`, `PI_REASONING`. |
| `tag` | string or `$VAR` | Label for grouping runs (default: top-level). |
| `driver` | driver name | Agent driver override (default: top-level or `claude-code`). |

**Effort values** are driver-dependent:

- Claude Code: `low`, `medium`, `high`, `max` (Opus only).
- Codex CLI: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`.
- Gemini CLI: ignored.
- Pi: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`;
  `none` maps to `off`. Pi clamps levels to the selected model's support.

Top-level fields: `prompt`, `setup`, `max_idle` (default: `3`),
`max_retry_wait`, `driver`, `inject_git_rules`,
`git_user` (`name`, `email`, `signing_key`),
`claude_code_version`, `codex_cli_version`, `pi_version`, `title`, `tag`,
`pricing`, `docker_args`, `post_process`.

### Interactive profiles

Use `interactive`, `chat`, or `shell` to open one human-guided
container from an `agents[]` profile:

```bash
SWARM_CONFIG=swarm.json ./launch.sh interactive hunter
SWARM_CONFIG=swarm.json ./launch.sh shell --agent hunter
SWARM_CONFIG=swarm.json ./launch.sh chat --agent-index 2
```

The profile supplies the same setup, Docker args, driver, model,
effort, auth, context, prompt, tag, and signing configuration used
for numbered agents. The container checks out a distinct branch:

```text
swarm/<run>/interactive-<profile>-<id>
```

Promptless profiles are allowed. They still need an explicit
`agents[]` entry; omitting `prompt` only means no prompt file is
injected before the native driver UI starts. Omit `count` or use
`count: 0` for a profile that should never launch as an
autonomous numbered agent:

```json
{
  "driver": "codex-cli",
  "agents": [
    {
      "name": "operator",
      "count": 0,
      "model": "gpt-5.4",
      "effort": "xhigh",
      "auth": "chatgpt",
      "context": "slim"
    }
  ]
}
```

Interactive containers do not affect numbered-agent idle
accounting and do not start post-processing. On exit, committed
work is pushed to the interactive branch. Uncommitted work stays
inside the container and is shown as dirty in the dashboard/status
view so it is not mistaken for harvested work.

### Retry on rate limits

Set `max_retry_wait` (seconds) to have agents retry with
exponential backoff when rate-limited instead of exiting:

```json
{ "max_retry_wait": 25200 }
```

Default is `0` (no retry -- exit immediately on fatal errors).
The backoff starts at 30 s, doubles each attempt, and caps at
30 min per sleep.  When the cumulative wait exceeds
`max_retry_wait`, the agent exits.  This also covers transient
network failures.

### Activity watchdog

Some CLIs (observed on `codex-cli`, occasionally `claude-code`)
can deadlock mid-request -- the process stays alive but stops
emitting output, so the harness's post-`wait` process-group
kill never fires and the container sits idle until an operator
notices and runs `docker stop`.  Setting
`SWARM_ACTIVITY_TIMEOUT` to a positive integer enables a
watchdog inside `_run_reaped` that polls the CLI's logfile
mtime; if the mtime doesn't advance for that many seconds the
watchdog SIGTERMs the CLI's process group, then SIGKILLs after
`SWARM_WATCHDOG_GRACE` seconds if the group hasn't exited.
Default is `0` (disabled); 300-600 is a sensible starting point
for production swarms:

```bash
SWARM_ACTIVITY_TIMEOUT=600 ./launch.sh start --dashboard
```

The watchdog's kill decision is written to the CLI's stderr
file (`/workspace/*.log.err` inside the container, visible via
`docker logs`) so an operator investigating an agent that
exited early can tell a watchdog-killed exit from a
crashed-on-its-own exit.  `SWARM_ACTIVITY_POLL` (default 10 s)
tunes how often the watchdog checks mtime;
`SWARM_WATCHDOG_GRACE` (default 10 s) tunes the SIGTERM→SIGKILL
gap.  Both rarely need adjustment outside the test suite.

### Stopping the swarm

`./launch.sh stop` sends every running container of the engagement
(numbered agents, post-process, interactive sessions)
`docker stop -t 60`; `--numbered` stops only the numbered agents.
The 60 s grace gives the harness's SIGTERM trap time to ship
any in-flight local commits (in-place rebase → scratch
worktree → `agent-parked/*` salvage) before docker forces
SIGKILL.  Without this window, commits the agent made during
the session it was interrupted in stayed in
`/workspace/.git` and died with the container; the
session-end push pipeline only runs at the bottom of each
loop iteration and never gets to run on a mid-session
SIGTERM.

Commits that no push shipped, because the push and the park both
failed or the container restarted first, are not reset away: at the
top of the next iteration the harness pushes them, and when that
fails it exits and leaves them on the workspace branch.

For larger swarms where 45+ agents race the same push lock,
raise the grace:

```bash
SWARM_STOP_TIMEOUT=120 ./launch.sh stop
```

The harness handles SIGTERM and SIGINT identically; an
`Exited (143)` (`128+SIGTERM`) or `Exited (130)`
(`128+SIGINT`) status with a clean log line of
`emergency shutdown complete` indicates the trap fired and
the emergency push attempt completed.

`stop` acts on the engagement the state file records when it starts,
through its token: it lists the running containers that carry it,
reads each one's labels again right before it stops it, and stops it
by ID, so a container of a later engagement is never stopped. It does
this first without the engagement lock, which a post-process holds for
its whole run, and lists them again after each pass. A start that is
still launching agents holds the lock until it is done, so `stop` then
waits for the lock, up to `SWARM_STOP_TIMEOUT` seconds, and under it
stops what came meanwhile. After a success no agent or post-process of
the engagement runs or is about to start, with two exceptions: an
interactive session holds the lock only while it prepares, so a
container it is starting is not waited for, and a `wait` already
running goes on to its post-process or harvest once it sees the agents
stopped, as it does when they finish. `stop` fails when the lock stays
held that long (run it again: it stops what runs then before it waits
for the lock), when containers keep appearing, when one of them still
runs afterwards, or when Docker cannot tell. It refuses an
engagement of an earlier release (see
[Engagements of earlier releases](#engagements-of-earlier-releases)),
and stops nothing while Docker talks to another daemon than the
engagement's.

### Extra Docker arguments

Pass flags to the `docker run` of each container `launch.sh` starts
(the agents, post-process and interactive sessions; not the helper
containers of `retire` and `cleanup`) with the top-level
`docker_args` array.  Each element is exactly one argument: no
element is split, and each must be a string that is not empty and
holds no newline and no NUL:

```json
{
  "docker_args": [
    "-v", "/var/run/docker.sock:/var/run/docker.sock",
    "--privileged"
  ]
}
```

This is useful for mounting the host Docker socket, adding
devices or capabilities, setting network modes, or passing any
other flags that the harness does not manage natively.

`start`, `post-process`, `interactive` (`chat` and `shell` too), and
`wait` when it goes on to post-process, check `docker_args` against
`docker run`'s options before they prepare anything, and refuse,
naming the element:

- an option this engine does not know: its table holds every option
  Docker 24.0 or 29.8 registers, hidden aliases (`--net`,
  `--net-alias`, `--dns-opt`) and deprecated ones included; an option
  newer than Docker 29.8 waits for that table;
- `--help` in any spelling, `--`, `-` alone, and anything that is no
  option where `docker run` expects one (a positional argument would
  end its options before the engine's own);
- an option that takes a value with nothing after it, a boolean short
  option with nothing after `=` (`-i=`), and grouped short options
  such as `-it` (give `-i` and `-t` apart).

An option that takes a value takes the next element as its value,
whatever it holds; `--name=value`, `-xVALUE` and `-x=VALUE` work too.
The check is about form: values are Docker's to check when it runs,
once the engagement is prepared (`--memory=nonsense` passes it). The
dashboard's post-process key stops the numbered agents before
post-process checks `docker_args`.

`docker_args` come right after `docker run`, before everything the
engine sets, so for an option that takes one value the engine's wins:
`-d` for agents and post-process (a `--detach=false` there changes
nothing), `-it` for interactive sessions (a session cannot be made
TTY-less from `docker_args`), the name, `--restart no`, `--rm=false`,
and interactive's `--entrypoint` (agents and post-process set none, so
`docker_args` can change theirs). Options that add up (`-v`,
`--mount`, `-e`, `--label`) add to the engine's: for an `-e` or
`--label` key given twice the later value wins, and a mount that
conflicts with one the engine makes (`/workspace`, `/upstream`) makes
`docker run` fail.

Labels in the engine's namespace cannot come from `docker_args`: the
check rejects `--label` or `-l`, in any spelling, whose key starts with
`swarm-core.` (whatever the case of its letters, leading spaces and
tabs aside), and `--label-file`, which could bring one. The engine sets
those labels, and programs find its containers by them (see
[Labels](#labels)).

Docker's `-e` flag accepts two forms: `-e VAR=value` passes a
literal value, and `-e VAR` (no `=value`) inherits `VAR` from the
caller's environment at `launch.sh start` time, omitting it
entirely when unset.  This lets you parameterize a single
swarmfile with host env without templating:

```json
{
  "setup": "scripts/setup.sh",
  "docker_args": ["-e", "HTTPS_PROXY", "-e", "NO_PROXY"]
}
```

What `launch.sh` gives a target's containers cannot come from
`docker_args`, whether or not the engagement has a target, so the
check also rejects: `-e` in any spelling naming `TARGET_REPO`,
`TARGET_REV`, `TARGET_REV_BASE`, `TARGET_REV_BASE_REPO` or
`SWARM_TARGET_MIRROR` (the name is what comes before the first `=`,
exactly); `--env-file` and `--volumes-from`, which could bring them;
and a mount at or below `/target-upstream`: any field of `-v` or
`--device` (a host path there counts too), the path of `--tmpfs`, and
the `target`, `dst` or `destination` of `--mount`, read as Docker 29
reads it (the whole value trimmed) and as Docker 24 does (nothing
trimmed), with paths cleaned as Docker cleans them (`//`, `.`, `..`,
a trailing `/`). It also rejects a `--mount` value that Docker cannot
read as one CSV record: a quote opens a field only at its start
(`"dst=/a,b"`, not `dst="/a,b"`).

Swarmfiles of earlier releases that passed the target with
`-e TARGET_REPO -e TARGET_REV` move it to the host environment, where
`launch.sh` resolves it (see [Target](#target)), and their setup hooks
call `swarm-target-checkout` instead of cloning it; an abbreviated
`TARGET_REV` becomes a full commit id, a branch or a tag. Joining an
engagement started without a target is rejected while `TARGET_*` is
set: unset it, or finish the engagement (`./launch.sh stop`,
`harvest.sh`, `./launch.sh cleanup`) before one with a target starts.

### Setup hook

The `setup` script runs once at container startup as root, via
`sudo -E bash <setup>`, so the full container environment crosses
the `sudo` boundary into the script.  Any variable passed through
`docker_args -e` (plus the swarm's own env like `AGENT_ID`,
`SWARM_MODEL`, `MAX_IDLE`, ...) is visible inside `setup.sh`.
Default Debian sudoers would otherwise strip everything except
`PATH` via `env_reset`, so `-E` is what makes the example above
work end-to-end.

After `setup.sh` returns, the harness reclaims ownership of
`/workspace` so subsequent agent runs can modify the tree as the
non-root `agent` user.

### Target

An engagement can have an audit target: a repository and a revision
that `launch.sh` resolves on the host, once, when it creates the
engagement, into a snapshot that every container of the engagement
mounts read-only. Set it in the host environment (`docker_args` may
not set the target's variables, see
[Extra Docker arguments](#extra-docker-arguments)):

```bash
TARGET_REPO=git@github.com:org/repo.git TARGET_REV=v1.2.0 \
    ./launch.sh start
```

| Variable | Description |
|----------|-------------|
| `TARGET_REPO` | The repository: an absolute local path, `ssh://`, `[user@]host:path`, or `https://` without a user name, a query or a fragment. |
| `TARGET_REV` | A full commit id, a full ref under `refs/heads/` or `refs/tags/`, or a branch or tag name. |
| `TARGET_REV_BASE` | Optional: a base revision, in the same forms. |
| `TARGET_REV_BASE_REPO` | The base's repository when it is not `TARGET_REPO` (needs `TARGET_REV_BASE`). |
| `SWARM_TARGET_TIMEOUT` | Seconds each network Git command may take (1 to 86400, default 300). |
| `SWARM_TARGET_VERIFY_TIMEOUT` | Seconds each local Git command on the snapshot may take (1 to 86400, default 600). |

Setting any of the four variables, even to an empty value, asks for
a target. `TARGET_REPO` and `TARGET_REV` must both be set, and empty
values are rejected. An expression such as `main~1` is rejected; an
abbreviated commit id is rejected unless a branch or a tag has that
name, and so is a name that is both a branch and a tag (give the full
ref). Each named revision is looked up with one listing of its
repository's refs, and the commit that listing gives is then fetched
by id; a full commit id is fetched as given. Git runs with your Git
configuration and credentials (a credential helper, your ssh agent and
configuration), over ssh, https or the local file system only, and
never prompts: a custom ssh command or credential helper there must
work unattended. Each network command is bounded by
`SWARM_TARGET_TIMEOUT` and each local one by
`SWARM_TARGET_VERIFY_TIMEOUT` (perl arms the alarm, so it is
required). The snapshot has the checkout's object format.

The snapshot is `target.git` in the runtime directory: a bare
repository holding `refs/swarm/target` at the commit (and
`refs/swarm/target-base` at the base's), checked with `git fsck` and
readable by every user. The state file records the target in the
write that records the engagement: each repository as given and its
physical path, each revision as given and its commit, and the object
format. A failure before that write leaves no engagement, and the next
`start` can follow at once. If publishing the snapshot or making the
bare repo fails after it, the engagement is incomplete, and every
launch rejects it until `./launch.sh cleanup` has finished it.

Every container of the engagement (agents, post-process, interactive
sessions) gets `target.git` mounted read-only at `/target-upstream`,
with `SWARM_TARGET_MIRROR=/target-upstream`, `TARGET_REPO` (as given),
`TARGET_REV` (the commit id), `TARGET_REV_BASE` (the base's commit id)
and `TARGET_REV_BASE_REPO` (as given), the base ones empty without a
base. Without a target, a container gets no mount and the five set
empty.

Before anything is built or run, `post-process` and `interactive`
joining an engagement, and `wait` before it polls, check:

- the record, as creation writes it (a damaged one points to
  `./launch.sh cleanup`);
- each `TARGET_*` variable that is set (an unset one takes the
  recorded value): `TARGET_REPO` must be the repository as given or
  its physical path, `TARGET_REV` the revision as given or its commit,
  and the base ones likewise. Any of them is rejected for an engagement
  without a target, and a base one for a target without a base;
- the snapshot: a directory of this user's with nothing mounted in it,
  holding only regular files and directories, with `r-x` on
  directories and `r--` on files for user, group and other (a
  container's user may match any of them), only the settings this
  resolver's `git init` writes, no object storage outside it, exactly
  the pins at the recorded commits, and a clean `git fsck --full`,
  which reads every object. Each Git command is bounded by
  `SWARM_TARGET_VERIFY_TIMEOUT`. A damaged snapshot cannot be repaired
  in place: stop the agents, run `harvest.sh`, then
  `./launch.sh cleanup`.

Nothing reaches the target's source: a join works when the source is
gone or out of reach. Under the lock, once the agents are done, `wait`
checks the record and the variables again; the snapshot is checked
again where it is mounted, by the post-process `wait` goes on to, so
damage made while `wait` polls stops that post-process but not
`harvest.sh`, which never mounts the snapshot. The checks see modes,
not access control lists: every container user needs effective read
access to the snapshot's files and read and search access to its
directories, and a default ACL on the runtime directory or a parent of
it that takes that away makes the containers' reads fail.

A setup hook (see [Setup hook](#setup-hook)) checks the target out
with the image's helper, without the network:

```bash
swarm-target-checkout /workspace/target
```

By default, the harness tells agents to commit with `git add -A`.
For a target checkout inside `/workspace`, ignore its directory in
this checkout's root `.gitignore` (`/target/` for the hook above),
and commit the rule before `start`, `post-process` or `interactive`
creates the engagement. Otherwise an agent's commit can record the
target checkout as a gitlink, and `harvest.sh` merges that commit
into this checkout.

`swarm-target-checkout DIR` makes `DIR` a checkout of the recorded
commit, `HEAD` detached at `TARGET_REV`, with its pin as
`refs/swarm/target` and, with a base, `refs/swarm/target-base`; a
snapshot whose pins are not `TARGET_REV` and `TARGET_REV_BASE`
themselves is refused. `DIR` must not exist, or be an empty directory,
and must not be a link; its parent directory must exist. The checkout
is built in a temporary directory beside `DIR` and renamed to `DIR` at
the end: until then a failure leaves `DIR` as it was (a helper that
was killed can leave a `.swarm-target-checkout.*` directory there,
which may be deleted), and the rename fails when `DIR` has become a
link, a file or a directory that is not empty meanwhile. A second run
on the same `DIR` refuses. The checkout's mode follows the umask: made
as root with umask 022 outside `/workspace`, it is readable by the
agent when its parent directories are. Its Git
commands run with no user or system configuration and none of the
caller's `GIT_*` variables, with hooks, fsmonitor and submodule
recursion off: no filter, hook or URL rewrite of the caller's applies,
and an LFS pointer stays a pointer. The target's submodules and LFS
content are not fetched. It works as root (setup) and as the agent.
Custom images get it by copying `lib/target-checkout.sh` the way the
Dockerfile does. A hook that clones `TARGET_REPO` over the network
instead works only for a source the container can reach.

### Commit signing

Set `git_user.signing_key` to an SSH private-key path on the
host to sign every commit agents and post-processors make.
Accepts a literal path, a bare `$VAR` reference (expanded from
the host environment), or a path starting with `~/` (expanded
to `$HOME` before mounting):

```json
{
  "git_user": {
    "name": "swarm-agent",
    "email": "agent@swarm.local",
    "signing_key": "~/.ssh/swarm-agent-signing"
  }
}
```

The key is bind-mounted read-only into each container at
`/etc/swarm/signing_key`.  The harness then copies it to
`/dev/shm/swarm-signing-key` with `0600` perms before
configuring git:

```
gpg.format      = ssh
user.signingkey = /dev/shm/swarm-signing-key
commit.gpgsign  = true
```

The copy step exists because `ssh-keygen -Y sign` refuses
world-readable keys with `UNPROTECTED PRIVATE KEY FILE`, and
the bind mount inherits host perms (often `0644` for shared
swarm-bot keys).  `/dev/shm` is tmpfs, RAM-backed, and
per-container in Docker, so the private key bytes never hit
disk.  Without the copy, signing fails inside the container,
and Codex CLI silently retries with `--no-gpg-sign`
([openai/codex#6199](https://github.com/openai/codex/issues/6199)),
landing commits without a signature.

When `signing_key` is absent -- or resolves to empty via an
unset `$VAR` -- signing is explicitly disabled inside the
container (`commit.gpgsign = false`), overriding anything that
might otherwise leak in from the image or a mounted config.

The host key file must exist at `launch.sh start` time;
otherwise launch fails with `ERROR: signing key not found`.
The container image ships `openssh-client` for the
`ssh-keygen -Y sign` that git invokes.

## Dashboard

```bash
./dashboard.sh
```

Per-agent model, auth source, status, cost, tokens, cache,
turns, throughput, and duration.  Updates every 3s.  The
header shows a compact model summary on a single line.
Interactive containers appear as `I1`, `I2`, etc. with their
branch and `dirty`, `unharvested`, or `harvested` state; they
do not count toward numbered-agent completion.

A numbered agent or the post-process that has no container but a
workspace volume of the engagement shows `volume only`: `./launch.sh
retire` removed its container (or `docker run` never made it), and its
files stay on the volume until `./launch.sh cleanup`. Once no container
is left, a line under the recent commits counts those volumes. A
cleanup that has not finished (running, or stopped before the end) is
shown there instead, until it finishes; if it is not running, run
`./launch.sh cleanup` again.

| Key | Action |
|-----|--------|
| `q` | Quit. |
| `1`-`9` | Logs for agent N. |
| `P` | Post-process logs (the `P` row), if it exists. |
| `h` | Harvest results. |
| `s` | Stop the containers of the engagement shown (`./launch.sh stop`). |
| `p` | After confirmation, stop the numbered agents and start post-process; refuses while an earlier post-process container is there. |

The Model column appends the agent's reasoning effort as a
parenthesised letter: `(h)` high, `(m)` medium or minimal, `(l)` low,
`(x)` xhigh, `(n)` none, `(o)` off (Pi), and `(M)` max. Models configured
without an `effort` show no suffix.

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
events from the agent CLI and prints one line per tool call
or thinking block.  The timestamp and agent ID are colored
in ANSI yellow (matching git's commit-hash color) for
readability.

Thinking/reasoning content appears as `Think: <summary>`
when the model produces it.  Whether thinking is emitted
depends on the model and configuration: Claude Code requires
extended thinking to be enabled, and Gemini CLI emits thought
events only for models that support them.

On Opus 4.7 and later the Anthropic API default for
`thinking.display` is `"omitted"`: the `thinking` field is
empty and the full reasoning is returned encrypted in the
`signature` field.  To restore summaries the client has to
explicitly send `thinking: {"display": "summarized"}` on
each Messages API request.

The claude-code driver writes `"showThinkingSummaries": true`
into the workspace's `.claude/settings.local.json` as a
forward-compatible opt-in.  As of Claude Code 2.1.111 the
CLI does not yet plumb that setting through to headless
(`-p --output-format stream-json`) requests for Opus 4.7, so
on today's releases this opt-in is effectively a no-op for
our pipeline.  The setting is retained so that a future
Claude Code release which wires it to the Messages API will
restore summaries automatically with no further swarm change.

While the client-side opt-in is missing, the activity filter
classifies the otherwise-blank blocks to keep the dashboard
informative:

- `Think: [encrypted]` — `thinking` empty, `signature` present.
  This is the expected Opus 4.7 `display:"omitted"` payload;
  the full reasoning exists server-side but is unavailable
  to the client.
- `Think: [empty]` — `thinking` empty and `signature` empty.
  Anomalous: neither summary nor encrypted reasoning; useful
  diagnostic that something upstream is off.

Blank `Think:` lines no longer reach the dashboard.  On
Opus 4.6 and earlier, summaries were the default and continue
to render as `Think: <summary>` unchanged.

## Testing

```bash
./tests/test.sh --help               # All options.
./tests/test.sh --unit               # Unit tests only.
./tests/test.sh                      # Single smoke test.
./tests/test.sh --all                # Full matrix.
./tests/test.sh --config swarm.json  # Custom config.
./tests/test.sh --no-inject          # Explicit git prompt.
./tests/test.sh --oauth              # OAuth-only smoke test.
```

Flags combine: `./tests/test.sh --config f.json --no-inject`.

Smoke tests take the project id from the directory name.  When
another checkout on the Docker host already uses it, set
`SWARM_PROJECT`: `SWARM_PROJECT=swarm-core-2 ./tests/test.sh`.

The test harness uses its own built-in prompt (counting +
reasoning) regardless of config. The reasoning step exercises
adaptive thinking at different effort levels.

Unit tests (no Docker or API key):

```bash
./tests/test.sh --unit         # All unit tests.
./tests/test_activity_filter.sh  # Activity stream parsing.
./tests/test_config.sh         # Config parsing.
./tests/test_costs.sh          # Cost aggregation.
./tests/test_dashboard.sh      # Dashboard rendering.
./tests/test_drivers.sh        # Agent driver interface.
./tests/test_format.sh         # Formatting helpers.
./tests/test_harness.sh        # Stat extraction.
./tests/test_harvest.sh        # Harvest git ops.
./tests/test_launch.sh         # Launch logic.
./tests/test_pi.sh             # Pi driver and build integration.
```

`--all` also runs `./tests/runtime_pi.sh`: the installed Pi CLI in Docker
against test APIs, without real credentials or paid model calls. It
checks the four tools, Git commits/pushes, idle exit, post-processing,
harvest, activity, usage stats, and structured API failures. Two additional
network-isolated Pi containers verify shared Codex OAuth refresh and
persisted credentials using a test-only transport. With Python
3 available on the host, it also checks native UI startup, `/quit`, and
interactive branch push through a PTY; otherwise that check is skipped.
This is not a substitute for live-provider verification.

For a live Pi OAuth smoke test (billable Anthropic extra usage):

```bash
./tests/test.sh --config tests/configs/pi-only.json
```

## Post-processing

Add to `swarm.json`:

```json
{
  "post_process": {
    "prompt": "prompts/review.md",
    "model": "claude-opus-4-6",
    "effort": "low",
    "max_idle": 2
  }
}
```

Trigger via `[p]` in the dashboard, `./launch.sh post-process`,
or automatically via `./launch.sh wait` after numbered agents have
already been started. `./launch.sh wait` does not launch numbered
agents.

`post-process` refuses while numbered agents of the engagement run:
stop them (`./launch.sh stop --numbered`) or wait for them first. A
post-process container is never replaced: while
`<project>-agent-post` is there, `post-process` refuses. Stop it first
if it runs, then remove it with `./launch.sh retire --post-process`;
its workspace volume stays for cleanup.

The post-process agent clones the same bare repo, sees all
commits on `agent-work`, runs its prompt, and pushes.

`harvest.sh` only merges agent work into the current local branch:
`agent-work` plus any `swarm/*/interactive-*` branches. It does
not run `post_process`. If you harvested manually and still need
post-processing, run `./launch.sh post-process`; use that command
directly when you intentionally want to run only the post-process
agent and then harvest.

`harvest.sh` merges a branch built on the commit the engagement started
from (`base_commit` in the state file) as long as HEAD's history still
has that commit, so it also merges agent work after you merged an
interactive branch or made commits of your own. It refuses when HEAD's
history no longer has it (rewritten after the engagement started, by a
force-push or a rebase): take what you need by hand, then end the
engagement with `./launch.sh cleanup --allow-unharvested`. It also
records what each harvest merged, and refuses when HEAD no longer has
that (a rebase dropped some of it): merging again would bring it back.
Each merge is recorded before it starts, and committed whatever merge
options the Git config sets (`--no-commit`, `--squash`). A merge that
stops on a conflict says how to finish it or give it up. Finished by
hand, it counts as merged; given up, or cut short with the harvest
(killed, say), the next harvest refuses as well, as does one run while
the merge is still in progress. After undoing a harvest on purpose
(`git reset --hard <tag>`, below) or giving up such a merge,
`./harvest.sh --again` merges that work again, also what the bare
repo's branches no longer bring back (a branch deleted there, or
`agent-work` moved back): it merges the recorded commits by id from
this checkout, which keeps them recorded until HEAD has them, and
refuses one the checkout no longer has.

The files a harvest merges are the agents', so Git runs no hook and no
fsmonitor command for `harvest.sh` on the host
(`core.hooksPath=/dev/null`, an empty `core.fsmonitor`, and each hook
the checkout's Git config defines turned off by name; a hook name with
`=` makes it refuse). It still runs the commands your Git config names
for Git to run (filters and merge drivers, on the files an agent's
`.gitattributes` assigns them to; `uploadpack.packObjectsHook`, for its
fetch), and the hooks a submodule's own config defines. And the files
stay in the checkout: a hook an agent added there can run with later
Git commands, and a Git config that includes a file of the checkout
takes what an agent wrote there. Review what a harvest merged, as you
would a pull request, before you run anything in the checkout.

Before merging, `harvest.sh` tags the current branch tip with a
local `swarm-harvest-<date>-<time>` tag (`-2`, `-3` and so on for
another harvest within the same second; skipped on `--dry` and
when nothing is new). Undo a harvest with
`git reset --hard <tag>`. The tag is never pushed and does not
interfere with the harvested branches.

`post_process` also accepts `base_url`, `api_key`,
`auth_token`, `auth`, `tag`, `driver`, and `max_idle` -- same
fields as per-group agents -- to route post-processing through
a different provider or credential. `max_idle` controls how
many consecutive sessions with no commits before the
post-processor exits. When omitted it inherits the top-level
`max_idle` (default: `3`).

`post_process.setup` overrides the setup script for the
post-process pass: a path runs that script, `false` or `""`
skips setup (so a heavy top-level `setup` is not redone), and
omitting the key inherits the top-level `setup`.

`./launch.sh post-process` (and `wait` when it triggers
post-processing) exits with the post-process container's exit
code. Harvest still runs first, so a crashed agent's in-flight
commits are recovered locally, but a non-zero exit lets CI or
daemons refuse to publish partial state.

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

- **`auth`** — Controls which host credential is forwarded to
  the container.  Values: `apikey`, `oauth`, `chatgpt`, or
  omit (auto-detect).

- **`api_key`** — Per-group provider API key, mapped to the
  selected driver's credential mechanism. Supports `$VAR`
  references to host env vars.

- **`auth_token`** — Per-group Bearer token for Anthropic-compatible
  endpoints through Claude Code or Pi (`ANTHROPIC_AUTH_TOKEN`).
  Claude Code clears `ANTHROPIC_API_KEY` to enter third-party mode.
  Supports `$VAR` references.

### Claude Code

| `auth` value | Credential injected |
|---|---|
| `apikey` | `ANTHROPIC_API_KEY` only |
| `oauth` | `CLAUDE_CODE_OAUTH_TOKEN` only |
| omit | Both (CLI decides) |

For subscription auth (Pro/Max/Teams/Enterprise), generate
an OAuth token with `claude setup-token` and export
`CLAUDE_CODE_OAUTH_TOKEN`.

Claude Code credentials are resolved each time a container is
created. If you run `ANTHROPIC_API_KEY=... ./launch.sh start`,
that inline environment does not persist for a later
`./launch.sh shell --agent ...`; export the variable first or
prefix the `shell`, `chat`, or `interactive` command too. Inside a
Claude interactive shell, `claude auth status` should report the
injected credential.

### Codex CLI

| `auth` value | Credential injected |
|---|---|
| `apikey` | `OPENAI_API_KEY` only |
| `chatgpt` | Mounts `~/.codex/auth.json` (ChatGPT subscription) |
| omit | API key if set + auth.json if found |

For ChatGPT subscription auth (Plus/Pro/Team/Enterprise),
run `codex login` on the host to create `~/.codex/auth.json`,
then set `"auth": "chatgpt"` in your swarm config:

```json
{
  "driver": "codex-cli",
  "agents": [{ "model": "gpt-5.4", "auth": "chatgpt" }]
}
```

The auth file is bind-mounted read-only into containers.
Override the path with `CODEX_AUTH_JSON=/path/to/auth.json`.

### Pi

Set `"driver": "pi"` for numbered agents, interactive profiles, or
post-processing. Pi runs inside the existing Docker boundary. The image
installs Node.js, Pi, `fd`, and `ripgrep`. API-key and Anthropic-token runs
do not need host Pi; Codex subscription setup uses Pi's `/login`.

Bare model IDs select Anthropic. For another built-in Pi provider, use
`provider/model`, including any slashes inside the model ID:

```json
{
  "driver": "pi",
  "pi_version": "0.86.1",
  "prompt": "tasks/work.md",
  "agents": [
    { "count": 1, "model": "anthropic/claude-sonnet-4-6",
      "auth": "oauth", "effort": "low" },
    { "name": "operator", "count": 0, "model": "openai/gpt-5.4",
      "api_key": "$OPENAI_API_KEY", "effort": "high" }
  ]
}
```

Run `./launch.sh interactive operator` for Pi's native UI. As with the
other interactive drivers, the profile prompt's path is displayed, not
automatically submitted. Git instructions are appended to the system
prompt in both modes.

| Credential selection | Behavior |
|---|---|
| Group `api_key` | Explicit key for the selected Pi provider. |
| Group `auth_token` | Anthropic Bearer token (`ANTHROPIC_AUTH_TOKEN`). |
| `auth: "apikey"` | `PI_API_KEY`, then `ANTHROPIC_API_KEY`; no OAuth fallback. |
| `auth: "oauth"` | `ANTHROPIC_OAUTH_TOKEN`, then `CLAUDE_CODE_OAUTH_TOKEN`. |
| `auth: "chatgpt"` | Shared writable `PI_AUTH_DIR`; requires `openai-codex/<model>`. |
| Omitted `auth` | `PI_API_KEY`, then Anthropic OAuth, then `ANTHROPIC_API_KEY`. |

Group credentials override `auth`. Anthropic environment credentials
apply only to Anthropic. Other providers require an explicit `api_key`
or `PI_API_KEY`, except for the Codex subscription mode below. Pi's
normal host auth/session directory is not automatically mounted.
Supplied Anthropic OAuth tokens must remain valid for the run.

**Anthropic subscription auth in third-party apps uses paid extra
usage, not plan limits.** Enable/fund extra usage or use an API key.
An extra-usage rejection is fatal, not a reason to retry indefinitely.

`base_url` registers the selected provider in Pi's container-local
`models.json` as a full provider definition — built-in prefixes
(`openrouter/...`) get their endpoint redirected, and custom prefixes
(`ethereum-foundation/...`) resolve as first-class providers with the
model declared (`api` defaults to `openai-completions`; metadata via
`PI_API_KIND`, `PI_CONTEXT_WINDOW`, `PI_MAX_TOKENS`). Pi treats a model
it does not know as non-reasoning and ignores `effort` for it; set
`PI_REASONING=1` to declare it a reasoning model. On
`openai-completions`, `effort: "none"` then sends `reasoning_effort:
"none"`, which endpoints that reason by default need to stop. This
override is not allowed with `auth: "chatgpt"`. For API-key/token
modes, secrets stay in environment variables; generated auth files
contain environment references outside the worktree.

Headless runs use fresh, unsaved sessions with `read`, `write`, `edit`,
and `bash`. Project Pi settings/extensions are not automatically trusted;
the native interactive UI retains its trust prompt. Pi reads root
`AGENTS.md`/`CLAUDE.md` natively; if neither exists (nor
`AGENTS.override.md`), the driver appends `.claude/CLAUDE.md` when present.
Existing context modes still only strip `.claude/`, not `.pi/` or root
context files.

Startup network checks and telemetry are disabled. By default the harness
owns retries; Pi's automatic retry and cache warming are disabled. Costs are
Pi's provider-reported usage multiplied by its catalog rates, not a
subscription invoice. Timing uses the harness's wall-clock fallback.

#### Pi timeouts and retries

Pi's `httpIdleTimeoutMs` (default 300000) also bounds how long a request
may wait for response headers. A local backend that queues requests and
only starts streaming when it begins processing can exceed five minutes
under load, and the session then fails with `Request timed out.` Two
environment variables adjust the generated container settings; they are
forwarded from the host environment or set through `docker_args`:

```json
"docker_args": ["-e", "PI_HTTP_IDLE_TIMEOUT_MS=1800000",
                "-e", "PI_MAX_RETRIES=2"]
```

`PI_HTTP_IDLE_TIMEOUT_MS=0` disables the timeout inside Pi. A positive
`PI_MAX_RETRIES` enables Pi's own retry, which re-issues the request inside
the same session and keeps the conversation; the harness `max_retry_wait`
fallback restarts the task from the prompt instead. Only
`httpIdleTimeoutMs` is written, never `retry.provider.timeoutMs`. Keep
`SWARM_ACTIVITY_TIMEOUT` above the backend's longest silent period, since a
long prefill emits no log lines.

Pi compacts the conversation once its context passes `contextWindow`
minus `compaction.reserveTokens` (16384 by default), and caps a summary
at a share of that reserve and of `maxTokens`. A reasoning model spends
the same budget on reasoning, so its summary can hit the cap, and Pi
then ends the session with `Summarization failed: generation hit the
token cap`. `PI_COMPACTION_RESERVE_TOKENS` sets a larger reserve, set
the same way; raise `PI_MAX_TOKENS` with it for custom models. It
applies to every agent of the run.

#### Codex subscription through Pi

Use Pi's `openai-codex` provider for a ChatGPT subscription, not its
`openai` API-key provider. Log in with host Pi into a **dedicated**
directory outside the worktree:

```bash
export PI_AUTH_DIR="$HOME/.config/swarm-core/pi-codex"
install -d -m 700 "$PI_AUTH_DIR"
PI_CODING_AGENT_DIR="$PI_AUTH_DIR" pi
# In Pi: /login, select OpenAI Codex, finish login, then /quit.
```

Then configure the swarm:

```json
{
  "driver": "pi",
  "pi_version": "0.86.1",
  "agents": [
    { "count": 1, "model": "openai-codex/gpt-5.5",
      "auth": "chatgpt", "effort": "low" }
  ]
}
```

Choose a model enabled for your account. The live smoke config uses
`gpt-5.5`; model availability is not guaranteed by a successful login.
This mode works for headless agents and native interactive profiles.

The whole dedicated directory is mounted read-write at
`/home/agent/.pi/agent`. Keep it private and writable by the container's
agent user (UID 1000); `auth.json` should have mode 600 and contain only
an `openai-codex` OAuth entry. Do not use your normal `~/.pi/agent`, add
unrelated credentials/extensions, or copy the same refresh token into
independent stores for parallel runs. `CODEX_AUTH_JSON` belongs to the
separate `codex-cli` driver and is not used here.

Pi shares `auth.json` and its adjacent lock across containers, refreshes
expired credentials, and persists rotated tokens back to this directory.
The driver replaces its `settings.json` at startup, uses SSE transport,
and keeps new interactive sessions container-local. If refresh fails,
log in again in the dedicated directory; there is no API-key fallback.

Verify with a live subscription call:

```bash
./tests/test.sh --config tests/configs/pi-chatgpt.json
```

### General rules

Groups with `api_key` or `auth_token` ignore the `auth`
field; their custom credential is always used.  When neither
is set, `auth` determines which host credential to inject.

The dashboard **Auth** column reflects the actual credential
source: `key`, `oauth`, `chatgpt`, `token`, or `auto` (see
Dashboard columns).

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
  (Claude subscription token), `chatgpt` (ChatGPT subscription),
  `token` (Bearer / OpenRouter-style),
  `auto` (multiple credentials present, CLI decides).
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
any supported agent.

Built-in drivers:

| Driver | CLI | Default |
|--------|-----|---------|
| `claude-code` | `claude` | Yes |
| `gemini-cli` | `gemini` | |
| `codex-cli` | `codex` | |
| `pi` | `pi` | |
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

### Pinning Codex CLI version

By default the Docker image installs the latest Codex CLI.
To pin a specific version, set `codex_cli_version` in the
swarmfile:

```json
{ "codex_cli_version": "0.125.0" }
```

The value is forwarded to `npm install -g @openai/codex@<ver>`
inside the image build.  Leave the field unset (or empty) to
keep the default "latest published release" behavior.

### Pinning Pi version

Set `pi_version` to pin `@earendil-works/pi-coding-agent` in the image:

```json
{ "pi_version": "0.86.1" }
```

Omit it to install the latest published release. The driver is tested
with Pi 0.86.1 (Node.js 22.19+); older Pi releases may lack required
CLI flags or event fields. npm lifecycle scripts are disabled during
installation.

### Writing a new driver

Create `lib/drivers/<name>.sh` implementing these functions:

```bash
agent_default_model()   # Fallback model when none configured
agent_name()            # Human-readable name for commit trailers
agent_cmd()             # CLI command name
agent_version()         # Print version string to stdout
agent_run()             # Run one session (model, prompt, logfile, append_file)
agent_interactive_run() # Start native UI (model, prompt_file, append_file)
agent_settings()        # Write agent config files into workspace
agent_extract_stats()   # Parse stats from log file (TSV output)
agent_detect_fatal()    # Detect fatal errors from log + exit code
agent_is_retriable()    # Detect retriable errors (rate limits, overload)
agent_activity_jq()     # Return jq filter for activity streaming
agent_docker_env()      # Print -e flags for agent-specific env vars
agent_docker_auth()     # Resolve credentials, emit Docker -e flags
agent_install_cmd()     # Print install commands (documentation only)
```

The Dockerfile hardcodes install steps for built-in drivers.
New drivers require corresponding Dockerfile changes.

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

Clean up afterwards as described in [Cleanup](#cleanup).

## Runtime directory

Each project keeps its host-side state in one directory:

| Path | Content |
|------|---------|
| `upstream.git` | Bare repo that containers mount at `/upstream`. |
| `mirrors/<id>.git` | Submodule mirrors, numbered (`/mirrors`, read-only). |
| `mirrors/manifest.json` | Which submodule each mirror is (see [Submodule mirrors](#submodule-mirrors)). |
| `upstream.git.new`, `mirrors/<id>.git.new`, `mirrors/manifest.json.new` | A bare repo, mirror or manifest being made, renamed once ready. |
| `state.json` | State file for a standalone dashboard. |
| `engagement.lock` | Lock that lifecycle commands hold. |

The state file is JSON (`swarm-core.state/v1`, mode 600) that
`launch.sh start` replaces in one rename; the dashboard reads it with
jq and never sources it.

The directory is `$XDG_STATE_HOME/swarm-core/<project>`, which is
`~/.local/state/swarm-core/<project>` when `XDG_STATE_HOME` is unset
or relative. Set `SWARM_RUNTIME_DIR` to an absolute path to put it
elsewhere, and set it the same way for every command of a run
(`launch.sh`, `harvest.sh`, `dashboard.sh`, `progress.sh`,
`costs.sh`): each one resolves the directory on its own.
`launch.sh start` prints the directory it used.

Cleanup has to be able to work there, so `launch.sh` refuses, before
it creates anything, a runtime directory that is `/` or your home
directory, that holds or lies inside the checkout or its git dir, that
is not a directory of yours, or whose path has a comma, a quote, a tab
or a newline. Only an earlier release can have made one in such a
place (see
[Engagements of earlier releases](#engagements-of-earlier-releases)).

`launch.sh` creates the directory with mode 700 and refuses one that
is a symlink, belongs to another user, has any group or other
permission bits, or (on macOS) has an ACL entry that allows access;
`harvest.sh` and `progress.sh` refuse it too. On macOS it also refuses
to create the directory below an inheritable ACL entry that allows
access, since the new directory would inherit it. The
bare repo inside stays writable for every UID, because the
container's `agent` user can have a different UID from the host user
(native Linux); the directory around it keeps other host users out.

### Project identity

The project id names the runtime directory, the image
(`<project>-agent`) and the containers (`<project>-agent-N`, ...).
`SWARM_PROJECT` sets it; otherwise it comes from the repository root's
directory name: lowercased, ASCII letters and digits kept, `.`, `_` and
`-` kept as separators, any other character turned into `-`, a run of
separators reduced to its first one, separators at either end dropped,
and `swarm` when nothing is left (`My.Repo` gives `my.repo`, `My Repo!`
gives `my-repo`). A `SWARM_PROJECT` value that is not already in that
form is refused, and the error shows the accepted form.

The state file records which checkout owns the runtime directory.
Every `launch.sh` command, `harvest.sh`, `progress.sh`, `costs.sh` and
the dashboard refuse to act when another checkout owns it, so two
checkouts with the same directory name never share a bare repo, an
image or containers: give the second one its own `SWARM_PROJECT`. A
checkout moved to a new path is refused the same way. Harvest from the
old path first, or remove the runtime directory once nothing in it is
needed. `launch.sh stop` keeps the state file.

Container names are shared by everything on the Docker host, and the
runtime directory can live anywhere, so containers carry their project
id and the checkout that created them in `swarm-core.project` and
`swarm-core.checkout` labels, with the others [Labels](#labels)
lists. Every command refuses to act while one of
the project's containers belongs to another checkout, or has no labels
because an older release created it (see
[Upgrading from `/tmp` state](#upgrading-from-tmp-state)). Removing or
stopping a container checks its labels again and acts on its ID.
`harvest.sh` only looks into containers when the Docker daemon answers.

### Workspace volumes

Each container's `/workspace` is a Docker volume of its own,
`<container name>-ws-<8 hex digits>`, created right before the
container. The volume carries the `swarm-core.project`,
`swarm-core.checkout`, `swarm-core.engagement` and
`swarm-core.engagement-token` labels, plus `swarm-core.container` (its
container's name), `swarm-core.kind` (`agent` for numbered agents and
post-process, `interactive` for a human session), `swarm-core.context`
(`full`, `slim` or `none`) and a random `swarm-core.nonce` that
`launch.sh` reads back after creating the volume. A launch fails before
`docker run` when the volume cannot be created or does not carry those
labels. Containers carry the engagement labels too. Removing a stopped
container (`./launch.sh retire`) leaves its volume, and the files in
it; `./launch.sh cleanup` copies what Git keeps there into the checkout,
then deletes the volumes.

### Engagements

An engagement is one life of the bare repo. It begins when `start`
creates the bare repo, or when `post-process` or `interactive` creates
it because the state file records no engagement, and the state file
records its id: the value
of `SWARM_ENGAGEMENT_ID` (1-64 letters, digits, `.`, `_` or `-`,
starting with a letter or digit), or a generated
`<UTC time>-<random hex>` id. `post-process`, `interactive`, `stop`,
`wait`, `harvest.sh` and the dashboard act on an existing engagement
only when `SWARM_ENGAGEMENT_ID` is unset or equal to the recorded id,
so a caller that names its engagement cannot act on another one. An
empty value counts as set and is refused.

A new bare repo starts from the commit the checkout has: `agent-work`
and `refs/swarm/base` point at it, the state file records it as
`base_commit`, and the checkout's own `swarm/*` and `agent-parked/*`
branches are not copied, so branches from an earlier engagement never
look like new agent work. The bare repo and the submodule mirrors are
cloned through Git's transport (`--no-local`): they hold what the
checkout's (or the submodule's) branches, tags and HEAD reach, and not
the objects that only remote-tracking branches, the stash, the reflogs
or recovery refs keep. A mirror also keeps the commit the base records
for its submodule, under `refs/swarm/gitlink`, fetched by id when the
submodule's own checkout has moved on. Which submodules are mirrored,
and how the containers check them out, is in
[Submodule mirrors](#submodule-mirrors).

The state file also records the Docker daemon (`docker info` ID) the
engagement runs on, and a token of 16 random hex digits that
`launch.sh` makes for each new engagement (an engagement id can come
from the caller and repeat, the token cannot); containers and volumes
carry it in `swarm-core.engagement-token`. `post-process` and
`interactive` joining an engagement, `stop`, `wait`, `retire` and
`cleanup` refuse when Docker talks to another daemon (another Docker
context or `DOCKER_HOST`): switch back first. Each command uses the
Docker context it found when it started for all its Docker calls, even
if another terminal switches it meanwhile.

`SWARM_ENGAGEMENT_TOKEN` binds a command to one engagement: `stop`,
`post-process`, `interactive`, `retire`, `cleanup` and `harvest.sh`
refuse when it is set and the state file records another token or none
(`retire` and `cleanup` check it under the engagement lock, before they
change anything), and `post-process` and `interactive` then never
create an engagement. `start` refuses it outright: it makes a new
engagement, and a token names one to join. Set and empty is refused by
every command: only an unset variable names no engagement. `wait`
reads the token
once, refuses to go on when the engagement changed while it waited
(a cleanup and a new start in another terminal), and passes the token
to the post-process or harvest it runs; the dashboard passes it to each
`launch.sh` it runs.

A new engagement starts only on a clean runtime directory. `start`, and
`post-process` or `interactive` when the state file records no
engagement, refuse while the runtime directory holds a bare repo, an
`upstream.git.new`, `mirrors/` or a remnant of a cleanup, while a
container or a workspace volume of this checkout exists, or while an
interactive session is open; `start` also refuses while the state file
still records an engagement, even with nothing of it left on disk. The
error lists what it found and, when the bare repo holds agent work the
checkout lacks, what to harvest. End the engagement first: stop the
agents, run `harvest.sh`, then `./launch.sh cleanup`. Nothing is
removed by force.

The state file decides between creating and joining: an engagement it
records is joined, never created again, and only when it is complete,
that is when its bare repo is a usable bare repository (Git, given its
path, takes it for one, and its `HEAD` names a commit). `post-process`
and `interactive`, and `wait` before it goes on to post-process or
`harvest.sh`, refuse an incomplete engagement and point to
`./launch.sh cleanup`; a recorded engagement's bare repo is never made
again. With a target, `post-process` and `interactive` also need its
snapshot to pass the target's check, and `wait` checks it before it
polls (see [Target](#target)). The engagement is recorded before
anything of it is made (a target is resolved into scratch first and
published as `target.git` right after the record), and a bare repo or
a mirror is cloned to `<name>.new` and renamed once ready (the mirrors'
manifest is written before the mirrors it lists), so a run
stopped half way leaves the record and whatever it had made by then
(`target.git`, target scratch, a `.new`, the bare repo, mirrors),
which `cleanup` finishes, keeping what Git holds in the bare repo, the
mirrors and a `.new` as recovery refs. A mistake in the swarmfile (an
unknown driver or context mode) or a failed image build stops `start`
before the engagement is created. Containers mount the bare repo with
`--mount`, which fails on a missing source rather than creating an
empty directory there.

### Submodule mirrors

Every submodule initialized on the host is mirrored, at any depth: the
submodules the engagement's base records (each submodule at the commit
its superproject's commit records) whose name the host's own
`.gitmodules` maps to a path with a `.git` there. A submodule moved on
the host is found under its name; a linked worktree's submodules are
its own; one that `git submodule deinit` left without its `.git` is not
initialized, and neither is anything under it. Each mirror is cloned
from the Git directory that `.git` leads to, with none of your system
or global Git configuration (no URL rewrite applies), into
`mirrors/<id>.git`, numbered in the order of the walk, parents first.
`mirrors/manifest.json` (`swarm-core.mirrors/v1`) lists each with its
id, its superproject's id (0 for the checkout), its name and its path
in that superproject (base64, so that any bytes go through) and its
commit.

Before an engagement is created, `start`, and `post-process` or
`interactive` when they create one, refuse a submodule the containers
could not get, and say what to do: one whose Git directory lacks the
commit the base records (fetch it there, `git submodule update`, or
deinit the submodule), a shallow or partial clone, one reached through
a link or outside its superproject, a `.git` that leads nowhere, a
name or path with a tab or a newline, two names whose Git directories
would be one inside the other, a `.gitmodules` Git refuses (a key
without a value, `update = !command`), a name the host's `.gitmodules`
gives two paths, or a repository at a submodule's path that the host's
`.gitmodules` gives to no submodule. Earlier releases warned about a
missing commit and went on; every container then stopped at that
submodule.

An interactive session that joins keeps the mirrors there, makes again
one that is gone, and adds the submodules initialized on the host
since; one whose mirror is there needs nothing more from the host.
`post-process` joining adds none. Before any container starts, every
mirror the manifest lists must be there with its commit; otherwise the
command stops and says whether an interactive session that joins can
make it again or only `./launch.sh cleanup` deals with it. With no
submodule, nothing is mounted.

Containers mount `mirrors/` read-only at `/mirrors`. At startup, before
the agent runs, each submodule the manifest listed when the launch found
the mirrors ready (a join may add more meanwhile) is checked out from its
mirror,
parents first, at the commit its superproject's checkout records,
through the file protocol only and never with `--recursive`: no
submodule is fetched over the network, and one the manifest does not
list stays uninitialized (the agent can still initialize it itself).
A submodule that agent-work moved, replaced, renamed or set to
`update = none` is skipped; one that cannot be checked out from its
mirror stops the startup. When the agent leaves submodules off their
gitlinks, the push path puts every checked-out one under `/workspace`
back with a forced checkout, without fetching anything. The target's
submodules are not mirrored (see [Target](#target)).

An engagement an earlier release created has its mirrors named after
the submodules and no manifest: this release does not join it
(`post-process` and `interactive` refuse); finish it with that release,
or end it with `./launch.sh cleanup`, which handles both layouts.

### Engagements of earlier releases

An earlier release's engagement records no Docker daemon in the state
file, and its containers keep their files in their own layers (or in
volumes `docker_args` made); Docker may remove some when they stop
(`--rm` in `docker_args`). This release does not take such an
engagement over: `start`, `post-process`, `interactive`, `stop`,
`wait`, `retire`, `cleanup` and `harvest.sh` refuse it and change
nothing, and only `status` and `logs` work on it. The same holds for
what an engagement leaves (a bare repo, mirrors, containers, volumes)
when the state file records none, and for a runtime directory in a
place this release refuses. Finish it with the release that made it:
check that release out, stop the agents, run `harvest.sh`, then follow
that release's cleanup steps in its USAGE.md, and come back to this
one.

### Engagement lock

`start`, `post-process`, `interactive`, `chat`, `shell` and
`harvest.sh` take `engagement.lock` in the runtime directory with
`flock -n` before they change anything, and fail at once while another
operation holds it. `start` and `post-process` keep it until they exit
(`harvest.sh` started by them shares it). `interactive` keeps it while
it records the session in `interactive-<container name>.pending` in the
runtime directory (its pid, that process's start time and the Docker
daemon), then lets it go and execs `docker run`, which keeps the pid.
Docker mounts the bare repo and the mirrors when the container starts,
so while that process runs, or the container runs after a detach
or was created and may still start (found by its `swarm-core.session`
label, which a rename keeps),
`start`, and `post-process` or `interactive` when they would create
the bare repo, fail instead of replacing them. Every command that
creates the bare repo mirrors the submodules; an interactive session
that joins an existing bare repo keeps the mirrors already there and
only adds missing ones. Once the session's process has ended, a check from
another Docker daemon (another Docker context or `DOCKER_HOST`) fails
instead of guessing, and each check and launch pins one Docker context
for all its Docker commands. `start --dashboard` lets the lock go before
the dashboard opens. `stop` waits for it after its first passes, which
stop what runs without it (see [Stopping the swarm](#stopping-the-swarm));
`wait` takes it once the agents are done, and waits up to a minute for
it. `status`, `logs`, `progress.sh`, `costs.sh` and the dashboard
never take it, and containers push through git without it.

A caller that runs several commands as one unit can hold the lock
itself and pass the descriptor in `SWARM_LOCK_FD`. The engine checks
that the descriptor is open on that lock file and locks through it:

```bash
(
    exec 9>>"<runtime dir>/engagement.lock"
    flock -n 9 || exit 1
    SWARM_LOCK_FD=9 ./launch.sh start || exit $?
    SWARM_LOCK_FD=9 ./launch.sh wait
)   # The lock goes when the subshell exits.
```

`flock` comes with util-linux on Linux; on macOS install it with
`brew install flock`.

### Upgrading from `/tmp` state

Older releases kept this state in `/tmp/<project>-upstream.git`,
`/tmp/<project>-mirror-*.git` and `/tmp/<project>-swarm.env`, where
any local user could write to it. It is never reused, and this release
changes nothing there. While `/tmp/<project>-upstream.git` exists and
belongs to you, `start`, `post-process`, `interactive`, `chat`, `shell`
and `harvest.sh` stop.

Containers that an older release started carry no labels, so
`launch.sh` refuses every command while they exist, `stop` included,
before it gets to the `/tmp` check (see
[Project identity](#project-identity)). Their agents push to the old
bare repo. Finish that engagement with the release that made it, as
for [engagements of earlier releases](#engagements-of-earlier-releases):
check it out, stop the agents, harvest, then follow its USAGE.md. To
look at the agents' commits in the old bare repo meanwhile, fetch its
branches and review them before merging anything (this changes nothing
there):

```bash
git fetch /tmp/<project>-upstream.git \
    '+refs/heads/*:refs/remotes/legacy-swarm/*'
```

## Retiring containers

`./launch.sh retire` removes this checkout's stopped engine containers;
`./launch.sh retire --post-process` removes only `<project>-agent-post`,
so `post-process` can run again. A container's `/workspace` is a
Docker volume that stays; what goes is the container's own layer, so
retire checks every selected container before it removes any, and
refuses when one

- is running, paused or restarting, or has a restart policy or
  auto-remove (Docker could start or remove it on its own);
- has anything but its own workspace volume at `/workspace`, or
  another mount or a tmpfs below it;
- belongs to an open interactive session;
- has global or system git config (the global files where Git looks
  for them under the container's `HOME` and `XDG_CONFIG_HOME`, and the
  system file the container's git names with `git var`, which needs
  Git 2.42 or later in the image; read as the container's user)
  that sets `lfs.storage`, `core.worktree` or `core.hooksPath`,
  includes other files, cannot be parsed, or lies on a mount; or has
  Git environment variables of its own, or a `HOME` that is empty,
  relative or not normalized;
- has repository data outside `/workspace`: a worktree registered
  elsewhere (except the linked worktrees below), a `.git` that is a
  link or a gitfile, repository config
  that includes files or sets `core.worktree` outside, `core.hooksPath`,
  `lfs.storage` or a filter driver, alternates outside, or a
  repository inside the volume that the scan cannot carry (see
  [Cleanup](#cleanup));
- has a symlink in the volume that leads to data the container wrote
  itself, or to an image file it changed (links into the unchanged
  image, such as a virtualenv's `python`, are fine);
- has a Git repository outside `/workspace` that is not a checkout
  (a bare repository, a git dir kept apart from its work tree, a
  `.git` file or link outside every checkout, a repository at `/`), or
  a checkout there that the scan below refuses.

A checkout outside `/workspace` (a test's fixture in `/tmp`, a clone
the agent made, one its image ships: `docker diff` goes by metadata, so
any repository there may hold changes) is kept: retire scans it in the
snapshot the way cleanup scans a volume, copies everything Git keeps
there into this checkout as recovery refs, runs `git fsck --full`, and
only then removes the container. Work outside Git's history in it
(uncommitted, untracked or ignored files, the agent's `agent_logs`
included) stops retire, unless `./launch.sh retire
--discard-uncommitted` (or cleanup's) drops exactly what it lists; so
does a repository below it that the scan cannot carry, and a link that
leads out of it into what the container wrote. A repository nested in
it is kept with it, the way cleanup keeps one in a volume. A container's
checkouts may take `SWARM_RETIRE_LAYER_LIMIT_MB` megabytes (default
100) as bundles; above that, copy out what you need and remove the
container yourself.

A linked worktree of a repository in the volume that lies in the
container's own layer (`git worktree add /tmp/base` run in a checkout
under `/workspace`) is checked the same way, without a bundle of its
own, since its history and its admin files are in the volume: its work
outside Git's history stops retire unless `--discard-uncommitted` drops
exactly what it lists. Retire lets it through only when its registered
path is absolute, passes no link and no mount, has no mount below it,
holds a `.git` file naming that repository's admin directory for it,
and holds no other repository, no special file and no link that leads
out of it; anything else refuses as before (a relative path, a worktree
of a checkout in the layer, a volume repository's worktree inside such
a checkout). A registration whose directory is verifiably not there
(each directory on the way listed, none of them a link or on a mount)
stops nothing; its admin files are kept with the repository.

The checks run in a throwaway container started from a snapshot of the
stopped container (`docker commit`, removed afterwards, also when
retire is interrupted; one left by a retire that was killed outright
is removed by the next), with the volume read-only and no network, so
links resolve as they did in the container and every repository
outside the volume is found. For links that lead out of the volume,
`docker diff` and a comparison with the original image tell whether
the container wrote what they lead to (a name that is not valid UTF-8
reaches `docker diff` altered, so such a name refuses too).

Those containers run the agent's own files and tools, so what they
send back is checked rather than trusted: the docker client writes at
most `SWARM_HELPER_OUTPUT_LIMIT_MB` megabytes to any one file (the
bound is per file, not a total, and not the disk a helper uses inside
Docker), a scan's archive must hold only the scan's own files, and
the scans read no global or system Git config and stop before they
read a work tree whose repository config sets a filter driver or
includes other files.

The error says what to copy out first. Removal goes by ID, without
`-f`, and leaves any container that changed since it was checked. Run
`costs.sh` before retire if you need the containers' stats. retire
needs no swarmfile; it takes the engagement lock, refuses an engagement
of an earlier release (see
[Engagements of earlier releases](#engagements-of-earlier-releases)),
and removes nothing while Docker talks to another daemon than the
engagement's.

## Cleanup

`./launch.sh cleanup` deletes this checkout's engagement: its
containers, its workspace volumes, the bare repo and the mirrors. It
loses nothing Git kept there: before it deletes a repository location
it copies everything Git keeps in it (every ref and reflog entry,
every object, stashes, unfinished operations, and every file of the
git dir) into the checkout as recovery refs, and checks them there.
A repository cloned or initialized inside a workspace (a setup hook's
clone of the code under audit, say) is copied the same way, with its
submodules: its git dir is checked like the workspace's, its work
outside Git's history is listed with its path, and the workspace's
entry for its directory is not counted as the workspace's own. A
repository there that is not an ordinary checkout (a bare repository,
a `.git` that is a link, a `.git` file that leads anywhere but a git
dir the scan copies, a repository with another object format) stops
cleanup.

The target snapshot, `target.git` in the runtime directory (the
engagement's copy of the audit target), holds none of the engagement's
work: cleanup deletes it without copying it, after the repository
locations, with a record of its own in the checkpoint, so a run cut off
resumes from what is left on disk. What a target resolution cut off
left (`.target-fetch.*` and `.target-prep.*` in the runtime directory)
is never part of an engagement: every cleanup deletes it first, best
effort, and names what it leaves (something mounted in it, files this
user cannot delete). Something mounted in the runtime directory still
stops the cleanup of an engagement, as below.

```bash
./launch.sh cleanup [--discard-uncommitted] [--allow-unharvested]
```

It stops, and deletes nothing of the engagement, when

- the bare repo holds agent work that HEAD's history does not have yet
  (`agent-work`, `swarm/*`, `agent-parked/*`): harvest first. When it
  never can (`harvest.sh` refuses when HEAD's history no longer has
  the engagement's base commit, after a rewritten upstream say), take
  what you need by
  hand and pass `--allow-unharvested`, which keeps that work as
  recovery refs only. A read of the bare repo's refs that fails part of
  the way refuses either way;
- a container still runs (stop the agents first) or cannot be retired
  (see [Retiring containers](#retiring-containers)), or an interactive
  session is open or starting;
- a workspace, the bare repo or a mirror holds work outside Git's
  history (uncommitted or ignored files, files too large to copy):
  commit or copy it out, or pass `--discard-uncommitted`, which drops
  exactly what it lists;
- a repository in a workspace is a partial clone (its history is not
  all there, and cleanup never fetches);
- `mirrors/` holds anything that is not a mirror, a remnant of one, or
  the manifest as a regular file;
- `target.git` or `target.git.removing` is a link, is not a directory
  or is another user's, or both are there;
- the checkout cannot keep the copies by itself (a shallow or partial
  clone, alternates, an object store inside what cleanup deletes), or
  `git fsck --full` finds problems in it;
- the Docker daemon is not the engagement's, or sees other files than
  this host at the runtime directory's path (a remote daemon);
- the runtime directory is `/`, your home directory or another user's,
  holds or lies inside the checkout or its git dir, or has a comma, a
  quote, a tab or a newline in its path;
- something is mounted inside the runtime directory, or at a workspace
  volume's directory on this host (cleanup never deletes through a
  mount);
- the engagement is an earlier release's (see
  [Engagements of earlier releases](#engagements-of-earlier-releases)).

It checks the workspace volumes while the stopped containers are still
there, so none of these refusals touches a container; then it retires
the containers and checks everything again before it copies and
deletes. A later failure (the copy into the checkout, `git fsck`)
leaves the containers retired and every repository location in place,
so save the containers' logs and stats first if you need them
(`./launch.sh logs N`, `costs.sh`). A `.new` that a run cut off while
it cloned the bare repo or a mirror is copied as it is (every file)
and deleted too.

A repository in a volume that registers a linked worktree outside it
does not stop those checks: such a worktree is in a container's layer,
which retire checks first (see
[Retiring containers](#retiring-containers)), or it is gone. Only a
directory at that path in the image the checks run from that holds a
`.git` file naming the repository back stops them.

The recovery refs are `refs/swarm-recovery/e<hex>/<snapshot>/s<n>/...`
(cleanup) and `.../l<n>/...` (the checkouts retire keeps), `<hex>`
being the engagement id in hex;
`git cat-file blob refs/swarm-recovery/e<hex>/<snapshot>/sources`
says what each `s<n>` or `l<n>` was, and the tree at
`.../<snapshot>/mirrors-manifest` holds the mirrors' manifest as it was
(which submodule each `mirrors/<id>.git` was). Under each, every git dir copied
has a number `<k>`: `<k>/path` holds where it was (`.git`, or
`engagement_target/.git` for a repository nested in the workspace),
`<k>/t/...` hold its objects. The files of the workspace's `.git` are
under `0/files` and `0/f/...`, and those of a nested repository's
`.git` under the number of that `.git`; the git dirs of its submodules
and linked worktrees have their own `<k>/path` and objects, their
files being part of that `.git`. That sources ref is written only
once every copy of its snapshot is in the checkout and `git fsck`
passed, so a snapshot with one is a verified copy; one without it was
stopped before (its refs may be partial), and the next run copies again
under a new snapshot. The engine never deletes them. To drop them once
you are sure you do not need them:

```bash
git for-each-ref --format='%(refname)' refs/swarm-recovery/ \
    | xargs -n 1 git update-ref -d
```

Files the agents wrote belong to the container's user; what this user
cannot delete goes through a throwaway container of the engine image,
as root. A cleanup that stops half way (an error, Ctrl-C) leaves a
checkpoint in the state file: start, post-process, interactive, stop
and harvest.sh refuse until `./launch.sh cleanup` runs again and
finishes. Each run checks everything again and copies whatever is still
there; it also checks that the recovery refs earlier runs wrote are
intact. The engagement lock, the runtime directory and its claim stay.

## Control interface

A program that drives engagements (a CI job, a scheduler) uses
`control.sh`: it names the interface it was written for, runs the
engine's commands, and observes an engagement without changing
anything. This section is `swarm-core.control/v1`. Such a program
depends on it and on nothing else of swarm-core: paths, the files in
the runtime directory (`state.json`, the mirrors' manifest), container
names and the output of commands may change from one release to the
next.

```bash
./control.sh version
./control.sh --interface swarm-core.control/v1 observe
./control.sh --interface swarm-core.control/v1 start
./control.sh --interface swarm-core.control/v1 wait
./control.sh --interface swarm-core.control/v1 cleanup
```

### Commands

Every command but `version` and `--help` takes
`--interface swarm-core.control/v1` first, as two arguments. Another
interface, none, no command, an unknown command, or an argument to
`version` or `observe` exits 2, before anything is read, with one line
on stderr: `swarm-core: usage: <message>`, or
`swarm-core: unsupported-interface: <message>`.

Actions are the engine's commands: `start`, `stop`, `wait`,
`post-process`, `retire`, `cleanup`, `interactive`, `chat` and `shell`
run `launch.sh` with that command and the arguments that follow it,
`harvest` runs `harvest.sh` with its arguments. `control.sh` runs them
by `exec`, before it reads anything: the same process, working
directory, environment, descriptors and terminal, and that command's
output and exit status. Each does what the rest of this document says
it does and needs what it needs (`retire` and `cleanup` need no
swarmfile, `harvest` no Docker). They exit 0 when they did it, and
non-zero with a message otherwise. `post-process` exits with the status
of the harvest it runs when that harvest fails, and with its container's
otherwise; the interactive commands exit with `docker run`'s, which is
the session's. v1 does not tell failures apart: a program reads
`observe` before it decides what to do next. `status` and `logs` are for people, and not part of v1.

Queries change nothing. No file, directory, lock, container, volume,
image, Git object or ref, Docker context or Docker configuration is
created, changed or removed, and no temporary file is made; reading
still updates what any read updates (access times). Queries take no
lock, and their only Docker calls are `docker context show`,
`docker info`, `docker ps`, `docker container inspect`,
`docker volume ls` and `docker volume inspect`. On macOS, where
`/usr/bin/git` is a shim that can write a cache of the developer tools'
place in a temporary directory, a query runs the developer tools' git
itself (the one `xcode-select -p` names) when the git on `PATH` is that
shim.

- `version` prints
  `{"schema":"swarm-core.version/v1","engine":"<version>","interfaces":["swarm-core.control/v1"]}`.
  It reads only the engine's `VERSION` file, from any directory.
- `observe` prints one JSON document, `swarm-core.observation/v1`
  (below), for the checkout of the current directory, once it is
  complete.

A query exits 0, or 1 with nothing on stdout and, first on stderr, one
line `swarm-core: <reason>: <message>`:

| Reason | When |
|--------|------|
| `not-a-checkout` | The current directory is in no Git working tree. |
| `bad-environment` | `SWARM_PROJECT` is no project id, or the runtime directory (from `SWARM_RUNTIME_DIR`, `XDG_STATE_HOME` or `HOME`; see [Runtime directory](#runtime-directory)) is a place it cannot be, as `start` refuses it: not an absolute path, `/` or `HOME`, the checkout, its git dir or something in or around them, or a path with a comma, a quote, a tab or a newline. |
| `runtime-unsafe` | The runtime directory exists, and is a link, no directory, another user's, has permission bits other than 700 (special bits such as the sticky bit aside), or on macOS has an ACL with an allow entry. |
| `runtime-foreign` | The runtime directory belongs to another checkout, or to another project id. |
| `state-unreadable` | The state file is no regular file, is not one `swarm-core.state/v1` object, or has a field of the wrong type. |
| `state-unstable` | The state file changed between the two reads of `observe` three times running. |
| `missing-tool` | `jq`, `git` or `perl` is not installed, or neither `sha256sum` nor `shasum` is; on macOS, also when `git` is Apple's shim and no developer tools with a git are there. |
| `engine-unreadable` | The engine's `VERSION` file, or one of its `lib/` files, cannot be read. |
| `internal` | A tool the query runs failed where it should not; the message says at which step. |

The environment a program sets for these commands, as this document
describes each variable: `SWARM_CONFIG`, `SWARM_PROJECT`,
`SWARM_RUNTIME_DIR`, `XDG_STATE_HOME`, `SWARM_ENGAGEMENT_ID`,
`SWARM_ENGAGEMENT_TOKEN`, `TARGET_REPO`, `TARGET_REV`,
`TARGET_REV_BASE`, `TARGET_REV_BASE_REPO`, `DOCKER_HOST` and
`DOCKER_CONTEXT`. Of these, `observe` reads only `SWARM_PROJECT`,
`SWARM_RUNTIME_DIR`, `XDG_STATE_HOME`, `DOCKER_HOST` and
`DOCKER_CONTEXT` (and `HOME`). The other variables of
[Environment variables](#environment-variables) (credentials,
timeouts, limits) work as described there, outside v1; `SWARM_LOCK_FD`
is not part of v1.

### Observation

`observe` reads the state file once, and everything it says of the
state comes from that read. It checks whether the engagement's bare
repo is published between that read and a second one; when the two
differ, it starts again, three times at most (then `state-unstable`).
Every Docker call uses the same choice of
daemon (the context read once, or `DOCKER_HOST`), so another terminal
that switches the current context meanwhile changes nothing; the calls
span an interval, so the lists are no atomic snapshot of Docker, and
a container or volume that goes between its listing and its inspection
is left out.

Every field is always there, with its type; "or null" says when it can
be null.

| Field | Type | Meaning |
|-------|------|---------|
| `schema` | string | `swarm-core.observation/v1`. |
| `interface` | string | `swarm-core.control/v1`. |
| `engine` | string | The engine's version. |
| `observed_at` | string | When the reads began, UTC (`2026-01-31T12:00:00Z`). |
| `project` | string | The project id. |
| `checkout` | string | The checkout's path, links resolved. |
| `runtime_dir` | string | The runtime directory, for people: what it holds is not part of the interface. |
| `docker.context` | string or null | The Docker context every call used (`DOCKER_CONTEXT`, or the current one); null when `DOCKER_HOST` chose the daemon, or no context could be read. |
| `docker.daemon` | string or null | The ID of the daemon Docker talks to; null when it could not be reached. |
| `conditions` | array of strings | The conditions below that hold, sorted. |
| `engagement` | object or null | The engagement the state records; null when it records none. |
| `containers` | array or null | This checkout's workload containers, sorted by name; null when Docker did not answer. |
| `workspaces` | array or null | This checkout's workspace volumes, sorted by name; null when Docker did not answer. |

When Docker answered `docker info` but a listing or an inspection then
failed, `docker.daemon` has the ID and `containers` and `workspaces`
are null: null never stands for an empty list.

`engagement`:

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | The engagement id. |
| `token` | string or null | Its token; null for an earlier release's engagement. |
| `started_at` | string or null | When it began, UTC; null when not recorded. |
| `base_commit` | string or null | The checkout's commit the agents started from; null when not recorded. |
| `docker_daemon` | string or null | The daemon it runs on; null for an earlier release's engagement. Compare it with `docker.daemon`: `stop`, `wait`, `post-process`, an interactive session that joins, `retire` and `cleanup` refuse another daemon; `harvest`, which reads the bare repo, does not. |
| `revision` | string | A digest of the state record the document comes from: two documents with the same revision come from the same record, and a record that changed gets another one. |
| `complete` | boolean | Its bare repo is published and usable (a bare repository whose `HEAD` names a commit). False while `start` is still making it, after a run stopped before it was, or when it is gone or damaged. |
| `target` | object or null | Its audit target as recorded when the engagement began (see [Target](#target)): `repo` and `rev` as given, `commit` resolved then, `format` (`sha1` or `sha256`), and `base`, null or `repo`, `rev` and `commit` of the base. All strings. |
| `cleanup_checkpoint` | object or null | A cleanup recorded its checkpoint and has not finished; it may be running, or may have stopped. `recorded_at` (string, UTC) and `run_count` (integer: the runs that recorded one). `recorded_at` is when the first run recorded it. Null does not mean no cleanup ran. |

Each of `containers`:

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | Docker's full container ID. |
| `name` | string | Its name now. |
| `role` | string or null | `agent` (a numbered agent), `post-process`, `interactive` or `shell` (the mode a session opened in); null for a container an earlier release made. |
| `profile_index` | integer or null | The `agents[]` entry (from 1) its profile is; null for post-process. |
| `agent_number` | integer or null | A numbered agent's N; null for the others. |
| `engagement` | string or null | The engagement it belongs to. |
| `engagement_token` | string or null | That engagement's token. |
| `state` | string | Docker's: `created`, `running`, `paused`, `restarting`, `removing`, `exited`, `dead`, or a later value as Docker gives it. |
| `error` | string or null | Docker's error starting it: a container that failed to start stays `created` with one. |
| `exit_code` | integer or null | Its exit code when `exited` or `dead`; null otherwise. |
| `oom_killed` | boolean | Docker says the kernel ended it for memory. |
| `created_at` | string | Docker's time (RFC 3339, UTC). |
| `started_at` | string or null | Docker's time; null when it never started. |
| `finished_at` | string or null | Docker's time; null when it never finished. |

Each of `workspaces`:

| Field | Type | Meaning |
|-------|------|---------|
| `volume` | string | The volume's name. |
| `container` | string or null | The name of the container it was made for; that container may since be gone, or renamed. |
| `kind` | string or null | `agent` (numbered agents and post-process) or `interactive` (interactive and shell sessions). |
| `engagement` | string or null | The engagement it belongs to. |
| `engagement_token` | string or null | That engagement's token. |

Conditions:

| Condition | Meaning |
|-----------|---------|
| `cleanup-pending` | A cleanup recorded its checkpoint and has not finished. Every action but `retire` and `cleanup` refuses; `cleanup` goes on with it. |
| `legacy-engagement` | An earlier release recorded the engagement (it records no Docker daemon). Every action refuses it: finish it with that release (see [Engagements of earlier releases](#engagements-of-earlier-releases)). |
| `legacy-mirrors` | The runtime directory holds submodule mirrors an earlier release made, without a manifest. `post-process` and `interactive` do not join the engagement; `cleanup` ends it. |
| `mirrors-incomplete` | A run stopped while it wrote the mirrors' manifest or a mirror (`manifest.json.new`, or a mirror's `.git.new`), the mirrors directory or its manifest is not one this release can use (a link, no regular file, not this engagement's manifest, a name or path in it that is none), or a mirror it lists is a link or its `refs/swarm/gitlink` is not the commit the manifest gives (the pin that `post-process` checks too; the commit object itself is not looked for). `post-process` and `interactive` do not join the engagement; `cleanup` ends it, unless the mirrors directory or a manifest is a link or no regular file. Without the engagement's base commit (an earlier release's record), only the manifest's form is checked. |
| `mirrors-missing` | A mirror the manifest lists is gone. `post-process` does not join the engagement; an interactive session that joins makes the mirror again while the host still has that submodule initialized, and `cleanup` ends the engagement. |
| `unrecorded-leftovers` | No engagement is recorded, but the runtime directory or Docker holds part of one, which an earlier release made. A new engagement does not start, and `retire` and `cleanup` refuse, until it is finished with that release. |
| `unlabeled-containers` | Containers named like this project's carry no owner label: an earlier release made them. Every action refuses (`harvest` when Docker answers) until they are gone. |
| `foreign-containers` | Containers of this project id belong to another checkout. Every action refuses (`harvest` when Docker answers) until they are gone, or this checkout has its own `SWARM_PROJECT`. |
| `legacy-tmp-state` | An earlier release left state in `/tmp` (see [Upgrading from `/tmp` state](#upgrading-from-tmp-state)). `start`, `post-process`, `interactive` and `harvest` refuse, and so does `wait` once its agents are done, until it is finished with that release. |

`observe` looks for the conditions that need Docker
(`unlabeled-containers`, `foreign-containers`, and the containers and
volumes behind `unrecorded-leftovers`) only when `containers` is not
null. The list names states this release knows: an action can still
refuse for another reason, and then says why.

What `observe` does not tell: a `start` that is still running (the
engagement is recorded before its target, bare repo and agents, and
`complete` turns true once the bare repo is published), and how many
agents a run was meant to have (the program keeps the plan it gave;
none is recorded until every agent was launched).

### Labels

Workload containers (numbered agents, post-process, interactive and
shell sessions) carry these labels, which are part of the interface:
`swarm-core.project` (the project id), `swarm-core.checkout` (the
checkout's path, links resolved), `swarm-core.engagement`,
`swarm-core.engagement-token`, `swarm-core.role` (`agent`,
`post-process`, `interactive`, `shell`), `swarm-core.profile-index`
(the `agents[]` entry, from 1; empty for post-process) and
`swarm-core.agent-number` (a numbered agent's N; empty for the
others). The engine sets every one of them on every workload
container, from the profile it chose and the mode a session opens in
(`interactive --shell` is `shell`, `shell --chat` is `interactive`).
`docker_args` cannot set a `swarm-core.` label (see
[Extra Docker arguments](#extra-docker-arguments)). The helper
containers of `retire` and `cleanup` carry none of them with a value:
retire's checks run from snapshots that have them emptied. A label keeps
its meaning for good; another meaning would take another key. Other
`swarm-core.` labels are the engine's own.

### Compatibility

`swarm-core.control/v1` covers the grammar above; the commands, their
arguments and the environment above, as this document describes them;
what each action does; exit statuses; the `observe` fields with their
types and nullability; the reasons and conditions with their meanings;
and the labels. A program ignores fields it does not know, and takes an
unknown `state`, `role`, `kind`, reason or condition for one it cannot
act on. v1 may gain commands, optional arguments, fields, reasons,
conditions and values, and nothing else: no field becomes required or
nullable, or changes meaning or type, and no exit status changes.
Anything else is a new interface, which `version` lists and
`--interface` selects.

## Verify image

```bash
docker run --rm --entrypoint bash \
    -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
    <project>-agent \
    -c 'claude --dangerously-skip-permissions \
        -p "What model are you? Reply with model id only." \
        --model claude-opus-4-6 2>&1'
```
