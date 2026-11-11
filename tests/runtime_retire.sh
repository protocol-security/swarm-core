#!/bin/bash
set -uo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# tests/runtime_retire.sh
#
# swarm retire under real Docker.  Retire checks each container in
# a snapshot of it (docker commit) and through docker diff, which the
# fake docker in test_retire.sh only imitates.  Each case leaves one
# stopped container with a repository in its workspace volume and
# something in its own layer, runs retire, and checks whether the
# container is gone.
#
# Cases (the base image ships no repository):
#   1. A plain file in /tmp                          -> removed.
#   2. A link in the volume into the unchanged image -> removed.
#   3. A link in the volume to a file it wrote       -> refused.
#   4. A link out of the volume, and a name that is not UTF-8 in its
#      layer (docker diff reports the name altered)  -> refused.
#   5. core.hooksPath in its global git config       -> refused.
#   6. core.hooksPath in the system config of a git built with another
#      prefix (/usr/local/etc/gitconfig)             -> refused.
#   7. A clone with a new commit in /tmp             -> refused.
# An image that ships repositories (one whose name is not UTF-8, a bare
# one, and a bare one whose objects/ is a link elsewhere) is refused,
# changed or not, since docker diff cannot show every change:
#   8. Nothing changed                               -> refused.
#   9. An edit, a same-size edit with its time put back, a new tag, a
#      new object (also through the objects/ link)   -> refused.
#  10. An edit under a repository rooted at /        -> refused.
# Two containers, the second one unsafe: both are checked and neither
# is removed.
# And retire stopped by SIGTERM once its snapshot exists, or by a
# Ctrl-C during its checks or while docker commit runs, removes the
# snapshot and keeps the container; a snapshot an earlier retire left
# is removed first.
#
# Requires Docker.  No API key needed.  Wall-clock: about a minute
# once the image is cached.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LAUNCH_SH="${REPO_ROOT}/bin/swarm"

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not found"
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker daemon not running"
    exit 0
fi

# shellcheck source=../lib/project.sh
source "$REPO_ROOT/lib/project.sh"

# The image runtime_signal_trap.sh builds (cached), and three built on
# it.
BASE_IMAGE="swarm-core-runtime-test"
IMAGE="swarm-core-retire-test"
ROOT_IMAGE="swarm-core-retire-root-test"
CHECKOUT_IMAGE="swarm-core-retire-checkout-test"
PREFIX_IMAGE="swarm-core-retire-prefix-test"
P="swarm-core-retire-test"
NAME="${P}-agent-1"
VOL="${NAME}-ws-00000000"
NAME2="${P}-agent-2"
VOL2="${NAME2}-ws-00000000"
WORKDIR=$(mktemp -d /tmp/swarm-core-retire-XXXXXX)

drop_case() {
    docker rm -f "$NAME" "$NAME2" >/dev/null 2>&1 || true
    docker volume rm "$VOL" "$VOL2" >/dev/null 2>&1 || true
}
# What a failed run (of this test or of retire) may leave: containers
# with this test's project label, its snapshots.  The project id is
# this test's own.
drop_leftovers() {
    local c snap
    for c in $(docker ps -aq --filter "label=${SWARM_PROJECT_LABEL}=${P}"); do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    for snap in $(docker images -q --filter "reference=${P}-agent-retire"); do
        docker rmi -f "$snap" >/dev/null 2>&1 || true
    done
}
cleanup() {
    drop_case
    drop_leftovers
    docker rmi "$IMAGE" "$ROOT_IMAGE" "$PREFIX_IMAGE" "$CHECKOUT_IMAGE" \
        >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

PASS=0
FAIL=0

check() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "    PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "    FAIL: ${label}  expected=${expected} got=${actual}"
        FAIL=$((FAIL + 1))
    fi
}

drop_leftovers
echo "--- Building ${BASE_IMAGE} (fake driver only) ---"
docker build --quiet --tag "$BASE_IMAGE" \
    --build-arg SWARM_AGENTS=fake "$REPO_ROOT" >/dev/null || exit 1
# Repositories in the image (one whose name is not UTF-8), a bare
# repository and one whose objects/ is a link to /opt/object-pool; an
# image whose / is a work tree; and an image whose git, like one built
# with another prefix, reads /usr/local/etc/gitconfig.  The agent user
# may write to the repositories.
# An image that ships one checkout and nothing else.  Its file is dated
# well before its index, so that Git trusts the stat data it recorded
# (no racy entry): a change that keeps size and mtime is then found by
# its ctime alone.
docker build --quiet --tag "$CHECKOUT_IMAGE" - >/dev/null <<EOF || exit 1
FROM ${BASE_IMAGE}
USER root
RUN git init -q /opt/tool \\
    && echo 'int main(void) { return 0; }' > /opt/tool/main.c \\
    && touch -d '2020-01-01 00:00:00' /opt/tool/main.c \\
    && git -C /opt/tool add main.c \\
    && git -C /opt/tool -c user.name=t -c user.email=t@t commit -q -m tool \\
    && chown -R agent:agent /opt/tool
USER agent
EOF
docker build --quiet --tag "$IMAGE" - >/dev/null <<EOF || exit 1
FROM ${BASE_IMAGE}
USER root
RUN git init -q /opt/tool \\
    && echo 'int main(void) { return 0; }' > /opt/tool/main.c \\
    && git -C /opt/tool add main.c \\
    && git -C /opt/tool -c user.name=t -c user.email=t@t commit -q -m tool \\
    && git init -q --bare /srv/repo.git \\
    && git -C /opt/tool push -q /srv/repo.git HEAD:refs/heads/main \\
    && git clone -q /opt/tool "\$(printf '/opt/repo\\377')" \\
    && git init -q --bare /srv/pool.git && mkdir -p /opt/object-pool \\
    && mv /srv/pool.git/objects /opt/object-pool/objects \\
    && ln -s /opt/object-pool/objects /srv/pool.git/objects \\
    && chown -R agent:agent /opt/tool /srv/repo.git /srv/pool.git \\
        /opt/object-pool "\$(printf '/opt/repo\\377')"
USER agent
EOF
sed "s|@BASE@|${BASE_IMAGE}|" <<'EOF' \
    | docker build --quiet --tag "$PREFIX_IMAGE" - >/dev/null || exit 1
FROM @BASE@
USER root
RUN mkdir -p /usr/local/etc \
    && printf '[core]\n\thooksPath = /opt/hooks\n' > /usr/local/etc/gitconfig \
    && printf '#!/bin/sh\nGIT_CONFIG_SYSTEM=/usr/local/etc/gitconfig exec /usr/bin/git "$@"\n' \
        > /usr/local/bin/git \
    && chmod 755 /usr/local/bin/git
USER agent
EOF
docker build --quiet --tag "$ROOT_IMAGE" - >/dev/null <<EOF || exit 1
FROM ${BASE_IMAGE}
USER root
RUN mkdir -p /opt && echo v1 > /opt/x && cd / && git init -q \\
    && git add opt/x \\
    && git -c user.name=t -c user.email=t@t commit -q -m root \\
    && chown agent:agent /opt/x
USER agent
EOF

# The checkout and its runtime directory, on this Docker daemon.
CHECKOUT="$WORKDIR/checkout"
git init -q "$CHECKOUT"
git -C "$CHECKOUT" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m init
CK=$(swarm_checkout_path "$CHECKOUT")
RT="$WORKDIR/runtime"
mkdir -m 700 "$RT"
swarm_runtime_claim "$RT" "$CHECKOUT" "$P" || exit 1
DAEMON=$(swarm_docker_daemon_id) || exit 1
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e1" | .docker_daemon = $d' --arg d "$DAEMON" || exit 1

# More docker run arguments for the next make_container (an environment
# variable, a tmpfs); empty by default.
MC_ARGS=()

# Leave a stopped container of image IMG with a committed repository in
# its workspace volume, after ACTION ran in it: NAME with VOL (after
# dropping what an earlier case left), or the second one, NAME2 with
# VOL2, when SECOND is given.  Fails (with a check) when it cannot.
make_container() {
    local label="$1" img="$2" action="$3" name="$NAME" vol="$VOL"
    if [ -n "${4:-}" ]; then
        name="$NAME2"
        vol="$VOL2"
    else
        drop_case
    fi
    if ! docker volume create \
            --label "${SWARM_PROJECT_LABEL}=${P}" \
            --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
            --label "${SWARM_CONTAINER_LABEL}=${name}" \
            --label "${SWARM_KIND_LABEL}=agent" \
            --label "${SWARM_CONTEXT_LABEL}=full" \
            --label "${SWARM_ENGAGEMENT_LABEL}=e1" \
            "$vol" >/dev/null; then
        check "$label: volume" "failed" "created"
        return 1
    fi
    # The labels of the interface, as on a numbered agent of the engine.
    if ! docker run --name "$name" \
            --label "${SWARM_PROJECT_LABEL}=${P}" \
            --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
            --label "${SWARM_ENGAGEMENT_LABEL}=e1" \
            --label "${SWARM_TOKEN_LABEL}=0123456789abcdef" \
            --label "${SWARM_ROLE_LABEL}=agent" \
            --label "${SWARM_PROFILE_INDEX_LABEL}=1" \
            --label "${SWARM_AGENT_NUMBER_LABEL}=1" \
            --mount "type=volume,src=${vol},dst=/workspace" \
            "${MC_ARGS[@]+"${MC_ARGS[@]}"}" \
            --entrypoint bash "$img" -c '
                set -e
                cd /workspace
                git init -q
                git -c user.name=t -c user.email=t@t commit -q \
                    --allow-empty -m init
                '"$action" > "$WORKDIR/run.out" 2>&1; then
        check "$label: container ran" "failed" "ok"
        tail -8 "$WORKDIR/run.out" | sed 's/^/      /'
        return 1
    fi
}

container_state() {
    if docker container inspect "${1:-$NAME}" >/dev/null 2>&1; then
        echo present
    else
        echo gone
    fi
}

# Case LABEL: make_container IMG ACTION, then retire.  EXPECT is
# "removed", or text retire's refusal must contain.
run_case() {
    local label="$1" img="$2" action="$3" expect="$4" rc=0 out
    local failed_before="$FAIL"
    echo "--- ${label} ---"
    make_container "$label" "$img" "$action" || return
    out=$(cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        "$BASH" "$LAUNCH_SH" retire 2>&1) || rc=$?
    if [ "$expect" = removed ]; then
        check "$label: retired" "$rc" "0"
        check "$label: container gone" "$(container_state)" "gone"
        check "$label: volume kept" \
            "$(docker volume inspect "$VOL" >/dev/null 2>&1 \
                && echo kept || echo gone)" "kept"
    else
        check "$label: refused" "$rc" "1"
        check "$label: for that reason" \
            "$(printf '%s\n' "$out" | LC_ALL=C grep -acF -- "$expect" \
                | awk '{ print ($1 > 0) }')" "1"
        check "$label: container kept" "$(container_state)" "present"
    fi
    if [ "$FAIL" -gt "$failed_before" ]; then
        printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
    fi
}

snapshots() {
    docker images -q --filter "reference=${P}-agent-retire" | wc -l \
        | tr -d ' '
}

# Retire gets SIGTERM (as from a timeout) once its snapshot exists: it
# stops, removes the snapshot, and keeps the container.  The workspace
# holds a few thousand files, so the checks take a while.
interrupt_case() {
    local label="interrupted by SIGTERM" pid rc=0 seen=0 tries=0 base
    local failed_before="$FAIL"
    echo "--- ${label} ---"
    make_container "$label" "$BASE_IMAGE" '
        mkdir many
        for i in $(seq 1 3000); do echo "$i" > "many/f$i"; done
        git add many
        git -c user.name=t -c user.email=t@t commit -q -m many' || return
    # Snapshots left by anything else do not count.
    base=$(snapshots)
    (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        exec "$BASH" "$LAUNCH_SH" retire) > "$WORKDIR/int.out" 2>&1 &
    pid=$!
    # Up to a minute for the snapshot to show up.
    while [ "$tries" -lt 600 ]; do
        if [ "$(snapshots)" -gt "$base" ]; then
            seen=1
            break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
        tries=$((tries + 1))
    done
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" || rc=$?
    check "$label: the snapshot existed first" "$seen" "1"
    check "$label: stopped" "$rc" "143"
    check "$label: snapshot removed" "$(snapshots)" "$base"
    check "$label: container kept" "$(container_state)" "present"
    if [ "$FAIL" -gt "$failed_before" ]; then
        tail -8 "$WORKDIR/int.out" | sed 's/^/      /'
    fi
}

# A Ctrl-C at the terminal (SIGINT to retire's process group) while
# docker commit works on a large layer: the daemon finishes the image
# even when its client stops, so retire must wait for the commit and
# remove the snapshot after; none may show up later.
group_interrupt_case() {
    local label="Ctrl-C during the commit" pid rc=0 tries=0 seen=0 base
    local failed_before="$FAIL"
    echo "--- ${label} ---"
    make_container "$label" "$BASE_IMAGE" \
        'head -c 400000000 /dev/urandom > /tmp/big' || return
    base=$(snapshots)
    set -m
    (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        exec "$BASH" "$LAUNCH_SH" retire) > "$WORKDIR/gint.out" 2>&1 &
    pid=$!
    set +m
    # Up to a minute for docker commit to start.
    while [ "$tries" -lt 600 ]; do
        # A here-string: under pipefail, ps | grep -q can miss a match.
        if grep -qE '(^|/)docker commit ' <<< "$(ps -A -o args=)"; then
            seen=1
            break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
        tries=$((tries + 1))
    done
    sleep 0.5
    kill -INT -- "-$pid" 2>/dev/null
    wait "$pid" || rc=$?
    check "$label: the commit was running" "$seen" "1"
    check "$label: stopped" "$rc" "130"
    # Long enough for the daemon to finish an abandoned commit.
    sleep 15
    check "$label: no snapshot left" "$(snapshots)" "$base"
    check "$label: container kept" "$(container_state)" "present"
    if [ "$FAIL" -gt "$failed_before" ]; then
        tail -8 "$WORKDIR/gint.out" | sed 's/^/      /'
    fi
}

# A Ctrl-C at the terminal once the snapshot exists (while the checks
# run containers from it): retire stops, removes those containers and
# the snapshot, and keeps the container.  The snapshot carries the
# engine's labels emptied.
group_interrupt_scan_case() {
    local label="Ctrl-C during the checks" pid rc=0 seen=0 tries=0 base
    local snap="" labels="" failed_before="$FAIL"
    echo "--- ${label} ---"
    make_container "$label" "$BASE_IMAGE" '
        mkdir many
        for i in $(seq 1 3000); do echo "$i" > "many/f$i"; done
        git add many
        git -c user.name=t -c user.email=t@t commit -q -m many' || return
    base=$(snapshots)
    set -m
    (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        exec "$BASH" "$LAUNCH_SH" retire) > "$WORKDIR/gsint.out" 2>&1 &
    pid=$!
    set +m
    # Up to a minute for the snapshot to show up.
    while [ "$tries" -lt 600 ]; do
        if [ "$(snapshots)" -gt "$base" ]; then
            seen=1
            break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
        tries=$((tries + 1))
    done
    if [ "$seen" = 1 ]; then
        snap=$(docker images -q --no-trunc \
            --filter "reference=${P}-agent-retire" | head -n 1)
        labels=$(docker image inspect -f \
            '{{index .Config.Labels "swarm-core.project"}}|{{index .Config.Labels "swarm-core.checkout"}}|{{index .Config.Labels "swarm-core.engagement"}}|{{index .Config.Labels "swarm-core.engagement-token"}}|{{index .Config.Labels "swarm-core.role"}}|{{index .Config.Labels "swarm-core.profile-index"}}|{{index .Config.Labels "swarm-core.agent-number"}}' \
            "$snap" 2>/dev/null)
    fi
    kill -INT -- "-$pid" 2>/dev/null
    wait "$pid" || rc=$?
    check "$label: the snapshot existed first" "$seen" "1"
    check "$label: its engine labels are empty" "$labels" "||||||"
    check "$label: stopped" "$rc" "130"
    check "$label: snapshot removed" "$(snapshots)" "$base"
    check "$label: no container made from it is left" \
        "$(docker ps -a --no-trunc --format '{{.Image}}' \
            | grep -cF -- "${snap:-none}" || true)" "0"
    check "$label: container kept" "$(container_state)" "present"
    if [ "$FAIL" -gt "$failed_before" ]; then
        tail -8 "$WORKDIR/gsint.out" | sed 's/^/      /'
    fi
}

# Whether a job started here under job control can be stopped by
# SIGINT: not when this run started with SIGINT ignored (a background
# job of a script), since the ignore is inherited and cannot be undone.
# Bash 3.2 does not report such an ignore through trap -p, so try it,
# in a subshell: job control switched on in the test's own shell would
# stay with it on Bash 3.2.
sigint_works() {
    local pid tries=0
    set -m
    sleep 30 &
    pid=$!
    set +m
    # Signal it once it runs sleep: before its exec, the shell's own
    # handling of SIGINT still applies and the signal can be lost.
    while [ "$tries" -lt 40 ]; do
        case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
            *sleep) break ;;
        esac
        sleep 0.05
        tries=$((tries + 1))
    done
    kill -INT "$pid" 2>/dev/null
    tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 20 ]; do
        sleep 0.05
        tries=$((tries + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 1
    fi
    wait "$pid" 2>/dev/null
    return 0
}

# Two containers, the second one unsafe (a clone in /tmp): retire
# checks both, so it refuses and removes neither.
two_container_case() {
    local label="a safe container and an unsafe one" rc=0 out
    local failed_before="$FAIL"
    echo "--- ${label} ---"
    make_container "$label" "$BASE_IMAGE" 'echo notes > /tmp/notes' \
        || return
    make_container "$label" "$BASE_IMAGE" '
        git clone -q --bare /workspace /tmp/experiment.git' second || return
    out=$(cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        "$BASH" "$LAUNCH_SH" retire 2>&1) || rc=$?
    check "$label: refused" "$rc" "1"
    check "$label: for the unsafe one" \
        "$(printf '%s\n' "$out" | grep -c "${NAME2} has Git repositories")" "1"
    check "$label: the safe one kept" "$(container_state "$NAME")" "present"
    check "$label: the unsafe one kept" "$(container_state "$NAME2")" "present"
    if [ "$FAIL" -gt "$failed_before" ]; then
        printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
    fi
}

# The untracked file of the last case, dropped on purpose: retire
# --discard-uncommitted lists it and keeps the rest of the clone.
discard_case() {
    local label="--discard-uncommitted" rc=0 out file="${1:-results.txt}"
    out=$(cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        "$BASH" "$LAUNCH_SH" retire --discard-uncommitted 2>&1) || rc=$?
    check "$label: retired" "$rc" "0"
    check "$label: listing what it drops" \
        "$(printf '%s\n' "$out" | grep -c "$file")" "1"
    check "$label: container gone" "$(container_state)" "gone"
}

# A snapshot an earlier retire left (one killed outright) is removed
# first.
sweep_case() {
    local label="a snapshot an earlier retire left" rc=0 out
    local failed_before="$FAIL"
    echo "--- ${label} ---"
    make_container "$label" "$BASE_IMAGE" 'true' || return
    docker tag "$BASE_IMAGE" "${P}-agent-retire:left-behind" || {
        check "$label: tagged" "failed" "ok"
        return
    }
    out=$(cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        "$BASH" "$LAUNCH_SH" retire 2>&1) || rc=$?
    check "$label: retired" "$rc" "0"
    check "$label: removed" \
        "$(docker image inspect "${P}-agent-retire:left-behind" \
            >/dev/null 2>&1 && echo present || echo gone)" "gone"
    check "$label: said so" \
        "$(printf '%s\n' "$out" | grep -c 'a snapshot an earlier retire left')" \
        "1"
    if [ "$FAIL" -gt "$failed_before" ]; then
        printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
    fi
}

run_case "a plain file in /tmp" "$BASE_IMAGE" \
    'echo notes > /tmp/notes' removed
run_case "a link in the volume into the unchanged image" "$BASE_IMAGE" \
    'ln -s /usr/bin/git /workspace/git-link' removed
run_case "a link in the volume to a file it wrote" "$BASE_IMAGE" '
    echo result > /tmp/result
    ln -s /tmp/result /workspace/result' \
    "links out of its volume to data in the container"
run_case "a link out, and a name that is not UTF-8 in its layer" \
    "$BASE_IMAGE" '
    ln -s /usr/bin/git /workspace/git-link
    echo result > "$(printf "/tmp/result\377")"' "cannot report exactly"
run_case "core.hooksPath in its global git config" "$BASE_IMAGE" \
    'git config --global core.hooksPath /home/agent/hooks' \
    "core.hookspath"
run_case "a system git config outside /etc" "$PREFIX_IMAGE" 'true' \
    "config-setting /usr/local/etc/gitconfig core.hookspath"
run_case "a clone with a new commit in /tmp" "$BASE_IMAGE" '
    git clone -q --no-hardlinks /workspace /tmp/experiment
    git -C /tmp/experiment -c user.name=t -c user.email=t@t \
        commit -q --allow-empty -m unpushed' removed
check "the clone's new commit is kept as a recovery ref" \
    "$(git -C "$CHECKOUT" log --all --format=%s | grep -c '^unpushed$')" "1"
check "under a snapshot with its sources ref" \
    "$(git -C "$CHECKOUT" for-each-ref 'refs/swarm-recovery/*/*/sources' \
        | wc -l | tr -d ' ')" "1"
run_case "a checkout below a directory it made, with an internal link" \
    "$BASE_IMAGE" '
    mkdir -p /tmp/fixture
    git init -q /tmp/fixture/repo
    cd /tmp/fixture/repo
    echo data > a.txt
    ln -s a.txt link
    git add a.txt link
    git -c user.name=t -c user.email=t@t commit -q -m fixture' removed
run_case "a checkout with a clean submodule below a directory it made" \
    "$BASE_IMAGE" '
    git init -q /tmp/subsrc
    git -C /tmp/subsrc -c user.name=t -c user.email=t@t commit -q \
        --allow-empty -m sub
    mkdir -p /tmp/fixture2
    git init -q /tmp/fixture2/repo
    cd /tmp/fixture2/repo
    git -c protocol.file.allow=always submodule add -q /tmp/subsrc sub
    git -c user.name=t -c user.email=t@t commit -q -m with-sub' removed
run_case "a clone with an untracked file in /tmp" "$BASE_IMAGE" '
    git clone -q --no-hardlinks /workspace /tmp/fixture
    echo results > /tmp/fixture/results.txt' \
    "holds work outside Git's history"
discard_case
run_case "a checkout the image ships, unchanged" "$CHECKOUT_IMAGE" 'true' \
    removed
run_case "an edit in a checkout of the image" "$CHECKOUT_IMAGE" \
    'echo "/* edit */" >> /opt/tool/main.c' "dirty .:  M main.c"
run_case "a same-size edit with its time put back" "$CHECKOUT_IMAGE" '
    f=/opt/tool/main.c
    t=$(stat -c %y "$f")
    sed -i "s/main/mian/" "$f"
    touch -d "$t" "$f"
    git -C /opt/tool config core.trustctime false
    git -C /opt/tool config core.checkStat minimal' "dirty .:  M main.c"
run_case "repositories the image ships, bare ones among them" "$IMAGE" \
    'true' "  /srv/repo.git"
run_case "a new tag in a bare repository of the image" "$IMAGE" \
    'git -C /srv/repo.git tag v1 main' "  /srv/repo.git"
run_case "a new object in a bare repository of the image" "$IMAGE" \
    'echo data | git -C /srv/repo.git hash-object -w --stdin >/dev/null' \
    "  /srv/repo.git"
run_case "a new object through an objects/ link" "$IMAGE" \
    'echo data | git -C /srv/pool.git hash-object -w --stdin >/dev/null' \
    "  /srv/pool.git"
run_case "an edit in an image repository whose name is not UTF-8" "$IMAGE" \
    'echo "/* edit */" >> "$(printf "/opt/repo\377")/main.c"' \
    "not valid UTF-8"
run_case "an edit under a repository rooted at /" "$ROOT_IMAGE" \
    'echo edited >> /opt/x' "  /.git"
# Linked worktrees of the workspace's repository in the container's own
# layer: checked like a checkout there (the volume scan's helper keeps
# its scratch under /, so a worktree at /tmp, or one TMPDIR points into,
# gets no file of the helper's).
run_case "a clean linked worktree of the workspace in /tmp" "$BASE_IMAGE" '
    git worktree add -q --detach /tmp/wt HEAD' removed
run_case "a linked worktree rooted at /tmp itself" "$BASE_IMAGE" '
    git worktree add -q --detach /tmp HEAD' removed
MC_ARGS=(-e TMPDIR=/tmp/wt3)
run_case "a linked worktree that TMPDIR points into" "$BASE_IMAGE" '
    git worktree add -q --detach /tmp/wt3 HEAD' removed
MC_ARGS=()
run_case "a linked worktree in /tmp with an untracked file" "$BASE_IMAGE" '
    git worktree add -q --detach /tmp/wt HEAD
    echo results > /tmp/wt/notes.txt' \
    "a linked worktree outside /workspace, in its layer, holds work"
discard_case notes.txt
run_case "a linked worktree whose directory is gone" "$BASE_IMAGE" '
    git worktree add -q --detach /tmp/wt HEAD
    rm -rf /tmp/wt' removed
run_case "a copy of the workspace in /tmp, its worktree gone" \
    "$BASE_IMAGE" '
    git worktree add -q --detach /tmp/wt HEAD
    cp -a /workspace /tmp/copy
    rm -rf /tmp/wt' removed
run_case "a linked worktree with a repository inside" "$BASE_IMAGE" '
    git worktree add -q --detach /tmp/wt HEAD
    git init -q /tmp/wt/inner' "a repository inside"
MC_ARGS=(--tmpfs /scratch)
run_case "a linked worktree on a tmpfs" "$BASE_IMAGE" '
    git worktree add -q --detach /scratch/wt HEAD' "under a mount"
MC_ARGS=()
two_container_case
interrupt_case
if ! (sigint_works); then
    echo "--- SKIP: the Ctrl-C cases (SIGINT is ignored here) ---"
else
    group_interrupt_scan_case
    group_interrupt_case
fi
sweep_case

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
