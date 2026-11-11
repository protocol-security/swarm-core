#!/bin/bash
# launch.sh cleanup: delete this checkout's engagement (its workspace
# volumes, the bare repo, the mirrors, and the engagement's records)
# without losing anything Git kept there.  Every repository location
# about to go is first copied into the checkout as recovery refs
#   refs/swarm-recovery/e<engagement, hex>/<snapshot>/s<n>/...
# (with a "sources" blob that names each s<n>), and verified there.
# Every run, first or resumed, checks everything again and preserves
# what is still there under a new snapshot; a checkpoint in the state
# file records what each run preserved, so a run that stops half way
# is finished by the next one, and other commands wait until it is.
#
# Sourced by launch.sh after lib/project.sh, lib/preserve.sh and
# lib/retire.sh; uses PROJECT, REPO_ROOT, CHECKOUT_PATH, RUNTIME_DIR,
# STATE_FILE, BARE_REPO, MIRROR_DIR and IMAGE_NAME.

CLEANUP_DISCARD=false
CLEANUP_ALLOW_UNHARVESTED=false
CLEANUP_HELPER_LABEL="swarm-core.cleanup"

# Print STRING as lowercase hex (swarm_recovery_hex).
cleanup_hex() {
    swarm_recovery_hex "$1"
}

# Print the cleanup checkpoint of the state file as JSON (null when
# there is none).
cleanup_checkpoint() {
    swarm_state_read "$STATE_FILE" | jq -c '.cleanup // null'
}

# Print the sha256 of the "<ref> <oid>" lines under PREFIX/ in the
# checkout, sorted: the evidence that what a run preserved is still
# there, ref for ref.
cleanup_inventory() {
    local prefix="$1" list
    list=$(swarm_recovery_git -C "$REPO_ROOT" for-each-ref \
        --format='%(refname) %(objectname)' "$prefix/" 2>/dev/null) \
        || return 1
    printf '%s\n' "$list" | LC_ALL=C sort | swarm_sha256
}

# sha256 of standard input, hex only.
swarm_sha256() {
    local h
    if command -v sha256sum >/dev/null 2>&1; then
        h=$(sha256sum) || return 1
    else
        h=$(shasum -a 256) || return 1
    fi
    printf '%s\n' "${h%% *}"
}

# Print the number of lines of FILE; fails when it cannot be read.  A
# read that fails ends a while-read loop like the end of its list, so
# every loop over a list cleanup acts on compares its count with this.
cleanup_lines() {
    local count
    count=$(wc -l < "$1") || return 1
    printf '%s' "$((count + 0))"
}

# Succeed when the runtime directory is safe to delete things in (the
# rules every lifecycle command applies to it; see
# swarm_runtime_location_ok).
cleanup_runtime_sane() {
    swarm_runtime_location_ok "$RUNTIME_DIR" "$REPO_ROOT"
}

# Wait for, then remove, the helper containers a killed cleanup of this
# project left (they carry the cleanup label), for at most
# SWARM_CLEANUP_HELPER_WAIT seconds (default 900) each.  Nothing is
# inspected before they are gone, and only a listing that works and
# shows none counts as gone.
cleanup_settle_helpers() {
    local ids c st waited limit="${SWARM_CLEANUP_HELPER_WAIT:-900}"
    case "$limit" in
        ''|*[!0-9]*) limit=900 ;;
    esac
    if ! ids=$(docker ps -aq --filter \
            "label=${CLEANUP_HELPER_LABEL}=${PROJECT}" 2>/dev/null); then
        echo "ERROR: cannot list Docker containers." >&2
        return 1
    fi
    for c in $ids; do
        echo "Waiting for ${c}, a helper an earlier cleanup left..."
        waited=0
        while :; do
            if ! st=$(docker container inspect -f '{{.State.Status}}' "$c" \
                    2>/dev/null); then
                # Gone already, or Docker cannot say: the listing below
                # decides.
                break
            fi
            case "$st" in
                exited|created|dead) break ;;
            esac
            if [ "$waited" -ge "$limit" ]; then
                echo "ERROR: the helper container ${c} is still ${st}" \
                     "after ${limit}s; stop it (docker stop ${c}) and run" \
                     "cleanup again." >&2
                return 1
            fi
            sleep 1
            waited=$((waited + 1))
        done
        docker rm "$c" >/dev/null 2>&1 || true
    done
    if ! ids=$(docker ps -aq --filter \
            "label=${CLEANUP_HELPER_LABEL}=${PROJECT}" 2>/dev/null); then
        echo "ERROR: cannot list Docker containers." >&2
        return 1
    fi
    if [ -n "$ids" ]; then
        echo "ERROR: helper containers an earlier cleanup left remain:" \
             "$(printf '%s' "$ids" | tr '\n' ' ')" >&2
        return 1
    fi
}

# Fail when an interactive session is pending or open: its launch can
# run after the lock is released, and would use what cleanup deletes.
cleanup_no_pending() {
    local live
    live=$(swarm_pending_live "$RUNTIME_DIR") || return 1
    if [ -n "$live" ]; then
        echo "ERROR: interactive sessions are open or starting:" >&2
        printf '%s\n' "$live" | sed 's/^/  /' >&2
        echo "  End them first." >&2
        return 1
    fi
}

# Fail, naming them, while containers of this checkout run (or are
# paused or restarting), or Docker cannot say they do not: their
# workspaces still change, so the scans would judge them too early, and
# retire refuses them anyway.  Stopping the agents is the step to take,
# not dropping what a scan finds.
cleanup_none_running() {
    local list line name id st live="" IFS
    list=$(swarm_own_containers "$PROJECT" "$REPO_ROOT") || {
        echo "ERROR: cannot list Docker containers." >&2
        return 1
    }
    # "<name> <id>" lines; no read loop over a here-string (see
    # wait_count in launch.sh).  Names and ids hold no glob characters.
    IFS=$'\n'
    for line in $list; do
        name="${line%% *}"
        id="${line#* }"
        if ! st=$(docker container inspect "$id" 2>/dev/null \
                | jq -r '.[0].State.Status // empty' 2>/dev/null); then
            # One gone since the listing is no longer in the way; one
            # Docker cannot describe might still run.
            swarm_container_gone "$id" && continue
            st=""
        fi
        case "$st" in
            exited|created|dead) ;;
            *) live="${live}  ${name} (${st:-state unknown})"$'\n' ;;
        esac
    done
    if [ -n "$live" ]; then
        echo "ERROR: containers of this engagement still run, or Docker" \
             "cannot tell; stop them first (./launch.sh stop):" >&2
        printf '%s' "$live" >&2
        return 1
    fi
}

# Fail unless every snapshot the checkpoint records is still intact in
# the checkout: each source's "<ref> <oid>" list and each run's sources
# blob, from the first run on.  A remnant deleted part of the way can
# no longer give back what is gone, so its earlier snapshot must hold.
cleanup_check_evidence() {
    local cp tmp kind prefix want got seen=0 total
    cp=$(cleanup_checkpoint) || return 1
    [ "$cp" != null ] || return 0
    tmp=$(retire_tmpdir) || return 1
    printf '%s' "$cp" | jq -r '.runs[]? as $r
        | ($r.sources[]? | select(.inventory != null)
           | "src\t\(.prefix)\t\(.inventory)"),
          "map\t\($r.sources_ref)\t\($r.sources_oid)",
          (if $r.manifest_ref == null then empty
           else "map\t\($r.manifest_ref)\t\($r.manifest_oid)" end)' \
        > "$tmp/evidence" || return 1
    while IFS="$(printf '\t')" read -r -u 3 kind prefix want; do
        seen=$((seen + 1))
        case "$kind" in
            src)
                got=$(cleanup_inventory "$prefix") || got="" ;;
            map)
                got=$(swarm_recovery_git -C "$REPO_ROOT" rev-parse \
                    --verify --quiet "$prefix" 2>/dev/null) || got="" ;;
            *) got="" ;;
        esac
        if [ -z "$got" ] || [ "$got" != "$want" ]; then
            echo "ERROR: recovery refs an earlier cleanup wrote changed or" \
                 "went: ${prefix}." >&2
            echo "  Cleanup will not delete what they no longer keep." \
                 "Restore them, or see USAGE (CLEANUP) for the manual" \
                 "steps." >&2
            return 1
        fi
    done 3< "$tmp/evidence" < /dev/null || return 1
    total=$(cleanup_lines "$tmp/evidence") || return 1
    if [ "$seen" -ne "$total" ]; then
        echo "ERROR: cannot read the recovery records of an earlier" \
             "cleanup." >&2
        return 1
    fi
}

# The target snapshot, RUNTIME_DIR/target.git, is a copy of the audit
# target that start made; nothing of the engagement's work is in it.
# Cleanup deletes it without preserving it, with a record of its own in
# the checkpoint (.cleanup.target), and resumes from what is on disk.

# Fail unless what is at PATH (the target snapshot or its remnant, both
# named directly in the runtime directory) can be deleted safely: a
# directory, not a link, this user's, nothing mounted at or under it.
# Whether it is a valid snapshot does not matter.
cleanup_target_safe() {
    local path="$1"
    if [ -L "$path" ]; then
        echo "ERROR: ${path} is a link; cleanup will not follow it." >&2
        return 1
    fi
    if [ ! -d "$path" ]; then
        echo "ERROR: ${path} is not a directory." >&2
        return 1
    fi
    if [ ! -O "$path" ]; then
        echo "ERROR: ${path} is not this user's; cleanup leaves it." >&2
        return 1
    fi
    swarm_no_mounts "$path" at
}

# Check what is there of the target snapshot (the first pass, before
# anything is retired or deleted, and again after retire): both names at
# once refuse, and each one there must be safe to delete.
cleanup_target_check() {
    local t="$RUNTIME_DIR/target.git" r="$RUNTIME_DIR/target.git.removing"
    if { [ -e "$t" ] || [ -L "$t" ]; } && { [ -e "$r" ] || [ -L "$r" ]; }
    then
        echo "ERROR: both ${t} and ${r} exist; cleanup will not rename one" \
             "into the other.  Move one out first." >&2
        return 1
    fi
    if [ -e "$t" ] || [ -L "$t" ]; then
        cleanup_target_safe "$t" || return 1
    fi
    if [ -e "$r" ] || [ -L "$r" ]; then
        cleanup_target_safe "$r" || return 1
    fi
}

# Record step STATE of the target snapshot's deletion in the checkpoint.
cleanup_target_record() {
    swarm_state_update "$STATE_FILE" \
        '.cleanup.target = {state: $s, at: $at}' --arg s "$1" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || {
        echo "ERROR: cannot record the target snapshot's deletion in" \
             "${STATE_FILE}." >&2
        return 1
    }
}

# Delete the target snapshot: "removing" recorded before it is renamed
# to target.git.removing, "renamed", "deleting", then "deleted" once it
# is gone.  A run that stopped resumes from the disk: target.git there
# is renamed, target.git.removing there is deleted.  Each step checks
# again that it is safe.
cleanup_target_remove() {
    local t="$RUNTIME_DIR/target.git" r="$RUNTIME_DIR/target.git.removing"
    cleanup_target_check || return 1
    if [ -e "$t" ] || [ -L "$t" ]; then
        cleanup_target_record removing || return 1
        cleanup_target_safe "$t" || return 1
        if [ -e "$r" ] || [ -L "$r" ]; then
            echo "ERROR: ${r} exists; cleanup will not rename into it." >&2
            return 1
        fi
        mv "$t" "$r" || {
            echo "ERROR: cannot rename ${t}." >&2
            return 1
        }
        cleanup_target_record renamed || return 1
    fi
    if [ -e "$r" ] || [ -L "$r" ]; then
        cleanup_target_record deleting || return 1
        cleanup_target_safe "$r" || return 1
        chmod -R u+rwX "$r" 2>/dev/null || true
        rm -rf "$r" 2>/dev/null || true
        if [ -e "$r" ] || [ -L "$r" ]; then
            echo "ERROR: cannot delete ${r} (files this user cannot" \
                 "remove?)." >&2
            return 1
        fi
        cleanup_target_record deleted || return 1
        echo "  deleted ${t}"
    fi
}

# Write the sources cleanup will delete to FILE, one per line:
#   <kind>\t<path or volume>
# kind: removing, mirror, new, bare, volume.  Remnants (*.removing)
# come first and are recognised before mirrors/ is checked: a mirror
# deleted part of the way is no longer a repository.  Anything else in
# mirrors/ refuses, since nothing would preserve it.
cleanup_sources() {
    local out="$1" e name base vols v rest odd=""
    # Every write is checked: a location left out of this list would be
    # neither preserved nor deleted.
    : > "$out" || return 1
    # Hidden names too: a submodule's mirror can start with a dot.
    for e in "$RUNTIME_DIR"/*.removing "$RUNTIME_DIR"/.[!.]*.removing \
            "$RUNTIME_DIR"/..?*.removing "$MIRROR_DIR"/*.removing \
            "$MIRROR_DIR"/.[!.]*.removing "$MIRROR_DIR"/..?*.removing; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        # The target snapshot's remnant is cleanup_target_remove's: a
        # copy of the target, never a preserved source.
        [ "$e" != "$RUNTIME_DIR/target.git.removing" ] || continue
        case "$e" in
            *$'\t'*|*$'\n'*) odd="${odd}  ${e}"$'\n'; continue ;;
        esac
        if [ -L "$e" ]; then
            echo "ERROR: ${e} is a link; cleanup will not follow it." >&2
            return 1
        fi
        printf 'removing\t%s\n' "$e" >> "$out" || return 1
    done
    if [ -e "$MIRROR_DIR" ] || [ -L "$MIRROR_DIR" ]; then
        if [ -L "$MIRROR_DIR" ] || [ ! -d "$MIRROR_DIR" ]; then
            echo "ERROR: ${MIRROR_DIR} is not a directory." >&2
            return 1
        fi
        rest=""
        for e in "$MIRROR_DIR"/* "$MIRROR_DIR"/.[!.]* "$MIRROR_DIR"/..?*; do
            [ -e "$e" ] || [ -L "$e" ] || continue
            name="${e##*/}"
            case "$name" in
                *.removing) continue ;;
                *$'\t'*|*$'\n'*) odd="${odd}  ${e}"$'\n'; continue ;;
                manifest.json|manifest.json.new)
                    # The mirrors' list (lib/mirrors.sh), not a source:
                    # cleanup_run keeps it under a recovery ref and
                    # deletes it after the mirrors.  Only a file.
                    if [ -L "$e" ] || [ ! -f "$e" ]; then
                        rest="${rest}  ${e}"$'\n'
                    fi
                    continue ;;
                *.new)
                    # A mirror cut off while it was made.
                    if [ -L "$e" ]; then
                        echo "ERROR: ${e} is a link; cleanup will not" \
                             "follow it." >&2
                        return 1
                    fi
                    printf 'new\t%s\n' "$e" >> "$out" || return 1
                    continue ;;
            esac
            if [ ! -L "$e" ] && [ -d "$e" ] && [ -f "$e/HEAD" ] \
                    && { [ -d "$e/objects" ] || [ -f "$e/commondir" ]; }; then
                printf 'mirror\t%s\n' "$e" >> "$out" || return 1
            else
                rest="${rest}  ${e}"$'\n'
            fi
        done
        if [ -n "$rest" ]; then
            echo "ERROR: ${MIRROR_DIR} holds what is not a mirror, and" \
                 "cleanup would delete it unpreserved:" >&2
            printf '%s' "$rest" >&2
            echo "  Move it out first." >&2
            return 1
        fi
    fi
    if [ -n "$odd" ]; then
        echo "ERROR: names with a tab or a newline, which cleanup's lists" \
             "cannot carry:" >&2
        printf '%s' "$odd" >&2
        echo "  Rename them first." >&2
        return 1
    fi
    for base in "${BARE_REPO}.new" "$BARE_REPO"; do
        [ -e "$base" ] || [ -L "$base" ] || continue
        if [ "$base" = "$BARE_REPO" ]; then
            printf 'bare\t%s\n' "$base" >> "$out" || return 1
        else
            printf 'new\t%s\n' "$base" >> "$out" || return 1
        fi
    done
    if ! vols=$(docker volume ls -q \
            --filter "label=${SWARM_PROJECT_LABEL}=${PROJECT}" \
            --filter "label=${SWARM_CHECKOUT_LABEL}=${CHECKOUT_PATH}" \
            2>/dev/null); then
        echo "ERROR: cannot list Docker volumes." >&2
        return 1
    fi
    for v in $vols; do
        printf 'volume\t%s\n' "$v" >> "$out" || return 1
    done
}

# Print the Mountpoint of volume NAME.
cleanup_volume_mountpoint() {
    docker volume inspect -f '{{.Mountpoint}}' "$1" 2>/dev/null
}

# Succeed when volume NAME is this checkout's (labels) and no container
# uses it.
cleanup_volume_free() {
    local name="$1" labels users
    labels=$(docker volume inspect -f '{{json .Labels}}' "$name" \
        2>/dev/null) || {
        echo "ERROR: cannot inspect volume ${name}." >&2
        return 1
    }
    if ! printf '%s' "$labels" | jq -e \
            --arg pk "$SWARM_PROJECT_LABEL" --arg p "$PROJECT" \
            --arg ck "$SWARM_CHECKOUT_LABEL" --arg c "$CHECKOUT_PATH" \
            '.[$pk] == $p and .[$ck] == $c' >/dev/null 2>&1; then
        echo "ERROR: volume ${name} is not this checkout's." >&2
        return 1
    fi
    if ! users=$(docker ps -aq --filter "volume=${name}" 2>/dev/null); then
        echo "ERROR: cannot list Docker containers." >&2
        return 1
    fi
    if [ -n "$users" ]; then
        echo "ERROR: volume ${name} is in use by containers:" \
             "$(printf '%s' "$users" | tr '\n' ' ')" >&2
        return 1
    fi
}

# Scan source KIND at PATH (a volume name for kind volume) into the
# empty directory OUT; for a remnant, gitdir mode first and files mode
# when it is no longer a git dir or that scan fails.  Prints the mode
# used.
cleanup_scan() {
    local kind="$1" path="$2" out="$3" format context tag
    case "$kind" in
        volume)
            context=$(docker volume inspect -f \
                "{{index .Labels \"${SWARM_CONTEXT_LABEL}\"}}" "$path" \
                2>/dev/null) || context=""
            tag=$(cleanup_hex "$path" | cut -c1-24) || return 1
            # shellcheck disable=SC2034  # read by swarm_scan_volume
            SWARM_SCAN_DOCKER_ARGS=(--name "${PROJECT}-cleanup-scan-${tag}-$$"
                --label "${CLEANUP_HELPER_LABEL}=${PROJECT}")
            if swarm_scan_volume "$path" "$IMAGE_NAME" "${context:-full}" \
                    "$out" "" cleanup 2>"$out.err"; then
                # shellcheck disable=SC2034
                SWARM_SCAN_DOCKER_ARGS=()
                echo volume
                return 0
            fi
            # shellcheck disable=SC2034
            SWARM_SCAN_DOCKER_ARGS=()
            sed 's/^/  /' "$out.err" >&2
            return 1 ;;
        removing|new)
            if [ -f "$path/HEAD" ] \
                    && { [ -d "$path/objects" ] \
                         || [ -f "$path/commondir" ]; } \
                    && swarm_scan_host "$path" "$out" 2>"$out.err"; then
                echo gitdir
                return 0
            fi
            # What is left of a repository a deletion got part of the way
            # through: keep every file.
            rm -rf "$out"
            mkdir "$out" || return 1
            format=$(swarm_recovery_git -C "$REPO_ROOT" rev-parse \
                --show-object-format 2>/dev/null) || return 1
            if bash "$(dirname "${BASH_SOURCE[0]}")/preserve-scan.sh" \
                    files "$path" "$format" "$out" 2>"$out.err"; then
                echo files
                return 0
            fi
            sed 's/^/  /' "$out.err" >&2
            return 1 ;;
        *)
            if swarm_scan_host "$path" "$out" 2>"$out.err"; then
                echo gitdir
                return 0
            fi
            sed 's/^/  /' "$out.err" >&2
            return 1 ;;
    esac
}

# Retire every container (retire_run), which first keeps the Git
# checkouts in their layers; --discard-uncommitted goes on to it, to drop
# what it lists there too.
cleanup_retire() {
    if [ "$CLEANUP_DISCARD" = true ]; then
        retire_run --discard-uncommitted
    else
        retire_run
    fi
}

# Apply the policy to scan report REPORT of SOURCE: block lines refuse;
# layer-uncommitted lines refuse too (cleanup's scans see no container
# layer, so one means the scan is not what it should be); uncommitted
# lines refuse unless --discard-uncommitted, which lists them.  Fails
# when the source may not be deleted.
cleanup_policy() {
    local report="$1" source="$2" rc=0
    grep -a '^layer-uncommitted ' "$report" > "$report.lunc" 2>/dev/null \
        || rc=$?
    case "$rc" in
        0)
            echo "ERROR: the scan of ${source} reports work in a container" \
                 "layer, which cleanup's scans cannot see:" >&2
            sed 's/^layer-uncommitted /  /' "$report.lunc" >&2
            return 1 ;;
        1) ;;
        *)
            echo "ERROR: cannot read the scan of ${source}." >&2
            return 1 ;;
    esac
    rc=0
    grep -a '^block ' "$report" > "$report.block" 2>/dev/null || rc=$?
    case "$rc" in
        0)
            echo "ERROR: ${source} holds what cleanup cannot keep:" >&2
            sed 's/^block /  /' "$report.block" >&2
            return 1 ;;
        1) ;;
        *)
            echo "ERROR: cannot read the scan of ${source}." >&2
            return 1 ;;
    esac
    rc=0
    grep -a '^uncommitted ' "$report" > "$report.unc" 2>/dev/null || rc=$?
    case "$rc" in
        0)
            if [ "$CLEANUP_DISCARD" = true ]; then
                echo "Discarding, from ${source}:"
                sed 's/^uncommitted /  /' "$report.unc"
                return 0
            fi
            echo "ERROR: ${source} holds work outside Git's history:" >&2
            sed 's/^uncommitted /  /' "$report.unc" >&2
            echo "  Commit or copy it out, or run cleanup with" \
                 "--discard-uncommitted to drop exactly these." >&2
            return 1 ;;
        1) return 0 ;;
        *)
            echo "ERROR: cannot read the scan of ${source}." >&2
            return 1 ;;
    esac
}

# Record a change to source ID of the current run in the checkpoint:
# jq FILTER applied to that source object.  Fails unless the run holds
# exactly one record of ID.
cleanup_record() {
    local id="$1" filter="$2"
    shift 2
    swarm_state_update "$STATE_FILE" "
        if [.cleanup.runs[-1].sources[] | select(.id == \$sid)] | length != 1
        then error(\"no record of \" + \$sid)
        else (.cleanup.runs[-1].sources[] | select(.id == \$sid))
            |= (${filter})
        end" --arg sid "$id" "$@" || {
        echo "ERROR: cannot record source ${id} in ${STATE_FILE}." >&2
        return 1
    }
}

# Delete host source PATH (the source with ID): renamed to PATH.removing
# first (unless it already is a remnant), then removed, by this user
# where it can be and through a Docker helper as root for what the
# containers wrote; it must be gone at the end.
cleanup_delete_host() {
    local id="$1" path="$2" target token rel name rc=0 parent
    # Only what lies inside the runtime directory (or its mirrors/) is
    # ever renamed or deleted.
    parent=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P) || parent=""
    if [ "$parent" != "$(cd -P "$RUNTIME_DIR" && pwd -P)" ] \
            && [ "$parent" != "$(cd -P "$MIRROR_DIR" 2>/dev/null && pwd -P)" ]
    then
        echo "ERROR: ${path} is not in ${RUNTIME_DIR}; not deleting it." >&2
        return 1
    fi
    swarm_no_mounts "$RUNTIME_DIR" || return 1
    case "$path" in
        *.removing) target="$path" ;;
        *)
            target="${path}.removing"
            if [ -e "$target" ] || [ -L "$target" ]; then
                echo "ERROR: ${target} exists; cleanup will not rename into" \
                     "it." >&2
                return 1
            fi
            mv "$path" "$target" || {
                echo "ERROR: cannot rename ${path}." >&2
                return 1
            }
            cleanup_record "$id" '.renamed = $t | .state = "renamed"' \
                --arg t "$target" || return 1 ;;
    esac
    cleanup_record "$id" '.state = "deleting"' || return 1
    chmod -R u+rwX "$target" 2>/dev/null || true
    rm -rf "$target" 2>/dev/null || true
    if [ -e "$target" ] || [ -L "$target" ]; then
        # What this user cannot delete (files the containers wrote as
        # their own user) goes through Docker, as root.  A token written
        # here must be what the helper finds at the mounted path, or the
        # daemon sees another file system (a remote daemon) and nothing
        # is deleted.
        # The marker gets a name nobody can know beforehand and is made
        # only when nothing has that name (noclobber), so it cannot be
        # sent through a link someone left in the remnant.
        token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
        if [ -L "$target" ] || [ ! -d "$target" ] \
                || ! ( set -C; printf '%s\n' "$token" \
                    > "$target/.swarm-cleanup-$token" ); then
            echo "ERROR: cannot write into ${target}." >&2
            return 1
        fi
        rel="${target#"$RUNTIME_DIR"/}"
        name="${PROJECT}-cleanup-rm-${id}-$$"
        cleanup_record "$id" '.helper = $n' --arg n "$name" || return 1
        swarm_docker_own_group run --rm --pull never --network none \
            --user 0 --entrypoint sh --name "$name" \
            --label "${CLEANUP_HELPER_LABEL}=${PROJECT}" \
            --mount "type=bind,src=${RUNTIME_DIR},dst=/runtime" \
            "$IMAGE_NAME" -c '
                t="/runtime/$1"
                [ -f "$t/.swarm-cleanup-$2" ] \
                    && [ "$(cat "$t/.swarm-cleanup-$2")" = "$2" ] \
                    || { echo "not the same directory" >&2; exit 4; }
                # Nothing may be mounted at or under it here: Docker
                # binds a directory with the mounts below it, which the
                # daemon may see and this host not.  The table is read
                # whole, by a command whose failure counts (a read in a
                # loop would end at an error as at the end), and writes
                # a space as \040 and a backslash as \134.
                m=$(cat /proc/self/mountinfo) && [ -n "$m" ] \
                    || { echo "cannot read the mount table" >&2; exit 5; }
                e=$(printf "%s" "$t" | sed "s/\\\\/\\\\134/g; s/ /\\\\040/g")
                m=$(printf "%s\n" "$m" | while read -r _ _ _ _ p _; do
                        case "$p" in
                            ("$e"|"$e"/*) printf "%s\n" "$p" ;;
                        esac
                    done)
                [ -z "$m" ] \
                    || { echo "something is mounted in it: $m" >&2; exit 5; }
                rm -rf -- "$t"
            ' sh "$rel" "$token" < /dev/null > /dev/null \
            2>"$RETIRE_SCRATCH/rm.err" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: cannot delete ${target} through Docker:" \
                 "$(cat "$RETIRE_SCRATCH/rm.err")" >&2
            return 1
        fi
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
        echo "ERROR: ${target} is still there." >&2
        return 1
    fi
    cleanup_record "$id" '.state = "deleted"'
}

# Examine every location cleanup would delete, into directory OUT: the
# list (OUT/sources), the storage check, every scan (OUT/scan.<n>) with
# the policy applied, and the list of what was scanned (OUT/scanned,
# "<n>\t<kind>\t<path>\t<mode>").  With FREE set, a volume must also
# have no container left that uses it.  Sets CLEANUP_TOTAL to the
# number of locations.  Fails on any refusal, having changed nothing.
cleanup_examine() {
    local out="$1" free="${2:-}" sources targets=() kind path mp seen=0
    local total n=0 dir mode
    sources="$out/sources"
    cleanup_sources "$sources" || return 1

    # Storage: the checkout must keep what it gets by itself.
    swarm_no_mounts "$RUNTIME_DIR" || return 1
    cleanup_target_check || return 1
    while IFS="$(printf '\t')" read -r -u 3 kind path; do
        seen=$((seen + 1))
        if [ "$kind" = volume ]; then
            if [ -n "$free" ]; then
                cleanup_volume_free "$path" || return 1
            fi
            mp=$(cleanup_volume_mountpoint "$path") || {
                echo "ERROR: cannot inspect volume ${path}." >&2
                return 1
            }
            if [ -n "$mp" ]; then
                swarm_no_mounts "$mp" at || return 1
                targets+=("$mp")
            fi
        else
            targets+=("$path")
        fi
    done 3< "$sources" < /dev/null || return 1
    total=$(cleanup_lines "$sources") || return 1
    if [ "$seen" -ne "$total" ]; then
        echo "ERROR: checked the storage of ${seen} of the ${total}" \
             "locations to clean up." >&2
        return 1
    fi
    swarm_checkout_storage_ok "$REPO_ROOT" "$RUNTIME_DIR" \
        "${targets[@]+"${targets[@]}"}" || return 1

    # Scan every source and apply the policy before anything is copied.
    : > "$out/scanned" || return 1
    while IFS="$(printf '\t')" read -r -u 3 kind path; do
        n=$((n + 1))
        dir="$out/scan.$n"
        mkdir "$dir" || return 1
        mode=$(cleanup_scan "$kind" "$path" "$dir") || {
            echo "ERROR: cannot scan ${path}." >&2
            return 1
        }
        cleanup_policy "$dir/report" "$path" || return 1
        printf '%s\t%s\t%s\t%s\n' "$n" "$kind" "$path" "$mode" \
            >> "$out/scanned" || return 1
    done 3< "$sources" < /dev/null || return 1
    if [ "$n" -ne "$total" ]; then
        echo "ERROR: scanned ${n} of the ${total} locations to clean up." >&2
        return 1
    fi
    CLEANUP_TOTAL="$total"
}

# The cleanup command; cmd_cleanup runs it with retire's cleanup and
# traps in place.
cleanup_run() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --discard-uncommitted) CLEANUP_DISCARD=true; shift ;;
            --allow-unharvested) CLEANUP_ALLOW_UNHARVESTED=true; shift ;;
            -h|--help)
                cat <<HELP
Usage: $0 cleanup [--discard-uncommitted] [--allow-unharvested]

Delete this checkout's engagement: retire its containers, then copy
everything Git keeps in its workspace volumes, the bare repo and the
mirrors into the checkout as recovery refs (refs/swarm-recovery/...),
and delete them.  Work outside Git's history (uncommitted or ignored
files, files too large to copy) stops it, unless
--discard-uncommitted drops exactly what it lists.  So does agent work
in the bare repo that HEAD's history lacks, unless --allow-unharvested
keeps it as recovery refs only (after a rewritten upstream, say).  The
engagement lock and the runtime directory stay.
HELP
                return 0 ;;
            *) echo "ERROR: unknown cleanup option: $1" >&2; return 1 ;;
        esac
    done
    if [ ! -f "$STATE_FILE" ]; then
        echo "ERROR: no state file in ${RUNTIME_DIR}; cannot tell which" \
             "engagement to clean up." >&2
        return 1
    fi
    swarm_lock "$RUNTIME_DIR" || return 1
    # Checked before the lock too, but another checkout of this project
    # id could have claimed the runtime and started in between.
    swarm_runtime_verify "$RUNTIME_DIR" "$REPO_ROOT" "$PROJECT" || return 1
    swarm_engagement_join "$STATE_FILE" || return 1
    # A caller that names its engagement by token cleans up that one
    # only: another started since under the same id is not its to
    # delete, and with none recorded there is nothing of its left.
    swarm_engagement_token_check "$STATE_FILE" || return 1
    cleanup_runtime_sane || return 1
    # Scratch a target resolution left (never part of an engagement),
    # best effort.
    swarm_target_scratch_clean "$RUNTIME_DIR"
    local engagement
    engagement=$(swarm_engagement_recorded "$STATE_FILE") || return 1
    if [ -z "$engagement" ]; then
        # Nothing recorded: a cleaned-up runtime directory, unless
        # something of an engagement is left without one to file it
        # under (an earlier release's).
        swarm_unrecorded_refuse "$RUNTIME_DIR" "$PROJECT" "$REPO_ROOT" \
            "$CHECKOUT_PATH" || return 1
        echo "No engagement recorded in ${STATE_FILE}; nothing to clean up."
        return 0
    fi
    swarm_legacy_refuse "$RUNTIME_DIR" "$STATE_FILE" || return 1
    swarm_engagement_daemon_check "$STATE_FILE" || return 1
    cleanup_settle_helpers || return 1
    cleanup_no_pending || return 1
    cleanup_check_evidence || return 1

    # The bare repo's agent work must be in the checkout already
    # (harvest); recovery refs are the safety net, not the workflow.
    local rc=0
    if [ -d "$BARE_REPO" ]; then
        swarm_preservation_check "$BARE_REPO" "$REPO_ROOT" \
            > "$RETIRE_SCRATCH/e3" || rc=$?
        case "$rc" in
            0) ;;
            1)
                if [ "$CLEANUP_ALLOW_UNHARVESTED" = true ]; then
                    echo "Kept only as recovery refs (HEAD's history" \
                         "lacks them):"
                    sed 's/^/  /' "$RETIRE_SCRATCH/e3"
                else
                    swarm_preservation_explain "$BARE_REPO" \
                        < "$RETIRE_SCRATCH/e3"
                    echo "  Or, to keep that work only as recovery refs" \
                         "(after a rewritten upstream, say), run cleanup" \
                         "with --allow-unharvested." >&2
                    return 1
                fi ;;
            *) return 1 ;;
        esac
    fi

    # A first pass that only reads, while the stopped containers are
    # still there: a refusal here (work outside Git's history, storage)
    # leaves every container, its logs and its volume as they were.
    cleanup_none_running || return 1
    mkdir "$RETIRE_SCRATCH/first" || return 1
    cleanup_examine "$RETIRE_SCRATCH/first" || return 1

    # Every container goes next, through retire's checks.
    cleanup_retire || {
        echo "Cleanup stops: every container must be retired first." >&2
        return 1
    }
    local left
    left=$(swarm_own_containers "$PROJECT" "$REPO_ROOT") || return 1
    if [ -n "$left" ]; then
        echo "ERROR: containers of this checkout remain:" >&2
        printf '%s\n' "$left" | sed 's/^/  /' >&2
        return 1
    fi

    # Then everything again, the volumes now free: nothing checked
    # before retire is trusted after it.
    cleanup_examine "$RETIRE_SCRATCH" free || return 1
    local total="$CLEANUP_TOTAL" n kind path mode dir

    # Preserve every source under a new snapshot, then verify the
    # checkout's whole object store once.
    local snap hex base prefix inv empty sources_blob sources_ref
    snap=$(swarm_recovery_snapshot_id) || return 1
    hex=$(cleanup_hex "$engagement") || return 1
    base="${SWARM_RECOVERY_NS}/e${hex}/${snap}"
    printf '[]' > "$RETIRE_SCRATCH/run.json" || return 1
    while IFS="$(printf '\t')" read -r -u 3 n kind path mode; do
        dir="$RETIRE_SCRATCH/scan.$n"
        prefix="${base}/s${n}"
        empty=false
        inv=null
        if grep -qx empty "$dir/report" 2>/dev/null \
                && [ ! -f "$dir/bundle" ]; then
            empty=true
        else
            swarm_recovery_import "$REPO_ROOT" "$dir" "$prefix" || return 1
            inv=$(cleanup_inventory "$prefix") || return 1
            inv="\"$inv\""
        fi
        jq --arg id "s$n" --arg k "$kind" --arg p "$path" \
            --arg pre "$prefix" --arg m "$mode" --argjson inv "$inv" \
            --argjson e "$empty" '. + [{id: $id, kind: $k, path: $p,
                prefix: (if $e then null else $pre end), mode: $m,
                inventory: $inv, empty: $e, state: "preserved"}]' \
            "$RETIRE_SCRATCH/run.json" > "$RETIRE_SCRATCH/run.json.new" \
            && mv "$RETIRE_SCRATCH/run.json.new" "$RETIRE_SCRATCH/run.json" \
            || return 1
    done 3< "$RETIRE_SCRATCH/scanned" < /dev/null || return 1
    local kept
    kept=$(jq length "$RETIRE_SCRATCH/run.json") || return 1
    if [ "$kept" != "$total" ]; then
        echo "ERROR: preserved ${kept} of the ${total} locations to clean" \
             "up." >&2
        return 1
    fi
    # "s<n> <kind> <path as a JSON string>" per source, for people.
    jq -r '.[] | "\(.id) \(.kind) \(.path | tojson)"' \
        "$RETIRE_SCRATCH/run.json" > "$RETIRE_SCRATCH/map" || return 1
    # The sources blob first (git fsck checks it too), the ref only once
    # the checkout is verified: a sources ref marks a verified copy of
    # every location it lists.
    sources_blob=$(swarm_recovery_git -C "$REPO_ROOT" hash-object -w \
        --stdin < "$RETIRE_SCRATCH/map") || return 1
    sources_ref="${base}/sources"
    # The mirrors' manifest (and one cut off while it was written), which
    # says what submodule each numbered mirror was: a tree of the files
    # as they are, under its own ref.
    local mf mf_oid mf_entries="" mf_tree="" mf_ref=""
    for mf in manifest.json manifest.json.new; do
        [ -f "${MIRROR_DIR}/${mf}" ] && [ ! -L "${MIRROR_DIR}/${mf}" ] \
            || continue
        mf_oid=$(swarm_recovery_git -C "$REPO_ROOT" hash-object -w \
            --no-filters "${MIRROR_DIR}/${mf}") || return 1
        mf_entries="${mf_entries}100644 blob ${mf_oid}"$'\t'"${mf}"$'\n'
    done
    if [ -n "$mf_entries" ]; then
        mf_tree=$(printf '%s' "$mf_entries" \
            | swarm_recovery_git -C "$REPO_ROOT" mktree) || return 1
        mf_ref="${base}/mirrors-manifest"
    fi
    swarm_recovery_verify_checkout "$REPO_ROOT" || return 1
    swarm_recovery_git -C "$REPO_ROOT" update-ref "$sources_ref" \
        "$sources_blob" "" || return 1
    if [ -n "$mf_ref" ]; then
        swarm_recovery_git -C "$REPO_ROOT" update-ref "$mf_ref" \
            "$mf_tree" "" || return 1
    fi

    # The checkpoint, before the first deletion.
    swarm_state_update "$STATE_FILE" '
        .cleanup = ((.cleanup // {engagement: $e, started_at: $at,
                     runs: []})
            | .runs += [{snapshot: $s, sources_ref: $ref,
                         sources_oid: $oid, sources: $src}
                        + (if $mref == "" then {}
                           else {manifest_ref: $mref, manifest_oid: $moid}
                           end)])' \
        --arg e "$engagement" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg s "$snap" --arg ref "$sources_ref" --arg oid "$sources_blob" \
        --arg mref "$mf_ref" --arg moid "$mf_tree" \
        --argjson src "$(cat "$RETIRE_SCRATCH/run.json")" || return 1

    # Delete, volumes first and the bare repo last, each step checked
    # again right before it acts.
    local order id rest
    for order in volume mirror new removing bare; do
        while IFS="$(printf '\t')" read -r -u 3 n kind path mode; do
            [ "$kind" = "$order" ] || continue
            id="s$n"
            prefix="${base}/${id}"
            # Its one record in the checkpoint must show it preserved:
            # an inventory that still holds, or a scan that found it
            # empty.
            rest=$(swarm_state_read "$STATE_FILE" | jq -r --arg id "$id" \
                --arg k "$kind" --arg p "$path" '
                [.cleanup.runs[-1].sources[]
                 | select(.id == $id and .kind == $k and .path == $p)]
                | if length != 1 then "none"
                  elif .[0].empty == true then "empty"
                  elif (.[0].inventory | type) == "string"
                  then "inventory " + .[0].inventory
                  else "none" end') || rest=none
            case "$rest" in
                empty) ;;
                "inventory "*)
                    inv=$(cleanup_inventory "$prefix") || inv=""
                    if [ "$inv" != "${rest#inventory }" ]; then
                        echo "ERROR: the recovery refs of ${path} changed" \
                             "before it was deleted." >&2
                        return 1
                    fi ;;
                *)
                    echo "ERROR: the checkpoint has no record that ${path}" \
                         "was preserved; not deleting it." >&2
                    return 1 ;;
            esac
            case "$kind" in
                volume)
                    cleanup_volume_free "$path" || return 1
                    mp=$(cleanup_volume_mountpoint "$path") || {
                        echo "ERROR: cannot inspect volume ${path}." >&2
                        return 1
                    }
                    if [ -n "$mp" ]; then
                        swarm_no_mounts "$mp" at || return 1
                    fi
                    cleanup_record "$id" '.state = "deleting"' || return 1
                    if ! docker volume rm "$path" >/dev/null 2>&1; then
                        echo "ERROR: cannot remove volume ${path}." >&2
                        return 1
                    fi
                    cleanup_record "$id" '.state = "deleted"' || return 1 ;;
                bare)
                    rc=0
                    swarm_preservation_check "$BARE_REPO" "$REPO_ROOT" \
                        > "$RETIRE_SCRATCH/e3" || rc=$?
                    if [ "$rc" -ne 0 ] && { [ "$rc" -ne 1 ] \
                            || [ "$CLEANUP_ALLOW_UNHARVESTED" != true ]; }
                    then
                        echo "ERROR: ${BARE_REPO} changed during cleanup." >&2
                        return 1
                    fi
                    cleanup_delete_host "$id" "$path" || return 1 ;;
                *)
                    cleanup_delete_host "$id" "$path" || return 1 ;;
            esac
            echo "  deleted ${path}"
        done 3< "$RETIRE_SCRATCH/scanned" < /dev/null || return 1
    done
    # The manifest goes after the mirrors it lists, once each file is
    # still what the checkpoint kept.
    local mf_have mf_want mf_kept=""
    # The ref the checkpoint recorded must still hold that tree.
    if [ -n "$mf_tree" ]; then
        mf_kept=$(swarm_state_read "$STATE_FILE" | jq -r \
            --arg r "$mf_ref" --arg o "$mf_tree" '
            .cleanup.runs[-1] | select(.manifest_ref == $r
                and .manifest_oid == $o) | .manifest_oid') || mf_kept=""
        if [ -z "$mf_kept" ] || [ "$(swarm_recovery_git -C "$REPO_ROOT" \
                rev-parse --verify --quiet "$mf_ref" 2>/dev/null)" \
                != "$mf_tree" ]; then
            echo "ERROR: ${mf_ref}, which keeps the mirrors' manifest," \
                 "changed or went; not deleting the manifest." >&2
            return 1
        fi
    fi
    for mf in manifest.json manifest.json.new; do
        [ -e "${MIRROR_DIR}/${mf}" ] || [ -L "${MIRROR_DIR}/${mf}" ] \
            || continue
        mf_have="" mf_want=""
        if [ -n "$mf_tree" ] && [ -f "${MIRROR_DIR}/${mf}" ] \
                && [ ! -L "${MIRROR_DIR}/${mf}" ]; then
            mf_have=$(swarm_recovery_git -C "$REPO_ROOT" hash-object \
                --no-filters "${MIRROR_DIR}/${mf}" 2>/dev/null) || mf_have=""
            mf_want=$(swarm_recovery_git -C "$REPO_ROOT" rev-parse \
                --verify --quiet "${mf_tree}:${mf}" 2>/dev/null) || mf_want=""
        fi
        if [ -z "$mf_have" ] || [ "$mf_have" != "$mf_want" ]; then
            echo "ERROR: ${MIRROR_DIR}/${mf} changed during cleanup." >&2
            return 1
        fi
        rm -f "${MIRROR_DIR}/${mf}" || return 1
        echo "  deleted ${MIRROR_DIR}/${mf}"
    done
    if [ -d "$MIRROR_DIR" ] && ! rmdir "$MIRROR_DIR" 2>/dev/null; then
        echo "ERROR: ${MIRROR_DIR} is not empty after cleanup." >&2
        return 1
    fi
    cleanup_target_remove || return 1
    # The engagement's records go only once nothing they stand for is
    # left, whatever this run did or did not list.
    cleanup_sources "$RETIRE_SCRATCH/left" || return 1
    local tgt
    for tgt in "$RUNTIME_DIR/target.git" "$RUNTIME_DIR/target.git.removing"
    do
        if [ -e "$tgt" ] || [ -L "$tgt" ]; then
            printf 'target\t%s\n' "$tgt" >> "$RETIRE_SCRATCH/left" \
                || return 1
        fi
    done
    if [ -s "$RETIRE_SCRATCH/left" ]; then
        echo "ERROR: cleanup left these in place:" >&2
        cut -f2 "$RETIRE_SCRATCH/left" | sed 's/^/  /' >&2
        echo "  Run ./launch.sh cleanup again." >&2
        return 1
    fi

    # The engagement's records go last; the claim of the runtime
    # directory and its lock stay.
    local f
    for f in "$RUNTIME_DIR"/interactive-*.pending; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        rm -f "$f" || return 1
    done
    swarm_state_update "$STATE_FILE" '{schema: .schema, project: .project,
        repo_root: .repo_root}' || return 1
    echo "Cleaned up engagement ${engagement}."
    echo "Recovery refs: ${base}/ (what each s<n> was: git cat-file" \
         "blob ${sources_ref})."
}

cmd_cleanup() {
    local rc=0
    RETIRE_SCRATCH=""
    # shellcheck disable=SC2034  # read by retire_cleanup (lib/retire.sh)
    RETIRE_SNAP_REF=""
    trap retire_stopped EXIT
    trap 'trap "" HUP INT TERM; retire_cleanup; trap - EXIT; exit 129' HUP
    trap 'trap "" HUP INT TERM; retire_cleanup; trap - EXIT; exit 130' INT
    trap 'trap "" HUP INT TERM; retire_cleanup; trap - EXIT; exit 143' TERM
    if RETIRE_SCRATCH=$(retire_tmpdir); then
        cleanup_run "$@" || rc=$?
    else
        rc=1
    fi
    retire_cleanup
    trap - EXIT HUP INT TERM
    return "$rc"
}
