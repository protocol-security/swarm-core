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
        if [ "$2" = ls ]; then
            ls "$F/volumes"
            exit 0
        fi
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
                # $F/flood-search: the search sends far more than any
                # list (a snapshot's tools are its agent's); a write
                # that fails stops it, as it stops the docker client.
                if [ -e "$F/flood-search" ]; then
                    head -c 3000000 /dev/zero || exit 1
                    exit 0
                fi
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
                # $F/repos-unmapped: the root resolved and the paths
                # passed on as found, for paths the volume scan names
                # the same way (linked worktrees, section 6).
                [ ! -e "$F/repos-unmapped" ] \
                    || root=$(cd -P "$F/snaproot" && pwd -P)
                bash -c "$prog" swarm-repos "$root" > "$d/found" || exit $?
                # "<kind><path>" records ended by NUL, mapped back to
                # the snapshot's names.
                while IFS= read -r -d '' r; do
                    k="${r:0:1}"
                    r="${r:1}"
                    if [ -e "$F/repos-unmapped" ]; then
                        printf '%s%s\0' "$k" "$r"
                        continue
                    fi
                    case "$r" in
                        "$root") printf '%s/\0' "$k" ;;
                        "$root"/*) printf '%s%s\0' "$k" "${r#"$root"}" ;;
                        *) printf '%soutside the root: %s\0' "$k" "$r" ;;
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
        # The scan of a checkout in the layer: the real scanner in
        # worktree mode on $F/snaproot<path>, run as the snapshot runs it.
        # $F/layer-scan-fail: the helper fails.
        case "$*" in
            *swarm-layer-scan*)
                cat > "$d/scan.sh"
                [ ! -e "$F/layer-scan-fail" ] || exit 3
                lpath=""
                prev=""
                for a in "$@"; do
                    [ "$prev" != swarm-layer-scan ] || lpath="$a"
                    prev="$a"
                done
                lmounts=""
                prev=""
                for a in "$@"; do
                    if [ "$prev" = -e ]; then
                        case "$a" in
                            SWARM_SCAN_MOUNTS=*) lmounts="${a#SWARM_SCAN_MOUNTS=}" ;;
                        esac
                    fi
                    prev="$a"
                done
                mkdir "$d/out"
                printf '%s\n' "$lpath" >> "$F/layer-scans"
                SWARM_SCAN_MOUNTS="$lmounts" bash "$d/scan.sh" worktree \
                    "$F/snaproot$lpath" layer "$d/out" >&2 || exit $?
                # $F/layer-scan-incomplete: a result missing a part.
                case "$(cat "$F/layer-scan-incomplete" 2>/dev/null)" in
                    nogitdir) sed -i.bak '/^gitdir /d' "$d/out/report" ;;
                    nobundle) rm -f "$d/out/bundle" ;;
                    noobjects) rm -f "$d/out/objects" ;;
                    empty) echo empty > "$d/out/report"
                           rm -f "$d/out/bundle" "$d/out/objects" ;;
                esac
                rm -f "$d/out/report.bak"
                (cd "$d/out" && set -- report \
                    && { [ ! -f bundle ] || set -- "$@" bundle; } \
                    && { [ ! -f objects ] || set -- "$@" objects; } \
                    && tar -cf - "$@") || exit 3
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
        # A volume with a directory under voldir/ is scanned for real,
        # by the production helper's own script (the -c argument): its
        # scratch under $F instead of /, the volume at voldir/<vol>
        # instead of /workspace; the scanner comes on stdin, the context
        # is the last argument.  $F/xtamper: the archive is unpacked and
        # changed before it goes back (a helper's output is its
        # container's to choose).
        if [ -d "$F/voldir/$vol" ]; then
            prog=""
            prev=""
            for a in "$@"; do
                [ "$prev" != -c ] || prog="$a"
                ctx="$a"
                if [ "$prev" = -e ]; then
                    case "$a" in
                        SWARM_SCAN_MOUNTS=*)
                            export SWARM_SCAN_MOUNTS="${a#SWARM_SCAN_MOUNTS=}" ;;
                        SWARM_SCAN_ORIGIN=*)
                            export SWARM_SCAN_ORIGIN="${a#SWARM_SCAN_ORIGIN=}" ;;
                    esac
                fi
                prev="$a"
            done
            mkdir -p "$F/scratch"
            printf '%s\n' "$prog" > "$F/helper-prog"
            prog=$(printf '%s\n' "$prog" | sed \
                -e "s|mktemp -d /swarm-volume-scan\.XXXXXX|mktemp -d $F/scratch/swarm-volume-scan.XXXXXX|" \
                -e "s| worktree /workspace | worktree $F/voldir/$vol |")
            if [ ! -e "$F/xtamper" ]; then
                bash -c "$prog" scan "$ctx"
                exit $?
            fi
            bash -c "$prog" scan "$ctx" > "$d/prod.tar" || exit $?
            mkdir "$d/x"
            tar -C "$d/x" -xf "$d/prod.tar" || exit 3
            xp=$(tr '\0' '\n' < "$d/x/external-worktrees" 2>/dev/null | head -1)
            case "$(cat "$F/xtamper")" in
                unterminated) printf '%s' "$xp" > "$d/x/external-worktrees" ;;
                duplicate) printf '%s\0%s\0' "$xp" "$xp" > "$d/x/external-worktrees" ;;
                relative) printf 'rel/wt\0' > "$d/x/external-worktrees" ;;
                control) printf '%s\t\0' "$xp" > "$d/x/external-worktrees" ;;
                extra) printf '%s/other\0' "$xp" >> "$d/x/external-worktrees" ;;
                forged) printf 'external-worktree %s/forged\n' "$xp" >> "$d/x/report" ;;
                nolist) rm -f "$d/x/external-worktrees" ;;
                big) head -c 70000 /dev/zero > "$d/x/external-worktrees" ;;
                empty) : > "$d/x/external-worktrees" ;;
                emptyrec) printf '\0' > "$d/x/external-worktrees" ;;
                utf8) printf '%s\377\0' "$xp" > "$d/x/external-worktrees" ;;
                b65536) head -c 65536 /dev/zero | tr '\0' a \
                    > "$d/x/external-worktrees" ;;
                b65537) head -c 65537 /dev/zero | tr '\0' a \
                    > "$d/x/external-worktrees" ;;
            esac
            (cd "$d/x" && set -- report \
                && { [ ! -f bundle ] || set -- "$@" bundle; } \
                && { [ ! -f objects ] || set -- "$@" objects; } \
                && { [ ! -f external-worktrees ] \
                     || set -- "$@" external-worktrees; } \
                && tar -cf - "$@") || exit 3
            exit 0
        fi
        cat > /dev/null
        if [ "$(cat "$F/scan/$vol" 2>/dev/null)" = fail ]; then exit 3; fi
        cp "$F/scan/$vol" "$d/report" 2>/dev/null || : > "$d/report"
        # $F/scan-extra: the archive carries a member no scan writes.
        if [ -e "$F/scan-extra" ]; then
            echo x > "$d/extra"
            tar -C "$d" -cf - report extra
            exit 0
        fi
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
        # $F/term-on-rm: retire gets SIGTERM once a container is gone.
        if [ -e "$F/term-on-rm" ]; then
            rm -f "$F/term-on-rm"
            kill -TERM "$PPID"
        fi
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
    (cd "$REPO" && PATH="${SHIM_DIR:+$SHIM_DIR:}$TMPDIR/bin:$PATH" \
        FAKE_DOCKER="$F" FAKE_CK="$CK" \
        SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
        exec "$BASH" "$LAUNCH" retire "$@" > "$TMPDIR/out" 2>&1) &
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
refused "a config file that does not parse" "config-unreadable $H/e/.gitconfig: fatal: bad config line 3"
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
# A checkout in the layer (one the container made, one its image ships)
# is kept as recovery refs before the container goes (section 5).
case_setup
git init -q "$F/snaproot/tmp/experiment"
assert_eq "a checkout in the container's /tmp: retired" "0" "$(retire)"
assert_eq "once kept as recovery refs" "1" \
    "$(grep -c 'The Git checkouts they had outside their volumes are kept' "$TMPDIR/out" || true)"
case_setup
git init -q --bare "$F/snaproot/tmp/x.git"
refused "a bare clone in the container's layer" "  /tmp/x.git"
case_setup
git init -q "$F/snaproot/opt/tool"
assert_eq "a checkout the image ships: retired" "0" "$(retire)"
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
assert_eq "named as a path with a control character" "1" \
    "$(grep -c '(a control character)' "$TMPDIR/out" || true)"
# What a helper sends back is bounded (SWARM_HELPER_OUTPUT_LIMIT_MB) and
# checked: a flooding search and a scan archive with a member no scan
# writes refuse.
case_setup
: > "$F/flood-search"
SWARM_HELPER_OUTPUT_LIMIT_MB=1 refused "a repository search that floods" \
    "cannot check proj-agent-1 for Git repositories"
case_setup
: > "$F/scan-extra"
refused "a scan archive with an extra member" \
    "the scan archive holds an unexpected entry"
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
# An engagement with no recorded daemon was started by an earlier
# release: refused, untouched, with how to finish it.
swarm_state_update "$RT/state.json" 'del(.docker_daemon)'
assert_eq "an earlier release's engagement is refused" "1" "$(retire)"
assert_eq "the message says how to finish it" "1" \
    "$(grep -c 'release that made it' "$TMPDIR/out" || true)"
assert_eq "nothing removed then" "0" "$(removed)"
# Containers with no engagement recorded at all are an earlier
# release's too; with nothing left, there is nothing to retire.
swarm_state_update "$RT/state.json" 'del(.engagement_id, .docker_daemon)'
assert_eq "a container without a recorded engagement is refused" "1" \
    "$(retire)"
assert_eq "as an earlier release's" "1" \
    "$(grep -c 'release that made it' "$TMPDIR/out" || true)"
assert_eq "nothing removed then" "0" "$(removed)"
# Stopped on an unset variable (a flock that names one, through
# BASH_ENV), retire does not end with status 0, as Bash 3.2's EXIT trap
# would have it, and removes nothing.
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e1" | .docker_daemon = "d1"'
cat > "$TMPDIR/unset-hook.sh" <<'EOF'
flock() { : "$swarm_test_unset_variable"; }
EOF
reset_fake
add proj-agent-1
rc=$(BASH_ENV="$TMPDIR/unset-hook.sh" retire)
assert_eq "retire stopped on an unset variable: not status 0" "true" \
    "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_eq "and removes nothing" "0" "$(removed)"
# The check is made only where swarm_stop_guard_needed says so (Bash
# before 4.1): retire's EXIT trap, extracted, in a child Bash with
# retire_cleanup recording its call and the version test stubbed both
# ways.  Status 0 prints the line and ends with 1 only where the check is
# made; another status stays; the cleanup runs every time.
_sg_bashes="/bin/bash"
_sg_brew=""
if command -v brew >/dev/null 2>&1; then
    _sg_brew="$(brew --prefix)/bin/bash"
fi
if [ -n "$_sg_brew" ] && [ -x "$_sg_brew" ]; then
    _sg_bashes="$_sg_bashes $_sg_brew"
elif [ "$(uname)" = Darwin ]; then
    if [ -n "${CI:-}" ]; then
        assert_eq "CI has the Homebrew bash" "yes" "no"
    else
        echo "  SKIP: no Homebrew bash, so only /bin/bash is checked"
    fi
fi
awk '/^retire_stopped\(\)[[:space:]]*\{/ { p = 1 }
     p { print }
     p && /^\}[[:space:]]*$/ { exit }' "$REPO_ROOT/lib/retire.sh" \
    > "$TMPDIR/sg-trap.sh"
assert_eq "retire's EXIT trap is extracted" "1" \
    "$(grep -c '^retire_stopped()' "$TMPDIR/sg-trap.sh")"
_sg_run() {  # BASH NEEDED(0 yes, 1 no) END
    : > "$TMPDIR/sg-cleanups"
    cat > "$TMPDIR/sg-run.sh" <<EOF
set -euo pipefail
# shellcheck source=/dev/null
source "$TMPDIR/sg-trap.sh"
retire_cleanup() { echo cleanup >> "$TMPDIR/sg-cleanups"; }
swarm_stop_guard_needed() { return $2; }
trap retire_stopped EXIT
$3
EOF
    "$1" "$TMPDIR/sg-run.sh" 2>&1
}
_sg_line='the run stopped before its end'
for _sg_b in $_sg_bashes; do
    _sg_rc=0
    _sg_out=$(_sg_run "$_sg_b" 0 ':') || _sg_rc=$?
    assert_eq "$_sg_b: status 0 where the check is made: status 1" "1" \
        "$_sg_rc"
    assert_eq "$_sg_b:   saying so once" "1" \
        "$(grep -c "$_sg_line" <<< "$_sg_out")"
    assert_eq "$_sg_b:   having cleaned up once" "1" \
        "$(grep -c cleanup "$TMPDIR/sg-cleanups")"
    _sg_rc=0
    _sg_out=$(_sg_run "$_sg_b" 1 ':') || _sg_rc=$?
    assert_eq "$_sg_b: status 0 where it is not: status 0" "0" "$_sg_rc"
    assert_eq "$_sg_b:   no line" "0" \
        "$(grep -c "$_sg_line" <<< "$_sg_out")"
    assert_eq "$_sg_b:   having cleaned up once" "1" \
        "$(grep -c cleanup "$TMPDIR/sg-cleanups")"
    _sg_rc=0
    _sg_out=$(_sg_run "$_sg_b" 0 'exit 3') || _sg_rc=$?
    assert_eq "$_sg_b: another status stays" "3" "$_sg_rc"
    assert_eq "$_sg_b:   with no line" "0" \
        "$(grep -c "$_sg_line" <<< "$_sg_out")"
    assert_eq "$_sg_b:   having cleaned up once" "1" \
        "$(grep -c cleanup "$TMPDIR/sg-cleanups")"
done
# End to end: retire waits in docker images (the listing of snapshots an
# earlier retire left, entered with status 0), after its traps are set
# and its scratch directory made, and before any helper starts a process
# group of its own, when it gets a signal.
# SIGPIPE, which a closed pipe sends and retire does not trap, reaches
# the EXIT trap: the line only before Bash 4.1, death by the signal on
# every version.  SIGTERM goes through retire's own trap: status 143, no
# line.  The scratch directory goes either way.  python3 starts the run
# in a session of its own, signals launch.sh only, then lets the held
# docker go (Bash may hold the signal until it returns), and kills the
# whole session at the end.
_sg_py=yes
if ! command -v python3 >/dev/null 2>&1; then
    _sg_py=no
    if [ -n "${CI:-}" ]; then
        assert_eq "CI has python3" "yes" "no"
    else
        echo "  SKIP: no python3, so no signal is sent"
    fi
fi
mkdir -p "$TMPDIR/bin-hold"
cat > "$TMPDIR/bin-hold/docker" <<EOF
#!/bin/bash
if [ "\$1" = images ] && [ -e "$TMPDIR/sg/hold" ]; then
    rm -f "$TMPDIR/sg/hold"
    trap 'kill "\$s" 2>/dev/null; exit 0' TERM
    sleep 30 &
    s=\$!
    printf '%s\n' "\$\$" > "$TMPDIR/sg/ready.tmp"
    mv "$TMPDIR/sg/ready.tmp" "$TMPDIR/sg/ready"
    wait "\$s"
    exit 1
fi
exec "$TMPDIR/bin/docker" "\$@"
EOF
chmod +x "$TMPDIR/bin-hold/docker"
cat > "$TMPDIR/sg-sigrun.py" <<'EOF'
import glob, os, signal, subprocess, sys, time
bash, script, cwd, ready, errfile, signame, watch = sys.argv[1:8]
args = sys.argv[8:]
def made():
    return "yes" if glob.glob(watch) else "no"
p = None
held = None
def release(sig=signal.SIGTERM):
    # The held command traps SIGTERM and exits with 0.
    if held is not None:
        try:
            os.kill(held, sig)
        except ProcessLookupError:
            pass
def killgroup():
    release(signal.SIGKILL)
    if p is None:
        return
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
# A TERM, HUP or INT to this supervisor (a test run cancelled) ends it
# through the finally block, which kills the run's session.  They are
# blocked while the run is made, and unblocked in the run before exec.
def stop(signum, frame):
    raise SystemExit(128 + signum)
caught = {signal.SIGTERM, signal.SIGHUP, signal.SIGINT}
for s in caught:
    signal.signal(s, stop)
try:
    signal.pthread_sigmask(signal.SIG_BLOCK, caught)
    try:
        with open(errfile, "w") as err:
            p = subprocess.Popen(
                [bash, script] + args, cwd=cwd, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=err,
                start_new_session=True,
                preexec_fn=lambda: signal.pthread_sigmask(
                    signal.SIG_UNBLOCK, caught))
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, caught)
    deadline = time.time() + 20
    while time.time() < deadline and not os.path.exists(ready):
        if p.poll() is not None:
            break
        time.sleep(0.1)
    if not os.path.exists(ready):
        print("ready no")
        sys.exit(0)
    with open(ready) as f:
        held = int(f.read().strip())
    print("ready yes")
    print("before", made())
    # Then let the held command end with 0 at once: whether Bash acts
    # on its signal before or after it sees that end, the status it
    # has is 0, as it would be in a run the signal stops there.
    os.kill(p.pid, getattr(signal, signame))
    release()
    try:
        rc = p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        print("rc timeout")
        sys.exit(0)
    print("rc", rc)
    print("after", made())
finally:
    killgroup()
EOF
if [ "$_sg_py" = yes ]; then
    for _sg_b in $_sg_bashes; do
        _sg_v=$("$_sg_b" -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"')
        # shellcheck disable=SC2086  # major and minor as two words
        if swarm_stop_guard_needed $_sg_v; then _sg_n=1; else _sg_n=0; fi
        for _sg_sig in PIPE:-13:"$_sg_n" TERM:143:0; do
            _sg_s="${_sg_sig%%:*}"
            _sg_want="${_sg_sig#*:}"
            _sg_lines="${_sg_want#*:}"
            _sg_want="${_sg_want%%:*}"
            _sg_name="$_sg_b, SIG${_sg_s}"
            reset_fake
            add proj-agent-1
            rm -rf "$TMPDIR/sg"
            mkdir -p "$TMPDIR/sg/tmp"
            : > "$TMPDIR/sg/hold"
            _sg_out=$(cd "$REPO" \
                && env PATH="$TMPDIR/bin-hold:$TMPDIR/bin:$PATH" \
                    FAKE_DOCKER="$F" FAKE_CK="$CK" SWARM_RUNTIME_DIR="$RT" \
                    SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
                    TMPDIR="$TMPDIR/sg/tmp" \
                    python3 "$TMPDIR/sg-sigrun.py" "$_sg_b" "$LAUNCH" \
                        "$REPO" "$TMPDIR/sg/ready" "$TMPDIR/sg/err" \
                        "SIG${_sg_s}" "$TMPDIR/sg/tmp/swarm-retire.*" \
                        retire 2>&1)
            assert_eq "$_sg_name: retire waits in docker images" "yes" \
                "$(sed -n 's/^ready //p' <<< "$_sg_out")"
            assert_eq "$_sg_name:   its scratch directory there" "yes" \
                "$(sed -n 's/^before //p' <<< "$_sg_out")"
            assert_eq "$_sg_name:   ends with $_sg_want" "$_sg_want" \
                "$(sed -n 's/^rc //p' <<< "$_sg_out")"
            assert_eq "$_sg_name:   the line $_sg_lines time(s)" \
                "$_sg_lines" \
                "$(grep -c "$_sg_line" "$TMPDIR/sg/err" || true)"
            assert_eq "$_sg_name:   the scratch directory goes" "no" \
                "$(sed -n 's/^after //p' <<< "$_sg_out")"
            assert_eq "$_sg_name:   nothing removed" "0" "$(removed)"
        done
    done
fi
swarm_state_update "$RT/state.json" 'del(.engagement_id, .docker_daemon)'
reset_fake
assert_eq "no engagement and nothing left: retire succeeds" "0" "$(retire)"
assert_eq "with nothing to retire" "1" \
    "$(grep -c 'nothing to retire' "$TMPDIR/out" || true)"
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e1" | .docker_daemon = "d1"'
reset_fake
add proj-agent-1
rc=0
(cd "$REPO" && PATH="$TMPDIR/bin:$PATH" FAKE_DOCKER="$F" FAKE_CK="$CK" \
    SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
    SWARM_ENGAGEMENT_ID=e2 "$BASH" "$LAUNCH" retire > /dev/null 2>&1) \
    || rc=$?
assert_eq "another engagement id is refused" "1" "$rc"
# A token names the engagement: another one, none recorded, or an empty
# token is refused under the lock, before anything is removed; the
# engagement's own token goes on.
swarm_state_update "$RT/state.json" '.engagement_token = "aaaaaaaaaaaaaaaa"'
reset_fake
add proj-agent-1
assert_eq "another engagement's token: retire refused" "1" \
    "$(SWARM_ENGAGEMENT_TOKEN=bbbbbbbbbbbbbbbb retire)"
assert_eq "saying the engagement is gone" "1" \
    "$(grep -c 'the engagement this command was started for is gone' \
        "$TMPDIR/out" || true)"
assert_eq "and removes nothing" "0" "$(removed)"
reset_fake
add proj-agent-1
assert_eq "an empty token: retire refused" "1" \
    "$(SWARM_ENGAGEMENT_TOKEN='' retire)"
assert_eq "saying it is empty" "1" \
    "$(grep -c 'SWARM_ENGAGEMENT_TOKEN is set but empty' "$TMPDIR/out" \
        || true)"
assert_eq "and removes nothing" "0" "$(removed)"
reset_fake
add proj-agent-1
assert_eq "the engagement's own token: retire goes on" "0" \
    "$(SWARM_ENGAGEMENT_TOKEN=aaaaaaaaaaaaaaaa retire)"
assert_eq "and removes the stopped agent" "1" "$(removed)"
# With no engagement recorded and nothing left, retire has nothing to
# do; with a token, that engagement is gone.
swarm_state_update "$RT/state.json" \
    'del(.engagement_id, .docker_daemon, .engagement_token)'
reset_fake
assert_eq "a token with no engagement recorded: retire refused" "1" \
    "$(SWARM_ENGAGEMENT_TOKEN=aaaaaaaaaaaaaaaa retire)"
assert_eq "saying the engagement is gone" "1" \
    "$(grep -c 'the engagement this command was started for is gone' \
        "$TMPDIR/out" || true)"
assert_eq "without a token: nothing to retire" "0" "$(retire)"
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e1" | .docker_daemon = "d1"'
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
echo "=== 5. Git checkouts in a container's layer are kept ==="
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# The checkout's recovery refs, and its retire snapshots' sources.
rrefs() {
    git -C "$REPO" for-each-ref --format='%(refname)' refs/swarm-recovery/
}
nsources() {
    rrefs | grep -c '/sources$' || true
}
last_sources() {
    git -C "$REPO" cat-file blob "$(rrefs | grep '/sources$' | tail -1)"
}
clear_rrefs() {
    rrefs | sed 's/^/delete /' | git -C "$REPO" update-ref --stdin
}
# A checkout at $F/snaproot<PATH> with one commit.
fixture() {
    local d="$F/snaproot$1"
    mkdir -p "$d"
    git init -q "$d"
    echo one > "$d/a"
    g -C "$d" add a
    g -C "$d" commit -qm one
}
# Succeed when every object of the repository at DIR is in the checkout.
all_kept() {
    git -C "$1" cat-file --batch-all-objects --batch-check='%(objectname)' \
        | git -C "$REPO" cat-file --batch-check='%(objectname) %(objecttype)' \
        | grep -q ' missing$' && return 1
    return 0
}
kept_case() {
    reset_fake
    add proj-agent-1
    clear_rrefs
}
# A checkout with history of every kind: commits, a branch, a tag, a
# stash, a commit only its reflog reaches, and a file of its own in .git.
kept_case
fixture /tmp/fx
FX="$F/snaproot/tmp/fx"
g -C "$FX" checkout -q -b side
echo two > "$FX/b"
g -C "$FX" add b
g -C "$FX" commit -qm side
g -C "$FX" tag t1
g -C "$FX" checkout -q -
echo stashed > "$FX/a"
g -C "$FX" stash -q
echo lost > "$FX/c"
g -C "$FX" add c
g -C "$FX" commit -qm lost
g -C "$FX" reset -q --hard HEAD~1
echo note > "$FX/.git/my-notes"
assert_eq "a checkout in the layer: retired" "0" "$(retire)"
assert_eq "the container is removed" "1" "$(removed)"
assert_eq "every object of it is in the checkout" "true" \
    "$(all_kept "$FX" && echo true || echo false)"
assert_eq "its own file in .git too" "blob" \
    "$(git -C "$REPO" cat-file -t "$(git hash-object "$FX/.git/my-notes")" 2>/dev/null)"
assert_eq "the sources name the container, its id and the path" \
    'l1 layer proj-agent-1 id-proj-agent-1 "/tmp/fx"' "$(last_sources)"
assert_eq "one retire snapshot, with its sources ref" "1" "$(nsources)"
assert_eq "saying where" "1" \
    "$(grep -c 'kept as recovery refs under refs/swarm-recovery/e' "$TMPDIR/out" || true)"
# Work outside Git's history in it refuses, or is dropped and listed
# with --discard-uncommitted; files the engine writes in a workspace
# are nobody's in a layer checkout.
kept_case
fixture /tmp/fx2
FX2="$F/snaproot/tmp/fx2"
echo staged > "$FX2/s"
g -C "$FX2" add s
echo untracked > "$FX2/u"
mkdir -p "$FX2/agent_logs" "$FX2/.claude"
echo log > "$FX2/agent_logs/x"
echo '{}' > "$FX2/.claude/settings.local.json"
printf 'ign\n' > "$FX2/.gitignore"
g -C "$FX2" add .gitignore
g -C "$FX2" commit -qm ignore
echo staged > "$FX2/s"
echo i > "$FX2/ign"
echo changed > "$FX2/a"
g -C "$FX2" update-index --skip-worktree .gitignore
refused "a layer checkout with uncommitted work" \
    "holds work outside Git's history"
for _what in 'dirty .: ?? u' 'dirty .: ?? agent_logs/x' \
        'dirty .: ?? .claude/settings.local.json' 'dirty .:  M a' \
        'ignored .: ign' 'hidden .: S .gitignore'; do
    assert_eq "listed: ${_what}" "1" \
        "$(grep -cF -- "  ${_what}" "$TMPDIR/out" | awk '{ print ($1 > 0) }')"
done
assert_eq "nothing imported" "" "$(rrefs)"
assert_eq "with --discard-uncommitted: retired" "0" \
    "$(retire --discard-uncommitted)"
assert_eq "saying what is dropped" "1" \
    "$(grep -c 'Discarding, from proj-agent-1, in /tmp/fx2:' "$TMPDIR/out" || true)"
assert_eq "the staged blob is kept all the same" "blob" \
    "$(git -C "$REPO" cat-file -t "$(git hash-object "$FX2/s")" 2>/dev/null)"
# Nesting: a submodule is scanned with its parent; any other repository
# below a checkout makes that scan block.
kept_case
SUBSRC="$TMPDIR/subsrc5"
rm -rf "$SUBSRC"
git init -q "$SUBSRC"
echo s > "$SUBSRC/s"
g -C "$SUBSRC" add s
g -C "$SUBSRC" commit -qm sub
fixture /tmp/p
g -C "$F/snaproot/tmp/p" -c protocol.file.allow=always submodule add -q \
    "$SUBSRC" sub >/dev/null 2>&1
g -C "$F/snaproot/tmp/p" commit -qm add-sub
assert_eq "a checkout with a clean submodule: retired" "0" "$(retire)"
assert_eq "in one scan, its parent's" "/tmp/p" \
    "$(cat "$F/layer-scans" 2>/dev/null)"
assert_eq "the submodule's objects are kept" "true" \
    "$(all_kept "$F/snaproot/tmp/p/.git/modules/sub" && echo true || echo false)"
kept_case
fixture /tmp/p
g -C "$F/snaproot/tmp/p" -c protocol.file.allow=always submodule add -q \
    "$SUBSRC" sub >/dev/null 2>&1
g -C "$F/snaproot/tmp/p" commit -qm add-sub
echo changed > "$F/snaproot/tmp/p/sub/s"
refused "a dirty submodule in a layer checkout" "dirty sub"
kept_case
fixture /tmp/p
git init -q "$F/snaproot/tmp/p/inner"
echo i > "$F/snaproot/tmp/p/inner/i"
g -C "$F/snaproot/tmp/p/inner" add i
g -C "$F/snaproot/tmp/p/inner" commit -qm inner
assert_eq "a checkout inside a layer checkout: retired" "0" "$(retire)"
assert_eq "in one scan, its parent's" "/tmp/p" \
    "$(cat "$F/layer-scans" 2>/dev/null)"
assert_eq "the inner checkout's objects are kept" "true" \
    "$(all_kept "$F/snaproot/tmp/p/inner/.git" && echo true || echo false)"
kept_case
fixture /tmp/p
git init -q "$F/snaproot/tmp/p/inner"
echo i > "$F/snaproot/tmp/p/inner/i"
g -C "$F/snaproot/tmp/p/inner" add i
g -C "$F/snaproot/tmp/p/inner" commit -qm inner
echo changed > "$F/snaproot/tmp/p/inner/i"
refused "a dirty checkout inside a layer checkout" "dirty inner"
kept_case
fixture /tmp/p
git init -q --bare "$F/snaproot/tmp/p/x.git"
refused "a bare repository inside a layer checkout" "embedded x.git"
kept_case
fixture /tmp/a
fixture /tmp/ab
assert_eq "sibling checkouts /tmp/a and /tmp/ab: retired" "0" "$(retire)"
assert_eq "both scanned" "/tmp/a /tmp/ab" \
    "$(tr '\n' ' ' < "$F/layer-scans" | sed 's/ $//')"
assert_eq "both listed" "2" "$(last_sources | grep -c ' layer proj-agent-1 ')"
# Repositories that are not checkouts refuse as before.
kept_case
mkdir -p "$F/snaproot/srv"
git init -q --separate-git-dir "$F/snaproot/srv/gd" "$F/snaproot/srv/wt"
refused "a git dir apart from its work tree" "  /srv/gd"
assert_eq "and its gitfile" "1" \
    "$(grep -cxF '  /srv/wt/.git' "$TMPDIR/out" || true)"
# Links out of a layer checkout: into the unchanged image they are
# fine; into what the container wrote, or into /workspace, refuse.
kept_case
fixture /tmp/l
ln -s /usr/bin/env "$F/snaproot/tmp/l/env-link"
g -C "$F/snaproot/tmp/l" add env-link
g -C "$F/snaproot/tmp/l" commit -qm link
assert_eq "a tracked link to an unchanged image file: retired" "0" \
    "$(retire)"
kept_case
fixture /tmp/l
# (/srv: on macOS /tmp is itself a link, which the check would follow.)
ln -s /srv/hook-script "$F/snaproot/tmp/l/.git/hooks/pre-commit"
echo "A /srv/hook-script" > "$F/diff/id-proj-agent-1"
refused "a hook linked to a file the container wrote" \
    "links out of its volume to data in the container"
kept_case
fixture /tmp/l
ln -s /workspace/x "$F/snaproot/tmp/l/ws-link"
g -C "$F/snaproot/tmp/l" add ws-link
g -C "$F/snaproot/tmp/l" commit -qm ws
refused "a link into /workspace" "mount-crossing"
# Size: a container's layer checkouts, as bundles, stay under
# SWARM_RETIRE_LAYER_LIMIT_MB; --discard-uncommitted does not change that.
kept_case
fixture /tmp/big
head -c 2000000 /dev/urandom > "$F/snaproot/tmp/big/blob"
g -C "$F/snaproot/tmp/big" add blob
g -C "$F/snaproot/tmp/big" commit -qm big
SWARM_RETIRE_LAYER_LIMIT_MB=1 refused "a layer checkout over the limit" \
    "more than retire keeps"
SWARM_RETIRE_LAYER_LIMIT_MB=1 retire --discard-uncommitted > /dev/null
assert_eq "--discard-uncommitted does not change that" "0" "$(removed)"
kept_case
for _n in 1 2; do
    fixture "/tmp/half$_n"
    head -c 700000 /dev/urandom > "$F/snaproot/tmp/half$_n/blob"
    g -C "$F/snaproot/tmp/half$_n" add blob
    g -C "$F/snaproot/tmp/half$_n" commit -qm half
done
SWARM_RETIRE_LAYER_LIMIT_MB=1 refused "two layer checkouts over the limit together" \
    "more than retire keeps"
for _bad in 0 x 1.5; do
    kept_case
    SWARM_RETIRE_LAYER_LIMIT_MB="$_bad" refused \
        "SWARM_RETIRE_LAYER_LIMIT_MB '${_bad}'" "SWARM_RETIRE_LAYER_LIMIT_MB must be"
done
# A scan whose result lacks a part is not trusted.
for _miss in nogitdir nobundle noobjects empty; do
    kept_case
    fixture /tmp/fx3
    echo "$_miss" > "$F/layer-scan-incomplete"
    refused "a layer scan with ${_miss}" "is incomplete"
done
# Paths that are not valid UTF-8 cannot cross Docker's JSON; macOS file
# systems refuse to make them.
if mkdir "$F/snaproot/tmp/bad$(printf '\377')" 2>/dev/null; then
    kept_case
    mkdir -p "$F/snaproot/tmp"
    git init -q "$F/snaproot/tmp/bad$(printf '\377')"
    refused "a checkout whose path is not valid UTF-8" "not valid UTF-8"
else
    echo "  SKIP: no file names that are not valid UTF-8 here"
fi

# Lists that cannot be written or read in full: retire keeps a list of
# what it found and of what it scans; a write that fails, or a read
# that fails (ending its loop like the end of the list), refuses with
# nothing removed.  Sourced through BASH_ENV by the bash that runs
# retire: the HOOK_AT-th read whose arguments are HOOK_SIG fails, and a
# printf with format HOOK_FMT whose arguments hold HOOK_MATCH fails.
cat > "$TMPDIR/retire-hook.sh" <<'EOF'
read() {
    # (No local named like a variable the caller reads into; the
    # arguments joined with spaces, whatever IFS the caller set.)
    local __hook_n __hook_sig="" __hook_a
    for __hook_a in "$@"; do
        __hook_sig="${__hook_sig} ${__hook_a}"
    done
    if [ -n "${HOOK_SIG:-}" ] && [ "${__hook_sig# }" = "$HOOK_SIG" ]; then
        __hook_n=$(( $(cat "$HOOK_COUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$__hook_n" > "$HOOK_COUNT"
        [ "$__hook_n" -ne "$HOOK_AT" ] || return 1
    fi
    builtin read "$@"
}
printf() {
    if [ -n "${HOOK_FMT:-}" ] && [ "$1" = "$HOOK_FMT" ]; then
        case "$*" in
            *"$HOOK_MATCH"*) return 1 ;;
        esac
    fi
    builtin printf "$@"
}
EOF
# Retire with the hook; print its status.
retire_hooked() {
    rm -f "$TMPDIR/hook-count"
    BASH_ENV="$TMPDIR/retire-hook.sh" HOOK_COUNT="$TMPDIR/hook-count" \
        retire
}
list_case() {
    reset_fake
    add proj-agent-1
    clear_rrefs
    fixture /tmp/lw
    git init -q --bare "$F/snaproot/tmp/lw-bare.git"
}
list_case
rm -rf "$F/snaproot/tmp/lw-bare.git"
assert_eq "control: the hook passes a plain retire" "0" \
    "$(HOOK_SIG=none HOOK_AT=1 retire_hooked)"
list_case
rm -rf "$F/snaproot/tmp/lw-bare.git"
assert_eq "a write to the list of what was found fails: refused" "1" \
    "$(HOOK_FMT='%s\t%s\n' HOOK_MATCH=/tmp/lw/.git retire_hooked)"
assert_eq "saying so" "1" \
    "$(grep -c 'cannot keep track of the Git repositories' "$TMPDIR/out" || true)"
assert_eq "nothing removed" "0" "$(removed)"
list_case
rm -rf "$F/snaproot/tmp/lw-bare.git"
assert_eq "a write to the list of checkouts to scan fails: refused" "1" \
    "$(HOOK_FMT='%s\n' HOOK_MATCH=/tmp/lw retire_hooked)"
assert_eq "nothing removed" "0" "$(removed)"
list_case
assert_eq "a read that fails in the classifying pass: refused" "1" \
    "$(HOOK_SIG='-r path kind' HOOK_AT=4 retire_hooked)"
assert_eq "saying so, not skipping the bare repository" "1" \
    "$(grep -c 'cannot keep track of the Git repositories' "$TMPDIR/out" || true)"
assert_eq "nothing removed" "0" "$(removed)"
list_case
rm -rf "$F/snaproot/tmp/lw-bare.git"
assert_eq "a read that fails in the scanning pass: refused" "1" \
    "$(HOOK_SIG='-r path' HOOK_AT=1 retire_hooked)"
assert_eq "nothing removed" "0" "$(removed)"
list_case
rm -rf "$F/snaproot/tmp/lw-bare.git"
assert_eq "a read that fails in the size pass: refused" "1" \
    "$(HOOK_SIG='-r c _ _ path' HOOK_AT=1 retire_hooked)"
assert_eq "nothing removed" "0" "$(removed)"

# The import step on its own (lib/retire.sh loaded here, its import
# stubbed): a line count that cannot be read, or a path the JSON encoder
# fails on, publishes no sources ref and fails.
keep_alone() {
    local rc=0 scratch
    scratch=$(mktemp -d "$TMPDIR/keep.XXXXXX")
    mkdir -p "$scratch/layer/1"
    printf '1\tid-x\tproj-agent-1\t/tmp/fx\n' > "$scratch/layer.list"
    (
        ENGINE="$REPO_ROOT"
        # shellcheck source=../lib/preserve.sh
        source "$ENGINE/lib/preserve.sh"
        # shellcheck source=../lib/retire.sh
        source "$ENGINE/lib/retire.sh"
        # shellcheck disable=SC2034  # read by the function run here
        REPO_ROOT="$REPO" RUNTIME_DIR="$RT" RETIRE_SCRATCH="$scratch"
        # shellcheck disable=SC2329
        swarm_recovery_import() { return 0; }
        eval "$1"
        retire_keep_layer_checkouts e1 > /dev/null 2>&1
    ) || rc=$?
    printf '%s' "$rc"
}
clear_rrefs
assert_eq "control: the import step alone publishes its sources ref" "0" \
    "$(keep_alone :)"
assert_eq "control: one sources ref" "1" "$(nsources)"
clear_rrefs
# shellcheck disable=SC2016  # evaluated in keep_alone
assert_eq "a line count that cannot be read: the import step fails" "1" \
    "$(keep_alone 'retire_count_lines() { return 1; }')"
assert_eq "no sources ref" "0" "$(nsources)"
# shellcheck disable=SC2016  # evaluated in keep_alone
assert_eq "a path the JSON encoder fails on: the import step fails" "1" \
    "$(keep_alone 'jq() { case "$*" in "-R -s .") return 1 ;; esac; command jq "$@"; }')"
assert_eq "no sources ref" "0" "$(nsources)"

# The transaction: every import, then git fsck, then the sources ref,
# then removal.  A git that fails or stops at a step (a shim on PATH).
SHIM5="$TMPDIR/bin-git-5"
mkdir -p "$SHIM5"
_rgit=$(command -v git)
cat > "$SHIM5/git" <<EOF
#!/bin/bash
case " \$* " in
    *" fetch "*bundle*)
        n=\$(cat "$F/fetches" 2>/dev/null || echo 0)
        n=\$((n + 1))
        echo "\$n" > "$F/fetches"
        if [ -e "$F/fetch-fails-at" ] && [ "\$n" = "\$(cat "$F/fetch-fails-at")" ]; then
            exit 1
        fi
        if [ -e "$F/fetch-then-fail" ]; then
            "$_rgit" "\$@"
            exit 1
        fi
        if [ -e "$F/term-on-fetch" ]; then
            kill -TERM 0
        fi ;;
    *" fsck "*)
        [ ! -e "$F/fsck-fails" ] || exit 1
        if [ -e "$F/term-on-fsck" ]; then
            kill -TERM 0
        fi ;;
    *" update-ref "*"/sources "*)
        [ ! -e "$F/sources-fails" ] || exit 1 ;;
esac
exec "$_rgit" "\$@"
EOF
chmod +x "$SHIM5/git"
tx_case() {
    reset_fake
    add proj-agent-1
    add proj-agent-2
    clear_rrefs
    fixture /tmp/tx
    SHIM_DIR="$SHIM5"
}
tx_case
edit proj-agent-2 '.[0].HostConfig.RestartPolicy.Name = "always"'
assert_eq "the second container refused: retire fails" "1" "$(retire)"
assert_eq "nothing imported" "" "$(rrefs)"
assert_eq "nothing removed" "0" "$(removed)"
tx_case
echo 2 > "$F/fetch-fails-at"
assert_eq "the second import fails: retire fails" "1" "$(retire)"
assert_eq "nothing removed" "0" "$(removed)"
assert_eq "no sources ref" "0" "$(nsources)"
assert_eq "the first import's refs stay" "true" \
    "$([ -n "$(rrefs | grep '/l1/')" ] && echo true || echo false)"
_first=$(rrefs | head -1 | cut -d/ -f4)
tx_case
_now=$(retire)
assert_eq "the next run: retired" "0" "$_now"
assert_eq "under a new snapshot" "true" \
    "$([ -n "$(rrefs | grep '/sources$')" ] && echo true || echo false)"
tx_case
: > "$F/fetch-then-fail"
assert_eq "an import that updates its refs and then fails" "1" "$(retire)"
assert_eq "nothing removed" "0" "$(removed)"
assert_eq "no sources ref" "0" "$(nsources)"
tx_case
: > "$F/sources-fails"
assert_eq "the sources ref cannot be written" "1" "$(retire)"
assert_eq "nothing removed" "0" "$(removed)"
tx_case
: > "$F/fsck-fails"
assert_eq "git fsck fails" "1" "$(retire)"
assert_eq "nothing removed" "0" "$(removed)"
assert_eq "no sources ref" "0" "$(nsources)"
tx_case
: > "$F/term-on-fetch"
assert_eq "a SIGTERM during an import" "143" "$(retire_own_group)"
assert_eq "nothing removed" "0" "$(removed)"
assert_eq "no sources ref" "0" "$(nsources)"
tx_case
: > "$F/term-on-fsck"
assert_eq "a SIGTERM during git fsck" "143" "$(retire_own_group)"
assert_eq "nothing removed" "0" "$(removed)"
assert_eq "no sources ref" "0" "$(nsources)"
tx_case
: > "$F/term-on-rm"
assert_eq "a SIGTERM during removal" "143" "$(retire_own_group)"
assert_eq "one container is gone" "1" "$(removed)"
assert_eq "the sources ref is there" "1" "$(nsources)"
: > "$F/log"
printf 'id-proj-agent-2 proj-agent-2\n' > "$F/containers"
assert_eq "the next retire takes the other" "0" "$(retire)"
assert_eq "copying it again under a new snapshot" "2" "$(nsources)"
tx_case
jq '.[0].State.StartedAt = "S2"' "$F/inspect/id-proj-agent-1" \
    > "$F/inspect/id-proj-agent-1.now"
assert_eq "a container restarted during the import is left" "1" "$(retire)"
assert_eq "the other one goes" "1" "$(removed)"
SHIM_DIR=""

# ============================================================
echo ""
echo "=== 6. Linked worktrees of the volume's repositories in the layer ==="
# One container (proj-agent-2) whose volume holds a repository that
# registers a linked worktree in the container's layer ($F/snaproot,
# resolved; repos-unmapped so the layer search names it the way the
# volume scan does).  The real scanner runs through the production
# helper's script.
xw_setup() {  # NAME: the worktree's name
    reset_fake
    add proj-agent-2
    touch "$F/repos-unmapped"
    XS=$(cd -P "$F/snaproot" && pwd -P)
    _d=$(real_ws)
    echo a > "$_d/a"
    git -C "$_d" add a
    git -C "$_d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
        commit -q -m a
    git -C "$_d" worktree add -q --detach "$XS/$1" HEAD 2>/dev/null
}
xw_setup wt
assert_eq "a clean linked worktree in the layer: retired" "0" "$(retire)"
assert_eq "  the container removed" "1" "$(removed)"
assert_eq "  scanned by the helper's script from swarm_scan_volume" "1" \
    "$(grep -c 'mktemp -d /swarm-volume-scan\.XXXXXX' "$F/helper-prog")"
xw_setup wt
echo u > "$XS/wt/untracked.txt"
refused "work outside Git's history in it" \
    "a linked worktree outside /workspace, in its layer, holds work"
assert_eq "  naming the file" "1" \
    "$(grep -cF "dirty $XS/wt: ?? untracked.txt" "$TMPDIR/out")"
assert_eq "--discard-uncommitted retires it" "0" \
    "$(retire --discard-uncommitted)"
assert_eq "  listing what it drops" "1" \
    "$(grep -cF "dirty $XS/wt: ?? untracked.txt" "$TMPDIR/out")"
# A submodule not initialized in such a worktree: a file under its
# directory is work in the layer too, never taken for the volume's.
xw_setup wt
git -C "$_d" update-index --add --cacheinfo \
    "160000,$(git -C "$_d" rev-parse HEAD),sub"
git -C "$_d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q -m gitlink
mkdir -p "$_d/sub"
git -C "$_d" worktree add -q --detach "$XS/wtg" HEAD 2>/dev/null
mkdir -p "$XS/wtg/sub"
echo n > "$XS/wtg/sub/notes.txt"
refused "a file under a submodule not initialized in it" \
    "a linked worktree outside /workspace, in its layer, holds work"
assert_eq "  naming the file" "1" \
    "$(grep -cF "dirty $XS/wtg: ?? sub/notes.txt" "$TMPDIR/out")"
xw_setup wt
echo v > "$F/voldir/proj-agent-2-ws-00000000/in-volume.txt"
assert_eq "the volume's own untracked file still never stops retire" "0" \
    "$(retire)"
xw_setup wt
rm -rf "${XS:?}/wt"
assert_eq "a registration whose directory is gone: retired" "0" "$(retire)"
xw_setup wt
mkdir -p "$XS/wt2"
cp "$XS/wt/.git" "$XS/wt2/.git"
refused "another .git file in the layer is still refused" \
    "a .git file or link"
xw_setup wt
add proj-agent-1
refused "the same path in a container whose scan did not check it" \
    "a .git file or link"
for _xt in "unterminated:sent a malformed list" \
        "duplicate:sent a malformed list" "relative:sent a malformed list" \
        "control:sent a malformed list" \
        "extra:lists a linked worktree its report does not name" \
        "forged:its list of linked worktrees disagree" \
        "nolist:sent no list of them" "big:external-worktrees is too large" \
        "empty:its list of linked worktrees disagree" \
        "emptyrec:sent a malformed list" "utf8:sent a malformed list" \
        "b65536:sent a malformed list" \
        "b65537:external-worktrees is too large"
do
    xw_setup wt
    echo "${_xt%%:*}" > "$F/xtamper"
    refused "a list or report changed on the way (${_xt%%:*})" "${_xt#*:}"
done
rm -f "$F/xtamper"
# A path with a space, a backslash and glob characters, compared as it
# is.
xw_setup 'w t\*?[x]'
assert_eq "a worktree path with a space, a backslash and globs: retired" \
    "0" "$(retire)"
# A check of the list whose read fails is not an answer.
xw_setup wt
mkdir -p "$TMPDIR/xshim2"
cat > "$TMPDIR/xshim2/grep" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in */external.ok) exit 2 ;; esac
done
exec $(command -v grep) "\$@"
EOF
chmod +x "$TMPDIR/xshim2/grep"
SHIM_DIR="$TMPDIR/xshim2"
refused "a list retire cannot check" \
    "cannot check the list of linked worktrees"
SHIM_DIR=""
# A read of the report that fails is not a report without such lines.
xw_setup wt
mkdir -p "$TMPDIR/xshim"
cat > "$TMPDIR/xshim/grep" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" != '^external-worktree ' ] || exit 2; done
exec $(command -v grep) "\$@"
EOF
chmod +x "$TMPDIR/xshim/grep"
SHIM_DIR="$TMPDIR/xshim"
refused "a report retire cannot read" "cannot read the workspace scan"
SHIM_DIR=""
# A worktree let through (with a link inside it) does not hide the
# volume's own link out.
xw_setup wt
_d="$F/voldir/proj-agent-2-ws-00000000"
ln -s a "$_d/inner-link"
git -C "$_d" add inner-link
git -C "$_d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q -m link
git -C "$XS/wt" checkout -q --detach "$(git -C "$_d" rev-parse HEAD)"
rm "$_d/inner-link"
git -C "$_d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q -am "no link"
assert_eq "  the worktree holds a tracked link and nothing else to report" \
    "" "$(git -C "$XS/wt" status --porcelain)"
ln -s "$L/lfs" "$F/voldir/proj-agent-2-ws-00000000/lfs-link"
printf 'A %s/lfs\nA %s/lfs/objects\n' "$L" "$L" > "$F/diff/id-proj-agent-2"
refused "a volume link to data the container wrote, next to a worktree" \
    "links out of its volume to data"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
