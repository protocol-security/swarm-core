#!/bin/bash
# Shared helpers for driver implementations.
#
# Drivers that emit the standard JSONL format (with a "result" line
# containing usage stats) can delegate agent_extract_stats to
# _extract_jsonl_stats rather than reimplementing the same parsing.
#
# Drivers that shell out to an external CLI and pipe its stdout to
# the activity-filter pipeline MUST use _run_reaped to execute the
# CLI (see below for why).
#
# Usage in a driver file:
#   source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
#   agent_extract_stats() { _extract_jsonl_stats "$1"; }
#   agent_run() { _run_reaped "$logfile" cli --arg ... "$prompt"; }

# Activity watchdog for _run_reaped.
#
# Polls <logfile>'s mtime every $SWARM_ACTIVITY_POLL seconds
# (default 10).  If it hasn't advanced for <timeout> seconds while
# the CLI is still alive, SIGTERM the CLI's process group; if the
# group doesn't exit within $SWARM_WATCHDOG_GRACE seconds (default
# 10) SIGKILL it.  This catches the case `_run_reaped` alone
# cannot: the CLI itself is alive but deadlocked internally
# (inside a model request, a long-running MCP tool, or an I/O
# wait), so `wait "$_cmd_pid"` never returns and the post-wait
# group-kill never runs.  Without this, the harness sits on the
# `| tee` pipe indefinitely and only an external `docker stop`
# recovers the container.
#
# Activated only when $SWARM_ACTIVITY_TIMEOUT is a positive
# integer; 0 (the default) disables the watchdog, preserving the
# pre-0.20.5 behaviour for operators who haven't opted in.  The
# two tunables ($SWARM_ACTIVITY_POLL, $SWARM_WATCHDOG_GRACE) are
# defaulted to production-sensible values; tests override them to
# keep the behavioural suite under a few seconds.
#
# The mtime probe uses GNU `stat -c %Y` with a BSD `stat -f %m`
# fallback so the helper is runnable on stock macOS CI runners
# too, even though it only meaningfully fires inside the Linux
# production container.
#
# Args: <logfile> <cmd_pid> <timeout_seconds>
_reap_watchdog() {
    local _logfile="$1" _cmd_pid="$2" _timeout="$3"
    local _poll="${SWARM_ACTIVITY_POLL:-10}"
    local _grace="${SWARM_WATCHDOG_GRACE:-10}"
    if ! [[ "$_poll" =~ ^[0-9]+$ ]]  || [ "$_poll"  -lt 1 ]; then _poll=10;  fi
    if ! [[ "$_grace" =~ ^[0-9]+$ ]] || [ "$_grace" -lt 1 ]; then _grace=10; fi

    local _last_mtime _mtime _now _last_activity _i
    _last_activity=$(date +%s)
    # Seed _last_mtime from the current logfile so the first tick
    # can detect staleness immediately.  If stat fails (logfile
    # not yet created by tee) we fall through to 0, which the
    # first advance will overwrite.
    _last_mtime=$(stat -c %Y "$_logfile" 2>/dev/null \
        || stat -f %m "$_logfile" 2>/dev/null \
        || echo 0)

    while kill -0 "$_cmd_pid" 2>/dev/null; do
        sleep "$_poll"
        _mtime=$(stat -c %Y "$_logfile" 2>/dev/null \
            || stat -f %m "$_logfile" 2>/dev/null \
            || echo 0)
        if [ "$_mtime" -gt "$_last_mtime" ]; then
            _last_mtime="$_mtime"
            _last_activity=$(date +%s)
            continue
        fi
        _now=$(date +%s)
        if [ $((_now - _last_activity)) -ge "$_timeout" ]; then
            printf '[swarm watchdog] no log activity for %ss, ' \
                "$((_now - _last_activity))" >&2
            printf 'killing pgrp %s (SIGTERM -> %ss -> SIGKILL)\n' \
                "$_cmd_pid" "$_grace" >&2
            kill -TERM -- "-$_cmd_pid" 2>/dev/null || true
            # Poll for the group to die; exit early if SIGTERM
            # was honoured (the common case -- bash's default
            # SIGTERM handler exits), otherwise fall through to
            # SIGKILL after $_grace seconds.
            for _i in $(seq 1 "$_grace"); do
                kill -0 "$_cmd_pid" 2>/dev/null || return
                sleep 1
            done
            kill -KILL -- "-$_cmd_pid" 2>/dev/null || true
            return
        fi
    done
}

# Run an external CLI in its own process group, tee its stdout to
# <logfile>, redirect its stderr to <logfile>.err, and propagate its
# exit code.  After the CLI's main process exits, SIGKILL the entire
# process group so any surviving descendants release their FDs.
#
# Args: <logfile> <cmd> [args...]
#
# WHY PROCESS GROUPS:
#   Agent CLIs (codex, claude, gemini) commonly spawn helper
#   subprocesses -- MCP servers, subagents, reasoning workers, IPC
#   brokers -- that inherit the parent's stdout.  When the CLI's
#   main process exits without waiting for those children, the
#   children keep the pipe to `tee` open, `tee` never sees EOF, and
#   the entire downstream `| /activity-filter.sh` pipeline wedges
#   indefinitely.  The harness blocks on the pipe and no progress
#   is made until the container is externally killed.
#
#   `setsid` gives the CLI a fresh session/process group (pgid =
#   cmd_pid), so every descendant it forks inherits that pgid.
#   After `wait` returns, `kill -KILL -- -$cmd_pid` signals the
#   entire group, forcing any lingering descendant to exit and
#   release its pipe FD.  The downstream pipeline then observes
#   EOF and drains cleanly.
#
# WHY AN ACTIVITY WATCHDOG:
#   The process-group kill only fires after `wait "$_cmd_pid"`
#   returns.  If the CLI itself is alive but deadlocked (long-
#   running MCP tool, stuck model request, blocked I/O), `wait`
#   blocks forever and the group-kill never runs -- empirically
#   observed as "silence for 4h22m until external docker stop"
#   on codex-cli swarms.  Setting SWARM_ACTIVITY_TIMEOUT to a
#   positive integer enables `_reap_watchdog` above, which
#   SIGTERMs the CLI's process group after that many seconds of
#   logfile staleness and falls through to SIGKILL after another
#   10 seconds.  Default 0 (disabled); 300-600 is a good starting
#   point for production codex-cli / claude-code swarms.
#
# EXIT STATUS:
#   Returns the CLI's wait-reported exit code (128+N for signalled
#   exits), preserved across the tee pipe via PIPESTATUS.
#
# PORTABILITY:
#   `stdbuf` and `setsid` are GNU utilities (coreutils / util-linux).
#   They're always present on the production target (the
#   debian:bookworm-slim container), but stock macOS ships neither.
#   To keep unit tests runnable on non-Linux CI runners we degrade
#   gracefully when either is absent:
#     - no stdbuf -> bare `tee` (same fallback `fake.sh` uses);
#     - no setsid -> run the command in-line and skip the group kill.
#   The setsid fallback effectively disables the zombie-reaping
#   protection, but that protection only matters inside the
#   production container where setsid is always available.
_run_reaped() {
    local logfile="$1"; shift

    local _tee_cmd=(tee "$logfile")
    if command -v stdbuf >/dev/null 2>&1; then
        _tee_cmd=(stdbuf -oL tee "$logfile")
    fi

    if ! command -v setsid >/dev/null 2>&1; then
        "$@" 2>"${logfile}.err" | "${_tee_cmd[@]}"
        return "${PIPESTATUS[0]}"
    fi

    # Normalise the activity-timeout knob: strict positive integer
    # enables the watchdog, anything else (unset, 0, non-numeric)
    # disables it.  Defensive regex because the value comes from
    # the environment and a typo shouldn't crash every session.
    local _wd_timeout="${SWARM_ACTIVITY_TIMEOUT:-0}"
    if ! [[ "$_wd_timeout" =~ ^[0-9]+$ ]]; then
        _wd_timeout=0
    fi

    {
        setsid "$@" 2>"${logfile}.err" &
        local _cmd_pid=$!
        local _wd_pid=""
        if [ "$_wd_timeout" -gt 0 ]; then
            # Route watchdog diagnostics into the CLI's stderr
            # file so operators inspecting <logfile>.err can tell
            # a watchdog-killed exit from a crashed-on-its-own
            # exit after the fact.  Without this tee-side stderr
            # gets swallowed if the caller redirected it.
            _reap_watchdog "$logfile" "$_cmd_pid" "$_wd_timeout" \
                2>>"${logfile}.err" &
            _wd_pid=$!
        fi
        # `wait || _ec=$?` keeps set -e from firing on a non-zero
        # CLI exit, which would terminate the subshell before the
        # group kill below runs and leave surviving descendants
        # holding the tee pipe open (empirically observed on
        # exit-42 in unit tests).
        local _ec=0
        wait "$_cmd_pid" || _ec=$?
        # Group kill: -$_cmd_pid targets the process group whose
        # leader is the setsid'd command.  Swallow errors -- an
        # already-empty group is fine.
        kill -KILL -- "-$_cmd_pid" 2>/dev/null || true
        # Tear down the watchdog (if one was started) so it doesn't
        # keep polling a dead pid for up to its 10s sleep window.
        if [ -n "$_wd_pid" ]; then
            kill "$_wd_pid" 2>/dev/null || true
            wait "$_wd_pid" 2>/dev/null || true
        fi
        exit "$_ec"
    } | "${_tee_cmd[@]}"
    return "${PIPESTATUS[0]}"
}

# Extract stats from a JSONL log containing a "result" line.
# Falls back to treating the entire file as a single JSON object.
# Prints: cost\ttok_in\ttok_out\tcache_rd\tcache_cr\tdur\tapi_ms\tturns
_extract_jsonl_stats() {
    local logfile="$1"
    local RESULT_LINE
    RESULT_LINE=$(grep '"type"[[:space:]]*:[[:space:]]*"result"' "$logfile" 2>/dev/null | tail -1 || true)
    if [ -z "$RESULT_LINE" ]; then
        RESULT_LINE=$(cat "$logfile" 2>/dev/null || true)
    fi
    local cost dur api_ms turns tok_in tok_out cache_rd cache_cr
    cost=$(echo "$RESULT_LINE" | jq -r '.total_cost_usd // 0' 2>/dev/null || true)
    cost="${cost:-0}"
    dur=$(echo "$RESULT_LINE" | jq -r '.duration_ms // 0' 2>/dev/null || true)
    dur="${dur:-0}"
    api_ms=$(echo "$RESULT_LINE" | jq -r '.duration_api_ms // 0' 2>/dev/null || true)
    api_ms="${api_ms:-0}"
    turns=$(echo "$RESULT_LINE" | jq -r '.num_turns // 0' 2>/dev/null || true)
    turns="${turns:-0}"
    tok_in=$(echo "$RESULT_LINE" | jq -r '.usage.input_tokens // 0' 2>/dev/null || true)
    tok_in="${tok_in:-0}"
    tok_out=$(echo "$RESULT_LINE" | jq -r '.usage.output_tokens // 0' 2>/dev/null || true)
    tok_out="${tok_out:-0}"
    cache_rd=$(echo "$RESULT_LINE" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || true)
    cache_rd="${cache_rd:-0}"
    cache_cr=$(echo "$RESULT_LINE" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || true)
    cache_cr="${cache_cr:-0}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "$cost" "$tok_in" "$tok_out" "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns"
}
