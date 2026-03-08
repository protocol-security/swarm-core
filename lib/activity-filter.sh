#!/bin/bash
set -euo pipefail

# Reads stream-json (JSONL) from stdin and prints human-readable
# activity summaries to stdout.  Designed to be used with:
#
#   claude ... --output-format stream-json | tee "$LOG" | activity-filter.sh
#
# Each tool_use content block becomes one full-line ANSI
# yellow output (matching harness green for visual contrast):
#   \033[33m12:34:56   agent[1] Read src/main.ts\033[0m
#   \033[33m12:35:01   agent[1] Shell: npm test\033[0m
#
# Uses a single jq invocation for efficiency (no per-line fork).

AGENT_ID="${AGENT_ID:-?}"

exec jq --unbuffered --raw-input --arg id "$AGENT_ID" -r '
  def truncate(n):
    if length > n then .[:n-3] + "..." else . end;

  def first_line:
    split("\n")[0] // .;

  def ts:
    now | strftime("%H:%M:%S");

  def prefix:
    "\u001b[33m\(ts)   agent[\($id)]";

  def reset:
    "\u001b[0m";

  fromjson? // empty |
  select(.type == "assistant") |
  .message.content[]? |
  select(.type == "tool_use") |
  if   .name == "Bash"  then "\(prefix) Shell: " + ((.input.command // "") | first_line | truncate(80)) + reset
  elif .name == "Read"  then "\(prefix) Read "  + (.input.file_path // .input.path // "") + reset
  elif .name == "Write" then "\(prefix) Write " + (.input.file_path // .input.path // "") + reset
  elif .name == "Edit"  then "\(prefix) Edit "  + (.input.file_path // .input.path // "") + reset
  elif .name == "MultiEdit" then "\(prefix) MultiEdit " + (.input.file_path // .input.path // "") + reset
  elif .name == "Glob"  then "\(prefix) Glob "  + (.input.pattern // "") + reset
  elif .name == "Grep"  then "\(prefix) Grep "  + (.input.pattern // "") + reset
  elif .name == "Task"  then "\(prefix) Task: " + ((.input.description // .input.prompt // "") | first_line | truncate(60)) + reset
  else "\(prefix) " + .name + reset
  end
'
