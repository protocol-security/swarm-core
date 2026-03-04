#!/bin/bash
set -euo pipefail

# Reads stream-json (JSONL) from stdin and prints human-readable
# activity summaries to stdout.  Designed to be used with:
#
#   claude ... --output-format stream-json | tee "$LOG" | activity-filter.sh
#
# Each tool_use content block becomes one line:
#   [agent:1] Read src/main.ts
#   [agent:1] Write src/main.ts
#   [agent:1] Edit src/main.ts
#   [agent:1] Shell: npm test
#   [agent:1] Glob *.ts
#
# Uses a single jq invocation for efficiency (no per-line fork).

AGENT_ID="${AGENT_ID:-?}"

exec jq --unbuffered --raw-input --arg id "$AGENT_ID" -r '
  def truncate(n):
    if length > n then .[:n-3] + "..." else . end;

  def first_line:
    split("\n")[0] // .;

  fromjson? // empty |
  select(.type == "assistant") |
  .message.content[]? |
  select(.type == "tool_use") |
  if   .name == "Bash"  then "[agent:\($id)] Shell: " + ((.input.command // "") | first_line | truncate(80))
  elif .name == "Read"  then "[agent:\($id)] Read "  + (.input.file_path // .input.path // "")
  elif .name == "Write" then "[agent:\($id)] Write " + (.input.file_path // .input.path // "")
  elif .name == "Edit"  then "[agent:\($id)] Edit "  + (.input.file_path // .input.path // "")
  elif .name == "MultiEdit" then "[agent:\($id)] MultiEdit " + (.input.file_path // .input.path // "")
  elif .name == "Glob"  then "[agent:\($id)] Glob "  + (.input.pattern // "")
  elif .name == "Grep"  then "[agent:\($id)] Grep "  + (.input.pattern // "")
  elif .name == "Task"  then "[agent:\($id)] Task: " + ((.input.description // .input.prompt // "") | first_line | truncate(60))
  else "[agent:\($id)] " + .name
  end
'
