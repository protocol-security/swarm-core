#!/bin/bash
# Shared helpers for driver implementations.
#
# Drivers that emit the standard JSONL format (with a "result" line
# containing usage stats) can delegate agent_extract_stats to
# _extract_jsonl_stats rather than reimplementing the same parsing.
#
# Usage in a driver file:
#   source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
#   agent_extract_stats() { _extract_jsonl_stats "$1"; }

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
