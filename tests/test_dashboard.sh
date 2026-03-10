#!/bin/bash
# shellcheck disable=SC2034,SC2016
set -euo pipefail

# Unit tests for dashboard.sh helper functions:
#   format_model, truncate_str, and column layout (with optional Tag).
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
        echo "        expected: |${expected}|"
        echo "        actual:   |${actual}|"
        FAIL=$((FAIL + 1))
    fi
}

# --- Functions under test (copied from dashboard.sh) ---

format_model() {
    local m="${1:-unknown}" effort="${2:-}"
    if [ -n "$effort" ]; then
        printf '%s (%s)' "$m" "${effort:0:1}"
    else
        printf '%s' "$m"
    fi
}

truncate_str() {
    local s="$1" max="${2:-16}"
    if [ "${#s}" -le "$max" ]; then
        printf '%s' "$s"
        return
    fi
    local keep=$(( (max - 1) / 2 ))
    printf '%s~%s' "${s:0:$keep}" "${s: -$keep}"
}

# ============================================================
echo "=== 1. format_model ==="

assert_eq "claude opus high"     "claude-opus-4-6 (h)"    "$(format_model claude-opus-4-6 high)"
assert_eq "claude sonnet high"   "claude-sonnet-4-6 (h)"  "$(format_model claude-sonnet-4-6 high)"
assert_eq "claude sonnet medium" "claude-sonnet-4-6 (m)"  "$(format_model claude-sonnet-4-6 medium)"
assert_eq "claude sonnet low"    "claude-sonnet-4-6 (l)"  "$(format_model claude-sonnet-4-6 low)"
assert_eq "claude haiku"         "claude-haiku-3-5 (h)"   "$(format_model claude-haiku-3-5 high)"
assert_eq "openai via openrouter" "openai/gpt-5.4"        "$(format_model openai/gpt-5.4 "")"
assert_eq "minimax with effort"  "MiniMax-M2.5 (h)"       "$(format_model MiniMax-M2.5 high)"
assert_eq "bare string medium"   "gpt-4o (m)"             "$(format_model gpt-4o medium)"
assert_eq "no effort"            "claude-opus-4-6"         "$(format_model claude-opus-4-6 "")"
assert_eq "unknown no effort"    "unknown"                 "$(format_model unknown "")"
assert_eq "empty default"        "unknown"                 "$(format_model)"

# ============================================================
echo ""
echo "=== 2. truncate_str ==="

assert_eq "short (no truncation)"     "explore"           "$(truncate_str explore 16)"
assert_eq "exact fit"                  "exactly-sixteen!" "$(truncate_str 'exactly-sixteen!' 16)"
assert_eq "one over"                   "sevente~chars!!"  "$(truncate_str 'seventeen-chars!!' 16)"
assert_eq "long smoke-reconcile"       ".claude~concile"  "$(truncate_str .claude-swarm-smoke-reconcile 16)"
assert_eq "long smoke-alt"             ".claude~oke-alt"  "$(truncate_str .claude-swarm-smoke-alt 16)"
assert_eq "long smoke-pp"              ".claude~moke-pp"  "$(truncate_str .claude-swarm-smoke-pp 16)"
assert_eq "max=8"                      "abc~fgh"          "$(truncate_str abcdefgh 7)"
assert_eq "max=5"                      "ab~ef"            "$(truncate_str abcdef 5)"
assert_eq "empty string"              ""                   "$(truncate_str '' 16)"
assert_eq "single char"               "x"                  "$(truncate_str x 16)"

# ============================================================
echo ""
echo "=== 3. row layout ==="

BOLD=""; RESET=""; GREEN=""; RED=""; DIM=""
MODEL_COL_W=25
TAG_COL_W=12
HAS_TAGS=true

emit_row() {
    local id_str="$1" model_str="$2" auth_str="$3"
    local status_color="$4" status_str="$5"
    local cost_str="$6" inout_str="$7" cache_str="$8"
    local turns_str="$9" tps_str="${10}" dur_str="${11}"
    local tag_str="${12:-}" is_bold="${13:-}"
    printf "  %-3s %-${MODEL_COL_W}s" "$id_str" "$model_str"
    if $SHOW_AUTH;  then printf " %-6s" "$auth_str"; fi
    printf " %-8s %7s" "$status_str" "$cost_str"
    if $SHOW_INOUT; then printf " %10s" "$inout_str"; fi
    if $SHOW_CACHE; then printf " %7s" "$cache_str"; fi
    if $SHOW_TURNS; then printf " %6s" "$turns_str"; fi
    if $SHOW_TPS;   then printf " %6s" "$tps_str"; fi
    printf " %8s" "$dur_str"
    if $SHOW_TAG;   then printf "  %-${TAG_COL_W}s" "$tag_str"; fi
    printf "\n"
}

# Wide: all columns visible.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=true; SHOW_TPS=true; SHOW_CACHE=true; SHOW_TAG=true
wide_line=$(emit_row "1" "claude-opus-4-6 (h)" "oauth" "" "running" \
    '$21.06' "6k/34k" "5.6M" "86" "15.7" "23m 27s" "explore")
assert_eq "wide has Auth"   "true" "$(echo "$wide_line" | grep -q 'oauth' && echo true || echo false)"
assert_eq "wide has Cache"  "true" "$(echo "$wide_line" | grep -q '5.6M' && echo true || echo false)"
assert_eq "wide has Turns"  "true" "$(echo "$wide_line" | grep -q '86' && echo true || echo false)"
assert_eq "wide has Tok/s"  "true" "$(echo "$wide_line" | grep -q '15.7' && echo true || echo false)"
assert_eq "wide has Tag"    "true" "$(echo "$wide_line" | grep -q 'explore' && echo true || echo false)"

# Narrow: minimal columns (no Auth, Cache, Turns, Tok/s, Tag).
SHOW_INOUT=false; SHOW_AUTH=false; SHOW_TURNS=false; SHOW_TPS=false; SHOW_CACHE=false; SHOW_TAG=false
narrow_line=$(emit_row "1" "claude-opus-4-6 (h)" "oauth" "" "running" \
    '$21.06' "6k/34k" "5.6M" "86" "15.7" "23m 27s" "explore")
assert_eq "narrow no Auth"  "false" "$(echo "$narrow_line" | grep -q 'oauth' && echo true || echo false)"
assert_eq "narrow no Cache" "false" "$(echo "$narrow_line" | grep -q '5.6M' && echo true || echo false)"
assert_eq "narrow no Tag"   "false" "$(echo "$narrow_line" | grep -q 'explore' && echo true || echo false)"
assert_eq "narrow has Cost"  "true" "$(echo "$narrow_line" | grep -q '21.06' && echo true || echo false)"
assert_eq "narrow has Time"  "true" "$(echo "$narrow_line" | grep -q '23m' && echo true || echo false)"

# Tag hidden when terminal is narrow but other optional columns shown.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=true; SHOW_TPS=true; SHOW_CACHE=true; SHOW_TAG=false
mid_line=$(emit_row "1" "claude-opus-4-6 (h)" "oauth" "" "running" \
    '$21.06' "6k/34k" "5.6M" "86" "15.7" "23m 27s" "explore")
assert_eq "mid has Auth"   "true"  "$(echo "$mid_line" | grep -q 'oauth' && echo true || echo false)"
assert_eq "mid no Tag"     "false" "$(echo "$mid_line" | grep -q 'explore' && echo true || echo false)"

# Status column alignment across different model widths.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=true; SHOW_TPS=true; SHOW_CACHE=true; SHOW_TAG=true
line_opus=$(emit_row "1" "claude-opus-4-6 (h)" "oauth" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "explore")
line_sonnet=$(emit_row "3" "claude-sonnet-4-6 (h)" "oauth" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "deep")
status_pos_opus=$(echo "$line_opus" | grep -bo 'running' | head -1 | cut -d: -f1)
status_pos_sonnet=$(echo "$line_sonnet" | grep -bo 'running' | head -1 | cut -d: -f1)
assert_eq "Status column aligns" "$status_pos_opus" "$status_pos_sonnet"

# Tag at the end of the row.
SHOW_INOUT=false; SHOW_AUTH=false; SHOW_TURNS=false; SHOW_TPS=false; SHOW_CACHE=false; SHOW_TAG=true
tag_line=$(emit_row "2" "claude-sonnet-4-6 (m)" "key" "" "running" \
    '$1.05' "1k/2k" "100k" "5" "12.0" "2m 30s" "reviewer")
tag_pos=$(echo "$tag_line" | grep -bo 'reviewer' | head -1 | cut -d: -f1)
time_pos=$(echo "$tag_line" | grep -bo '2m 30s' | head -1 | cut -d: -f1)
assert_eq "Tag after Time" "true" "$([ "$tag_pos" -gt "$time_pos" ] && echo true || echo false)"

# Empty tag does not break layout.
SHOW_TAG=true
empty_tag_line=$(emit_row "1" "claude-opus-4-6 (h)" "oauth" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "")
assert_eq "empty tag ok" "true" "$([ -n "$empty_tag_line" ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 4. tag column width from config ==="

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/tags.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 2, "model": "claude-opus-4-6", "tag": "explore" },
    { "count": 1, "model": "claude-sonnet-4-6", "tag": "review" }
  ]
}
EOF

tw=$(jq -r '[.agents[] | .tag // empty] | if length == 0 then 0
    else map(length) | max end' "$TMPDIR/tags.json")
assert_eq "tag col width" "7" "$tw"

cat > "$TMPDIR/no_tags.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 2, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-sonnet-4-6" }
  ]
}
EOF

tw=$(jq -r '[.agents[] | .tag // empty] | if length == 0 then 0
    else map(length) | max end' "$TMPDIR/no_tags.json")
assert_eq "no tags → 0" "0" "$tw"

cat > "$TMPDIR/mixed_tags.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "tag": "x" },
    { "count": 1, "model": "claude-sonnet-4-6" }
  ]
}
EOF

tw=$(jq -r '[.agents[] | .tag // empty] | if length == 0 then 0
    else map(length) | max end' "$TMPDIR/mixed_tags.json")
assert_eq "partial tags" "1" "$tw"

# ============================================================
echo ""
echo "=== 5. tag field in agents.cfg ==="

parse_agents_cfg() {
    jq -r '.agents[] | range(.count) as $i |
        [.model, (.base_url // ""), (.api_key // ""), (.effort // ""), (.auth // ""), (.context // ""), (.prompt // ""), (.auth_token // ""), (.tag // "")] | join("|")' "$1"
}

CFG=$(parse_agents_cfg "$TMPDIR/tags.json")
LINE1=$(echo "$CFG" | sed -n '1p')
LINE3=$(echo "$CFG" | sed -n '3p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 tag1 <<< "$LINE1"
assert_eq "tag explore" "explore" "$tag1"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 tag3 <<< "$LINE3"
assert_eq "tag review" "review" "$tag3"

CFG=$(parse_agents_cfg "$TMPDIR/no_tags.json")
LINE1=$(echo "$CFG" | sed -n '1p')
IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 tag1 <<< "$LINE1"
assert_eq "tag empty" "" "$tag1"

# ============================================================
echo ""
echo "=== 6. MODEL_COL_W computation from config ==="

compute_model_col_w() {
    local w
    w=$(jq -r '
        [.agents[] | .model + if .effort then " (\(.effort[:1]))" else "" end] +
        [.post_process // {} | select(.model) |
         .model + if .effort then " (\(.effort[:1]))" else "" end] |
        map(length) | max + 2
    ' "$1" 2>/dev/null || echo 25)
    [ "$w" -lt 22 ] && w=22
    echo "$w"
}

cat > "$TMPDIR/short_models.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 2, "model": "gpt-4o" }]
}
EOF
assert_eq "short model → floor 22" "22" "$(compute_model_col_w "$TMPDIR/short_models.json")"

cat > "$TMPDIR/mixed_models.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "effort": "high" },
    { "count": 1, "model": "claude-sonnet-4-6", "effort": "high" },
    { "count": 1, "model": "openai/gpt-5.4" },
    { "count": 1, "model": "MiniMax-M2.5" }
  ]
}
EOF
# claude-sonnet-4-6 (h) = 21 chars → 21 + 2 = 23
assert_eq "mixed models width" "23" "$(compute_model_col_w "$TMPDIR/mixed_models.json")"

cat > "$TMPDIR/pp_wider.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "gpt-4o" }],
  "post_process": { "prompt": "r.md", "model": "claude-sonnet-4-6", "effort": "high" }
}
EOF
# pp model claude-sonnet-4-6 (h) = 21 chars → 21 + 2 = 23, wider than agent
assert_eq "pp model widens column" "23" "$(compute_model_col_w "$TMPDIR/pp_wider.json")"

# ============================================================
echo ""
echo "=== 7. Model label fits within column ==="

# Verify that common model labels don't overflow MODEL_COL_W=25.
check_fits() {
    local label="$1" col_w="$2"
    if [ "${#label}" -le "$col_w" ]; then
        echo "fits"
    else
        echo "overflow:${#label}"
    fi
}

assert_eq "opus (h) fits"   "fits" "$(check_fits "claude-opus-4-6 (h)" 25)"
assert_eq "sonnet (h) fits" "fits" "$(check_fits "claude-sonnet-4-6 (h)" 25)"
assert_eq "haiku (h) fits"  "fits" "$(check_fits "claude-haiku-4-5 (h)" 25)"
assert_eq "openai fits"     "fits" "$(check_fits "openai/gpt-5.4-pro (h)" 25)"
assert_eq "minimax fits"    "fits" "$(check_fits "MiniMax-M2.5 (h)" 25)"
assert_eq "bare model fits" "fits" "$(check_fits "claude-opus-4-6" 25)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
