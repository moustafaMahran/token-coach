#!/usr/bin/env bash
# token-coach — PreToolUse(Bash): flag commands that tend to dump huge output
# into the context window. Observe-only; never blocks (exit 0).

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/tc-common.sh" 2>/dev/null || true

input=$(cat 2>/dev/null)
tc_have_jq || exit 0
[ "$(tc_cfg '.wasteSniffer.enabled' true)" = "true" ] || exit 0

sid=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0
[ -z "$cmd" ] && exit 0
tc_state_init "$sid"

low=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
nudge=""

# Already scoped? (a limit, a pager, or head/tail present) → don't nag.
is_scoped() { printf '%s' "$low" | grep -qE '(\| *(head|tail|grep|wc)| -n +[0-9]|--max-count|--oneline|-[0-9]+|--quiet| -q\b|--silent)'; }

case "$low" in
  *"git log"*)
    is_scoped || nudge="unbounded \`git log\` can dump thousands of lines — add -n / --oneline" ;;
  *"find /"*|*"find / "*)
    nudge="\`find /\` scans the whole filesystem — narrow the path" ;;
  *"cat "*)
    is_scoped || nudge="\`cat\` of a whole file lands in context — prefer a range or grep" ;;
  *"rspec"*|*"jest"*|*"pytest"*|*"npm test"*|*"pnpm test"*)
    is_scoped || nudge="full test run output is heavy — scope to one file/spec or add a quiet flag" ;;
  *"docker logs"*|*"kubectl logs"*|*"journalctl"*)
    is_scoped || nudge="log dumps are heavy — add --tail / a line limit" ;;
esac

[ -n "$nudge" ] && tc_record_nudge "$sid" "bashoutput" "$nudge"
exit 0
