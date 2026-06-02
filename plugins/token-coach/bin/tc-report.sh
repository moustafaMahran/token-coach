#!/usr/bin/env bash
# token-coach — session report. Prints a human-readable summary built entirely
# from locally-tracked numbers (no transcript parsing, no content). Invoked by
# the /cost-review slash command, or directly: tc-report.sh [session_id].

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/tc-common.sh" 2>/dev/null || true

tc_have_jq || { echo "token-coach: jq is required for /cost-review."; exit 0; }

sid="${1:-}"
if [ -n "$sid" ]; then
  f=$(tc_state_file "$sid")
else
  f=$(ls -t "$TC_STATE_DIR"/*.json 2>/dev/null | head -1)
fi
[ -n "$f" ] && [ -f "$f" ] || { echo "token-coach: no session data yet (the meter populates it as you work)."; exit 0; }

now=$(tc_now)

IFS=$'\t' read -r cost ctx in_tok out_tok cache_read tool_bytes rereads prompts nudges started <<EOF
$(jq -r '[
  .last_cost_usd, .last_ctx_pct, .in_tokens, .out_tokens, .cache_read_tokens,
  .tool_output_bytes, .reread_count, .prompts, .nudges_fired, .started_at
] | @tsv' "$f" 2>/dev/null)
EOF
baseline=$(tc_baseline)

dur_min=$(( (now - ${started:-now}) / 60 ))
[ "$dur_min" -lt 0 ] 2>/dev/null && dur_min=0

# Cache hit rate ≈ cache reads / total input tokens.
cache_pct=0
if [ "${in_tok:-0}" -gt 0 ] 2>/dev/null; then
  cache_pct=$(echo "scale=0; ${cache_read:-0} * 100 / ${in_tok}" | bc 2>/dev/null)
fi

files_total=$(jq -r '.files_read | length' "$f" 2>/dev/null)
files_reread=$(jq -r '[.files_read[] | select(.count > 1)] | length' "$f" 2>/dev/null)
tool_kb=$(echo "scale=0; ${tool_bytes:-0}/1024" | bc 2>/dev/null)

hum() {
  local n="${1:-0}"
  if [ "$n" -ge 1000000 ] 2>/dev/null; then echo "$(echo "scale=1;$n/1000000"|bc)M"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then echo "$(echo "$n/1000"|bc)k"
  else echo "$n"; fi
}

# Nudge breakdown by reason.
nudge_breakdown=$(jq -r '
  (.nudge_log // []) | group_by(.reason)
  | map("\(.[0].reason): \(length)") | join("   ")' "$f" 2>/dev/null)

echo "───────────────  token-coach: session review  ───────────────"
printf ' Duration %sm   │   Cost $%s   │   Prompts %s\n' "$dur_min" "${cost:-0}" "${prompts:-0}"
printf ' Tokens: ↑ %s in   ↓ %s out   │   cache hit ~%s%%   │   ctx %s%%\n' \
  "$(hum "${in_tok:-0}")" "$(hum "${out_tok:-0}")" "${cache_pct:-0}" "${ctx:-0}"
echo
echo " Observed activity"
printf '   • files read .............. %s   (re-read: %s)\n' "${files_total:-0}" "${files_reread:-0}"
printf '   • tool output captured ..... %s KB\n' "${tool_kb:-0}"
printf '   • coaching signals ......... %s fired\n' "${nudges:-0}"
[ -n "$nudge_breakdown" ] && printf '        %s\n' "$nudge_breakdown"
echo

# Recommendations, derived from the numbers.
echo " Suggestions for next time"
hint=0
if [ "${files_reread:-0}" -gt 0 ] 2>/dev/null; then
  echo "   ① ${files_reread} file(s) read more than once — they were already in context."; hint=1
fi
if [ "$(echo "${ctx:-0} >= 75" | bc -l 2>/dev/null)" = 1 ]; then
  echo "   ② context is at ${ctx}% — /clear or /compact between unrelated tasks."; hint=1
fi
if [ "${cache_pct:-100}" -lt 50 ] 2>/dev/null && [ "${in_tok:-0}" -gt 50000 ] 2>/dev/null; then
  echo "   ③ cache hit rate is low (~${cache_pct}%) — long idle gaps evict the cache."; hint=1
fi
if [ "${tool_kb:-0}" -gt 200 ] 2>/dev/null; then
  echo "   ④ ${tool_kb} KB of tool output — scope commands (head/tail/-n/--quiet)."; hint=1
fi
[ "$hint" = 0 ] && echo "   ✓ nothing notable — lean session."
echo

if [ "${baseline}" = "true" ]; then
  echo " (baseline mode: signals are logged but not shown live. Flip baselineMode"
  echo "  to false in your config to enable real-time nudges on the status line.)"
  echo "──────────────────────────────────────────────────────────────"
fi
exit 0
