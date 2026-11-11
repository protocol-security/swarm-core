#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for swarm costs aggregation and formatting logic.
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

# --- Helpers: same awk/logic used in swarm costs ---

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
echo "=== 6. format_tokens (swarm costs copy) ==="

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
echo "=== 8. format_duration (swarm costs) ==="

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
echo "=== 9. swarm costs effort tag (real script, stub docker) ==="

# Run swarm costs through its #!/bin/bash shebang, which is Bash 3.2 on
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

COSTS_SH="$(cd "$(dirname "$0")/.." && pwd)/libexec/costs"
rc=0
out=$(cd "$PROJ_DIR" && PATH="$STUB_BIN:$PATH" SWARM_SKIP_DEP_CHECK=1 \
    SWARM_RUNTIME_DIR="$TMPDIR/no-runtime" STUB_OWNER="$PROJ_OWNER" \
    "$COSTS_SH" 2>&1) || rc=$?
assert_eq "exits 0 with an effort level" "0" "$rc"
assert_eq "effort tag is uppercase" "1" \
    "$(printf '%s\n' "$out" | grep -c 'opus-4-6 \[H\]' || true)"

# ============================================================
echo ""
echo "=== 10. swarm costs copies stats into a private temp dir ==="

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

_costs_sh="$(cd "$(dirname "$0")/.." && pwd)/libexec/costs"
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
echo "=== 11. A run stopped on an unset variable fails ==="

# Bash 3.2 (macOS's /bin/bash, which the script's shebang runs) gives an
# EXIT trap status 0 when set -u stops the script.  The real script with
# the fake docker of section 10, and a printf that, through BASH_ENV,
# reads an unset variable when it prints the table's header (in the
# script's own shell, after the trap is set).
# The status /bin/bash gives an EXIT trap when set -u stops a script: 0
# on Bash 3.2 (the bug), where the trap must say why it ends with 1; 1 on
# later versions, where Bash's own status and error say it.
printf '%s\n' 'set -euo pipefail' "trap 'echo \"\$?\"' EXIT" \
    ': "$swarm_probe_unset"' > "$TMPDIR/stop-probe.sh"
_stop_status=$(/bin/bash "$TMPDIR/stop-probe.sh" 2>/dev/null || true)
_stop_says=0
[ "$_stop_status" = 0 ] && _stop_says=1
cat > "$TMPDIR/stop-env.sh" <<'EOF'
printf() {
    if [ -n "${SWARM_TEST_STOP:-}" ] && [ "${1:-}" = \
            "%-4s %-20s %9s %10s %10s %6s %8s %8s\n" ]; then
        : "$swarm_test_unset_variable"
    fi
    builtin printf "$@"
}
EOF
_stop_rc=0
_stop_out=$(cd "$_costs_repo" \
    && PATH="$_fake_bin:$PATH" SWARM_RUNTIME_DIR="$TMPDIR/no-runtime" \
        BASH_ENV="$TMPDIR/stop-env.sh" SWARM_TEST_STOP=1 \
        "$_costs_sh" 2>&1) || _stop_rc=$?
assert_eq "a run stopped on an unset variable ends with 1" "1" "$_stop_rc"
assert_eq "saying so where Bash 3.2 would end with 0" "$_stop_says" \
    "$(grep -c 'swarm costs stopped before the end of its run' <<< "$_stop_out")"
_stop_rc=0
(cd "$_costs_repo" \
    && PATH="$_fake_bin:$PATH" SWARM_RUNTIME_DIR="$TMPDIR/no-runtime" \
        BASH_ENV="$TMPDIR/stop-env.sh" "$_costs_sh" >/dev/null 2>&1) \
    || _stop_rc=$?
assert_eq "the same run without the stop ends with 0" "0" "$_stop_rc"

# The check is made only on Bash before 4.1: later versions end a run
# that set -u stops with a nonzero status themselves, and every version
# can run the EXIT trap with $? at 0 when a signal ends the script.  The
# shared version test (lib/project.sh) and the script's trap, extracted.
_extract() {  # FUNCTION FILE
    awk -v f="$1" '$0 ~ "^" f "\\(\\)[[:space:]]*\\{" { p = 1 }
         p { print }
         p && /^\}[[:space:]]*$/ { exit }' "$2"
}
_extract swarm_stop_guard_needed "$(dirname "$_costs_sh")/../lib/project.sh" \
    > "$TMPDIR/stop-guard.sh"
_extract costs_exit_trap "$_costs_sh" > "$TMPDIR/exit-trap.sh"
_guard() {
    (
        # shellcheck source=/dev/null
        source "$TMPDIR/stop-guard.sh"
        if swarm_stop_guard_needed "$1" "$2"; then echo yes; else echo no; fi
    )
}
_guards="$(_guard 3 2) $(_guard 4 0) $(_guard 4 1) $(_guard 4 4)"
_guards="$_guards $(_guard 5 2) $(_guard 10 0)"
assert_eq "the check is made on Bash 3.2 and 4.0, not from 4.1 on" \
    "yes yes no no no no" "$_guards"
# Every Bash the runner has: /bin/bash, and on macOS the Homebrew bash
# CI installs (required there).
_bashes="/bin/bash"
_brew_bash=""
if command -v brew >/dev/null 2>&1; then
    _brew_bash="$(brew --prefix)/bin/bash"
fi
if [ -n "$_brew_bash" ] && [ -x "$_brew_bash" ]; then
    _bashes="$_bashes $_brew_bash"
elif [ "$(uname)" = Darwin ]; then
    if [ -n "${CI:-}" ]; then
        assert_eq "CI has the Homebrew bash" "yes" "no"
    else
        echo "  SKIP: no Homebrew bash, so only /bin/bash is checked"
    fi
fi
# The trap, with the version test stubbed both ways, in a child Bash: a
# run that ends without the flag prints the line and ends with 1 only
# where the check is made; the flag, or another status, is kept; the
# scratch directory goes every time.
_trap_run() {  # BASH NEEDED(0 yes, 1 no) END
    cat > "$TMPDIR/trap-run.sh" <<EOF
set -euo pipefail
COSTS_TMPDIR="$TMPDIR/trap-scratch"
mkdir -p "\$COSTS_TMPDIR"
COSTS_EXIT_OK=false
# shellcheck source=/dev/null
source "$TMPDIR/exit-trap.sh"
swarm_stop_guard_needed() { return $2; }
trap costs_exit_trap EXIT
$3
EOF
    "$1" "$TMPDIR/trap-run.sh" 2>&1
}
_trap_gone() {
    if [ -e "$TMPDIR/trap-scratch" ]; then echo no; else echo yes; fi
}
for _b in $_bashes; do
    _tr_rc=0
    _tr_out=$(_trap_run "$_b" 0 ':') || _tr_rc=$?
    assert_eq "$_b: no flag where the check is made: status 1" "1" "$_tr_rc"
    assert_eq "$_b:   saying so once" "1" \
        "$(grep -c 'swarm costs stopped before the end of its run' \
            <<< "$_tr_out")"
    assert_eq "$_b:   the scratch directory goes" "yes" "$(_trap_gone)"
    _tr_rc=0
    _tr_out=$(_trap_run "$_b" 1 ':') || _tr_rc=$?
    assert_eq "$_b: no flag where it is not: status 0" "0" "$_tr_rc"
    assert_eq "$_b:   no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_tr_out")"
    assert_eq "$_b:   the scratch directory goes" "yes" "$(_trap_gone)"
    _tr_rc=0
    _tr_out=$(_trap_run "$_b" 0 'COSTS_EXIT_OK=true') || _tr_rc=$?
    assert_eq "$_b: the flag: status 0" "0" "$_tr_rc"
    assert_eq "$_b:   no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_tr_out")"
    assert_eq "$_b:   the scratch directory goes" "yes" "$(_trap_gone)"
    _tr_rc=0
    _tr_out=$(_trap_run "$_b" 0 'exit 3') || _tr_rc=$?
    assert_eq "$_b: another status stays" "3" "$_tr_rc"
    assert_eq "$_b:   with no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_tr_out")"
    assert_eq "$_b:   the scratch directory goes" "yes" "$(_trap_gone)"
done
# End to end: SIGTERM and SIGHUP to the script while it waits in docker
# cp, the first docker call after the trap is set (its destination is
# in the scratch directory).  python3 starts the script in a session of
# its own, signals the script only, then lets the waiting fake go (Bash
# may hold the signal until it returns), and kills the whole session at
# the end.  On Bash 4.1 and later no line, on earlier versions the line;
# death by the signal and the scratch directory gone on every version.
_have_py=yes
if ! command -v python3 >/dev/null 2>&1; then
    _have_py=no
    if [ -n "${CI:-}" ]; then
        assert_eq "CI has python3" "yes" "no"
    else
        echo "  SKIP: no python3, so no signal is sent"
    fi
fi
_sig_bin="$TMPDIR/sig-bin"
_sig_fix="$TMPDIR/sig-fixture"
mkdir -p "$_sig_bin" "$_sig_fix"
# Mktemp makes its directory with the real one and records it, so the
# script's scratch directory is known even when the run never gets to
# docker cp (macOS's mktemp -d ignores TMPDIR), and nothing is left.
_real_mktemp=$(command -v mktemp)
cat > "$_sig_bin/mktemp" <<EOF
#!/bin/bash
r=\$("$_real_mktemp" "\$@") || exit \$?
printf '%s\n' "\$r" >> "$_sig_fix/mktemp.log"
printf '%s\n' "\$r"
EOF
chmod +x "$_sig_bin/mktemp"
cat > "$_sig_bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    ps)
        printf '{"id":"%s","name":"%s","project":"%s","owner":"%s"}\n' \
            cid-1 costs-repo-agent-1 costs-repo "$_costs_owner" ;;
    inspect)
        case "\$3" in
            *Env*) echo "CLAUDE_MODEL=claude-opus-4-6" ;;
            *) echo "exited" ;;
        esac ;;
    cp)
        printf '%s\t%s\n' "\$3" "\$\$" > "$_sig_fix/ready.tmp"
        mv "$_sig_fix/ready.tmp" "$_sig_fix/ready"
        exec sleep 30 ;;
esac
EOF
chmod +x "$_sig_bin/docker"
cat > "$_sig_fix/sigrun.py" <<'EOF'
import os, shutil, signal, subprocess, sys, time
bash, script, cwd, ready, errfile, signame, made = sys.argv[1:8]
with open(errfile, "w") as err:
    p = subprocess.Popen([bash, script], cwd=cwd, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=err,
                         start_new_session=True)
def killgroup():
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
def sweep():
    # Whatever the recorded mktemp made and the run left: removed here,
    # after the assertions read the state.
    try:
        with open(made) as f:
            paths = [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        paths = []
    for d in paths:
        if os.path.isdir(d):
            shutil.rmtree(d, ignore_errors=True)
        elif os.path.lexists(d):
            os.remove(d)
try:
    deadline = time.time() + 20
    while time.time() < deadline and not os.path.exists(ready):
        if p.poll() is not None:
            break
        time.sleep(0.1)
    if not os.path.exists(ready):
        print("ready no")
        sys.exit(0)
    with open(ready) as f:
        dest, pid = f.read().rstrip("\n").split("\t")
    scratch = os.path.dirname(dest)
    print("ready yes")
    print("before", "yes" if os.path.isdir(scratch) else "no")
    os.kill(p.pid, getattr(signal, signame))
    time.sleep(0.3)
    try:
        os.kill(int(pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        rc = p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        print("rc timeout")
        sys.exit(0)
    print("rc", rc)
    print("after", "yes" if os.path.isdir(scratch) else "no")
finally:
    killgroup()
    sweep()
EOF
if [ "$_have_py" = yes ]; then
    for _b in $_bashes; do
        _bv=$("$_b" -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"')
        # shellcheck disable=SC2086  # major and minor as two words
        if [ "$(_guard $_bv)" = yes ]; then _sig_line=1; else _sig_line=0; fi
        for _sig in TERM:-15 HUP:-1; do
            _sn="$_b, SIG${_sig%%:*}"
            rm -f "$_sig_fix/ready" "$_sig_fix/mktemp.log"
            _sig_out=$(cd "$_costs_repo" \
                && PATH="$_sig_bin:$PATH" \
                    SWARM_RUNTIME_DIR="$TMPDIR/no-runtime" \
                    python3 "$_sig_fix/sigrun.py" "$_b" "$_costs_sh" \
                        "$_costs_repo" "$_sig_fix/ready" "$_sig_fix/err" \
                        "SIG${_sig%%:*}" "$_sig_fix/mktemp.log" 2>&1)
            assert_eq "$_sn: the run waits in docker cp" "yes" \
                "$(sed -n 's/^ready //p' <<< "$_sig_out")"
            assert_eq "$_sn:   its scratch directory there" "yes" \
                "$(sed -n 's/^before //p' <<< "$_sig_out")"
            assert_eq "$_sn:   it dies of the signal" \
                "${_sig#*:}" "$(sed -n 's/^rc //p' <<< "$_sig_out")"
            assert_eq "$_sn:   the line only before Bash 4.1" \
                "$_sig_line" \
                "$(grep -c 'swarm costs stopped before the end of its run' \
                    "$_sig_fix/err" || true)"
            assert_eq "$_sn:   the scratch directory goes" "no" \
                "$(sed -n 's/^after //p' <<< "$_sig_out")"
        done
    done
fi

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
