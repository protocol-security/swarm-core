#!/bin/bash
# Run bin/progress.sh, where this command lives now.  This wrapper keeps
# the old path working and goes away in a later release.
exec "$(dirname "$0")/bin/progress.sh" "$@"
