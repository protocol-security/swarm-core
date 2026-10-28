#!/bin/bash

# Keep test behavior independent of host Git settings.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_COUNT=0
unset GIT_CONFIG GIT_CONFIG_PARAMETERS

# Keep it independent of the caller's swarm-core settings too.
unset SWARM_PROJECT SWARM_RUNTIME_DIR SWARM_ENGAGEMENT_ID
