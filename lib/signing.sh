#!/bin/bash
# Git SSH commit-signing config, driven by file existence.
#
# When the key file exists, enable SSH-format signing and point
# git at the key.  Otherwise, disable signing.  Writes to the
# global git config so subsequent `git commit` invocations pick
# it up without per-repo plumbing.
#
# Sourced by lib/harness.sh inside the container (key at
# /etc/swarm/signing_key) and by tests/test_harness.sh with a
# sandbox path.

configure_git_signing() {
    local key_path="${1:-/etc/swarm/signing_key}"
    if [ -f "$key_path" ]; then
        git config --global gpg.format ssh
        git config --global user.signingkey "$key_path"
        git config --global commit.gpgsign true
    else
        git config --global commit.gpgsign false
    fi
}
