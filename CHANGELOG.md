# Changelog

## 0.19.0 — 2026-04-13

- **Codex CLI driver.** New `codex-cli` driver
  (`lib/drivers/codex-cli.sh`) implements the full interface for
  OpenAI's Codex CLI: headless mode with `codex exec --json`,
  JSONL stats extraction (with cached-token deduplication for
  accurate cost), activity parsing, fatal/retriable error
  detection, and reasoning effort support.
- **ChatGPT subscription auth.** Codex agents can authenticate
  via `"auth": "chatgpt"` (mounts `~/.codex/auth.json`) or
  `"auth": "apikey"` (uses `OPENAI_API_KEY`). Auto-detection
  when both are present. Usage-limit errors from ChatGPT
  subscriptions are retriable.
- **Bridge .claude/ conventions to Codex.** When `AGENTS.md` is
  absent, copies `.claude/CLAUDE.md` (or root `CLAUDE.md`) so
  Codex picks up project instructions. When `.agents/skills/`
  is absent, symlinks `.claude/skills/` so Codex discovers
  existing skills. Both are git-excluded to avoid committing
  bridged files.
- **Context stripping hooks.** Git hooks (`post-merge`,
  `post-checkout`, `post-rewrite`) re-strip `.claude/` after
  `git pull --rebase`, preventing agents from seeing files
  removed by `context: slim` or `context: none`.
- **Stale rebase cleanup.** Push safety net cleans up stale
  `.git/rebase-merge` and `.git/rebase-apply` before retries,
  preventing repeated `git pull --rebase` failures.
- **Inline system prompt for Codex.** System instructions are
  prepended directly to the prompt text rather than relying on
  project-level instruction files, ensuring rules are always
  applied under `--skip-git-repo-check`.
- **Document per-driver effort values.** USAGE.md now lists
  valid effort values for each driver (Claude Code:
  low/medium/high/max; Codex CLI: none/low/medium/high/xhigh).
  Gemini CLI ignores the field.

## 0.18.4 — 2026-04-11

- **Tag and driver in setup wizard.** `setup.sh` now prompts for
  the `tag` and `driver` fields under advanced settings. Tag
  supports `$VAR` env expansion; driver defaults to `claude-code`
  and is omitted from the config when unchanged. A tip after
  writing the config points users to USAGE.md for additional
  advanced fields.

## 0.18.3 — 2026-04-10

- **Fix bare repo UID mismatch for container pushes.** The bare
  repo is created by the host user, but the container's `agent`
  user may have a different UID.  Set `core.sharedRepository=world`
  and `chmod -R a+rwX` so any UID can push.  Fixes integration
  test failures (`2-agents-sonnet`, `1-agent-effort`,
  `2-agents-effort`) caused by `unable to create temporary object
  directory` errors on GitHub Actions runners.

## 0.18.2 — 2026-04-09

- **Create bare repo on demand in post-process.** When
  `launch.sh post-process` runs standalone (after harvest has
  cleaned up), the bare repo no longer exists. Instead of
  exiting with an error, create one from the local repo.

## 0.18.1 — 2026-04-07

- **Soften agent system prompt.** Replace urgency and fear-based
  framing ("IMPORTANT", "will be lost") with calmer language that
  normalizes push failures and mentions the harness safety net.
  Motivated by Anthropic's interpretability research showing that
  desperation-associated representations causally increase reward
  hacking and misaligned behavior in Claude.

## 0.18.0 — 2026-04-07

- **Extra Docker arguments.** New top-level `docker_args` array in
  the swarmfile passes arbitrary flags to every `docker run`
  invocation. Each element is one shell token. Useful for mounting
  the host Docker socket (`-v /var/run/docker.sock:...`), adding
  `--privileged`, `--network=host`, or any other Docker flag the
  harness does not manage natively.

## 0.17.1 — 2026-04-06

- **Fix rate-limit retry for Pro subscriptions.** Claude Code's
  Pro rate limit uses `"rate_limit"` and `"rate_limit_event"` in
  its output, which the retriable-error detector did not match.
  Additionally, when no pattern matched, `agent_is_retriable`
  returned a non-zero exit code that crashed the harness under
  `set -e`, silently killing the agent instead of retrying or
  logging a fatal error.
- **Compact retry status in dashboard.** Format retry wait/max
  as short durations (e.g. `retry 0s/7h` instead of raw seconds)
  so the Status column doesn't cause line wrapping on narrow
  terminals.
- **Clear retry status when session resumes.** The retry file was
  only removed after the session ended, so the dashboard showed
  stale "retry" status while the agent was actively working.

## 0.17.0 — 2026-04-04

- **Push safety net for concurrent agents.** After each agent
  session the harness checks for unpushed local commits and
  retries `git pull --rebase && git push` up to three times with
  random jitter.  Fixes the race condition where multiple agents
  competing for the bare-repo lock could leave commits stranded
  locally, causing idle-timeout exits in multi-agent swarms.

## 0.16.0 — 2026-04-04

- **Thinking/reasoning in activity stream.** Agent logs now
  display thinking content alongside tool calls.  Claude Code
  thinking blocks (`type:"thinking"`) and Gemini CLI thought
  events (`type:"thought"`) both render as
  `Think: <first 80 chars>` in the live activity feed.

## 0.15.0 — 2026-04-04

- **Top-level tag with per-group override.** New `tag` field in
  the swarmfile sets a default label for all agent groups.
  Per-group `tag` overrides the top-level value.  Supports
  `$VAR` env expansion.  Post-process inherits the top-level
  tag when none is set. (#41)
- **Documentation cleanup.** Complete the driver interface list
  in USAGE.md (all 13 functions).  Add missing test files to
  the unit-test listing.  Remove stale claims, redundant
  paragraphs, and fix per-group fields list in README.md.

## 0.14.0 — 2026-04-04

- **Rate-limit retry with exponential backoff.** New
  `max_retry_wait` field (seconds) in the swarmfile. When set,
  agents retry with exponential backoff (30 s initial, 30 min cap)
  on rate limits and zero-token exits instead of exiting. Default
  is 0 (exit immediately). New `agent_is_retriable` driver
  interface function distinguishes retriable errors from true
  fatals.

## 0.13.1 — 2026-04-04

- **Dependency version warnings.** `check_deps` now warns when
  bash, git, jq, or docker are below the tested minimums. Set
  `SWARM_SKIP_DEP_CHECK=1` to silence. Never blocks execution.
- **Disable git commit signing in containers.** Agents set
  `commit.gpgsign=false` globally so FIDO/GPG-enforced hosts
  do not block agent commits. Tests do the same in temp repos.
- **jq 1.8 compatibility.** Guard `split("/") | .[-1]` with
  `// ""` fallback in model summary expressions. jq 1.8 returns
  null for `.[-1]` on empty arrays (from splitting an empty
  string), breaking `rtrimstr()`. Coerce pricing interpolation
  values to numbers with `+ 0`. Both changes are no-ops on
  jq 1.6. (#42)

## 0.13.0 — 2026-03-23

- **Swarmfile-only configuration.** Environment variables and CLI
  flags can no longer substitute for swarmfile fields. A swarmfile
  is now always required. API credentials (`ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `OPENROUTER_API_KEY`, etc.) remain
  environment variables.
- **Optional top-level prompt.** The top-level `prompt` field is no
  longer required when every agent group specifies its own `prompt`.
- **Dashboard column widening.** Status column widened to 14 chars
  (handles `idle N/M` without misalignment), In/Out column widened
  to 13 chars for large token counts.
- **Branch info in dashboard header.** The header now shows the git
  branch instead of the prompt path. Auto-detects branch and HEAD
  from the repo the swarm runs in. The `title` field in the
  swarmfile is respected and persists across dashboard refreshes.
- **Claude Code version pinning.** New `claude_code_version` field
  in the swarmfile passes a specific version to the install script,
  allowing reproducible Docker image builds.
- **MiniMax-M2.7 in kitchen-sink.** Updated the showcase config to
  the newer model with per-model pricing.
- Rewrite dry-run documentation to use the swarmfile pattern.
  Expand cleanup section with full artifact inventory.

## 0.12.1 — 2026-03-23

- **Config pricing overrides driver cost.** The `pricing` map in
  `swarm.json` now always takes precedence when present. Previously
  it only applied when the driver reported $0 (Gemini CLI path).
  Claude Code reports costs at Anthropic rates even when routing to
  third-party endpoints (MiniMax, self-hosted models via litellm),
  so third-party runs showed wildly inflated costs.

## 0.12.0 — 2026-03-19

- **Push after every commit.** System prompt now instructs agents to
  push immediately after each commit, not just at session end.
  Prevents silent commit accumulation inside containers that the
  harness and harvest cannot see.
- **Task-complete stopping.** Replaced "stop after pushing" with
  "keep working until your task is complete, then stop." Agents
  with multi-step or looping prompts now continue naturally instead
  of exiting after the first push. The harness idle counter still
  catches agents with nothing to do.
- **Hardened smoke test.** Split counting and reasoning into two
  commits with distinct messages; add step-0 "already done" guard
  so harness re-runs do not produce duplicate commits; pre-commit
  hook now unstages `agent_logs/` and `.claude/settings.local.json`;
  verification fails on missing reasoning files and garbage commits.

## 0.11.0 — 2026-03-17

- **Gemini CLI driver.** New `gemini-cli` driver
  (`lib/drivers/gemini-cli.sh`) implements the full interface for
  Google's Gemini CLI: headless mode with `--output-format stream-json`,
  JSONL stats extraction, tool-call activity parsing, and fatal error
  detection.
- **Auth abstraction.** New `agent_docker_auth()` interface function
  lets each driver resolve its own credentials and emit Docker `-e`
  flags. Claude Code handles ANTHROPIC_API_KEY / OAuth / auth-token;
  Gemini CLI handles GEMINI_API_KEY and OpenRouter. The ~50-line auth
  block that was duplicated in `launch.sh` (start + post-process) is
  now a single call per driver.
- **Default model per driver.** New `agent_default_model()` interface
  function so each driver declares its fallback model (claude-opus-4-6,
  gemini-2.5-pro, fake-model). `harness.sh` calls it when
  `SWARM_MODEL` is unset, removing the hardcoded Claude default.
- **Conditional Dockerfile.** `SWARM_AGENTS` build arg controls which
  CLIs are installed: `claude-code` (default), `gemini-cli`, or both.
  Node.js 22 is only installed when Gemini CLI is needed. `launch.sh`
  derives the arg from config and passes it to `docker build`.
- **Dashboard driver label.** `format_model()` shows a `[gem]` or
  `[fake]` suffix when the agent's driver is not the default
  `claude-code`, making mixed-driver swarms easy to identify at a
  glance.
- Add 6 new test configs covering gemini-only, mixed-driver,
  OpenRouter, driver inheritance, post-process, and heterogeneous
  kitchen-sink scenarios. 87 new test assertions (762 total).

## 0.10.0 — 2026-03-16

- **Agent driver abstraction.** The harness is no longer coupled to
  Claude Code. A pluggable driver interface (`lib/drivers/*.sh`)
  lets each agent CLI implement `agent_run`, `agent_extract_stats`,
  `agent_activity_jq`, and other role functions. Adding a new agent
  is now a single file in `lib/drivers/`.
- Ship two drivers: `claude-code` (production) and `fake` (test
  double that emits realistic JSONL without Docker or API keys).
- Add `SWARM_DRIVER` config field in `swarm.json` (top-level
  default and per-agent override) to select the agent driver.
- Validate driver interface on startup: harness fails fast with a
  clear error if any required function is missing.
- Extract shared JSONL stats parser into `lib/drivers/_common.sh`
  to eliminate duplication across drivers.
- Wire up `agent_docker_env()` so drivers can map generic config
  (e.g. effort level) to CLI-specific Docker environment variables.
- Dashboard reads generic `SWARM_MODEL` and `SWARM_EFFORT` env
  vars instead of Claude-specific `CLAUDE_MODEL` and
  `CLAUDE_CODE_EFFORT_LEVEL`.
- Bridge the process boundary for activity filtering: the driver's
  `agent_activity_jq` output is written to a temp file so the
  piped `activity-filter.sh` subprocess can read it.
- Preflight driver validation in `launch.sh`: unknown drivers are
  rejected before any containers are started.
- Document the Dockerfile build-time limitation (CLI binary is
  baked in, `SWARM_DRIVER` is a runtime choice) with a TODO for
  build-arg support when a second production driver lands.
- Add 40+ new unit test assertions covering driver fields in config
  parsing, `agent_docker_env`, shared stats helper, interface
  completeness, and activity filter process boundary.
- Guard the dashboard post-process keybinding (`p`) so it checks
  whether `post_process` is configured before stopping agents.
- Document dry-run pattern using the `fake` driver in `USAGE.md`.

## 0.9.3 — 2026-03-12

- Set `CLAUDE_CODE_ATTRIBUTION_HEADER=0` in workspace settings to
  prevent KV cache invalidation with local models (up to 10x
  faster inference via llama.cpp / other local backends).
- Disable telemetry and nonessential traffic in agent containers
  (`CLAUDE_CODE_ENABLE_TELEMETRY=0`,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`).
- Error out when `--agents` is used with a config file that defines
  agent groups, instead of silently ignoring the flag.

## 0.9.2 — 2026-03-10

- Add CHANGELOG.md covering all releases (0.1.0 through 0.9.1).
- Block execution when required tools are missing. A shared
  `check_deps()` guard in `lib/check-deps.sh` checks for bash,
  git, jq, bc, docker, and tput at startup.
- Update README prerequisites with tput, whiptail (optional),
  and shellcheck (development).

## 0.9.1 — 2026-03-10

- Show idle state (`idle N/M`) in dashboard Status column via
  lightweight file-based approach (replaces `docker logs` parsing).
- Widen dashboard Model column to prevent row wrapping with
  long model names.
- Add README for test config fixture files.
- Remove unrelated rules from CLAUDE.md.

## 0.9.0 — 2026-03-09

- Responsive dashboard columns that adapt to terminal width,
  hiding less-critical columns on narrow screens.
- Optional user-supplied tag column in dashboard.
- Show credential source in dashboard Auth column.
- Show test progress counter in dashboard title.
- Slim README to scannable landing page, move details to
  USAGE.md with fenced code blocks for syntax highlighting.
- Color full agent log line yellow, not just prefix.

## 0.8.0 — 2026-03-08

- Add CLI flags to `launch.sh start` (`--prompt`, `--model`,
  `--agents`, `--max-idle`, `--effort`, `--setup`,
  `--no-inject-git-rules`, `--dashboard`).
- Flatten dashboard header into single line.
- Color activity filter prefix with ANSI yellow.
- Hide idle count from dashboard status column (later
  reintroduced in 0.9.1).

## 0.7.0 — 2026-03-06

- Support `auth_token` for OpenRouter-style Bearer auth.
- Expand `$VAR` env references in `api_key` config fields.
- Rebalance dashboard column widths for long model names.

## 0.6.0 — 2026-03-04

- Show per-group prompt tags and tree-style agent summary in
  dashboard header.
- Add pre-commit hook to guard submodule pointers.
- Add post-rewrite hook to re-inject provenance trailers.
- Prevent submodule recurse on `git fetch`.
- Reclaim workspace ownership after sudo setup.

## 0.5.0 — 2026-03-04

- Per-group prompt override in `swarm.json` so each agent group
  can run a different task file.
- Add per-group prompt question to setup wizard.

## 0.4.0 — 2026-03-04

- Per-agent context mode (`full`, `slim`, `none`) to control how
  much of `.claude/` each agent group sees.
- Show context mode in dashboard Ctx column.
- Add context mode prompt to setup wizard.
- Add `hlog()` helper for timestamped harness log lines.
- Color harness lines green, errors red; align agent prefix with
  harness prefix in log output.
- Skip session when prompt file is missing.

## 0.3.0 — 2026-03-03

- Activity streaming: real-time tool-call feed from `stream-json`
  output, shown via `launch.sh logs N` or dashboard `[1-9]` key.
- Add `lib/activity-filter.sh` to parse `stream-json` events.

## 0.2.0 — 2026-02-27

- `swarm.json` config file for per-agent model groups.
- Always-on TUI dashboard with per-agent cost, tokens, cache,
  turns, throughput, and duration.
- `costs.sh` for standalone cost and usage summary.
- Interactive setup wizard (`setup.sh`).
- Wait and post-process commands.
- Per-agent auth source selection and Auth column in dashboard.
- Accept `CLAUDE_CODE_OAUTH_TOKEN` as alternative to API key.
- Support effort level per agent and globally.
- Inject git coordination rules via system prompt.
- Add `--help` flag to all scripts.
- Move model provenance from git author name to commit trailers.
- Add VERSION file and `Tools:` trailer with claude-swarm
  branding.
- Prefix project env vars with `SWARM_`.
- Move internal files into `lib/` and tests into `tests/`.
- Comprehensive unit test suite (500+ assertions).

## 0.1.0 — 2026-02-10

- Initial release.
- N Claude Code instances in Docker, coordinating through git.
- Bare repo mirroring with per-agent workspace clones.
- Harness loop: reset to `origin/agent-work`, run one session,
  push.
- `harvest.sh` to merge agent work into the host branch.
- Configurable git identity via `GIT_USER_NAME` and
  `GIT_USER_EMAIL`.
