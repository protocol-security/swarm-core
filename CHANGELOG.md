# Changelog

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
  Node.js 20 is only installed when Gemini CLI is needed. `launch.sh`
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
