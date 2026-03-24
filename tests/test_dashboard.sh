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
DRV_COL_W=6
HAS_TAGS=true

short_driver() {
    case "${1:-}" in
        claude-code) printf 'claude' ;;
        gemini-cli)  printf 'gemini' ;;
        *)           printf '%s' "${1:-}" ;;
    esac
}

emit_row() {
    local id_str="$1" model_str="$2" driver_str="$3" auth_str="$4"
    local status_color="$5" status_str="$6"
    local cost_str="$7" inout_str="$8" cache_str="$9"
    local turns_str="${10}" tps_str="${11}" dur_str="${12}"
    local tag_str="${13:-}" is_bold="${14:-}"
    printf "  %-3s %-${MODEL_COL_W}s" "$id_str" "$model_str"
    if $SHOW_DRIVER; then printf " %-${DRV_COL_W}s" "$driver_str"; fi
    if $SHOW_AUTH;  then printf " %-6s" "$auth_str"; fi
    printf " %-14s %7s" "$status_str" "$cost_str"
    if $SHOW_INOUT; then printf " %13s" "$inout_str"; fi
    if $SHOW_CACHE; then printf " %7s" "$cache_str"; fi
    if $SHOW_TURNS; then printf " %6s" "$turns_str"; fi
    if $SHOW_TPS;   then printf " %6s" "$tps_str"; fi
    printf " %8s" "$dur_str"
    if $SHOW_TAG;   then printf "  %-${TAG_COL_W}s" "$tag_str"; fi
    printf "\n"
}

# Wide: all columns visible.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=true; SHOW_TPS=true; SHOW_CACHE=true; SHOW_TAG=true; SHOW_DRIVER=false
wide_line=$(emit_row "1" "claude-opus-4-6 (h)" "" "oauth" "" "running" \
    '$21.06' "6k/34k" "5.6M" "86" "15.7" "23m 27s" "explore")
assert_eq "wide has Auth"   "true" "$(echo "$wide_line" | grep -q 'oauth' && echo true || echo false)"
assert_eq "wide has Cache"  "true" "$(echo "$wide_line" | grep -q '5.6M' && echo true || echo false)"
assert_eq "wide has Turns"  "true" "$(echo "$wide_line" | grep -q '86' && echo true || echo false)"
assert_eq "wide has Tok/s"  "true" "$(echo "$wide_line" | grep -q '15.7' && echo true || echo false)"
assert_eq "wide has Tag"    "true" "$(echo "$wide_line" | grep -q 'explore' && echo true || echo false)"

# Narrow: minimal columns (no Auth, Cache, Turns, Tok/s, Tag, Driver).
SHOW_INOUT=false; SHOW_AUTH=false; SHOW_TURNS=false; SHOW_TPS=false; SHOW_CACHE=false; SHOW_TAG=false; SHOW_DRIVER=false
narrow_line=$(emit_row "1" "claude-opus-4-6 (h)" "" "oauth" "" "running" \
    '$21.06' "6k/34k" "5.6M" "86" "15.7" "23m 27s" "explore")
assert_eq "narrow no Auth"  "false" "$(echo "$narrow_line" | grep -q 'oauth' && echo true || echo false)"
assert_eq "narrow no Cache" "false" "$(echo "$narrow_line" | grep -q '5.6M' && echo true || echo false)"
assert_eq "narrow no Tag"   "false" "$(echo "$narrow_line" | grep -q 'explore' && echo true || echo false)"
assert_eq "narrow has Cost"  "true" "$(echo "$narrow_line" | grep -q '21.06' && echo true || echo false)"
assert_eq "narrow has Time"  "true" "$(echo "$narrow_line" | grep -q '23m' && echo true || echo false)"

# Tag hidden when terminal is narrow but other optional columns shown.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=true; SHOW_TPS=true; SHOW_CACHE=true; SHOW_TAG=false; SHOW_DRIVER=false
mid_line=$(emit_row "1" "claude-opus-4-6 (h)" "" "oauth" "" "running" \
    '$21.06' "6k/34k" "5.6M" "86" "15.7" "23m 27s" "explore")
assert_eq "mid has Auth"   "true"  "$(echo "$mid_line" | grep -q 'oauth' && echo true || echo false)"
assert_eq "mid no Tag"     "false" "$(echo "$mid_line" | grep -q 'explore' && echo true || echo false)"

# Status column alignment across different model widths.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=true; SHOW_TPS=true; SHOW_CACHE=true; SHOW_TAG=true; SHOW_DRIVER=false
line_opus=$(emit_row "1" "claude-opus-4-6 (h)" "" "oauth" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "explore")
line_sonnet=$(emit_row "3" "claude-sonnet-4-6 (h)" "" "oauth" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "deep")
status_pos_opus=$(echo "$line_opus" | grep -bo 'running' | head -1 | cut -d: -f1)
status_pos_sonnet=$(echo "$line_sonnet" | grep -bo 'running' | head -1 | cut -d: -f1)
assert_eq "Status column aligns" "$status_pos_opus" "$status_pos_sonnet"

# Tag at the end of the row.
SHOW_INOUT=false; SHOW_AUTH=false; SHOW_TURNS=false; SHOW_TPS=false; SHOW_CACHE=false; SHOW_TAG=true; SHOW_DRIVER=false
tag_line=$(emit_row "2" "claude-sonnet-4-6 (m)" "" "key" "" "running" \
    '$1.05' "1k/2k" "100k" "5" "12.0" "2m 30s" "reviewer")
tag_pos=$(echo "$tag_line" | grep -bo 'reviewer' | head -1 | cut -d: -f1)
time_pos=$(echo "$tag_line" | grep -bo '2m 30s' | head -1 | cut -d: -f1)
assert_eq "Tag after Time" "true" "$([ "$tag_pos" -gt "$time_pos" ] && echo true || echo false)"

# Empty tag does not break layout.
SHOW_TAG=true
empty_tag_line=$(emit_row "1" "claude-opus-4-6 (h)" "" "oauth" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "")
assert_eq "empty tag ok" "true" "$([ -n "$empty_tag_line" ] && echo true || echo false)"

# Idle status in Status column.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=true; SHOW_TPS=true; SHOW_CACHE=true; SHOW_TAG=false; SHOW_DRIVER=false
idle_line=$(emit_row "2" "claude-opus-4-6 (h)" "" "key" "" "idle 1/3" \
    '$0.05' "1k/500" "50k" "3" "12.0" "30s" "")
assert_eq "idle in status"  "true" "$(echo "$idle_line" | grep -q 'idle 1/3' && echo true || echo false)"
assert_eq "idle has cost"   "true" "$(echo "$idle_line" | grep -q '0.05' && echo true || echo false)"

# Status column now 14 chars: idle states with larger counts fit.
_s="idle 2/3";         assert_eq "idle 2/3 fits"         "true" "$([ ${#_s} -le 14 ] && echo true || echo false)"
_s="idle 10/10";       assert_eq "idle 10/10 fits"       "true" "$([ ${#_s} -le 14 ] && echo true || echo false)"
_s="idle 10/999";      assert_eq "idle 10/999 fits"      "true" "$([ ${#_s} -le 14 ] && echo true || echo false)"
_s="idle 999/999";     assert_eq "idle 999/999 fits"     "true" "$([ ${#_s} -le 14 ] && echo true || echo false)"
_s="idle 999/1234567"; assert_eq "idle 999/1234567 long" "true" "$([ ${#_s} -gt 14 ] && echo true || echo false)"

# Idle status aligns with running.
SHOW_DRIVER=false
running_line=$(emit_row "1" "claude-opus-4-6 (h)" "" "key" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "")
idle_align_line=$(emit_row "2" "claude-opus-4-6 (h)" "" "key" "" "idle 1/3" \
    '$0' "0/0" "0" "0" "--" "0s" "")
cost_pos_run=$(echo "$running_line" | grep -bo '\$0' | head -1 | cut -d: -f1)
cost_pos_idle=$(echo "$idle_align_line" | grep -bo '\$0' | head -1 | cut -d: -f1)
assert_eq "idle cost aligns with running" "$cost_pos_run" "$cost_pos_idle"

# Wider idle value aligns correctly with cost column.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=true; SHOW_TPS=true; SHOW_CACHE=true; SHOW_TAG=false; SHOW_DRIVER=false
wide_idle_line=$(emit_row "2" "claude-opus-4-6 (h)" "" "key" "" "idle 10/999" \
    '$0.05' "1k/500" "50k" "3" "12.0" "30s" "")
assert_eq "wide idle in status" "true" "$(echo "$wide_idle_line" | grep -q 'idle 10/999' && echo true || echo false)"
assert_eq "wide idle has cost"  "true" "$(echo "$wide_idle_line" | grep -q '0.05' && echo true || echo false)"

# In/Out column handles large values (13-char width).
large_inout_line=$(emit_row "1" "claude-opus-4-6 (h)" "" "key" "" "exited" \
    '$199.28' "171.6M/952k" "72.3M" "4398" "27.6" "10h 00m" "")
assert_eq "large inout present" "true" "$(echo "$large_inout_line" | grep -q '171.6M/952k' && echo true || echo false)"

# Driver column visible when SHOW_DRIVER=true.
SHOW_INOUT=true; SHOW_AUTH=true; SHOW_TURNS=false; SHOW_TPS=false; SHOW_CACHE=false; SHOW_TAG=false; SHOW_DRIVER=true
drv_line=$(emit_row "1" "claude-opus-4-6 (h)" "claude" "oauth" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "")
assert_eq "driver col visible" "true" "$(echo "$drv_line" | grep -q 'claude' && echo true || echo false)"

# Driver column hidden when SHOW_DRIVER=false.
SHOW_DRIVER=false
no_drv_line=$(emit_row "1" "claude-opus-4-6 (h)" "gemini" "key" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "")
assert_eq "driver col hidden" "false" "$(echo "$no_drv_line" | grep -q 'gemini' && echo true || echo false)"

# Driver column aligns across rows.
SHOW_DRIVER=true; SHOW_AUTH=true; SHOW_INOUT=false; SHOW_TURNS=false; SHOW_TPS=false; SHOW_CACHE=false; SHOW_TAG=false
drv_claude=$(emit_row "1" "claude-opus-4-6 (h)" "claude" "oauth" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "")
drv_gemini=$(emit_row "2" "gemini-2.5-pro" "gemini" "key" "" "running" \
    '$0' "0/0" "0" "0" "--" "0s" "")
auth_pos_c=$(echo "$drv_claude" | grep -bo 'oauth' | head -1 | cut -d: -f1)
auth_pos_g=$(echo "$drv_gemini" | grep -bo 'key' | head -1 | cut -d: -f1)
assert_eq "auth aligns with driver col" "$auth_pos_c" "$auth_pos_g"

# ============================================================
echo ""
echo "=== 4. short_driver ==="

assert_eq "claude-code → claude" "claude" "$(short_driver claude-code)"
assert_eq "gemini-cli → gemini"  "gemini" "$(short_driver gemini-cli)"
assert_eq "fake passthrough"     "fake"   "$(short_driver fake)"
assert_eq "unknown passthrough"  "foo"    "$(short_driver foo)"
assert_eq "empty → empty"       ""        "$(short_driver "")"

# ============================================================
echo ""
echo "=== 5. tag column width from config ===" 

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
echo "=== 6. tag field in agents.cfg ==="

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
echo "=== 7. MODEL_COL_W computation from config ==="

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
echo "=== 8. Model label fits within column ==="

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
assert_eq "gemini pro needs wide col" "overflow:34" "$(check_fits "gemini-3.1-pro-preview-customtools" 25)"
assert_eq "gemini pro fits 40"        "fits"        "$(check_fits "gemini-3.1-pro-preview-customtools" 40)"
assert_eq "gemini flash fits"         "fits"        "$(check_fits "gemini-3-flash-preview" 25)"

# ============================================================
echo ""
echo "=== 9. format_model passthrough for all drivers ==="

assert_eq "gemini full name" "gemini-3.1-pro-preview-customtools" \
    "$(format_model "gemini-3.1-pro-preview-customtools" "")"
assert_eq "gemini flash no effort" "gemini-3-flash-preview" \
    "$(format_model "gemini-3-flash-preview" "")"
assert_eq "gemini with effort" "gemini-2.5-pro (h)" \
    "$(format_model "gemini-2.5-pro" "high")"

# ============================================================
echo ""
echo "=== 10. HAS_MULTI_DRIVERS jq detection ==="

detect_multi_drivers() {
    jq -r '.driver as $dd | [.agents[] | (.driver // $dd // "claude-code")] | unique | length' \
        "$1" 2>/dev/null || echo 1
}

cat > "$TMPDIR/single_claude.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 2, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-sonnet-4-6" }
  ]
}
EOF
assert_eq "all claude → 1 driver" "1" "$(detect_multi_drivers "$TMPDIR/single_claude.json")"

cat > "$TMPDIR/mixed_explicit.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6" },
    { "count": 1, "model": "gemini-2.5-pro", "driver": "gemini-cli" }
  ]
}
EOF
assert_eq "mixed explicit → 2 drivers" "2" "$(detect_multi_drivers "$TMPDIR/mixed_explicit.json")"

cat > "$TMPDIR/inherit_top.json" <<'EOF'
{
  "prompt": "p.md",
  "driver": "gemini-cli",
  "agents": [
    { "count": 1, "model": "gemini-2.5-pro" },
    { "count": 1, "model": "gemini-3-flash-preview" }
  ]
}
EOF
assert_eq "inherit top-level → 1 driver" "1" "$(detect_multi_drivers "$TMPDIR/inherit_top.json")"

cat > "$TMPDIR/override_top.json" <<'EOF'
{
  "prompt": "p.md",
  "driver": "gemini-cli",
  "agents": [
    { "count": 1, "model": "gemini-2.5-pro" },
    { "count": 1, "model": "claude-opus-4-6", "driver": "claude-code" }
  ]
}
EOF
assert_eq "override top-level → 2 drivers" "2" "$(detect_multi_drivers "$TMPDIR/override_top.json")"

cat > "$TMPDIR/all_gemini_explicit.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "gemini-2.5-pro", "driver": "gemini-cli" },
    { "count": 1, "model": "gemini-3-flash-preview", "driver": "gemini-cli" }
  ]
}
EOF
assert_eq "all gemini explicit → 1 driver" "1" "$(detect_multi_drivers "$TMPDIR/all_gemini_explicit.json")"

# ============================================================
echo ""
echo "=== 11. Git info and default title ==="

GIT_BRANCH_TEST=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
GIT_SHORT_HEAD_TEST=$(git rev-parse --short HEAD 2>/dev/null || echo "")
assert_eq "git branch detected" "true" "$([ -n "$GIT_BRANCH_TEST" ] && echo true || echo false)"
assert_eq "git short head detected" "true" "$([ -n "$GIT_SHORT_HEAD_TEST" ] && echo true || echo false)"

PROJECT_TEST=$(basename "$(git rev-parse --show-toplevel)")
DEFAULT_TITLE_TEST="${PROJECT_TEST} (@${GIT_SHORT_HEAD_TEST})"
assert_eq "default title format" "${PROJECT_TEST} (@${GIT_SHORT_HEAD_TEST})" "$DEFAULT_TITLE_TEST"

# State file title: config title captured when no env var.
config_title=$(jq -r '.title // empty' "$TMPDIR/tags.json")
assert_eq "no title field → empty" "" "$config_title"

cat > "$TMPDIR/titled.json" <<'EOF'
{ "prompt": "p.md", "title": "My Fuzzer", "agents": [{ "count": 1, "model": "m" }] }
EOF
config_title=$(jq -r '.title // empty' "$TMPDIR/titled.json")
assert_eq "title from config" "My Fuzzer" "$config_title"

# Title priority: user env > state file > config > default.
USER_TITLE_T="user-set"
SWARM_TITLE_T="state-set"
assert_eq "user title wins" "user-set" "${USER_TITLE_T:-${SWARM_TITLE_T:-${DEFAULT_TITLE_TEST}}}"
USER_TITLE_T=""
assert_eq "state title wins" "state-set" "${USER_TITLE_T:-${SWARM_TITLE_T:-${DEFAULT_TITLE_TEST}}}"
SWARM_TITLE_T=""
assert_eq "default title wins" "$DEFAULT_TITLE_TEST" "${USER_TITLE_T:-${SWARM_TITLE_T:-${DEFAULT_TITLE_TEST}}}"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
