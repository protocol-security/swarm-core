#!/bin/bash
set -euo pipefail

# Guard against the regression reported in the bug:
#   dashboard.sh: line 207: printf: 52.185737173...: invalid number
# on systems using `,` as the decimal separator.  Pin the
# `export LC_NUMERIC=C` fix structurally, then drive the
# formatting functions under a comma-decimal locale to prove
# the fix actually solves the bug end-to-end.

PASS=0
FAIL=0
SKIP=0
TMPDIR=$(mktemp -d)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        needle:  ${needle}"
        echo "        haystack:"
        printf '%s\n' "$haystack" | head -5 | sed 's/^/          /'
        FAIL=$((FAIL + 1))
    fi
}

skip() {
    echo "  SKIP: $1"
    SKIP=$((SKIP + 1))
}

# ============================================================
echo "=== 1. Structural: LC_NUMERIC=C pinned near script top ==="

# The export must appear within the first 20 lines so it fires
# before any function runs or any `bc`/`awk`/`printf` call.
for f in dashboard.sh costs.sh lib/harness.sh; do
    path="$REPO_ROOT/$f"
    head_lines=$(head -20 "$path")
    if printf '%s\n' "$head_lines" | grep -qE '^export LC_NUMERIC=C$'; then
        echo "  PASS: $f exports LC_NUMERIC=C in first 20 lines"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $f is missing 'export LC_NUMERIC=C' in first 20 lines"
        FAIL=$((FAIL + 1))
    fi
done

# ============================================================
echo ""
echo "=== 2. Bootstrap a comma-decimal locale for the live test ==="

# Try the locales most likely to be installed on a dev or CI
# box; fall back to generating de_DE.UTF-8 via an unprivileged
# `localedef` into LOCPATH if none is available (glibc only).
# The probe explicitly unsets LC_ALL and sets LANG to the
# candidate because bash's builtin printf only enforces the
# locale's decimal separator strictly when LC_ALL is unset and
# LANG (or LC_NUMERIC via a full locale load) is the comma
# locale.  LC_MESSAGES=C keeps error messages in English so
# the assertion below can grep for "invalid number".
probe_locale() {
    local loc=$1
    LC_ALL='' LANG="$loc" LC_MESSAGES=C \
        bash -c 'printf "%.1f" "1.5" 2>&1; exit $?'
}

COMMA_LOCALE=""
for candidate in de_DE.UTF-8 de_DE.utf8 fr_FR.UTF-8 fr_FR.utf8 \
        sv_SE.UTF-8 nl_NL.UTF-8 it_IT.UTF-8; do
    out=$(probe_locale "$candidate" 2>&1) || true
    if printf '%s' "$out" | grep -qF 'invalid number'; then
        COMMA_LOCALE=$candidate
        break
    fi
done

if [ -z "$COMMA_LOCALE" ] && command -v localedef >/dev/null; then
    mkdir -p "$TMPDIR/locale"
    if localedef -f UTF-8 -i de_DE "$TMPDIR/locale/de_DE.UTF-8" \
            >/dev/null 2>&1; then
        export LOCPATH="$TMPDIR/locale"
        out=$(probe_locale de_DE.UTF-8 2>&1) || true
        if printf '%s' "$out" | grep -qF 'invalid number'; then
            COMMA_LOCALE="de_DE.UTF-8"
        fi
    fi
fi

if [ -z "$COMMA_LOCALE" ]; then
    echo "  (no comma-decimal locale available on this host;"
    echo "   §3 and §4 will skip -- the structural pin in §1"
    echo "   is the only safety net on this platform)"
    FOUND_LOCALE=false
else
    echo "  using $COMMA_LOCALE as the broken-locale probe"
    FOUND_LOCALE=true
fi

# Extract the format_* function definitions out of dashboard.sh
# so we can exercise them without running the TUI main loop.
# `sed` pulls each `name() { ... }` block up to the first bare
# `}` line.
extract_fn() {
    local fn=$1 src=$2
    sed -n "/^${fn}()/,/^}\$/p" "$src"
}

FORMAT_LIB="$TMPDIR/format_lib.sh"
{
    echo '#!/bin/bash'
    extract_fn format_tokens "$REPO_ROOT/dashboard.sh"
    echo
    extract_fn format_cost   "$REPO_ROOT/dashboard.sh"
    echo
    extract_fn format_tps    "$REPO_ROOT/dashboard.sh"
} > "$FORMAT_LIB"

# Sanity-check the extraction: each function must be present
# and the file must parse under `bash -n`.
bash -n "$FORMAT_LIB" 2>&1 | tee "$TMPDIR/syntax.err" >/dev/null
assert_eq "extracted format_lib parses under bash -n" \
    "" "$(cat "$TMPDIR/syntax.err")"
assert_contains "format_tps present in extract" \
    "format_tps()" "$(cat "$FORMAT_LIB")"

# ============================================================
echo ""
echo "=== 3. Live: format_tps under broken locale without fix ==="

if ! $FOUND_LOCALE; then
    skip "requires a comma-decimal locale (none available)"
else
    # Reproduce the original bug: call format_tps with tokens
    # that force `bc -l` to emit a long decimal.  Without
    # LC_NUMERIC=C, printf must die.
    rc=0
    out=$(LC_ALL='' LANG="$COMMA_LOCALE" LC_MESSAGES=C bash -c "
        set -e
        . '$FORMAT_LIB'
        format_tps 52 996
    " 2>&1) || rc=$?
    assert_eq "unfixed call fails under $COMMA_LOCALE" "true" \
        "$([ "$rc" -ne 0 ] && echo true || echo false)"
    assert_contains "error message names printf + invalid number" \
        "invalid number" "$out"
fi

# ============================================================
echo ""
echo "=== 4. Live: format_tps with LC_NUMERIC=C override works ==="

if ! $FOUND_LOCALE; then
    skip "requires a comma-decimal locale (none available)"
else
    # Simulate the fix: user sets the broken locale, the
    # script's own `export LC_NUMERIC=C` overrides it, all
    # formatting succeeds.
    rc=0
    out=$(LC_ALL='' LANG="$COMMA_LOCALE" LC_MESSAGES=C bash -c "
        set -euo pipefail
        export LC_NUMERIC=C
        . '$FORMAT_LIB'
        format_tps 52 996
        echo
        format_tokens 1500000
        echo
        format_tokens 1500
        echo
        format_cost 12.3456
    " 2>&1) || rc=$?
    assert_eq "fixed call exits 0" "0" "$rc"
    # format_tps 52 996 = 52*1000/996 ≈ 52.2; printed as "52.2".
    assert_contains "format_tps output has '.' separator" \
        "52.2" "$out"
    # format_tokens 1500000 ≈ 1.5M
    assert_contains "format_tokens M-branch uses '.'" \
        "1.5M" "$out"
    # format_tokens 1500 = 2k (printf '%.0f' rounds 1.5 to 2;
    # banker's rounding or round-half-up -- accept either).
    assert_eq "format_tokens k-branch is integer + 'k'" \
        "true" \
        "$(printf '%s' "$out" | grep -qE '^(1|2)k$' \
            && echo true || echo false)"
    # format_cost 12.3456 -> $12.35 (literal dollar sign).
    # shellcheck disable=SC2016
    assert_contains "format_cost keeps '.' for cents" \
        '$12.35' "$out"
fi

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "==============================="

[ "$FAIL" -eq 0 ]
