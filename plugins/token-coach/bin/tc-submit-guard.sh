#!/usr/bin/env bash
# token-coach — UserPromptSubmit guard.
#
# Detects prompts likely to cost a lot and records a nudge. By default it is
# OBSERVE-ONLY: it logs (for measurement) and, outside baseline mode, surfaces a
# transient warning via the status line. It NEVER injects text into Claude's
# context (that would itself cost tokens). Only in active + strict mode will it
# block an egregious paste (exit 2); everything else always exits 0.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/tc-common.sh" 2>/dev/null || true

input=$(cat 2>/dev/null)
tc_have_jq || exit 0

sid=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
prompt=$(echo "$input" | jq -r '.prompt // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0
tc_state_init "$sid"

now=$(tc_now)
last_prompt=$(tc_state_get "$sid" '.last_prompt_at')
tc_state_update "$sid" '.last_prompt_at=$n | .prompts=(.prompts+1)' --argjson n "$now"

nudge=""; reason=""

# 1) Large paste / heavy prompt — known exactly from the prompt text.
lines=$(printf '%s' "$prompt" | wc -l | tr -d ' ')
chars=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
approx_tok=$(( chars / 4 ))
paste_thr=$(tc_cfg '.submitGuard.pasteLineThreshold' 150)
if [ "${lines:-0}" -ge "$paste_thr" ] 2>/dev/null; then
  nudge="large paste (~${approx_tok} tok) → put it in a file & @-mention it"
  reason="paste"
fi

# 2) Session already large → suggest /clear (uses the status-line snapshot).
if [ -z "$nudge" ]; then
  ctx=$(tc_state_get "$sid" '.last_ctx_pct')
  clear_thr=$(tc_cfg '.submitGuard.clearCtxPct' 75)
  if [ -n "$ctx" ] && [ "$(echo "${ctx:-0} >= $clear_thr" | bc -l 2>/dev/null)" = 1 ]; then
    nudge="ctx ${ctx}% — consider /clear before a new task"
    reason="clear"
  fi
fi

# 3) Idle since last prompt → prompt cache likely expired.
if [ -z "$nudge" ] && [ -n "$last_prompt" ]; then
  idle_min=$(tc_cfg '.submitGuard.idleCacheWarnMins' 5)
  diff=$(( (now - last_prompt) / 60 ))
  if [ "$diff" -ge "$idle_min" ] 2>/dev/null; then
    nudge="cache cold (${diff}m idle) — this turn re-reads history at full price"
    reason="cold"
  fi
fi

# 4) Broad-scope verbs → heuristic guess that the *work* will be expensive.
if [ -z "$nudge" ]; then
  low=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')
  case "$low" in
    *"entire codebase"*|*"refactor everything"*|*"all files"*|*"across the codebase"*|*"every file"*|*"whole codebase"*|*"the whole repo"*)
      nudge="broad scope → scope to one module/file to bound cost"; reason="scope" ;;
  esac
fi

# 5) Vague + short → likely triggers a search loop.
if [ -z "$nudge" ]; then
  words=$(printf '%s' "$prompt" | wc -w | tr -d ' ')
  if [ "${words:-99}" -le 5 ] 2>/dev/null && ! printf '%s' "$prompt" | grep -qE '[/.`]|[A-Z][a-z]+[A-Z]'; then
    nudge="vague prompt → name the file/symptom to avoid a search loop"; reason="vague"
  fi
fi

if [ -n "$nudge" ]; then
  tc_record_nudge "$sid" "$reason" "$nudge"

  # Active + strict: block only egregious pastes; resubmit via a file.
  enabled=$(tc_cfg '.submitGuard.enabled' false)
  strict=$(tc_cfg '.submitGuard.strict' false)
  if [ "$enabled" = "true" ] && [ "$strict" = "true" ] && [ "$reason" = "paste" ]; then
    echo "token-coach: $nudge — strict mode blocked this. Point me at a file, or disable submitGuard.strict." >&2
    exit 2
  fi
fi
exit 0
