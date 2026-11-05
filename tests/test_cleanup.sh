#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for launch.sh cleanup, with a fake docker CLI whose answers
# come from files, and real Git repositories for the checkout, the bare
# repo and the mirrors: the preservation check, the scans, the import of
# recovery refs and git fsck all run for real.  No Docker or API key
# required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
# Exported, so that the fake docker and the programs it runs make their
# scratch files here, under the cleanup below.
export TMPDIR
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH="$REPO_ROOT/launch.sh"
trap 'chmod -R u+rwX "$TMPDIR" 2>/dev/null; rm -rf "$TMPDIR"' EXIT

# The scanner asks git which config files it reads (git var, Git 2.42
# or later); here it runs on this host's git.
if ! git var GIT_CONFIG_SYSTEM >/dev/null 2>&1; then
    echo "SKIP: these tests need Git 2.42 or later (git var)"
    # The runner wants a summary from every file.
    echo "  0 passed, 0 failed"
    exit 0
fi

# shellcheck source=../lib/project.sh
source "$REPO_ROOT/lib/project.sh"

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

gitc() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}

P=proj
_ct=$(cd -P "$TMPDIR" && pwd -P)

# Fake docker.  $F holds the answers:
#   containers          "<id> <name>" lines of the project's containers
#   inspect/<id>        their docker container inspect JSON
#   volumes             the project's volume names, one per line
#   vollabels/<name>    a volume's labels (JSON)
#   voldir/<name>       a volume's files (scanned by the real scanner)
#   volusers/<name>     ids of containers using a volume
#   helpers             ids of cleanup helpers an earlier run left
#   remote-daemon       the daemon sees another file system (bind mounts
#                       show an empty directory)
#   daemon              docker info id (default d1)
#   helper-mountinfo    the mount table a deletion helper sees
#   volume-later        a volume name that docker volume ls adds once it
#                       was called volume-later-after times (default 1)
#   present-ids         ids docker ps --filter id= lists (none by default:
#                       a container whose inspect fails is gone)
#   log                 every call
F="$TMPDIR/fake"
mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/docker" <<'EOF'
#!/bin/bash
F="$FAKE_DOCKER"
printf '%s\n' "$*" >> "$F/log"
case "$1" in
    info) cat "$F/daemon" 2>/dev/null || echo d1; exit 0 ;;
    context) echo default; exit 0 ;;
    images) exit 0 ;;
    wait) exit 0 ;;
    rm)
        shift
        [ "$1" != -f ] || shift
        [ ! -e "$F/helper-rm-fails" ] || exit 1
        grep -vxF "$1" "$F/helpers" > "$F/helpers.new" 2>/dev/null || true
        mv "$F/helpers.new" "$F/helpers"
        exit 0 ;;
    ps)
        case "$*" in
            *"label=swarm-core.cleanup="*)
                [ ! -e "$F/ps-fails" ] || exit 1
                cat "$F/helpers"
                exit 0 ;;
            *"ancestor="*) exit 0 ;;
            *"volume="*)
                v=$(printf '%s\n' "$*" | sed -n 's/.*volume=\([^ ]*\).*/\1/p')
                cat "$F/volusers/$v" 2>/dev/null
                exit 0 ;;
            *"label=swarm-core.session="*) exit 0 ;;
            *" id="*) cat "$F/present-ids" 2>/dev/null ;;
            *"label=swarm-core.project="*)
                while read -r id name; do
                    [ -n "$id" ] || continue
                    jq -nc --arg id "$id" --arg n "$name" --arg o "$FAKE_CK" \
                        '{id: $id, name: $n, project: "proj", owner: $o}'
                done < "$F/containers" ;;
        esac
        exit 0 ;;
    container)
        [ "$2" = inspect ] || exit 1
        if [ "$3" = -f ] || [ "$3" = --format ]; then
            # A helper's state, from $F/helper-status.
            if grep -qxF "$5" "$F/helpers" 2>/dev/null \
                    && [ -f "$F/helper-status" ]; then
                cat "$F/helper-status"
                exit 0
            fi
            [ -f "$F/inspect/$5" ] || exit 1
            jq -r '.[0].Id' "$F/inspect/$5"
            exit 0
        fi
        [ -f "$F/inspect/$3" ] || exit 1
        cat "$F/inspect/$3"
        exit 0 ;;
    volume)
        case "$2" in
            ls)
                cat "$F/volumes"
                # A volume that shows up after the first listing.
                if [ -f "$F/volume-later" ]; then
                    listed=$(cat "$F/volume-listed" 2>/dev/null || echo 0)
                    if [ "$listed" -ge \
                            "$(cat "$F/volume-later-after" 2>/dev/null \
                                || echo 1)" ]; then
                        cat "$F/volume-later"
                    fi
                    echo $((listed + 1)) > "$F/volume-listed"
                fi
                exit 0 ;;
            rm)
                grep -qxF "$3" "$F/volumes" || exit 1
                grep -vxF "$3" "$F/volumes" > "$F/volumes.new" || true
                mv "$F/volumes.new" "$F/volumes"
                exit 0 ;;
            inspect)
                name="${*: -1}"
                grep -qxF "$name" "$F/volumes" || exit 1
                case "$*" in
                    *Mountpoint*) echo "/var/lib/docker/volumes/$name/_data" ;;
                    *"json .Labels"*) cat "$F/vollabels/$name" ;;
                    *swarm-core.context*) echo full ;;
                    *) echo "{}" ;;
                esac
                exit 0 ;;
        esac
        exit 1 ;;
    run)
        d=$(mktemp -d "$F/run.XXXXXX")
        # A volume scan: the real scanner over voldir/<volume>, its
        # script on stdin, its output streamed back as a tar.
        vol=$(printf '%s\n' "$*" \
            | sed -n 's/.*type=volume,src=\([^,]*\),.*/\1/p')
        if [ -n "$vol" ]; then
            cat > "$d/scan.sh"
            mkdir "$d/out"
            ctx="${*: -1}"
            bash "$d/scan.sh" worktree "$F/voldir/$vol" "$ctx" "$d/out" \
                >&2 || exit $?
            set -- report
            [ ! -f "$d/out/bundle" ] || set -- "$@" bundle
            [ ! -f "$d/out/objects" ] || set -- "$@" objects
            tar -C "$d/out" -cf - "$@"
            exit 0
        fi
        # A deletion helper: cleanup's own program, run here with the
        # bind mount's source in place of /runtime (an empty directory
        # when the daemon sees another file system).
        prog=""; prev=""; src=""
        for a in "$@"; do
            [ "$prev" != -c ] || prog="$a"
            case "$a" in
                type=bind,src=*)
                    src="${a#type=bind,src=}"
                    src="${src%%,dst=*}" ;;
            esac
            prev="$a"
        done
        rel="${*: -2:1}"
        token="${*: -1}"
        if [ -e "$F/remote-daemon" ]; then
            src="$d/elsewhere"
            mkdir -p "$src"
        fi
        prog="${prog//\/runtime/$src}"
        # Its mount table: helper-mountinfo (what the daemon shows it).
        prog="${prog//\/proc\/self\/mountinfo/$F/helper-mountinfo}"
        PATH="$ORIG_PATH" sh -c "$prog" sh "$rel" "$token"
        exit $? ;;
esac
exit 0
EOF
chmod +x "$TMPDIR/bin/docker"

# A shim rm that cannot delete what is under the runtime directory while
# $F/rm-fails exists: files the containers wrote as their own user, which
# only the Docker helper (root) can delete.
mkdir -p "$TMPDIR/bin-rm"
cat > "$TMPDIR/bin-rm/rm" <<'EOF'
#!/bin/bash
if [ -e "$FAKE_DOCKER/rm-fails" ]; then
    for a in "$@"; do
        case "$a" in
            "$FAKE_RT"/*) exit 1 ;;
        esac
    done
fi
exec /bin/rm "$@"
EOF
chmod +x "$TMPDIR/bin-rm/rm"

# A checkout with one commit; its bare repo and a mirror whose name has
# a space; the runtime directory, claimed, with engagement EID.
setup() {
    local eid="${1:-e1}" head
    chmod -R u+rwX "$TMPDIR/case" 2>/dev/null || true
    rm -rf "$TMPDIR/case" "$F"
    mkdir -p "$TMPDIR/case" "$F/inspect" "$F/vollabels" "$F/voldir" \
        "$F/volusers"
    : > "$F/containers"
    : > "$F/volumes"
    : > "$F/helpers"
    : > "$F/log"
    echo "1 0 0:1 / / rw - overlay overlay rw" > "$F/helper-mountinfo"
    REPO="$TMPDIR/case/proj"
    git init -q "$REPO"
    echo a > "$REPO/a"
    gitc -C "$REPO" add a
    gitc -C "$REPO" commit -qm init
    CK=$(cd -P "$REPO" && pwd -P)
    RT="$TMPDIR/case/runtime"
    mkdir -m 700 "$RT"
    swarm_runtime_claim "$RT" "$REPO" "$P"
    swarm_state_update "$RT/state.json" \
        '.engagement_id = $e | .docker_daemon = "d1"' --arg e "$eid"
    git clone -q --bare --no-hardlinks "$REPO" "$RT/upstream.git"
    head=$(git -C "$REPO" rev-parse HEAD)
    git -C "$RT/upstream.git" update-ref refs/heads/agent-work "$head"
    mkdir -p "$RT/mirrors"
    git init -q --bare "$RT/mirrors/lib space.git"
    gitc -C "$REPO" push -q "$RT/mirrors/lib space.git" HEAD:refs/heads/main
    : > "$RT/engagement.lock"
}

# Run launch.sh cleanup ARGS; print "<status>".  SHIM_DIR (when set)
# comes first on PATH.
SHIM_DIR=""
cleanup() {
    local rc=0 orig="$PATH"
    (cd "$REPO" && PATH="${SHIM_DIR:+$SHIM_DIR:}$TMPDIR/bin:$PATH" \
        ORIG_PATH="$orig" FAKE_DOCKER="$F" FAKE_CK="$CK" FAKE_RT="$RT" \
        SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
        "$BASH" "$LAUNCH" cleanup "$@" > "$TMPDIR/out" 2>&1) || rc=$?
    printf '%s' "$rc"
}
said() {
    grep -cF -- "$1" "$TMPDIR/out" | awk '{ print ($1 > 0) }'
}
present() {
    if [ -e "$1" ] || [ -L "$1" ]; then echo yes; else echo no; fi
}
recovery_refs() {
    git -C "$REPO" for-each-ref --format='%(refname)' refs/swarm-recovery/ \
        | grep -c . || true
}
refused() {
    local label="$1" expect="$2"
    assert_eq "$label: refused" "1" "$(cleanup "${@:3}")"
    assert_eq "$label: for that reason" "1" "$(said "$expect")"
    assert_eq "$label: the bare repo stays" "yes" \
        "$(present "$RT/upstream.git")"
    [ -z "${SHOW_REASON:-}" ] || grep -m1 '^ERROR' "$TMPDIR/out" \
        | sed 's/^/    reason: /' || true
}

echo "=== 1. Cleanup preserves, then deletes ==="
setup
# An object only the bare repo has, outside the preservation refs.
blob=$(printf 'only in the bare repo\n' \
    | git -C "$RT/upstream.git" hash-object -w --stdin)
git -C "$RT/upstream.git" update-ref refs/keep/extra "$blob"
assert_eq "cleanup succeeds" "0" "$(cleanup)"
assert_eq "the bare repo is gone" "no" "$(present "$RT/upstream.git")"
assert_eq "no remnant is left" "no" "$(present "$RT/upstream.git.removing")"
assert_eq "the mirror is gone" "no" "$(present "$RT/mirrors")"
assert_eq "the lock stays" "yes" "$(present "$RT/engagement.lock")"
assert_eq "the runtime directory stays" "yes" "$(present "$RT")"
assert_eq "the state keeps only the claim" '["project","repo_root","schema"]' \
    "$(jq -c 'keys' "$RT/state.json")"
assert_eq "recovery refs are written" "1" \
    "$(recovery_refs | awk '{ print ($1 > 0) }')"
e1hex=$(printf 'e1' | od -An -tx1 | tr -d ' \n')
base=$(git -C "$REPO" for-each-ref --format='%(refname)' \
    "refs/swarm-recovery/e${e1hex}/" \
    | sed -n 's|^\(refs/swarm-recovery/e[0-9a-f]*/[^/]*\)/.*|\1|p' \
    | sort -u)
assert_eq "one snapshot, under the engagement's hex" "1" \
    "$(printf '%s\n' "$base" | grep -c .)"
assert_eq "the object only the bare repo had is kept" "1" \
    "$(git -C "$REPO" rev-list --objects --all | grep -c "^$blob" || true)"
map=$(git -C "$REPO" cat-file blob "$base/sources")
assert_eq "the sources map names the bare repo" "1" \
    "$(printf '%s\n' "$map" | grep -c ' bare "' || true)"
assert_eq "and the mirror, its name kept" "1" \
    "$(printf '%s\n' "$map" | grep -cF 'mirror "' || true)"
assert_eq "a mirror name with a space still makes valid refs" "1" \
    "$(printf '%s\n' "$map" | grep -cF 'lib space.git"' || true)"
assert_eq "cleanup says where the refs are" "1" \
    "$(said "Recovery refs: $base/")"
# A second run has nothing left to do.
assert_eq "cleanup again finds no engagement" "0" "$(cleanup)"
assert_eq "and says so" "1" "$(said "nothing to clean up")"

# An engagement id that is no valid ref component still gives valid refs.
setup 'eng..1'
assert_eq "an engagement id with .. is fine" "0" "$(cleanup)"
assert_eq "its refs are under its hex" "1" \
    "$(git -C "$REPO" for-each-ref "refs/swarm-recovery/e$(printf 'eng..1' \
        | od -An -tx1 | tr -d ' \n')/" | grep -c . | awk '{ print ($1 > 0) }')"

echo ""
echo "=== 2. What stops cleanup before anything is deleted ==="
setup
rm "$RT/state.json"
assert_eq "no state file: refused" "1" "$(cleanup)"
assert_eq "for that reason" "1" "$(said "no state file")"
setup
echo d2 > "$F/daemon"
refused "another Docker daemon" "runs on Docker daemon d1"
setup
# A runtime directory of another project id (SWARM_RUNTIME_DIR kept,
# SWARM_PROJECT changed): cleanup would look for that project's
# containers and volumes, so it refuses before anything else.
setup
echo "id-c1 proj-agent-1" > "$F/containers"
cp "$RT/state.json" "$TMPDIR/state.before"
rc=0
_orig="$PATH"
(cd "$REPO" && PATH="$TMPDIR/bin:$PATH" ORIG_PATH="$_orig" \
    FAKE_DOCKER="$F" FAKE_CK="$CK" FAKE_RT="$RT" \
    SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT=other SWARM_SKIP_DEP_CHECK=1 \
    "$BASH" "$LAUNCH" cleanup > "$TMPDIR/out" 2>&1) || rc=$?
assert_eq "a runtime of another project id: refused" "1" "$rc"
assert_eq "for that reason" "1" "$(said "belongs to project id 'proj'")"
assert_eq "its bare repo stays" "yes" "$(present "$RT/upstream.git")"
assert_eq "and its state file" "same" \
    "$(cmp -s "$TMPDIR/state.before" "$RT/state.json" && echo same)"
assert_eq "Docker made or removed nothing" "0" \
    "$(grep -cE '^(run|create|rm|volume rm|commit|stop|kill)' "$F/log" \
        || true)"
# Another checkout of the project id claims the runtime and starts
# between this cleanup's first checks and its lock (a flock first on
# PATH writes that claim once, then locks): cleanup checks again under
# the lock and leaves that checkout's engagement alone.
mkdir -p "$TMPDIR/bin-flock"
cat > "$TMPDIR/bin-flock/flock" <<'EOF'
#!/bin/bash
if [ -n "${FLOCK_CLAIM:-}" ] && [ ! -e "$FAKE_RT/claimed" ]; then
    : > "$FAKE_RT/claimed"
    st="$FAKE_RT/state.json"
    jq -c --arg r "$FLOCK_CLAIM" '.repo_root = $r' "$st" > "$st.new"
    chmod 600 "$st.new"
    mv "$st.new" "$st"
fi
PATH="$ORIG_PATH" exec flock "$@"
EOF
chmod +x "$TMPDIR/bin-flock/flock"
setup
mkdir -p "$TMPDIR/case/other"
_other=$(cd -P "$TMPDIR/case/other" && pwd -P)
swarm_state_update "$RT/state.json" 'del(.repo_root)'
SHIM_DIR="$TMPDIR/bin-flock"
assert_eq "a runtime another checkout claims before the lock: refused" "1" \
    "$(FLOCK_CLAIM="$_other" cleanup)"
SHIM_DIR=""
assert_eq "for that reason" "1" "$(said "belongs to another checkout")"
assert_eq "that checkout's bare repo stays" "yes" \
    "$(present "$RT/upstream.git")"
assert_eq "and its mirror" "yes" "$(present "$RT/mirrors/lib space.git")"
assert_eq "no recovery refs are written" "0" "$(recovery_refs)"
assert_eq "Docker removed nothing" "0" \
    "$(grep -cE '^(rm|volume rm|commit|stop|kill)' "$F/log" || true)"
setup

# The engagement lock is held by another process.
(
    exec 9>>"$RT/engagement.lock"
    flock -n 9
    sleep 30
) &
_holder=$!
sleep 1
refused "the lock held by another command" "another swarm-core operation"
kill "$_holder" 2>/dev/null || true
wait "$_holder" 2>/dev/null || true
setup
sleep 60 &
_live=$!
swarm_pending_write "$RT" proj-agent-interactive-x "$_live" d1
refused "an interactive session starting" "interactive sessions are open"
kill "$_live" 2>/dev/null || true
wait "$_live" 2>/dev/null || true
setup
# Agent work the checkout does not have: harvest first.
gitc -C "$REPO" checkout -q -b side
echo b > "$REPO/b"
gitc -C "$REPO" add b
gitc -C "$REPO" commit -qm side
gitc -C "$REPO" push -q "$RT/upstream.git" \
    side:refs/heads/agent-work 2>/dev/null \
    || git -C "$RT/upstream.git" fetch -q "$REPO" "+side:agent-work"
gitc -C "$REPO" checkout -q -
gitc -C "$REPO" branch -q -D side
refused "agent work the checkout lacks" "agent-work"
assert_eq "nothing is copied then" "0" "$(recovery_refs)"
setup
# A container of the project (before workspace volumes: retire refuses).
echo "id-c1 proj-agent-1" > "$F/containers"
jq -n --arg ck "$CK" '[{Id: "id-c1", Name: "/proj-agent-1",
    State: {Status: "exited"}, HostConfig: {RestartPolicy: {Name: "no"}},
    Mounts: [{Type: "bind", Source: "/x", Destination: "/workspace"}],
    Config: {Labels: {"swarm-core.project": "proj",
        "swarm-core.checkout": $ck}}}]' > "$F/inspect/id-c1"
refused "a container that cannot be retired" "every container must be retired"
setup
echo notes > "$RT/mirrors/notes.txt"
refused "a file in mirrors/ that is not a mirror" "holds what is not a mirror"
assert_eq "the file stays" "yes" "$(present "$RT/mirrors/notes.txt")"
setup
mv "$RT/mirrors/lib space.git" "$RT/mirrors/lib"$'\t'"tab.git"
refused "a mirror name with a tab" "names with a tab or a newline"
# A runtime directory whose own path holds a tab.
setup
mv "$RT" "$TMPDIR/case/run"$'\t'"time"
RT="$TMPDIR/case/run"$'\t'"time"
refused "a runtime directory with a tab in its path" "a tab or a newline"
# The home directory, and a runtime directory inside the checkout.
setup
assert_eq "a runtime directory that is HOME: refused" "1" \
    "$(HOME="$RT" cleanup)"
assert_eq "for that reason" "1" "$(said "as the runtime directory")"
assert_eq "its bare repo stays" "yes" "$(present "$RT/upstream.git")"
setup
mv "$RT" "$REPO/rt"
RT="$REPO/rt"
refused "a runtime directory inside the checkout" \
    "is inside the checkout or its git dir"
# A linked worktree whose own git dir someone moved into mirrors/: its
# checkout must not lose it (the common git dir is elsewhere).
setup
WT="$TMPDIR/case/wt"
git -C "$REPO" worktree add -q "$WT" -b wtbranch
gd=$(git -C "$WT" rev-parse --absolute-git-dir)
mv "$gd" "$RT/mirrors/wt"
printf 'gitdir: %s\n' "$RT/mirrors/wt" > "$WT/.git"
(cd -P "$REPO/.git" && pwd -P) > "$RT/mirrors/wt/commondir"
printf '%s\n' "$WT/.git" > "$RT/mirrors/wt/gitdir"
swarm_state_update "$RT/state.json" '.repo_root = $r' \
    --arg r "$(cd -P "$WT" && pwd -P)"
# Run from the worktree, which the runtime directory now belongs to.
REPO="$WT"
CK=$(cd -P "$WT" && pwd -P)
assert_eq "a checkout whose git dir is in the runtime directory: refused" \
    "1" "$(cleanup)"
assert_eq "for that reason" "1" "$(said "holds the checkout")"
assert_eq "its git dir stays" "yes" "$(present "$RT/mirrors/wt/HEAD")"
assert_eq "and the worktree still works" "wtbranch" \
    "$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
# A file over the size limit (lowered through the scanner's environment).
setup
head -c 3000 /dev/urandom > "$RT/upstream.git/rescue.patch"
export SWARM_SCAN_FILE_LIMIT=1000
refused "a large file in the bare repo" "holds work outside Git's history"
assert_eq "--discard-uncommitted drops exactly that" "0" \
    "$(cleanup --discard-uncommitted)"
assert_eq "and lists it" "1" "$(said "large-file rescue.patch 3000")"
unset SWARM_SCAN_FILE_LIMIT
setup
# A corrupt object only the checkout has (the import never reads it):
# the final git fsck fails, and nothing is deleted.
obj=$(printf 'only in the checkout\n' | git -C "$REPO" hash-object -w --stdin)
f="$REPO/.git/objects/${obj:0:2}/${obj:2}"
chmod u+w "$f"
printf 'garbage' > "$f"
refused "a checkout git fsck finds broken" "git fsck found problems"
# The sources ref comes only after git fsck: a snapshot with one is a
# verified copy.
assert_eq "and no sources ref names that snapshot" "0" \
    "$(git -C "$REPO" for-each-ref 'refs/swarm-recovery/*/*/sources' \
        | wc -l | tr -d ' ')"

echo ""
echo "=== 3. Workspace volumes ==="
# Add volume NAME of this checkout holding a committed repository (or
# nothing, with EMPTY set).
add_volume() {
    local name="$1" empty="${2:-}"
    printf '%s\n' "$name" >> "$F/volumes"
    jq -n --arg ck "$CK" '{"swarm-core.project": "proj",
        "swarm-core.checkout": $ck, "swarm-core.context": "full"}' \
        > "$F/vollabels/$name"
    mkdir -p "$F/voldir/$name"
    if [ -z "$empty" ]; then
        git init -q "$F/voldir/$name"
        echo w > "$F/voldir/$name/w"
        gitc -C "$F/voldir/$name" add w
        gitc -C "$F/voldir/$name" commit -qm work
    fi
}
setup
add_volume proj-agent-1-ws-00000001
add_volume proj-agent-2-ws-00000002
assert_eq "two volumes: cleanup succeeds" "0" "$(cleanup)"
# Scanned twice each: before retire, and again once it is done.
assert_eq "both are scanned" "4" "$(grep -c 'type=volume,src=' "$F/log")"
assert_eq "both are removed" "0" "$(grep -c . "$F/volumes" || true)"
assert_eq "their work is kept" "1" \
    "$(git -C "$REPO" for-each-ref refs/swarm-recovery/ | grep -c . \
        | awk '{ print ($1 > 0) }')"
setup
add_volume proj-agent-1-ws-00000001 empty
assert_eq "an empty volume: cleanup succeeds" "0" "$(cleanup)"
assert_eq "and removes it" "0" "$(grep -c . "$F/volumes" || true)"
setup
add_volume proj-agent-1-ws-00000001
echo dirty > "$F/voldir/proj-agent-1-ws-00000001/w"
refused "uncommitted work in a volume" "holds work outside Git's history"
assert_eq "the volume stays" "1" "$(grep -c . "$F/volumes")"
assert_eq "--discard-uncommitted drops it" "0" \
    "$(cleanup --discard-uncommitted)"
setup
add_volume proj-agent-1-ws-00000001
echo id-x > "$F/volusers/proj-agent-1-ws-00000001"
refused "a volume a container uses" "is in use by containers"
setup
add_volume proj-agent-1-ws-00000001
jq -n '{"swarm-core.project": "proj", "swarm-core.checkout": "/elsewhere"}' \
    > "$F/vollabels/proj-agent-1-ws-00000001"
refused "a volume of another checkout" "is not this checkout's"

echo ""
echo "=== 4. A run that stops half way, and the next one ==="
# The first run stops at its first deletion: this user's rm cannot
# delete, and the Docker helper sees another file system.
first_run_stops() {
    : > "$F/rm-fails"
    : > "$F/remote-daemon"
    SHIM_DIR="$TMPDIR/bin-rm"
    assert_eq "the first run stops" "1" "$(cleanup)"
    assert_eq "because the helper sees another directory" "1" \
        "$(said "not the same directory")"
    SHIM_DIR=""
    rm -f "$F/rm-fails" "$F/remote-daemon"
}
setup
first_run_stops
assert_eq "the mirror was renamed, not deleted" "yes" \
    "$(present "$RT/mirrors/lib space.git.removing")"
assert_eq "the checkpoint is there" "true" \
    "$(jq 'has("cleanup")' "$RT/state.json")"
rc=0
swarm_cleanup_pending_check "$RT/state.json" 2>/dev/null || rc=$?
assert_eq "other commands refuse meanwhile" "1" "$rc"
rc=0
(cd "$REPO" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    "$BASH" "$REPO_ROOT/harvest.sh" > "$TMPDIR/hout" 2>&1) || rc=$?
assert_eq "harvest refuses meanwhile" "1" "$rc"
assert_eq "saying a cleanup is in progress" "1" \
    "$(grep -c 'cleanup in progress' "$TMPDIR/hout" || true)"
echo rescue > "$RT/mirrors/lib space.git.removing/rescue.txt"
assert_eq "the next run finishes" "0" "$(cleanup)"
assert_eq "the remnant is gone" "no" \
    "$(present "$RT/mirrors/lib space.git.removing")"
assert_eq "so is the bare repo" "no" "$(present "$RT/upstream.git")"
assert_eq "the checkpoint is gone" "false" \
    "$(jq 'has("cleanup")' "$RT/state.json")"
assert_eq "two snapshots were written" "2" \
    "$(git -C "$REPO" for-each-ref --format='%(refname)' refs/swarm-recovery/ \
        | sed -n 's|^refs/swarm-recovery/e[0-9a-f]*/\([^/]*\)/.*|\1|p' \
        | sort -u | grep -c .)"
assert_eq "a file added to the remnant between runs is kept" "1" \
    "$(git -C "$REPO" rev-list --objects --all \
        | grep -c "^$(printf 'rescue\n' | git hash-object --stdin)" || true)"
# Something mounted under a remnant that the daemon shows the deletion
# helper and this host does not see: the helper finds it in its own
# mount table and deletes nothing.  (The table writes the space in the
# path as \040.)
setup
mkdir -p "$RT/mirrors/lib space.git/sub"
echo keep > "$RT/mirrors/lib space.git/sub/sentinel"
: > "$F/rm-fails"
SHIM_DIR="$TMPDIR/bin-rm"
printf '36 25 0:32 / %s rw - tmpfs tmpfs rw\n' \
    "$(printf '%s' "$RT/mirrors/lib space.git.removing/sub" \
        | sed 's/ /\\040/g')" >> "$F/helper-mountinfo"
assert_eq "a mount only the daemon sees: refused" "1" "$(cleanup)"
assert_eq "for that reason" "1" "$(said "something is mounted in it")"
assert_eq "what is mounted there stays" "yes" \
    "$(present "$RT/mirrors/lib space.git.removing/sub/sentinel")"
SHIM_DIR=""
rm -f "$F/rm-fails"
# A mount table the helper cannot read (here: a directory in its
# place): it deletes nothing either.
setup
mkdir -p "$RT/mirrors/lib space.git/sub"
echo keep > "$RT/mirrors/lib space.git/sub/sentinel"
: > "$F/rm-fails"
SHIM_DIR="$TMPDIR/bin-rm"
rm -f "$F/helper-mountinfo"
mkdir "$F/helper-mountinfo"
assert_eq "a mount table that cannot be read: refused" "1" "$(cleanup)"
assert_eq "for that reason" "1" "$(said "cannot read the mount table")"
assert_eq "and the remnant keeps its files" "yes" \
    "$(present "$RT/mirrors/lib space.git.removing/sub/sentinel")"
SHIM_DIR=""
rm -f "$F/rm-fails"
# A link planted in a remnant this user cannot clean (here: rm fails)
# does not redirect cleanup's marker onto a file outside.
setup
first_run_stops
echo precious > "$TMPDIR/case/external"
ln -sf "$TMPDIR/case/external" \
    "$RT/mirrors/lib space.git.removing/.swarm-cleanup-token"
: > "$F/rm-fails"
SHIM_DIR="$TMPDIR/bin-rm"
assert_eq "with a link planted in the remnant: the next run finishes" "0" \
    "$(cleanup)"
SHIM_DIR=""
rm -f "$F/rm-fails"
assert_eq "the file the link points to is untouched" "precious" \
    "$(cat "$TMPDIR/case/external")"
# A remnant that is itself a link is not followed.
setup
mkdir -p "$TMPDIR/case/elsewhere"
ln -s "$TMPDIR/case/elsewhere" "$RT/upstream.git.new.removing"
refused "a remnant that is a link" "is a link; cleanup will not follow it"
assert_eq "what it points to stays" "yes" "$(present "$TMPDIR/case/elsewhere")"
# A remnant a deletion got part of the way through: no HEAD left.
setup
first_run_stops
rm -f "$RT/mirrors/lib space.git.removing/HEAD"
assert_eq "a remnant without HEAD: the next run finishes" "0" "$(cleanup)"
assert_eq "the remnant is gone" "no" \
    "$(present "$RT/mirrors/lib space.git.removing")"
# Recovery refs an earlier run wrote, deleted or changed since.
setup
first_run_stops
ref=$(git -C "$REPO" for-each-ref --format='%(refname)' refs/swarm-recovery/ \
    | grep '/s[0-9]*/' | head -n 1)
git -C "$REPO" update-ref -d "$ref"
refused "a recovery ref of the first run deleted" "changed or went"
assert_eq "the remnant stays" "yes" \
    "$(present "$RT/mirrors/lib space.git.removing")"
setup
first_run_stops
ref=$(git -C "$REPO" for-each-ref --format='%(refname)' refs/swarm-recovery/ \
    | grep '/sources$' | head -n 1)
git -C "$REPO" update-ref "$ref" "$(git -C "$REPO" rev-parse HEAD)"
refused "the sources map retargeted" "changed or went"
# A helper container a killed run left is waited for and removed first.
setup
echo id-helper > "$F/helpers"
assert_eq "a helper left by a killed run: cleanup succeeds" "0" "$(cleanup)"
assert_eq "it was checked" "1" \
    "$(grep -c 'container inspect -f {{.State.Status}} id-helper' "$F/log")"
assert_eq "and removed" "1" "$(grep -c '^rm id-helper$' "$F/log")"
setup
echo id-helper > "$F/helpers"
: > "$F/helper-rm-fails"
refused "a helper that cannot be removed" "an earlier cleanup left remain"
setup
echo id-helper > "$F/helpers"
echo running > "$F/helper-status"
export SWARM_CLEANUP_HELPER_WAIT=1
refused "a helper still running after the wait" "is still running after 1s"
unset SWARM_CLEANUP_HELPER_WAIT
setup
: > "$F/ps-fails"
refused "helpers that cannot be listed" "cannot list Docker containers"
# A hidden mirror (a submodule named with a leading dot) left half way.
setup
rm -rf "$RT/mirrors/lib space.git"
git init -q --bare "$RT/mirrors/.hidden.git"
gitc -C "$REPO" push -q "$RT/mirrors/.hidden.git" HEAD:refs/heads/main
first_run_stops
assert_eq "a hidden mirror was renamed" "yes" \
    "$(present "$RT/mirrors/.hidden.git.removing")"
assert_eq "the next run finishes it" "0" "$(cleanup)"
assert_eq "the hidden remnant is gone" "no" \
    "$(present "$RT/mirrors/.hidden.git.removing")"
assert_eq "and mirrors/ with it" "no" "$(present "$RT/mirrors")"

# Run cleanup's function ARGS in a subshell with the case's variables
# and the fake docker; with FAIL_BARE set, writing the bare repo's line
# fails.  Print its status.
in_cleanup() {
    local rc=0
    (
        # shellcheck source=../lib/preserve.sh
        source "$REPO_ROOT/lib/preserve.sh"
        # shellcheck source=../lib/retire.sh
        source "$REPO_ROOT/lib/retire.sh"
        # shellcheck source=../lib/cleanup.sh
        source "$REPO_ROOT/lib/cleanup.sh"
        # shellcheck disable=SC2034  # read by the functions run here
        RUNTIME_DIR="$RT" MIRROR_DIR="$RT/mirrors" \
            STATE_FILE="$RT/state.json" BARE_REPO="$RT/upstream.git" \
            PROJECT="$P" CHECKOUT_PATH="$CK"
        # shellcheck disable=SC2329
        docker() {
            FAKE_DOCKER="$F" FAKE_CK="$CK" "$TMPDIR/bin/docker" "$@"
        }
        if [ -n "${FAIL_BARE:-}" ]; then
            # shellcheck disable=SC2329
            printf() {
                case "$1" in
                    bare*) return 1 ;;
                esac
                # shellcheck disable=SC2059  # printf's own arguments
                builtin printf "$@"
            }
        fi
        "$@"
    ) > "$TMPDIR/out" 2>&1 || rc=$?
    builtin printf '%s' "$rc"
}

# cleanup retires the containers through retire, which keeps the Git
# checkouts in their layers; --discard-uncommitted goes on to it.
# shellcheck disable=SC2016  # expanded by the eval
in_cleanup eval 'retire_run() { echo "retire:$*"; }; CLEANUP_DISCARD=true; cleanup_retire' > /dev/null
assert_eq "cleanup --discard-uncommitted reaches retire" "retire:--discard-uncommitted" \
    "$(cat "$TMPDIR/out")"
# shellcheck disable=SC2016  # expanded by the eval
in_cleanup eval 'retire_run() { echo "retire:$*"; }; CLEANUP_DISCARD=false; cleanup_retire' > /dev/null
assert_eq "and only with it" "retire:" "$(cat "$TMPDIR/out")"

# Only what lies in the runtime directory (or its mirrors/) is ever
# renamed or deleted, whatever path the deletion is handed.
setup
mkdir -p "$TMPDIR/case/outside"
echo keep > "$TMPDIR/case/outside/f"
assert_eq "a deletion outside the runtime directory is refused" "1" \
    "$(in_cleanup cleanup_delete_host s1 "$TMPDIR/case/outside")"
assert_eq "for that reason" "1" "$(said "is not in")"
assert_eq "and what is there stays" "yes" "$(present "$TMPDIR/case/outside/f")"

# A failed write to the list of sources stops cleanup: a location left
# out of it would be neither preserved nor deleted.
setup
assert_eq "the sources are listed" "0" \
    "$(in_cleanup cleanup_sources "$TMPDIR/list")"
assert_eq "the bare repo among them" "1" \
    "$(grep -c "^bare" "$TMPDIR/list" || true)"
assert_eq "a write to that list that fails stops it" "1" \
    "$(FAIL_BARE=1 in_cleanup cleanup_sources "$TMPDIR/list")"
if [ -w /dev/full ]; then
    assert_eq "so does a full disk (/dev/full)" "1" \
        "$(in_cleanup cleanup_sources /dev/full)"
fi

# Before the engagement's records go, cleanup lists the sources again:
# one that showed up meanwhile keeps them.
setup
echo "${P}-late-ws-00000001" > "$F/volume-later"
# Listed first before retire, then after it: it shows up in the last
# listing, the one before the engagement's records go.
echo 2 > "$F/volume-later-after"
assert_eq "a volume that shows up during cleanup: refused" "1" "$(cleanup)"
assert_eq "for that reason" "1" "$(said "left these in place")"
assert_eq "the checkpoint stays" "true" \
    "$(jq 'has("cleanup")' "$RT/state.json")"
assert_eq "and so does the engagement" "e1" \
    "$(jq -r '.engagement_id' "$RT/state.json")"

# A read that fails part of the way through a list (an I/O error) ends
# the loop as the end of the list would.  Sourced through BASH_ENV by
# the bash that runs cleanup, this makes the HOOK_AT-th read whose last
# variable is HOOK_VAR fail (HOOK_DO=fail), or first drop the bare
# repo's record from the checkpoint (HOOK_DO=drop); every other read
# works.
cat > "$TMPDIR/hook.sh" <<'EOF'
read() {
    local c
    if [ "$#" -ge 4 ] && [ "$2" = -u ] && [ "${!#}" = "$HOOK_VAR" ]; then
        c=$(( $(cat "$HOOK_COUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$c" > "$HOOK_COUNT"
        if [ "$c" -eq "$HOOK_AT" ]; then
            case "$HOOK_DO" in
                fail) return 1 ;;
                drop)
                    jq -c 'del(.cleanup.runs[-1].sources[]
                        | select(.kind == "bare"))' "$STATE_FILE" \
                        > "$STATE_FILE.new" \
                        && mv "$STATE_FILE.new" "$STATE_FILE" ;;
            esac
        fi
    fi
    builtin read "$@"
}
EOF
# Run cleanup with that hook: hooked VAR AT DO.
hooked() {
    rm -f "$TMPDIR/hook.count"
    BASH_ENV="$TMPDIR/hook.sh" HOOK_VAR="$1" HOOK_AT="$2" HOOK_DO="$3" \
        HOOK_COUNT="$TMPDIR/hook.count" cleanup
}
# The sources here: s1 the mirror, s2 the bare repo.
setup
assert_eq "a read that fails while preserving: refused" "1" \
    "$(hooked mode 2 fail)"
assert_eq "for that reason" "1" "$(said "preserved 1 of the 2 locations")"
assert_eq "the mirror stays" "yes" "$(present "$RT/mirrors/lib space.git")"
assert_eq "so does the bare repo" "yes" "$(present "$RT/upstream.git")"
assert_eq "and no checkpoint is written" "false" \
    "$(jq 'has("cleanup")' "$RT/state.json")"
# The storage pass reads the list three times (two lines, then its
# end); the fifth read is the scan pass's second.
setup
assert_eq "a read that fails while scanning: refused" "1" \
    "$(hooked path 5 fail)"
assert_eq "for that reason" "1" "$(said "scanned 1 of the 2 locations")"
assert_eq "the bare repo stays" "yes" "$(present "$RT/upstream.git")"
# With a volume as third source, the storage pass's third read is the
# volume's: failing, it would leave the volume's Mountpoint out of the
# storage check.
setup
add_volume proj-agent-1-ws-00000001
assert_eq "a read that fails while checking the storage: refused" "1" \
    "$(hooked path 3 fail)"
assert_eq "for that reason" "1" \
    "$(said "checked the storage of 2 of the 3 locations")"
assert_eq "the volume stays" "1" \
    "$(grep -c proj-agent-1-ws-00000001 "$F/volumes" || true)"
# The checkpoint loses the bare repo's record before the first deletion
# (the preservation pass reads three times, the deletion pass next).
setup
assert_eq "a source with no record in the checkpoint: refused" "1" \
    "$(hooked mode 4 drop)"
assert_eq "for that reason" "1" "$(said "has no record that")"
assert_eq "the bare repo stays where it is" "yes" \
    "$(present "$RT/upstream.git")"
# A run after one that stopped: a read that fails while checking the
# recovery refs of the earlier run.
setup
first_run_stops
assert_eq "a read that fails while checking earlier runs: refused" "1" \
    "$(hooked want 1 fail)"
assert_eq "for that reason" "1" \
    "$(said "cannot read the recovery records")"
assert_eq "the remnant stays" "yes" \
    "$(present "$RT/mirrors/lib space.git.removing")"

# Nothing may be mounted in the runtime directory: deleting there would
# delete what the mount shows.
if [ ! -r /proc/self/mountinfo ]; then
    # This host lists its mounts with mount(8); a fake one shows one.
    mkdir -p "$TMPDIR/bin-mount"
    cat > "$TMPDIR/bin-mount/mount" <<'EOF'
#!/bin/bash
echo "/dev/disk9 on $(cd -P "$FAKE_RT" && pwd -P)/mirrors/x (nullfs, local)"
EOF
    chmod +x "$TMPDIR/bin-mount/mount"
    setup
    SHIM_DIR="$TMPDIR/bin-mount"
    refused "something mounted in the runtime directory" \
        "something is mounted in"
    SHIM_DIR=""
elif unshare -rm true 2>/dev/null; then
    # A linked worktree's own git dir, bind-mounted (in a user and mount
    # namespace of its own) where a remnant would be.
    setup
    WT="$TMPDIR/case/wt"
    git -C "$REPO" worktree add -q "$WT" -b wtbranch
    gd=$(git -C "$WT" rev-parse --absolute-git-dir)
    wtck=$(cd -P "$WT" && pwd -P)
    swarm_state_update "$RT/state.json" '.repo_root = $r' --arg r "$wtck"
    mkdir "$RT/mirrors/w t.removing"
    rc=0
    orig="$PATH"
    (cd "$WT" && PATH="$TMPDIR/bin:$PATH" ORIG_PATH="$orig" \
        FAKE_DOCKER="$F" FAKE_CK="$wtck" FAKE_RT="$RT" \
        SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
        unshare -rm "$BASH" -c \
            'mount --bind "$1" "$2" && exec "$BASH" "$3" cleanup' sh \
            "$gd" "$RT/mirrors/w t.removing" "$LAUNCH") \
        > "$TMPDIR/out" 2>&1 || rc=$?
    assert_eq "a bind mount in the runtime directory: refused" "1" "$rc"
    assert_eq "for that reason" "1" "$(said "something is mounted in")"
    assert_eq "the worktree's git dir keeps its HEAD" "yes" \
        "$(present "$gd/HEAD")"
    assert_eq "and the worktree still works" "wtbranch" \
        "$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null)"
else
    echo "  SKIP: no bind mount here (unshare -rm)"
fi

echo ""
echo "=== 5. Commands that wait for a pending cleanup ==="
# Run launch.sh ARGS (another command than cleanup) with a small
# swarmfile; print "<status>".
lifecycle() {
    local rc=0 orig="$PATH"
    (cd "$REPO" && PATH="$TMPDIR/bin:$PATH" \
        ORIG_PATH="$orig" FAKE_DOCKER="$F" FAKE_CK="$CK" FAKE_RT="$RT" \
        SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
        SWARM_CONFIG="$TMPDIR/case/swarm.json" \
        "$BASH" "$LAUNCH" "$@" > "$TMPDIR/out" 2>&1) || rc=$?
    printf '%s' "$rc"
}
# With a cleanup half done, every lifecycle command stops before it
# creates or replaces anything, whether the bare repo is still there,
# renamed or gone.  Each command starts from its own half-done cleanup.
for bare in present renamed gone; do
    for cmd in start post-process interactive stop; do
        setup
        first_run_stops
        case "$bare" in
            renamed) mv "$RT/upstream.git" "$RT/upstream.git.removing" ;;
            gone) rm -rf "$RT/upstream.git" ;;
        esac
        printf '%s\n' '{ "prompt": "p.md", "agents": [{ "count": 1,
            "model": "m" }], "post_process": { "prompt": "p.md" } }' \
            > "$TMPDIR/case/swarm.json"
        echo p > "$REPO/p.md"
        (cd "$RT" && find . | LC_ALL=C sort) > "$TMPDIR/before"
        cp "$RT/state.json" "$TMPDIR/state.before"
        : > "$F/log"
        what="bare repo ${bare}, ${cmd}"
        assert_eq "${what}: refused" "1" "$(lifecycle "$cmd")"
        assert_eq "${what}: for that reason" "1" \
            "$(said "cleanup in progress")"
        (cd "$RT" && find . | LC_ALL=C sort) > "$TMPDIR/after"
        assert_eq "${what}: the runtime directory is as it was" "" \
            "$(diff "$TMPDIR/before" "$TMPDIR/after" || true)"
        assert_eq "${what}: so is the state file" "same" \
            "$(cmp -s "$TMPDIR/state.before" "$RT/state.json" \
                && echo same)"
        assert_eq "${what}: Docker made or removed nothing" "0" \
            "$(grep -cE '^(run|create|rm|volume|build|stop|kill)' \
                "$F/log" || true)"
    done
done

echo ""
echo "=== 6. Engagements of earlier releases, and runs cut off ==="
# An engagement an earlier release started records no Docker daemon:
# cleanup refuses it, says how to finish it, and changes nothing.
docker_changes() {
    grep -cE '^(run|create|rm|volume rm|commit|stop|kill)' "$F/log" || true
}
setup
swarm_state_update "$RT/state.json" 'del(.docker_daemon)'
cp "$RT/state.json" "$TMPDIR/state.before"
refused "an earlier release's engagement" \
    "Finish it with the release that made it"
assert_eq "its state file stays as it was" "same" \
    "$(cmp -s "$TMPDIR/state.before" "$RT/state.json" && echo same)"
assert_eq "its mirror stays" "yes" "$(present "$RT/mirrors/lib space.git")"
assert_eq "nothing is copied" "0" "$(recovery_refs)"
assert_eq "Docker made or removed nothing" "0" "$(docker_changes)"
# What an engagement leaves, with none recorded, is an earlier release's
# too: the bare repo, a hidden remnant, a container, a volume.
for _left in bare hidden container volume; do
    setup
    swarm_state_update "$RT/state.json" 'del(.engagement_id, .docker_daemon)'
    rm -rf "$RT/mirrors"
    [ "$_left" = bare ] || rm -rf "$RT/upstream.git"
    case "$_left" in
        hidden) mkdir "$RT/.x.removing" ;;
        container) echo "id-c1 proj-agent-1" > "$F/containers" ;;
        volume) echo proj-agent-1-ws-00000001 > "$F/volumes" ;;
    esac
    cp "$RT/state.json" "$TMPDIR/state.before"
    assert_eq "$_left without an engagement: refused" "1" "$(cleanup)"
    assert_eq "$_left without an engagement: as an earlier release's" "1" \
        "$(said "Finish it with the release that made it")"
    assert_eq "$_left without an engagement: state as it was" "same" \
        "$(cmp -s "$TMPDIR/state.before" "$RT/state.json" && echo same)"
    assert_eq "$_left without an engagement: Docker changed nothing" "0" \
        "$(docker_changes)"
    if [ "$_left" = hidden ]; then
        assert_eq "the hidden remnant stays" "yes" \
            "$(present "$RT/.x.removing")"
    fi
done

# Runs cut off while they made the bare repo and a mirror: each left a
# .new without HEAD and with part of the objects, under the recorded
# engagement.  cleanup keeps their files (files mode) and removes them.
setup
mv "$RT/upstream.git" "$TMPDIR/case/bare.full"
mkdir -p "$RT/upstream.git.new/objects"
cp -R "$TMPDIR/case/bare.full/objects/." "$RT/upstream.git.new/objects/"
rm -rf "$TMPDIR/case/bare.full"
mkdir -p "$RT/mirrors/.sub.git.new/objects/pack"
head -c 2000 /dev/urandom > "$RT/mirrors/.sub.git.new/objects/pack/tmp_pack_x"
assert_eq "two runs cut off half way: cleanup succeeds" "0" "$(cleanup)"
assert_eq "the bare repo's .new is removed" "no" \
    "$(present "$RT/upstream.git.new")"
assert_eq "so is the hidden mirror's" "no" \
    "$(present "$RT/mirrors/.sub.git.new")"
_base=$(git -C "$REPO" for-each-ref --format='%(refname)' refs/swarm-recovery/ \
    | sed -n 's|^\(refs/swarm-recovery/e[0-9a-f]*/[^/]*\)/.*|\1|p' | sort -u)
_map=$(git -C "$REPO" cat-file blob "$_base/sources" 2>/dev/null || true)
assert_eq "both are recorded as cut-off creations" "2" \
    "$(printf '%s\n' "$_map" | grep -c ' new "' || true)"
assert_eq "their files are kept" "1" \
    "$(git -C "$REPO" for-each-ref "$_base/" | grep -c '/files$' \
        | awk '{ print ($1 > 0) }')"

# A stopped container whose volume holds uncommitted work: cleanup's
# first pass refuses while the container is still there, so its logs
# and its volume stay (retire never ran).
setup
add_volume proj-agent-1-ws-00000001
echo dirty > "$F/voldir/proj-agent-1-ws-00000001/w"
echo "id-c1 proj-agent-1" > "$F/containers"
jq -n --arg ck "$CK" '[{Id: "id-c1", Name: "/proj-agent-1",
    State: {Status: "exited"},
    HostConfig: {RestartPolicy: {Name: "no"}, AutoRemove: false},
    Mounts: [{Type: "volume", Name: "proj-agent-1-ws-00000001",
        Destination: "/workspace"}],
    Config: {Labels: {"swarm-core.project": "proj",
        "swarm-core.checkout": $ck}}}]' > "$F/inspect/id-c1"
echo id-c1 > "$F/volusers/proj-agent-1-ws-00000001"
refused "uncommitted work while the container is there" \
    "holds work outside Git's history"
assert_eq "retire never ran: no container removed" "0" \
    "$(grep -cE '^(rm|commit|stop|kill)' "$F/log" || true)"
assert_eq "the container is still listed" "1" \
    "$(grep -c proj-agent-1 "$F/containers")"
assert_eq "and its volume stays" "1" "$(grep -c . "$F/volumes")"

# A container that still runs: refused before any scan, with the step
# to take (stop the agents), not --discard-uncommitted for what its
# changing workspace holds.
setup
add_volume proj-agent-1-ws-00000001
echo dirty > "$F/voldir/proj-agent-1-ws-00000001/w"
echo "id-c1 proj-agent-1" > "$F/containers"
jq -n --arg ck "$CK" '[{Id: "id-c1", Name: "/proj-agent-1",
    State: {Status: "running"},
    HostConfig: {RestartPolicy: {Name: "no"}, AutoRemove: false},
    Mounts: [{Type: "volume", Name: "proj-agent-1-ws-00000001",
        Destination: "/workspace"}],
    Config: {Labels: {"swarm-core.project": "proj",
        "swarm-core.checkout": $ck}}}]' > "$F/inspect/id-c1"
refused "a container that still runs" "still run, or Docker cannot tell"
assert_eq "naming it" "1" "$(said "proj-agent-1 (running)")"
assert_eq "before any scan" "0" "$(grep -c '^run ' "$F/log" || true)"
assert_eq "nothing removed or stopped" "0" \
    "$(grep -cE '^(rm|commit|stop|kill)' "$F/log" || true)"
# Docker cannot describe a container it still lists: refused the same
# way, rather than taken for gone.
rm -f "$F/inspect/id-c1"
echo id-c1 > "$F/present-ids"
: > "$F/log"
refused "a container Docker cannot describe" \
    "still run, or Docker cannot tell"
assert_eq "naming it" "1" "$(said "proj-agent-1 (state unknown)")"
assert_eq "before any scan" "0" "$(grep -c '^run ' "$F/log" || true)"

# Agent work HEAD's history lacks (after a rewritten upstream, say):
# refused, then kept only as recovery refs with --allow-unharvested.
setup
gitc -C "$REPO" commit -q --amend -m rewritten
_old=$(git -C "$RT/upstream.git" rev-parse agent-work)
refused "work HEAD's history lacks" "agent-work"
assert_eq "the refusal names --allow-unharvested" "1" \
    "$(said "--allow-unharvested")"
assert_eq "nothing is copied then" "0" "$(recovery_refs)"
assert_eq "--allow-unharvested: cleanup goes on" "0" \
    "$(cleanup --allow-unharvested)"
assert_eq "saying what is kept only as recovery refs" "1" \
    "$(said "Kept only as recovery refs")"
assert_eq "the bare repo is gone" "no" "$(present "$RT/upstream.git")"
assert_eq "the old tip is in the recovery refs" "1" \
    "$(git -C "$REPO" for-each-ref --format='%(objectname)' \
        refs/swarm-recovery/ | grep -cx "$_old" | awk '{ print ($1 > 0) }')"
assert_eq "the engagement is cleaned up" "" \
    "$(jq -r '.engagement_id // empty' "$RT/state.json")"

# A read of the bare repo's refs that fails part of the way (an I/O
# error) is no proof that the checkout has them: refused, with and
# without --allow-unharvested.
cat > "$TMPDIR/hook-ref.sh" <<'EOF'
read() {
    if [ "$#" -eq 4 ] && [ "$1" = -r ] && [ "$2" != -u ] \
            && [ "$4" = ref ]; then
        return 1
    fi
    builtin read "$@"
}
EOF
for _flag in "" --allow-unharvested; do
    setup
    gitc -C "$REPO" commit -q --amend -m rewritten
    assert_eq "a failed read of the refs${_flag:+ ($_flag)}: refused" "1" \
        "$(BASH_ENV="$TMPDIR/hook-ref.sh" cleanup $_flag)"
    assert_eq "for that reason${_flag:+ ($_flag)}" "1" \
        "$(said "cannot read the refs of")"
    assert_eq "the bare repo stays${_flag:+ ($_flag)}" "yes" \
        "$(present "$RT/upstream.git")"
    assert_eq "nothing is copied${_flag:+ ($_flag)}" "0" "$(recovery_refs)"
done

# Stopped on an unset variable (a flock that names one, through
# BASH_ENV), cleanup does not end with status 0, as Bash 3.2's EXIT trap
# would have it, and deletes nothing.
cat > "$TMPDIR/unset-hook.sh" <<'EOF'
flock() { : "$swarm_test_unset_variable"; }
EOF
setup
_rc=$(BASH_ENV="$TMPDIR/unset-hook.sh" cleanup)
assert_eq "cleanup stopped on an unset variable: not status 0" "true" \
    "$([ "$_rc" -ne 0 ] && echo true || echo false)"
assert_eq "the bare repo stays" "yes" "$(present "$RT/upstream.git")"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="
[ "$FAIL" -eq 0 ]
