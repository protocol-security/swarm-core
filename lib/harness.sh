#!/bin/bash
set -euo pipefail

# Container entrypoint: clone, setup, loop agent sessions.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Container entrypoint for swarm agents. Not intended to be run
directly -- launched automatically inside Docker by launch.sh.

Clones the bare repo, runs optional setup, then loops agent
sessions until the agent is idle for MAX_IDLE cycles.

Required environment:
  SWARM_PROMPT   Path to prompt file (relative to repo root).

Optional environment:
  SWARM_MODEL    Model (default: driver's default model).
  AGENT_ID       Agent identifier (default: unnamed).
  SWARM_DRIVER   Agent driver (default: claude-code).
  SWARM_SETUP    Setup script to run before first session.
  MAX_IDLE       Idle sessions before exit (default: 3).
  MAX_RETRY_WAIT Max seconds to retry on fatal errors (default: 0 = no retry).
  INJECT_GIT_RULES  Inject git coordination rules (default: true).
  SWARM_CONTEXT  Context mode: full (default), slim, or none.
HELP
    exit 0
fi

AGENT_ID="${AGENT_ID:-unnamed}"
SWARM_PROMPT="${SWARM_PROMPT:?SWARM_PROMPT is required.}"
SWARM_SETUP="${SWARM_SETUP:-}"
MAX_IDLE="${MAX_IDLE:-3}"
MAX_RETRY_WAIT="${MAX_RETRY_WAIT:-0}"
INJECT_GIT_RULES="${INJECT_GIT_RULES:-true}"
SWARM_CONTEXT="${SWARM_CONTEXT:-full}"
SWARM_DRIVER="${SWARM_DRIVER:-claude-code}"
STATS_FILE="agent_logs/stats_agent_${AGENT_ID}.tsv"

# Load the agent driver.
DRIVER_FILE="/drivers/${SWARM_DRIVER}.sh"
if [ ! -f "$DRIVER_FILE" ]; then
    echo "ERROR: driver not found: ${DRIVER_FILE}" >&2
    exit 1
fi
# shellcheck source=drivers/claude-code.sh
source "$DRIVER_FILE"

# Validate the driver implements all required interface functions.
_required_fns=(agent_default_model agent_name agent_cmd agent_version
               agent_run agent_settings agent_extract_stats
               agent_activity_jq agent_docker_auth)
for _fn in "${_required_fns[@]}"; do
    if ! type -t "$_fn" &>/dev/null; then
        echo "ERROR: driver '${SWARM_DRIVER}' missing required function: ${_fn}" >&2
        exit 1
    fi
done
unset _required_fns _fn

# Resolve model: explicit env > driver default.
SWARM_MODEL="${SWARM_MODEL:-$(agent_default_model)}"

# Backward compat: export CLAUDE_MODEL so existing hooks and
# dashboard env-parsing still work.
export CLAUDE_MODEL="${SWARM_MODEL}"

GREEN=$'\033[32m'
RED=$'\033[31m'
RST=$'\033[0m'

hlog() {
    printf '%s%s harness[%s] %s%s\n' \
        "$GREEN" "$(date +%H:%M:%S)" "$AGENT_ID" "$*" "$RST"
}

hlog_err() {
    printf '%s%s harness[%s] %s%s\n' \
        "$RED" "$(date +%H:%M:%S)" "$AGENT_ID" "$*" "$RST"
}

hlog_pipe() {
    while IFS= read -r line; do
        printf '%s%s harness[%s] %s%s\n' \
            "$GREEN" "$(date +%H:%M:%S)" "$AGENT_ID" "$line" "$RST"
    done
}

GIT_USER_NAME="${GIT_USER_NAME:-swarm-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@swarm.local}"
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
# shellcheck source=signing.sh
source /signing.sh
configure_git_signing

# Capture CLI version once for the prepare-commit-msg hook.
AGENT_CLI_VERSION=$(agent_version)
export AGENT_CLI_VERSION
export AGENT_CLI_NAME
AGENT_CLI_NAME=$(agent_name)
export SWARM_RUN_CONTEXT="${SWARM_RUN_CONTEXT:-unknown}"
export SWARM_CFG_PROMPT="${SWARM_CFG_PROMPT:-${SWARM_PROMPT}}"
export SWARM_CFG_SETUP="${SWARM_CFG_SETUP:-${SWARM_SETUP}}"

hlog "starting driver=${SWARM_DRIVER} model=${SWARM_MODEL} prompt=${SWARM_PROMPT} context=${SWARM_CONTEXT}"

# Write the driver's activity jq filter to a file so the
# activity-filter.sh subprocess (piped from agent_run) can read it.
# This bridges the process boundary: the driver is sourced here but
# activity-filter.sh runs as a separate process.
SWARM_JQ_FILTER_FILE=$(mktemp /tmp/swarm-jq-XXXXXX.jq)
agent_activity_jq > "$SWARM_JQ_FILTER_FILE"
export SWARM_JQ_FILTER_FILE

if [ ! -d "/workspace/.git" ]; then
    hlog "cloning upstream"
    git clone -q /upstream /workspace
    cd /workspace

    # Init only submodules whose mirrors were mounted into the
    # container. Client submodules without mirrors keep their
    # upstream URLs and are left for the agent to init on demand.
    if [ -f .gitmodules ]; then
        git config --file .gitmodules --get-regexp 'submodule\..*\.path' | \
        while read -r key path; do
            name="${key#submodule.}"
            name="${name%.path}"
            if [ -d "/mirrors/${name}" ]; then
                git config "submodule.${name}.url" "/mirrors/${name}"
                git submodule update --init -q -- "$path"
            fi
        done
    fi

    git checkout -q agent-work

    # Strip .claude context per the context mode setting.
    # See: "Evaluating AGENTS.md" (arXiv:2602.11988) for motivation.
    if [ -d .claude ]; then
        case "$SWARM_CONTEXT" in
            none)
                hlog "context=none: removing .claude/"
                rm -rf .claude
                ;;
            slim)
                hlog "context=slim: keeping only .claude/CLAUDE.md"
                find .claude -mindepth 1 -maxdepth 1 ! -name CLAUDE.md \
                    -exec rm -rf {} +
                ;;
        esac
    fi

    # Install git hooks that re-strip context after pulls/checkouts.
    # Without these, `git pull --rebase` restores the stripped files.
    # Claude Code respects context internally, but other drivers
    # (Codex, Gemini) see the raw filesystem.
    if [ "$SWARM_CONTEXT" != "full" ]; then
        cat > .git/hooks/_strip_context <<CTXHOOK
#!/bin/bash
case "$SWARM_CONTEXT" in
    none) rm -rf .claude 2>/dev/null ;;
    slim) [ -d .claude ] && find .claude -mindepth 1 -maxdepth 1 ! -name CLAUDE.md -exec rm -rf {} + 2>/dev/null ;;
esac
CTXHOOK
        chmod +x .git/hooks/_strip_context
        for _hook in post-merge post-checkout; do
            printf '#!/bin/bash\n.git/hooks/_strip_context\n' \
                > ".git/hooks/$_hook"
            chmod +x ".git/hooks/$_hook"
        done
    fi

    # Run project-specific setup if provided.
    if [ -n "$SWARM_SETUP" ] && [ -f "$SWARM_SETUP" ]; then
        hlog "running setup ${SWARM_SETUP}"
        sudo -E bash "$SWARM_SETUP"
        # Setup runs as root; reclaim ownership so the agent user
        # (and git reset on restart) can modify all workspace files.
        sudo chown -R "$(id -u):$(id -g)" /workspace
    fi

    # Write agent-specific settings (e.g. Claude Code disables its
    # Co-Authored-By trailer, attribution header, and telemetry).
    agent_settings /workspace

    # Install prepare-commit-msg hook to append provenance trailers.
    # Fires on every commit including git commit -m.
    SWARM_VERSION=$(cat /swarm-version 2>/dev/null || echo "unknown")
    export SWARM_VERSION
    mkdir -p .git/hooks
    cat > .git/hooks/prepare-commit-msg <<'HOOK'
#!/bin/bash
if ! grep -q '^Model:' "$1"; then
    printf '\nModel: %s\nTools: swarm %s, %s %s\n' \
        "$SWARM_MODEL" "$SWARM_VERSION" "$AGENT_CLI_NAME" "$AGENT_CLI_VERSION" >> "$1"
    printf '> Run: %s\n' "$SWARM_RUN_CONTEXT" >> "$1"
    cfg="$SWARM_CFG_PROMPT"
    [ -n "$SWARM_CFG_SETUP" ] && cfg="${cfg}, ${SWARM_CFG_SETUP}"
    printf '> Cfg: %s\n' "$cfg" >> "$1"
    ctx_label="$SWARM_CONTEXT"
    [ "$ctx_label" = "none" ] && ctx_label="bare"
    [ "$SWARM_CONTEXT" != "full" ] && \
        printf '> Ctx: %s\n' "$ctx_label" >> "$1" || true
fi
HOOK
    chmod +x .git/hooks/prepare-commit-msg

    # post-rewrite hook: re-inject trailers lost during rebase/amend.
    # Not affected by --no-verify, so acts as a safety net.
    cat > .git/hooks/post-rewrite <<'HOOK'
#!/bin/bash
# Amend HEAD if provenance trailers were lost during rebase/amend.
msg=$(git log -1 --format='%B' HEAD 2>/dev/null) || exit 0
if printf '%s' "$msg" | grep -q '^Model:'; then
    exit 0
fi
trailer=$(printf '\nModel: %s\nTools: swarm %s, %s %s\n' \
    "$SWARM_MODEL" "$SWARM_VERSION" "$AGENT_CLI_NAME" "$AGENT_CLI_VERSION")
trailer+=$(printf '> Run: %s\n' "$SWARM_RUN_CONTEXT")
cfg="$SWARM_CFG_PROMPT"
[ -n "$SWARM_CFG_SETUP" ] && cfg="${cfg}, ${SWARM_CFG_SETUP}"
trailer+=$(printf '> Cfg: %s\n' "$cfg")
ctx_label="$SWARM_CONTEXT"
[ "$ctx_label" = "none" ] && ctx_label="bare"
[ "$SWARM_CONTEXT" != "full" ] && \
    trailer+=$(printf '> Ctx: %s\n' "$ctx_label") || true
git commit --amend --no-verify --no-edit -m "${msg}${trailer}" \
    --allow-empty >/dev/null 2>&1 || true
# Re-strip .claude context after rebase (covers git pull --rebase).
[ -x .git/hooks/_strip_context ] && .git/hooks/_strip_context
HOOK
    chmod +x .git/hooks/post-rewrite

    # pre-commit hook: prevent accidental staging of internal files
    # and submodule pointer changes from broad `git add`.
    cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/bash
# Unstage internal harness/agent files that should never be committed.
git reset -q HEAD -- agent_logs/ .claude/settings.local.json 2>/dev/null || true

# Silently unstage submodule pointer changes so agents can't
# accidentally commit a submodule bump via broad `git add`.
changed_subs=$(git diff --cached --diff-filter=M --name-only | while read -r path; do
    if git ls-tree HEAD -- "$path" 2>/dev/null | grep -q '^160000 '; then
        echo "$path"
    fi
done)
if [ -n "$changed_subs" ]; then
    echo "$changed_subs" | while read -r sub; do
        git reset -q HEAD -- "$sub" 2>/dev/null || true
    done
fi
HOOK
    chmod +x .git/hooks/pre-commit

    mkdir -p agent_logs
    hlog "setup complete"
fi

cd /workspace
STATS_FILE="/workspace/${STATS_FILE}"

IDLE_COUNT=0
IDLE_FILE="/workspace/agent_logs/idle_agent_${AGENT_ID}"
RETRY_FILE="/workspace/agent_logs/retry_agent_${AGENT_ID}"
rm -f "$RETRY_FILE"

while true; do
    # Reset to latest. Do not re-init submodules; setup changes would be lost.
    git fetch --no-recurse-submodules origin 2>&1 | hlog_pipe
    git reset --hard origin/agent-work 2>&1 | hlog_pipe

    BEFORE=$(git rev-parse origin/agent-work)
    COMMIT=$(git rev-parse --short=6 HEAD)
    LOGFILE="agent_logs/agent_${AGENT_ID}_${COMMIT}_$(date +%s).log"
    mkdir -p agent_logs

    hlog "session start at=${COMMIT}"

    if [ ! -f "$SWARM_PROMPT" ]; then
        hlog_err "prompt file not found: ${SWARM_PROMPT}, skipping"
        sleep 2
        continue
    fi

    APPEND_FILE=""
    if [ "$INJECT_GIT_RULES" = "true" ] && [ -f /agent-system-prompt.md ]; then
        APPEND_FILE="/agent-system-prompt.md"
    fi

    AGENT_RUN_EXIT=0
    _run_start=$SECONDS
    agent_run "$SWARM_MODEL" "$(cat "$SWARM_PROMPT")" "$LOGFILE" "$APPEND_FILE" \
        | /activity-filter.sh || AGENT_RUN_EXIT=$?
    _run_elapsed_ms=$(( (SECONDS - _run_start) * 1000 ))

    # Extract usage stats via the driver.
    STATS_LINE=$(agent_extract_stats "$LOGFILE")
    IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS_LINE"
    cost="${cost:-0}"; tok_in="${tok_in:-0}"; tok_out="${tok_out:-0}"
    cache_rd="${cache_rd:-0}"; cache_cr="${cache_cr:-0}"
    dur="${dur:-0}"; api_ms="${api_ms:-0}"; turns="${turns:-0}"
    # Fall back to wall-clock time when the driver has no native timing.
    [ "${dur:-0}" = "0" ] && dur="$_run_elapsed_ms"
    [ "${api_ms:-0}" = "0" ] && api_ms="$_run_elapsed_ms"

    # Compute cost from token counts when the driver doesn't report
    # it natively (e.g. Gemini CLI).  Pricing is $/M tokens, passed
    # via env vars from launch.sh (sourced from config "pricing" map).
    if [ -n "${SWARM_PRICE_INPUT:-}" ]; then
        cost=$(awk "BEGIN {printf \"%.6f\",
            (${tok_in} * ${SWARM_PRICE_INPUT} + ${tok_out} * ${SWARM_PRICE_OUTPUT:-0} + ${cache_rd} * ${SWARM_PRICE_CACHED:-0}) / 1000000}")
    fi

    mkdir -p "$(dirname "$STATS_FILE")"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
        "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns" \
        >> "$STATS_FILE"
    hlog "session end cost=\$${cost} in=${tok_in} out=${tok_out} turns=${turns} time=${dur}ms"

    # Ask the driver to detect fatal errors (model not found, auth
    # failure, etc.).  The driver inspects its own log format.
    FATAL_MSG=""
    if type -t agent_detect_fatal &>/dev/null; then
        FATAL_MSG=$(agent_detect_fatal "$LOGFILE" "$AGENT_RUN_EXIT")
    fi
    # Generic fallback: a non-zero exit with zero tokens is fatal
    # when retry is disabled.  When retry is enabled, treat it as
    # potentially transient (network error, temporary outage) so
    # the backoff loop gets a chance to recover.
    _zero_token_fatal=false
    if [ -z "$FATAL_MSG" ] && [ "$AGENT_RUN_EXIT" -ne 0 ] \
            && [ "$tok_in" = "0" ] && [ "$tok_out" = "0" ]; then
        FATAL_MSG="agent exited with code ${AGENT_RUN_EXIT} and produced no tokens"
        _zero_token_fatal=true
    fi
    if [ -n "$FATAL_MSG" ]; then
        _retriable=""
        if [ "$MAX_RETRY_WAIT" -gt 0 ]; then
            if type -t agent_is_retriable &>/dev/null; then
                _retriable=$(agent_is_retriable "$LOGFILE" "$AGENT_RUN_EXIT" || true)
            fi
            # Zero-token exits are often transient (network loss,
            # DNS failure, temporary outage).  Allow retry.
            if [ -z "$_retriable" ] && [ "$_zero_token_fatal" = true ]; then
                _retriable="zero_tokens"
            fi
        fi
        if [ -n "$_retriable" ] && [ "$MAX_RETRY_WAIT" -gt 0 ]; then
            _backoff=30; _total_waited=0
            while [ "$_total_waited" -lt "$MAX_RETRY_WAIT" ]; do
                hlog_err "retriable error: ${FATAL_MSG}"
                hlog "retrying in ${_backoff}s (waited ${_total_waited}/${MAX_RETRY_WAIT}s)"
                printf '%s/%s\n' "$_total_waited" "$MAX_RETRY_WAIT" > "$RETRY_FILE"
                sleep "$_backoff"
                _total_waited=$((_total_waited + _backoff))
                _backoff=$((_backoff * 2))
                if [ "$_backoff" -gt 1800 ]; then
                    _backoff=1800
                fi
                hlog "retry: starting session"
                rm -f "$RETRY_FILE"
                AGENT_RUN_EXIT=0
                _run_start=$SECONDS
                agent_run "$SWARM_MODEL" "$(cat "$SWARM_PROMPT")" "$LOGFILE" "$APPEND_FILE" \
                    | /activity-filter.sh || AGENT_RUN_EXIT=$?
                _run_elapsed_ms=$(( (SECONDS - _run_start) * 1000 ))
                STATS_LINE=$(agent_extract_stats "$LOGFILE")
                IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS_LINE"
                cost="${cost:-0}"; tok_in="${tok_in:-0}"; tok_out="${tok_out:-0}"
                cache_rd="${cache_rd:-0}"; cache_cr="${cache_cr:-0}"
                dur="${dur:-0}"; api_ms="${api_ms:-0}"; turns="${turns:-0}"
                [ "${dur:-0}" = "0" ] && dur="$_run_elapsed_ms"
                [ "${api_ms:-0}" = "0" ] && api_ms="$_run_elapsed_ms"
                if [ -n "${SWARM_PRICE_INPUT:-}" ]; then
                    cost=$(awk "BEGIN {printf \"%.6f\",
                        (${tok_in} * ${SWARM_PRICE_INPUT} + ${tok_out} * ${SWARM_PRICE_OUTPUT:-0} + ${cache_rd} * ${SWARM_PRICE_CACHED:-0}) / 1000000}")
                fi
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                    "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
                    "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns" \
                    >> "$STATS_FILE"
                FATAL_MSG=""
                if type -t agent_detect_fatal &>/dev/null; then
                    FATAL_MSG=$(agent_detect_fatal "$LOGFILE" "$AGENT_RUN_EXIT")
                fi
                if [ -z "$FATAL_MSG" ]; then
                    hlog "retry: session succeeded"
                    rm -f "$RETRY_FILE"
                    break
                fi
                _retriable=$(agent_is_retriable "$LOGFILE" "$AGENT_RUN_EXIT" || true)
                if [ -z "$_retriable" ]; then
                    hlog_err "fatal (non-retriable): ${FATAL_MSG}"
                    hlog_err "exiting due to unrecoverable error"
                    exit 1
                fi
            done
            if [ -n "$FATAL_MSG" ]; then
                hlog_err "fatal: ${FATAL_MSG}"
                hlog_err "retry wait limit reached (${MAX_RETRY_WAIT}s), exiting"
                exit 1
            fi
        else
            hlog_err "fatal: ${FATAL_MSG}"
            hlog_err "exiting due to unrecoverable error"
            exit 1
        fi
    fi

    git fetch --no-recurse-submodules origin 2>&1 | hlog_pipe
    AFTER=$(git rev-parse origin/agent-work)

    # Safety net: if the agent committed locally but failed to
    # push (concurrent lock, transient error), push on its behalf
    # with jittered retries to avoid collisions across containers.
    _local_head=$(git rev-parse HEAD)
    if [ "$_local_head" != "$AFTER" ] \
            && [ "$(git rev-list origin/agent-work..HEAD 2>/dev/null | wc -l)" -gt 0 ]; then
        hlog "found unpushed local commits, pushing"

        # The session-end push rebases local commits onto origin/agent-work.
        # Any dirty state in the working tree -- tracked mods, deletions,
        # untracked scratch files, submodule pointer drift -- has to be
        # cleaned out first or `git pull --rebase` will refuse with
        # "cannot rebase: You have unstaged changes" and the retry loop
        # burns through all three attempts without pushing.
        #
        # v0.20.2 tried to solve this with `rebase.autoStash=true`, but
        # autoStash has three documented gaps that caused real push
        # failures in production (see CHANGELOG 0.20.4 for the
        # failure-mode breakdown):
        #
        #   (1) `git stash` defaults to NOT stashing untracked files, so
        #       autoStash silently leaves `?? <path>` in the worktree and
        #       the rebase refuses anyway.
        #
        #   (2) `git stash` does NOT capture submodule pointer drift
        #       (`M <submodule>`) regardless of flags -- the superproject
        #       gitlink diff is simply not visible to stash's default
        #       traversal.  Agents that run `cargo build`, `git worktree
        #       add`, or anything else that bumps a submodule HEAD trip
        #       this every time.
        #
        #   (3) When autoStash does create a stash, the auto-pop after a
        #       successful rebase is best-effort per git's own docs and
        #       was observed failing mid-rebase on
        #       "skipped previously applied commit" in multi-agent swarms.
        #
        # The fix below sidesteps all three by doing the stash explicitly
        # (with --include-untracked), re-syncing submodule HEADs to what
        # the superproject expects, and running the rebase against a
        # guaranteed-clean tree.  We intentionally do NOT pop the stash:
        # the next loop iteration runs `git reset --hard origin/agent-work`
        # at the top, which would wipe a popped stash anyway, so popping
        # here buys nothing while reintroducing the autoStash-pop conflict
        # class.  The stash stays in reflog (`git stash list`) for
        # forensic recovery if an operator needs to inspect what was
        # in-flight.
        _dirty=$(git status --porcelain=v1 2>/dev/null)
        if [ -n "$_dirty" ]; then
            hlog "dirty worktree before push:"
            printf '%s\n' "$_dirty" | hlog_pipe

            # (a) Stash everything `git stash` can reach -- tracked mods,
            # tracked deletions, staged changes, untracked files.
            # Count-before / count-after is the bulletproof way to
            # detect "nothing was actually stashed" (all of the dirty
            # state was submodule drift, which stash silently ignores).
            _stash_before=$(git stash list 2>/dev/null | wc -l)
            git stash push --include-untracked --quiet \
                -m "claude-swarm pre-push $(date -u +%s)" 2>&1 | hlog_pipe || true
            _stash_after=$(git stash list 2>/dev/null | wc -l)
            if [ "$_stash_after" -gt "$_stash_before" ]; then
                hlog "pre-push stash: $(git rev-parse 'stash@{0}' 2>/dev/null)"
            fi

            # (b) Re-sync submodule HEADs to the superproject's expected
            # gitlink.  This is what clears `M <submodule>` from status
            # -- stash cannot reach it.  --force is safe here because
            # dirty submodule state is ephemeral build output; anything
            # worth preserving should already be in a commit or in the
            # stash above.  `|| true` so a submodule-less repo or a
            # transient network hiccup doesn't abort the push path.
            git submodule update --init --recursive --force 2>&1 | hlog_pipe || true
        fi

        _push_ok=false
        for _try in 1 2 3; do
            sleep $((RANDOM % 5 + 1))
            # Clean up stale rebase state that blocks git pull --rebase.
            if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
                git rebase --abort 2>/dev/null || rm -rf .git/rebase-merge .git/rebase-apply
            fi
            # Bare `git pull --rebase` -- the pre-stash + submodule-sync
            # above guarantees a clean tree, so there is nothing for the
            # rebase to trip on and autoStash is intentionally absent
            # (see the comment block above for why).
            if git pull --rebase origin agent-work 2>&1 | hlog_pipe \
                    && git push origin agent-work 2>&1 | hlog_pipe; then
                _push_ok=true
                break
            fi
            hlog "push retry ${_try}/3"
        done
        if [ "$_push_ok" = true ]; then
            git fetch --no-recurse-submodules origin 2>&1 | hlog_pipe
            AFTER=$(git rev-parse origin/agent-work)
        else
            hlog_err "push failed after 3 retries"
        fi
    fi

    if [ "$BEFORE" = "$AFTER" ]; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        printf '%s/%s\n' "$IDLE_COUNT" "$MAX_IDLE" > "$IDLE_FILE"
        hlog "no commits (idle ${IDLE_COUNT}/${MAX_IDLE})"
        if [ "$IDLE_COUNT" -ge "$MAX_IDLE" ]; then
            hlog "idle limit reached, exiting"
            exit 0
        fi
    else
        IDLE_COUNT=0
        rm -f "$IDLE_FILE"
        hlog "session end, restarting"
    fi
done
