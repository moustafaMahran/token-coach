#!/usr/bin/env bash
# token-coach — PostToolUse: silently tally tool-output size. This is the raw
# material for /cost-review's "tool output" attribution. No surface, exit 0.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/tc-common.sh" 2>/dev/null || true

input=$(cat 2>/dev/null)
tc_have_jq || exit 0

sid=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0

# Byte length of the serialised tool output (numbers only — content is never stored).
bytes=$(echo "$input" | jq -r '(.tool_output // "") | tostring | length' 2>/dev/null)
[ -z "$bytes" ] && bytes=0

tc_state_init "$sid"
tc_state_update "$sid" '.tool_output_bytes = ((.tool_output_bytes // 0) + $b)' --argjson b "${bytes:-0}"
exit 0
