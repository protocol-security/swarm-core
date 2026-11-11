#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for control.sh, the control interface swarm-core.control/v1
# (USAGE, CONTROL INTERFACE): its grammar, version, the actions
# run by exec, and observe against a fake docker, with every field
# type-checked, every condition and reason, and the promise that a
# query changes nothing.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
TMPDIR=$(cd -P "$TMPDIR" && pwd -P)
export TMPDIR
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTROL="$REPO_ROOT/bin/control.sh"
IFACE="swarm-core.control/v1"
cleanup() {
    chmod -R u+rwx "$TMPDIR" 2>/dev/null || true
    rm -rf "$TMPDIR"
    [ -z "${LEGACY_TMP:-}" ] || rm -rf "$LEGACY_TMP"
}
trap cleanup EXIT
unset DOCKER_HOST DOCKER_CONTEXT XDG_STATE_HOME

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

# --- fixtures ---------------------------------------------------------
# A checkout with one commit, under a name of its own (its project id).
CO_NAME="ctl-repo-$$"
CO="$TMPDIR/$CO_NAME"
git init -q -b main "$CO"
git -C "$CO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m init
CK=$(cd -P "$CO" && pwd -P)
PJ="$CO_NAME"
BASE=$(git -C "$CO" rev-parse HEAD)
RT="$TMPDIR/rt"

# A fake docker: each call logged in $FD/log, answers from
# $FD/containers.jsonl (docker inspect objects) and $FD/volumes.jsonl;
# $FD/fail-<call> makes one kind of call fail, $FD/gone-<id or name>
# makes that object go between its listing and its inspection.
FD="$TMPDIR/fd"
FBIN="$TMPDIR/fbin"
mkdir -p "$FD" "$FBIN"
cat > "$FBIN/docker" <<'EOF'
#!/bin/bash
d="$FD"
printf '%s\n' "$*" >> "$d/log"
# The context each call was given; with $FD/switch, another terminal
# switches the current context to ctxb once it was read.
printf '%s|%s\n' "${DOCKER_CONTEXT:-}" "$1" >> "$d/ctxlog"
fails() { [ -e "$d/fail-$1" ]; }
case "$1 ${2:-}" in
    "context show")
        fails context && exit 1
        cat "$d/current" 2>/dev/null || echo ctxa
        if [ -e "$d/switch" ]; then
            rm -f "$d/switch"
            echo ctxb > "$d/current"
        fi
        exit 0 ;;
    "info -f")
        fails info && exit 1
        echo daemon-a; exit 0 ;;
esac
sub="$1"; shift
if [ "$sub" = container ] || [ "$sub" = volume ]; then
    sub="$sub $1"; shift
fi
quiet=false fmt="" filters="[]"
while [ $# -gt 0 ]; do
    case "$1" in
        -a|--no-trunc) ;;
        -q) quiet=true ;;
        -aq) quiet=true ;;
        --filter) filters=$(printf '%s' "$filters" | jq -c --arg f "$2" '. + [$f]'); shift ;;
        --format|-f) fmt="$2"; shift ;;
        *) break ;;
    esac
    shift
done
sel='def lab($kv): ($kv | index("=")) as $i
        | if $i == null then (.Config.Labels // .Labels // {}) | has($kv)
          else ((.Config.Labels // .Labels // {})[$kv[:$i]] // null)
              == $kv[$i + 1:] end;
    . as $o | select(all($f[]; . as $x
        | if startswith("label=") then $o | lab($x[6:])
          elif startswith("name=") then ($o.Name // "" | ltrimstr("/")
              | contains($x[5:]))
          elif startswith("id=") then ($o.Id // "" | startswith($x[3:]))
          else false end))'
case "$sub" in
    ps)
        fails ps && exit 1
        [ -s "$d/containers.jsonl" ] || exit 0
        jq -r --argjson f "$filters" --arg fmt "$fmt" --argjson q "$quiet" \
            "$sel"'
            | if $q or $fmt == "{{.ID}}" then .Id
              elif ($fmt | contains("\"owner\":")) then
                {id: .Id, name: (.Name | ltrimstr("/")),
                 project: (.Config.Labels["swarm-core.project"] // ""),
                 owner: (.Config.Labels["swarm-core.checkout"] // "")}
                | tojson
              else .Name | ltrimstr("/") end' "$d/containers.jsonl" \
            | while IFS= read -r line; do
                # Asked by id, one that went is not there.
                case "$filters" in
                    *'"id='*) [ -e "$d/gone-$line" ] && continue ;;
                esac
                printf '%s\n' "$line"
            done ;;
    "container inspect"|inspect)
        fails inspect && { echo "Cannot connect" >&2; exit 1; }
        [ -e "$d/gone-$1" ] && { echo "Error: No such object: $1" >&2; exit 1; }
        [ -e "$d/garbage-$1" ] && { echo "not json"; exit 0; }
        [ -e "$d/empty-$1" ] && exit 0
        o=$(jq -c --arg i "$1" 'select(.Id == $i)' "$d/containers.jsonl")
        [ -n "$o" ] || { echo "Error: No such object: $1" >&2; exit 1; }
        printf '[%s]\n' "$o" ;;
    "volume ls")
        fails vls && exit 1
        [ -s "$d/volumes.jsonl" ] || exit 0
        jq -r --argjson f "$filters" "$sel"' | .Name' "$d/volumes.jsonl" \
            | while IFS= read -r v; do
                if [ -e "$d/gone-$v" ] && [ -e "$d/listed-$v" ]; then
                    continue
                fi
                : > "$d/listed-$v"
                printf '%s\n' "$v"
            done ;;
    "volume inspect")
        fails vinspect && exit 1
        [ -e "$d/gone-$1" ] && { echo "Error: No such volume: $1" >&2; exit 1; }
        [ -e "$d/garbage-$1" ] && { echo "not json"; exit 0; }
        [ -e "$d/empty-$1" ] && exit 0
        o=$(jq -c --arg n "$1" 'select(.Name == $n)' "$d/volumes.jsonl")
        [ -n "$o" ] || exit 1
        printf '[%s]\n' "$o" ;;
    *) echo "fake docker: unexpected call: $sub $*" >&2; exit 99 ;;
esac
exit 0
EOF
chmod +x "$FBIN/docker"

# An empty Docker world, a fresh fixture directory.
fd_reset() {
    rm -rf "$FD"
    mkdir -p "$FD"
    : > "$FD/log"
    : > "$FD/ctxlog"
    : > "$FD/containers.jsonl"
    : > "$FD/volumes.jsonl"
}
fd_reset

# A full id for NAME.
full_id() {
    printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } \
        | cut -c1-64
}
# Add container NAME to the fake Docker: a numbered agent of this
# checkout's engagement e1, exited 0, changed by jq filter FILTER.
ctr() {
    local name="$1" filter="${2:-.}"
    jq -cn --arg n "$name" --arg id "$(full_id "$name")" --arg p "$PJ" \
        --arg c "$CK" '{Id: $id, Name: ("/" + $n),
        Created: "2026-01-01T00:00:00.000000001Z",
        Config: {Labels: {"swarm-core.project": $p,
            "swarm-core.checkout": $c, "swarm-core.engagement": "e1",
            "swarm-core.engagement-token": "aaaaaaaaaaaaaaaa",
            "swarm-core.role": "agent", "swarm-core.profile-index": "1",
            "swarm-core.agent-number": "1", "swarm-core.nonce": "x"}},
        State: {Status: "exited", Error: "", ExitCode: 0,
            OOMKilled: false, StartedAt: "2026-01-01T00:00:01Z",
            FinishedAt: "2026-01-01T00:01:00Z"}}' \
        | jq -c "$filter" >> "$FD/containers.jsonl"
}
# Add workspace volume NAME, of this checkout's engagement e1, made for
# container FOR, changed by jq filter FILTER.
vol() {
    local name="$1" for="$2" filter="${3:-.}"
    jq -cn --arg n "$name" --arg f "$for" --arg p "$PJ" --arg c "$CK" \
        '{Name: $n, Labels: {"swarm-core.project": $p,
        "swarm-core.checkout": $c, "swarm-core.engagement": "e1",
        "swarm-core.engagement-token": "aaaaaaaaaaaaaaaa",
        "swarm-core.container": $f, "swarm-core.kind": "agent",
        "swarm-core.context": "full", "swarm-core.nonce": "y"}}' \
        | jq -c "$filter" >> "$FD/volumes.jsonl"
}

# A runtime directory of this checkout, with state STATE (a jq filter on
# the owner record; "none" for no state file).
rt_reset() {
    chmod -R u+rwx "$RT" 2>/dev/null || true
    rm -rf "$RT"
    mkdir -m 700 "$RT"
    if [ "${1:-.}" != none ]; then
        jq -cn --arg p "$PJ" --arg c "$CK" \
            '{schema: "swarm-core.state/v1", project: $p, repo_root: $c}' \
            | jq -c "${1:-.}" > "$RT/state.json"
        chmod 600 "$RT/state.json"
    fi
}
ENGAGED='.engagement_id = "e1" | .engagement_token = "aaaaaaaaaaaaaaaa"
    | .engagement_started_at = "2026-01-01T00:00:00Z"
    | .base_commit = "'"$BASE"'" | .docker_daemon = "daemon-a"'

# Run control.sh with ARGS in the checkout (or in directory $IN), the
# fake docker first on PATH; stdout to $TMPDIR/out, stderr to
# $TMPDIR/err; print the status.
ctl() {
    local rc=0
    (cd "${IN:-$CO}" && PATH="$FBIN:$PATH" FD="$FD" SWARM_RUNTIME_DIR="$RT" \
        "$BASH" "$CONTROL" "$@" > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
    printf '%s' "$rc"
}
obs() { ctl --interface "$IFACE" observe; }
# jq EXPR on the last document.
q() { jq -c "$1" "$TMPDIR/out" 2>/dev/null; }
qr() { jq -r "$1" "$TMPDIR/out" 2>/dev/null; }

# Every field of the observation, with its type and nullability, as
# USAGE gives them: "valid" or the first field that is not.
# shellcheck disable=SC2016
TYPES='def str: type == "string";
def ostr: . == null or type == "string";
def oint: . == null or (type == "number" and . == floor);
def int: type == "number" and . == floor;
def obj($k): type == "object" and keys == ($k | sort);
def check($name; c): if c then empty else $name end;
[
 check("top"; obj(["schema", "interface", "engine", "observed_at",
     "project", "checkout", "runtime_dir", "docker", "conditions",
     "engagement", "containers", "workspaces"])),
 check("schema"; .schema == "swarm-core.observation/v1"),
 check("interface"; .interface == "swarm-core.control/v1"),
 check("engine"; .engine | str),
 check("observed_at"; .observed_at | str
     and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")),
 check("project"; .project | str),
 check("checkout"; .checkout | str),
 check("runtime_dir"; .runtime_dir | str),
 check("docker"; .docker | obj(["context", "daemon"])
     and (.context | ostr) and (.daemon | ostr)),
 check("conditions"; .conditions | type == "array" and all(.[]; str)
     and . == unique),
 check("engagement"; .engagement == null or (.engagement
     | obj(["id", "token", "started_at", "base_commit", "docker_daemon",
            "revision", "complete", "target", "cleanup_checkpoint"])
     and (.id | str) and (.token | ostr) and (.started_at | ostr)
     and (.base_commit | ostr) and (.docker_daemon | ostr)
     and (.revision | str) and (.complete | type == "boolean")
     and (.target == null or (.target
         | obj(["repo", "rev", "commit", "format", "base"])
         and (.repo | str) and (.rev | str) and (.commit | str)
         and (.format | str)
         and (.base == null or (.base | obj(["repo", "rev", "commit"])
             and all(.[]; str)))))
     and (.cleanup_checkpoint == null or (.cleanup_checkpoint
         | obj(["recorded_at", "run_count"]) and (.recorded_at | str)
         and (.run_count | int))))),
 check("containers"; .containers == null or (.containers
     | type == "array" and . == sort_by(.name) and all(.[];
         obj(["id", "name", "role", "profile_index", "agent_number",
              "engagement", "engagement_token", "state", "error",
              "exit_code", "oom_killed", "created_at", "started_at",
              "finished_at"])
         and (.id | str) and (.name | str) and (.role | ostr)
         and (.profile_index | oint) and (.agent_number | oint)
         and (.engagement | ostr) and (.engagement_token | ostr)
         and (.state | str) and (.error | ostr) and (.exit_code | oint)
         and (.oom_killed | type == "boolean") and (.created_at | str)
         and (.started_at | ostr) and (.finished_at | ostr)))),
 check("workspaces"; .workspaces == null or (.workspaces
     | type == "array" and . == sort_by(.volume) and all(.[];
         obj(["volume", "container", "kind", "engagement",
              "engagement_token"])
         and (.volume | str) and (.container | ostr) and (.kind | ostr)
         and (.engagement | ostr) and (.engagement_token | ostr))))
] | first // "valid"'
# Check the last observe: status 0, empty stderr, one document of the
# right types.
obs_ok() {
    local label="$1" rc="$2"
    assert_eq "$label: exits 0" "0" "$rc"
    assert_eq "$label: nothing on stderr" "" "$(cat "$TMPDIR/err")"
    assert_eq "$label: one document, fields typed" "valid" \
        "$(jq -s -r 'if length == 1 then .[0] else error("count") end
            | '"$TYPES" "$TMPDIR/out" 2>/dev/null || echo invalid)"
}
# Check the last query failed: status 1, nothing on stdout, and the
# reason line first on stderr.
refused() {
    local label="$1" reason="$2" rc="$3"
    assert_eq "$label: exits 1" "1" "$rc"
    assert_eq "$label: nothing on stdout" "" "$(cat "$TMPDIR/out")"
    assert_eq "$label: reason $reason first on stderr" "true" \
        "$(head -n 1 "$TMPDIR/err" | grep -q "^swarm-core: ${reason}: ." \
            && echo true || echo false)"
}
# Check the last call was a usage error: status 2, nothing on stdout,
# one line on stderr, nothing read.
usage_err() {
    local label="$1" reason="$2" rc="$3"
    assert_eq "$label: exits 2" "2" "$rc"
    assert_eq "$label: nothing on stdout" "" "$(cat "$TMPDIR/out")"
    assert_eq "$label: one line, reason $reason" "true" \
        "$([ "$(wc -l < "$TMPDIR/err" | tr -d ' ')" = 1 ] \
            && grep -q "^swarm-core: ${reason}: ." "$TMPDIR/err" \
            && echo true || echo false)"
    assert_eq "$label: no Docker call" "" "$(cat "$FD/log")"
}

echo "=== 1. Grammar ==="
fd_reset
rc=$(ctl --help)
assert_eq "--help exits 0" "0" "$rc"
assert_eq "with the grammar on stdout" "true" \
    "$(grep -qF -- "--interface ${IFACE} COMMAND" "$TMPDIR/out" \
        && echo true || echo false)"
rc=$(ctl)
usage_err "no argument" usage "$rc"
rc=$(ctl observe)
usage_err "no interface" usage "$rc"
rc=$(ctl start)
usage_err "an action without an interface" usage "$rc"
rc=$(ctl --interface)
usage_err "--interface without a value" usage "$rc"
rc=$(ctl --interface swarm-core.control/v2 observe)
usage_err "another interface" unsupported-interface "$rc"
rc=$(ctl --interface "" start)
usage_err "an empty interface" unsupported-interface "$rc"
rc=$(ctl --interface=swarm-core.control/v1 observe)
usage_err "--interface=VALUE (one argument)" usage "$rc"
rc=$(ctl --interface "$IFACE")
usage_err "an interface and no command" usage "$rc"
for c in nope status logs costs dashboard progress $'bad\nsecond line'; do
    rc=$(ctl --interface "$IFACE" "$c")
    usage_err "$(printf '%q' "$c") is no v1 command" usage "$rc"
done
rc=$(ctl --interface "$IFACE" observe extra)
usage_err "observe takes no argument" usage "$rc"
rc=$(ctl version extra)
usage_err "version takes no argument" usage "$rc"
rc=$(ctl --interface "$IFACE" version extra)
usage_err "version (with the interface) takes no argument" usage "$rc"

echo ""
echo "=== 2. version ==="
WANT_VERSION=$(jq -cn --arg v "$(cat "$REPO_ROOT/VERSION")" \
    '{schema: "swarm-core.version/v1", engine: $v,
      interfaces: ["swarm-core.control/v1"]}')
fd_reset
rc=$(IN=/ ctl version)
assert_eq "version outside any checkout: exits 0" "0" "$rc"
assert_eq "  prints the version document" "$WANT_VERSION" \
    "$(jq -c . "$TMPDIR/out" 2>/dev/null)"
assert_eq "  one line" "1" "$(wc -l < "$TMPDIR/out" | tr -d ' ')"
assert_eq "  nothing on stderr" "" "$(cat "$TMPDIR/err")"
assert_eq "  no Docker call" "" "$(cat "$FD/log")"
rc=$(ctl --interface "$IFACE" version)
assert_eq "version with the interface: the same" "0|$WANT_VERSION" \
    "$rc|$(jq -c . "$TMPDIR/out" 2>/dev/null)"
# Run by a relative path with CDPATH exported, which makes cd print
# where it goes.
mkdir -p "$TMPDIR/rel/bin"
cp -R "$REPO_ROOT/lib" "$REPO_ROOT/VERSION" "$TMPDIR/rel/"
cp "$REPO_ROOT/bin/control.sh" "$TMPDIR/rel/bin/"
rc=0
(cd "$TMPDIR" && CDPATH=. "$BASH" rel/bin/control.sh version > "$TMPDIR/out" \
    2> "$TMPDIR/err") || rc=$?
assert_eq "version by a relative path, CDPATH set" "0|$WANT_VERSION|" \
    "$rc|$(jq -c . "$TMPDIR/out" 2>/dev/null)|$(cat "$TMPDIR/err")"
# An engine without its VERSION file.
E2="$TMPDIR/engine-noversion"
mkdir -p "$E2/bin"
cp -R "$REPO_ROOT/lib" "$E2/"
cp "$REPO_ROOT/bin/control.sh" "$E2/bin/"
rc=0
(cd / && "$BASH" "$E2/bin/control.sh" version > "$TMPDIR/out" \
    2> "$TMPDIR/err") || rc=$?
refused "no VERSION file" engine-unreadable "$rc"
printf 'not a "version"\n' > "$E2/VERSION"
rc=0
(cd / && "$BASH" "$E2/bin/control.sh" version > "$TMPDIR/out" \
    2> "$TMPDIR/err") || rc=$?
refused "a VERSION file that holds no version" engine-unreadable "$rc"
# An engine without one of the files observe reads: the reason first,
# and nothing else on stderr.
E3="$TMPDIR/engine-nolib"
mkdir -p "$E3/bin"
cp -R "$REPO_ROOT/lib" "$REPO_ROOT/VERSION" "$E3/"
cp "$REPO_ROOT/bin/control.sh" "$E3/bin/"
rm -f "$E3/lib/target.sh"
rc=0
(cd "$CO" && "$BASH" "$E3/bin/control.sh" --interface "$IFACE" observe \
    > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
refused "an engine without lib/target.sh" engine-unreadable "$rc"
assert_eq "  one line on stderr" "1" "$(wc -l < "$TMPDIR/err" | tr -d ' ')"

echo ""
echo "=== 3. Actions run by exec ==="
# An engine whose launch.sh and harvest.sh only report how they were
# run: their pid, arguments, directory, environment, descriptor 3,
# standard input; they exit with PROBE_STATUS.
E="$TMPDIR/engine"
mkdir -p "$E/bin"
cp -R "$REPO_ROOT/lib" "$REPO_ROOT/VERSION" "$E/"
cp "$REPO_ROOT/bin/control.sh" "$E/bin/"
for s in launch.sh harvest.sh; do
    cat > "$E/bin/$s" <<'EOF'
#!/bin/bash
{
    echo "script=${0##*/}"
    echo "pid=$$"
    printf 'arg=%s\n' "$@"
    echo "argc=$#"
    echo "cwd=$(pwd -P)"
    echo "marker=${CTL_MARKER:-}"
    if { true >&3; } 2>/dev/null; then echo "fd3=open"; else echo "fd3=closed"; fi
    if [ -t 0 ]; then
        echo "tty=yes"
    else
        echo "tty=no"
        IFS= read -r line || true
        echo "stdin=${line:-}"
    fi
} > "$PROBE_OUT"
exit "${PROBE_STATUS:-0}"
EOF
    chmod +x "$E/bin/$s"
done
D="$TMPDIR/somewhere"
mkdir -p "$D"
D=$(cd -P "$D" && pwd -P)
PROBE_OUT="$TMPDIR/probe"
export PROBE_OUT
for c in start stop wait post-process retire cleanup interactive chat \
        shell harvest; do
    rm -f "$PROBE_OUT"
    rc=0
    printf 'line on stdin\n' | (cd "$D" && CTL_MARKER=m-$c PROBE_STATUS=7 \
        exec "$E/bin/control.sh" --interface "$IFACE" "$c" --x "a b" "" \
        3> "$TMPDIR/fd3" > /dev/null) &
    pid=$!
    wait "$pid" || rc=$?
    case "$c" in
        harvest) want_script=harvest.sh; want_args=$'arg=--x\narg=a b\narg=' ;;
        *) want_script=launch.sh; want_args="arg=$c"$'\narg=--x\narg=a b\narg=' ;;
    esac
    assert_eq "$c: runs $want_script" "script=$want_script" \
        "$(grep '^script=' "$PROBE_OUT" 2>/dev/null)"
    assert_eq "$c: in the same process (exec)" "pid=$pid" \
        "$(grep '^pid=' "$PROBE_OUT" 2>/dev/null)"
    assert_eq "$c: with its arguments exactly" "$want_args" \
        "$(grep '^arg=' "$PROBE_OUT" 2>/dev/null)"
    assert_eq "$c: in the caller's directory" "cwd=$D" \
        "$(grep '^cwd=' "$PROBE_OUT" 2>/dev/null)"
    assert_eq "$c: with the caller's environment" "marker=m-$c" \
        "$(grep '^marker=' "$PROBE_OUT" 2>/dev/null)"
    assert_eq "$c: its descriptors" "fd3=open" \
        "$(grep '^fd3=' "$PROBE_OUT" 2>/dev/null)"
    assert_eq "$c: and standard input" "stdin=line on stdin" \
        "$(grep '^stdin=' "$PROBE_OUT" 2>/dev/null)"
    assert_eq "$c: its exit status" "7" "$rc"
done
# Actions read nothing first: no swarmfile, Git or Docker call, even
# outside a checkout.
fd_reset
rm -f "$PROBE_OUT"
rc=0
(cd / && PATH="$FBIN:$PATH" FD="$FD" PROBE_STATUS=0 \
    "$E/bin/control.sh" --interface "$IFACE" retire < /dev/null \
    > /dev/null 2>&1) || rc=$?
assert_eq "an action outside a checkout still runs" "0|script=launch.sh" \
    "$rc|$(grep '^script=' "$PROBE_OUT" 2>/dev/null)"
assert_eq "  with no Docker call first" "" "$(cat "$FD/log")"
# The terminal reaches the action (script(1) gives it one).
rm -f "$PROBE_OUT"
if script -q /dev/null true </dev/null >/dev/null 2>&1; then
    script -q /dev/null "$E/bin/control.sh" --interface "$IFACE" shell \
        </dev/null >/dev/null 2>&1 || true
elif script -qec true /dev/null </dev/null >/dev/null 2>&1; then
    script -qec "'$E/bin/control.sh' --interface '$IFACE' shell" /dev/null \
        </dev/null >/dev/null 2>&1 || true
fi
if [ -e "$PROBE_OUT" ]; then
    assert_eq "an interactive action keeps the terminal" "tty=yes" \
        "$(grep '^tty=' "$PROBE_OUT")"
else
    echo "  SKIP: no script(1) here to give the action a terminal"
fi

echo ""
echo "=== 4. observe: what the state records ==="
# No runtime directory.
fd_reset
rm -rf "$RT"
rc=$(obs)
obs_ok "no runtime directory" "$rc"
assert_eq "  the envelope" \
    "[\"swarm-core.observation/v1\",\"$IFACE\",\"$(cat "$REPO_ROOT/VERSION")\",\"$PJ\",\"$CK\",\"$RT\"]" \
    "$(q '[.schema, .interface, .engine, .project, .checkout, .runtime_dir]')"
assert_eq "  no engagement, no conditions, empty lists" \
    '[null,[],[],[]]' "$(q '[.engagement, .conditions, .containers, .workspaces]')"
assert_eq "  the context and the daemon" '{"context":"ctxa","daemon":"daemon-a"}' \
    "$(q .docker)"
assert_eq "  nothing made" "no" "$([ -e "$RT" ] && echo yes || echo no)"
# A runtime directory without a state file, and one that only records
# its owner.
rt_reset none
rc=$(obs)
obs_ok "a runtime directory without state" "$rc"
assert_eq "  no engagement" "null" "$(q .engagement)"
rt_reset
rc=$(obs)
obs_ok "an owner record" "$rc"
assert_eq "  no engagement" "null" "$(q .engagement)"
# An engagement whose bare repo is not there.
rt_reset "$ENGAGED"
rc=$(obs)
obs_ok "an engagement, no bare repo" "$rc"
assert_eq "  its fields" \
    "{\"id\":\"e1\",\"token\":\"aaaaaaaaaaaaaaaa\",\"started_at\":\"2026-01-01T00:00:00Z\",\"base_commit\":\"$BASE\",\"docker_daemon\":\"daemon-a\",\"complete\":false,\"target\":null,\"cleanup_checkpoint\":null}" \
    "$(q '.engagement | del(.revision)')"
assert_eq "  a revision of 64 hex digits" "true" \
    "$(q '.engagement.revision | test("^[0-9a-f]{64}$")')"
REV1=$(qr .engagement.revision)
rc=$(obs)
assert_eq "  the same state, the same revision" "$REV1" \
    "$(qr .engagement.revision)"
# Its bare repo, published: complete.
git clone -q --bare "$CO" "$RT/upstream.git"
rc=$(obs)
obs_ok "a published bare repo" "$rc"
assert_eq "  complete" "true" "$(q .engagement.complete)"
assert_eq "  the revision is the state's, not the bare repo's" "$REV1" \
    "$(qr .engagement.revision)"
# upstream.git.new beside it does not count, and a broken one is not
# complete.
rm -rf "$RT/upstream.git"
git clone -q --bare "$CO" "$RT/upstream.git.new"
rc=$(obs)
assert_eq "an unpublished bare repo: not complete" "false" \
    "$(q .engagement.complete)"
rm -rf "$RT/upstream.git.new"
mkdir "$RT/upstream.git"
rc=$(obs)
assert_eq "an empty directory: not complete" "0|false" \
    "$rc|$(q .engagement.complete)"
rmdir "$RT/upstream.git"
# Another state, another revision.
rt_reset "$ENGAGED | .engagement_token = \"bbbbbbbbbbbbbbbb\""
rc=$(obs)
assert_eq "another state: another revision" "true" \
    "$([ "$(qr .engagement.revision)" != "$REV1" ] && echo true || echo false)"
# A target, without and with a base.
TGT='.target = {repo: "https://example.com/t.git", repo_physical: "x",
    rev: "main", commit: "'"$BASE"'", base_repo: null,
    base_repo_physical: null, base_rev: null, base_commit: null,
    format: "sha1"}'
rt_reset "$ENGAGED | $TGT"
rc=$(obs)
obs_ok "a target" "$rc"
assert_eq "  as recorded, without its private fields" \
    "{\"repo\":\"https://example.com/t.git\",\"rev\":\"main\",\"commit\":\"$BASE\",\"format\":\"sha1\",\"base\":null}" \
    "$(q .engagement.target)"
rt_reset "$ENGAGED | $TGT | .target.base_repo = \"/b\"
    | .target.base_repo_physical = \"/b\" | .target.base_rev = \"v1\"
    | .target.base_commit = \"$BASE\""
rc=$(obs)
obs_ok "a target with a base" "$rc"
assert_eq "  its base" "{\"repo\":\"/b\",\"rev\":\"v1\",\"commit\":\"$BASE\"}" \
    "$(q .engagement.target.base)"
# A cleanup checkpoint.
rt_reset "$ENGAGED | .cleanup = {engagement: \"e1\",
    started_at: \"2026-01-02T00:00:00Z\", runs: [{}, {}]}"
rc=$(obs)
obs_ok "a cleanup checkpoint" "$rc"
assert_eq "  its time and its runs" \
    '{"recorded_at":"2026-01-02T00:00:00Z","run_count":2}' \
    "$(q .engagement.cleanup_checkpoint)"
assert_eq "  cleanup-pending" '["cleanup-pending"]' "$(q .conditions)"
# An earlier release's engagement: no daemon, no token.
rt_reset "$ENGAGED | del(.docker_daemon, .engagement_token)"
rc=$(obs)
obs_ok "an earlier release's engagement" "$rc"
assert_eq "  its token and daemon are null" '[null,null]' \
    "$(q '[.engagement.token, .engagement.docker_daemon]')"
assert_eq "  legacy-engagement" '["legacy-engagement"]' "$(q .conditions)"
rt_reset "$ENGAGED | del(.docker_daemon, .engagement_token,
    .engagement_started_at, .base_commit)"
rc=$(obs)
obs_ok "an older record still" "$rc"
assert_eq "  what it lacks is null" '[null,null]' \
    "$(q '[.engagement.started_at, .engagement.base_commit]')"
rt_reset "$ENGAGED | .engagement_token = \"\""
rc=$(obs)
assert_eq "an empty recorded token is null" "0|null" \
    "$rc|$(q .engagement.token)"

echo ""
echo "=== 5. observe: reasons ==="
fd_reset
rc=$(IN=/ obs)
refused "outside a checkout" not-a-checkout "$rc"
rc=$(SWARM_PROJECT="Not An Id" obs)
refused "an invalid SWARM_PROJECT" bad-environment "$rc"
rc=0
(cd "$CO" && PATH="$FBIN:$PATH" FD="$FD" SWARM_RUNTIME_DIR=relative/rt \
    "$BASH" "$CONTROL" --interface "$IFACE" observe > "$TMPDIR/out" \
    2> "$TMPDIR/err") || rc=$?
refused "a relative SWARM_RUNTIME_DIR" bad-environment "$rc"
# Places the runtime directory cannot be (start refuses them too): in
# the checkout or its git dir, a relative path from HOME, HOME itself.
for d in "$CO/runtime" "$CO/.git/rt"; do
    rc=0
    (cd "$CO" && PATH="$FBIN:$PATH" FD="$FD" SWARM_RUNTIME_DIR="$d" \
        "$BASH" "$CONTROL" --interface "$IFACE" observe > "$TMPDIR/out" \
        2> "$TMPDIR/err") || rc=$?
    refused "a runtime directory at ${d#"$TMPDIR"/}" bad-environment "$rc"
done
rc=0
(cd "$CO" && env -u SWARM_RUNTIME_DIR -u XDG_STATE_HOME HOME=relative \
    PATH="$FBIN:$PATH" FD="$FD" "$BASH" "$CONTROL" --interface "$IFACE" \
    observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
refused "a relative HOME" bad-environment "$rc"
mkdir -m 700 "$TMPDIR/home"
rc=0
(cd "$CO" && HOME="$TMPDIR/home" SWARM_RUNTIME_DIR="$TMPDIR/home" \
    PATH="$FBIN:$PATH" FD="$FD" "$BASH" "$CONTROL" --interface "$IFACE" \
    observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
refused "the runtime directory at HOME" bad-environment "$rc"
rt_reset
chmod 755 "$RT"
rc=$(obs)
refused "a runtime directory others can enter" runtime-unsafe "$rc"
chmod 700 "$RT"
mv "$RT" "$RT.real"
ln -s "$RT.real" "$RT"
rc=$(obs)
refused "a runtime directory that is a link" runtime-unsafe "$rc"
rm -f "$RT"
mv "$RT.real" "$RT"
rt_reset '.repo_root = "/elsewhere"'
rc=$(obs)
refused "another checkout's runtime directory" runtime-foreign "$rc"
rt_reset '.project = "other"'
rc=$(obs)
refused "another project's runtime directory" runtime-foreign "$rc"
for bad in 'not json' '{"schema": "swarm-core.state/v1"} {}' \
        '{"schema": "swarm-core.state/v0"}' '[1]' '"x"'; do
    rt_reset
    printf '%s\n' "$bad" > "$RT/state.json"
    rc=$(obs)
    refused "a state file of $(printf '%q' "$bad")" state-unreadable "$rc"
done
for f in '.engagement_id = 5' '.engagement_token = {}' \
        '.docker_daemon = []' '.repo_root = 1' '.base_commit = true' \
        '.cleanup = "x"' '.cleanup = {runs: []}' \
        '.cleanup = {started_at: "t", runs: 3}' \
        '.target = {repo: "x"}' '.target = 5'; do
    rt_reset "$ENGAGED | $f"
    rc=$(obs)
    refused "a field of the wrong type ($f)" state-unreadable "$rc"
done
rt_reset none
mkdir "$RT/state.json"
rc=$(obs)
refused "a state file that is a directory" state-unreadable "$rc"
rmdir "$RT/state.json"
rt_reset "$ENGAGED"
mv "$RT/state.json" "$RT/state.real"
ln -s state.real "$RT/state.json"
rc=$(obs)
refused "a state file that is a link" state-unreadable "$rc"
# Missing tools: jq first.
mkdir -p "$TMPDIR/minbin"
for t in dirname date; do
    ln -sf "$(command -v "$t")" "$TMPDIR/minbin/$t"
done
rc=0
(cd "$CO" && PATH="$TMPDIR/minbin" "$BASH" "$CONTROL" --interface "$IFACE" \
    observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
refused "no jq" missing-tool "$rc"

echo ""
echo "=== 6. observe: conditions of the files ==="
fd_reset
# Mirrors: an earlier release's, a manifest cut off, a damaged one, one
# that is a link; a valid manifest is no condition.
rt_reset "$ENGAGED"
mkdir -m 755 "$RT/mirrors"
mkdir "$RT/mirrors/sub_a.git"
rc=$(obs)
obs_ok "mirrors without a manifest" "$rc"
assert_eq "  legacy-mirrors" '["legacy-mirrors"]' "$(q .conditions)"
rm -rf "$RT/mirrors"/*
jq -cn --arg b "$BASE" '{schema: "swarm-core.mirrors/v1", base: $b,
    mirrors: []}' > "$RT/mirrors/manifest.json"
rc=$(obs)
assert_eq "a valid manifest: no condition" "0|[]" "$rc|$(q .conditions)"
cp "$RT/mirrors/manifest.json" "$RT/mirrors/manifest.json.new"
rc=$(obs)
assert_eq "a manifest.json.new: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
rm -f "$RT/mirrors/manifest.json.new"
jq -cn '{schema: "swarm-core.mirrors/v1",
    base: "0000000000000000000000000000000000000000", mirrors: []}' \
    > "$RT/mirrors/manifest.json"
rc=$(obs)
assert_eq "a manifest of another base: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
printf '{' > "$RT/mirrors/manifest.json"
rc=$(obs)
assert_eq "a manifest that is no JSON: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
rm -f "$RT/mirrors/manifest.json"
ln -s /dev/null "$RT/mirrors/manifest.json"
rc=$(obs)
assert_eq "a manifest that is a link: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
rm -rf "$RT/mirrors"
ln -s "$TMPDIR" "$RT/mirrors"
rc=$(obs)
assert_eq "mirrors that are a link: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
rm -f "$RT/mirrors"
# A manifest's mirrors, as post-process checks them before it mounts
# them: one complete is no condition; one gone, mirrors-missing (an
# interactive session that joins can make it again); one cut off while
# it was made, without its commit, or a link, and a name that is none,
# mirrors-incomplete.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
mkdir -m 755 "$RT/mirrors"
git clone -q --bare "$CO" "$RT/mirrors/1.git"
git --git-dir="$RT/mirrors/1.git" update-ref refs/swarm/gitlink "$BASE"
jq -cn --arg b "$BASE" --arg n "$(b64 lib/x)" '{schema:
    "swarm-core.mirrors/v1", base: $b, mirrors: [{id: 1, parent: 0,
    name: $n, path: $n, commit: $b}]}' > "$RT/mirrors/manifest.json"
rc=$(obs)
assert_eq "a complete mirror: no condition" '0|[]' "$rc|$(q .conditions)"
mv "$RT/mirrors/1.git" "$RT/mirrors/1.keep"
rc=$(obs)
assert_eq "a listed mirror gone: mirrors-missing" '0|["mirrors-missing"]' \
    "$rc|$(q .conditions)"
mkdir "$RT/mirrors/1.git.new"
rc=$(obs)
assert_eq "one cut off while it was made: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
rmdir "$RT/mirrors/1.git.new"
mv "$RT/mirrors/1.keep" "$RT/mirrors/1.git"
git --git-dir="$RT/mirrors/1.git" update-ref -d refs/swarm/gitlink
rc=$(obs)
assert_eq "a mirror without its commit: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
git --git-dir="$RT/mirrors/1.git" update-ref refs/swarm/gitlink "$BASE"
mv "$RT/mirrors/1.git" "$RT/mirrors/1.real"
ln -s 1.real "$RT/mirrors/1.git"
rc=$(obs)
assert_eq "a mirror that is a link: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
rm -f "$RT/mirrors/1.git"
mv "$RT/mirrors/1.real" "$RT/mirrors/1.git"
jq -c '.mirrors[0].name = "AA=="' "$RT/mirrors/manifest.json" \
    > "$RT/mirrors/m.x" && mv "$RT/mirrors/m.x" "$RT/mirrors/manifest.json"
rc=$(obs)
assert_eq "a name that is a NUL: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
# Without the engagement's base, the manifest's form is checked.
rt_reset "$ENGAGED | del(.base_commit)"
mkdir -m 755 "$RT/mirrors"
printf '{' > "$RT/mirrors/manifest.json"
rc=$(obs)
assert_eq "no base, a manifest that is no JSON: mirrors-incomplete" \
    '0|["mirrors-incomplete"]' "$rc|$(q .conditions)"
jq -cn '{schema: "swarm-core.mirrors/v1", base: "x", mirrors: []}' \
    > "$RT/mirrors/manifest.json"
rc=$(obs)
assert_eq "no base, a manifest of the right form: no condition" '0|[]' \
    "$rc|$(q .conditions)"
# What is left of an engagement none records.
rt_reset
for e in upstream.git upstream.git.new mirrors target.git x.removing \
        .hidden.removing; do
    mkdir "$RT/$e"
    rc=$(obs)
    assert_eq "no engagement, $e there: unrecorded-leftovers" \
        '0|["unrecorded-leftovers"]' "$rc|$(q .conditions)"
    rmdir "$RT/$e"
done
mkdir "$RT/.target-fetch.x"
rc=$(obs)
assert_eq "target scratch is no leftover" '0|[]' "$rc|$(q .conditions)"
rmdir "$RT/.target-fetch.x"
# State an earlier release left in /tmp, under the checkout's directory
# name.
LEGACY_TMP="/tmp/$(printf '%s' "$CO_NAME" | tr '[:upper:]' '[:lower:]')-upstream.git"
if [ ! -e "$LEGACY_TMP" ]; then
    mkdir "$LEGACY_TMP"
    rc=$(obs)
    assert_eq "an earlier release's /tmp state: legacy-tmp-state" \
        '0|["legacy-tmp-state"]' "$rc|$(q .conditions)"
    rmdir "$LEGACY_TMP"
else
    echo "  SKIP: $LEGACY_TMP is there already"
fi
LEGACY_TMP=""

echo ""
echo "=== 7. observe: Docker ==="
# Containers: this checkout's, sorted by name, every field; others left
# out.
rt_reset "$ENGAGED"
fd_reset
ctr "${PJ}-agent-2" '.State.Status = "running" | .State.ExitCode = 0
    | .State.FinishedAt = "0001-01-01T00:00:00Z"
    | .Config.Labels["swarm-core.agent-number"] = "2"'
ctr "${PJ}-agent-1" '.State.ExitCode = 3'
ctr "${PJ}-agent-10" '.State.Status = "created"
    | .State.Error = "no such image"
    | .State.StartedAt = "0001-01-01T00:00:00Z"
    | .State.FinishedAt = "0001-01-01T00:00:00Z"
    | .Config.Labels["swarm-core.agent-number"] = "10"
    | .Config.Labels["swarm-core.profile-index"] = "2"'
ctr "${PJ}-agent-post" '.State.Status = "dead" | .State.ExitCode = 137
    | .State.OOMKilled = true
    | .Config.Labels["swarm-core.role"] = "post-process"
    | .Config.Labels["swarm-core.profile-index"] = ""
    | .Config.Labels["swarm-core.agent-number"] = ""'
ctr "${PJ}-agent-interactive-b-1" '.State.Status = "paused"
    | .Config.Labels["swarm-core.role"] = "shell"
    | .Config.Labels["swarm-core.profile-index"] = "3"
    | .Config.Labels["swarm-core.agent-number"] = ""'
ctr "${PJ}-agent-3" '.Config.Labels |= with_entries(select(.key
    | IN("swarm-core.project", "swarm-core.checkout")))'
ctr "${PJ}-agent-renamed-later" '.Config.Labels["swarm-core.role"] = "agent-x"
    | .Config.Labels["swarm-core.profile-index"] = "one"
    | .Config.Labels["swarm-core.agent-number"] = "0"'
ctr "other-agent-1" '.Config.Labels["swarm-core.project"] = "other"'
ctr "${PJ}-agent-retire-check" '.Config.Labels["swarm-core.project"] = ""
    | .Config.Labels["swarm-core.checkout"] = ""'
rc=$(obs)
obs_ok "containers" "$rc"
assert_eq "  this checkout's, sorted by name" \
    "[\"${PJ}-agent-1\",\"${PJ}-agent-10\",\"${PJ}-agent-2\",\"${PJ}-agent-3\",\"${PJ}-agent-interactive-b-1\",\"${PJ}-agent-post\",\"${PJ}-agent-renamed-later\"]" \
    "$(q '[.containers[].name]')"
assert_eq "  a full id" "$(full_id "${PJ}-agent-1")" \
    "$(qr '.containers[0].id')"
assert_eq "  an exited agent" \
    '{"role":"agent","profile_index":1,"agent_number":1,"engagement":"e1","engagement_token":"aaaaaaaaaaaaaaaa","state":"exited","error":null,"exit_code":3,"oom_killed":false,"created_at":"2026-01-01T00:00:00.000000001Z","started_at":"2026-01-01T00:00:01Z","finished_at":"2026-01-01T00:01:00Z"}' \
    "$(q '.containers[0] | del(.id, .name)')"
assert_eq "  one that never started: its error, no times, no exit code" \
    '["created","no such image",null,null,null,2,10]' \
    "$(q '.containers[1] | [.state, .error, .exit_code, .started_at,
        .finished_at, .profile_index, .agent_number]')"
assert_eq "  a running one: no exit code, no finish" \
    '["running",null,null,2]' \
    "$(q '.containers[2] | [.state, .exit_code, .finished_at, .agent_number]')"
assert_eq "  an earlier release's: no role, profile, number or engagement" \
    '[null,null,null,null,null]' \
    "$(q '.containers[3] | [.role, .profile_index, .agent_number,
        .engagement, .engagement_token]')"
assert_eq "  a shell session" '["paused","shell",3,null,null]' \
    "$(q '.containers[4] | [.state, .role, .profile_index, .agent_number,
        .exit_code]')"
assert_eq "  post-process, dead, out of memory" \
    '["dead","post-process",null,null,137,true]' \
    "$(q '.containers[5] | [.state, .role, .profile_index, .agent_number,
        .exit_code, .oom_killed]')"
assert_eq "  a role as given, numbers that are none: null" \
    '["agent-x",null,null]' \
    "$(q '.containers[6] | [.role, .profile_index, .agent_number]')"
assert_eq "  no condition" '[]' "$(q .conditions)"
# Workspaces.
vol "${PJ}-agent-2-ws-bbbbbbbb" "${PJ}-agent-2"
vol "${PJ}-agent-1-ws-aaaaaaaa" "${PJ}-agent-1"
vol "${PJ}-agent-interactive-b-1-ws-cccccccc" "${PJ}-agent-interactive-b-1" \
    '.Labels["swarm-core.kind"] = "interactive"'
vol "${PJ}-old" "" '.Labels |= with_entries(select(.key
    | IN("swarm-core.project", "swarm-core.checkout")))'
vol "other-ws" "x" '.Labels["swarm-core.checkout"] = "/elsewhere"'
: > "$FD/log"
rc=$(obs)
obs_ok "workspaces" "$rc"
assert_eq "  this checkout's, sorted by name, every field" \
    "[{\"volume\":\"${PJ}-agent-1-ws-aaaaaaaa\",\"container\":\"${PJ}-agent-1\",\"kind\":\"agent\",\"engagement\":\"e1\",\"engagement_token\":\"aaaaaaaaaaaaaaaa\"},{\"volume\":\"${PJ}-agent-2-ws-bbbbbbbb\",\"container\":\"${PJ}-agent-2\",\"kind\":\"agent\",\"engagement\":\"e1\",\"engagement_token\":\"aaaaaaaaaaaaaaaa\"},{\"volume\":\"${PJ}-agent-interactive-b-1-ws-cccccccc\",\"container\":\"${PJ}-agent-interactive-b-1\",\"kind\":\"interactive\",\"engagement\":\"e1\",\"engagement_token\":\"aaaaaaaaaaaaaaaa\"},{\"volume\":\"${PJ}-old\",\"container\":null,\"kind\":null,\"engagement\":null,\"engagement_token\":null}]" \
    "$(q .workspaces)"
# Only the allowed Docker calls, through one pinned context.
assert_eq "  Docker calls: context show, info, ps, container inspect, volume ls and volume inspect only" \
    "" "$(grep -vE '^(context show|info -f [{][{].ID[}][}]|ps |container inspect |volume ls |volume inspect )' "$FD/log")"
assert_eq "  the context read once, first" "context show|1" \
    "$(head -n 1 "$FD/log")|$(grep -c '^context show' "$FD/log")"
# Another terminal switches the current context once observe read it:
# every later call still goes to the context read.
: > "$FD/ctxlog"
: > "$FD/switch"
rc=$(obs)
obs_ok "the current context switched meanwhile" "$rc"
assert_eq "  the document names the context read" '"ctxa"' \
    "$(q .docker.context)"
assert_eq "  the first call reads it, unpinned" "|context" \
    "$(head -n 1 "$FD/ctxlog")"
assert_eq "  every later call gets it" "0" \
    "$(awk -F'|' 'NR > 1 && $1 != "ctxa" { n++ } END { print n + 0 }' \
        "$FD/ctxlog")"
assert_eq "  (and there are later calls)" "true" \
    "$([ "$(wc -l < "$FD/ctxlog")" -gt 4 ] && echo true || echo false)"
rm -f "$FD/current"
# A container and a volume gone between their listing and their
# inspection are left out: listed, inspected in vain, then not listed
# again.
rm -f "$FD"/listed-*
: > "$FD/log"
: > "$FD/gone-$(full_id "${PJ}-agent-2")"
: > "$FD/gone-${PJ}-agent-2-ws-bbbbbbbb"
rc=$(obs)
obs_ok "objects gone in between" "$rc"
assert_eq "  that container left out" "false" \
    "$(q "[.containers[].name] | index(\"${PJ}-agent-2\") != null")"
assert_eq "  that volume left out" "false" \
    "$(q "[.workspaces[].volume] | index(\"${PJ}-agent-2-ws-bbbbbbbb\") != null")"
assert_eq "  the others kept" "6|3" \
    "$(q '.containers | length')|$(q '.workspaces | length')"
assert_eq "  the container: inspected, then looked for by id" "1|1" \
    "$(grep -c "^container inspect $(full_id "${PJ}-agent-2")$" "$FD/log")|$(grep -c "^ps -aq --no-trunc --filter id=$(full_id "${PJ}-agent-2")$" "$FD/log")"
assert_eq "  the volume: inspected, then the volumes listed again" "1|2" \
    "$(grep -c "^volume inspect ${PJ}-agent-2-ws-bbbbbbbb$" "$FD/log")|$(grep -c '^volume ls' "$FD/log")"
rm -f "$FD"/gone-* "$FD"/listed-*
# A failed inspection or listing: lists null, never empty; the daemon
# still known; no Docker condition.
for f in inspect vinspect ps vls; do
    : > "$FD/fail-$f"
    rc=$(obs)
    obs_ok "a failed docker $f" "$rc"
    assert_eq "  containers and workspaces null, the daemon known" \
        '[null,null,"daemon-a"]' \
        "$(q '[.containers, .workspaces, .docker.daemon]')"
    rm -f "$FD/fail-$f" "$FD"/listed-*
done
# An inspection Docker answers with something that is no JSON, or with
# nothing: the lists are null, not short.
for g in "$(full_id "${PJ}-agent-1")" "${PJ}-agent-1-ws-aaaaaaaa"; do
    for kind in garbage empty; do
        : > "$FD/$kind-$g"
        rc=$(obs)
        obs_ok "an inspection that is $kind" "$rc"
        assert_eq "  containers and workspaces null" '[null,null]' \
            "$(q '[.containers, .workspaces]')"
        rm -f "$FD"/garbage-* "$FD"/empty-* "$FD"/listed-*
    done
done
# Docker cannot be reached; no docker at all.
: > "$FD/fail-info"
rc=$(obs)
obs_ok "Docker unreachable" "$rc"
assert_eq "  the context, no daemon, null lists" '["ctxa",null,null,null]' \
    "$(q '[.docker.context, .docker.daemon, .containers, .workspaces]')"
rm -f "$FD/fail-info"
: > "$FD/fail-context"
rc=$(obs)
obs_ok "no context to read" "$rc"
assert_eq "  nothing of Docker" '[null,null,null,null]' \
    "$(q '[.docker.context, .docker.daemon, .containers, .workspaces]')"
rm -f "$FD/fail-context"
# A PATH of the tools observe runs, without docker.
NODOCKER="$TMPDIR/nodocker"
mkdir -p "$NODOCKER"
for t in dirname basename date git jq perl stat sed tr uname cat \
        sha256sum shasum awk head cut sort ls id env; do
    p=$(command -v "$t" 2>/dev/null) || continue
    case "$p" in /*) ln -sf "$p" "$NODOCKER/$t" ;; esac
done
rc=0
(cd "$CO" && PATH="$NODOCKER" SWARM_RUNTIME_DIR="$RT" "$BASH" "$CONTROL" \
    --interface "$IFACE" observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
obs_ok "no docker installed" "$rc"
assert_eq "  nothing of Docker" '[null,null,null,null]' \
    "$(q '[.docker.context, .docker.daemon, .containers, .workspaces]')"
# DOCKER_HOST and DOCKER_CONTEXT choose the daemon: no context read.
: > "$FD/log"
rc=$(DOCKER_HOST=unix:///x obs)
obs_ok "DOCKER_HOST" "$rc"
assert_eq "  no context, and none read" "null|0" \
    "$(q .docker.context)|$(grep -c '^context show' "$FD/log" || true)"
: > "$FD/log"
rc=$(DOCKER_CONTEXT=ctxb obs)
obs_ok "DOCKER_CONTEXT" "$rc"
assert_eq "  that context, none read" '"ctxb"|0' \
    "$(q .docker.context)|$(grep -c '^context show' "$FD/log" || true)"
# Containers of the project that are not this checkout's.
fd_reset
ctr "${PJ}-agent-1"
ctr "${PJ}-agent-2" '.Config.Labels["swarm-core.checkout"] = "/elsewhere"'
rc=$(obs)
obs_ok "another checkout's container" "$rc"
assert_eq "  foreign-containers, and it is not listed" \
    "[\"foreign-containers\"]|[\"${PJ}-agent-1\"]" \
    "$(q .conditions)|$(q '[.containers[].name]')"
fd_reset
ctr "${PJ}-agent-post" '.Config.Labels = {}'
rc=$(obs)
obs_ok "an unlabeled container" "$rc"
assert_eq "  unlabeled-containers, and it is not listed" \
    '["unlabeled-containers"]|[]' "$(q .conditions)|$(q .containers)"
fd_reset
ctr "${PJ}x-agent-1" '.Config.Labels = {}'
ctr "${PJ}-agent-notes" '.Config.Labels = {}'
rc=$(obs)
assert_eq "names that are not the project's: no condition" "0|[]" \
    "$rc|$(q .conditions)"
# Containers or volumes of no recorded engagement.
rt_reset
fd_reset
ctr "${PJ}-agent-1"
rc=$(obs)
assert_eq "no engagement, a container: unrecorded-leftovers" \
    '0|["unrecorded-leftovers"]' "$rc|$(q .conditions)"
fd_reset
vol "${PJ}-agent-1-ws-aaaaaaaa" "${PJ}-agent-1"
rc=$(obs)
assert_eq "no engagement, a volume: unrecorded-leftovers" \
    '0|["unrecorded-leftovers"]' "$rc|$(q .conditions)"
: > "$FD/fail-vls"
rc=$(obs)
assert_eq "  not looked for when Docker did not answer" '0|[]' \
    "$rc|$(q .conditions)"
fd_reset

echo ""
echo "=== 8. observe: one read of the state ==="
# A git first on PATH changes the state while the bare repo is checked:
# once (the second attempt is consistent, and the document is of that
# state), then each time (state-unstable).
rt_reset "$ENGAGED"
git clone -q --bare "$CO" "$RT/upstream.git"
REAL_GIT=$(command -v git)
GBIN="$TMPDIR/gbin"
mkdir -p "$GBIN"
cat > "$GBIN/git" <<EOF
#!/bin/bash
case " \$* " in
    *" rev-parse --is-bare-repository "*)
        n=\$(( \$(cat "$TMPDIR/flips" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" > "$TMPDIR/flips"
        if [ "\$n" -le "\$(cat "$TMPDIR/flip-max")" ]; then
            jq -c --arg t "\$(printf '%08d%08d' "\$\$" "\$n")" \
                '.engagement_token = \$t' "$RT/state.json" \
                > "$RT/state.x" && mv "$RT/state.x" "$RT/state.json"
        fi ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GBIN/git"
echo 1 > "$TMPDIR/flip-max"
rm -f "$TMPDIR/flips"
rc=0
(cd "$CO" && PATH="$GBIN:$FBIN:$PATH" FD="$FD" SWARM_RUNTIME_DIR="$RT" \
    "$BASH" "$CONTROL" --interface "$IFACE" observe > "$TMPDIR/out" \
    2> "$TMPDIR/err") || rc=$?
obs_ok "the state changed once while it was read" "$rc"
assert_eq "  the document is of the state read again" \
    "$(jq -r .engagement_token "$RT/state.json")" "$(qr .engagement.token)"
assert_eq "  not of the first one" "false" \
    "$(q '.engagement.token == "aaaaaaaaaaaaaaaa"')"
assert_eq "  read twice more" "2" "$(cat "$TMPDIR/flips")"
echo 99 > "$TMPDIR/flip-max"
rm -f "$TMPDIR/flips"
rc=0
(cd "$CO" && PATH="$GBIN:$FBIN:$PATH" FD="$FD" SWARM_RUNTIME_DIR="$RT" \
    "$BASH" "$CONTROL" --interface "$IFACE" observe > "$TMPDIR/out" \
    2> "$TMPDIR/err") || rc=$?
refused "the state changed at each read" state-unstable "$rc"
assert_eq "  after three attempts" "3" "$(cat "$TMPDIR/flips")"

echo ""
echo "=== 9. A query changes nothing ==="
# The runtime directory, the state, the checkout's Git data, HOME and
# TMPDIR as they were; no lock taken (a query while another process
# holds it answers at once).
rt_reset "$ENGAGED | .cleanup = {engagement: \"e1\", started_at: \"t\", runs: []}"
git clone -q --bare "$CO" "$RT/upstream.git"
mkdir -m 755 "$RT/mirrors"
jq -cn --arg b "$BASE" '{schema: "swarm-core.mirrors/v1", base: $b,
    mirrors: []}' > "$RT/mirrors/manifest.json"
fd_reset
ctr "${PJ}-agent-1"
vol "${PJ}-agent-1-ws-aaaaaaaa" "${PJ}-agent-1"
# Every entry under directory DIR with its mode, size and modification
# time (a file made and removed meanwhile changes its directory's), and
# a digest of the files' contents.
if stat -c %Y . >/dev/null 2>&1; then
    STAT_FMT=(-c '%A %s %Y %n')
else
    STAT_FMT=(-f '%Sp %z %m %N')
fi
snap() {
    (cd "$1" && find . -print0 | LC_ALL=C sort -z \
        | xargs -0 stat "${STAT_FMT[@]}"
     find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cat 2>/dev/null \
        | { sha256sum 2>/dev/null || shasum -a 256; })
}
QHOME="$TMPDIR/qhome"
QTMP="$TMPDIR/qtmp"
mkdir -p "$QHOME" "$QTMP"
before_rt=$(snap "$RT")
before_git=$(snap "$CO/.git")
sleep 1
rc=0
(cd "$CO" && HOME="$QHOME" TMPDIR="$QTMP" PATH="$FBIN:$PATH" FD="$FD" \
    SWARM_RUNTIME_DIR="$RT" "$BASH" "$CONTROL" --interface "$IFACE" \
    observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
obs_ok "a query" "$rc"
assert_eq "  the runtime directory as it was, times too" "$before_rt" \
    "$(snap "$RT")"
assert_eq "  the checkout's Git data as it was" "$before_git" \
    "$(snap "$CO/.git")"
assert_eq "  HOME and TMPDIR still empty" "|" \
    "$(ls -A "$QHOME")|$(ls -A "$QTMP")"
assert_eq "  no lock file made" "no" \
    "$([ -e "$RT/engagement.lock" ] && echo yes || echo no)"
if command -v flock >/dev/null 2>&1; then
    : > "$RT/engagement.lock"
    (exec 9>>"$RT/engagement.lock"; flock 9; exec sleep 20) &
    holder=$!
    sleep 0.5
    start_s=$(date +%s)
    rc=$(obs)
    took=$(( $(date +%s) - start_s ))
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    obs_ok "a query while another process holds the lock" "$rc"
    assert_eq "  answers without waiting for it" "true" \
        "$([ "$took" -lt 10 ] && echo true || echo false)"
    rm -f "$RT/engagement.lock"
else
    echo "  SKIP: no flock here"
fi
# Every write denied (macOS's sandbox): no temporary file, no lock, no
# Git or Docker configuration write, or the query would fail.
if command -v sandbox-exec >/dev/null 2>&1 \
        && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null; then
    prof="(version 1)(allow default)(deny file-write* (require-not
        (require-any (literal \"/dev/null\") (literal \"/dev/tty\")
        (subpath \"/dev/fd\") (subpath \"$FD\"))))"
    rc=0
    (cd "$CO" && PATH="$FBIN:$PATH" FD="$FD" SWARM_RUNTIME_DIR="$RT" \
        sandbox-exec -p "$prof" "$BASH" "$CONTROL" --interface "$IFACE" \
        observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
    obs_ok "a query with every write denied" "$rc"
    assert_eq "  the same document" "true" \
        "$(q '.engagement.id == "e1" and (.containers | length) == 1
            and .conditions == ["cleanup-pending"]')"
    # The sandbox does deny writes: a here-string fails in it.
    assert_eq "  (the sandbox denies a here-string's file)" "1" \
        "$(sandbox-exec -p "$prof" "$BASH" -c 'cat <<< x' >/dev/null 2>&1; echo $?)"
else
    echo "  SKIP: no sandbox-exec here"
fi
# What observe runs: control.sh holds no here-document, here-string,
# process substitution or mktemp outside comments, and neither does any
# function that ran (traced through a DEBUG trap).
assert_eq "control.sh makes no temporary file" "" \
    "$(grep -nE '<<|<\(|mktemp' "$CONTROL" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
cat > "$TMPDIR/trace.sh" <<EOF
set -T
trap 'printf "%s\t%s\n" "\${FUNCNAME[0]:-main}" "\${BASH_SOURCE[0]:-}" \
    >> "$TMPDIR/funcs"' DEBUG
EOF
rm -f "$TMPDIR/funcs"
rc=0
(cd "$CO" && PATH="$FBIN:$PATH" FD="$FD" SWARM_RUNTIME_DIR="$RT" \
    BASH_ENV="$TMPDIR/trace.sh" "$BASH" "$CONTROL" --interface "$IFACE" \
    observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
assert_eq "a traced query works" "0" "$rc"
# The engine's functions only (the fake docker is a Bash script too).
funcs=$(awk -F'\t' -v r="$REPO_ROOT/" 'index($2, r) == 1 && $1 != "main" {
    print $1 }' "$TMPDIR/funcs" | sort -u)
assert_eq "  through the engine's read helpers" "true" \
    "$(printf '%s\n' "$funcs" | grep -qx swarm_bare_repo_ready \
        && printf '%s\n' "$funcs" | grep -qx swarm_project_containers \
        && echo true || echo false)"
bad=$(
    # shellcheck source=../lib/project.sh
    source "$REPO_ROOT/lib/project.sh"
    # shellcheck source=../lib/submodules.sh
    source "$REPO_ROOT/lib/submodules.sh"
    # shellcheck source=../lib/target.sh
    source "$REPO_ROOT/lib/target.sh"
    for f in $funcs; do
        [[ "$f" != control_* ]] || continue
        if ! declare -f "$f" >/dev/null; then
            echo "$f: not found"
        elif declare -f "$f" | grep -qE '<<|<\(|mktemp'; then
            echo "$f"
        fi
    done)
assert_eq "  none of which makes a temporary file" "" "$bad"
# On macOS, Apple's /usr/bin/git is a shim that may write a cache in a
# temporary directory: a query runs the developer tools' git instead,
# whether PATH finds the shim or a link to it (the sandbox kills a
# process that runs the shim).
if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/git ] \
        && /usr/bin/xcode-select -p >/dev/null 2>&1 \
        && command -v sandbox-exec >/dev/null 2>&1 \
        && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null; then
    kprof='(version 1)(allow default)(deny process-exec
        (literal "/usr/bin/git") (with send-signal SIGKILL))'
    mkdir -p "$TMPDIR/shimlink"
    ln -sf /usr/bin/git "$TMPDIR/shimlink/git"
    ln -sfn /usr/bin "$TMPDIR/bindir"
    for first in /usr/bin "$TMPDIR/shimlink" /usr/bin/. /usr/bin/../bin \
            "$TMPDIR/bindir"; do
        rc=0
        (cd "$CO" && PATH="$first:$FBIN:$PATH" FD="$FD" \
            SWARM_RUNTIME_DIR="$RT" sandbox-exec -p "$kprof" "$BASH" \
            "$CONTROL" --interface "$IFACE" observe > "$TMPDIR/out" \
            2> "$TMPDIR/err") || rc=$?
        obs_ok "git first on PATH from ${first#"$TMPDIR"/}, never run" "$rc"
        assert_eq "  the engagement read through Git" "true" \
            "$(q '.engagement.complete')"
    done
    assert_eq "(the sandbox kills the shim)" "137" \
        "$(sandbox-exec -p "$kprof" /usr/bin/git --version >/dev/null 2>&1; echo $?)"
else
    echo "  SKIP: no shim git, or no sandbox-exec, here"
fi

echo ""
echo "=== 10. A tool that fails: internal, and nothing on stdout ==="
# jq failing at the conditions or at the document, and date failing.
REAL_JQ=$(command -v jq)
FAILBIN="$TMPDIR/failbin"
mkdir -p "$FAILBIN"
cat > "$FAILBIN/jq" <<EOF
#!/bin/bash
case " \$* " in
    *"\$JQ_FAIL_ON"*) echo "jq: error: injected" >&2; exit 5 ;;
esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$FAILBIN/jq"
for pat in " -R " "swarm-core.observation/v1" ".docker_daemon == null"; do
    rc=0
    (cd "$CO" && PATH="$FAILBIN:$FBIN:$PATH" FD="$FD" JQ_FAIL_ON="$pat" \
        SWARM_RUNTIME_DIR="$RT" "$BASH" "$CONTROL" --interface "$IFACE" \
        observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
    refused "jq failing at '$pat'" internal "$rc"
    assert_eq "  its own message not on stderr" "1" \
        "$(wc -l < "$TMPDIR/err" | tr -d ' ')"
done
mkdir -p "$TMPDIR/datebin"
printf '#!/bin/bash\necho "date: injected" >&2\nexit 1\n' \
    > "$TMPDIR/datebin/date"
chmod +x "$TMPDIR/datebin/date"
rc=0
(cd "$CO" && PATH="$TMPDIR/datebin:$FBIN:$PATH" FD="$FD" \
    SWARM_RUNTIME_DIR="$RT" "$BASH" "$CONTROL" --interface "$IFACE" \
    observe > "$TMPDIR/out" 2> "$TMPDIR/err") || rc=$?
refused "date failing" internal "$rc"
assert_eq "  one line on stderr" "1" "$(wc -l < "$TMPDIR/err" | tr -d ' ')"
# No date at all: Bash's own "command not found" stays off stderr.
NODATE="$TMPDIR/nodate"
mkdir -p "$NODATE"
for t in dirname basename git jq perl stat sed tr uname cat sha256sum \
        shasum awk head cut sort ls id env base64 wc xargs mkdir; do
    p=$(command -v "$t" 2>/dev/null) || continue
    case "$p" in /*) ln -sf "$p" "$NODATE/$t" ;; esac
done
rc=0
(cd "$CO" && PATH="$NODATE:$FBIN" FD="$FD" SWARM_RUNTIME_DIR="$RT" \
    "$BASH" "$CONTROL" --interface "$IFACE" observe > "$TMPDIR/out" \
    2> "$TMPDIR/err") || rc=$?
refused "no date" internal "$rc"
assert_eq "  one line on stderr" "1" "$(wc -l < "$TMPDIR/err" | tr -d ' ')"

echo ""
echo "=== 11. Git writes no trace ==="
# Trace targets in a configuration file (trace2) and in the environment
# (trace1 and trace2): observe, which runs Git in the checkout, the bare
# repo and a mirror, leaves no trace file.
rt_reset "$ENGAGED"
git clone -q --bare "$CO" "$RT/upstream.git"
mkdir -m 755 "$RT/mirrors"
git clone -q --bare "$CO" "$RT/mirrors/1.git"
git --git-dir="$RT/mirrors/1.git" update-ref refs/swarm/gitlink "$BASE"
jq -cn --arg b "$BASE" --arg n "$(b64 lib/x)" '{schema:
    "swarm-core.mirrors/v1", base: $b, mirrors: [{id: 1, parent: 0,
    name: $n, path: $n, commit: $b}]}' > "$RT/mirrors/manifest.json"
fd_reset
TR="$TMPDIR/traces"
mkdir -p "$TR"
printf '[trace2]\n\tnormalTarget = %s/cfg-normal\n\teventTarget = %s/cfg-event\n\tperfTarget = %s/cfg-perf\n' \
    "$TR" "$TR" "$TR" > "$TMPDIR/trace.gitconfig"
# The global configuration: GIT_CONFIG_GLOBAL from Git 2.32 on, HOME's
# .gitconfig before that.
mkdir -p "$TMPDIR/trace-home"
cp "$TMPDIR/trace.gitconfig" "$TMPDIR/trace-home/.gitconfig"
# (Git does write them when asked so.)
HOME="$TMPDIR/trace-home" GIT_CONFIG_GLOBAL="$TMPDIR/trace.gitconfig" \
    git -C "$CO" rev-parse HEAD >/dev/null
assert_eq "(this Git writes the configured traces)" "cfg-event cfg-normal cfg-perf" \
    "$(ls "$TR" | tr '\n' ' ' | sed 's/ $//')"
rm -f "$TR"/*
rc=0
(cd "$CO" && PATH="$FBIN:$PATH" FD="$FD" SWARM_RUNTIME_DIR="$RT" \
    HOME="$TMPDIR/trace-home" GIT_CONFIG_GLOBAL="$TMPDIR/trace.gitconfig" \
    GIT_TRACE="$TR/env-trace" \
    GIT_TRACE_SETUP="$TR/env-setup" GIT_TRACE2="$TR/env-normal" \
    GIT_TRACE2_EVENT="$TR/env-event" GIT_TRACE2_PERF="$TR/env-perf" \
    "$BASH" "$CONTROL" --interface "$IFACE" observe > "$TMPDIR/out" \
    2> "$TMPDIR/err") || rc=$?
obs_ok "observe with every trace target set" "$rc"
assert_eq "  through the bare repo and the mirror" "true|[]" \
    "$(q .engagement.complete)|$(q .conditions)"
assert_eq "  and no trace file" "" "$(ls -A "$TR")"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="
[ "$FAIL" -eq 0 ]
