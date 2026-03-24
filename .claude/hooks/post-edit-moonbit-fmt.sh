#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook: auto-format .mbt files after Edit/Write
# Reads tool invocation JSON from stdin, formats with moon fmt.

# Read the full stdin JSON
input="$(cat)"

# Extract file path from tool_input.file_path or tool_input.path
file_path="$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')"

# If no file path found, exit silently
if [[ -z "${file_path:-}" ]]; then
  exit 0
fi

# Only act on .mbt files
case "$file_path" in
  *.mbt)
    ;;
  *)
    exit 0
    ;;
esac

# Check if the file actually exists
if [[ ! -f "$file_path" ]]; then
  exit 0
fi

# Check if moon is available
if ! command -v moon &>/dev/null; then
  exit 0
fi

# Find the project root (where moon.mod.json lives)
project_root="$(cd "$(dirname "$file_path")" && git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$project_root" ]] || [[ ! -f "$project_root/moon.mod.json" ]]; then
  exit 0
fi

# Run moon fmt (formats all .mbt files in the project)
fmt_output=""
if ! fmt_output="$(cd "$project_root" && moon fmt 2>&1)"; then
  jq -n --arg msg "moon fmt failed: $fmt_output" \
    '{"hookSpecificOutput": {"additionalContext": $msg}}'
  exit 0
fi

# Verify formatting is clean
check_output=""
if ! check_output="$(cd "$project_root" && moon fmt --check 2>&1)"; then
  jq -n --arg msg "moon fmt: formatting issues remain: $check_output" \
    '{"hookSpecificOutput": {"additionalContext": $msg}}'
fi

exit 0
