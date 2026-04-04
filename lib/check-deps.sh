#!/bin/bash
# Verify that required external tools are installed and warn
# when versions fall outside the tested range.
# Source this file and call check_deps with the list of commands.

# Minimum tested versions. Values are compared numerically
# (major.minor only).  Update when CI confirms a new range.
_TESTED_VERSIONS=(
    "bash:5.0"
    "git:2.30"
    "jq:1.6"
    "docker:24.0"
)

check_deps() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: Missing required tools: ${missing[*]}" >&2
        echo "Install them and retry. See README.md prerequisites." >&2
        exit 1
    fi

    if [ "${SWARM_SKIP_DEP_CHECK:-}" = "1" ]; then
        return
    fi

    for entry in "${_TESTED_VERSIONS[@]}"; do
        local cmd="${entry%%:*}"
        local min="${entry#*:}"
        command -v "$cmd" &>/dev/null || continue
        local ver
        ver=$(_dep_version "$cmd") || continue
        if ! _ver_ge "$ver" "$min"; then
            echo "WARNING: ${cmd} ${ver} is below tested ${min}." \
                "Set SWARM_SKIP_DEP_CHECK=1 to silence." >&2
        fi
    done
}

# Extract major.minor version from a command.
_dep_version() {
    local raw
    case "$1" in
        bash)   raw="${BASH_VERSION:-}" ;;
        git)    raw=$(git --version 2>/dev/null) ;;
        jq)     raw=$(jq --version 2>/dev/null) ;;
        docker) raw=$(docker --version 2>/dev/null) ;;
        *)      return 1 ;;
    esac
    # Strip to first dotted number pair.
    echo "$raw" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# Return 0 if $1 >= $2 (major.minor comparison).
_ver_ge() {
    local a_maj a_min b_maj b_min
    IFS='.' read -r a_maj a_min <<< "$1"
    IFS='.' read -r b_maj b_min <<< "$2"
    a_maj="${a_maj:-0}"; a_min="${a_min:-0}"
    b_maj="${b_maj:-0}"; b_min="${b_min:-0}"
    if [ "$a_maj" -gt "$b_maj" ]; then return 0; fi
    if [ "$a_maj" -eq "$b_maj" ] && [ "$a_min" -ge "$b_min" ]; then
        return 0
    fi
    return 1
}
