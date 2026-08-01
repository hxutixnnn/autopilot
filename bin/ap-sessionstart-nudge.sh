#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine autopilot
# primary whose current harness session has not already acquired the home lock.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
STATE="${AP_STATE_OVERRIDE:-$AP_HOME/state}"

# shellcheck source=bin/ap-gate-refuse-lib.sh
. "$SCRIPT_DIR/ap-gate-refuse-lib.sh"
# shellcheck source=bin/ap-primary-scope-lib.sh
. "$SCRIPT_DIR/ap-primary-scope-lib.sh"
# shellcheck source=bin/ap-operational-input.sh
. "$SCRIPT_DIR/ap-operational-input.sh"

ap_is_gate_agent "$AP_ROOT" && exit 0
ap_primary_scope_matches "$AP_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

lock_is_in_ancestry && exit 0
nudge=
ap_operational_input_encode session-start \
  "Run \`bin/ap-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
