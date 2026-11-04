#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for launch.sh retire, with a fake docker CLI whose answers
# come from files: no Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
# Exported, so that the fake docker and the programs it runs make their
# scratch files here, under the cleanup below.
export TMPDIR
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH="$REPO_ROOT/launch.sh"
trap 'rm -rf "$TMPDIR"' EXIT

# The git config check asks git which files it reads (git var, Git 2.42
# or later); here the scanner runs on this host's git.
if ! git var GIT_CONFIG_SYSTEM >/dev/null 2>&1; then
    echo "SKIP: these tests need Git 2.42 or later (git var)"
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

# A checkout (no swarmfile: retire must not need one) and its runtime.
REPO="$TMPDIR/proj"
git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m init
CK=$(cd -P "$REPO" && pwd -P)
P=proj
RT="$TMPDIR/runtime"
mkdir -m 700 "$RT"
swarm_runtime_claim "$RT" "$REPO" "$P"
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e1" | .docker_daemon = "d1"'

# Fake docker.  $F holds the answers:
#   containers       "<id> <name>" lines (all labeled for this checkout)
#   inspect/<id>     docker container inspect JSON
#   volumes/<name>   volume labels JSON
#   cp/<id><path>    files docker cp finds in the container
#   scan/<volume>    the scanner's report for that volume ("fail": exit 3)
#   rmfail/<id>      docker rm fails
#   snaproot/        the / of every snapshot, for the repository search
#   daemon           docker info id (default d1)
#   log              every call
F="$TMPDIR/fake"
mkdir -p "$F/inspect" "$F/volumes" "$F/cp" "$F/scan" "$F/rmfail" "$TMPDIR/bin"
cat > "$TMPDIR/bin/docker" <<'EOF'
#!/bin/bash
F="$FAKE_DOCKER"
printf '%s\n' "$*" >> "$F/log"
case "$1" in
    info) cat "$F/daemon" 2>/dev/null || echo d1; exit 0 ;;
    context) echo default; exit 0 ;;
    ps)
        case "$*" in
            # Containers made from a snapshot: $F/left-from-snapshot
            # ("<id>", or "<id> unlabeled" for one retire did not make,
            # from any snapshot) and $F/made (what docker run made while
            # $F/leave-helpers exists, "<id> <image> labeled|unlabeled",
            # matched by the snapshot's name or image id).
            *"ancestor="*)
                ref=$(printf '%s\n' "$*" \
                    | sed -n 's/.*ancestor=\([^ ]*\).*/\1/p')
                sha=$(awk -v r="$ref" '$1 == r { print $2 }' \
                    "$F/images" 2>/dev/null)
                only=""
                case "$*" in
                    *"label=swarm-core.retire=proj"*) only=labeled ;;
                esac
                if [ -e "$F/left-from-snapshot" ]; then
                    if [ -n "$only" ]; then
                        grep -v ' unlabeled$' "$F/left-from-snapshot" || true
                    else
                        sed 's/ unlabeled$//' "$F/left-from-snapshot"
                    fi
                fi
                [ ! -e "$F/made" ] || awk -v r="$ref" -v s="$sha" \
                    -v o="$only" '($2 == r || (s != "" && $2 == s)) \
                        && (o == "" || $3 == o) { print $1 }' "$F/made"
                exit 0 ;;
            *"label=swarm-core.session="*) exit 0 ;;
            *"label=swarm-core.project="*)
                while read -r id name; do
                    [ -n "$id" ] || continue
                    jq -nc --arg id "$id" --arg n "$name" --arg o "$FAKE_CK" \
                        '{id: $id, name: $n, project: "proj", owner: $o}'
                done < "$F/containers" ;;
        esac
        exit 0 ;;
    container)
        shift
        [ "$1" = inspect ] || exit 1
        shift
        if [ "$1" = -f ] || [ "$1" = --format ]; then
            fmt="$2"; id="$3"
            [ -f "$F/inspect/$id" ] || exit 1
            case "$fmt" in
                *State.Status*StartedAt*)
                    jq -r '.[0].State | "\(.Status) \(.StartedAt) \(.FinishedAt)"' \
                        "$F/inspect/$id.now" 2>/dev/null \
                        || jq -r '.[0].State | "\(.Status) \(.StartedAt) \(.FinishedAt)"' \
                            "$F/inspect/$id" ;;
                *Labels*) jq -c '.[0].Config.Labels' "$F/inspect/$id" ;;
                *Config.Env*) jq -c '.[0].Config.Env // []' "$F/inspect/$id" ;;
                *Config.User*) jq -r '.[0].Config.User // ""' "$F/inspect/$id" ;;
                *Destination*)
                    jq -r '.[0].Mounts[]?.Destination,
                        ((.[0].HostConfig.Tmpfs // {}) | keys[])' \
                        "$F/inspect/$id" ;;
                *) jq -r '.[0].Id' "$F/inspect/$id" ;;
            esac
            exit 0
        fi
        [ -f "$F/inspect/$1" ] || exit 1
        cat "$F/inspect/$1"
        exit 0 ;;
    volume)
        [ "$2" = inspect ] || exit 1
        [ -f "$F/volumes/$5" ] || exit 1
        cat "$F/volumes/$5"
        exit 0 ;;
    cp)
        follow=""
        if [ "$2" = -L ]; then follow=h; shift; fi
        src="${2#*:}"; id="${2%%:*}"
        if [ ! -e "$F/cp/$id$src" ] && [ ! -L "$F/cp/$id$src" ]; then
            echo "Error response from daemon: Could not find the file $src in container $id" >&2
            exit 1
        fi
        tar -C "$(dirname "$F/cp/$id$src")" "-c${follow}f" - \
            "$(basename "$src")"
        exit 0 ;;
    run)
        # $F/leave-helpers: each container docker run makes stays behind,
        # as a client stopped between create and start leaves it, in
        # $F/made as "<id> <image> labeled|unlabeled"; the label comes
        # from the run's own arguments.
        if [ -e "$F/leave-helpers" ]; then
            img=""; prev=""; lab=unlabeled
            for a in "$@"; do
                [ "$a" != -c ] || img="$prev"
                if [ "$prev" = --label ] \
                        && [ "$a" = swarm-core.retire=proj ]; then
                    lab=labeled
                fi
                prev="$a"
            done
            n=$(wc -l < "$F/made" 2>/dev/null) || n=0
            echo "made-$((n + 1)) ${img:-none} $lab" >> "$F/made"
        fi
        d=$(mktemp -d "$F/run.XXXXXX")
        # The repository search in the snapshot: retire's own program,
        # run here with $F/snaproot as the snapshot's root.  Found paths
        # are mapped back to the snapshot's names.
        case "$*" in
            *swarm-repos*)
                # docker run -i copies standard input into the container,
                # whether or not the program reads it.
                for a in "$@"; do
                    if [ "$a" = -i ]; then
                        cat > /dev/null
                        break
                    fi
                done
                prog=""; prev=""
                for a in "$@"; do
                    [ "$prev" != -c ] || prog="$a"
                    prev="$a"
                done
                root="$F/snaproot"
                bash -c "$prog" swarm-repos "$root" > "$d/found" || exit $?
                while IFS= read -r r; do
                    case "$r" in
                        "$root") printf '/\n' ;;
                        "$root"/*) printf '%s\n' "${r#"$root"}" ;;
                        *) printf 'outside the root: %s\n' "$r" ;;
                    esac
                done < "$d/found"
                exit 0 ;;
        esac
        # The image comparison: read each path on this file system, as
        # the snapshot would; for the original image (sha256:aaa...),
        # the paths listed in $F/orig-changed read as another content.
        case "$*" in
            *swarm-compare*)
                img=""
                for a in "$@"; do
                    case "$a" in sha256:*) img="$a" ;; esac
                done
                while IFS= read -r p; do
                    if [ -L "$p" ]; then
                        printf '%s\tl\t%s\n' "$p" "$(readlink "$p")"
                    elif [ -f "$p" ]; then
                        h=$(shasum -a 256 < "$p" 2>/dev/null \
                            || sha256sum < "$p")
                        if [ "$img" = "sha256:$(printf 'a%.0s' $(seq 64))" ] \
                                && grep -qxF "$p" "$F/orig-changed" 2>/dev/null
                        then
                            h="0000 -"
                        fi
                        printf '%s\tf\t%s\n' "$p" "${h%% *}"
                    elif [ -e "$p" ]; then
                        printf '%s\to\t-\n' "$p"
                    else
                        printf '%s\t-\t-\n' "$p"
                    fi
                done
                exit 0 ;;
        esac
        # The git config check: the real scanner in userconfig mode, with
        # the container's HOME and XDG_CONFIG_HOME from -e (a test home
        # when none is given), never the caller's own.
        case "$*" in
            *userconfig*)
                cat > "$d/scan.sh"
                mkdir "$d/out"
                prev=""; uhome="$F/home-default"; uxdg=""; umounts=""
                for a in "$@"; do
                    if [ "$prev" = -e ]; then
                        case "$a" in
                            HOME=*) uhome="${a#HOME=}" ;;
                            XDG_CONFIG_HOME=*) uxdg="${a#XDG_CONFIG_HOME=}" ;;
                            SWARM_SCAN_MOUNTS=*) umounts="${a#SWARM_SCAN_MOUNTS=}" ;;
                        esac
                    fi
                    prev="$a"
                done
                mkdir -p "$F/home-default"
                if [ -n "$uxdg" ]; then
                    env -i PATH="$PATH" HOME="$uhome" XDG_CONFIG_HOME="$uxdg" \
                        SWARM_SCAN_MOUNTS="$umounts" \
                        bash "$d/scan.sh" userconfig - - "$d/out" >&2 || exit $?
                else
                    env -i PATH="$PATH" HOME="$uhome" \
                        SWARM_SCAN_MOUNTS="$umounts" \
                        bash "$d/scan.sh" userconfig - - "$d/out" >&2 || exit $?
                fi
                cat "$d/out/report" || exit 3
                exit 0 ;;
        esac
        vol=$(printf '%s\n' "$*" | sed -n 's/.*type=volume,src=\([^,]*\),.*/\1/p')
        # $F/term-on-scan: retire gets SIGTERM while it scans (after
        # its snapshot exists), as from a timeout.
        if [ -n "$vol" ] && [ -e "$F/term-on-scan" ]; then
            kill -TERM "$PPID"
        fi
        # A volume with a directory under voldir/ is scanned for real:
        # the scanner script comes on stdin, the context is the last
        # argument.
        if [ -d "$F/voldir/$vol" ]; then
            cat > "$d/scan.sh"
            mkdir "$d/out"
            prev=""
            for a in "$@"; do
                ctx="$a"
                if [ "$prev" = -e ]; then
                    case "$a" in
                        SWARM_SCAN_MOUNTS=*)
                            export SWARM_SCAN_MOUNTS="${a#SWARM_SCAN_MOUNTS=}" ;;
                    esac
                fi
                prev="$a"
            done
            bash "$d/scan.sh" worktree "$F/voldir/$vol" "$ctx" "$d/out" \
                >&2 || exit $?
            tar -C "$d/out" -cf - report
            exit 0
        fi
        cat > /dev/null
        if [ "$(cat "$F/scan/$vol" 2>/dev/null)" = fail ]; then exit 3; fi
        cp "$F/scan/$vol" "$d/report" 2>/dev/null || : > "$d/report"
        tar -C "$d" -cf - report
        exit 0 ;;
    diff)
        cat "$F/diff/$2" 2>/dev/null
        exit 0 ;;
    commit)
        [ ! -e "$F/commitfail" ] || exit 1
        echo "Flag --pause has been deprecated."
        # commit [--change ...] <container> <name>: one image id per
        # container, its digits padded; $F/images holds "<name> <id>"
        # per image made.
        cid="${*: -2:1}"
        cname="${*: -1}"
        snapid=$(printf 'sha256:%064d' "$(printf '%s' "$cid" | tr -cd '0-9')")
        if [ -e "$F/int-on-commit" ]; then
            # Ctrl-C at the terminal while the daemon commits: SIGINT
            # to retire's process group.  The daemon makes the image a
            # second later all the same; this client waits for it,
            # unless the SIGINT stops it first.
            ( trap '' INT; sleep 1
              printf '%s %s\n' "$cname" "$snapid" >> "$F/images" ) &
            trap 'exit 130' INT
            kill -INT -- "-$(ps -o pgid= -p "$PPID" | tr -d ' ')"
            sleep 2
        else
            printf '%s %s\n' "$cname" "$snapid" >> "$F/images"
        fi
        echo "$snapid"
        exit 0 ;;
    rmi)
        # $F/term-on-rmi: retire gets SIGTERM during its first docker
        # rmi, which then removes nothing.
        if [ -e "$F/term-on-rmi" ]; then
            rm -f "$F/term-on-rmi"
            kill -TERM "$PPID"
            exit 1
        fi
        if [ -e "$F/images" ] && awk -v r="$2" '$1 == r || $2 == r { f = 1 }
                END { exit !f }' "$F/images"; then
            awk -v r="$2" '$1 != r && $2 != r' "$F/images" > "$F/images.new"
            mv "$F/images.new" "$F/images"
            exit 0
        fi
        echo "Error response from daemon: No such image: $2" >&2
        exit 1 ;;
    image)
        # image inspect <name>
        [ -e "$F/images" ] && awk -v r="$3" '$1 == r { f = 1 }
            END { exit !f }' "$F/images"
        exit $? ;;
    images)
        [ ! -e "$F/imagesfail" ] || exit 1
        ref=""
        for a in "$@"; do
            case "$a" in reference=*) ref="${a#reference=}" ;; esac
        done
        [ ! -e "$F/images" ] || awk -v p="$ref:" \
            'index($1, p) == 1 { print $1 }' "$F/images"
        exit 0 ;;
    rm)
        [ ! -e "$F/rmfail/$2" ] || exit 1
        echo "$2"
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMPDIR/bin/docker"

# Add container NAME (id id-NAME) with state STATE and a proper
# workspace volume NAME-ws-00000000 of kind KIND.
add() {
    local name="$1" state="${2:-exited}" kind="${3:-agent}"
    local id="id-$name" vol="$name-ws-00000000"
    printf '%s %s\n' "$id" "$name" >> "$F/containers"
    # The image's passwd, as docker cp finds it.
    mkdir -p "$F/cp/$id/etc"
    printf 'root:x:0:0:root:/root:/bin/bash\nagent:x:1000:1000::/home/agent:/bin/bash\n' \
        > "$F/cp/$id/etc/passwd"
    jq -n --arg id "$id" --arg st "$state" --arg vol "$vol" --arg n "$name" \
        --arg ck "$CK" '[{
            Id: $id, Name: ("/" + $n),
            Image: ("sha256:" + ("a" * 64)),
            State: {Status: $st, StartedAt: "S1", FinishedAt: "F1"},
            HostConfig: {RestartPolicy: {Name: "no"}, AutoRemove: false,
                Tmpfs: null},
            Mounts: [
                {Type: "volume", Name: $vol, Destination: "/workspace"},
                {Type: "bind", Source: "/x", Destination: "/upstream"}],
            Config: {Labels: {"swarm-core.project": "proj",
                "swarm-core.checkout": $ck}}
        }]' > "$F/inspect/$id"
    jq -n --arg n "$name" --arg ck "$CK" --arg k "$kind" '{
        "swarm-core.project": "proj", "swarm-core.checkout": $ck,
        "swarm-core.container": $n, "swarm-core.kind": $k,
        "swarm-core.context": "full", "swarm-core.engagement": "e1"
    }' > "$F/volumes/$vol"
}
# Change container NAME's inspect JSON with jq filter FILTER.
edit() {
    local n="$1"
    shift
    jq "$@" "$F/inspect/id-$n" > "$F/inspect/id-$n.tmp"
    mv "$F/inspect/id-$n.tmp" "$F/inspect/id-$n"
}
reset_fake() {
    chmod -R u+w "$F" 2>/dev/null || true
    rm -rf "$F"
    mkdir -p "$F/inspect" "$F/volumes" "$F/cp" "$F/scan" "$F/rmfail" \
        "$F/voldir" "$F/diff" "$F/snaproot"
    : > "$F/images"
    : > "$F/containers"
    : > "$F/log"
}
# Run launch.sh retire in a process group of its own, as from a
# terminal, so that a SIGINT to that group stays there; print
# "<status>".
retire_own_group() {
    local rc=0 pid
    set -m
    (cd "$REPO" && PATH="$TMPDIR/bin:$PATH" FAKE_DOCKER="$F" FAKE_CK="$CK" \
        SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
        exec "$BASH" "$LAUNCH" retire > "$TMPDIR/out" 2>&1) &
    pid=$!
    set +m
    wait "$pid" || rc=$?
    printf '%s' "$rc"
}
# Run launch.sh retire ARGS, with SHIM_DIR (when set) first on PATH;
# print "<status>".
SHIM_DIR=""
retire() {
    local rc=0
    (cd "$REPO" && PATH="${SHIM_DIR:+$SHIM_DIR:}$TMPDIR/bin:$PATH" \
        FAKE_DOCKER="$F" FAKE_CK="$CK" \
        SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
        "$BASH" "$LAUNCH" retire "$@" > "$TMPDIR/out" 2>&1) || rc=$?
    printf '%s' "$rc"
}
# The number of entries in directory DIR.
entries() {
    find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}
# Engine containers removed (docker rm without -f; a forced removal is
# a check container made from a snapshot).
removed() {
    grep -cE '^rm [^-]' "$F/log" || true
}

echo "=== 1. Stopped containers whose files are in their volumes ==="
reset_fake
assert_eq "nothing to retire succeeds" "0" "$(retire)"
add proj-agent-1
add proj-agent-2
assert_eq "retire removes stopped agents" "0" "$(retire)"
assert_eq "both are removed" "2" "$(removed)"
assert_eq "by id, without -f" "2" "$(grep -cE '^rm id-proj-agent-[12]$' "$F/log")"
assert_eq "it needs no swarmfile" "false" \
    "$([ -e "$REPO/swarm.json" ] && echo true || echo false)"

reset_fake
add proj-agent-1
add proj-agent-post
assert_eq "--post-process retires only the post-process container" "0" \
    "$(retire --post-process)"
assert_eq "only it is removed" "rm id-proj-agent-post" \
    "$(grep '^rm ' "$F/log")"

echo ""
echo "=== 2. Containers whose layer may hold work are refused ==="
# Each case: one container breaks a rule; nothing at all is removed,
# not even a sound container checked first.
# Run retire and expect a refusal with nothing removed.  EXPECT, when
# given, must appear in retire's output: the specific finding, so that a
# scanner failure cannot pass for it.  With SHOW_REASON set, print each
# refusal's first error line.
refused() {
    local label="$1" expect="${2:-}"
    assert_eq "$label: refused" "1" "$(retire)"
    if [ -n "$expect" ]; then
        assert_eq "$label: for that reason" "1" \
            "$(grep -cF -- "$expect" "$TMPDIR/out" | awk '{ print ($1 > 0) }')"
    fi
    [ -z "${SHOW_REASON:-}" ] \
        || sed -n 's/^ERROR: /    reason: /p; s/^  \(.*mount-crossing.*\)/    detail: \1/p; s/^  \(config-.*\)/    detail: \1/p' \
            "$TMPDIR/out" | head -2
    assert_eq "$label: nothing removed" "0" "$(removed)"
}
case_setup() {
    reset_fake
    add proj-agent-1
    add proj-agent-2 "${1:-exited}" "${2:-agent}"
}
case_setup running;    refused "a running container" "state running"
# Every selected container is checked, whatever the checks of the ones
# before it read: here the third one is unsafe.
reset_fake
add proj-agent-1
add proj-agent-2
add proj-agent-3 running
refused "a third container that is unsafe" "state running"
assert_eq "all three were checked" "3" \
    "$(grep -cE '^container inspect id-proj-agent-[123]$' "$F/log" || true)"
case_setup paused;     refused "a paused container" "state paused"
case_setup restarting; refused "a restarting container" "state restarting"
case_setup
edit proj-agent-2 '.[0].HostConfig.RestartPolicy.Name = "always"'
refused "a restart policy" "restart policy always"
case_setup
edit proj-agent-2 '.[0].HostConfig.AutoRemove = true'
refused "auto-remove" "auto-remove is on"
case_setup
edit proj-agent-2 '.[0].HostConfig.Tmpfs = {"/workspace/tmp": ""}'
refused "a tmpfs below /workspace" "tmpfs at /workspace/tmp"
case_setup
edit proj-agent-2 '.[0].Mounts += [{Type: "volume", Name: "x",
    Destination: "/workspace/sub"}]'
refused "a second mount below /workspace" "no single workspace mount"
case_setup
edit proj-agent-2 '.[0].Mounts[0].Type = "bind"'
refused "a bind-mounted /workspace" "workspace is not a volume"
case_setup
edit proj-agent-2 '.[0].Mounts = [.[0].Mounts[1]]'
refused "no /workspace mount (a pre-volume container)" "no single workspace mount"
case_setup
jq '.["swarm-core.container"] = "other"' \
    "$F/volumes/proj-agent-2-ws-00000000" > "$F/v.tmp"
mv "$F/v.tmp" "$F/volumes/proj-agent-2-ws-00000000"
refused "another container's volume" "is not its workspace volume"

# Git config the container's processes read, checked inside its
# snapshot (here: this file system, with HOME and XDG_CONFIG_HOME from
# the container's environment).
H="$(cd -P "$TMPDIR" && pwd -P)/homes"
case_setup
mkdir -p "$H/a"
printf '[lfs]\n\tstorage = /home/agent/lfs\n' > "$H/a/.gitconfig"
edit proj-agent-2 --arg h "$H/a" '.[0].Config.Env = ["HOME=" + $h]'
refused "lfs.storage in the container's global git config" "config-setting"
case_setup
mkdir -p "$H/b"
printf '[include]\n\tpath = /x\n' > "$H/b/.gitconfig"
edit proj-agent-2 --arg h "$H/b" '.[0].Config.Env = ["HOME=" + $h]'
refused "an include in the global git config" "include.path"
case_setup
mkdir -p "$H/c"
printf '[user]\n\tname = a\n' > "$H/c/.gitconfig"
edit proj-agent-2 --arg h "$H/c" '.[0].Config.Env = ["HOME=" + $h]'
assert_eq "a plain git config is fine" "0" "$(retire)"
case_setup
mkdir -p "$H/d" "$H/elsewhere"
printf '[core]\n\thooksPath = /home/agent/hooks\n' > "$H/elsewhere/real"
ln -sfn "$H/elsewhere/real" "$H/d/.gitconfig"
edit proj-agent-2 --arg h "$H/d" '.[0].Config.Env = ["HOME=" + $h]'
refused "a symlinked .gitconfig is read through the link" "core.hookspath"
case_setup
mkdir -p "$H/x/git"
printf '[core]\n\tworktree = /x\n' > "$H/x/git/config"
edit proj-agent-2 --arg x "$H/x" '.[0].Config.Env = ["XDG_CONFIG_HOME=" + $x]'
refused "config under the container's XDG_CONFIG_HOME" "core.worktree"
case_setup
mkdir -p "$H/e"
printf '[lfs]\n\tstorage = /x\n[broken\n' > "$H/e/.gitconfig"
edit proj-agent-2 --arg h "$H/e" '.[0].Config.Env = ["HOME=" + $h]'
refused "a config file that does not parse" "config-paths-unknown fatal: bad config line 3 in file $H/e/.gitconfig"
# Config on a mount, or reached through a link onto one, cannot be
# read from the snapshot; Docker's own mounts count too.
case_setup
mkdir -p "$H/m"
edit proj-agent-2 --arg h "$H/m" '.[0].Config.Env = ["HOME=" + $h]
    | .[0].Mounts += [{Type: "bind", Source: "/gone", Destination: $h}]'
refused "git config on a mount of the container" "config-on-mount"
case_setup
mkdir -p "$H/t"
ln -sfn "$H/t" "$H/alias"
edit proj-agent-2 --arg h "$H/alias" --arg t "$H/t" \
    '.[0].Config.Env = ["HOME=" + $h] | .[0].HostConfig.Tmpfs = {($t): ""}'
refused "git config through a link onto a tmpfs" "config-on-mount"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["HOME=/dev/shm"]'
refused "git config in Docker's /dev/shm" "config-on-mount"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["HOME=/workspace"]'
refused "git config in the workspace (not in the snapshot)" "config-on-mount"
mkdir -p "$H/run/git-home"
ln -sfn "$H/run" "$H/varrun"
case_setup
edit proj-agent-2 --arg h "$H/run/git-home" --arg m "$H/varrun/git-home" \
    '.[0].Config.Env = ["HOME=" + $h]
     | .[0].Mounts += [{Type: "bind", Source: "/g", Destination: $m}]'
refused "git config on a mount configured through a link" "config-on-mount"
if [ "$(id -u)" != 0 ]; then
    case_setup
    mkdir -p "$H/locked/inner"
    chmod 000 "$H/locked"
    edit proj-agent-2 --arg h "$H/locked/inner" '.[0].Config.Env = ["HOME=" + $h]'
    refused "a home git cannot search" "config-unreadable"
    chmod 700 "$H/locked"
    case_setup
    mkdir -p "$H/noread"
    printf '[user]\n\tname = a\n' > "$H/noread/.gitconfig"
    chmod 000 "$H/noread/.gitconfig"
    edit proj-agent-2 --arg h "$H/noread" '.[0].Config.Env = ["HOME=" + $h]'
    refused "an unreadable .gitconfig" "config-unreadable"
    chmod 600 "$H/noread/.gitconfig"
fi
# The files checked are those the container's git names: a git built
# with another prefix reads its system file elsewhere than /etc.
REAL_GIT=$(command -v git)
mkdir -p "$TMPDIR/bin-git-prefix" "$TMPDIR/bin-git-old" "$H/prefix/etc"
printf '[core]\n\thooksPath = /opt/hooks\n' > "$H/prefix/etc/gitconfig"
cat > "$TMPDIR/bin-git-prefix/git" <<EOF
#!/bin/bash
GIT_CONFIG_SYSTEM='$H/prefix/etc/gitconfig' exec '$REAL_GIT' "\$@"
EOF
cat > "$TMPDIR/bin-git-old/git" <<EOF
#!/bin/bash
if [ "\$1" = var ]; then
    echo "usage: git var (-l | <variable>)" >&2
    exit 129
fi
exec '$REAL_GIT' "\$@"
EOF
chmod +x "$TMPDIR/bin-git-prefix/git" "$TMPDIR/bin-git-old/git"
case_setup
SHIM_DIR="$TMPDIR/bin-git-prefix"
refused "a system git config where this git reads it, not in /etc" \
    "config-setting $H/prefix/etc/gitconfig core.hookspath"
SHIM_DIR=""
case_setup
SHIM_DIR="$TMPDIR/bin-git-old"
refused "a git that cannot name its config files" "config-paths-unknown"
SHIM_DIR=""
case_setup
edit proj-agent-2 '.[0].Config.Env = ["HOME=/custom\n"]'
refused "a HOME ending in a newline" "HOME to an empty, relative or unnormalized"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["XDG_CONFIG_HOME=/a\nb"]'
refused "an XDG_CONFIG_HOME with a newline inside" "XDG_CONFIG_HOME to an empty"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["HOME="]'
refused "an empty HOME" "HOME to an empty"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["HOME=/opt/alias/.."]'
refused "a HOME with .." "HOME to an empty"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["XDG_CONFIG_HOME=/a//b"]'
refused "an XDG_CONFIG_HOME with //" "XDG_CONFIG_HOME to an empty"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["HOME=."]'
refused "a relative HOME" "HOME to an empty"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["XDG_CONFIG_HOME=cfg"]'
refused "a relative XDG_CONFIG_HOME" "XDG_CONFIG_HOME to an empty"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["GIT_CONFIG_GLOBAL=/x", "GIT_USER_NAME=a"]'
refused "a Git environment variable in the container" "GIT_CONFIG_GLOBAL"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["BASH_ENV=/home/agent/env.sh"]'
refused "a BASH_ENV in the container" "BASH_ENV"
case_setup
edit proj-agent-2 '.[0].Config.Env = ["GIT_USER_NAME=a", "GIT_USER_EMAIL=b"]'
assert_eq "the engine's own GIT_USER_* variables are fine" "0" "$(retire)"
case_setup
edit proj-agent-2 '.[0].Config.User = "agent"'
assert_eq "the container's user is passed to the check" "1" \
    "$(retire >/dev/null; grep -c -- '--user agent' "$F/log" || true)"

# Worktrees outside the volume, and a scan that cannot tell.
case_setup
echo "block external /tmp/scratch" > "$F/scan/proj-agent-2-ws-00000000"
refused "a worktree outside the volume" "external /tmp/scratch"
case_setup
echo "block mismatched-worktree agent_logs/copy" \
    > "$F/scan/proj-agent-2-ws-00000000"
refused "a mismatched worktree" "mismatched-worktree"
case_setup
echo fail > "$F/scan/proj-agent-2-ws-00000000"
refused "a failed scan" "cannot scan the workspace"
for _b in "gitfile /workspace/.git is not a directory" \
        "gitlink /workspace/.git is a symlink" \
        "lfs-storage .git /home/agent/lfs" "newline-path a\nb"; do
    case_setup
    echo "block $_b" > "$F/scan/proj-agent-2-ws-00000000"
    refused "scan finding ${_b%% *}"
done
case_setup
echo "block embedded cache.git" > "$F/scan/proj-agent-2-ws-00000000"
refused "a nested repository (not inspected deeply)" "embedded cache.git"

# The real scanner on a directory standing in for the volume.
real_ws() {
    local d="$F/voldir/proj-agent-2-ws-00000000"
    git init -q "$d"
    git -C "$d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
        commit -q --allow-empty -m ws
    printf '%s' "$d"
}
# The container's own paths, here under the canonical temp dir (a path
# like /home goes through a host link on macOS).
_ct=$(cd -P "$TMPDIR" && pwd -P)
L="$_ct/layer"
case_setup
real_ws >/dev/null
assert_eq "a clean real workspace is retired" "0" "$(retire)"
case_setup
_d=$(real_ws)
mkdir -p "$TMPDIR/outside-wt"
git -C "$_d" config core.worktree "$TMPDIR/outside-wt"
refused "a repository-local core.worktree outside the volume" "core-worktree"
case_setup
_d=$(real_ws)
ln -s "$L/lfs" "$_d/.git/lfs"
printf 'A %s/lfs\nA %s/lfs/objects\n' "$L" "$L" > "$F/diff/id-proj-agent-2"
refused "a git-dir symlink to storage the container wrote" "links out of its volume to data"
case_setup
_d=$(real_ws)
git init -q --bare "$_d/cache.git"
refused "an embedded bare repository" "embedded cache.git"
case_setup
_d=$(real_ws)
git -C "$_d" config include.path /home/agent/extra
refused "a repository-local include" "config-include"
case_setup
_d=$(real_ws)
git -C "$_d" config core.hooksPath /home/agent/hooks
refused "a repository-local core.hooksPath outside the volume" "core-hookspath"
case_setup
_d=$(real_ws)
mkdir -p "$_d/lfs"
ln -s "$L/lfs-objects" "$_d/lfs/objects"
ln -s "$_d/lfs" "$_d/.git/lfs"
printf 'A %s/lfs-objects\n' "$L" > "$F/diff/id-proj-agent-2"
refused "a git-dir link to a directory that links into the layer" "links out of its volume to data"
# Links out of the volume: fine into the image, refused into what the
# container added or changed (docker diff).
mkdir -p "$F/diff"
case_setup
_d=$(real_ws)
ln -s "$L/result" "$_d/result"
mkdir -p "$F/diff"
printf 'C %s\nA %s/result\nA %s/result/x\n' "$L" "$L" "$L" \
    > "$F/diff/id-proj-agent-2"
refused "a checkout symlink to data the container wrote" "links out of its volume to data"
case_setup
_d=$(real_ws)
mkdir -p "$_d/.venv/bin"
ln -s /usr/bin/python3 "$_d/.venv/bin/python"
mkdir -p "$F/diff"
printf 'C /tmp\nA /tmp/x\n' > "$F/diff/id-proj-agent-2"
assert_eq "a link into the unchanged image (a virtualenv) is fine" "0" \
    "$(retire)"
# Links are resolved where they were made: the scan runs from a
# snapshot of the container (here: this file system), the kernel's way.
mkdir -p "$_ct/real-run" "$_ct/store" "$_ct/srv/run" "$_ct/opt"
ln -sfn "$_ct/real-run" "$_ct/img-run"
case_setup
_d=$(real_ws)
ln -s "$_ct/img-run/results" "$_d/results"
printf 'A %s/real-run/results\n' "$_ct" > "$F/diff/id-proj-agent-2"
refused "a link through another link to data the container wrote" "links out of its volume to data"
case_setup
_d=$(real_ws)
ln -s "$_ct/img-run/newdir/result" "$_d/result"
printf 'A %s/real-run/newdir\nA %s/real-run/newdir/result\n' "$_ct" "$_ct" \
    > "$F/diff/id-proj-agent-2"
refused "a link through a directory only the container has" "links out of its volume to data"
case_setup
_d=$(real_ws)
ln -sfn "$_ct/store" "$_ct/alias"
ln -s "$_ct/alias/result" "$_d/result"
printf 'A %s/alias\nA %s/store/result\n' "$_ct" "$_ct" \
    > "$F/diff/id-proj-agent-2"
refused "a link through an alias the container created" "links out of its volume to data"
case_setup
_d=$(real_ws)
ln -sfn "$_ct/srv/run" "$_ct/opt/alias"
ln -s "$_ct/opt/alias/../result" "$_d/result"
printf 'A %s/srv/result\n' "$_ct" > "$F/diff/id-proj-agent-2"
refused "a link whose .. comes after another link" "links out of its volume to data"
case_setup
_d=$(real_ws)
ln -sfn "$_d" "$_ct/opt/current"
ln -s "$_ct/opt/current/inside" "$_d/back"
printf 'A /anything/else\n' > "$F/diff/id-proj-agent-2"
assert_eq "a link that leads back into the volume is fine" "0" "$(retire)"
assert_eq "the scan ran from a snapshot of the container" "1" \
    "$(grep -c '^commit .* id-proj-agent-2 proj-agent-retire:' "$F/log" || true)"
assert_eq "with the engine's labels emptied on the snapshot" "2" \
    "$(grep -cF -- '--change LABEL swarm-core.project="" swarm-core.checkout="" swarm-core.session=""' \
        "$F/log" || true)"
assert_eq "each snapshot is removed after, by its name" "2" \
    "$(grep -c '^rmi proj-agent-retire:id-proj-agen-[0-9][0-9]*$' "$F/log" \
        || true)"
# The config check, the scan, the search for repositories and the
# comparison with the image (this case has a link on the way) all run
# from the snapshot.
assert_eq "config check, scan, repository search and comparison use the snapshot" "4" \
    "$(grep -c "sha256:$(printf '%064d' 2) -c " "$F/log" || true)"
case_setup
_d=$(real_ws)
ln -s /upstream/alias/result "$_d/result"
refused "a link into another mount of the container" "mount-crossing result /upstream"
case_setup
_d=$(real_ws)
ln -s "$_ct/real-run" "$_d/rundir"
refused "a link to a directory outside the volume" "outside-dir-link"
case_setup
_d=$(real_ws)
ln -s /upstream/alias/../../result "$_d/result"
refused "a link whose .. crosses another mount" "mount-crossing result /upstream"
mkdir -p "$_ct/usrbin"
: > "$_ct/usrbin/tool"
case_setup
_d=$(real_ws)
ln -sfn "$_ct/usrbin" "$_ct/opt/tools"
ln -s "$_ct/opt/tools/tool" "$_d/tool"
printf 'A %s/opt/tools\n' "$_ct" > "$F/diff/id-proj-agent-2"
refused "a link through a link the container created" "links out of its volume to data"
case_setup
_d=$(real_ws)
ln -sfn "$_d" "$_ct/opt/current"
ln -s "$_ct/opt/current/inside" "$_d/back"
printf 'A %s/opt/current\n' "$_ct" > "$F/diff/id-proj-agent-2"
refused "a link back into the volume through a link the container made" "links out of its volume to data"
# A mount whose configured destination goes through a link is also
# found under the link's target.
mkdir -p "$_ct/run/data"
ln -sfn "$_ct/run" "$_ct/varrun"
case_setup
_d=$(real_ws)
edit proj-agent-2 --arg m "$_ct/varrun/data" \
    '.[0].Mounts += [{Type: "bind", Source: "/h", Destination: $m}]'
ln -s "$_ct/run/data/result" "$_d/result"
refused "a link into a mount reached through another link" "mount-crossing"
case_setup
_d=$(real_ws)
ln -s /usr/bin "$_d"$'\n'"cache"
ln -s "$_d"$'\n'"cache/true" "$_d/tool"
refused "a link through a name with a newline" "newline-path"
case_setup
_d=$(real_ws)
ln -sfn "$_d" "$_ct/zalias"
edit proj-agent-2 --arg m "$_ct/zalias/.git" \
    '.[0].Mounts += [{Type: "bind", Source: "/h", Destination: $m}]'
refused "a mount that lands in the volume through a link" "mount-in-workspace"
case_setup
edit proj-agent-2 '.[0].HostConfig.Mounts = [{Target: "/workspace",
    VolumeOptions: {Subpath: "sub"}}]'
refused "a workspace mount of a volume subdirectory" "subdirectory of its volume"
case_setup
edit proj-agent-2 '.[0].Mounts += [{Type: "bind", Source: "/h",
    Destination: "/varrun\n/data"}]'
refused "a mount destination with a newline" "control character"
case_setup
edit proj-agent-2 '.[0].Mounts += [{Type: "bind", Source: "/h",
    Destination: "/mnt/a\tb"}]'
refused "a mount destination with a tab" "control character"
# A mount whose destination passes through another mount cannot be
# resolved from the snapshot.
mkdir -p "$_ct/mnt"
case_setup
edit proj-agent-2 --arg a "$_ct/mnt" --arg b "$_ct/mnt/ws" \
    '.[0].Mounts += [{Type: "bind", Source: "/h1", Destination: $a},
                     {Type: "bind", Source: "/h2", Destination: $b}]'
real_ws >/dev/null
refused "a mount whose destination is inside another mount" "mount-through-mount"
mkdir -p "$_ct/runp"
ln -sfn "$_ct/runp" "$_ct/varrunp"
case_setup
edit proj-agent-2 --arg a "$_ct/varrunp" --arg b "$_ct/varrunp/ws" \
    '.[0].Mounts += [{Type: "bind", Source: "/h1", Destination: $a},
                     {Type: "bind", Source: "/h2", Destination: $b}]'
real_ws >/dev/null
refused "a mount below another mount whose path is a symlink" "mount-through-mount"
# Mount checks run for an empty volume too.
case_setup
mkdir -p "$F/voldir/proj-agent-2-ws-00000000"
ln -sfn "$F/voldir/proj-agent-2-ws-00000000" "$_ct/zempty"
edit proj-agent-2 --arg m "$_ct/zempty" \
    '.[0].Mounts += [{Type: "bind", Source: "/h", Destination: $m}]'
refused "an empty volume with a mount landing on it" "mount-in-workspace"
case_setup
_d=$(real_ws)
ln -s /etc/hosts "$_d/hosts"
refused "a link to a file Docker mounts itself" "mount-crossing hosts"
# Paths the repository's settings name may not resolve through a mount
# the snapshot lacks (there, a link may lead elsewhere).
mkdir -p "$_ct/optm"
case_setup
_d=$(real_ws)
ln -sfn "$_d" "$_ct/optm/wt"
git -C "$_d" config core.worktree "$_ct/optm/wt"
edit proj-agent-2 --arg m "$_ct/optm" \
    '.[0].Mounts += [{Type: "bind", Source: "/o", Destination: $m}]'
refused "a core.worktree through a mount" "core-worktree"
case_setup
_d=$(real_ws)
git init -q --bare "$_d/pool.git"
ln -sfn "$_d/pool.git" "$_ct/optm/pool"
echo "$_ct/optm/pool/objects" > "$_d/.git/objects/info/alternates"
edit proj-agent-2 --arg m "$_ct/optm" \
    '.[0].Mounts += [{Type: "bind", Source: "/o", Destination: $m}]'
refused "alternates through a mount back into the volume" "alternates"
# docker diff goes by metadata; a link to an image file whose content
# changed with its metadata kept is caught by comparing with the image.
mkdir -p "$_ct/imgfiles"
echo original > "$_ct/imgfiles/tool"
case_setup
_d=$(real_ws)
ln -s "$_ct/imgfiles/tool" "$_d/tool"
: > "$F/diff/id-proj-agent-2"
assert_eq "a link to an unchanged image file is fine" "0" "$(retire)"
case_setup
_d=$(real_ws)
ln -s "$_ct/imgfiles/tool" "$_d/tool"
: > "$F/diff/id-proj-agent-2"
printf '%s\n' "$_ct/imgfiles/tool" > "$F/orig-changed"
refused "a link to an image file changed without a trace in docker diff" \
    "to files it changed"
rm -f "$F/orig-changed"
# Any Git repository in the snapshot outside /workspace refuses, made by
# the container or shipped by the image, changed or not: docker diff
# cannot show every change.  The search runs retire's program over
# $F/snaproot, the snapshot's / here; docker diff plays no part.  A
# HEAD file alone, HEAD with refs/ but no objects, and a repository
# under /workspace (the volume, scanned on its own) do not count.
case_setup
mkdir -p "$F/snaproot/tmp" "$F/snaproot/srv/x/refs" "$F/snaproot/workspace"
: > "$F/snaproot/tmp/HEAD"
: > "$F/snaproot/srv/x/HEAD"
git init -q "$F/snaproot/workspace/repo"
assert_eq "a snapshot without repositories is fine" "0" "$(retire)"
assert_eq "the search runs in the snapshot, offline, as root" "1" \
    "$(grep -cF -- "--network none --user 0 --label swarm-core.retire=proj --entrypoint bash sha256:$(printf '%064d' 2) -c" \
        "$F/log" | awk '{ print ($1 > 0) }')"
case_setup
git init -q "$F/snaproot/tmp/experiment"
refused "a clone in the container's /tmp" "  /tmp/experiment/.git"
case_setup
git init -q --bare "$F/snaproot/tmp/x.git"
refused "a bare clone in the container's layer" "  /tmp/x.git"
case_setup
git init -q "$F/snaproot/opt/tool"
refused "a repository the image ships, even unchanged" "  /opt/tool/.git"
case_setup
mkdir -p "$F/snaproot/opt/wt"
printf 'gitdir: /opt/tool/.git/worktrees/wt\n' > "$F/snaproot/opt/wt/.git"
refused "a linked worktree (a .git file)" "  /opt/wt/.git"
case_setup
mkdir -p "$F/snaproot/opt/ln"
ln -s /nonexistent/gitdir "$F/snaproot/opt/ln/.git"
refused "a dangling .git link" "  /opt/ln/.git"
case_setup
git init -q "$F/snaproot"
refused "a repository rooted at /" "  /.git"
case_setup
git init -q --bare "$F/snaproot/srv/repo.git"
refused "a bare repository of the image" "  /srv/repo.git"
# New objects of a bare repository whose objects/ is a link land outside
# it; the repository is found all the same, dangling link or not.  So is
# a git dir kept apart from its work tree (commondir).
case_setup
git init -q --bare "$F/snaproot/srv/p.git"
mkdir -p "$F/snaproot/opt/pool"
mv "$F/snaproot/srv/p.git/objects" "$F/snaproot/opt/pool/objects"
ln -s "$F/snaproot/opt/pool/objects" "$F/snaproot/srv/p.git/objects"
refused "a bare repository whose objects/ is a link" "  /srv/p.git"
case_setup
mkdir -p "$F/snaproot/srv/d.git/refs"
: > "$F/snaproot/srv/d.git/HEAD"
ln -s /nonexistent/objects "$F/snaproot/srv/d.git/objects"
refused "a git dir whose objects/ link dangles" "  /srv/d.git"
case_setup
mkdir -p "$F/snaproot/var/gd"
: > "$F/snaproot/var/gd/HEAD"
echo ../.. > "$F/snaproot/var/gd/commondir"
refused "a git dir kept apart from its work tree" "  /var/gd"
case_setup
git init -q --bare "$F/snaproot"
refused "a bare repository rooted at /" "Git repositories outside its workspace"
assert_eq "named as /" "1" "$(grep -cx '  /' "$TMPDIR/out" || true)"
case_setup
git init -q "$F/snaproot/tmp/a
b"
refused "a repository whose path holds a newline" \
    "Git repositories outside its workspace"
if [ "$(id -u)" != 0 ]; then
    case_setup
    mkdir -p "$F/snaproot/root/locked"
    chmod 000 "$F/snaproot/root/locked"
    # (Both containers share the fake's snapshot: the first one stops.)
    refused "a directory the search cannot read" \
        "cannot check proj-agent-1 for Git repositories"
    chmod 700 "$F/snaproot/root/locked"
fi
# docker diff is read for links out of the volume.  It prints names
# unescaped: a newline makes it ambiguous.
case_setup
_d=$(real_ws)
ln -s "$_ct/imgfiles/tool" "$_d/tool"
printf 'A /tmp/experiment\nname\n' > "$F/diff/id-proj-agent-2"
refused "a docker diff with a newline in a name" "cannot report unambiguously"
# Docker sends names as JSON, which turns bytes that are not UTF-8 into
# U+FFFD: such a name does not exist in the container.
case_setup
_d=$(real_ws)
ln -s "$_ct/imgfiles/tool" "$_d/tool"
printf 'C /opt/data\nA /opt/data/x\357\277\275\n' > "$F/diff/id-proj-agent-2"
refused "a name docker diff reports altered (not UTF-8)" "cannot report exactly"
# The list of links to compare cannot be built: refuse.
mkdir -p "$TMPDIR/bin-sed"
cat > "$TMPDIR/bin-sed/sed" <<'EOF'
#!/bin/bash
case "$*" in *'s/^layer-link //p'*) exit 4 ;; esac
exec /usr/bin/sed "$@"
EOF
chmod +x "$TMPDIR/bin-sed/sed"
case_setup
_d=$(real_ws)
ln -s "$_ct/imgfiles/tool" "$_d/tool"
: > "$F/diff/id-proj-agent-2"
rc=0
(cd "$REPO" && PATH="$TMPDIR/bin-sed:$TMPDIR/bin:$PATH" FAKE_DOCKER="$F" \
    FAKE_CK="$CK" SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    SWARM_SKIP_DEP_CHECK=1 "$BASH" "$LAUNCH" retire > "$TMPDIR/out" 2>&1) \
    || rc=$?
assert_eq "a failed link list for the image comparison refuses" "1" "$rc"
assert_eq "for that reason" "1" \
    "$(grep -c 'cannot list the links of' "$TMPDIR/out" || true)"
assert_eq "nothing removed then" "0" "$(removed)"
# A quoted alternates entry is decoded by Git; the scan refuses it even
# when a directory spelled with the quotes exists in the volume.
git init -q --bare "$_ct/qpool.git"
case_setup
_d=$(real_ws)
mkdir -p "$_d/.git/objects/\"$_ct/qpool.git/objects\""
printf '"%s/qpool.git/objects"\n' "$_ct" > "$_d/.git/objects/info/alternates"
refused "a quoted alternates entry" "alternates .git/objects \"$_ct/qpool.git/objects\""
# A git dir split into a common dir that is not a listed git dir.
case_setup
_d=$(real_ws)
mkdir -p "$_d/.git/common"
mv "$_d/.git/objects" "$_d/.git/refs" "$_d/.git/common/"
echo common > "$_d/.git/commondir"
refused "a common dir the scan does not inspect" "commondir .git "
# An alternates file with a NUL byte: Git and the shell would read
# different paths from it.
case_setup
_d=$(real_ws)
# Git reads up to the NUL: an existing store outside, so git status
# works and the refusal comes from the NUL rule.
printf '%s/qpool.git/objects\000/../..%s/.git/objects\n' "$_ct" \
    "$(cd -P "$_d" && pwd -P)" > "$_d/.git/objects/info/alternates"
refused "an alternates file with a NUL byte" "(unreadable or NUL byte)"
# A link target that is not valid UTF-8: docker diff (JSON) reports it
# with U+FFFD, so it cannot be compared and refuses.
case_setup
_d=$(real_ws)
ln -s "$_ct/layer/result$(printf '\377')" "$_d/bad-name"
printf 'A %s/layer/result\357\277\275\n' "$_ct" > "$F/diff/id-proj-agent-2"
# Run under a UTF-8 locale, where GNU grep would drop the line: retire
# must compare bytes whatever locale it is called with.
LC_ALL=C.UTF-8 refused "a link to a path that is not valid UTF-8" \
    "not valid UTF-8"
case_setup
_d=$(real_ws)
ln -s "$_ct/layer/caf$(printf '\303\251')" "$_d/good-name"
: > "$F/diff/id-proj-agent-2"
assert_eq "a valid non-ASCII link target is compared as usual" "0" "$(retire)"
# A link outside the volume that a repository setting passes, made by
# the container: compared with docker diff like links in the volume.
mkdir -p "$_ct/optv"
case_setup
_d=$(real_ws)
ln -sfn "$_d" "$_ct/optv/wt"
git -C "$_d" config core.worktree "$_ct/optv/wt"
printf 'A %s/optv/wt\n' "$_ct" > "$F/diff/id-proj-agent-2"
refused "a core.worktree through a link the container made" "links out of its volume to data"
# A directory the container added, passed on the way back in.
mkdir -p "$_ct/home2/transient"
case_setup
_d=$(real_ws)
_dc=$(cd -P "$_d" && pwd -P)
# Up out of transient and home2, then down into the volume again.
ln -s "$_ct/home2/transient/../..${_dc#"$_ct"}/result" "$_d/back"
echo r > "$_d/result"
printf 'A %s/home2/transient\n' "$_ct" > "$F/diff/id-proj-agent-2"
refused "a link through a directory the container added" "links out of its volume to data"
case_setup
_d=$(real_ws)
ln -s /proc/1/cwd/result "$_d/saved"
refused "a link through /proc" "mount-crossing saved /proc"
case_setup
: > "$F/commitfail"
refused "a container that cannot be snapshotted" "cannot snapshot"
# Interrupted while it scans (SIGTERM after the snapshot exists), retire
# removes the snapshot and every scratch file, and nothing else.
reset_fake
add proj-agent-1
: > "$F/term-on-scan"
_before=$(entries "$TMPDIR")
assert_eq "an interrupted retire stops (SIGTERM)" "143" "$(retire)"
assert_eq "it removes the snapshot it made" "1" \
    "$(grep -c '^rmi proj-agent-retire:id-proj-agen-[0-9][0-9]*$' "$F/log" \
        || true)"
assert_eq "it leaves no scratch files" "$_before" "$(entries "$TMPDIR")"
assert_eq "it removes no container" "0" "$(removed)"
rm -f "$F/term-on-scan"
# A container made from a snapshot that retire did not start (no label
# of retire's) stays: when an interrupted retire cleans up, and when a
# later one sweeps the snapshot a killed one left (with a warning).
reset_fake
add proj-agent-1
: > "$F/term-on-scan"
echo "look-1 unlabeled" > "$F/left-from-snapshot"
assert_eq "an interrupted retire with someone's container on the snapshot" \
    "143" "$(retire)"
assert_eq "does not remove that container" "0" \
    "$(grep -c '^rm -f look-1$' "$F/log" || true)"
rm -f "$F/term-on-scan"
reset_fake
add proj-agent-1
echo "proj-agent-retire:left-1 sha256:$(printf '%064d' 9)" >> "$F/images"
echo "look-1 unlabeled" > "$F/left-from-snapshot"
assert_eq "a retire that finds a snapshot a killed one left" "0" "$(retire)"
assert_eq "does not remove someone's container made from it" "0" \
    "$(grep -c '^rm -f look-1$' "$F/log" || true)"
assert_eq "and says so" "1" \
    "$(grep -c 'that retire did not start stay' "$TMPDIR/out" || true)"
rm -f "$F/left-from-snapshot"
# Check containers a stopped client left (made from the snapshot) go
# before the snapshot does.  Each run leaves its container here, with
# the labels its own arguments gave it.
reset_fake
add proj-agent-1
: > "$F/term-on-scan"
: > "$F/leave-helpers"
assert_eq "an interrupted retire with its check containers left" "143" \
    "$(retire)"
_snap="sha256:$(printf '%064d' 1)"
_from=$(awk -v s="$_snap" '$2 == s' "$F/made" | grep -c . || true)
assert_eq "its checks made containers from the snapshot" "1" \
    "$([ "$_from" -gt 1 ] && echo 1 || echo 0)"
assert_eq "every one of them with retire's label" "0" \
    "$(awk -v s="$_snap" '$2 == s && $3 != "labeled"' "$F/made" \
        | grep -c . || true)"
assert_eq "it removes each of them" "$_from" \
    "$(grep -c '^rm -f made-' "$F/log" || true)"
assert_eq "before the snapshot" "rm -f made|rmi proj-agent-retire" \
    "$(grep -E '^(rm -f |rmi proj-agent-retire)' "$F/log" \
        | sed 's/:.*//; s/-[0-9]*$//' | uniq | tr '\n' '|' | sed 's/|$//')"
assert_eq "and no engine container" "0" "$(removed)"
rm -f "$F/term-on-scan" "$F/leave-helpers" "$F/made"
# A Ctrl-C while the daemon commits: retire waits for the commit, then
# removes the snapshot, so none is left once the daemon is done.
if ! (sigint_works); then
    echo "  SKIP: a Ctrl-C during the commit (SIGINT is ignored here)"
else
    reset_fake
    add proj-agent-1
    : > "$F/int-on-commit"
    assert_eq "a Ctrl-C during the commit stops retire" "130" \
        "$(retire_own_group)"
    sleep 2
    assert_eq "no snapshot is left once the daemon is done" "0" \
        "$(grep -c . "$F/images" || true)"
    assert_eq "it removes no container then" "0" "$(removed)"
    rm -f "$F/int-on-commit"
fi
# A signal while retire removes its snapshot (TERM during the first
# docker rmi, which removes nothing): the cleanup still has the name
# and removes it.
reset_fake
add proj-agent-1
: > "$F/term-on-rmi"
assert_eq "a retire stopped while it removes its snapshot" "143" "$(retire)"
assert_eq "the snapshot is removed all the same" "0" \
    "$(grep -c . "$F/images" || true)"
assert_eq "it removes no container there" "0" "$(removed)"
# A signal right after the commit job starts, before its pid is known:
# the cleanup still waits for the commit, then removes the snapshot.
reset_fake
_rc=0
PATH="$TMPDIR/bin:$PATH" FAKE_DOCKER="$F" RETIRE_LIB="$REPO_ROOT/lib/retire.sh" \
    "$BASH" -c '
        source "$RETIRE_LIB"
        RETIRE_SNAP_REF="proj-agent-retire:boundary-1"
        # The commit job, whose daemon makes the image a second later.
        ( sleep 1
          printf "%s sha256:%064d\n" "$RETIRE_SNAP_REF" 7 \
              >> "$FAKE_DOCKER/images" ) &
        retire_cleanup
    ' || _rc=$?
# Long enough for the daemon of a commit the cleanup did not wait for.
sleep 2
assert_eq "a cleanup before the commit's pid is known succeeds" "0" "$_rc"
assert_eq "it waits for the commit and removes the snapshot" "0" \
    "$(grep -c . "$F/images" || true)"
assert_eq "by its name" "1" \
    "$(grep -c '^rmi proj-agent-retire:boundary-1$' "$F/log" || true)"
# Snapshots an earlier retire left (one killed outright) go first.
reset_fake
add proj-agent-1
printf 'proj-agent-retire:old-1 sha256:%064d\n' 9 > "$F/images"
assert_eq "retire with a snapshot an earlier one left" "0" "$(retire)"
assert_eq "it removes that snapshot" "1" \
    "$(grep -c '^rmi proj-agent-retire:old-1$' "$F/log" || true)"
assert_eq "and says so" "1" \
    "$(grep -c 'a snapshot an earlier retire left' "$TMPDIR/out" || true)"
assert_eq "no snapshot is left after" "0" "$(grep -c . "$F/images" || true)"
reset_fake
add proj-agent-1
: > "$F/imagesfail"
refused "images that cannot be listed" "cannot list Docker images"
case_setup
_d=$(real_ws)
ln -s "$_ct/img-run/x" "$_d/x"
printf 'C /usr\nA /usr/local/x\n' > "$F/diff/id-proj-agent-2"
assert_eq "unrelated changes in the container do not stop retire" "0" \
    "$(retire)"
# A report that cannot be read refuses rather than passing as clean.
mkdir -p "$TMPDIR/bin-grep"
cat > "$TMPDIR/bin-grep/grep" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in */report) [ "$prev" = "^block " ] && exit 2 ;; esac
    prev="$a"
done
exec /usr/bin/grep "$@"
EOF
chmod +x "$TMPDIR/bin-grep/grep"
case_setup
rc=0
(cd "$REPO" && PATH="$TMPDIR/bin-grep:$TMPDIR/bin:$PATH" FAKE_DOCKER="$F" \
    FAKE_CK="$CK" SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    SWARM_SKIP_DEP_CHECK=1 "$BASH" "$LAUNCH" retire > "$TMPDIR/out" 2>&1) \
    || rc=$?
assert_eq "an unreadable config check report refuses" "1" "$rc"
assert_eq "for that reason" "1" \
    "$(grep -c 'cannot read the git config check' "$TMPDIR/out" || true)"
assert_eq "nothing removed then" "0" "$(removed)"

# A failing comparison refuses rather than passing.
mkdir -p "$TMPDIR/bin-awk"
cat > "$TMPDIR/bin-awk/awk" <<'EOF'
#!/bin/bash
case "$*" in *'index(p, x'*) exit 2 ;; esac
exec /usr/bin/awk "$@"
EOF
chmod +x "$TMPDIR/bin-awk/awk"
case_setup
_d=$(real_ws)
ln -s "$_ct/img-run/x" "$_d/x"
: > "$F/diff/id-proj-agent-2"
rc=0
(cd "$REPO" && PATH="$TMPDIR/bin-awk:$TMPDIR/bin:$PATH" FAKE_DOCKER="$F" \
    FAKE_CK="$CK" SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    SWARM_SKIP_DEP_CHECK=1 "$BASH" "$LAUNCH" retire > /dev/null 2>&1) \
    || rc=$?
assert_eq "a failed link comparison refuses" "1" "$rc"
assert_eq "nothing removed then" "0" "$(removed)"

case_setup
_d=$(real_ws)
mkdir -p "$_d/pool/info"
ln -s "$L/alternates" "$_d/pool/info/alternates"
echo "$_d/pool" > "$_d/.git/objects/info/alternates"
mkdir -p "$F/diff"
printf 'A %s/alternates\n' "$L" > "$F/diff/id-proj-agent-2"
refused "an in-volume object pool whose alternates link into the layer" "links out of its volume to data"
case_setup
_d=$(real_ws)
ln -s / "$_d/rootlink"
mkdir -p "$F/diff"
printf 'A /anything\n' > "$F/diff/id-proj-agent-2"
refused "a link to / with anything in the layer" "outside-dir-link"
case_setup
_d=$(real_ws)
git init -q --bare "$TMPDIR/alt-store.git"
printf '%s' "$TMPDIR/alt-store.git/objects" > "$_d/.git/objects/info/alternates"
refused "alternates to an existing store outside, without a final newline" "alternates .git/objects"
[ -z "${SHOW_REASON:-}" ] || grep -c 'alternates' "$TMPDIR/out"

case_setup
echo "uncommitted dirty .:  M a" > "$F/scan/proj-agent-2-ws-00000000"
assert_eq "uncommitted files in the volume do not stop retire" "0" \
    "$(retire)"

# An open interactive session keeps its container.
case_setup exited interactive
sleep 60 &
_live=$!
swarm_pending_write "$RT" proj-agent-2 "$_live" d1
refused "an open interactive session" "session proj-agent-2 is open"
kill "$_live" 2>/dev/null || true
wait "$_live" 2>/dev/null || true

echo ""
echo "=== 3. Removal acts only on what was checked ==="
reset_fake
add proj-agent-1
jq '.[0].State.StartedAt = "S2"' "$F/inspect/id-proj-agent-1" \
    > "$F/inspect/id-proj-agent-1.now"
assert_eq "a container restarted since the check is left" "1" "$(retire)"
assert_eq "and not removed" "0" "$(removed)"
reset_fake
add proj-agent-1
add proj-agent-2
: > "$F/rmfail/id-proj-agent-1"
assert_eq "a failed docker rm fails retire" "1" "$(retire)"
assert_eq "the other container is still removed" "rm id-proj-agent-2" \
    "$(grep '^rm ' "$F/log" | grep -v proj-agent-1 || true)"

echo ""
echo "=== 4. Engagement, daemon and lock ==="
reset_fake
add proj-agent-1
echo d2 > "$F/daemon"
assert_eq "another Docker daemon is refused" "1" "$(retire)"
rm -f "$F/daemon"
swarm_state_update "$RT/state.json" 'del(.docker_daemon)'
assert_eq "no recorded daemon is refused" "1" "$(retire)"
assert_eq "the message says how to name it" "1" \
    "$(grep -c 'SWARM_DOCKER_DAEMON=' "$TMPDIR/out" || true)"
rc=0
(cd "$REPO" && PATH="$TMPDIR/bin:$PATH" FAKE_DOCKER="$F" FAKE_CK="$CK" \
    SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
    SWARM_DOCKER_DAEMON=d1 "$BASH" "$LAUNCH" retire > /dev/null 2>&1) \
    || rc=$?
assert_eq "SWARM_DOCKER_DAEMON names it" "0" "$rc"
swarm_state_update "$RT/state.json" '.docker_daemon = "d1"'
reset_fake
add proj-agent-1
rc=0
(cd "$REPO" && PATH="$TMPDIR/bin:$PATH" FAKE_DOCKER="$F" FAKE_CK="$CK" \
    SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
    SWARM_ENGAGEMENT_ID=e2 "$BASH" "$LAUNCH" retire > /dev/null 2>&1) \
    || rc=$?
assert_eq "another engagement id is refused" "1" "$rc"
exec 8>>"$RT/engagement.lock"
flock -n 8
assert_eq "a held lock is refused" "1" "$(retire 8>&-)"
assert_eq "nothing removed then" "0" "$(removed)"
exec 8>&-
# Another checkout of the project id claims the runtime between
# retire's first checks and its lock (a flock first on PATH writes that
# claim once, then locks): retire checks again under the lock and
# removes nothing.
mkdir -p "$TMPDIR/bin-flock" "$TMPDIR/other"
cat > "$TMPDIR/bin-flock/flock" <<'EOF'
#!/bin/bash
if [ -n "${FLOCK_CLAIM:-}" ] && [ ! -e "$SWARM_RUNTIME_DIR/claimed" ]; then
    : > "$SWARM_RUNTIME_DIR/claimed"
    st="$SWARM_RUNTIME_DIR/state.json"
    jq -c --arg r "$FLOCK_CLAIM" '.repo_root = $r' "$st" > "$st.new"
    chmod 600 "$st.new"
    mv "$st.new" "$st"
fi
self=$(cd "$(dirname "$0")" && pwd)
IFS=:
for d in $PATH; do
    if [ "$d" != "$self" ] && [ -x "$d/flock" ]; then
        exec "$d/flock" "$@"
    fi
done
exit 127
EOF
chmod +x "$TMPDIR/bin-flock/flock"
reset_fake
add proj-agent-1
cp "$RT/state.json" "$TMPDIR/state.keep"
swarm_state_update "$RT/state.json" 'del(.repo_root)'
SHIM_DIR="$TMPDIR/bin-flock"
assert_eq "a runtime another checkout claims before the lock: refused" "1" \
    "$(FLOCK_CLAIM="$(cd -P "$TMPDIR/other" && pwd -P)" retire)"
SHIM_DIR=""
assert_eq "for that reason" "1" \
    "$(grep -c 'belongs to another checkout' "$TMPDIR/out" || true)"
assert_eq "nothing removed then" "0" "$(removed)"
cp "$TMPDIR/state.keep" "$RT/state.json"
rm -f "$RT/claimed"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
