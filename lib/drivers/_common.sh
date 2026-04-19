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

    {
        setsid "$@" 2>"${logfile}.err" &
        local _cmd_pid=$!
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
