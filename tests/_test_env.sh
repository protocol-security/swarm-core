#!/bin/bash

# Keep test behavior independent of host Git settings.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_COUNT=0
unset GIT_CONFIG GIT_CONFIG_PARAMETERS
