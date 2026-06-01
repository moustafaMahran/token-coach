#!/usr/bin/env bash
# token-coach — the budget meter.
#
# Reads the status-line JSON on stdin and prints ONE line. It must always print
# something and exit 0: a status line that errors or hangs breaks the Claude
# Code UI. It also persists a snapshot (cost, context %, tokens) to the session
# state file, because the hook events do NOT carry token counts — this is the
# only place those numbers are available.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/tc-common.sh" 2>/dev/null || true

input=$(cat 2>/dev/null)
tc_have_jq || { echo "token-coach (install jq to enable the meter)"; exit 0; }

get() { echo "$input" | jq -r "$1 // empty" 2>/dev/null; }

sid=$(get '.session_id')
model=$(get '.model.display_name'); [ -z "$model" ] && model=$(get '.model.id')
[ -z "$model" ] && model="claude"
cost=$(get '.cost.total_cost_usd');                              [ -z "$cost" ] && cost=0
ctx=$(get '.context_window.used_percentage');                   [ -z "$ctx" ] && ctx=0
in_tok=$(get '.context_window.total_input_tokens');             [ -z "$in_tok" ] && in_tok=0
out_tok=$(get '.context_window.total_output_tokens');           [ -z "$out_tok" ] && out_tok=0
cache_read=$(get '.context_window.current_usage.cache_read_input_tokens'); [ -z "$cache_read" ] && cache_read=0

# Persist the snapshot so hooks + /cost-review can read live cost/context.
if [ -n "$sid" ]; then
  tc_state_init "$sid"
  tc_state_update "$sid" \
    '.last_cost_usd=$c | .last_ctx_pct=$p | .in_tokens=$i | .out_tokens=$o | .cache_read_tokens=$cr' \
    --argjson c "${cost:-0}" --argjson p "${ctx:-0}" \
    --argjson i "${in_tok:-0}" --argjson o "${out_tok:-0}" --argjson cr "${cache_read:-0}"
fi

amber=$(tc_cfg '.statusline.amber_ctx' 70)
red=$(tc_cfg '.statusline.red_ctx' 85)

ESC=$(printf '\033')
R="${ESC}[0m"; DIM="${ESC}[2m"; GRN="${ESC}[32m"; YEL="${ESC}[33m"; RED="${ESC}[31m"; CYN="${ESC}[36m"

ge() { [ "$(echo "${1:-0} >= ${2:-0}" | bc -l 2>/dev/null)" = 1 ]; }

ctxcol=$GRN
if ge "$ctx" "$red"; then ctxcol=$RED; elif ge "$ctx" "$amber"; then ctxcol=$YEL; fi

# 10-cell context bar.
filled=$(echo "($ctx/10)+0.5" | bc -l 2>/dev/null | cut -d. -f1); [ -z "$filled" ] && filled=0
[ "$filled" -gt 10 ] 2>/dev/null && filled=10
[ "$filled" -lt 0 ] 2>/dev/null && filled=0
bar=""; i=0
while [ "$i" -lt 10 ]; do
  if [ "$i" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
  i=$((i+1))
done

# Cache warm/cold from idle since the last user prompt (status-line refreshes on
# a timer even while idle, so this stays accurate between turns).
warm="●warm"; warmcol=$GRN
if [ -n "$sid" ]; then
  last_prompt=$(tc_state_get "$sid" '.last_prompt_at')
  idle_min=$(tc_cfg '.submitGuard.idleCacheWarnMins' 5)
  if [ -n "$last_prompt" ]; then
    diff=$(( ( $(tc_now) - last_prompt ) / 60 ))
    if [ "$diff" -ge "$idle_min" ] 2>/dev/null; then warm="○cold"; warmcol=$YEL; fi
  fi
fi

costfmt=$(printf '%.2f' "$cost" 2>/dev/null); [ -z "$costfmt" ] && costfmt="$cost"

hum() {
  local n="${1:-0}"
  if [ "$n" -ge 1000000 ] 2>/dev/null; then printf '%sM' "$(echo "scale=1;$n/1000000" | bc 2>/dev/null)"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then printf '%sk' "$(echo "$n/1000" | bc 2>/dev/null)"
  else printf '%s' "$n"; fi
}

line="${CYN}◐ ${model}${R}  ${DIM}│${R}  ctx ${ctxcol}${bar} ${ctx}%${R}  ${DIM}│${R}  \$${costfmt}  ${DIM}│${R}  ${warmcol}${warm}${R}  ${DIM}│${R}  ↑$(hum "$in_tok") ↓$(hum "$out_tok")"

# Surface a transient nudge (set by the hooks) for a few seconds.
if [ -n "$sid" ]; then
  ntext=$(tc_state_get "$sid" '.nudge.text')
  nuntil=$(tc_state_get "$sid" '.nudge.until')
  if [ -n "$ntext" ] && [ -n "$nuntil" ] && [ "$(tc_now)" -lt "$nuntil" ] 2>/dev/null; then
    line="${line}  ${YEL}⚠ ${ntext}${R}"
  fi
fi

printf '%s\n' "$line"
exit 0
