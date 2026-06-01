#!/usr/bin/env bash
# token-coach — shared helpers, sourced by every hook + the status line.
#
# Hard rule: nothing in here may break Claude Code. Callers default to exit 0,
# and every function degrades quietly (empty output) when jq is missing or a
# file is unreadable. We never write code, prompt text, or file *contents* to
# disk — only paths, sizes, counts, and numbers, all local to this machine.

TC_HOME="${TC_HOME:-$HOME/.claude/token-coach}"
TC_STATE_DIR="${TC_STATE_DIR:-$TC_HOME/state}"
TC_CONFIG_FILE="${TC_CONFIG_FILE:-$TC_HOME/config.json}"

# CLAUDE_PLUGIN_ROOT is set by Claude Code for plugin-bundled hooks. Fall back to
# the repo root (one level up from bin/) when run standalone or in tests.
TC_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TC_DEFAULTS_FILE="$TC_PLUGIN_ROOT/config/defaults.json"

tc_now() { date +%s; }

tc_have_jq() { command -v jq >/dev/null 2>&1; }

# Effective config = defaults overlaid with the user's config.json (if any).
tc_config() {
  if [ -f "$TC_CONFIG_FILE" ]; then
    jq -s '.[0] * .[1]' "$TC_DEFAULTS_FILE" "$TC_CONFIG_FILE" 2>/dev/null || cat "$TC_DEFAULTS_FILE" 2>/dev/null
  else
    cat "$TC_DEFAULTS_FILE" 2>/dev/null || echo '{}'
  fi
}

# tc_cfg <jq-path> <default>
# NB: we must NOT use jq's `//` operator here — `false // x` returns x in jq
# (false is treated as null-ish), which would make every boolean default to true
# when explicitly set to false. So we read the raw value and test for null/empty.
tc_cfg() {
  local path="$1" def="$2" val
  val=$(tc_config | jq -r "$path" 2>/dev/null)
  if [ -n "$val" ] && [ "$val" != "null" ]; then echo "$val"; else echo "$def"; fi
}

# Master switch: in baseline mode we log everything but surface nothing to the
# user — that's the silent observation window for measuring effectiveness.
tc_baseline() { tc_cfg '.baselineMode' true; }
tc_should_surface() { [ "$(tc_baseline)" != "true" ]; }

tc_state_file() { echo "$TC_STATE_DIR/${1:-unknown}.json"; }

tc_state_init() {
  mkdir -p "$TC_STATE_DIR" 2>/dev/null
  local f; f=$(tc_state_file "$1")
  if [ ! -f "$f" ]; then
    local now; now=$(tc_now)
    jq -n --arg sid "$1" --argjson now "$now" '{
      session_id: $sid, started_at: $now, last_prompt_at: $now,
      last_cost_usd: 0, last_ctx_pct: 0,
      in_tokens: 0, out_tokens: 0, cache_read_tokens: 0,
      tool_output_bytes: 0, reread_count: 0, prompts: 0,
      nudges_fired: 0, nudge: null, files_read: {}, nudge_log: []
    }' > "$f" 2>/dev/null
  fi
}

# tc_state_update <session_id> <jq-filter> [jq args...]  — read-modify-write.
tc_state_update() {
  local sid="$1"; shift
  local filter="$1"; shift
  local f; f=$(tc_state_file "$sid")
  [ -f "$f" ] || tc_state_init "$sid"
  local tmp="$f.tmp.$$"
  if jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# tc_state_get <session_id> <jq-filter>
tc_state_get() {
  local f; f=$(tc_state_file "$1")
  if [ -f "$f" ]; then jq -r "$2 // empty" "$f" 2>/dev/null; else echo ""; fi
}

# Record a nudge: always log it (for measurement); only set the visible .nudge
# surface when not in baseline mode. <session_id> <reason> <text>
tc_record_nudge() {
  local sid="$1" reason="$2" text="$3" now until
  now=$(tc_now); until=$(( now + 20 ))
  if tc_should_surface; then
    tc_state_update "$sid" \
      '.nudge={text:$t, until:$u} | .nudges_fired=(.nudges_fired+1) | .nudge_log += [{reason:$r, at:$n}]' \
      --arg t "$text" --argjson u "$until" --arg r "$reason" --argjson n "$now"
  else
    tc_state_update "$sid" \
      '.nudges_fired=(.nudges_fired+1) | .nudge_log += [{reason:$r, at:$n}]' \
      --arg r "$reason" --argjson n "$now"
  fi
}
