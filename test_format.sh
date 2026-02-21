#!/bin/bash
set -euo pipefail

# Unit tests for formatting functions used by dashboard.sh and costs.sh.
# No Docker or API key required.

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

# --- Functions under test (from dashboard.sh / costs.sh) ---

format_duration() {
    local s=$1
    if [ "$s" -ge 3600 ]; then
        printf '%dh %02dm' $((s / 3600)) $(((s % 3600) / 60))
    elif [ "$s" -ge 60 ]; then
        printf '%dm %02ds' $((s / 60)) $((s % 60))
    else
        printf '%ds' "$s"
    fi
}

format_duration_ms() {
    format_duration $(( ${1:-0} / 1000 ))
}

format_tokens() {
    local n=${1:-0}
    if [ "$n" -ge 1000000 ]; then
        printf '%.1fM' "$(echo "$n / 1000000" | bc -l)"
    elif [ "$n" -ge 1000 ]; then
        printf '%.0fk' "$(echo "$n / 1000" | bc -l)"
    else
        printf '%d' "$n"
    fi
}

format_cost() {
    printf '$%.2f' "${1:-0}"
}

# ============================================================
echo "=== 1. format_duration ==="

assert_eq "0 seconds"   "0s"       "$(format_duration 0)"
assert_eq "1 second"    "1s"       "$(format_duration 1)"
assert_eq "59 seconds"  "59s"      "$(format_duration 59)"
assert_eq "60 seconds"  "1m 00s"   "$(format_duration 60)"
assert_eq "61 seconds"  "1m 01s"   "$(format_duration 61)"
assert_eq "125 seconds" "2m 05s"   "$(format_duration 125)"
assert_eq "3599 seconds" "59m 59s" "$(format_duration 3599)"
assert_eq "3600 seconds" "1h 00m"  "$(format_duration 3600)"
assert_eq "3661 seconds" "1h 01m"  "$(format_duration 3661)"
assert_eq "7200 seconds" "2h 00m"  "$(format_duration 7200)"
assert_eq "7384 seconds" "2h 03m"  "$(format_duration 7384)"

# ============================================================
echo ""
echo "=== 2. format_duration_ms ==="

assert_eq "0 ms"      "0s"      "$(format_duration_ms 0)"
assert_eq "500 ms"    "0s"      "$(format_duration_ms 500)"
assert_eq "1000 ms"   "1s"      "$(format_duration_ms 1000)"
assert_eq "5000 ms"   "5s"      "$(format_duration_ms 5000)"
assert_eq "65000 ms"  "1m 05s"  "$(format_duration_ms 65000)"
assert_eq "3600000 ms" "1h 00m" "$(format_duration_ms 3600000)"
assert_eq "empty"     "0s"      "$(format_duration_ms)"

# ============================================================
echo ""
echo "=== 3. format_tokens ==="

assert_eq "0"          "0"     "$(format_tokens 0)"
assert_eq "1"          "1"     "$(format_tokens 1)"
assert_eq "999"        "999"   "$(format_tokens 999)"
assert_eq "1000"       "1k"    "$(format_tokens 1000)"
assert_eq "1500"       "2k"    "$(format_tokens 1500)"
assert_eq "15000"      "15k"   "$(format_tokens 15000)"
assert_eq "999999"     "1000k" "$(format_tokens 999999)"
assert_eq "1000000"    "1.0M"  "$(format_tokens 1000000)"
assert_eq "1500000"    "1.5M"  "$(format_tokens 1500000)"
assert_eq "25000000"   "25.0M" "$(format_tokens 25000000)"
assert_eq "empty"      "0"     "$(format_tokens)"

# ============================================================
echo ""
echo "=== 4. format_cost ==="

assert_eq "zero"       '$0.00'   "$(format_cost 0)"
assert_eq "small"      '$0.13'   "$(format_cost 0.1292)"
assert_eq "round up"   '$0.50'   "$(format_cost 0.499)"
assert_eq "dollar"     '$1.00'   "$(format_cost 1)"
assert_eq "large"      '$12.35'  "$(format_cost 12.345)"
assert_eq "empty"      '$0.00'   "$(format_cost)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
