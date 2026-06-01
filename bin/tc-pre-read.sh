#!/usr/bin/env bash
# token-coach — PreToolUse(Read): track file reads, flag re-reads and huge reads.
# Observe-only: records to state and (outside baseline) surfaces a nudge. Never
# blocks — always exits 0.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/tc-common.sh" 2>/dev/null || true

input=$(cat 2>/dev/null)
tc_have_jq || exit 0

[ "$(tc_cfg '.wasteSniffer.enabled' true)" = "true" ] || exit 0

sid=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
file=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0
[ -z "$file" ] && exit 0
tc_state_init "$sid"

f=$(tc_state_file "$sid")
prev=$(jq -r --arg f "$file" '.files_read[$f].count // 0' "$f" 2>/dev/null)
[ -z "$prev" ] && prev=0

# Increment the per-file read counter.
tc_state_update "$sid" \
  '.files_read[$f].count = ((.files_read[$f].count // 0) + 1)' --arg f "$file"

base=$(basename "$file")

# Re-read of a file already in context.
if [ "$prev" -ge 1 ] 2>/dev/null && [ "$(tc_cfg '.wasteSniffer.rereadGuard' true)" = "true" ]; then
  tc_state_update "$sid" '.reread_count=(.reread_count+1)'
  tc_record_nudge "$sid" "reread" "re-reading ${base} (already in context)"
  exit 0
fi

# Whole-file read of a large file.
if [ -f "$file" ]; then
  flines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  huge=$(tc_cfg '.wasteSniffer.hugeReadLines' 1000)
  if [ "${flines:-0}" -ge "$huge" ] 2>/dev/null; then
    tc_record_nudge "$sid" "hugeread" "reading ${base} (${flines} lines) — a range/grep is cheaper"
  fi
fi
exit 0
