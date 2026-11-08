#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for lib/docker-args.sh: docker_args read as the exact vector
# docker run gets, and checked against docker run's option grammar.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=../lib/docker-args.sh
source "$REPO_ROOT/lib/docker-args.sh"

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
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected to contain: ${needle}"
        echo "        actual:              ${haystack}"
        FAIL=$((FAIL + 1))
    fi
}

# Read docker_args from a swarmfile whose docker_args is JSON value $1;
# print "<status>|" then the elements as a JSON array.  Stderr goes to
# $TMPDIR/err.
readv() {
    local rc=0 out
    printf '{"prompt": "p.md", "docker_args": %s}\n' "$1" > "$TMPDIR/s.json"
    # shellcheck disable=SC2030,SC2031  # each read in a subshell
    out=$(
        exec 2> "$TMPDIR/err"
        swarm_docker_args_read "$TMPDIR/s.json" || exit 1
        jq -nc '$ARGS.positional' --args -- \
            "${SWARM_DOCKER_ARGS[@]+"${SWARM_DOCKER_ARGS[@]}"}"
    ) || rc=$?
    printf '%s|%s' "$rc" "$out"
}

# Check the elements given as arguments; print "<status>|<stderr>".
chk() {
    local rc=0 e
    # shellcheck disable=SC2030,SC2031  # each check in a subshell
    e=$(
        SWARM_DOCKER_ARGS=("$@")
        swarm_docker_args_check 2>&1 >/dev/null
    ) || rc=$?
    printf '%s|%s' "$rc" "$e"
}
accepted() {
    assert_eq "accepted: $(printf '%q ' "$@")" "0|" "$(chk "$@")"
}
refused() {
    local msg="$1" out
    shift
    out=$(chk "$@")
    assert_eq "refused: $(printf '%q ' "$@")" 1 "${out%%|*}"
    assert_contains "  saying so" "$msg" "${out#*|}"
}

echo "=== 1. The exact vector ==="
assert_eq "elements as they are" \
    '0|["-v","/a b:/c","--label","x=\"q\" y","--entrypoint","-x","ä"]' \
    "$(readv '["-v","/a b:/c","--label","x=\"q\" y","--entrypoint","-x","ä"]')"
assert_eq "an element with leading and trailing spaces keeps them" \
    '0|["--label"," a "]' "$(readv '["--label"," a "]')"
# shellcheck disable=SC2031  # read in that subshell
assert_eq "absent" "0|[]" "$(
    printf '{"prompt": "p.md"}\n' > "$TMPDIR/n.json"
    swarm_docker_args_read "$TMPDIR/n.json" && printf '0|'
    jq -nc '$ARGS.positional' --args -- \
        "${SWARM_DOCKER_ARGS[@]+"${SWARM_DOCKER_ARGS[@]}"}")"
assert_eq "null" "0|[]" "$(readv null)"
assert_eq "empty" "0|[]" "$(readv '[]')"
for case in '{"a":"--privileged"}:is not an array of strings' \
        '"--privileged":is not an array of strings' \
        '["--rm",1]:element 2 in' \
        '["--rm",{"a":1}]:element 2 in' \
        '["--rm",["x"]]:element 2 in' \
        '["--rm",null]:element 2 in' \
        '["--rm",""]:is empty' \
        '["--label","a\nb"]:holds a newline' \
        '["--label","a\u0000b"]:holds a NUL'; do
    json="${case%:*}"
    msg="${case##*:}"
    assert_eq "read refuses $json" "1|" "$(readv "$json")"
    assert_contains "  saying so" "$msg" "$(cat "$TMPDIR/err")"
done
# The swarmfile must be one JSON document: empty, or two documents,
# refuse instead of giving no docker_args.
: > "$TMPDIR/empty.json"
assert_eq "an empty swarmfile refuses" 1 "$(
    swarm_docker_args_read "$TMPDIR/empty.json" 2>/dev/null; echo $?)"
printf '%s\n' '{"docker_args": ["--rm"]}' '{"docker_args": ["--init"]}' \
    > "$TMPDIR/two.json"
assert_eq "two documents refuse" 1 "$(
    swarm_docker_args_read "$TMPDIR/two.json" 2>/dev/null; echo $?)"
assert_contains "  saying so" "one JSON document" "$(
    swarm_docker_args_read "$TMPDIR/two.json" 2>&1 >/dev/null || true)"
assert_contains "a non-string element is named as such" "is not a string" \
    "$(readv '["--rm",1]' >/dev/null; cat "$TMPDIR/err")"

echo ""
echo "=== 2. The grammar ==="
accepted --rm
accepted --rm=false
accepted --privileged=true
accepted --name x
accepted --name=x
accepted --name=
accepted --env --help
accepted --label -itd
accepted --env --
accepted --entrypoint -x
accepted -e FOO=1
accepted -eFOO=1
accepted -e=FOO
accepted -e=
accepted -i
accepted -i=false
accepted -d=0
accepted -t=True
accepted -help
accepted -h x
accepted -v /a:/b
accepted --net host
accepted --net-alias a
accepted --dns-opt ndots:1
accepted --kernel-memory 1m
accepted --disable-content-trust
accepted --cpu-count 2
accepted --use-api-socket
accepted --detach-keys=ctrl-x --label -itd --name custom-session
accepted
refused "is '--', which would end docker run's options" --
refused "is '--', which would end docker run's options" --rm --
refused "is no option where docker run expects one" -
refused "is no option where docker run expects one" image
refused "element 2 (false) is no option" --rm false
refused "element 3 (x) is no option" --name a x
refused "takes a value, and nothing follows it" --name
refused "takes a value, and nothing follows it" -e
refused "element 3 (--label) takes a value" --rm -i --label
refused "is no docker run option this engine knows" --nope
refused "is no docker run option this engine knows" --nope=1
refused "is no docker run option this engine knows" -Z
refused "is no docker run option this engine knows" -1
refused "is no docker run option this engine knows" --=x
refused "is no docker run option this engine knows" '--rm x'
refused "is no docker run option this engine knows" '--rm sig-proxy'
refused "is no docker run option this engine knows" '--name net' x
refused "is no docker run option this engine knows" "--name$(printf '\t')net" x
refused "is no docker run option this engine knows" '--RM'
refused "asks for docker run's help" --help
refused "asks for docker run's help" --help=false
refused "asks for docker run's help" --help=
refused "gives a boolean option no value after '='" -i=
refused "groups short options" -it
refused "groups short options" -it=false
refused "groups short options" -dP

echo ""
echo "=== 3. The table ==="
# The table matches the pinned list of what Docker 24.0.9 and 29.8.2
# register.
FIX="$REPO_ROOT/tests/fixtures/docker-run-options.txt"
table_longs() {
    local w
    for w in $SWARM_DOCKER_VALUE_OPTS; do
        printf '%s VALUE\n' "$w"
    done
    for w in $SWARM_DOCKER_BOOL_OPTS; do
        printf '%s BOOL\n' "$w"
    done
}
assert_eq "the long options and their kinds match the fixture" \
    "$(grep -v '^#' "$FIX" | awk '{ print $2, $3 }' | LC_ALL=C sort)" \
    "$(table_longs | LC_ALL=C sort)"
assert_eq "the short options taking a value match it" \
    "$(grep -v '^#' "$FIX" | awk '$1 != "-" && $3 == "VALUE" { print $1 }' \
        | LC_ALL=C sort | tr -d '\n')" \
    "$(printf '%s' "$SWARM_DOCKER_SHORT_VALUE" | fold -w1 | LC_ALL=C sort \
        | tr -d '\n')"
assert_eq "the boolean short options match it" \
    "$(grep -v '^#' "$FIX" | awk '$1 != "-" && $3 == "BOOL" { print $1 }' \
        | LC_ALL=C sort | tr -d '\n')" \
    "$(printf '%s' "$SWARM_DOCKER_SHORT_BOOL" | fold -w1 | LC_ALL=C sort \
        | tr -d '\n')"
assert_eq "no name in both kinds" "" \
    "$(table_longs | awk '{ print $1 }' | LC_ALL=C sort | uniq -d)"
# Every option the Docker here shows in docker run --help is in the table
# with the same kind (help hides options by the daemon's OS and API
# version: a subset check).
if help=$(docker run --help 2>/dev/null) && [ -n "$help" ]; then
    # "<short>|<long>|<type>" per option, short and type empty when none.
    printf '%s\n' "$help" | sed -n '/^Options:/,$p' \
        | grep -E '^ +(-[A-Za-z], )?--[a-z0-9-]+' \
        | sed -E 's/^ +(-([A-Za-z]), )?--([a-z0-9-]+)( ([a-z0-9]+))?.*/\2|\3|\5/' \
        > "$TMPDIR/help"
    missing=""
    while IFS='|' read -r s l t; do
        want=VALUE
        [ -n "$t" ] || want=BOOL
        got=$(_swarm_docker_long_kind "$l" | tr '[:lower:]' '[:upper:]')
        [ "$got" = "$want" ] || missing="${missing} --${l}(${want}/${got:-none})"
        if [ -n "$s" ]; then
            got=$(_swarm_docker_short_kind "$s" | tr '[:lower:]' '[:upper:]')
            [ "$got" = "$want" ] \
                || missing="${missing} -${s}(${want}/${got:-none})"
        fi
    done < "$TMPDIR/help"
    assert_eq "every option docker run --help shows is in the table" "" \
        "$missing"
    assert_eq "  (it showed some)" yes \
        "$([ "$(wc -l < "$TMPDIR/help")" -gt 50 ] && echo yes || echo no)"
else
    echo "  SKIP: no docker here for the help check"
fi

echo ""
echo "=== 4. What launch.sh gives a target's containers ==="
# The five variables, by exact name before the first "=", in every
# spelling the grammar takes.
refused "sets TARGET_REPO" -e TARGET_REPO=x
refused "sets TARGET_REPO" -e TARGET_REPO
refused "sets TARGET_REV" --env TARGET_REV=1
refused "sets TARGET_REV_BASE" --env=TARGET_REV_BASE=1
refused "sets TARGET_REV_BASE_REPO" -eTARGET_REV_BASE_REPO=/x
refused "sets SWARM_TARGET_MIRROR" -e=SWARM_TARGET_MIRROR=/y
refused "element 2 (-e) sets TARGET_REPO" --rm -e TARGET_REPO=
accepted -e TARGET_REPOX=1
accepted -e XTARGET_REPO=1
accepted -e target_repo=1
accepted -e ' TARGET_REPO=1'
accepted --env FOO=TARGET_REPO=1
accepted --label TARGET_REPO=1
# Whole files of variables and other containers' mounts, always.
refused "reads variables from a file" --env-file /dev/null
refused "reads variables from a file" --env-file=/dev/null
refused "takes every mount of another container" --volumes-from c1
refused "takes every mount of another container" --volumes-from=c1:ro
accepted --label-file /dev/null
# Mounts at or below /target-upstream, after Go's path.Clean: every
# field of -v and --device (a host path there counts too), the part of
# --tmpfs before its first ":".
U="puts something at or below /target-upstream"
refused "$U" -v /x:/target-upstream
refused "$U" -v /x:/target-upstream:ro
refused "$U" -v /target-upstream
refused "$U" -v /x:/target-upstream/sub
refused "$U" --volume=/x://target-upstream/
refused "$U" -v/x:/a/../target-upstream
refused "$U" -v=/x:/target-upstream
refused "$U" -v /target-upstream:/data
refused "$U" -v myvol:/target-upstream/.
refused "$U" -v ' /target-upstream'
refused "$U" --device /dev/null:/target-upstream/probe
refused "$U" --device=/target-upstream
refused "$U" --device /dev/null:/target-upstream:rwm
refused "$U" --tmpfs /target-upstream
refused "$U" --tmpfs /target-upstream:rw,size=1m
refused "$U" --tmpfs=/target-upstream/x
refused "$U" -v /x:/./target-upstream
accepted -v /x:/target-upstreamx
accepted -v target-upstream:/data
accepted -v /x:/target-upstream-2
accepted -v /x:/data/target-upstream
accepted -v /x:/target-upstream/..
accepted --device /dev/null:/dev/xnull
accepted --tmpfs /tmp:/target-upstream
accepted --tmpfs /run
# --mount, read as Docker 29 reads it (the whole value trimmed) and as
# Docker 24 does (nothing trimmed), one CSV record each.
refused "$U" --mount type=bind,src=/x,dst=/target-upstream
refused "$U" --mount type=volume,target=/target-upstream/sub
refused "$U" --mount type=tmpfs,destination=/target-upstream
refused "$U" --mount=type=bind,src=/x,DST=/target-upstream
refused "$U" --mount type=bind,src=/x,Destination=/target-upstream
refused "$U" --mount "$(printf 'DEST\304\260NAT\304\260ON=/target-upstream')"
refused "$U" --mount '"dst=/target-upstream"'
refused "$U" --mount 'type=bind,"src=/a,b",dst=/target-upstream'
refused "$U" --mount '"dst=/target-upstream/""x"""'
refused "$U" --mount 'type=bind,src=/x,dst=/target-upstream '
refused "$U" --mount 'dst=/target-upstream/.. '
refused "$U" --mount "$(printf 'dst=/target-upstream\r')"
refused "$U" --mount "$(printf '\302\240dst=/target-upstream\302\240')"
refused "$U" --mount 'dst = /target-upstream'
refused "$U" --mount dst=/x,dst=/target-upstream
refused "$U" --mount dst=/target-upstream,dst=/x
refused "$U" --mount dst=//target-upstream/./
C="has a value Docker cannot read as one CSV record"
refused "$C" --mount 'dst="/target-upstream"'
refused "$C" --mount '"dst=/x'
refused "$C" --mount '"dst=/x"y'
refused "$C" --mount ' '
refused "is not UTF-8" --mount "$(printf 'dst=/x\377')"
accepted --mount type=bind,src=/target-upstream,dst=/data
accepted --mount type=volume,src=target-upstream,dst=/data
accepted --mount "$(printf 'dst=/target-upstream/..\r')"
accepted --mount type=bind,src=/x,dst=/target-upstreamx
accepted --mount type=bind,src=/x,dst=/data,readonly
accepted --mount dst=/target-upstream/..
accepted --mount '"dst=/a,b"'
accepted --mount "$(printf 'type=bind,src=/x,dst=/data/\357\277\277')"
accepted --mount "$(printf 'dst=/x,k\342\204\252y=/target-upstream')"
# A perl that fails is no clear answer.
mkdir -p "$TMPDIR/badperl"
printf '#!/bin/sh\nexit 99\n' > "$TMPDIR/badperl/perl"
chmod +x "$TMPDIR/badperl/perl"
assert_contains "a failing perl refuses" "cannot be checked (perl ended" \
    "$(PATH="$TMPDIR/badperl:$PATH" chk --mount dst=/x)"
assert_eq "  and only the options it checks need it" "0|" \
    "$(PATH="$TMPDIR/badperl:$PATH" chk --rm -e FOO=1 --name x)"
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
