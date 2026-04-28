# Changelog

## 0.20.13 — 2026-04-28

- **Fix: codex-cli driver misclassifies "Selected model is at
  capacity" as non-retriable.** OpenAI's fleet-saturation
  response is `{"message": "Selected model is at capacity.
  Please try a different model."}` -- a genuine short-lived
  transient.  `agent_is_retriable` in
  `lib/drivers/codex-cli.sh` only matched the rate-limit/quota
  class and v0.20.7's transient class (SSE drops, 5xx,
  connection layer), so the capacity message fell through to
  non-retriable and killed the agent with `exiting due to
  unrecoverable error`.

  Worst at quota-reset boundaries: when every quota-bound
  client retries simultaneously, the model fleet is briefly
  saturated and capacity errors land on the first post-reset
  session attempt -- exactly the moment the backoff loop
  should be re-entering, not exiting.  Observed in production
  swarm runs as silent agent loss with no clean recovery path
  (container has to be `docker start`ed by hand) and outcomes
  that depend on which retry happens to land a few seconds
  later when capacity frees up.

  Fix: extend the `_transient` regex with `at capacity` and
  `please try a different model`.  Either substring alone
  classifies the response as transient, so an OpenAI wording
  tweak that drops one half doesn't reintroduce the
  regression.  Genuinely fatal conditions (invalid auth,
  model not found, etc.) still return empty.

  Tests: `tests/test_harness.sh` §14b adds three assertions
  matching the issue's reproduction: the full JSON message,
  the `at capacity` substring alone, and the `please try a
  different model` substring alone.  Existing non-retriable
  counter-tests (auth error, model not found) still pass, so
  the change is additive.  Closes #85.

## 0.20.12 — 2026-04-28

- **Fix: codex agents commit unsigned even when `signing_key`
  is configured.**  The bind-mounted `/etc/swarm/signing_key`
  inherits host perms (often `0644` for shared swarm-bot
  keys), and `ssh-keygen -Y sign` refuses world-readable keys
  with `UNPROTECTED PRIVATE KEY FILE`.  Claude Code surfaces
  the failure; Codex CLI silently retries the same commit
  with `--no-gpg-sign` (openai/codex#6199), so commits land
  without a signature and signing-required branches reject
  the push hours later.  See
  https://github.com/openai/codex/issues/6199.

  Fix: `lib/signing.sh` now `install -m 0600`'s the source key
  to `/dev/shm/swarm-signing-key` (tmpfs, RAM-backed,
  per-container in Docker -- private key bytes never hit disk)
  and points `user.signingkey` at the copy.  `install` failure
  short-circuits with `return 1` before any `git config` runs,
  so a missing `/dev/shm` or full tmpfs surfaces immediately
  instead of leaving `user.signingkey` pointing at a path that
  doesn't exist (which would silently fail every later commit).
  An optional second argument lets tests override the
  destination.

  Tests: `tests/test_harness.sh` §12 adds six assertions: copy
  exists, perms are `0600`, `user.signingkey` points at the
  copy, nothing leaks under `$HOME/.ssh/`, install failure
  returns non-zero, and install failure does not poison
  `user.signingkey`.  The pre-existing `run_signing_config`
  helper now threads an explicit sandbox `dst_key` so unit
  tests stop leaking files into the host's `/dev/shm`.

- **Codex CLI version pinning.** New `codex_cli_version` field
  in the swarmfile mirrors `claude_code_version`: forwarded to
  `npm install -g @openai/codex@<ver>` via a Docker build-arg.
  Empty (or unset) keeps the default "latest published
  release" behavior.  `Dockerfile` adds
  `ARG CODEX_CLI_VERSION=`, `launch.sh` reads the field with
  `jq` and forwards it as `--build-arg` only when set, and
  `lib/drivers/codex-cli.sh`'s `agent_install_cmd` heredoc
  matches.  Tests: `tests/test_launch.sh` §29 pins the jq
  filter (present + absent), and `tests/test_drivers.sh` §30
  pins the install snippet structurally and behaviorally
  (empty `CODEX_CLI_VERSION` -> `@openai/codex`, pinned ->
  `@openai/codex@<ver>`).

- **Test infra: isolate scratch-repo unit tests from host
  gitconfig.**  `tests/test_launch.sh` and
  `tests/test_session_end_push.sh` build scratch repos and run
  `git commit` / `commit-tree` against them.  When the host
  has SSH-SK signing or a `commit.gpgsign=true` global, every
  internal commit prompts for a hardware-key touch.  Both
  files now `export GIT_CONFIG_GLOBAL=/dev/null` and
  `GIT_CONFIG_SYSTEM=/dev/null` at the top, so the unit-test
  surface is independent of the developer's signing setup.

## 0.20.11 — 2026-04-24

- **Fix: `launch.sh` bare-repo preflight sends the operator
  at `harvest.sh` even when local HEAD is strictly ahead of
  the bare.**  The divergence guard refused every
  `BARE_HEAD != LOCAL_HEAD` case with the same message, but
  when local is ahead of the bare `harvest.sh` has nothing
  to collect and the only workable remediation is `rm -rf`
  on the bare.  Post-harvest cherry-picks of recovered
  `agent-parked/*` refs (routine under 0.20.10's retry park),
  squash/rebase of the harvested branch before the next phase,
  and topic branches forked from post-harvest state all land
  here.

  Fix: distinguish the two directions with `git merge-base
  --is-ancestor $BARE_HEAD HEAD` in the local repo.  Running
  the check in the bare (as first drafted in the report) would
  fail to resolve `LOCAL_HEAD` in the stale case -- local's new
  commit is not in the bare's object db -- and collapse stale
  into unharvested, leaving the bug in place.  In local,
  ancestry resolves cleanly across all three cases:
  `BARE_HEAD` in local and ancestor of `HEAD` -> stale;
  `BARE_HEAD` absent from local -> unharvested (which also
  covers true divergence).  Both messages name short
  `BARE_HEAD` and `LOCAL_HEAD` so the operator can verify at
  a glance, and the stale branch leads with `rm -rf` as the
  primary remediation.

  Also switch the `rev-parse refs/heads/agent-work` call to
  `--verify --quiet`.  Without it, a bare that exists but
  lacks the `agent-work` ref captures the literal pathspec
  (`refs/heads/agent-work`) into `BARE_HEAD`, the divergence
  test sees a non-empty value, and the guard fires on an
  otherwise-empty bare with a garbage SHA.

  Tests: `tests/test_launch.sh` §37 mirrors the guard as a
  helper and drives it against six scenarios: equal (guard
  allows), unharvested (bare has a commit local doesn't),
  stale (local has a commit bare doesn't), divergent (each
  side has unique commits), bare absent (no-op), bare present
  without `agent-work` ref (no-op).  Each failure branch pins
  both the wording and the presence of both short SHAs in
  the output.

## 0.20.10 — 2026-04-23

- **Fix: session-end `git pull --rebase && git push` fails every
  retry when the target repo installs worktree-touching hooks.**
  The push path in `lib/harness.sh` ran the primary rebase and
  push with client-side hooks active.  When the consumer repo
  installed a `post-checkout` or `post-rewrite` hook that
  regenerates docs, stamps build artifacts, or otherwise
  modifies tracked files, those hooks fired during the rebase's
  internal checkouts under `.git/rebase-merge/` and re-dirtied
  the tree that the pre-rebase stash + submodule-sync had just
  cleaned.  Every one of the three primary retries hit the same
  dirty-tree trap.  The `_scratch_worktree_push` fallback
  recovered because it already passed `-c core.hooksPath=/dev/null`
  on its `git worktree add`, cherry-pick, and commit -- but the
  common case paid the cost of the rare case, and when
  `/upstream` had any other transient issue on top (the reporter
  hit a momentarily corrupt loose object from a concurrent
  unpack on the bare repo) the fallback also failed and the
  salvage-park push dropped the commit: scratch push rejected,
  park push rejected too, harness logged "commits remain in
  local repo", and the ephemeral container exited with the
  agent's work lost.

  Fix, part 1: pass `-c core.hooksPath=/dev/null` to both `git
  pull --rebase` and `git push` on the primary session-end path,
  matching what the scratch fallback already does.  Suppression
  is safe: the swarm's own `prepare-commit-msg` and
  `post-rewrite` hooks are both no-ops on commits that already
  carry a `Model:` trailer, and every agent commit does because
  `prepare-commit-msg` runs at commit time.  The override is
  client-side only, so server-side hooks on `/upstream`
  (pre-receive, update, post-receive) still run.

  Fix, part 2: wrap the salvage-park push inside
  `_scratch_worktree_push` in the same bounded
  `for _ptry in 1 2 3` retry with 1..5s jitter that the primary
  path uses, and gate the "parking also failed" error on a
  `_park_ok` flag so a successful attempt 2 or 3 no longer gets
  reported as a loss.  A transient `/upstream` hiccup now has
  three chances to drain before the container exits.

  Tests: `tests/test_session_end_push.sh` §1 pins
  `-c core.hooksPath=/dev/null` on both primary git invocations
  and on the scratch-fallback `worktree add` structurally; §2
  pins the park retry loop's shape, backoff, logging, and
  `_park_ok` gating against a regex-extracted slice of
  `lib/harness.sh`; §3 proves the hook-suppression mechanism at
  the elementary level (repo with a `post-checkout` hook fires
  twice without the flag, zero times with it); §4 reproduces
  the bug end-to-end by setting up two clones of a bare remote
  that diverge on `agent-work`, installing a hostile
  `post-checkout` hook in the second clone that rewrites a
  tracked file, and asserting that without the fix `git pull
  --rebase` leaves the tree dirty or fails, whereas with the
  fix the rebase exits 0, the worktree is clean, HEAD is the
  local commit correctly rebased onto the remote tip, and the
  subsequent push lands; §5 drives the park retry idiom with a
  fake `git` that fails a configurable number of push attempts
  and asserts the loop survives 2 transient rejections with
  `park_ok=true`, returns after 1 attempt when push succeeds
  immediately, and exhausts with `park_ok=false` after 3
  rejections.  `tests/test_harness.sh` pre-existing invariants
  updated to match the new shape.

  Reported by @BowTiedRadone (#82).

## 0.20.9 — 2026-04-23

- **Fix: `dashboard.sh` / `costs.sh` / `lib/harness.sh` die with
  `printf: <n>.<m>: invalid number` on hosts using `,` as the
  decimal separator.**  All three scripts format decimals the
  same way -- `printf '%.1f' "$(echo ... | bc -l)"` in the shell
  tier, `awk "BEGIN { printf \"%.6f\" ... }"` for per-session
  cost accounting in the harness -- and `bc` / most `awk`
  implementations always emit `.` regardless of locale.  Bash's
  builtin `printf` and GNU awk's `printf`, however, parse `%f`
  arguments per LC_NUMERIC, so on a host with LC_ALL unset and
  LANG pointing at a locale that uses `,` as the decimal
  separator (de_DE, fr_FR, sv_SE, nl_NL, ...) the dashboard
  greeted the operator with a garbled error line instead of a
  tokens-per-second value, and the harness would silently
  miscount session cost on any container running gawk under an
  affected locale.

  Fix: export `LC_NUMERIC=C` at the top of each entry point
  (directly under `set -euo pipefail`, before any function is
  defined or any `bc`/`awk`/`printf` runs), so internal number
  parsing and formatting use `.` as the decimal separator
  regardless of the operator's locale.  LC_ALL, LANG,
  LC_MESSAGES, LC_TIME, and LC_COLLATE are left untouched, so
  timestamps, error messages, and UI text still render in the
  operator's language.

  Tests: `tests/test_locale.sh` §1 pins the `export LC_NUMERIC=C`
  literally on all three scripts (structural); §2 bootstraps a
  comma-decimal locale either from the host's available locales
  or via unprivileged `localedef` into a per-test `LOCPATH`
  (glibc-only; skips gracefully on macOS); §3 reproduces the bug
  by sourcing the formatting helpers under the broken locale
  without the fix and asserts the subshell exits non-zero with
  an `invalid number` error on stderr; §4 re-enables the fix in
  the same subshell and asserts `format_tps`, `format_tokens`
  (both the `M` and `k` branches), and `format_cost` all produce
  `.`-separated output.

  Reported by @friedger.

## 0.20.8 — 2026-04-23

- **Fix: `harvest.sh` aborts mid-preview when `agent-work` has
  a large commit log.**  `harvest.sh` runs under
  `set -euo pipefail` and line 55 emits a preview of the
  incoming commits with `echo "$COMMIT_LOG" | head -20`.  When
  `agent-work` has more than 20 new commits and the oneline
  log exceeds the 64 KiB kernel pipe buffer, `head` closes
  stdin after its 20-line slice, `echo` gets SIGPIPE (exit
  141), pipefail propagates the failure to the pipeline, and
  `set -e` exits the script before the `... and N more`
  overflow line can print and before the actual `git merge`
  runs.  A user harvesting a large swarm sees the first 20
  commits printed and an unexplained non-zero exit with no
  merge performed.

  Fix: append `|| true` to the preview pipeline, matching the
  `grep -c . || true` idiom one line above.  Short logs render
  unchanged; long logs now advance to the merge step.

  Tests: `tests/test_harvest.sh` §6 pins the `|| true` on the
  preview line structurally, §7 seeds 100 empty commits with
  ~1 KiB subject padding so the oneline log exceeds the pipe
  buffer and runs the real `harvest.sh --dry` against the
  fixture (asserts exit 0 and the `... and 80 more` overflow
  line), and §8 pipes a synthetic 250 KiB log through the
  guarded and unguarded forms of the idiom to document the
  class of bug.

  Credit: Fredrik (@fredrik0x) spotted and fixed the SIGPIPE.

## 0.20.7 — 2026-04-22

- **Fix: codex-cli SSE stream drops treated as unrecoverable
  despite `max_retry_wait` being set.**  Codex CLI's own
  reconnect budget is a hard-coded 5 attempts; after 2 of those
  are consumed on a transient OpenAI 5xx / SSE drop it emits
  `fatal: Reconnecting... 2/5 (stream disconnected before
  completion: An error occurred while processing your request...
  You can retry your request...)` and exits.  0.20.6's
  `agent_is_retriable` for codex-cli only matched rate-limit /
  quota wording, so the harness classified this as fatal and
  exited the agent container immediately — bypassing the
  backoff loop entirely even when the operator set
  `max_retry_wait: 1800` in the swarmfile.  Observed in practice
  as a validator container dying at T+3h15m of a 5h production
  run on a transient network blip, leaving the swarm one role
  short for the rest of the run.

  Fix: `agent_is_retriable` in `lib/drivers/codex-cli.sh` now
  recognises a `transient` class alongside `rate_limited`,
  covering SSE stream drops (`stream disconnected`,
  `Reconnecting...`), connection layer errors (`connection
  reset|closed|refused`, `timed out`), upstream 5xx gateway
  signals (`bad gateway`, `service unavailable`, `50[234]`),
  and OpenAI's generic retry hint (`processing your request`).
  Genuinely fatal conditions (invalid auth, model not found,
  etc.) still return empty so the harness exits fast on config
  bugs.

  Tests: `tests/test_harness.sh` §14b sources the driver, feeds
  probe strings for each pattern class, and asserts the
  classifier returns `rate_limited` / `transient` / `""`
  respectively.

- **Fix: cherry-pick conflicts in `_scratch_worktree_push` drop
  the agent's commits on the floor.**  0.20.6's fallback aborts
  the cherry-pick on conflict, resets the scratch worktree, and
  returns 1.  The local commits live on in the agent's working
  repo, but the *next* session's opening
  `git reset --hard origin/agent-work` erases them — the
  hands-free recovery path assumed the next pull-rebase would
  succeed, and when a real conflict persists across sessions it
  does not.  Observed as 3 lost commits across a 23-transplant
  5h production run (all were low-value journal/claim markers,
  but the failure mode is indistinguishable from losing a
  finding).

  Fix: when the scratch transplant fails at any step
  (cherry-pick, commit, or final push) `_scratch_worktree_push`
  now pushes the agent's local HEAD to a salvage ref on origin
  named `agent-parked/<agent-id>-<UTC-timestamp>` before tearing
  down.  The parked branch holds the agent's original SHAs (not
  the discarded cherry-pick replays), so harvest and manual
  inspection see the exact commits the agent made.  The push
  step proper still returns 1 — `agent-work` is not advanced,
  which keeps dedup / fetch semantics unchanged — but the work
  is no longer lost.  If the parking push itself fails
  (unreachable origin, auth, etc.) the commits remain in the
  agent's local repo, which is exactly where they started, and
  an error is logged so the operator can investigate.

  Tests: `tests/test_harness.sh` §18e stages a genuine textual
  conflict (both-added file at identical path with incompatible
  content), runs the fallback against a bare repo, and asserts
  (a) the fallback returns 1, (b) exactly one
  `agent-parked/<agent>-*` ref was created on origin, (c) its
  tip is the original local SHA, (d) `agent-work` was not
  advanced.  Structural pins against `lib/harness.sh` verify
  the parking code path exists in the production function, not
  just in the test rig.

## 0.20.6 — 2026-04-21

- **Fix `scratch push: worktree add failed` under consumer-
  installed post-checkout hooks.**  0.20.5's
  `_scratch_worktree_push` passes `-c core.hooksPath=/dev/null`
  to the `cherry-pick` and `commit` invocations but not to the
  preceding `git worktree add`.  That omission was benign in
  most cases but fatal for any consumer that installs a
  post-checkout hook referencing another hook via a relative
  path: in a linked worktree `.git` is a gitfile (not a
  directory), so `.git/hooks/<anything>` resolves to "Not a
  directory" at the syscall level and the entire worktree-add
  aborts before cherry-pick ever runs.  Observed in practice
  as 100% fallback failure with the log line `scratch push:
  worktree add failed` immediately followed by `push failed
  after 3 retries and scratch fallback` -- the scratch path
  was effectively dead on arrival for affected consumers,
  reverting 0.20.5 to 0.20.4 behaviour (commit loss at session
  close).

  Fix: add `-c core.hooksPath=/dev/null` to the `git worktree
  add` call in `lib/harness.sh`.  One-line code change; hooks
  were already irrelevant in the scratch worktree.

  Tests: `tests/test_harness.sh` §18a pins the flag on the
  worktree-add site structurally and §18d exercises the
  failure mode end-to-end -- installs a hostile post-checkout
  hook, runs the fallback, asserts it still succeeds, then
  repeats with a flag-free control to confirm the hostile hook
  does break worktree-add when suppression is off.  (See
  §18d's "negative control" assertion.)

## 0.20.5 — 2026-04-20

- **Cherry-pick-onto-scratch fallback when session-end rebase
  exhausts its retries.**  On a 12-event dirty-tree bug-report
  run against an 0.20.4 swarm the in-place `git pull --rebase
  && git push` path failed in 12/12 cases across three distinct
  patterns: (A) submodule pointer drift that `git stash` cannot
  capture (`M <submodule>` on the gitlink); (B) context-stripping
  hooks firing during the rebase's internal checkouts under
  `.git/rebase-merge/` re-dirtying the tree between the pre-apply
  clean state and the rebase's own integrity check; (C) "skipped
  previously applied commit" interactions with multi-agent swarms
  whose commit graphs overlap.  Each ended with the three-attempt
  retry loop burning out and the next session's opening
  `git reset --hard origin/agent-work` erasing the in-flight
  work.  0.20.5 adds `_scratch_worktree_push` in `lib/harness.sh`:
  after the existing retry loop gives up, the harness fetches
  `origin/agent-work` fresh, spins up a detached `git worktree
  add` at that tip in `/tmp/swarm-push-<agent>-<pid>-<rand>`,
  cherry-picks each unpushed commit via `cherry-pick -n` +
  redundancy check + `commit --allow-empty-message -C`, pushes
  `HEAD:agent-work` from the scratch, and tears the worktree
  down.  Hooks are suppressed in the scratch via
  `core.hooksPath=/dev/null` so the context-stripping post-
  checkout hook that caused pattern B cannot re-delete files the
  cherry-pick is meant to bring back.  Submodules are
  deliberately not initialised in the scratch -- the push only
  cares about the superproject's gitlinks, and a submodule-free
  worktree sidesteps pattern A entirely.  The two-step cherry
  pick + `commit -C` dance is a manual equivalent of git 2.45's
  `cherry-pick --empty=drop` done by hand so it stays portable
  to the git 2.39 on Debian bookworm (the base image); the
  "dropping redundant commit" branch specifically handles
  pattern C.  Behavioural coverage in `tests/test_harness.sh`
  §18b sets up a bare + working clone with a three-shape dirty
  tree (tracked mod, tracked deletion, untracked scratch),
  drives the fallback, and verifies the commits land on origin
  while the main worktree's dirty state survives untouched;
  §18c simulates pattern A by publishing a patch-equivalent D'
  via a sibling clone and asserts the fallback drops the local
  D instead of stamping a duplicate on top.

- **Activity watchdog inside `_run_reaped` for silent CLI
  hangs.**  On the same bug-report run one codex-cli agent went
  silent for 4h22m (SESSION_TIMEOUT=0 on that invocation) before
  the operator noticed and ran `docker stop`; the CLI was alive
  but deadlocked internally (stuck model request or blocked MCP
  tool), so `wait "$_cmd_pid"` in `_run_reaped` never returned,
  the post-wait group-kill never fired, and the harness sat on
  the `| tee` pipe indefinitely.  0.20.5 adds `_reap_watchdog`
  in `lib/drivers/_common.sh`: a sibling background process
  polls `<logfile>`'s mtime every `$SWARM_ACTIVITY_POLL` seconds
  (default 10), and if no advance is seen for
  `$SWARM_ACTIVITY_TIMEOUT` seconds it SIGTERMs the CLI's
  process group, polls for up to `$SWARM_WATCHDOG_GRACE` seconds
  (default 10), then SIGKILLs.  The kill decision is tee'd into
  `<logfile>.err` so operators can distinguish a watchdog-killed
  exit from a crashed-on-its-own exit after the fact.  Opt-in
  via `SWARM_ACTIVITY_TIMEOUT` -- 0 (the default) disables the
  watchdog and preserves pre-0.20.5 behaviour; 300-600 is a
  sensible starting point for production codex-cli / claude-code
  swarms.  `SWARM_ACTIVITY_POLL` and `SWARM_WATCHDOG_GRACE` are
  exposed primarily so the behavioural test suite can drive the
  full escalation in ~3s rather than the production 20s floor.
  `tests/test_drivers.sh` §40 adds 15 structural pins (mtime
  probe with BSD fallback, SIGTERM-before-SIGKILL escalation,
  poll-for-exit rather than fixed sleep, env-var validation,
  watchdog backgrounding + cleanup) plus 6 behavioural
  assertions (full-escalation path, pre-kill output preserved,
  dormant-when-disabled, non-numeric-degrades-safely).

- **Test coverage growth.**  `tests/test_harness.sh` goes from
  124 to 147 assertions (+23 in §18); `tests/test_drivers.sh`
  from 300 to 321 (+21 in §40).  Full `./tests/test.sh --unit`
  runtime increases by roughly 3 s on Linux (mostly the §40b
  watchdog escalation rehearsal), unchanged on macOS (the
  setsid/stdbuf behavioural blocks skip cleanly).

## 0.20.4 — 2026-04-19

- **Close the remaining session-end rebase failures on dirty trees.**
  The `rebase.autoStash=true` fix shipped in 0.20.2 closed the common
  unstaged-tracked-file case but left three adjacent failure modes
  unhandled, each empirically observed across an 11-event,
  2-hour / 4-agent codex-cli run on a repo with a submodule:
  (1) `git stash` defaults to **not** stashing untracked files, so
  `?? <path>` survives the autoStash and the rebase still refuses;
  (2) `git stash` does **not** capture submodule pointer drift
  (`M <submodule>`) regardless of flags -- the superproject gitlink
  diff is invisible to stash's default traversal, which causes every
  `cargo build` / `git worktree add` / etc. that bumps a submodule's
  HEAD to block the next push; (3) when autoStash *does* create a
  stash, the auto-pop after a successful rebase is best-effort per
  git's own docs and was observed failing mid-rebase on "skipped
  previously applied commit" in multi-agent swarms where commit
  histories overlap.  The push block now sidesteps all three: it
  runs an explicit `git stash push --include-untracked` to capture
  tracked + untracked state, then `git submodule update --init
  --recursive --force` to re-sync submodule HEADs to what the
  superproject expects (the one thing stash cannot reach), then a
  bare `git pull --rebase` against a guaranteed-clean tree.  The
  pre-push stash is intentionally **not** popped -- the next
  session's opening `git reset --hard origin/agent-work` wipes
  whatever was in-flight anyway, and not popping removes the entire
  autoStash-pop conflict class.  The stash stays in the reflog
  (`git stash list` / `git stash show stash@{N}`) for forensic
  recovery.  `tests/test_harness.sh` §17 now pins seven invariants
  against the harness source: pre-stash with `--include-untracked`,
  submodule force-sync, bare rebase, absence of `git -c
  rebase.autoStash`, absence of `git stash pop` inside the push
  block, porcelain status logging, and stash-ref logging.  Credit
  to the operator who ran the 2h / 4-agent codex-cli smoke on a
  superproject-with-submodule repo and filed the bug report with
  raw harness logs and the empirical failure-mode breakdown that
  made this fix straightforward to scope.

## 0.20.3 — 2026-04-19

- **Tolerate missing `stdbuf`/`setsid` on macOS CI runners.** The
  `_run_reaped` helper introduced in 0.20.2 unconditionally piped
  through `stdbuf -oL tee` and launched the CLI under `setsid`,
  which broke `./tests/test.sh --unit` on the macOS GitHub Action
  with "stdbuf: command not found" -- both are GNU utilities
  (coreutils / util-linux) shipped with the production
  `debian:bookworm-slim` container but absent from stock macOS.
  `_run_reaped` now probes for each tool: missing `stdbuf` falls
  back to bare `tee` (matching the pattern `fake.sh` already
  uses), missing `setsid` runs the CLI in-line without the
  group-kill (the zombie-reaping protection is only meaningful
  inside the production container where `setsid` is always
  present, so the in-line fallback is unit-test scaffolding
  rather than a degraded production path).  §39's behavioural
  block skips with a `SKIP` notice when either tool is
  unavailable; the 7 structural grep pins still run on every
  host so the bug cannot silently regress in source.

## 0.20.2 — 2026-04-19

- **Preserve agent work across session-end rebase.** The push path
  in `lib/harness.sh` now runs `git -c rebase.autoStash=true pull
  --rebase` instead of the bare form.  Without autoStash, `git pull
  --rebase` refuses outright on a dirty working tree ("cannot pull
  with rebase: You have unstaged changes"), the three-attempt retry
  loop burns through all its tries without pushing, and the
  subsequent between-session `git reset --hard origin/agent-work`
  silently erases whatever in-flight edits, untracked scratch
  files, or dirty submodule pointers the agent left behind.
  autoStash stashes, rebases, and reapplies transparently, scoped
  via `git -c` so no container-level config is touched.  The push
  path also logs `git status --porcelain=v1` once before the retry
  loop so operators can audit the exact uncommitted state at
  session end.

- **Reap driver process groups so the agent pipeline can drain.**
  Agent CLIs (codex, claude, gemini) routinely spawn helper
  subprocesses (MCP servers, reasoning workers, IPC brokers) that
  inherit stdout.  When the CLI's main process exits without
  waiting for those children, the children keep the pipe to `tee`
  open, `tee` never sees EOF, and the downstream
  `| /activity-filter.sh` pipeline wedges indefinitely — the
  harness blocks on the pipe and no progress is made until the
  container is externally killed.  A new shared helper
  `_run_reaped` in `lib/drivers/_common.sh` puts each CLI in its
  own process group via `setsid` and SIGKILLs the group after
  `wait`, so surviving descendants release their FDs and the
  pipeline observes EOF normally.  `claude-code.sh`, `codex-cli.sh`
  and `gemini-cli.sh` now route through the helper; `fake.sh`
  emits synthetic JSONL inline and is intentionally exempt.

## 0.20.1 — 2026-04-17

- **Preserve environment across `sudo` in setup hook.** The
  container's setup script now runs via `sudo -E bash`,
  preserving the container environment across the `sudo`
  boundary.  Previously default Debian sudoers' `env_reset`
  stripped everything except `PATH`, so any variable set in
  the container -- including vars passed via `docker_args
  -e` and swarm-owned vars like `AGENT_ID`, `SWARM_MODEL`,
  and `MAX_IDLE` -- was silently dropped before `setup.sh`
  saw it.  Combined with docker's `-e VAR` inheritance form
  (no `=value` inherits from the caller's env, omits when
  unset), a single swarmfile can now be parameterized from
  host env at launch time: `"docker_args": ["-e",
  "TARGET_REPO"]` paired with `TARGET_REPO=...
  ./launch.sh start`.

## 0.20.0 — 2026-04-17

- **Optional SSH commit signing.** New `git_user.signing_key`
  field accepts a host-side path (literal, `$VAR`, or `~/...`)
  to an SSH private key.  When set, the key is bind-mounted
  read-only into each agent and post-processor container at
  `/etc/swarm/signing_key` and git is configured with
  `gpg.format=ssh`, `user.signingkey=/etc/swarm/signing_key`,
  and `commit.gpgsign=true`.  When absent -- or when the field
  resolves to empty via an unset `$VAR` -- signing is
  explicitly disabled inside the container to prevent a host
  signing config from leaking in.  `openssh-client` is now
  installed in the container image for the `ssh-keygen -Y
  sign` that git invokes.  Signing config is factored into
  `lib/signing.sh` and shared between `lib/harness.sh` and the
  harness test, so the production path and the regression
  test exercise the same code.
- **Per-post-processor `max_idle`.** `post_process.max_idle`
  controls the idle-session threshold for the post-processor
  independently of the top-level agent-facing `max_idle`.
  Falls back to the top-level value when omitted, preserving
  the prior behaviour for configs that don't set it.

## 0.19.2 — 2026-04-16

- **No more blank `Think:` lines on Opus 4.7.** The activity
  filter (both `lib/activity-filter.sh` and the driver's
  `agent_activity_jq`) now renders `Think: [encrypted]` when
  the `thinking` field is empty but `signature` is present
  (the expected Opus 4.7 `display: "omitted"` payload where
  the full reasoning ships encrypted server-side) and
  `Think: [empty]` when both are empty — so anomalous blocks
  are distinguishable from the expected encrypted-reasoning
  case. Opus 4.6 and earlier still render their summary
  text unchanged.
- **Forward-compatible `showThinkingSummaries` opt-in.** The
  claude-code driver's `.claude/settings.local.json` now
  includes `"showThinkingSummaries": true`. On Claude Code
  ≤ 2.1.111 this is a no-op on Opus 4.7 headless mode: the
  CLI does not yet plumb the setting through to an explicit
  `thinking.display: "summarized"` on the Messages API
  request, so the API keeps returning empty thinking. The
  opt-in is left in place so that a future Claude Code
  release which wires the setting through will restore
  summaries with no further swarm change. See
  https://docs.anthropic.com/en/about-claude/models/whats-new-claude-4-7
  and https://news.ycombinator.com/item?id=47664442.

## 0.19.1 — 2026-04-13

- **Retry on API 500 errors.** Claude Code driver now treats
  `api_error`, `internal_error`, and HTTP 500 responses as
  retriable, preventing agents from exiting on transient
  Anthropic outages.
- **Dashboard max-effort label.** `format_model` now displays
  `(M)` for `effort: "max"` instead of `(m)`, disambiguating
  it from medium.
- **Remove setup.sh wizard.** Deleted the interactive `setup.sh`
  and its tests. Copying a config from `tests/configs/` and
  editing is simpler and better documented. Not treated as a
  breaking change (would warrant 0.20.0) because no known
  users rely on it.
- **Weekly CI schedule.** CI now runs on a Monday morning cron
  (`0 7 * * 1`) in addition to push/PR triggers.

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
