#!/usr/bin/env bash
# Promote a recon task to a flight task in place: the flight crew member keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to flight in
# state/<task-id>.meta so ap-teardown.sh applies the full flight-task teardown protection
# again. After promoting, send the flight crew member its flight instructions via ap-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch ap/<task-id>, implement, then report done
# according to the project's delivery mode).
# Usage: ap-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
STATE="${AP_STATE_OVERRIDE:-$AP_HOME/state}"
"$AP_ROOT/bin/ap-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=recon' "$META" || { echo "error: task $ID is not a recon task (kind=recon not in meta)" >&2; exit 1; }

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=flight" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$AP_HOME")
echo "promoted $ID to flight (teardown protection restored)"
echo "next: AP_HOME=$HOME_Q bin/ap-send.sh ap-$ID '<flight instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch ap/$ID; implement; report done>'"
