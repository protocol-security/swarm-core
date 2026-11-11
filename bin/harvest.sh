#!/bin/bash
set -euo pipefail

# Fetch agent-work from the bare repo, merge into current branch.
# Usage: ./bin/harvest.sh [--dry] [--again]

# upload-pack, which Git starts in a local repository for a fetch (or a
# partial clone's lazy fetch), fetches nothing it lacks (Git 2.45.1 and
# later, and the fixes before them) unless the caller's
# GIT_NO_LAZY_FETCH says otherwise; such a fetch would run that
# repository's hooks, without the options harvest gives Git (below).
# Any value but 1 goes.
[ "${GIT_NO_LAZY_FETCH-1}" = 1 ] || unset GIT_NO_LAZY_FETCH

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh"

# Git runs no hook and no fsmonitor command for harvest on the host (the
# status it asks of a running interactive container runs there, among
# the agents' own work).  Its merges put the agents' files in the
# checkout, and Git would run what an agent wrote, here on the host: a
# hook in a directory of the checkout (core.hooksPath, as husky sets
# it), a hook the Git config defines (Git 2.54 and later) running a file
# of it, or the command core.fsmonitor names.  Every git below goes
# through this function: with no hooks directory, no fsmonitor (empty:
# Git before 2.36 runs any other value, "false" included, as a command),
# and each hook the checkout's Git config defines turned off by name
# (harvest_no_config_hooks).  Options given with -c come last, so the
# caller's GIT_CONFIG_PARAMETERS and GIT_CONFIG_COUNT do not override
# them, and they reach Git in a submodule too (a merge with local
# changes asks each submodule's status).  Not covered: hooks that a
# submodule's own config defines, the hooks of a local repository a
# partial clone's lazy fetch reaches (should its upload-pack fetch
# further: Git before 2.45.1 without that fix), the commands the Git
# config names for Git to run (filters, merge drivers,
# uploadpack.packObjectsHook for the fetch), and a Git config that
# includes a file of the checkout, which is the agents' to write.
HARVEST_GIT_BASE=(-c core.hooksPath=/dev/null -c core.fsmonitor=)
HARVEST_GIT_OPTS=("${HARVEST_GIT_BASE[@]}")
git() {
    command git "${HARVEST_GIT_OPTS[@]}" "$@"
}

# Turn off each hook the checkout's Git config defines, which
# core.hooksPath leaves on: by name, the only way Git 2.54 has
# (hook.<event>.enabled came in 2.55), an empty one included (Git 2.54
# also gives that name to a hook defined with no subsection, [hook]
# command).  Harvest scans again once it adds its remote, on which a
# conditional include can depend.  The scan reads bytes (LC_ALL=C: a
# regexp in a UTF-8 locale can miss a name that is not UTF-8) without
# GIT_CONFIG, which git config reads and other commands ignore; the
# shell takes the names apart, which needs no temporary file.  A name
# -c cannot pass (with "=") refuses, as does a config that cannot be
# read.
harvest_no_config_hooks() {
    local keys key name prev=$'\n' rc=0
    local opts=("${HARVEST_GIT_BASE[@]}")
    keys=$(unset GIT_CONFIG
        LC_ALL=C git -C "$REPO_ROOT" config --includes --name-only \
            --get-regexp '^hook\.(.*\.)?(command|event)$') || rc=$?
    case "$rc" in
        0|1) ;;
        *)
            echo "ERROR: cannot read the Git config of ${REPO_ROOT}." >&2
            return 1
            ;;
    esac
    keys="${keys}"$'\n'
    # One name per hook key; [ = ] compares bytes, whatever the
    # caller's shell options (nocasematch) do to case patterns.
    while [ -n "$keys" ]; do
        key=${keys%%$'\n'*}
        keys=${keys#*$'\n'}
        [ -n "$key" ] || continue
        name=${key#hook.}
        case "$name" in
            *.*) name=${name%.*} ;;
            *) name="" ;;
        esac
        [ "$name" != "$prev" ] || continue
        prev=$name
        case "$name" in
            *=*)
                echo "ERROR: harvest cannot turn off the Git hook" \
                     "hook.${name}: a name with \"=\" cannot be passed" \
                     "with git -c.  Rename it, then harvest again." >&2
                return 1
                ;;
        esac
        opts+=(-c "hook.${name}.enabled=false")
    done
    HARVEST_GIT_OPTS=("${opts[@]}")
}

REPO_ROOT="$(git rev-parse --show-toplevel)"
harvest_no_config_hooks || exit 1
PROJECT="$(swarm_project_resolve "$REPO_ROOT")" || exit 1
RUNTIME_DIR="$(swarm_runtime_dir "$PROJECT")" || exit 1
BARE_REPO="${RUNTIME_DIR}/upstream.git"
REMOTE_NAME="_agent-harvest"
DRY_RUN=false
AGAIN=false

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<HELP
Usage: $0 [--dry] [--again]

Fetch agent-work from the bare repo and merge into the current branch.

Options:
  --dry        Show what would be merged without actually merging.
  --again      Merge again what an earlier harvest merged, or started
               merging, and HEAD does not have (after undoing that
               harvest with git reset --hard <restore tag>, or giving
               up its merge).
  -h, --help   Show this help message.

The bare repo lives in the project's runtime directory, which
launch.sh creates when starting agents: SWARM_RUNTIME_DIR if set,
else \$XDG_STATE_HOME/swarm-core/<project> (by default
~/.local/state/swarm-core/<project>).
HELP
            exit 0
            ;;
        --dry)  DRY_RUN=true ;;
        --again) AGAIN=true ;;
    esac
done

warn_dirty_interactive_containers() {
    [ "$DOCKER_UP" = true ] || return 0
    local name id state dirty tmpd tmpf branch

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # Act on the ID of a container this checkout created.
        id=$(swarm_own_container_id "$name" "$CHECKOUT_PATH" "$PROJECT") \
            || exit 1
        [ -n "$id" ] || continue
        state=$(docker inspect -f '{{.State.Status}}' "$id" \
            2>/dev/null || echo "")
        dirty=""
        if [ "$state" = "running" ]; then
            dirty=$(docker exec "$id" bash -lc \
                'cd /workspace && [ -n "$(git status --porcelain=v1)" ] && echo true || echo false' \
                2>/dev/null || true)
        else
            # docker cp gives the copy the source file's mode, so it
            # goes into a private directory.
            tmpd=$(mktemp -d)
            tmpf="${tmpd}/interactive_state"
            docker cp "${id}:/workspace/agent_logs/interactive_state" \
                "$tmpf" 2>/dev/null || true
            if [ -s "$tmpf" ]; then
                dirty=$(grep '^dirty=' "$tmpf" \
                    | head -1 | cut -d= -f2- || true)
                branch=$(grep '^branch=' "$tmpf" \
                    | head -1 | cut -d= -f2- || true)
            fi
            rm -rf "$tmpd"
        fi
        if [ "$dirty" = "true" ]; then
            echo "WARNING: ${name} has uncommitted interactive work" >&2
            [ -n "${branch:-}" ] && echo "         branch: ${branch}" >&2
        fi
    done < <(swarm_interactive_container_names "$PROJECT" 2>/dev/null \
        | sort || true)
}

swarm_refuse_legacy_state "$(swarm_project_id "$(basename "$REPO_ROOT")")" \
    || exit 1
if [ ! -d "$BARE_REPO" ]; then
    echo "ERROR: ${BARE_REPO} not found." >&2
    exit 1
fi
swarm_runtime_check "$RUNTIME_DIR" || exit 1
swarm_runtime_owner_check "$RUNTIME_DIR" "$REPO_ROOT" "$PROJECT" || exit 1
swarm_lock "$RUNTIME_DIR" || exit 1
swarm_cleanup_pending_check "$RUNTIME_DIR/state.json" || exit 1
# An earlier release's engagement is finished with that release; these
# checks read the state file only, so they hold without Docker too.
# This engine records the engagement before it makes the bare repo, so
# a bare repo with none recorded is an earlier release's as well.
swarm_legacy_refuse "$RUNTIME_DIR" "$RUNTIME_DIR/state.json" || exit 1
_engaged=$(swarm_engagement_recorded "$RUNTIME_DIR/state.json") || exit 1
if [ -z "$_engaged" ]; then
    swarm_legacy_explain "$RUNTIME_DIR" \
        "a bare repo with no engagement recorded"
    exit 1
fi
swarm_engagement_token_check "$RUNTIME_DIR/state.json" || exit 1
swarm_engagement_env_check || exit 1
swarm_engagement_join "$RUNTIME_DIR/state.json" || exit 1
# The commit the engagement started from, as this host recorded it when
# it made the bare repo (the bare repo's refs/swarm/base is the agents'
# to write, so it is not trusted).
# The state read here (_state) also holds the record of earlier harvests
# of this engagement (see harvest_list).
if ! _state=$(swarm_state_read "$RUNTIME_DIR/state.json") \
        || ! HARVEST_BASE=$(printf '%s' "$_state" \
            | jq -r '.base_commit // empty'); then
    echo "ERROR: cannot read ${RUNTIME_DIR}/state.json." >&2
    exit 1
fi
# A SHA-1 or SHA-256 commit id, nothing else.
case "${#HARVEST_BASE}:${HARVEST_BASE}" in
    40:*[!0123456789abcdef]*|64:*[!0123456789abcdef]*) HARVEST_BASE="" ;;
    40:*|64:*) ;;
    *) HARVEST_BASE="" ;;
esac
if [ -z "$HARVEST_BASE" ]; then
    echo "ERROR: ${RUNTIME_DIR}/state.json records no base commit for" \
         "engagement ${_engaged}." >&2
    exit 1
fi
CHECKOUT_PATH="$(swarm_checkout_path "$REPO_ROOT")"
# Harvest looks into interactive containers only when Docker answers.
# Without Docker, or with its daemon down, it touches no container and
# skips this check; the merge itself needs only git.
DOCKER_UP=false
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER_UP=true
    swarm_containers_verify "$PROJECT" "$REPO_ROOT" || exit 1
fi

cd "$REPO_ROOT"
warn_dirty_interactive_containers

git remote remove "$REMOTE_NAME" 2>/dev/null || true

echo "--- Fetching agent work ---"
git remote add "$REMOTE_NAME" "$BARE_REPO"
# Refused now, a hook this remote brought in may be on: the remote goes
# with git config, which runs none (nothing was fetched into it yet),
# from this checkout's config whatever GIT_CONFIG names.
if ! harvest_no_config_hooks; then
    (unset GIT_CONFIG
        git config --local --remove-section "remote.${REMOTE_NAME}")
    exit 1
fi
# Branches only: no tag from the bare repo (agents can push tags there)
# comes into this checkout.  upload-pack, which this fetch runs on the
# bare repo, whose config and hooks the agents write, gets none of the
# options above (Git clears them for the local transport), so it fetches
# nothing it lacks: such a fetch would run the bare repo's hooks.  No
# lazy fetch, and no protocol allowed, should its upload-pack fetch by
# default (Git before 2.45.1 without that fix).
git fetch --no-recurse-submodules --no-tags \
    --upload-pack='GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL= git-upload-pack' \
    "$REMOTE_NAME" '+refs/heads/*:refs/remotes/_agent-harvest/*'

HARVEST_BRANCHES=(agent-work)
while IFS= read -r branch; do
    [ -n "$branch" ] && HARVEST_BRANCHES+=("$branch")
done < <(swarm_no_fetch git -C "$BARE_REPO" for-each-ref \
    --format='%(refname:short)' refs/heads/swarm 2>/dev/null \
    | grep -E '/interactive-' || true)

# Succeed when commit A is an ancestor of commit B, fail with 1 when it
# is not; any other answer from git stops harvest.
harvest_is_ancestor() {
    local rc=0
    git merge-base --is-ancestor "$1" "$2" 2>/dev/null || rc=$?
    case "$rc" in
        0|1) return "$rc" ;;
    esac
    echo "ERROR: cannot compare $1 with $2." >&2
    git remote remove "$REMOTE_NAME"
    exit "$rc"
}

# Explain what cannot be merged, and stop.
harvest_refuse() {
    echo "" >&2
    printf '%s\n' "$@" >&2
    echo "" >&2
    echo "Take what you need from the bare repo by hand (git log" >&2
    echo "${REMOTE_NAME}/<branch>, cherry-pick), then end the engagement" >&2
    echo "with" >&2
    echo "  ./bin/launch.sh cleanup --allow-unharvested" >&2
    echo "which keeps everything in the bare repo as recovery refs," >&2
    echo "and start again from the current HEAD." >&2
    git remote remove "$REMOTE_NAME"
    exit 1
}

# The record of earlier harvests of this engagement, from the state read
# above, one commit id per line: FIELD harvested lists the commits HEAD
# must keep (the tips harvests merged), harvest_pending the tip of a
# merge a harvest started and did not see through (it stopped on a
# conflict, or with the harvest).
harvest_list() {
    printf '%s' "$_state" | jq -r --arg f "$1" '(.[$f] // [])[]'
}

# Print the tips of the harvested branches as fetched, one per line.
harvest_tips() {
    local branch
    for branch in "${HARVEST_BRANCHES[@]}"; do
        git rev-parse -q --verify \
            "refs/remotes/${REMOTE_NAME}/${branch}^{commit}" || true
    done
}

# Write the record (under the lock, as all of harvest): as harvested,
# the commits of LIST (one per line) that HEAD has, leaving out those
# another of them has in its history, so that the record never lowers
# what HEAD must keep; as harvest_pending, the commits of PENDING (a
# merge about to start, or one left stopped).
harvest_record() {
    local list pending="${2:-}" c d keep="" dominated h p IFS=$'\n'
    list=$(printf '%s\n' "$1" | sort -u) || return 1
    local contained=""
    for c in $list; do
        if harvest_is_ancestor "$c" HEAD; then
            contained="${contained}${c}"$'\n'
        fi
    done
    for c in $contained; do
        dominated=false
        for d in $contained; do
            [ "$d" != "$c" ] || continue
            if harvest_is_ancestor "$c" "$d"; then
                dominated=true
                break
            fi
        done
        $dominated || keep="${keep}${c}"$'\n'
    done
    if ! h=$(printf '%s' "$keep" \
                | jq -R -s -c 'split("\n") | map(select(length > 0))') \
            || ! p=$(printf '%s' "$pending" \
                | jq -R -s -c 'split("\n") | map(select(length > 0))
                    | unique') \
            || ! swarm_state_update "$RUNTIME_DIR/state.json" \
                '.harvested = $h | .harvest_pending = $p' \
                --argjson h "$h" --argjson p "$p"; then
        echo "ERROR: cannot record what was harvested in" \
             "${RUNTIME_DIR}/state.json." >&2
        return 1
    fi
}

# Guard against stale-bare poisoning.  The engagement started from
# HARVEST_BASE: HEAD must still have it (its history was not rewritten
# past it, by a force-push or a rebase), and the branch must be built on
# it (it holds this engagement's work).  Then merging it brings only
# work done since, even once HEAD moved on with an interactive branch
# merged or commits of its own; it never brings back commits that HEAD
# dropped from before the base.  What an earlier harvest merged must
# still be in HEAD too: a history rewritten after it (a rebase that
# dropped some of that work) refuses, unless --again says to merge it
# again.
MERGE_BRANCHES=()
TOTAL_NEW_COMMITS=0
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    echo "ERROR: a merge is in progress in ${REPO_ROOT}: commit it, or" \
         "give it up with git merge --abort, then harvest again." >&2
    git remote remove "$REMOTE_NAME"
    exit 1
fi
if ! HARVESTED=$(harvest_list harvested) \
        || ! PENDING=$(harvest_list harvest_pending); then
    echo "ERROR: cannot read what earlier harvests merged." >&2
    git remote remove "$REMOTE_NAME"
    exit 1
fi
if ! harvest_is_ancestor "$HARVEST_BASE" HEAD; then
    harvest_refuse \
        "ERROR: HEAD's history no longer has the commit this" \
        "engagement started from." \
        "  base:       ${HARVEST_BASE:0:12}" \
        "  HEAD:       $(git rev-parse --short HEAD)" \
        "" \
        "It was rewritten (a force-push, a rebase) after the engagement" \
        "started, and the bare repo at ${BARE_REPO} still has the old" \
        "ancestry: merging its branches would bring back commits HEAD" \
        "dropped."
fi
# What earlier harvests merged must still be in HEAD (a rebase that
# dropped some of it would otherwise bring it back with the next merge),
# whichever branches the bare repo has now; a merge an earlier harvest
# left stopped counts once it was finished, and refuses when it was
# given up or dropped since (as does one a harvest stopped during).
# --again merges all of that again, on purpose.
if ! $AGAIN; then
    for c in $PENDING; do
        if ! harvest_is_ancestor "$c" HEAD; then
            harvest_refuse \
                "ERROR: HEAD does not have ${c:0:12}, which an earlier" \
                "harvest left to merge: that merge stopped (on a" \
                "conflict, or with the harvest) and was given up, it" \
                "was finished and dropped since, or a harvest --again" \
                "stopped before it.  To merge it, run ./bin/harvest.sh --again."
        fi
    done
    for c in $HARVESTED; do
        if ! harvest_is_ancestor "$c" HEAD; then
            harvest_refuse \
                "ERROR: HEAD no longer has what an earlier harvest merged." \
                "  merged:     ${c:0:12}" \
                "  HEAD:       $(git rev-parse --short HEAD)" \
                "" \
                "HEAD's history was rewritten after that harvest (a" \
                "rebase, a reset), so merging again would bring back what" \
                "was dropped.  If that harvest was undone on purpose (git" \
                "reset --hard <restore tag>) and its work is wanted again," \
                "run ./bin/harvest.sh --again."
        fi
    done
fi
for branch in "${HARVEST_BRANCHES[@]}"; do
    # Git calls take the full ref name; the merge below takes the short
    # one (for the usual merge message), which must then name that ref
    # and not a tag or branch of the same name in this checkout, which
    # git would take first.
    remote_ref="refs/remotes/${REMOTE_NAME}/${branch}"
    if ! git show-ref --verify --quiet "$remote_ref"; then
        continue
    fi
    if [ "$(git rev-parse --symbolic-full-name "${REMOTE_NAME}/${branch}" \
            2>/dev/null)" != "$remote_ref" ]; then
        echo "ERROR: ${REMOTE_NAME}/${branch} also names a tag or a branch" \
             "in ${REPO_ROOT} (git show-ref ${REMOTE_NAME}/${branch} lists" \
             "it); delete or rename it, then harvest again." >&2
        git remote remove "$REMOTE_NAME"
        exit 1
    fi

    # A branch that HEAD already contains has nothing new, so merging
    # it is a no-op and cannot bring back removed commits.  Skip the
    # guard for it: once harvest merges an interactive branch,
    # agent-work no longer descends from HEAD.
    if git merge-base --is-ancestor "$remote_ref" HEAD; then
        echo ""
        echo "0 new commits on ${branch}:"
        continue
    else
        rc=$?
        if [ "$rc" -ne 1 ]; then
            echo "ERROR: cannot compare ${REMOTE_NAME}/${branch} with" \
                 "HEAD." >&2
            git remote remove "$REMOTE_NAME"
            exit "$rc"
        fi
    fi

    if ! harvest_is_ancestor "$HARVEST_BASE" "$remote_ref"; then
        harvest_refuse \
            "ERROR: ${REMOTE_NAME}/${branch} is not built on the commit this" \
            "engagement started from, so it does not hold this" \
            "engagement's work." \
            "  base:       ${HARVEST_BASE:0:12}" \
            "  ${branch}: $(git rev-parse --short "$remote_ref")"
    fi

    COMMIT_LOG=$(git log --oneline "$remote_ref" ^HEAD)
    NEW_COMMITS=$(echo "$COMMIT_LOG" | grep -c . || true)
    MERGE_BRANCHES+=("${branch}|${NEW_COMMITS}")
    TOTAL_NEW_COMMITS=$((TOTAL_NEW_COMMITS + NEW_COMMITS))
    echo ""
    echo "${NEW_COMMITS} new commits on ${branch}:"
    echo "$COMMIT_LOG" | head -20 || true
    if [ "$NEW_COMMITS" -gt 20 ]; then
        echo "  ... and $((NEW_COMMITS - 20)) more"
    fi
done

# The commits the record holds that HEAD lacks, under --again: it merges
# them all again, and they stay in the record, as pending, until HEAD
# has them (a harvest stopped half way leaves them there).
harvest_owed() {
    local c
    $AGAIN || return 0
    for c in $HARVESTED $PENDING; do
        # One this checkout does not have is owed too (and refused below).
        if ! git cat-file -e "${c}^{commit}" 2>/dev/null \
                || ! harvest_is_ancestor "$c" HEAD; then
            printf '%s\n' "$c"
        fi
    done
}
# --again merges by id what the record holds and no branch above brings
# back (its branch was deleted from the bare repo, or agent-work moved
# back), from this checkout, which has it from the harvest that merged
# it.  A commit it no longer has, or one not built on the base, refuses.
if $AGAIN; then
    for c in $(harvest_owed | LC_ALL=C sort -u); do
        case "${#c}:${c}" in
            40:*[!0123456789abcdef]*|64:*[!0123456789abcdef]*) bad=true ;;
            40:*|64:*) bad=false ;;
            *) bad=true ;;
        esac
        if $bad || ! git cat-file -e "${c}^{commit}" 2>/dev/null; then
            harvest_refuse \
                "ERROR: ./bin/harvest.sh --again cannot merge ${c:0:12}" \
                "again: an earlier harvest recorded it, and neither this" \
                "checkout nor a branch of the bare repo has it any more."
        fi
        # Brought in by a branch, or by a commit, queued before it.
        covered=false
        if [ "${#MERGE_BRANCHES[@]}" -gt 0 ]; then
            for item in "${MERGE_BRANCHES[@]}"; do
                branch="${item%%|*}"
                case "$branch" in
                    commit:*) ref="${branch#commit:}" ;;
                    *) ref="refs/remotes/${REMOTE_NAME}/${branch}" ;;
                esac
                if harvest_is_ancestor "$c" "$ref"; then
                    covered=true
                    break
                fi
            done
        fi
        $covered && continue
        if ! harvest_is_ancestor "$HARVEST_BASE" "$c"; then
            harvest_refuse \
                "ERROR: ${c:0:12}, which an earlier harvest recorded, is" \
                "not built on the commit this engagement started from."
        fi
        COMMIT_LOG=$(git log --oneline "$c" ^HEAD)
        NEW_COMMITS=$(echo "$COMMIT_LOG" | grep -c . || true)
        MERGE_BRANCHES+=("commit:${c}|${NEW_COMMITS}")
        TOTAL_NEW_COMMITS=$((TOTAL_NEW_COMMITS + NEW_COMMITS))
        echo ""
        echo "${NEW_COMMITS} new commits from ${c:0:12}, which an earlier" \
             "harvest recorded and no branch brings back:"
        echo "$COMMIT_LOG" | head -20 || true
        if [ "$NEW_COMMITS" -gt 20 ]; then
            echo "  ... and $((NEW_COMMITS - 20)) more"
        fi
    done
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "(dry run -- not merging)"
    git remote remove "$REMOTE_NAME"
    exit 0
fi

# What HEAD must keep after this harvest: what it had to keep before,
# the merges left stopped that it finished, and every harvested branch
# HEAD now has (harvest_record keeps those HEAD has).
RECORD=$(printf '%s\n%s\n' "$HARVESTED" "$PENDING")

if [ "$TOTAL_NEW_COMMITS" -eq 0 ]; then
    echo ""
    echo "Nothing new to merge."
    # A merge finished by hand since the last harvest counts from now.
    if ! harvest_record "${RECORD}"$'\n'"$(harvest_tips)" \
            "$(harvest_owed)"; then
        git remote remove "$REMOTE_NAME"
        exit 1
    fi
    git remote remove "$REMOTE_NAME"
    exit 0
fi

# Tag a restore point on the pre-merge HEAD so this harvest can be
# undone with `git reset --hard <tag>`.  The tag lives in refs/tags
# and never collides with the harvested branches in refs/heads, so
# it is safe alongside agent-work.  Skip if HEAD is already tagged.
if ! git tag --points-at HEAD | grep -q '^swarm-harvest-'; then
    # Two harvests in the same second (HEAD moved in between) would
    # want the same name; the later one gets a suffix.
    tag_stamp=$(date +%Y-%m-%d-%H%M%S)
    harvest_tag="swarm-harvest-${tag_stamp}"
    tag_n=1
    while git rev-parse -q --verify "refs/tags/${harvest_tag}" >/dev/null
    do
        tag_n=$((tag_n + 1))
        harvest_tag="swarm-harvest-${tag_stamp}-${tag_n}"
    done
    git tag "$harvest_tag"
    echo "Tagged restore point: ${harvest_tag}"
fi

echo ""
pre_merge=$(git rev-parse HEAD)
for item in "${MERGE_BRANCHES[@]}"; do
    branch="${item%%|*}"
    new_commits="${item##*|}"
    [ "$new_commits" -eq 0 ] && continue
    # A commit --again merges by id (no ref name has a colon), unless a
    # merge before it brought it in already.
    case "$branch" in
        commit:*)
            tip="${branch#commit:}"
            harvest_is_ancestor "$tip" HEAD && continue
            ref="$tip"
            branch="${tip:0:12}" ;;
        *)
            ref="${REMOTE_NAME}/${branch}"
            tip=$(git rev-parse --verify -q \
                "refs/remotes/${REMOTE_NAME}/${branch}^{commit}") \
                || tip="" ;;
    esac
    # Record the merge before it starts, with what HEAD has from the
    # merges before it: a harvest that stops before its last record
    # below (killed, say) leaves no merged work unrecorded.
    if [ -z "$tip" ] \
            || ! harvest_record "${RECORD}"$'\n'"$(harvest_tips)" \
                "${tip}"$'\n'"$(harvest_owed)"; then
        echo "ERROR: ${branch} not merged." >&2
        git remote remove "$REMOTE_NAME"
        exit 1
    fi
    echo "--- Merging ${branch} ---"
    # HEAD may have moved on since the engagement started, so this can be
    # a real merge, and it can stop on a conflict.  (The remote ref is
    # the recorded tip: harvest fetched once, under the lock.)  Each
    # merge is committed, whatever merge options the Git config sets
    # (--no-commit, --squash).
    if ! git merge --no-edit --commit --no-squash "$ref"
    then
        echo "" >&2
        if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
            echo "ERROR: merging ${branch} stopped. Resolve the conflicts" \
                 "and commit, or give up with git merge --abort; HEAD was" \
                 "${pre_merge:0:12} before this harvest (git reset --hard" \
                 "${pre_merge:0:12} undoes it)." >&2
        else
            echo "ERROR: git did not start merging ${branch} (see above:" \
                 "local changes in the way, say), and changed nothing for" \
                 "it.  Commit or stash those changes, then run harvest.sh" \
                 "again." >&2
        fi
        # What merged before this branch is recorded all the same, and
        # this branch's merge as left stopped, should one have started.
        stopped=""
        if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
            stopped="$tip"
        fi
        harvest_record "${RECORD}"$'\n'"$(harvest_tips)" \
            "${stopped}"$'\n'"$(harvest_owed)" || true
        git remote remove "$REMOTE_NAME"
        exit 1
    fi
    # Done means committed, with the tip in HEAD.  A merge left
    # unfinished all the same (a hook, say) stops harvest here, pending.
    if git rev-parse -q --verify MERGE_HEAD >/dev/null \
            || ! harvest_is_ancestor "$tip" HEAD; then
        echo "" >&2
        echo "ERROR: git left the merge of ${branch} uncommitted. Commit" \
             "it (git commit) to finish it, or give it up with git merge" \
             "--abort; after that, harvest refuses until ./bin/harvest.sh" \
             "--again." >&2
        harvest_record "${RECORD}"$'\n'"$(harvest_tips)" \
            "${tip}"$'\n'"$(harvest_owed)" || true
        git remote remove "$REMOTE_NAME"
        exit 1
    fi
done
if ! harvest_record "${RECORD}"$'\n'"$(harvest_tips)" \
        "$(harvest_owed)"; then
    git remote remove "$REMOTE_NAME"
    exit 1
fi

git remote remove "$REMOTE_NAME"

echo ""
echo "--- Done ---"
echo "Agent results merged into $(git branch --show-current)."
echo "Review with: git log --oneline -20"
