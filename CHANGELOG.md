# Changelog

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
