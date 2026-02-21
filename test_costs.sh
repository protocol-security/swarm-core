#!/bin/bash
set -euo pipefail

# Unit tests for costs.sh aggregation and formatting logic.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

# --- Helpers: same awk/logic used in costs.sh ---

aggregate_stats() {
    local tsv_file="$1"
    if [ ! -s "$tsv_file" ]; then
        echo "0 0 0 0 0 0 0"
        return
    fi
    awk -F'\t' '{
        cost += $2; tok_in += $3; tok_out += $4;
        cache += $5; dur += $7; turns += $9; sessions++
    } END {
        printf "%s %d %d %d %d %d %d\n",
            cost, tok_in, tok_out, cache, dur, turns, sessions
    }' "$tsv_file"
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

# ============================================================
echo "=== 1. Single-session TSV aggregation ==="

printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "1700000000" "0.1292" "800" "644" "117000" "5000" "19000" "15000" "6" \
    > "$TMPDIR/single.tsv"

STATS=$(aggregate_stats "$TMPDIR/single.tsv")
read -r cost tok_in tok_out cache dur turns sessions <<< "$STATS"

assert_eq "cost"     "0.1292" "$cost"
assert_eq "tok_in"   "800"    "$tok_in"
assert_eq "tok_out"  "644"    "$tok_out"
assert_eq "cache"    "117000" "$cache"
assert_eq "dur"      "19000"  "$dur"
assert_eq "turns"    "6"      "$turns"
assert_eq "sessions" "1"      "$sessions"

# ============================================================
echo ""
echo "=== 2. Multi-session TSV aggregation ==="

cat > "$TMPDIR/multi.tsv" <<'EOF'
1700000000	0.1292	800	644	117000	5000	19000	15000	6
1700000100	0.0500	400	300	50000	2000	10000	8000	3
1700000200	0.2000	1200	900	200000	8000	30000	25000	10
EOF

STATS=$(aggregate_stats "$TMPDIR/multi.tsv")
read -r cost tok_in tok_out cache dur turns sessions <<< "$STATS"

assert_eq "total cost"     "0.3792"  "$cost"
assert_eq "total tok_in"   "2400"    "$tok_in"
assert_eq "total tok_out"  "1844"    "$tok_out"
assert_eq "total cache"    "367000"  "$cache"
assert_eq "total dur"      "59000"   "$dur"
assert_eq "total turns"    "19"      "$turns"
assert_eq "total sessions" "3"       "$sessions"

# ============================================================
echo ""
echo "=== 3. Empty TSV ==="

: > "$TMPDIR/empty.tsv"
STATS=$(aggregate_stats "$TMPDIR/empty.tsv")
read -r cost tok_in tok_out cache dur turns sessions <<< "$STATS"

assert_eq "empty cost"     "0" "$cost"
assert_eq "empty sessions" "0" "$sessions"

# ============================================================
echo ""
echo "=== 4. JSON agent ID quoting ==="

quote_id() {
    local agent_id="$1"
    if ! [[ "$agent_id" =~ ^[0-9]+$ ]]; then
        echo "\"${agent_id}\""
    else
        echo "${agent_id}"
    fi
}

assert_eq "numeric 1"     "1"        "$(quote_id "1")"
assert_eq "numeric 42"    "42"       "$(quote_id "42")"
assert_eq "string post"   '"post"'   "$(quote_id "post")"
assert_eq "string mixed"  '"a1b"'    "$(quote_id "a1b")"

# ============================================================
echo ""
echo "=== 5. Total cost leading zero ==="

format_total_cost() {
    printf '%.6f' "$1"
}

assert_eq "leading zero"   "0.496874" "$(format_total_cost ".496874")"
assert_eq "already zero"   "0.123456" "$(format_total_cost "0.123456")"
assert_eq "whole number"   "1.000000" "$(format_total_cost "1")"
assert_eq "zero"           "0.000000" "$(format_total_cost "0")"

# ============================================================
echo ""
echo "=== 6. format_tokens (costs.sh copy) ==="

assert_eq "zero"   "0"     "$(format_tokens 0)"
assert_eq "small"  "500"   "$(format_tokens 500)"
assert_eq "kilo"   "15k"   "$(format_tokens 15000)"
assert_eq "mega"   "1.5M"  "$(format_tokens 1500000)"

# ============================================================
echo ""
echo "=== 7. Duration seconds calculation ==="

dur_ms=65432
dur_s=$((dur_ms / 1000))
assert_eq "ms to seconds" "65" "$dur_s"

dur_ms=0
dur_s=$((dur_ms / 1000))
assert_eq "zero ms" "0" "$dur_s"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
