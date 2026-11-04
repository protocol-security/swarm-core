#!/bin/bash
# launch.sh retire: remove this checkout's stopped engine containers
# without losing anything.  A container's /workspace is a Docker volume
# that stays; what dies with the container is its own layer, so retire
# refuses any container whose layer may hold work: one that runs or may
# still start, one whose /workspace is not exactly its volume, one with
# git settings that put repository data outside the volume, one whose
# workspace registers a worktree or links to data outside the volume,
# and one with a Git repository anywhere outside the volume.  Every
# selected container is checked before any is removed.
#
# Sourced by launch.sh after lib/project.sh and lib/preserve.sh; uses
# PROJECT, CHECKOUT_PATH, RUNTIME_DIR, STATE_FILE and IMAGE_NAME.

# What an interrupted retire (Ctrl-C, a timeout's SIGTERM) would leave
# behind: the scratch directory every check writes under, the snapshot
# in use (named before docker commit runs), and containers made from
# it.  Every docker command that makes something runs in a process
# group of its own (swarm_docker_own_group): a Ctrl-C does not stop
# the client mid-request, and the cleanup waits for it first.
RETIRE_SCRATCH=""
RETIRE_SNAP_REF=""
# Retire's own helper containers carry this label (with the project),
# so that its sweep removes nothing else made from a snapshot.
RETIRE_HELPER_LABEL="swarm-core.retire"

# Print a new directory under RETIRE_SCRATCH (or the system's temporary
# directory when retire's own is not set up).  The template is explicit:
# macOS mktemp ignores TMPDIR without one.
retire_tmpdir() {
    if [ -n "$RETIRE_SCRATCH" ]; then
        mktemp -d "$RETIRE_SCRATCH/check.XXXXXX"
    else
        mktemp -d "${TMPDIR:-/tmp}/swarm-retire.XXXXXX"
    fi
}

# Remove the helper containers retire made from image REF (the checks
# run them with --rm; one a stopped client left behind would keep the
# image).  Only those with retire's label go; anything else made from
# the snapshot (a container someone started to look into it) stays,
# and with it the snapshot.
retire_drop_containers() {
    local ref="$1" c other
    if [ -z "$ref" ]; then
        return 0
    fi
    for c in $(docker ps -aq --filter "ancestor=${ref}" \
            --filter "label=${RETIRE_HELPER_LABEL}=${PROJECT}" 2>/dev/null); do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    other=$(docker ps -aq --filter "ancestor=${ref}" 2>/dev/null) \
        || other=""
    if [ -n "$other" ]; then
        echo "WARNING: containers made from ${ref} that retire did not" \
             "start stay, and so does ${ref}:" \
             "$(printf '%s' "$other" | tr '\n' ' ')" >&2
    fi
}

# Remove the snapshot RETIRE_SNAP_REF names, if any.  Fails when it is
# still there.  The name is forgotten only after the attempt, so that a
# signal in between leaves the cleanup something to remove (doing it
# twice is harmless).
retire_drop_snapshot() {
    local ref="$RETIRE_SNAP_REF" rc=0
    if [ -z "$ref" ]; then
        return 0
    fi
    # Gone when docker rmi works, or when there is no such image (never
    # made, or removed already).
    if ! docker rmi "$ref" >/dev/null 2>&1 \
            && docker image inspect "$ref" >/dev/null 2>&1; then
        rc=1
    fi
    RETIRE_SNAP_REF=""
    return "$rc"
}

# Remove the snapshots an earlier retire left (one killed outright, so
# that its cleanup never ran).  Under the engagement lock no other
# retire of this project runs, so every image of ${IMAGE_NAME}-retire
# is such a leftover.
retire_sweep_snapshots() {
    local refs ref
    if ! refs=$(docker images --format '{{.Repository}}:{{.Tag}}' \
            --filter "reference=${IMAGE_NAME}-retire" 2>/dev/null); then
        echo "ERROR: cannot list Docker images." >&2
        return 1
    fi
    # The list comes on descriptor 3 and nothing in the loop reads
    # standard input: a command that does (docker run -i) cannot eat it.
    while IFS= read -r -u 3 ref; do
        if [ -z "$ref" ]; then
            continue
        fi
        retire_drop_containers "$ref"
        if docker rmi "$ref" >/dev/null 2>&1; then
            echo "Removed ${ref}, a snapshot an earlier retire left."
        else
            echo "WARNING: cannot remove ${ref}, a snapshot an earlier" \
                 "retire left." >&2
        fi
    done 3<<EOF < /dev/null
$refs
EOF
}

retire_cleanup() {
    # Every background job is a docker command retire started; a signal
    # can come before its pid is known, so wait for them all.
    wait 2>/dev/null || true
    retire_drop_containers "$RETIRE_SNAP_REF"
    retire_drop_snapshot || true
    if [ -n "$RETIRE_SCRATCH" ]; then
        rm -rf "$RETIRE_SCRATCH"
        RETIRE_SCRATCH=""
    fi
}

# Print, for container ID named NAME, one line
#   <id> <name> <volume> <started> <finished>
# when it may be removed, or say why not on stderr and fail.
swarm_retire_preflight() {
    local id="$1" name="$2" info verdict vol kind context live tmp
    local started finished vlabels
    info=$(docker container inspect "$id" 2>/dev/null) || {
        echo "ERROR: cannot inspect container ${name}." >&2
        return 1
    }
    # One verdict from the container's own description: its state, its
    # restart and auto-remove settings, and the mounts at and below
    # /workspace.
    verdict=$(printf '%s' "$info" | jq -r --arg name "$name" '
        .[0] as $c
        | ($c.State.Status // "") as $st
        | [($c.Mounts // [])[] | select(.Destination == "/workspace"
            or (.Destination | startswith("/workspace/")))] as $ws
        | (($c.HostConfig.Tmpfs // {}) | keys
            | map(select(. == "/workspace" or startswith("/workspace/"))))
            as $tmpfs
        | if ($st != "exited" and $st != "created") then
            "state " + $st
          elif (($c.HostConfig.RestartPolicy.Name // "") as $r
                | $r != "" and $r != "no") then
            "restart policy " + $c.HostConfig.RestartPolicy.Name
          elif ($c.HostConfig.AutoRemove // false) then
            "auto-remove is on"
          elif ($tmpfs | length) > 0 then
            "tmpfs at " + ($tmpfs | join(", "))
          elif ($ws | length) != 1 then
            "no single workspace mount (" + ($ws | length | tostring)
                + " mounts at or below /workspace)"
          elif $ws[0].Destination != "/workspace"
                or $ws[0].Type != "volume" then
            "workspace is not a volume at /workspace"
          elif ([($c.HostConfig.Mounts // [])[]
                 | select(.Target == "/workspace")
                 | (.VolumeOptions.Subpath // "")] | map(select(. != ""))
                 | length) > 0 then
            "the workspace mounts a subdirectory of its volume"
          elif ([($c.Mounts // [])[] | .Destination]
                + (($c.HostConfig.Tmpfs // {}) | keys)
                | map(select(test("[\u0000-\u001f\u007f]"))) | length) > 0 then
            "a mount destination holds a control character"
          else
            "ok " + $ws[0].Name + " " + ($c.State.StartedAt // "")
                + " " + ($c.State.FinishedAt // "")
          end') || verdict="unreadable"
    case "$verdict" in
        "ok "*) ;;
        *)
            echo "ERROR: container ${name} cannot be retired: ${verdict}." >&2
            case "$verdict" in
                "restart policy"*)
                    echo "  docker update --restart no ${id}" >&2 ;;
                "no single workspace mount"*|"workspace is not"*)
                    echo "  Its files live in its own layer. Copy what you" \
                         "need (docker cp ${id}:/workspace <dir>), then" \
                         "docker rm ${id}." >&2 ;;
            esac
            return 1 ;;
    esac
    read -r _ vol started finished <<EOF
$verdict
EOF
    # The volume must be this container's workspace volume.
    vlabels=$(docker volume inspect -f '{{json .Labels}}' "$vol" \
        2>/dev/null) || vlabels=""
    if ! printf '%s' "$vlabels" | jq -e \
            --arg pk "$SWARM_PROJECT_LABEL" --arg p "$PROJECT" \
            --arg ck "$SWARM_CHECKOUT_LABEL" --arg c "$CHECKOUT_PATH" \
            --arg nk "$SWARM_CONTAINER_LABEL" --arg n "$name" '
            .[$pk] == $p and .[$ck] == $c and .[$nk] == $n' \
            >/dev/null 2>&1; then
        echo "ERROR: the /workspace volume of ${name} (${vol}) is not" \
             "its workspace volume." >&2
        return 1
    fi
    kind=$(printf '%s' "$vlabels" | jq -r --arg k "$SWARM_KIND_LABEL" \
        '.[$k] // ""')
    context=$(printf '%s' "$vlabels" | jq -r --arg k "$SWARM_CONTEXT_LABEL" \
        '.[$k] // ""')
    # An interactive session that is open (or may still start) keeps its
    # container.
    if [ "$kind" = interactive ]; then
        live=$(swarm_pending_live "$RUNTIME_DIR") || return 1
        # A here-string, not a pipe: under pipefail, grep -q leaving
        # early can fail the writer and hide the match.
        if grep -qxF -- "$name" <<< "$live"; then
            echo "ERROR: the interactive session ${name} is open." >&2
            return 1
        fi
    fi
    # The checks below run from a snapshot of this very container
    # (docker commit: its image plus its own layer), so links and files
    # resolve as they would inside it.  The snapshot is removed after.
    local snap scan_rc=0
    tmp=$(retire_tmpdir) || return 1
    # The container is stopped, so there is nothing to pause.  The
    # snapshot is named before docker commit runs, so that an
    # interrupted retire can still remove it (retire_cleanup).  Some
    # Docker versions print notices on stdout; only the image id line
    # counts.
    RETIRE_SNAP_REF="${IMAGE_NAME}-retire:$(printf '%.12s' "$id")-$$"
    # The daemon finishes an image even when its client stops, so the
    # commit runs in a process group of its own (a Ctrl-C does not reach
    # it) and retire_cleanup waits for it.  The engine's labels on the
    # snapshot are emptied: a check container that outlived retire must
    # not pass for one of the engine's.
    local strip
    strip="LABEL ${SWARM_PROJECT_LABEL}=\"\" ${SWARM_CHECKOUT_LABEL}=\"\""
    strip+=" ${SWARM_SESSION_LABEL}=\"\""
    if ! swarm_docker_own_group commit --change "$strip" \
            "$id" "$RETIRE_SNAP_REF" < /dev/null > "$tmp/commit" \
            2>"$tmp/err"; then
        echo "ERROR: cannot snapshot ${name} for its scan:" \
             "$(cat "$tmp/err")" >&2
        retire_drop_snapshot || true
        rm -rf "$tmp"
        return 1
    fi
    snap=$(grep -E '^sha256:[0-9a-f]{64}$' "$tmp/commit" | tail -1)
    if [ -z "$snap" ]; then
        echo "ERROR: docker commit of ${name} printed no image id." >&2
        retire_drop_snapshot || true
        rm -rf "$tmp"
        return 1
    fi
    local mounts
    mounts=$(printf '%s' "$info" | jq -r '.[0] as $c
        | [($c.Mounts // [])[] | .Destination]
          + (($c.HostConfig.Tmpfs // {}) | keys)
          + ["/etc/hosts", "/etc/hostname", "/etc/resolv.conf",
             "/dev", "/proc", "/sys"]
        | unique | .[] | select(. != "/workspace")') || {
        echo "ERROR: cannot read the mounts of ${name}." >&2
        retire_drop_snapshot || true
        rm -rf "$tmp"
        return 1
    }
    # Git settings in the container's global and system config can keep
    # repository data outside the volume.
    if ! swarm_retire_config_check "$id" "$name" "$snap" "$mounts"; then
        retire_drop_snapshot || true
        rm -rf "$tmp"
        return 1
    fi
    # The scan runs from the snapshot too, so it carries retire's label.
    # shellcheck disable=SC2034  # read by swarm_scan_volume
    SWARM_SCAN_DOCKER_ARGS=(--label "${RETIRE_HELPER_LABEL}=${PROJECT}")
    swarm_scan_volume "$vol" "$snap" "${context:-full}" "$tmp" "$mounts" \
        2>"$tmp/err" || scan_rc=$?
    # shellcheck disable=SC2034
    SWARM_SCAN_DOCKER_ARGS=()
    # The snapshot is still needed below; every path from here removes
    # it before returning.
    local ok=0
    swarm_retire_after_scan "$id" "$name" "$snap" "$info" "$tmp" "$scan_rc" \
        || ok=$?
    if ! retire_drop_snapshot; then
        echo "WARNING: cannot remove the scan snapshot ${snap} of" \
             "${name}; remove it with docker rmi ${snap}." >&2
    fi
    rm -rf "$tmp"
    [ "$ok" -eq 0 ] || return 1
    printf '%s %s %s %s %s\n' "$id" "$name" "$vol" "$started" "$finished"
}

# The checks on scan output in TMP for container ID (snapshot SNAP,
# inspect JSON INFO; SCAN_RC is the scan's status).  Fails when the
# container may not be retired.
swarm_retire_after_scan() {
    local id="$1" name="$2" snap="$3" info="$4" tmp="$5" scan_rc="$6"
    if [ "$scan_rc" -ne 0 ]; then
        echo "ERROR: cannot scan the workspace of ${name}:" >&2
        sed 's/^/  /' "$tmp/err" >&2
        return 1
    fi
    # Any blocking finding stops retire: some put repository data in the
    # container's layer (worktrees elsewhere, a .git link or gitfile,
    # LFS storage or config pointing elsewhere, links out of a git dir),
    # and the others (nested repositories, files without a repository)
    # are not inspected deeply enough to rule that out.  Uncommitted
    # files in the volume stay with the volume.
    local grc=0
    grep -a '^block ' "$tmp/report" > "$tmp/blocks" 2>/dev/null || grc=$?
    case "$grc" in
        0)
            echo "ERROR: ${name} cannot be retired; its workspace scan" \
                 "found:" >&2
            sed 's/^block /  /' "$tmp/blocks" >&2
            echo "  Data outside /workspace is in the container: copy it" \
                 "out (docker cp ${id}:<path> <dir>) or move it into" \
                 "/workspace first." >&2
            return 1 ;;
        1) ;;
        *)
            echo "ERROR: cannot read the workspace scan of ${name}." >&2
            return 1 ;;
    esac
    # Repositories the container made or changed outside the volume
    # (a clone in /tmp, commits in a repository of the image) are in its
    # layer only.
    swarm_retire_layer_repos "$id" "$name" "$snap" || return 1
    # Symlinks in the volume that lead out of it: fine when they point
    # into the image (a virtualenv's python), not when the target, or
    # anything below it, is something the container added or changed.
    swarm_retire_layer_links "$id" "$name" "$tmp/report" "$info" "$snap"
}

# Write docker diff of container ID to file OUT, failing when it cannot
# be read or when a name may not be the real one: docker prints paths
# unescaped, so a name with a newline would split into lines that look
# like something else (any line not "<A|C|D> /<path>"), and Docker sends
# them as JSON, which turns bytes that are not UTF-8 into U+FFFD.
swarm_retire_diff() {
    local id="$1" name="$2" out="$3"
    if ! docker diff "$id" > "$out" 2>/dev/null; then
        echo "ERROR: cannot list what ${name} changed (docker diff)." >&2
        return 1
    fi
    local rc=0
    grep -avE '^[ACD] /' "$out" > /dev/null 2>&1 || rc=$?
    case "$rc" in
        0)
            echo "ERROR: ${name} changed paths whose names docker diff" \
                 "cannot report unambiguously (a newline in a name)." >&2
            return 1 ;;
        1) ;;
        *)
            echo "ERROR: cannot read what ${name} changed." >&2
            return 1 ;;
    esac
    rc=0
    grep -aF "$(printf '\357\277\275')" "$out" > /dev/null 2>&1 || rc=$?
    case "$rc" in
        0)
            echo "ERROR: ${name} changed paths whose names docker diff" \
                 "cannot report exactly (not valid UTF-8)." >&2
            return 1 ;;
        1) ;;
        *)
            echo "ERROR: cannot read what ${name} changed." >&2
            return 1 ;;
    esac
}

# Fail when snapshot SNAP of container ID holds a Git repository
# outside /workspace (the volume, scanned on its own): a .git entry of
# any type, or a directory with a HEAD entry next to objects or
# commondir (a bare repository, or a git dir kept apart from its work
# tree).  One the container made (a clone in /tmp) holds work only it
# has.  One the image ships may hold commits, tags, objects or edits
# the container added, and docker diff cannot be trusted to show them:
# it goes by metadata, which a write can keep, and an objects/ that is
# a link puts new objects outside the repository.  So any repository
# refuses, changed or not.
swarm_retire_layer_repos() {
    local id="$1" name="$2" snap="$3" tmp rc=0
    tmp=$(retire_tmpdir) || return 1
    swarm_docker_own_group run --rm --pull never --network none --user 0 \
        --label "${RETIRE_HELPER_LABEL}=${PROJECT}" \
        --entrypoint bash "$snap" -c '
            # swarm-repos: every Git repository under $1 (the root of
            # the snapshot) but outside $1/workspace.
            set -o pipefail
            r="${1%/}"
            e=$(mktemp "${TMPDIR:-/tmp}/swarm-repos.XXXXXX") || exit 3
            s=0
            find "${r:-/}" -xdev -path "$r/workspace" -prune \
                    -o -name .git -print0 -prune -o -name HEAD -print0 \
                    2>"$e" |
            while IFS= read -r -d "" f; do
                case "$f" in
                    */.git) printf "%s\n" "$f" ;;
                    *)
                        d="${f%/HEAD}"
                        if [ -e "$d/objects" ] || [ -L "$d/objects" ] \
                                || [ -e "$d/commondir" ] \
                                || [ -L "$d/commondir" ]; then
                            printf "%s\n" "${d:-/}"
                        fi ;;
                esac
            done || s=3
            if [ -s "$e" ]; then
                cat "$e" >&2
                s=3
            fi
            rm -f "$e"
            exit "$s"
        ' swarm-repos / < /dev/null > "$tmp/repos.raw" 2>"$tmp/err" \
        || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: cannot check ${name} for Git repositories:" \
             "$(cat "$tmp/err")" >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! sort -u "$tmp/repos.raw" > "$tmp/repos"; then
        echo "ERROR: cannot check ${name} for Git repositories." >&2
        rm -rf "$tmp"
        return 1
    fi
    if [ -s "$tmp/repos" ]; then
        echo "ERROR: ${name} has Git repositories outside its workspace" \
             "volume, in its own layer or in its image; retire cannot" \
             "tell whether it changed them:" >&2
        sed 's/^/  /' "$tmp/repos" >&2
        echo "  Push or copy out what they hold (docker cp" \
             "${id}:<path> <dir>); then, if nothing of yours is left in" \
             "them, remove the container yourself (docker rm ${id})." >&2
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
}

# Fail when scan REPORT names, as a layer-link, a path that container
# ID added or changed (docker diff), or one with such a path below it;
# or when a layer-link or layer-via path lies at or below one of the
# container's other mounts or tmpfs, including the files Docker mounts
# itself (/etc/hosts, /etc/hostname, /etc/resolv.conf; INFO is its
# inspect JSON): the
# scan's snapshot does not have their contents, so it cannot tell where
# links there lead.
swarm_retire_layer_links() {
    local id="$1" name="$2" report="$3" info="$4" snap="$5" tmp grc=0
    tmp=$(retire_tmpdir) || return 1
    grep -aE '^layer-(link|via|path) ' "$report" > "$tmp/links" 2>/dev/null \
        || grc=$?
    case "$grc" in
        0) ;;
        1) rm -rf "$tmp"; return 0 ;;
        *)
            echo "ERROR: cannot read the workspace scan of ${name}." >&2
            rm -rf "$tmp"
            return 1 ;;
    esac
    # Escaped names (a newline shows as \n) cannot be compared with
    # docker diff's paths.
    if grep -aq '[\]' "$tmp/links"; then
        echo "ERROR: ${name} has links out of its volume whose paths" \
             "cannot be compared; check them first:" >&2
        sed 's/^layer-[a-z]* /  /' "$tmp/links" >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! printf '%s' "$info" | jq -r '.[0] as $c
            | [($c.Mounts // [])[] | .Destination]
              + (($c.HostConfig.Tmpfs // {}) | keys)
              + ["/etc/hosts", "/etc/hostname", "/etc/resolv.conf",
             "/dev", "/proc", "/sys"]
            | unique | .[] | select(. != "/workspace")' > "$tmp/mounts"; then
        echo "ERROR: cannot read the mounts of ${name}." >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! awk 'NR == FNR { m[$0] = 1; next }
         {
             p = $0; sub(/^layer-(link|via|path) /, "", p)
             for (x in m)
                 if (p == x || index(p, x "/") == 1) print p " (mount " x ")"
         }' "$tmp/mounts" "$tmp/links" > "$tmp/mhits"; then
        echo "ERROR: cannot compare the links of ${name} with its mounts." >&2
        rm -rf "$tmp"
        return 1
    fi
    if [ -s "$tmp/mhits" ]; then
        echo "ERROR: ${name} has links out of its volume into its other" \
             "mounts, which the scan cannot follow:" >&2
        sed 's/^/  /' "$tmp/mhits" >&2
        rm -rf "$tmp"
        return 1
    fi
    # docker diff comes through JSON, which replaces bytes that are not
    # valid UTF-8; such a path cannot be compared exactly.
    if ! command -v iconv >/dev/null 2>&1; then
        echo "ERROR: retire needs iconv to compare the links of ${name}" \
             "with what it changed." >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! iconv -f UTF-8 -t UTF-8 < "$tmp/links" > /dev/null 2>&1; then
        echo "ERROR: ${name} has links out of its volume whose paths are" \
             "not valid UTF-8, which docker diff cannot report exactly:" >&2
        sed 's/^layer-[a-z]* /  /' "$tmp/links" >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! swarm_retire_diff "$id" "$name" "$tmp/diff"; then
        rm -rf "$tmp"
        return 1
    fi
    # A layer-link target, or anything below it, that the container
    # added or changed; or a link on the way that it added or changed.
    # A layer-link target, or anything below it, that the container
    # added or changed; a link on the way (layer-via) that it added or
    # changed; or a directory on the way (layer-path) that it added.
    if ! awk 'NR == FNR {
             if (substr($0, 1, 11) == "layer-link ") t[substr($0, 12)] = 1
             if (substr($0, 1, 10) == "layer-via ") v[substr($0, 11)] = 1
             if (substr($0, 1, 11) == "layer-path ") w[substr($0, 12)] = 1
             next
         }
         ($1 == "A" || $1 == "C") {
             p = substr($0, 3)
             for (x in t)
                 if (x == "/" || p == x || index(p, x "/") == 1)
                     print x " (" $0 ")"
             if (p in v) print p " (" $0 ")"
             if ($1 == "A" && (p in w)) print p " (" $0 ")"
         }' "$tmp/links" "$tmp/diff" > "$tmp/hits.raw" \
            || ! sort -u "$tmp/hits.raw" > "$tmp/hits"; then
        echo "ERROR: cannot compare the links of ${name} with what it" \
             "changed." >&2
        rm -rf "$tmp"
        return 1
    fi
    if [ -s "$tmp/hits" ]; then
        echo "ERROR: ${name} has links out of its volume to data in the" \
             "container:" >&2
        sed 's/^/  /' "$tmp/hits" >&2
        echo "  Copy it out with docker cp ${id}:<path> <dir> first." >&2
        rm -rf "$tmp"
        return 1
    fi
    # docker diff goes by metadata: a file whose content changed with its
    # size, mode and times kept does not show.  The link targets and the
    # links on the way must read the same in the snapshot as in the
    # image the container was made from.
    if ! swarm_retire_same_as_image "$name" "$snap" \
            "$(printf '%s' "$info" | jq -r '.[0].Image // empty')" \
            "$tmp/links"; then
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
}

# Fail unless every layer-link and layer-via path in file LINKS reads the
# same in image SNAP (the container's snapshot) as in image ORIG (its
# original image): a file by its content's SHA-256, a symlink by its
# target, anything else (or nothing) by its kind.
swarm_retire_same_as_image() {
    local name="$1" snap="$2" orig="$3" links="$4" tmp img rc
    case "$orig" in
        sha256:*) ;;
        *)
            echo "ERROR: cannot tell the image of ${name}." >&2
            return 1 ;;
    esac
    tmp=$(retire_tmpdir) || return 1
    if ! sed -n -e 's/^layer-link //p' -e 's/^layer-via //p' "$links" \
            > "$tmp/paths"; then
        echo "ERROR: cannot list the links of ${name} to compare." >&2
        rm -rf "$tmp"
        return 1
    fi
    if [ ! -s "$tmp/paths" ]; then
        rm -rf "$tmp"
        return 0
    fi
    for img in "$snap" "$orig"; do
        rc=0
        swarm_docker_own_group run --rm -i --pull never --network none \
            --user 0 --label "${RETIRE_HELPER_LABEL}=${PROJECT}" \
            --entrypoint bash "$img" -c '
                # swarm-compare: one line per path read on stdin
                while IFS= read -r p; do
                    if [ -L "$p" ]; then
                        printf "%s\tl\t%s\n" "$p" "$(readlink -n "$p")"
                    elif [ -f "$p" ]; then
                        h=$(sha256sum < "$p") || exit 3
                        printf "%s\tf\t%s\n" "$p" "${h%% *}"
                    elif [ -e "$p" ]; then
                        printf "%s\to\t-\n" "$p"
                    else
                        printf "%s\t-\t-\n" "$p"
                    fi
                done
            ' < "$tmp/paths" > "$tmp/out.${img#sha256:}" 2>"$tmp/err" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: cannot compare the links of ${name} with its" \
                 "image: $(cat "$tmp/err")" >&2
            rm -rf "$tmp"
            return 1
        fi
    done
    if ! cmp -s "$tmp/out.${snap#sha256:}" "$tmp/out.${orig#sha256:}"; then
        echo "ERROR: ${name} has links out of its volume to files it" \
             "changed:" >&2
        diff "$tmp/out.${orig#sha256:}" "$tmp/out.${snap#sha256:}" \
            | sed -n 's/^> /  /p' >&2
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
}

# Fail when the git config that container ID's processes read (global
# and system) sets what puts repository data outside its volume,
# includes other files, or cannot be checked.  Git environment variables
# other than the engine's own (GIT_USER_NAME, GIT_USER_EMAIL) can
# redirect any of this, so they refuse; so do HOME and XDG_CONFIG_HOME
# values that are empty, relative, unnormalized or hold a newline.  The
# files are then found and read inside snapshot SNAP, as the container's
# user with its HOME and XDG_CONFIG_HOME (Docker derives HOME from that
# user's passwd entry when it is not set), with every path resolved
# through the container's own links; a file on one of the container's
# mounts (MOUNTS) or Docker's own (/dev, /proc, /sys, ...) refuses, since
# the snapshot lacks those contents.
swarm_retire_config_check() {
    local id="$1" name="$2" snap="$3" mounts="$4" env bad user tmp rc=0
    local args=()
    env=$(docker container inspect -f '{{json .Config.Env}}' "$id" \
        2>/dev/null) || {
        echo "ERROR: cannot read the environment of ${name}." >&2
        return 1
    }
    # BASH_ENV and ENV make every bash in the container run a file
    # first, which can set any of these.
    bad=$(printf '%s' "$env" | jq -r '.[]? | split("=")[0]
        | select((startswith("GIT_") and . != "GIT_USER_NAME"
            and . != "GIT_USER_EMAIL") or . == "BASH_ENV" or . == "ENV")') \
        || bad="unreadable"
    if [ -n "$bad" ]; then
        echo "ERROR: ${name} sets Git environment variables that can" \
             "move repository data or config: ${bad//$'\n'/ }" >&2
        return 1
    fi
    if ! bad=$(printf '%s' "$env" | jq -r '.[]?
            | select(startswith("HOME=") or startswith("XDG_CONFIG_HOME="))
            | select((split("=")[1:] | join("=")) as $v
                | (startswith("HOME=") and $v == "")
                  or ($v != "" and (($v | startswith("/") | not)
                    or ($v | test("(^|/)[.][.]?(/|$)"))
                    or ($v | contains("//"))
                    or ($v | test("[\u0000-\u001f\u007f]")))))
            | split("=")[0]'); then
        echo "ERROR: cannot read the environment of ${name}." >&2
        return 1
    fi
    if [ -n "$bad" ]; then
        echo "ERROR: ${name} sets ${bad//$'\n'/ and } to an empty," \
             "relative or unnormalized path; its git config cannot be" \
             "located." >&2
        return 1
    fi
    user=$(docker container inspect -f '{{.Config.User}}' "$id" \
        2>/dev/null) || {
        echo "ERROR: cannot read the user of ${name}." >&2
        return 1
    }
    [ -z "$user" ] || args+=(--user "$user")
    while IFS= read -r e; do
        [ -n "$e" ] && args+=(-e "$e")
    done < <(printf '%s' "$env" | jq -r '.[]?
        | select(startswith("HOME=") or startswith("XDG_CONFIG_HOME="))')
    tmp=$(retire_tmpdir) || return 1
    swarm_docker_own_group run --rm -i --pull never --network none \
        --label "${RETIRE_HELPER_LABEL}=${PROJECT}" \
        "${args[@]+"${args[@]}"}" -e "SWARM_SCAN_MOUNTS=${mounts}" \
        --entrypoint bash "$snap" -c '
            d=$(mktemp -d) || exit 3
            cat > "$d/scan.sh" || exit 3
            mkdir "$d/out" || exit 3
            bash "$d/scan.sh" userconfig - - "$d/out" >&2 || exit $?
            cat "$d/out/report"
        ' < "$(dirname "${BASH_SOURCE[0]}")/preserve-scan.sh" \
        > "$tmp/report" 2>"$tmp/err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: cannot check the git config of ${name}:" \
             "$(cat "$tmp/err")" >&2
        rm -rf "$tmp"
        return 1
    fi
    rc=0
    grep -a '^block ' "$tmp/report" > "$tmp/blocks" 2>/dev/null || rc=$?
    case "$rc" in
        0)
            echo "ERROR: the git config of ${name} keeps repository data" \
                 "outside its workspace, or cannot be checked:" >&2
            sed 's/^block /  /' "$tmp/blocks" >&2
            rm -rf "$tmp"
            return 1 ;;
        1) ;;
        *)
            echo "ERROR: cannot read the git config check of ${name}." >&2
            rm -rf "$tmp"
            return 1 ;;
    esac
    rm -rf "$tmp"
}

cmd_retire() {
    local rc=0
    RETIRE_SCRATCH=""
    RETIRE_SNAP_REF=""
    # The traps come first, so that nothing retire makes is ever
    # outside them.  Once a signal starts the cleanup, further ones wait
    # for it.
    trap retire_cleanup EXIT
    trap 'trap "" HUP INT TERM; retire_cleanup; trap - EXIT; exit 129' HUP
    trap 'trap "" HUP INT TERM; retire_cleanup; trap - EXIT; exit 130' INT
    trap 'trap "" HUP INT TERM; retire_cleanup; trap - EXIT; exit 143' TERM
    if RETIRE_SCRATCH=$(retire_tmpdir); then
        retire_run "$@" || rc=$?
    else
        rc=1
    fi
    retire_cleanup
    trap - EXIT HUP INT TERM
    return "$rc"
}

# The retire command itself; cmd_retire runs it with cleanup in place.
retire_run() {
    local only_post=false
    # Reports and docker output are compared byte by byte: in a UTF-8
    # locale GNU grep would drop lines holding invalid UTF-8.
    LC_ALL=C
    export LC_ALL
    while [ $# -gt 0 ]; do
        case "$1" in
            --post-process) only_post=true; shift ;;
            -h|--help)
                cat <<HELP
Usage: $0 retire [--post-process]

Remove this checkout's stopped engine containers (or only the
post-process container) after checking that nothing lives only in
them.  Their workspace volumes stay (./launch.sh cleanup deletes them
after its own checks).  Run costs.sh first if you need the containers'
stats.
HELP
                return 0 ;;
            *) echo "ERROR: unknown retire option: $1" >&2; return 1 ;;
        esac
    done
    if [ ! -f "$STATE_FILE" ]; then
        echo "ERROR: no engagement in ${RUNTIME_DIR}; nothing to retire." >&2
        return 1
    fi
    swarm_lock "$RUNTIME_DIR" || return 1
    # Checked before the lock too, but another checkout of this project
    # id could have claimed the runtime and started in between.
    swarm_runtime_verify "$RUNTIME_DIR" "$REPO_ROOT" "$PROJECT" || return 1
    swarm_engagement_join "$STATE_FILE" || return 1
    retire_require_daemon || return 1
    retire_sweep_snapshots || return 1

    local list sel checked id name
    list=$(swarm_own_containers "$PROJECT" "$REPO_ROOT") || {
        echo "ERROR: cannot list Docker containers." >&2
        return 1
    }
    sel=$(printf '%s\n' "$list" | while read -r name id; do
        [ -n "$name" ] || continue
        if [ "$only_post" = true ] && [ "$name" != "${IMAGE_NAME}-post" ]; then
            continue
        fi
        printf '%s %s\n' "$id" "$name"
    done)
    if [ -z "$sel" ]; then
        echo "No containers to retire."
        return 0
    fi
    # Check every container before removing any.  The list comes on
    # descriptor 3 and the checks get no standard input, so none of them
    # can eat the rest of it; and every selected container must have
    # been checked.
    checked=$(retire_tmpdir) || return 1
    checked="$checked/checked"
    : > "$checked"
    while read -r -u 3 id name; do
        if ! swarm_retire_preflight "$id" "$name" >> "$checked"; then
            echo "Nothing was removed." >&2
            return 1
        fi
    done 3<<EOF < /dev/null
$sel
EOF
    local nsel nchecked
    nsel=$(printf '%s\n' "$sel" | grep -c . || true)
    nchecked=$(grep -c . "$checked" || true)
    if [ "$nsel" != "$nchecked" ]; then
        echo "ERROR: not every container was checked. Nothing was" \
             "removed." >&2
        return 1
    fi
    # Remove by ID, each only if nothing about it changed since.
    local vol started finished now failed=0
    while read -r -u 3 id name vol started finished; do
        now=$(docker container inspect -f \
            '{{.State.Status}} {{.State.StartedAt}} {{.State.FinishedAt}}' \
            "$id" 2>/dev/null) || now=""
        case "$now" in
            "exited $started $finished"|"created $started $finished") ;;
            *)
                echo "ERROR: ${name} changed since it was checked; left" \
                     "in place." >&2
                failed=1
                continue ;;
        esac
        if docker rm "$id" >/dev/null 2>&1; then
            echo "  retired ${name} (workspace volume ${vol} kept)"
        else
            echo "ERROR: docker rm ${name} failed; left in place." >&2
            failed=1
        fi
    done 3< "$checked" < /dev/null
    echo "Workspace volumes stay, with the files of the removed containers;" \
         "./launch.sh cleanup deletes them after its checks."
    return "$failed"
}

# Stop unless Docker talks to the daemon the engagement recorded.  An
# engagement without a recorded daemon is refused: retire acts on
# containers by ID and must know they are the engagement's.
retire_require_daemon() {
    local recorded current
    recorded=$(swarm_state_read "$STATE_FILE" 2>/dev/null \
        | jq -r '.docker_daemon // empty' 2>/dev/null) || recorded=""
    if [ -z "$recorded" ]; then
        if [ -z "${SWARM_DOCKER_DAEMON:-}" ]; then
            echo "ERROR: ${STATE_FILE} records no Docker daemon. Name the" \
                 "one this engagement runs on:" >&2
            echo "  SWARM_DOCKER_DAEMON=\$(docker info -f '{{.ID}}')" \
                 "./launch.sh retire" >&2
            return 1
        fi
        recorded="$SWARM_DOCKER_DAEMON"
    fi
    if ! swarm_docker_pin || ! current=$(swarm_docker_daemon_id); then
        echo "ERROR: cannot read the Docker daemon id." >&2
        return 1
    fi
    if [ "$current" != "$recorded" ]; then
        echo "ERROR: this engagement runs on Docker daemon ${recorded}," \
             "but Docker now talks to ${current}." >&2
        return 1
    fi
}
