#!/usr/bin/env bash
# token-coach — smoke tests. Simulates the hook/statusline JSON contracts and
# asserts behaviour, with no dependency on a live Claude Code session.
#
#   bash test/smoke.sh
#
# Each test runs in an isolated temp TC_HOME so state/config never leak between
# cases or touch your real ~/.claude.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/plugins/token-coach"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
BIN="$PLUGIN/bin"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko()  { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
assert_eq()       { [ "$1" = "$2" ] && ok "$3" || ko "$3 (got '$1' want '$2')"; }
assert_contains() { case "$1" in *"$2"*) ok "$3";; *) ko "$3 (output missing '$2')";; esac }
assert_ge()       { [ "${1:-0}" -ge "$2" ] 2>/dev/null && ok "$3" || ko "$3 (got '$1' want >= '$2')"; }

# new_home [config-json] -> sets TC_HOME/TC_STATE_DIR/TC_CONFIG_FILE for this test
new_home() {
  export TC_HOME; TC_HOME="$(mktemp -d)"
  export TC_STATE_DIR="$TC_HOME/state"
  export TC_CONFIG_FILE="$TC_HOME/config.json"
  [ -n "$1" ] && printf '%s' "$1" > "$TC_CONFIG_FILE" || rm -f "$TC_CONFIG_FILE"
}
state() { jq -r "$2" "$TC_STATE_DIR/$1.json" 2>/dev/null; }

echo "== manifests are valid JSON =="
jq empty "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null && ok "marketplace.json parses" || ko "marketplace.json INVALID JSON"
for f in .claude-plugin/plugin.json hooks/hooks.json config/defaults.json settings.json; do
  jq empty "$PLUGIN/$f" 2>/dev/null && ok "$f parses" || ko "$f INVALID JSON"
done
echo "== marketplace source points at the plugin subdir =="
src=$(jq -r '.plugins[0].source' "$ROOT/.claude-plugin/marketplace.json")
assert_eq "$src" "./plugins/token-coach" "source is a supported subdir path"
[ -f "$ROOT/$src/.claude-plugin/plugin.json" ] && ok "plugin.json exists at source path" || ko "plugin.json missing at source path"

echo "== status line renders =="
new_home
out=$(echo '{"session_id":"s","model":{"display_name":"Opus"},"cost":{"total_cost_usd":3.42},"context_window":{"used_percentage":68,"total_input_tokens":182000,"total_output_tokens":24000,"current_usage":{"cache_read_input_tokens":120000}}}' | "$BIN/statusline.sh")
assert_contains "$out" "Opus" "shows model"
assert_contains "$out" "ctx"  "shows context"
assert_contains "$out" '$3.42' "shows cost"

echo "== config: jq // gotcha regression (false must stay false) =="
new_home '{"baselineMode": false}'
# shellcheck source=/dev/null
( . "$BIN/tc-common.sh"; b=$(tc_baseline); [ "$b" = "false" ] && exit 0 || exit 1 ) \
  && ok "baselineMode:false is read as false" || ko "baselineMode:false leaked to default"
new_home
( . "$BIN/tc-common.sh"; [ "$(tc_baseline)" = "true" ] && exit 0 || exit 1 ) \
  && ok "baselineMode defaults to true" || ko "default baseline wrong"

echo "== submit guard: large paste logged =="
new_home
big=$(yes "log line of pasted output" | head -200 | jq -Rs .)
ec=$(printf '{"session_id":"p","prompt":%s}' "$big" | "$BIN/tc-submit-guard.sh"; echo $?)
assert_eq "$ec" "0" "exit 0 (non-blocking)"
assert_contains "$(state p '[.nudge_log[].reason]|join(",")')" "paste" "paste signal logged"

echo "== submit guard: vague short prompt =="
new_home
echo '{"session_id":"v","prompt":"fix it"}' | "$BIN/tc-submit-guard.sh"
assert_contains "$(state v '[.nudge_log[].reason]|join(",")')" "vague" "vague signal logged"

echo "== submit guard: high ctx -> clear suggestion =="
new_home
echo '{"session_id":"c","model":{"display_name":"Opus"},"context_window":{"used_percentage":88,"total_input_tokens":900000}}' | "$BIN/statusline.sh" >/dev/null
echo '{"session_id":"c","prompt":"now add a brand new feature please"}' | "$BIN/tc-submit-guard.sh"
assert_contains "$(state c '[.nudge_log[].reason]|join(",")')" "clear" "clear signal logged at high ctx"

echo "== baseline surfacing: off vs on =="
new_home '{"baselineMode": true}'
echo '{"session_id":"b1","prompt":"hi"}' | "$BIN/tc-submit-guard.sh"
assert_eq "$(state b1 '.nudge')" "null" "baseline ON: nothing surfaced"
new_home '{"baselineMode": false}'
echo '{"session_id":"b2","prompt":"hi"}' | "$BIN/tc-submit-guard.sh"
assert_contains "$(state b2 '.nudge.text')" "vague" "baseline OFF: nudge surfaced"

echo "== pre-read: re-read detection =="
new_home
echo "{\"session_id\":\"r\",\"tool_input\":{\"file_path\":\"$ROOT/README.md\"}}" | "$BIN/tc-pre-read.sh"
echo "{\"session_id\":\"r\",\"tool_input\":{\"file_path\":\"$ROOT/README.md\"}}" | "$BIN/tc-pre-read.sh"
assert_ge "$(state r '.reread_count')" "1" "second read flagged as re-read"

echo "== pre-bash: unbounded vs scoped =="
new_home
echo '{"session_id":"g","tool_input":{"command":"git log"}}' | "$BIN/tc-pre-bash.sh"
assert_contains "$(state g '[.nudge_log[].reason]|join(",")')" "bashoutput" "unbounded git log flagged"
n1=$(state g '.nudges_fired')
echo '{"session_id":"g","tool_input":{"command":"git log --oneline -20"}}' | "$BIN/tc-pre-bash.sh"
assert_eq "$(state g '.nudges_fired')" "$n1" "scoped git log NOT flagged"

echo "== post-tool: byte tally =="
new_home
payload=$(yes x | head -500 | tr -d '\n')
echo "{\"session_id\":\"o\",\"tool_output\":{\"stdout\":\"$payload\"}}" | "$BIN/tc-post-tool.sh"
assert_ge "$(state o '.tool_output_bytes')" "400" "tool output bytes tallied"

echo "== strict mode blocks egregious paste (exit 2) =="
new_home '{"baselineMode": false, "submitGuard": {"enabled": true, "strict": true, "pasteLineThreshold": 150}}'
big=$(yes "x" | head -200 | jq -Rs .)
ec=$(printf '{"session_id":"k","prompt":%s}' "$big" | "$BIN/tc-submit-guard.sh" 2>/dev/null; echo $?)
assert_eq "$ec" "2" "strict+paste exits 2 (blocks)"

echo "== /cost-review report renders =="
new_home
echo '{"session_id":"rep","model":{"display_name":"Opus"},"cost":{"total_cost_usd":9.40},"context_window":{"used_percentage":88,"total_input_tokens":2100000,"total_output_tokens":180000,"current_usage":{"cache_read_input_tokens":900000}}}' | "$BIN/statusline.sh" >/dev/null
out=$("$BIN/tc-report.sh" rep)
assert_contains "$out" "session review" "report header present"
assert_contains "$out" "Suggestions" "report suggestions present"

echo
printf 'RESULT: \033[32m%d passed\033[0m, ' "$pass"
if [ "$fail" -gt 0 ]; then printf '\033[31m%d failed\033[0m\n' "$fail"; exit 1; else printf '%d failed\n' "$fail"; exit 0; fi
