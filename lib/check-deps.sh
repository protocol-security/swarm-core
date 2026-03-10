#!/bin/bash
# Verify that required external tools are installed.
# Source this file and call check_deps with the list of commands.

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
}
