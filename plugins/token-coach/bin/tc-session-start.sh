#!/usr/bin/env bash
# token-coach — SessionStart: initialise per-session state.
# Prints NOTHING to stdout: SessionStart stdout is injected into Claude's
# context, and spending tokens to announce a token meter would be self-defeating.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/tc-common.sh" 2>/dev/null || true

input=$(cat 2>/dev/null)
tc_have_jq || exit 0

sid=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] && tc_state_init "$sid"
exit 0
