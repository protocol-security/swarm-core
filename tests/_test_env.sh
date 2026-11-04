#!/bin/bash

# Keep test behavior independent of host Git settings.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_COUNT=0
unset GIT_CONFIG GIT_CONFIG_PARAMETERS

# Keep it independent of the caller's swarm-core settings too.
unset SWARM_PROJECT SWARM_RUNTIME_DIR SWARM_ENGAGEMENT_ID SWARM_LOCK_FD

# Succeed when a job started under job control can be stopped by
# SIGINT: not when the test started with SIGINT ignored (a background
# job of a script), since the ignore is inherited and cannot be undone.
# Bash 3.2 does not report such an ignore through trap -p, so this
# tries it.  Call it in a subshell, (sigint_works): job control
# switched on in the test's own shell would stay with it on Bash 3.2.
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
