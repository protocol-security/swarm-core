#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

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
echo "=== 8. format_duration (costs.sh) ==="

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

assert_eq "0 seconds"    "0s"      "$(format_duration 0)"
assert_eq "45 seconds"   "45s"     "$(format_duration 45)"
assert_eq "60 seconds"   "1m 00s"  "$(format_duration 60)"
assert_eq "445 seconds"  "7m 25s"  "$(format_duration 445)"
assert_eq "3600 seconds" "1h 00m"  "$(format_duration 3600)"
assert_eq "7384 seconds" "2h 03m"  "$(format_duration 7384)"

# ============================================================
echo ""
echo "=== 9. costs.sh effort tag (real script, stub docker) ==="

# Run costs.sh through its #!/bin/bash shebang, which is Bash 3.2 on
# macOS, against a stub docker that reports one agent with an effort.
STUB_BIN="$TMPDIR/stub-bin"
PROJ_DIR="$TMPDIR/proj"
mkdir -p "$STUB_BIN" "$PROJ_DIR"
PROJ_OWNER=$(cd -P "$PROJ_DIR" && pwd -P)
cat > "$STUB_BIN/docker" <<'STUB'
#!/bin/bash
case "$1" in
    ps)
        # Both listings return id, name, project and owner as JSON.
        printf '{"id":"%s","name":"%s","project":"%s","owner":"%s"}\n' \
            cid-1 proj-agent-1 proj "$STUB_OWNER" ;;
    inspect)
        case "$3" in
            *State.Status*) echo "exited" ;;
            *Config.Env*)
                printf 'CLAUDE_MODEL=claude-opus-4-6\n'
                printf 'CLAUDE_CODE_EFFORT_LEVEL=high\n'
                ;;
        esac
        ;;
    cp) printf '1\t0.5\t100\t50\t0\t0\t2000\t0\t3\n' > "$3" ;;
esac
STUB
chmod +x "$STUB_BIN/docker"
git -C "$PROJ_DIR" init -q

COSTS_SH="$(cd "$(dirname "$0")/.." && pwd)/costs.sh"
rc=0
out=$(cd "$PROJ_DIR" && PATH="$STUB_BIN:$PATH" SWARM_SKIP_DEP_CHECK=1 \
    SWARM_RUNTIME_DIR="$TMPDIR/no-runtime" STUB_OWNER="$PROJ_OWNER" \
    "$COSTS_SH" 2>&1) || rc=$?
assert_eq "exits 0 with an effort level" "0" "$rc"
assert_eq "effort tag is uppercase" "1" \
    "$(printf '%s\n' "$out" | grep -c 'opus-4-6 \[H\]' || true)"

# ============================================================
echo ""
echo "=== 10. costs.sh copies stats into a private temp dir ==="

# Run the real script against a fake docker that serves one agent and
# records where `docker cp` writes.  The copy used to land on a fixed
# /tmp/.swarm-stats-<name>.tsv path.
_fake_bin="$TMPDIR/fake-bin"
_cp_log="$TMPDIR/docker-cp.log"
_costs_repo="$TMPDIR/costs-repo"
mkdir -p "$_fake_bin" "$_costs_repo"
_costs_owner=$(cd -P "$_costs_repo" && pwd -P)
cat > "$_fake_bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    ps)
        # Both listings return id, name, project and owner as JSON.
        printf '{"id":"%s","name":"%s","project":"%s","owner":"%s"}\n' \
            cid-1 costs-repo-agent-1 costs-repo "$_costs_owner" ;;
    inspect)
        case "\$3" in
            *Env*) echo "CLAUDE_MODEL=claude-opus-4-6" ;;
            *) echo "exited" ;;
        esac ;;
    cp)
        printf '%s\n' "\$3" >> "$_cp_log"
        printf '1\t0.5\t100\t200\t10\tx\t3000\tx\t4\n' > "\$3" ;;
esac
EOF
chmod +x "$_fake_bin/docker"

_costs_sh="$(cd "$(dirname "$0")/.." && pwd)/costs.sh"
git init -q "$_costs_repo"
_costs_out=$(cd "$_costs_repo" \
    && PATH="$_fake_bin:$PATH" SWARM_RUNTIME_DIR="$TMPDIR/no-runtime" \
        bash "$_costs_sh" --json 2>/dev/null || true)
_cp_dest=$(head -1 "$_cp_log" 2>/dev/null || true)

assert_eq "stats are read through docker cp" "0.5" \
    "$(printf '%s' "$_costs_out" | jq -r '.agents[0].cost_usd' 2>/dev/null)"
assert_eq "copy target is not a fixed /tmp name" "false" \
    "$([[ "$_cp_dest" == /tmp/.swarm-* ]] && echo true || echo false)"
assert_eq "copy target is gone after the run" "false" \
    "$([ -n "$_cp_dest" ] && [ -e "$_cp_dest" ] && echo true || echo false)"
assert_eq "copy target directory is removed too" "false" \
    "$([ -n "$_cp_dest" ] && [ -e "$(dirname "$_cp_dest")" ] \
        && echo true || echo false)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
