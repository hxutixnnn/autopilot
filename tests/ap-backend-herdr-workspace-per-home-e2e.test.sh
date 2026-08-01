#!/usr/bin/env bash
# tests/ap-backend-herdr-workspace-per-home-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the P3 "workspace-per-home" pass (AGENTS.md
# task herdr-copilot-spaces-k4). Drives the REAL bin/ap-spawn.sh and
# bin/ap-teardown.sh (not just adapter primitives), because the requirement
# under test - a --copilot spawn's tab landing in the copilot's OWN
# herdr workspace, and a flight crew member spawned FROM a copilot home landing there
# too - only exists at ap-spawn.sh's own home-shadowing logic (the herdr case
# arm) and at ap_backend_herdr_workspace_label's AP_HOME read; neither is
# exercised by the adapter-primitive smoke test.
#
# Mirrors tests/ap-backend-autodetect-smoke.test.sh's isolated-session
# convention: a private throwaway HERDR_SESSION (never the pilot's
# default), scratch AP_HOME(s), and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers, at minimum (per the task brief):
#   - a primary-shaped home (no .ap-copilot-home marker) spawning a
#     flight crew member into the "autopilot" workspace
#   - a copilot-shaped home (with .ap-copilot-home) getting its own
#     labeled workspace when the PRIMARY spawns it (ap-spawn.sh's AP_HOME
#     shadow for --copilot)
#   - a flight crew member spawned FROM that copilot-shaped home (the copilot
#     running its OWN ap-spawn.sh) landing in the copilot's own workspace -
#     this exact path has never run before this test
#   - teardown closing the right tab (and no other)
#   - list-live recovery seeing only its own home's tabs, for both homes
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}
assert_not_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by ap-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) for the same
# low-noise scratch fixture shape used by
# tests/ap-backend-autodetect-smoke.test.sh.
# ap-spawn no longer needs this as a symlink workaround: ap-spawn-symlink-guard-s8
# canonicalized project and backend cwd comparisons in the worktree-discovery
# poll.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/ap-herdr-e2e.XXXXXX")
SESSION="ap-lab-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
WT1=; WT2=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT2" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
ap_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/ap-backend.sh"
ap_backend_source herdr || fail "ap_backend_source herdr failed"

# --- scratch world: a primary-shaped home, a copilot-shaped home, two projects ---

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'trivial e2e primary flight crew member brief: nothing to do.\n' > "$PRIMARY_HOME/data/cm1/brief.md"

COPILOT_HOME="$TMP_ROOT/copilot-home"
mkdir -p "$COPILOT_HOME/state" "$COPILOT_HOME/data/cm2" "$COPILOT_HOME/config" "$COPILOT_HOME/projects" "$COPILOT_HOME/bin"
printf '# scratch copilot home AGENTS.md placeholder\n' > "$COPILOT_HOME/AGENTS.md"
printf 'e2ecopilot1\n' > "$COPILOT_HOME/.ap-copilot-home"
printf 'trivial e2e copilot charter: nothing to do.\n' > "$COPILOT_HOME/data/charter.md"
printf 'trivial e2e copilot-owned flight crew member brief: nothing to do.\n' > "$COPILOT_HOME/data/cm2/brief.md"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Autopilot Tests' -c user.email='tests@example.invalid' commit -qm initial
}

PROJ1="$TMP_ROOT/scratch-project-1"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/scratch-project-2"; make_scratch_project "$PROJ2"

# --- 1. primary-shaped home: a flight crew member spawns into the "autopilot" space ---

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
AP_SPAWN_NO_GUARD=1 AP_HOME="$PRIMARY_HOME" AP_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/ap-spawn.sh" cm1 "$PROJ1" "sh -c 'echo primary-flight-crew-ok'" --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "primary-shaped flight crew member spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"

CM1_META="$PRIMARY_HOME/state/cm1.meta"
[ -f "$CM1_META" ] || fail "no meta written for cm1"
assert_contains_local "$(cat "$CM1_META")" "backend=herdr" "cm1 meta missing backend=herdr"
WT1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "cm1 meta missing herdr_pane_id"
pass "real herdr E2E: a primary-shaped home spawns a flight crew member on the herdr backend"

sleep 1
CM1_CAPTURE=$(ap_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "primary-flight-crew-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "autopilot" ] || fail "a primary-shaped home's flight crew member should land in the 'autopilot' workspace, got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's flight crew member landed in the 'autopilot' workspace"

# --- 2. the PRIMARY spawns a copilot: its tab lands in the COPILOT's own space ---
# (ap-spawn.sh's herdr case arm shadows AP_HOME to the copilot's home for
# exactly this call - AGENTS.md task herdr-copilot-spaces-k4, requirement 3.)

COPILOT_OUT="$TMP_ROOT/copilot.out"; COPILOT_ERR="$TMP_ROOT/copilot.err"
AP_SPAWN_NO_GUARD=1 AP_HOME="$PRIMARY_HOME" AP_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/ap-spawn.sh" e2ecopilot1 "$COPILOT_HOME" "sh -c 'echo copilot-launch-ok'" --copilot --backend herdr \
  >"$COPILOT_OUT" 2>"$COPILOT_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary's --copilot spawn of e2ecopilot1 failed"$'\n'"--- stdout ---"$'\n'"$(cat "$COPILOT_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$COPILOT_ERR")"

COPILOT_META="$PRIMARY_HOME/state/e2ecopilot1.meta"
[ -f "$COPILOT_META" ] || fail "no meta written for e2ecopilot1 (recorded in the PRIMARY's own state dir, since the primary did the spawning)"
assert_contains_local "$(cat "$COPILOT_META")" "kind=copilot" "e2ecopilot1 meta missing kind=copilot"
assert_contains_local "$(cat "$COPILOT_META")" "backend=herdr" "e2ecopilot1 meta missing backend=herdr"
assert_contains_local "$(cat "$COPILOT_META")" "home=$COPILOT_HOME" "e2ecopilot1 meta does not record its own home"
COPILOT_PANE=$(grep '^herdr_pane_id=' "$COPILOT_META" | cut -d= -f2-)
[ -n "$COPILOT_PANE" ] || fail "e2ecopilot1 meta missing herdr_pane_id"
pass "real herdr E2E: the primary spawns a --copilot task on the herdr backend"

COPILOT_WSID=$(herdr pane get "$COPILOT_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$COPILOT_WSID" ] || fail "could not read e2ecopilot1's pane workspace_id"
[ "$COPILOT_WSID" != "$CM1_WSID" ] || fail "the copilot's tab must NOT land in the primary's workspace, but it shares $CM1_WSID"
COPILOT_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$COPILOT_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$COPILOT_WS_LABEL" = "copilot-e2ecopilot1" ] || fail "a --copilot spawn should land in 'copilot-<id>', got '$COPILOT_WS_LABEL'"
pass "real herdr E2E: a --copilot spawn by the PRIMARY lands in the COPILOT's own labeled workspace, distinct from the primary's"

# --- 3. a flight crew member spawned FROM the copilot-shaped home lands in the SAME
# copilot workspace (this exact path has never run before this test) -----

CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
AP_SPAWN_NO_GUARD=1 AP_HOME="$COPILOT_HOME" AP_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/ap-spawn.sh" cm2 "$PROJ2" "sh -c 'echo copilot-flight-crew-ok'" --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a flight crew member spawned FROM the copilot-shaped home failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"

CM2_META="$COPILOT_HOME/state/cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for cm2 (recorded in the COPILOT's own state dir - it did its own spawning)"
assert_contains_local "$(cat "$CM2_META")" "backend=herdr" "cm2 meta missing backend=herdr"
WT2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "cm2 meta missing herdr_pane_id"
pass "real herdr E2E: a flight crew member spawns successfully FROM a copilot-shaped home's own ap-spawn.sh process"

sleep 1
CM2_CAPTURE=$(ap_backend_herdr_capture "$SESSION:$CM2_PANE" 30) || fail "capture failed on cm2's pane"
assert_contains_local "$CM2_CAPTURE" "copilot-flight-crew-ok" "cm2's raw launch command did not run in its herdr pane"

CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" = "$COPILOT_WSID" ] || fail "a flight crew member spawned FROM the copilot home should land in the SAME workspace as the copilot's own task ($COPILOT_WSID), got '$CM2_WSID'"
[ "$CM2_WSID" != "$CM1_WSID" ] || fail "a flight crew member spawned FROM the copilot home must NOT land in the primary's workspace"
pass "real herdr E2E: a flight crew member spawned FROM the copilot-shaped home lands in the copilot's OWN workspace - falls out of per-home resolution, no glue needed"

# --- 4. list-live recovery: each home sees only its own tabs ---------------

PRIMARY_LIVE=$(AP_HOME="$PRIMARY_HOME" ap_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_LIVE" "ap-cm1" "the primary home's list_live did not see its own task"
assert_not_contains_local "$PRIMARY_LIVE" "ap-e2ecopilot1" "the primary home's list_live must not see the copilot's own task"
assert_not_contains_local "$PRIMARY_LIVE" "ap-cm2" "the primary home's list_live must not see the copilot-owned flight crew member's task"
pass "real herdr E2E: list_live from the primary's own context sees only the primary's own task"

COPILOT_LIVE=$(AP_HOME="$COPILOT_HOME" ap_backend_herdr_list_live "$SESSION")
assert_contains_local "$COPILOT_LIVE" "ap-e2ecopilot1" "the copilot home's list_live did not see its own task"
assert_contains_local "$COPILOT_LIVE" "ap-cm2" "the copilot home's list_live did not see the flight crew member spawned from it"
assert_not_contains_local "$COPILOT_LIVE" "ap-cm1" "the copilot home's list_live must not see the primary's task"
pass "real herdr E2E: list_live from the copilot's own context sees only tasks in the copilot's own workspace (both its own tab and its flight crew member's)"

# --- 5. teardown closes the RIGHT tab, and no other ------------------------

TD1_OUT="$TMP_ROOT/td1.out"
AP_ROOT_OVERRIDE="$ROOT" AP_STATE_OVERRIDE="$PRIMARY_HOME/state" AP_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  AP_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/ap-teardown.sh" cm1 >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "ap-teardown.sh failed for the primary-shaped flight crew member cm1"$'\n'"$(cat "$TD1_OUT")"
[ -f "$CM1_META" ] && fail "ap-teardown.sh did not remove cm1's meta"
if herdr pane get "$CM1_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "ap-teardown.sh did not close cm1's pane"
fi
if ! herdr pane get "$COPILOT_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed the copilot's OWN pane (wrong tab closed)"
fi
if ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed cm2's pane (wrong tab closed)"
fi
WT1=
pass "real herdr E2E: tearing down cm1 closes only its own tab - the copilot's and cm2's tabs survive untouched"

TD2_OUT="$TMP_ROOT/td2.out"
AP_ROOT_OVERRIDE="$ROOT" AP_STATE_OVERRIDE="$COPILOT_HOME/state" AP_DATA_OVERRIDE="$COPILOT_HOME/data" \
  AP_CONFIG_OVERRIDE="$COPILOT_HOME/config" \
  "$ROOT/bin/ap-teardown.sh" cm2 >"$TD2_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "ap-teardown.sh failed for the copilot-owned flight crew member cm2"$'\n'"$(cat "$TD2_OUT")"
[ -f "$CM2_META" ] && fail "ap-teardown.sh did not remove cm2's meta"
if herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "ap-teardown.sh did not close cm2's pane"
fi
if ! herdr pane get "$COPILOT_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm2 must not have closed the copilot's OWN pane (wrong tab closed)"
fi
WT2=
pass "real herdr E2E: tearing down cm2 closes only its own tab - the copilot's own tab (same workspace) survives untouched"

ap_backend_herdr_kill "$SESSION:$COPILOT_PANE"

cleanup_all
trap - EXIT
