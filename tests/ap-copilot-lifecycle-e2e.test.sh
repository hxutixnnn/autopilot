#!/usr/bin/env bash
# tests/ap-copilot-lifecycle-e2e.test.sh - the happy-path copilot operator
# flow, end to end, against one shared world:
#
#   seed -> spawn -> routed send -> backlog handoff -> recovery respawn -> teardown
#
# Each phase asserts the durable contracts the consolidation audit lists, so the
# many former positive unit tests (registry scope/charter/clone/mode, spawn meta,
# bare-window send, recovery respawn, teardown of an empty home, backlog handoff)
# collapse into one lifecycle. The path-boundary safety invariants and the
# lease-specific paths live in ap-copilot-safety.test.sh.
#
# Coverage anchored here (must not regress):
#   - registry line records scope (from a filled charter brief) and project list
#   - charter is copied into the copilot home
#   - remote-backed projects are cloned with their origin URL preserved
#   - a no-mistakes project is initialized (init + doctor) in the NEW copilot_home clone
#     and the parent project clone is never mutated (no write through a project)
#   - spawn meta records kind=copilot, home=, and the project list; launch runs
#     in the copilot home with the persistent charter and cleared operational overrides
#   - a bare `ap-<id>` send targets the window recorded in THIS home's meta
#   - backlog items move verbatim into the copilot home and leave the main backlog
#   - recovery respawns from the durable registry + persistent home
#   - teardown removes meta and the registry route only after removing the home
set -u

# shellcheck source=tests/copilot-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/copilot-helpers.sh"

TMP_ROOT=$(ap_test_tmproot ap-copilot-lifecycle)
export AP_BACKEND=tmux
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.$ROOT.insteadOf"
export GIT_CONFIG_VALUE_0=https://github.com/hxutixnnn/autopilot.git

HOME_DIR="$TMP_ROOT/main home"
SUB="$TMP_ROOT/design-home"
SUB_ABS=
FAKEBIN=
LOG="$TMP_ROOT/tmux.log"
PANE="$TMP_ROOT/pane.txt"
ALPHA_ORIGIN=
BETA_ORIGIN=

# --- shared world + seed ----------------------------------------------------
setup_world() {
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/state"
  ap_git_init_commit "$HOME_DIR/projects/alpha"
  ap_git_init_commit "$HOME_DIR/projects/beta"
  ap_git_init_commit "$HOME_DIR/projects/gamma"
  ap_git_add_origin "$HOME_DIR/projects/alpha" "$TMP_ROOT/remotes/alpha.git"
  ap_git_add_origin "$HOME_DIR/projects/beta" "$TMP_ROOT/remotes/beta.git"
  ap_git_add_origin "$HOME_DIR/projects/gamma" "$TMP_ROOT/remotes/gamma.git"
  cat > "$HOME_DIR/data/projects.md" <<EOF
- alpha [direct-PR +yolo] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
- gamma - gamma project (added 2026-06-22)
EOF
  ALPHA_ORIGIN=$(git -C "$HOME_DIR/projects/alpha" remote get-url origin)
  BETA_ORIGIN=$(git -C "$HOME_DIR/projects/beta" remote get-url origin)

  # One combined fakebin: tmux + treehouse (spawn/send/teardown) and no-mistakes
  # (gamma initialization during seed).
  FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
  make_fake_no_mistakes "$TMP_ROOT/fake" >/dev/null

  # A filled charter brief whose routing scope differs from the charter summary,
  # so the registry must read the scope from the brief, not invent a generic one.
  AP_COPILOT_SCOPE='customer onboarding from brief' \
    scaffold_copilot_charter "$HOME_DIR" design 'customer onboarding charter' alpha beta gamma \
    || fail "filled copilot charter scaffold failed"
}

phase_seed() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" AP_HOME="$HOME_DIR" \
    "$ROOT/bin/ap-home-seed.sh" design "$SUB" alpha beta gamma) \
    || fail "seed failed"
  SUB_ABS=$(cd "$SUB" && pwd -P)

  assert_contains "$out" "home=$SUB_ABS" "seed did not report the copilot home"
  assert_present "$SUB/.ap-copilot-home" "seed did not mark the copilot home"
  assert_present "$SUB/data/charter.md" "seed did not copy the charter into the copilot home"
  assert_grep 'customer onboarding charter' "$SUB/data/charter.md" "charter body was not copied verbatim"
  case "$(git -C "$SUB" config --get remote.origin.url)" in
    https://github.com/hxutixnnn/autopilot.git|git@github.com:hxutixnnn/autopilot.git) ;;
    *) fail "copilot home did not retain a canonical Autopilot update source" ;;
  esac

  # Projects cloned; remote-backed origins preserved.
  assert_present "$SUB/projects/alpha/.git" "alpha was not cloned"
  assert_present "$SUB/projects/beta/.git" "beta was not cloned"
  assert_present "$SUB/projects/gamma/.git" "gamma was not cloned"
  [ "$(git -C "$SUB/projects/alpha" remote get-url origin)" = "$ALPHA_ORIGIN" ] \
    || fail "alpha clone did not preserve its origin URL"
  [ "$(git -C "$SUB/projects/beta" remote get-url origin)" = "$BETA_ORIGIN" ] \
    || fail "direct-PR beta clone did not preserve its origin URL"

  # no-mistakes init runs in the NEW clone, never the parent project.
  assert_present "$SUB/projects/gamma/.no-mistakes-init" "no-mistakes project was not initialized in the copilot home"
  assert_present "$SUB/projects/gamma/.no-mistakes-doctor" "no-mistakes project was not doctored in the copilot home"
  assert_absent "$HOME_DIR/projects/gamma/.no-mistakes-init" "seed wrote no-mistakes state through the parent project"

  # Registry line: scope from the filled brief, project list, no legacy owns field.
  assert_grep '- design - customer onboarding charter' "$HOME_DIR/data/copilots.md" "registry summary not from the charter"
  assert_grep 'scope: customer onboarding from brief' "$HOME_DIR/data/copilots.md" "registry scope not from the filled brief"
  assert_grep 'projects: alpha, beta, gamma' "$HOME_DIR/data/copilots.md" "registry did not record the project list"
  assert_no_grep 'owns:' "$HOME_DIR/data/copilots.md" "registry used the legacy owns field"

  # Delivery modes preserved in the copilot home registry; validation passes.
  [ "$(AP_HOME="$SUB" "$ROOT/bin/ap-project-mode.sh" alpha)" = "direct-PR on" ] \
    || fail "alpha delivery mode not preserved in the copilot home"
  [ "$(AP_HOME="$SUB" "$ROOT/bin/ap-project-mode.sh" beta)" = "direct-PR off" ] \
    || fail "beta delivery mode not preserved in the copilot home"
  AP_HOME="$HOME_DIR" "$ROOT/bin/ap-home-seed.sh" validate >/dev/null || fail "registry validation failed after seed"

  pass "seed: registry scope+projects, charter copied, clones+origins, no-mistakes init in copilot_home only"
}

phase_spawn() {
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" AP_HOME="$HOME_DIR" AP_CONFIG_OVERRIDE="$HOME_DIR/parent-config" \
    AP_FAKE_TMUX_LOG="$LOG" AP_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/ap-spawn.sh" design "$SUB" codex --copilot >/dev/null \
    || fail "copilot spawn failed"

  local meta="$HOME_DIR/state/design.meta"
  assert_grep 'kind=copilot' "$meta" "spawn meta did not record kind=copilot"
  assert_grep "home=$SUB_ABS" "$meta" "spawn meta did not record the copilot home"
  assert_grep 'projects=alpha, beta, gamma' "$meta" "spawn meta did not record the project list"
  # Launch ran in the copilot home, with the persistent charter and cleared overrides,
  # and never ran a project-style treehouse get.
  assert_grep "AP_HOME='$SUB_ABS'" "$LOG" "copilot launch did not set AP_HOME to the copilot home"
  assert_grep 'AP_ROOT_OVERRIDE= AP_STATE_OVERRIDE= AP_DATA_OVERRIDE= AP_PROJECTS_OVERRIDE=' "$LOG" "launch did not clear operational overrides"
  assert_grep 'AP_CONFIG_OVERRIDE=' "$LOG" "launch did not clear the config override"
  assert_grep "$SUB_ABS/data/charter.md" "$LOG" "launch did not use the persistent charter"
  assert_no_grep 'notify=' "$LOG" "copilot codex launch included the parent turn-end notify hook"
  assert_no_grep 'turn-ended' "$LOG" "copilot codex launch referenced a parent turn-ended signal"
  assert_no_grep 'treehouse get' "$LOG" "copilot spawn ran a project treehouse get"
  pass "spawn: launches in the copilot home with persistent charter, records routing meta"
}

phase_send() {
  : > "$LOG"
  : > "$PANE"
  # The meta window (autopilot:ap-design) must win over a foreign same-named
  # window returned by list-windows.
  PATH="$FAKEBIN:$PATH" AP_HOME="$HOME_DIR" AP_FAKE_TMUX_WINDOW="other-session:ap-design" \
    AP_FAKE_TMUX_LOG="$LOG" AP_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/ap-send.sh" ap-design 'route this work' >/dev/null 2>&1 \
    || fail "ap-send failed for a bare autopilot window with home metadata"
  # design is a kind=copilot target, so the request is prefixed with the
  # from-autopilot marker (bin/ap-marker-lib.sh): the send targets the meta window
  # AND carries the marker label, and the original payload still follows it.
  assert_grep 'send-keys -t autopilot:ap-design -l [ap-from-autopilot]' "$LOG" "send did not use the window recorded in this home's meta, or did not mark the copilot request"
  assert_grep 'route this work' "$LOG" "the original request text did not survive the marker"
  assert_no_grep 'send-keys -t other-session:ap-design' "$LOG" "send targeted a foreign same-named window"
  pass "send: a bare ap-<id> copilot routes to the meta window with the from-autopilot marker"
}

phase_handoff() {
  # The move is delegated to `tasks-axi mv`; skip cleanly when it is absent (the
  # downstream recovery and teardown phases do not depend on this phase).
  if ! command -v tasks-axi >/dev/null 2>&1; then
    echo "skip: tasks-axi not found (backlog handoff delegates to it)"
    return 0
  fi
  cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - active work (repo: alpha, since 2026-06-20)

## Queued
- [ ] feat-x - add feature x (repo: alpha)
- [ ] feat-y - add feature y (repo: beta) blocked-by: feat-x - waits
- [ ] bug-z - fix bug z (repo: gamma)

## Done
- [x] old-task - delivered thing - local main (merged 2026-06-19)
EOF
  local out before
  out=$(AP_HOME="$HOME_DIR" "$ROOT/bin/ap-backlog-handoff.sh" design feat-x feat-y) \
    || fail "handoff failed for in-scope items"
  assert_contains "$out" "handed off 2 item(s) to design" "handoff did not report the moved items"

  assert_no_grep 'feat-x' "$HOME_DIR/data/backlog.md" "feat-x was not removed from the main backlog"
  assert_no_grep 'feat-y' "$HOME_DIR/data/backlog.md" "feat-y was not removed from the main backlog"
  assert_grep 'bug-z' "$HOME_DIR/data/backlog.md" "out-of-scope bug-z was wrongly removed"
  assert_grep 'live-task' "$HOME_DIR/data/backlog.md" "in-flight item was wrongly removed"

  assert_grep '- [ ] feat-x - add feature x (repo: alpha)' "$SUB/data/backlog.md" "feat-x did not arrive verbatim"
  assert_grep '- [ ] feat-y - add feature y (repo: beta) blocked-by: feat-x - waits' "$SUB/data/backlog.md" "feat-y line not preserved verbatim"
  awk '/^## Queued/{q=1;next} /^## /{q=0} q && /feat-x/{found=1} END{exit found?0:1}' "$SUB/data/backlog.md" \
    || fail "feat-x did not land under the Queued section"

  # Idempotent: a second handoff neither errors nor duplicates, and leaves main alone.
  before=$(cat "$HOME_DIR/data/backlog.md")
  AP_HOME="$HOME_DIR" "$ROOT/bin/ap-backlog-handoff.sh" design feat-x feat-y >/dev/null 2>&1 \
    || fail "idempotent re-run failed"
  [ "$(grep -cF -- '- [ ] feat-x - add feature x (repo: alpha)' "$SUB/data/backlog.md")" -eq 1 ] \
    || fail "idempotent re-run duplicated feat-x in the copilot home backlog"
  [ "$before" = "$(cat "$HOME_DIR/data/backlog.md")" ] || fail "idempotent re-run mutated the main backlog"
  pass "handoff: in-scope items move verbatim, out-of-scope stays, idempotent"
}

phase_recovery() {
  # Simulate a restart: drop the live meta, then respawn from the registry +
  # persistent home (no explicit home argument).
  rm -f "$HOME_DIR/state/design.meta"
  PATH="$FAKEBIN:$PATH" AP_HOME="$HOME_DIR" AP_FAKE_TMUX_LOG="$LOG" AP_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/ap-spawn.sh" design "echo relaunch" --copilot >/dev/null 2>&1 \
    || fail "recovery respawn failed"
  local meta="$HOME_DIR/state/design.meta"
  assert_grep "home=$SUB_ABS" "$meta" "respawn did not preserve the persistent home from the registry"
  assert_grep 'projects=alpha, beta, gamma' "$meta" "respawn did not preserve the project list from the registry"
  assert_grep 'window=autopilot:ap-design' "$meta" "respawn did not reconstruct the direct-report window"
  pass "recovery: respawns from the durable registry and persistent home"
}

phase_teardown() {
  local teardown_out
  : > "$LOG"
  teardown_out=$(PATH="$FAKEBIN:$PATH" AP_HOME="$HOME_DIR" AP_FAKE_TMUX_LOG="$LOG" AP_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/ap-teardown.sh" design 2>&1) \
    || fail "teardown failed for the empty copilot home"
  printf '%s\n' "$teardown_out" | grep -F 'Backlog:' >/dev/null \
    && fail "copilot teardown emitted a main-backlog completion reminder"
  assert_absent "$SUB" "teardown did not remove the retired copilot home"
  assert_absent "$HOME_DIR/state/design.meta" "teardown did not clear the parent meta"
  assert_no_grep '- design ' "$HOME_DIR/data/copilots.md" "teardown did not remove the registry route"
  # The parent's source projects are untouched (no write through a parent home).
  assert_present "$HOME_DIR/projects/alpha" "teardown disturbed a parent project"
  pass "teardown: removes the home, then clears meta and the registry route"
}

setup_world
phase_seed
phase_spawn
phase_send
phase_handoff
phase_recovery
phase_teardown
