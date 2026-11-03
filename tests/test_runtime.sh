#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091 source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for the per-project runtime directory in lib/project.sh.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
LEGACY_BARE=""
LEGACY_MIRROR=""
cleanup() {
    rm -rf "$TMPDIR"
    if [ -n "$LEGACY_BARE" ]; then
        rm -rf "$LEGACY_BARE"
    fi
    if [ -n "$LEGACY_MIRROR" ]; then
        rm -rf "$LEGACY_MIRROR"
    fi
}
trap cleanup EXIT
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091 source=../lib/project.sh
source "$TESTS_DIR/../lib/project.sh"

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
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected to contain: ${needle}"
        echo "        actual: ${haystack}"
        FAIL=$((FAIL + 1))
    fi
}

# Run a command and print its exit status, keeping set -e out of it.
status_of() {
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ============================================================
echo "=== 1. Runtime directory location ==="

assert_eq "XDG_STATE_HOME is used when absolute" \
    "/state/swarm-core/proj" \
    "$(env -u SWARM_RUNTIME_DIR XDG_STATE_HOME=/state HOME=/home/u \
        bash -c 'source "$1"; swarm_runtime_dir proj' _ \
        "$TESTS_DIR/../lib/project.sh")"

assert_eq "HOME/.local/state when XDG_STATE_HOME is unset" \
    "/home/u/.local/state/swarm-core/proj" \
    "$(env -u SWARM_RUNTIME_DIR -u XDG_STATE_HOME HOME=/home/u \
        bash -c 'source "$1"; swarm_runtime_dir proj' _ \
        "$TESTS_DIR/../lib/project.sh")"

assert_eq "relative XDG_STATE_HOME is ignored" \
    "/home/u/.local/state/swarm-core/proj" \
    "$(env -u SWARM_RUNTIME_DIR XDG_STATE_HOME=rel HOME=/home/u \
        bash -c 'source "$1"; swarm_runtime_dir proj' _ \
        "$TESTS_DIR/../lib/project.sh")"

assert_eq "SWARM_RUNTIME_DIR wins" "/srv/run" \
    "$(SWARM_RUNTIME_DIR=/srv/run XDG_STATE_HOME=/state \
        swarm_runtime_dir proj)"

assert_eq "relative SWARM_RUNTIME_DIR is refused" "1" \
    "$(SWARM_RUNTIME_DIR=run status_of swarm_runtime_dir proj)"

assert_eq "colon in the path is refused" "1" \
    "$(SWARM_RUNTIME_DIR=/srv/a:b status_of swarm_runtime_dir proj)"

assert_eq "trailing slashes are dropped" "/srv/run" \
    "$(SWARM_RUNTIME_DIR=/srv/run// swarm_runtime_dir proj)"
assert_eq "a final '.' is refused" "1" \
    "$(SWARM_RUNTIME_DIR=/srv/run/. status_of swarm_runtime_dir proj)"
assert_eq "a final '..' is refused" "1" \
    "$(SWARM_RUNTIME_DIR=/srv/run/.. status_of swarm_runtime_dir proj)"
assert_eq "a '..' component is refused" "1" \
    "$(SWARM_RUNTIME_DIR=/tmp/../srv/run status_of swarm_runtime_dir proj)"
assert_eq "a '.' component is refused" "1" \
    "$(SWARM_RUNTIME_DIR=/srv/./run status_of swarm_runtime_dir proj)"
assert_eq "a '..' in XDG_STATE_HOME is refused" "1" \
    "$(env -u SWARM_RUNTIME_DIR XDG_STATE_HOME=/a/../b HOME=/home/u \
        bash -c 'source "$1"; swarm_runtime_dir proj' _ \
        "$TESTS_DIR/../lib/project.sh" >/dev/null 2>&1; echo $?)"
assert_eq "names that start with dots are fine" "/srv/..run/.state" \
    "$(SWARM_RUNTIME_DIR=/srv/..run/.state swarm_runtime_dir proj)"

assert_eq "no HOME and no override is refused" "1" \
    "$(env -u SWARM_RUNTIME_DIR -u XDG_STATE_HOME -u HOME \
        bash -c 'source "$1"; swarm_runtime_dir proj' _ \
        "$TESTS_DIR/../lib/project.sh" >/dev/null 2>&1; echo $?)"

# ============================================================
echo ""
echo "=== 2. Runtime directory creation and checks ==="

_rt="$TMPDIR/state/swarm-core/proj"
(umask 022 && swarm_runtime_init "$_rt") >/dev/null 2>&1
assert_eq "init creates the directory" "true" \
    "$([ -d "$_rt" ] && echo true || echo false)"
assert_eq "init creates it owner-only despite umask 022" "700" \
    "$(swarm_file_mode "$_rt")"
_rt0="$TMPDIR/umask0/swarm-core/proj"
(umask 000 && swarm_runtime_init "$_rt0") >/dev/null 2>&1
assert_eq "init creates it owner-only despite umask 000" "700" \
    "$(swarm_file_mode "$_rt0")"
assert_eq "init accepts an existing private directory" "0" \
    "$(status_of swarm_runtime_init "$_rt")"
assert_eq "check accepts the private directory" "0" \
    "$(status_of swarm_runtime_check "$_rt")"

_open="$TMPDIR/open"
mkdir -m 755 "$_open"
assert_eq "check refuses a group/world readable directory" "1" \
    "$(status_of swarm_runtime_check "$_open")"
assert_eq "init does not chmod an existing directory" "755" \
    "$(status_of swarm_runtime_init "$_open" >/dev/null; \
       swarm_file_mode "$_open")"
assert_contains "mode error names the fix" "chmod 700" \
    "$(swarm_runtime_check "$_open" 2>&1 || true)"

# The printed command must name the same path when pasted into a shell,
# even with a dollar sign, a quote or a space in it.
_odd="$TMPDIR/"'odd $HOME "q" dir'
mkdir -m 755 "$_odd"
_hint=$(swarm_runtime_check "$_odd" 2>&1 | grep 'chmod 700 ' || true)
_hint="${_hint#*chmod 700 }"
eval "set -- $_hint"
assert_eq "chmod hint quotes the path for the shell" "$_odd" "${1:-}"

_link="$TMPDIR/link"
ln -s "$_rt" "$_link"
assert_eq "check refuses a symlink" "1" \
    "$(status_of swarm_runtime_check "$_link")"
assert_eq "init refuses a symlink" "1" \
    "$(status_of swarm_runtime_init "$_link")"
# A trailing slash would make [ -L ] look through the link.
_via_slash=$(SWARM_RUNTIME_DIR="${_link}/" swarm_runtime_dir proj)
assert_eq "trailing slash does not hide a symlink" "1" \
    "$(status_of swarm_runtime_check "$_via_slash")"

_file="$TMPDIR/file"
: > "$_file"
assert_eq "init refuses a regular file" "1" \
    "$(status_of swarm_runtime_init "$_file")"

assert_eq "check refuses a missing directory" "1" \
    "$(status_of swarm_runtime_check "$TMPDIR/missing")"

if [ "$(id -u)" != 0 ]; then
    assert_contains "check refuses a directory owned by another user" \
        "owned by another user" \
        "$(swarm_runtime_check /usr 2>&1 || true)"
else
    echo "  SKIP: ownership check (running as root)"
fi

# ============================================================
echo ""
echo "=== 2b. macOS ACLs ==="

# macOS checks ACL entries before the mode bits, so an "allow" entry
# opens a mode 700 directory, and a new directory inherits entries from
# its parent whatever the umask.
if [ "$(uname -s)" = Darwin ]; then
    _acl="$TMPDIR/acl"
    mkdir -m 700 "$_acl"
    chmod +a "everyone allow search" "$_acl"
    assert_eq "check refuses an allow ACL on a mode 700 directory" "1" \
        "$(status_of swarm_runtime_check "$_acl")"
    assert_contains "ACL error names the fix" "chmod -N" \
        "$(swarm_runtime_check "$_acl" 2>&1 || true)"

    # GNU ls from coreutils first in PATH must not hide the ACL.
    _gnu_ls="$TMPDIR/gnu-ls"
    mkdir -p "$_gnu_ls"
    printf '#!/bin/sh\necho "ls: invalid option -- e" >&2\nexit 2\n' \
        > "$_gnu_ls/ls"
    chmod +x "$_gnu_ls/ls"
    assert_eq "a different ls in PATH does not hide the ACL" "1" \
        "$(PATH="$_gnu_ls:$PATH" status_of swarm_runtime_check "$_acl")"

    # A failed ACL read is a refusal, not an empty ACL.
    _acl_read_rc=$(
        # Stands in for /bin/ls failing; swarm_runtime_check calls it.
        # shellcheck disable=SC2329
        swarm_acl_entries() { return 1; }
        status_of swarm_runtime_check "$_rt"
    )
    assert_eq "an unreadable ACL is refused" "1" "$_acl_read_rc"

    _acl_parent="$TMPDIR/acl-parent"
    mkdir -m 700 "$_acl_parent"
    chmod +a "everyone allow list,search,add_subdirectory,directory_inherit" \
        "$_acl_parent"
    _acl_new="$_acl_parent/state/proj"
    assert_eq "init refuses to create below an inheriting allow ACL" "1" \
        "$(status_of swarm_runtime_init "$_acl_new")"
    assert_eq "nothing is created below that ACL" "false" \
        "$([ -e "$_acl_parent/state" ] && echo true || echo false)"

    # A symlink among the ancestors must not hide the ACL of the
    # directory it points to.
    ln -s "$_acl_parent" "$TMPDIR/acl-link"
    assert_eq "init refuses a path through a symlinked ancestor" "1" \
        "$(status_of swarm_runtime_init "$TMPDIR/acl-link/new/proj")"
    assert_eq "nothing is created through that symlink" "false" \
        "$([ -e "$_acl_parent/new" ] && echo true || echo false)"
    # ".." after a symlink is resolved on the physical path.
    mkdir -p "$_acl_parent/inner"
    ln -s "$_acl_parent/inner" "$TMPDIR/acl-inner-link"
    assert_eq "init refuses symlink/.. into the ACL directory" "1" \
        "$(status_of swarm_runtime_init "$TMPDIR/acl-inner-link/../up/proj")"
    assert_eq "nothing is created through symlink/.." "false" \
        "$([ -e "$_acl_parent/up" ] && echo true || echo false)"

    _acl_deny="$TMPDIR/acl-deny"
    mkdir -m 700 "$_acl_deny"
    chmod +a "everyone deny delete" "$_acl_deny"
    assert_eq "check accepts a deny-only ACL" "0" \
        "$(status_of swarm_runtime_check "$_acl_deny")"
    # The deny entry would stop the cleanup trap from removing it.
    chmod -N "$_acl_deny"
else
    echo "  SKIP: ACL checks (macOS only)"
fi

# ============================================================
echo ""
echo "=== 2c. ACL matching does not depend on pipe timing ==="

# A `| grep -q` pipeline can end on SIGPIPE under pipefail and read as
# "no match".  Feed a long listing with the matching entry first, many
# times over, with mkdir stubbed to record any creation attempt.
_big_acl=" 0: group:everyone allow list,search,directory_inherit"
for _i in $(seq 1 300); do
    _big_acl="${_big_acl}
 ${_i}: user:u${_i} allow list,search,file_inherit,directory_inherit"
done
_mk_log="$TMPDIR/mkdir-calls"
: > "$_mk_log"
_big_rc=$(
    set -o pipefail
    # Stand-ins: swarm_runtime_init calls both.
    # shellcheck disable=SC2329
    swarm_acl_entries() { printf '%s\n' "$_big_acl"; }
    # shellcheck disable=SC2329
    mkdir() { echo "$*" >> "$_mk_log"; }
    _fails=0
    for _i in $(seq 1 40); do
        if swarm_runtime_init "$TMPDIR/big/run${_i}" 2>/dev/null; then
            _fails=$((_fails + 1))
        fi
    done
    printf '%s' "$_fails"
)
assert_eq "inheritable allow entry stops init every time" "0" "$_big_rc"
assert_eq "mkdir is never called" "" "$(cat "$_mk_log")"
_big_check=$(
    set -o pipefail
    # shellcheck disable=SC2329
    swarm_acl_entries() { printf '%s\n' "$_big_acl"; }
    _passes=0
    for _i in $(seq 1 40); do
        if swarm_runtime_check "$_rt" 2>/dev/null; then
            _passes=$((_passes + 1))
        fi
    done
    printf '%s' "$_passes"
)
assert_eq "allow entry fails the check every time" "0" "$_big_check"

# Matching must not need temporary storage: Bash 3.2 backs here-strings
# and here-documents with a file, and a failure to create it would read
# as "no match".  Bash falls back to /tmp when TMPDIR is not writable,
# so the failure cannot be staged here without root; check the body.
_acl_allows_body=$(type swarm_acl_allows)
assert_eq "swarm_acl_allows uses no here-string or here-document" "0" \
    "$(printf '%s\n' "$_acl_allows_body" | grep -c '<<' || true)"
assert_eq "allow entry is found in a long listing" "0" \
    "$(status_of swarm_acl_allows "$_big_acl")"
assert_eq "deny-only listing has no allow entry" "1" \
    "$(status_of swarm_acl_allows " 0: group:everyone deny delete")"
assert_eq "allow without inheritance is not inheritable" "1" \
    "$(status_of swarm_acl_allows " 0: group:everyone allow search" inherit)"

# ============================================================
echo ""
echo "=== 3. Portable mode helper ==="

_m="$TMPDIR/modes"
mkdir -m 750 "$_m"
assert_eq "mode 750" "750" "$(swarm_file_mode "$_m")"
chmod 700 "$_m"
assert_eq "mode 700" "700" "$(swarm_file_mode "$_m")"

# ============================================================
echo ""
echo "=== 4. Legacy /tmp state is refused ==="

_legacy_project="swarmtest-legacy-$$"
assert_eq "no legacy state passes" "0" \
    "$(status_of swarm_refuse_legacy_state "$_legacy_project")"

LEGACY_BARE="/tmp/${_legacy_project}-upstream.git"
mkdir -p "$LEGACY_BARE"
assert_eq "legacy bare repo is refused" "1" \
    "$(status_of swarm_refuse_legacy_state "$_legacy_project")"
_legacy_msg=$(swarm_refuse_legacy_state "$_legacy_project" 2>&1 || true)
assert_contains "message shows how to fetch the old refs" \
    "git fetch ${LEGACY_BARE}" "$_legacy_msg"
assert_contains "message stops old containers with the stop grace" \
    "  docker stop -t ${SWARM_STOP_TIMEOUT:-60} <container>..." \
    "$_legacy_msg"
assert_eq "legacy state is left in place" "true" \
    "$([ -d "$LEGACY_BARE" ] && echo true || echo false)"

# Run a printed removal line.  The docker stub runs on this host the
# command that the alpine container would run.
run_removal() {
    bash -c 'docker() {
        while [ "$#" -gt 0 ] && [ "$1" != alpine ]; do shift; done
        shift
        "$@"
    }
    eval "$1"' _ "$1"
}

# The printed removal command lists existing paths, with no glob that
# zsh would reject when nothing matches.  It goes through Docker, since
# agents wrote files there as another user.
_rm_prefix="  docker run --rm -v /tmp:/tmp alpine rm -rf"
_legacy_rm=$(printf '%s\n' "$_legacy_msg" | grep '^  docker run ' || true)
assert_eq "removal command names the old bare repo" \
    "${_rm_prefix} ${LEGACY_BARE}" "$_legacy_rm"
run_removal "$_legacy_rm"
assert_eq "printed command removes the old state" "0" \
    "$(status_of swarm_refuse_legacy_state "$_legacy_project")"

LEGACY_MIRROR="/tmp/${_legacy_project}-mirror-lib.git"
mkdir -p "$LEGACY_BARE" "$LEGACY_MIRROR"
_legacy_rm=$(swarm_refuse_legacy_state "$_legacy_project" 2>&1 \
    | grep '^  docker run ' || true)
assert_eq "removal command names existing mirrors too" \
    "${_rm_prefix} ${LEGACY_BARE} ${LEGACY_MIRROR}" "$_legacy_rm"
run_removal "$_legacy_rm"
assert_eq "old mirror is removed" "false" \
    "$([ -e "$LEGACY_MIRROR" ] && echo true || echo false)"
mkdir -p "$LEGACY_BARE"

# Anyone can create a path in /tmp.  Only a directory the user owns
# can be old swarm state; anything else must not block the user.
rm -rf "$LEGACY_BARE"
ln -s "$TMPDIR" "$LEGACY_BARE"
assert_eq "symlink at the legacy path is ignored" "0" \
    "$(status_of swarm_refuse_legacy_state "$_legacy_project")"
rm -f "$LEGACY_BARE"
: > "$LEGACY_BARE"
assert_eq "file at the legacy path is ignored" "0" \
    "$(status_of swarm_refuse_legacy_state "$_legacy_project")"
rm -f "$LEGACY_BARE"

# The removal command for a runtime bare repo mounts only the runtime
# directory, as one argument even with a space in it, and removes only
# the bare repo there.
_rm_dir="$TMPDIR/run time"
_rm_args=$(bash -c 'docker() { printf "<%s>\n" "$@"; }; eval "$1"' _ \
    "$(swarm_bare_rm_command "$_rm_dir")")
assert_eq "bare removal mounts the runtime directory only" "<run>
<--rm>
<-v>
<${_rm_dir}:/runtime>
<alpine>
<rm>
<-rf>
</runtime/upstream.git>" "$_rm_args"

# ============================================================
echo ""
echo "=== 5. State file ==="

# Print "refused" when a command fails, "accepted" otherwise.
verdict_of() {
    if "$@" >/dev/null 2>&1; then
        printf 'accepted'
    else
        printf 'refused'
    fi
}

_sf_dir="$TMPDIR/state-rt"
mkdir -m 700 "$_sf_dir"
_sf="$_sf_dir/state.json"
_sf_json='{"schema":"swarm-core.state/v1","title":"t"}'
(umask 022 && swarm_state_write "$_sf" "$_sf_json")
assert_eq "state file is mode 600 despite umask 022" "600" \
    "$(swarm_file_mode "$_sf")"
assert_eq "state file round trip" "$_sf_json" "$(swarm_state_read "$_sf")"
swarm_state_write "$_sf" '{"schema":"swarm-core.state/v1","title":"u"}'
assert_eq "write replaces the file" "u" \
    "$(swarm_state_read "$_sf" | jq -r .title)"
assert_eq "no temporary file is left" "state.json" "$(ls "$_sf_dir")"

printf '%s\n' '{"schema":"other/v1"}' > "$_sf"
assert_eq "another schema is refused" "refused" \
    "$(verdict_of swarm_state_read "$_sf")"
printf '%s\n' '[{"schema":"swarm-core.state/v1"}]' > "$_sf"
assert_eq "a non-object is refused" "refused" \
    "$(verdict_of swarm_state_read "$_sf")"
printf '%s\n%s\n' "$_sf_json" "$_sf_json" > "$_sf"
assert_eq "two objects are refused" "refused" \
    "$(verdict_of swarm_state_read "$_sf")"
printf 'SWARM_TITLE="x"\n' > "$_sf"
assert_eq "the old env format is refused" "refused" \
    "$(verdict_of swarm_state_read "$_sf")"
: > "$_sf"
assert_eq "an empty file is refused" "refused" \
    "$(verdict_of swarm_state_read "$_sf")"

# ============================================================
echo ""
echo "=== 6. Project identity ==="

assert_eq "default id is the sanitized basename" "my-repo" \
    "$(env -u SWARM_PROJECT bash -c 'source "$1"; swarm_project_resolve "$2"' \
        _ "$TESTS_DIR/../lib/project.sh" "/src/My Repo")"
assert_eq "SWARM_PROJECT sets the id" "proj-b" \
    "$(SWARM_PROJECT=proj-b swarm_project_resolve /src/proj)"
assert_eq "SWARM_PROJECT must already be an id" "1" \
    "$(SWARM_PROJECT="Proj B" status_of swarm_project_resolve /src/proj)"
assert_contains "the error suggests the id form" "proj-b" \
    "$(SWARM_PROJECT="Proj B" swarm_project_resolve /src/proj 2>&1 || true)"

_own_a="$TMPDIR/own/a/proj"
_own_b="$TMPDIR/own/b/proj"
_own_rt="$TMPDIR/own-rt"
mkdir -p "$_own_a" "$_own_b"
mkdir -m 700 "$_own_rt"
swarm_runtime_claim "$_own_rt" "$_own_a" proj
assert_eq "claim records the owner" "$(cd -P "$_own_a" && pwd -P)" \
    "$(jq -r .repo_root "$_own_rt/state.json")"
assert_eq "claim records the project id" "proj" \
    "$(jq -r .project "$_own_rt/state.json")"
assert_eq "claim keeps the schema" "swarm-core.state/v1" \
    "$(jq -r .schema "$_own_rt/state.json")"
assert_eq "the owner can claim again" "0" \
    "$(status_of swarm_runtime_claim "$_own_rt" "$_own_a" proj)"
ln -s "$_own_a" "$TMPDIR/own/a-link"
assert_eq "the owner through a symlinked path is the same checkout" "0" \
    "$(status_of swarm_runtime_owner_check "$_own_rt" \
        "$TMPDIR/own/a-link" proj)"
assert_eq "another checkout is refused" "1" \
    "$(status_of swarm_runtime_claim "$_own_rt" "$_own_b" proj)"
_own_msg=$(swarm_runtime_owner_check "$_own_rt" "$_own_b" proj 2>&1 || true)
assert_contains "the refusal names SWARM_PROJECT" "SWARM_PROJECT" "$_own_msg"
assert_contains "the refusal names the owner" \
    "$(cd -P "$_own_a" && pwd -P)" "$_own_msg"
assert_eq "a refused claim leaves the owner alone" \
    "$(cd -P "$_own_a" && pwd -P)" "$(jq -r .repo_root "$_own_rt/state.json")"

swarm_state_update "$_own_rt/state.json" '.title = $t' --arg t "run 1"
assert_eq "an update keeps the owner" "$(cd -P "$_own_a" && pwd -P)" \
    "$(jq -r .repo_root "$_own_rt/state.json")"
assert_eq "an update sets the field" "run 1" \
    "$(jq -r .title "$_own_rt/state.json")"

printf 'SWARM_TITLE="x"\n' > "$_own_rt/state.json"
assert_eq "an unreadable state file is refused" "1" \
    "$(status_of swarm_runtime_owner_check "$_own_rt" "$_own_a" proj)"
assert_eq "an unreadable state file is not overwritten" "1" \
    "$(status_of swarm_runtime_claim "$_own_rt" "$_own_a" proj)"

assert_eq "verify accepts a missing runtime" "0" \
    "$(status_of swarm_runtime_verify "$TMPDIR/none" "$_own_a" proj)"
assert_eq "verify does not create it" "false" \
    "$([ -e "$TMPDIR/none" ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 6b. Container owners ==="

_ctr_root="$(cd -P "$_own_a" && pwd -P)"
# Print docker ps lines in the JSON form swarm_containers_verify asks
# for, from "name project owner" triples.
ctr_listing() {
    while [ $# -gt 0 ]; do
        jq -nc --arg n "$1" --arg p "$2" --arg o "$3" \
            '{name: $n, project: $p, owner: $o}'
        shift 3
    done
}
containers_verdict() {
    # The docker stub runs inside the functions under test and would see
    # their locals first, so this name carries a prefix of its own.
    local _cv_listing="$1"
    (
        # Stands in for the Docker CLI; swarm_containers_verify calls it.
        # shellcheck disable=SC2329
        docker() { printf '%s\n' "$_cv_listing"; }
        status_of swarm_containers_verify proj "$_own_a"
    )
}
assert_eq "no containers" "0" "$(containers_verdict "")"
assert_eq "own numbered, post and interactive containers" "0" \
    "$(containers_verdict "$(ctr_listing proj-agent-1 proj "$_ctr_root" \
        proj-agent-post proj "$_ctr_root" \
        proj-agent-interactive-x-1 proj "$_ctr_root")")"
assert_eq "a container of another checkout is refused" "1" \
    "$(containers_verdict "$(ctr_listing proj-agent-2 proj /elsewhere/proj)")"
assert_eq "an unlabeled container is refused" "1" \
    "$(containers_verdict "$(ctr_listing proj-agent-post "" "")")"
assert_eq "unlabeled names of other projects are ignored" "0" \
    "$(containers_verdict "$(ctr_listing proj-agent-agent-1 "" "" \
        proj-agent-x "" "" proj-agentx-1 "" "")")"
# Project ids can overlap as names: proj-agent-interactive-tools has a
# container proj-agent-interactive-tools-agent-1.  Its project label
# keeps it out of proj's containers.
assert_eq "a labeled container of an overlapping id is ignored" "0" \
    "$(containers_verdict "$(ctr_listing \
        proj-agent-interactive-tools-agent-1 proj-agent-interactive-tools \
        /elsewhere/tools)")"
_ctr_msg=$(
    # shellcheck disable=SC2329
    docker() { ctr_listing proj-agent-2 proj /elsewhere/proj; }
    swarm_containers_verify proj "$_own_a" 2>&1 || true
)
assert_contains "the refusal names the container" "proj-agent-2" "$_ctr_msg"
assert_contains "the refusal names the owner" "/elsewhere/proj" "$_ctr_msg"
assert_contains "another checkout's containers: use SWARM_PROJECT" \
    "own id with SWARM_PROJECT" "$_ctr_msg"
assert_eq "another checkout's containers: no old-release steps" "0" \
    "$(printf '%s\n' "$_ctr_msg" | grep -c 'older swarm-core' || true)"

# Containers of an older release get the upgrade steps instead: stop
# with the grace, so their agents can still push to /tmp.
_ctr_msg=$(
    # shellcheck disable=SC2329
    docker() { ctr_listing proj-agent-1 "" "" proj-agent-post "" ""; }
    swarm_containers_verify proj "$_own_a" 2>&1 || true
)
assert_contains "old containers: stop them with the grace" \
    "  docker stop -t ${SWARM_STOP_TIMEOUT:-60} proj-agent-1 proj-agent-post" \
    "$_ctr_msg"
assert_contains "old containers: points to the upgrade steps" \
    "Upgrading from" "$_ctr_msg"
assert_eq "old containers: no SWARM_PROJECT advice" "0" \
    "$(printf '%s\n' "$_ctr_msg" | grep -c 'SWARM_PROJECT' || true)"
assert_eq "old containers: no docker rm -f advice" "0" \
    "$(printf '%s\n' "$_ctr_msg" | grep -c 'rm -f' || true)"
assert_eq "a failing docker ps is refused" "1" \
    "$(
        # shellcheck disable=SC2329
        docker() { return 1; }
        status_of swarm_containers_verify proj "$_own_a"
    )"

# Discovery has to find a labeled container whatever its name.  This
# stub honours docker ps filters: label=swarm-core.project=ID matches
# the project label exactly, name=P matches names that contain P.  The
# containers come from FILTER_TABLE lines "name project owner", with
# "-" for an empty field.
filter_docker() {
    local filter="" name project owner
    while [ $# -gt 0 ]; do
        case "$1" in
            --filter) filter="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    printf '%s\n' "$FILTER_TABLE" | while read -r name project owner; do
        [ -n "$name" ] || continue
        project="${project#-}" owner="${owner#-}"
        case "$filter" in
            label=swarm-core.project=*)
                [ "$project" = "${filter#label=swarm-core.project=}" ] \
                    || continue ;;
            name=*)
                case "$name" in
                    *"${filter#name=}"*) ;;
                    *) continue ;;
                esac ;;
        esac
        jq -nc --arg n "$name" --arg p "$project" --arg o "$owner" \
            '{name: $n, project: $p, owner: $o}'
    done
}
filter_verdict() {
    (
        # shellcheck disable=SC2329
        docker() { filter_docker "$@"; }
        status_of swarm_containers_verify proj "$_own_a"
    )
}
FILTER_TABLE="archived-proj proj /elsewhere"
assert_eq "a renamed container of another checkout is found" "1" \
    "$(filter_verdict)"
FILTER_TABLE="proj-agent-1 proj ${_ctr_root}
archived-proj proj ${_ctr_root}"
assert_eq "own containers, renamed or not, pass" "0" "$(filter_verdict)"
FILTER_TABLE="proj-agent-2 - -"
assert_eq "an unlabeled container is found by its name" "1" \
    "$(filter_verdict)"
FILTER_TABLE="other-thing other /x"
assert_eq "an unrelated container is not found" "0" "$(filter_verdict)"

# Name selection is literal: a '.' in the id matches only itself.
_names_out=$(
    # shellcheck disable=SC2329
    docker() {
        ctr_listing a.b-agent-1 a.b /r axb-agent-2 axb /r \
            a.b-agent-post a.b /r a.b-agent-interactive-x a.b /r \
            axb-agent-interactive-y "" "" a.b-agent-agent-3 "" ""
    }
    swarm_project_container_names a.b | tr '\n' ' '
)
assert_eq "project container names are matched literally" \
    "a.b-agent-1 a.b-agent-interactive-x a.b-agent-post " "$_names_out"
_names_out=$(
    # shellcheck disable=SC2329
    docker() {
        ctr_listing app-agent-1 app /r app-agent-interactive-x app /r \
            app-agent-interactive-tools-agent-1 app-agent-interactive-tools /r
    }
    swarm_interactive_container_names app | tr '\n' ' '
)
assert_eq "interactive names exclude an overlapping project's container" \
    "app-agent-interactive-x " "$_names_out"

# swarm_own_container_id: the ID of an own container, nothing for a
# missing one, a refusal for another checkout's or an unlabeled one.
own_id_of() {
    local _oi_labels="$1"
    (
        # shellcheck disable=SC2329
        docker() {
            [ "$_oi_labels" = missing ] && return 1
            printf '{"id":"cid","labels":%s}\n' "$_oi_labels"
        }
        _oi_rc=0
        _oi_out=$(swarm_own_container_id proj-agent-1 "$_ctr_root" proj \
            2>/dev/null) || _oi_rc=$?
        printf '%s:%s' "$_oi_rc" "$_oi_out"
    )
}
assert_eq "own container gives its ID" "0:cid" \
    "$(own_id_of "$(jq -nc --arg o "$_ctr_root" \
        '{"swarm-core.project": "proj", "swarm-core.checkout": $o}')")"
assert_eq "missing container gives nothing" "0:" "$(own_id_of missing)"
assert_eq "another checkout's container is refused" "1:" \
    "$(own_id_of '{"swarm-core.project": "proj",
                   "swarm-core.checkout": "/elsewhere"}')"
assert_eq "another project's container is refused" "1:" \
    "$(own_id_of "$(jq -nc --arg o "$_ctr_root" \
        '{"swarm-core.project": "other", "swarm-core.checkout": $o}')")"
assert_eq "an unlabeled container is refused" "1:" "$(own_id_of null)"

# ============================================================
echo ""
echo "=== 7. Engagement id ==="

for _eid in a eng-1 run.2026_10 "$(printf 'a%.0s' $(seq 1 64))"; do
    assert_eq "valid engagement id: ${_eid:0:12}" "0" \
        "$(status_of swarm_engagement_id_valid "$_eid")"
done
for _eid in "" -a .a "a b" 'a$b' "a/b" "$(printf 'a%.0s' $(seq 1 65))"; do
    assert_eq "invalid engagement id: '${_eid:0:12}'" "1" \
        "$(status_of swarm_engagement_id_valid "$_eid")"
done
# The check is ASCII whatever the locale.  "$BASH" is the shell running
# this file: Bash 3.2 ranges follow the locale, Bash 5 ones do not.
for _loc in en_US.UTF-8 C.UTF-8; do
    for _eid in "é" "İd" "a·b"; do
        assert_eq "non-ASCII id '${_eid}' is refused under ${_loc}" "1" \
            "$(LC_ALL="$_loc" "$BASH" -c \
                'source "$1"; swarm_engagement_id_valid "$2"; echo $?' \
                _ "$TESTS_DIR/../lib/project.sh" "$_eid" 2>/dev/null)"
    done
done
assert_eq "generated id has a time and a random part" "true" \
    "$(env -u SWARM_ENGAGEMENT_ID bash -c \
        'source "$1"; swarm_engagement_new' _ \
        "$TESTS_DIR/../lib/project.sh" \
        | grep -qE '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' \
        && echo true || echo false)"
assert_eq "SWARM_ENGAGEMENT_ID names the new engagement" "eng-1" \
    "$(SWARM_ENGAGEMENT_ID=eng-1 swarm_engagement_new)"
assert_eq "a bad SWARM_ENGAGEMENT_ID is refused" "1" \
    "$(SWARM_ENGAGEMENT_ID="a b" status_of swarm_engagement_env_check)"

_eng_dir="$TMPDIR/eng"
mkdir -m 700 "$_eng_dir"
_eng_file="$_eng_dir/state.json"
assert_eq "joining without a recorded id and no request works" "0" \
    "$(env -u SWARM_ENGAGEMENT_ID bash -c \
        'source "$1"; swarm_engagement_join "$2"' _ \
        "$TESTS_DIR/../lib/project.sh" "$_eng_file" >/dev/null 2>&1; \
       echo $?)"
assert_eq "naming an id while none is recorded is refused" "1" \
    "$(SWARM_ENGAGEMENT_ID=eng-1 status_of swarm_engagement_join \
        "$_eng_file")"
swarm_state_update "$_eng_file" '.engagement_id = $id' --arg id eng-1
assert_eq "the recorded engagement can be joined" "0" \
    "$(SWARM_ENGAGEMENT_ID=eng-1 status_of swarm_engagement_join \
        "$_eng_file")"
assert_eq "joining without naming an id works" "0" \
    "$(env -u SWARM_ENGAGEMENT_ID bash -c \
        'source "$1"; swarm_engagement_join "$2"' _ \
        "$TESTS_DIR/../lib/project.sh" "$_eng_file" >/dev/null 2>&1; \
       echo $?)"
assert_eq "another engagement is refused" "1" \
    "$(SWARM_ENGAGEMENT_ID=eng-2 status_of swarm_engagement_join \
        "$_eng_file")"
assert_eq "an empty SWARM_ENGAGEMENT_ID is not a free pass" "1" \
    "$(SWARM_ENGAGEMENT_ID="" status_of swarm_engagement_join \
        "$_eng_file")"
assert_eq "an empty SWARM_ENGAGEMENT_ID fails the format check" "1" \
    "$(SWARM_ENGAGEMENT_ID="" status_of swarm_engagement_env_check)"
assert_eq "an unset SWARM_ENGAGEMENT_ID passes the format check" "0" \
    "$(env -u SWARM_ENGAGEMENT_ID bash -c \
        'source "$1"; swarm_engagement_env_check' _ \
        "$TESTS_DIR/../lib/project.sh" >/dev/null 2>&1; echo $?)"
assert_contains "the refusal names the recorded engagement" "eng-1" \
    "$(SWARM_ENGAGEMENT_ID=eng-2 swarm_engagement_join "$_eng_file" 2>&1 \
        || true)"

# ============================================================
echo ""
echo "=== 8. Engagement lock ==="

_lk_dir="$TMPDIR/lock-rt"
mkdir -m 700 "$_lk_dir"
_lk_file="$_lk_dir/engagement.lock"
: > "$TMPDIR/other-file"

assert_eq "a free lock is taken" "0" "$(env -u SWARM_LOCK_FD \
    "$BASH" -c 'source "$1"; swarm_lock "$2" && printf %s "$SWARM_LOCK_FD"' \
    _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" >/dev/null 2>&1; echo $?)"
assert_eq "the lock descriptor is exported" "9" \
    "$(env -u SWARM_LOCK_FD "$BASH" -c \
        'source "$1"; swarm_lock "$2" && printf %s "$SWARM_LOCK_FD"' \
        _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" 2>/dev/null)"

# Hold the lock in this shell on descriptor 8.
exec 8>>"$_lk_file"
flock -n 8
assert_eq "another process fails at once while it is held" "1" \
    "$(env -u SWARM_LOCK_FD "$BASH" -c 'source "$1"; swarm_lock "$2"' \
        _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" >/dev/null 2>&1 8>&-; \
       echo $?)"
assert_contains "the refusal names the lock file" "engagement.lock" \
    "$(env -u SWARM_LOCK_FD "$BASH" -c 'source "$1"; swarm_lock "$2"' \
        _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" 2>&1 8>&-)"
assert_eq "a child given SWARM_LOCK_FD=8 shares the held lock" "0" \
    "$(SWARM_LOCK_FD=8 "$BASH" -c 'source "$1"; swarm_lock "$2"' \
        _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" >/dev/null 2>&1; \
       echo $?)"
exec 7>>"$TMPDIR/other-file"
assert_eq "SWARM_LOCK_FD open on another file is refused" "1" \
    "$(SWARM_LOCK_FD=7 "$BASH" -c 'source "$1"; swarm_lock "$2"' \
        _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" >/dev/null 2>&1; \
       echo $?)"
exec 7>&-
assert_eq "SWARM_LOCK_FD that is not open is refused" "1" \
    "$(SWARM_LOCK_FD=6 "$BASH" -c 'source "$1"; swarm_lock "$2"' \
        _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" >/dev/null 2>&1 6>&-; \
       echo $?)"
for _bad in x 1 "8 9"; do
    assert_eq "SWARM_LOCK_FD='${_bad}' is refused" "1" \
        "$(SWARM_LOCK_FD="$_bad" "$BASH" -c 'source "$1"; swarm_lock "$2"' \
            _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" >/dev/null 2>&1; \
           echo $?)"
done
exec 8>&-
assert_eq "the lock is free once the holder closes it" "0" \
    "$(env -u SWARM_LOCK_FD "$BASH" -c 'source "$1"; swarm_lock "$2"' \
        _ "$TESTS_DIR/../lib/project.sh" "$_lk_dir" >/dev/null 2>&1; \
       echo $?)"

_fd_check='source "$1"; exec 5>>"$2"; swarm_fd_is_file 5 "$3"; echo $?'
assert_eq "swarm_fd_is_file: same file" "0" \
    "$("$BASH" -c "$_fd_check" _ "$TESTS_DIR/../lib/project.sh" \
        "$_lk_file" "$_lk_file")"
assert_eq "swarm_fd_is_file: another file" "1" \
    "$("$BASH" -c "$_fd_check" _ "$TESTS_DIR/../lib/project.sh" \
        "$TMPDIR/other-file" "$_lk_file")"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
