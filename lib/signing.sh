#!/bin/bash
# Git SSH commit-signing config, driven by file existence.
#
# When the source key exists, copy it to a swarm-owned scratch
# location with 0600 perms and point git at the copy.  ssh-keygen
# -Y sign refuses world-readable keys with "UNPROTECTED PRIVATE
# KEY FILE", and the bind-mounted /etc/swarm/signing_key inherits
# host perms (often 0644 for shared swarm-bot keys).  Without
# this copy, signing fails inside the container, and Codex CLI
# reacts by silently passing --no-gpg-sign on its retry
# (openai/codex#6199), so commits land without a signature.
#
# The destination lives outside $HOME on purpose.  $HOME is the
# agent's namespace, not the harness's.  Default is /dev/shm
# (tmpfs, RAM-backed, per-container in Docker) so the private
# key bytes never hit disk; 0600 perms keep it from other users.
#
# Sourced by lib/harness.sh inside the container (source key
# at /etc/swarm/signing_key) and by tests/test_harness.sh with
# a sandbox path.

configure_git_signing() {
    local src_key="${1:-/etc/swarm/signing_key}"
    local dst_key="${2:-/dev/shm/swarm-signing-key}"
    if [ -f "$src_key" ]; then
        # Fail-fast on install errors (missing /dev/shm, full
        # tmpfs, perms): otherwise user.signingkey would point
        # at a non-existent file and every later commit would
        # silently fail to sign.
        install -m 0600 "$src_key" "$dst_key" || return 1
        git config --global gpg.format ssh
        git config --global user.signingkey "$dst_key"
        git config --global commit.gpgsign true
    else
        git config --global commit.gpgsign false
    fi
}
