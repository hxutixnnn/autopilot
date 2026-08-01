#!/usr/bin/env bash
# Tests for the local-HEAD copilot sync: every copilot home tracks the
# PRIMARY autopilot checkout's current default-branch commit by a purely LOCAL
# fast-forward (no origin fetch). Two hook points drive it - bin/ap-spawn.sh
# (before launching a copilot) and bin/ap-bootstrap.sh (a startup sweep of
# every live copilot home) - and both share the ff machinery in
# bin/ap-ff-lib.sh.
#
# The guarantees under test:
#   - The shared ff helper, driven with a LOCAL commit base, advances a behind
#     home (updated), is a no-op on an already-current home (current, no nudge),
#     and refuses - leaving work untouched - on a dirty, diverged, or
#     in-flight (feature-branch) home.
#   - No origin fetch happens in the local-HEAD sync path.
#   - The bootstrap sweep fast-forwards every live copilot home and sends a
#     reread nudge ONLY for a running copilot whose instruction surface
#     actually changed; a successful send is reported as BOOTSTRAP_INFO:, a
#     failed send is reported as NUDGE_COPILOTS:, an already-current or
#     readme-only home is never nudged, a skipped home is reported as
#     COPILOT_SYNC:, and a home with no live metadata is never swept.
#   - Spawning a copilot fast-forwards its worktree to the primary's HEAD
#     before launch, or warns and launches unchanged when the sync is skipped.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/ap-ff-lib.sh
. "$ROOT/bin/ap-ff-lib.sh"

BASE_PATH=${AP_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# Deterministic, isolated git identity for fixture commits.
ap_git_identity fmtest fmtest@example.com

TMP_ROOT=$(ap_test_tmproot ap-copilot-sync)
export AP_BACKEND=tmux

# --- world builders --------------------------------------------------------

# new_world <name>: a PRIMARY autopilot repo on `main` with one commit (the
# instruction surface seeded) and a home dir with state/ and data/. NO origin
# remote: the local-HEAD sync never needs one. Echoes the world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps ap-guard quiet for the spawn path.
  touch "$w/home/state/.last-watcher-beat"

  git init -q -b main "$w/main"
  # Mirror the real repo: the gitignored operational dirs never dirty a worktree,
  # so a copilot home's data/state/projects can never block its fast-forward.
  printf 'projects/\nstate/\ndata/\n.no-mistakes/\nconfig/flight-crew-harness\n' > "$w/main/.gitignore"
  printf 'v1\n' > "$w/main/AGENTS.md"
  printf 'r1\n' > "$w/main/README.md"
  mkdir -p "$w/main/bin" "$w/main/.agents/skills"
  printf 'echo a\n' > "$w/main/bin/tool.sh"
  printf 's1\n' > "$w/main/.agents/skills/note.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm c1
  printf '%s\n' "$w"
}

# add_copilot_worktree <w> <id> <commit>: a copilot home as a DETACHED worktree of
# the primary at <commit>, plus its seed marker and a LIVE kind=copilot meta
# (a window= makes it a running direct report).
add_copilot_worktree() {
  local w=$1 id=$2 commit=$3
  git -C "$w/main" worktree add -q --detach "$w/$id" "$commit"
  printf '%s\n' "$id" > "$w/$id/.ap-copilot-home"
  {
    printf 'window=autopilot:ap-%s\n' "$id"
    printf 'kind=copilot\n'
    printf 'harness=codex\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
}

# bump_primary <w> <mode>: advance the PRIMARY's main branch by one local commit.
# instr changes the instruction surface (AGENTS.md, bin, .agents/skills) plus README;
# readme changes only README. No push - the sync follows the primary's local HEAD.
bump_primary() {
  local w=$1 mode=$2
  printf 'r-%s\n' "$mode" >> "$w/main/README.md"
  if [ "$mode" = instr ]; then
    printf 'v-%s\n' "$mode" > "$w/main/AGENTS.md"
    printf 'echo %s\n' "$mode" > "$w/main/bin/tool.sh"
    printf 's-%s\n' "$mode" > "$w/main/.agents/skills/note.md"
  fi
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm "bump-$mode"
}

head_of() { git -C "$1" rev-parse HEAD; }

# ignore_marker_commit <w>: land THE FIX in the primary - add the seed marker to
# the tracked .gitignore and commit it on main. The marker (.ap-copilot-home)
# is autopilot-generic, written by bin/ap-home-seed.sh into every seeded home; once
# a home fast-forwards past this commit the marker is git-ignored and can no longer
# read as a dirty working tree to any `git status --porcelain` dirtiness check.
ignore_marker_commit() {
  local w=$1
  printf '.ap-copilot-home\n' >> "$w/main/.gitignore"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm "gitignore seed marker"
}

# seed_marked_home <w> <id> <commit>: a copilot home matching what
# bin/ap-home-seed.sh actually lays down - a detached worktree at <commit>, the
# seed marker, a live kind=copilot meta, and the gitignored operational dirs
# with a charter. The ONLY unignored extra file is the seed marker, which is
# exactly what this fix must keep from dirtying the home.
seed_marked_home() {
  local w=$1 id=$2 commit=$3
  add_copilot_worktree "$w" "$id" "$commit"
  mkdir -p "$w/$id/data" "$w/$id/state" "$w/$id/config" "$w/$id/projects"
  printf 'charter\n' > "$w/$id/data/charter.md"
}

# run_ff <dir> <base>: drive the shared ff helper in THIS shell (output to a file,
# not a subshell, so FF_STATUS / FF_INSTR propagate). Sets FF_OUT to the printed
# status line. Uses allow_detached=yes, ignore_seed_marker=yes (the copilot
# home contract).
FF_OUT=""
run_ff() {
  local dir=$1 base=$2 outfile="$TMP_ROOT/ff.out"
  ff_target "$dir" "copilot copilot" "$base" yes yes >"$outfile" 2>&1
  FF_OUT=$(cat "$outfile")
}

# --- T1: updated - a behind home fast-forwards to the primary's local HEAD ---
test_ff_updated() {
  local w c1 base
  w=$(new_world ff-updated)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/copilot" "$c1"
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")

  run_ff "$w/copilot" "$base"

  [ "$FF_STATUS" = updated ] || fail "FF_STATUS: expected updated, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "copilot copilot: updated " "updated home prints an advance line"
  assert_contains "$FF_INSTR" "AGENTS.md" "instruction change is recorded in FF_INSTR"
  [ "$(head_of "$w/copilot")" = "$base" ] || fail "home did not advance to the primary's local HEAD"
  git -C "$w/copilot" symbolic-ref -q HEAD >/dev/null && fail "home is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge would have two.
  [ "$(git -C "$w/copilot" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "home tip is not a single-parent fast-forward"
  pass "T1 updated: a behind home fast-forwards to the primary's local HEAD"
}

# --- T2: current - already on the primary's HEAD is a no-op (no nudge) -------
test_ff_current() {
  local w base
  w=$(new_world ff-current)
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/copilot" "$base"

  run_ff "$w/copilot" "$base"

  [ "$FF_STATUS" = current ] || fail "FF_STATUS: expected current, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "copilot copilot: already current" "current home reports already current"
  [ -z "$FF_INSTR" ] || fail "a no-op must not report instruction changes (would trigger a nudge)"
  [ "$(head_of "$w/copilot")" = "$base" ] || fail "current home HEAD moved"
  pass "T2 current: an already-current home is a no-op and reports no instruction change"
}

# --- T3: dirty - a home with uncommitted edits is skipped, edit preserved ----
test_ff_dirty() {
  local w c1 base before
  w=$(new_world ff-dirty)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/copilot" "$c1"
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")
  printf 'uncommitted local edit\n' >> "$w/copilot/AGENTS.md"
  before=$(head_of "$w/copilot")

  run_ff "$w/copilot" "$base"

  [ "$FF_STATUS" = skipped ] || fail "FF_STATUS: expected skipped, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "copilot copilot: skipped: dirty working tree" "dirty home is skipped"
  [ "$(head_of "$w/copilot")" = "$before" ] || fail "dirty home HEAD moved"
  grep -q 'uncommitted local edit' "$w/copilot/AGENTS.md" || fail "dirty edit was discarded"
  pass "T3 dirty: an uncommitted home is skipped, its edit preserved"
}

# --- T4: diverged - a home with its own commit is skipped, commit preserved --
test_ff_diverged() {
  local w c1 base before
  w=$(new_world ff-diverged)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/copilot" "$c1"
  printf 'fork work\n' > "$w/copilot/AGENTS.md"
  git -C "$w/copilot" add -A
  git -C "$w/copilot" commit -qm local-work
  before=$(head_of "$w/copilot")
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")

  run_ff "$w/copilot" "$base"

  [ "$FF_STATUS" = skipped ] || fail "FF_STATUS: expected skipped, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "copilot copilot: skipped: diverged from $base" "diverged home is skipped"
  [ "$(head_of "$w/copilot")" = "$before" ] || fail "diverged home HEAD moved (unlanded work at risk)"
  pass "T4 diverged: a home that is not an ancestor of the primary's HEAD is skipped"
}

# --- T5: in-flight - a home on a feature branch is skipped, work preserved ----
# A copilot home carrying its own in-flight work sits on a named feature
# branch, not a detached default-branch HEAD; the ff helper refuses to move it.
test_ff_inflight_feature_branch() {
  local w c1 base before
  w=$(new_world ff-inflight)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q -b feature/wip "$w/copilot" "$c1"
  printf 'work in progress\n' >> "$w/copilot/README.md"
  git -C "$w/copilot" add -A
  git -C "$w/copilot" commit -qm wip
  before=$(head_of "$w/copilot")
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")

  run_ff "$w/copilot" "$base"

  [ "$FF_STATUS" = skipped ] || fail "FF_STATUS: expected skipped, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "copilot copilot: skipped: on feature/wip, expected main" \
    "a home on a feature branch is skipped"
  [ "$(head_of "$w/copilot")" = "$before" ] || fail "in-flight home HEAD moved (work at risk)"
  pass "T5 in-flight: a home on a feature branch is skipped, its work preserved"
}

# --- T6: no origin fetch happens in the local-HEAD sync path -----------------
# A bare `git fetch` would need the network; the sync must never reach for it.
# Shadow git with a wrapper that records any `fetch` invocation, then drive the
# updated path and confirm the wrapper saw none.
test_no_fetch_in_local_path() {
  local w c1 base fakebin log real_git
  w=$(new_world ff-nofetch)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/copilot" "$c1"
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")

  fakebin="$w/fakebin"
  log="$w/fetch.log"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = fetch ]; then printf 'FETCH\n' >> '$log'; fi
done
exec '$real_git' "\$@"
SH
  chmod +x "$fakebin/git"

  PATH="$fakebin:$BASE_PATH" run_ff "$w/copilot" "$base"

  [ "$FF_STATUS" = updated ] || fail "FF_STATUS: expected updated, got '$FF_STATUS'"
  [ ! -f "$log" ] || fail "git fetch was invoked in the local-HEAD sync path: $(cat "$log")"
  pass "T6 no fetch: the local-HEAD sync never invokes git fetch"
}

# --- T7: sweep advances a readme-only home but does NOT nudge it -------------
test_sweep_nudge_requires_instruction_change() {
  local w c1 base
  w=$(new_world sweep-gate)
  c1=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-r "$c1"
  bump_primary "$w" readme
  base=$(primary_head_commit "$w/main")

  AP_ROOT="$w/main" AP_HOME="$w/home"
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  sweep_live_copilot_metas "$w/home/state" "$base" yes >/dev/null

  [ -z "$FF_NUDGE_WINDOWS" ] \
    || fail "readme-only advance must not nudge, got: '$FF_NUDGE_WINDOWS'"
  [ "$(head_of "$w/copilot-r")" = "$base" ] \
    || fail "home should still fast-forward even when it is not nudged"
  pass "T7 sweep nudges on a real instruction change only, but still fast-forwards"
}

# --- T8: bootstrap sweeps live homes, nudges only the real instruction change -
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  ap_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ -n "${AP_FAKE_TMUX_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$AP_FAKE_TMUX_LOG"
fi
case "$*" in
  list-windows*)
    sed -n 's/^window=[^:]*://p' "${AP_HOME:?}"/state/*.meta
    exit 0
    ;;
  *display-message*'#{pane_current_command}'*) printf '%s\n' codex; exit 0 ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1'; exit 0 ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0; exit 0 ;;
  *'send-keys'*' -l '*)
    [ "${AP_FAKE_TMUX_FAIL_LITERAL:-0}" = 1 ] && exit 1
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.1.1' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'quota-axi 0.1.16 (fake)'
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

add_real_jq() {
  local fakebin=$1 real_jq
  real_jq=$(command -v jq 2>/dev/null) || return 1
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

test_bootstrap_sweep_nudges_only_instruction_change() {
  local w c1 c2 c3 fakebin out info_line log marker_dir
  w=$(new_world boot-sweep)
  c1=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-instr "$c1"        # behind by an instruction change
  bump_primary "$w" instr
  c2=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-readme "$c2"       # behind by a readme-only change
  bump_primary "$w" readme
  c3=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-current "$c3"      # already on the primary's HEAD
  # A home with NO live meta must never be swept (live = a running direct report).
  git -C "$w/main" worktree add -q --detach "$w/copilot-nonlive" "$c1"
  printf 'copilot-nonlive\n' > "$w/copilot-nonlive/.ap-copilot-home"

  fakebin=$(make_fake_toolchain "$w")
  log="$w/tmux.log"
  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_SEND_SETTLE=0 AP_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)

  info_line=$(printf '%s\n' "$out" | grep '^BOOTSTRAP_INFO: nudged ap-copilot-instr ' || true)
  [ -n "$info_line" ] || fail "no BOOTSTRAP_INFO nudge line emitted (got: $out)"
  assert_contains "$info_line" "autopilot was updated to the latest - please re-read your AGENTS.md to pick up the new instructions." \
    "successful nudge report should include the exact message sent"
  assert_not_contains "$out" "NUDGE_COPILOTS:" "successful nudge must not leave an autopilot action item"
  assert_not_contains "$out" "copilot-readme" "readme-only advance is not nudged"
  assert_not_contains "$out" "copilot-current" "already-current copilot is not nudged"
  assert_contains "$(cat "$log")" "[ap-from-autopilot]" "nudge send should use the marked ap-send copilot path"
  assert_contains "$(cat "$log")" "autopilot was updated to the latest - please re-read your AGENTS.md" \
    "nudge send should type the exact re-read message"
  marker_dir="$w/home/state/.copilot-nudge-pending"
  [ ! -e "$marker_dir/copilot-instr.pending" ] || fail "successful nudge should clear its retry marker"

  # Every live home advanced to the primary's HEAD; the already-current one stayed.
  [ "$(head_of "$w/copilot-instr")" = "$c3" ] || fail "copilot-instr not at primary HEAD"
  [ "$(head_of "$w/copilot-readme")" = "$c3" ] || fail "copilot-readme not at primary HEAD"
  [ "$(head_of "$w/copilot-current")" = "$c3" ] || fail "copilot-current moved off primary HEAD"
  # The non-live home is never touched by the bootstrap sweep.
  [ "$(head_of "$w/copilot-nonlive")" = "$c1" ] || fail "a home with no live meta was swept"
  pass "T8 bootstrap sweeps live homes and sends exactly one marked nudge for the instruction change"
}

test_bootstrap_nudge_send_uses_state_override() {
  local w c1 fakebin out log override_state marker
  w=$(new_world nudge-state-override)
  c1=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-instr "$c1"
  bump_primary "$w" instr
  override_state="$w/override-state"
  mkdir -p "$override_state"
  mv "$w/home/state/copilot-instr.meta" "$override_state/copilot-instr.meta"
  touch "$override_state/.last-watcher-beat"
  fakebin=$(make_fake_toolchain "$w")
  log="$w/tmux.log"

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_STATE_OVERRIDE="$override_state" AP_SEND_SETTLE=0 AP_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "BOOTSTRAP_INFO: nudged ap-copilot-instr with" \
    "nudge send should resolve ap-copilot-instr through the effective state dir"
  assert_not_contains "$out" "NUDGE_COPILOTS:" \
    "effective-state nudge should not fail through AP_HOME/state"
  assert_contains "$(cat "$log")" "[ap-from-autopilot]" \
    "effective-state nudge should still use copilot marker metadata"
  marker="$override_state/.copilot-nudge-pending/copilot-instr.pending"
  assert_absent "$marker" "successful effective-state nudge should clear its retry marker"
  pass "T8a bootstrap nudge send respects AP_STATE_OVERRIDE"
}

test_bootstrap_nudge_retry_rejects_malformed_marker_id() {
  local w c1 fakebin out marker log evil
  w=$(new_world nudge-malformed-id)
  c1=$(head_of "$w/main")
  evil="$w/evil"
  git -C "$w/main" worktree add -q --detach "$evil" "$c1"
  printf '../escape\n' > "$evil/.ap-copilot-home"
  mkdir -p "$w/home/state/.copilot-nudge-pending"
  marker="$w/home/state/.copilot-nudge-pending/bad.pending"
  {
    printf 'id=../escape\n'
    printf 'selector=ap-../escape\n'
    printf 'home=%s\n' "$evil"
    printf 'commit=%s\n' "$c1"
    printf 'instructions=AGENTS.md\n'
    printf 'message=autopilot was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.\n'
  } > "$marker"
  {
    printf 'window=autopilot:ap-evil\n'
    printf 'kind=copilot\n'
    printf 'home=%s\n' "$evil"
  } > "$w/home/escape.meta"
  fakebin=$(make_fake_toolchain "$w")
  log="$w/tmux.log"

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_SEND_SETTLE=0 AP_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "NUDGE_COPILOTS: copilot ../escape: send failed: retry marker has unsafe id" \
    "malformed retry marker id should be rejected before target resolution"
  assert_not_contains "$out" "BOOTSTRAP_INFO: nudged ap-../escape" \
    "malformed retry marker id must never send through a path-traversed selector"
  assert_present "$marker" "malformed retry marker should remain for operator inspection"
  assert_absent "$log" "malformed retry marker should not invoke ap-send"
  pass "T8f bootstrap nudge retry rejects malformed marker ids"
}

test_bootstrap_nudge_failure_records_retry_marker() {
  local w c1 fakebin out marker
  w=$(new_world nudge-failure)
  c1=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-instr "$c1"
  bump_primary "$w" instr
  fakebin=$(make_fake_toolchain "$w")

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_SEND_SETTLE=0 AP_FAKE_TMUX_FAIL_LITERAL=1 \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "NUDGE_COPILOTS: copilot copilot-instr: send failed:" \
    "failed nudge send should be surfaced as actionable bootstrap output"
  marker="$w/home/state/.copilot-nudge-pending/copilot-instr.pending"
  assert_present "$marker" "failed nudge should leave a retry marker"
  assert_grep "selector=ap-copilot-instr" "$marker" "retry marker should pin the stable selector"
  assert_grep "message=autopilot was updated to the latest - please re-read your AGENTS.md to pick up the new instructions." \
    "$marker" "retry marker should pin the exact message"
  pass "T8c failed bootstrap nudge is surfaced and recorded for retry"
}

test_bootstrap_nudge_retry_is_idempotent() {
  local w c1 fakebin out marker out2
  w=$(new_world nudge-retry)
  c1=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-instr "$c1"
  bump_primary "$w" instr
  fakebin=$(make_fake_toolchain "$w")

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_SEND_SETTLE=0 AP_FAKE_TMUX_FAIL_LITERAL=1 \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "NUDGE_COPILOTS: copilot copilot-instr: send failed:" \
    "precondition: first nudge should fail"
  marker="$w/home/state/.copilot-nudge-pending/copilot-instr.pending"
  assert_present "$marker" "precondition: failed nudge should leave marker"

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_SEND_SETTLE=0 "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "BOOTSTRAP_INFO: nudged ap-copilot-instr with" \
    "retry should send the pending nudge once the endpoint works"
  assert_absent "$marker" "successful retry should clear the marker"

  out2=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_SEND_SETTLE=0 "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)
  [ -z "$out2" ] || fail "idempotent retry should converge to silence, got: $out2"
  pass "T8d bootstrap nudge retry is idempotent after success"
}

test_bootstrap_nudge_retry_refuses_changed_home() {
  local w c1 fakebin marker out other
  w=$(new_world nudge-retry-home-change)
  c1=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-instr "$c1"
  bump_primary "$w" instr
  fakebin=$(make_fake_toolchain "$w")

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_SEND_SETTLE=0 AP_FAKE_TMUX_FAIL_LITERAL=1 \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "NUDGE_COPILOTS: copilot copilot-instr: send failed:" \
    "precondition: first nudge should fail"
  marker="$w/home/state/.copilot-nudge-pending/copilot-instr.pending"
  assert_present "$marker" "precondition: failed nudge should leave marker"

  other="$w/copilot-other"
  git -C "$w/main" worktree add -q --detach "$other" "$(head_of "$w/copilot-instr")"
  printf '%s\n' copilot-instr > "$other/.ap-copilot-home"
  sed -i.bak "s|^home=.*|home=$other|" "$w/home/state/copilot-instr.meta" 2>/dev/null || \
    sed -i "s|^home=.*|home=$other|" "$w/home/state/copilot-instr.meta"
  rm -f "$w/home/state/copilot-instr.meta.bak"

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    AP_SEND_SETTLE=0 "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "NUDGE_COPILOTS: copilot copilot-instr: send failed: retry target home changed" \
    "retry must not infer a nudge target outside the recorded failed home"
  assert_present "$marker" "ambiguous retry should keep marker for operator inspection"
  pass "T8e bootstrap nudge retry refuses a changed home instead of guessing"
}

# --- T8b: stale herdr nudge failures retry through current ap-<id> metadata ---
# Reproduces the 2026-07-07 session-start bug: copilot_sync used to print raw
# backend targets (default:w9:pY) that liveness respawn immediately replaced
# (default:wA:p2), so ap-send with the printed target fell back to tmux and failed
# while ap-<id> resolved through current meta.
make_nudge_herdr_fake() {
  local dir=$1 stale=$2 fresh=$3 fakebin
  fakebin=$(ap_fakebin "$dir")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
cmd=\${1:-}; sub=\${2:-}; arg=\${3:-}
case "\$cmd \$sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "pane get")
    if [ "\$arg" = "${stale#*:}" ]; then
      printf '{"result":{"pane":{"pane_id":"${stale#*:}"}}}\n'
    elif [ "\$arg" = "${fresh#*:}" ]; then
      printf '{"result":{"pane":{"pane_id":"${fresh#*:}"}}}\n'
    else
      printf '{"error":{"code":"pane_not_found","message":"missing"}}\n' >&2
      exit 0
    fi
    ;;
  "agent get")
    if [ "\$arg" = "${stale#*:}" ]; then
      printf '{"error":{"code":"agent_not_found","message":"gone"}}\n' >&2
    elif [ "\$arg" = "${fresh#*:}" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found","message":"gone"}}\n' >&2
    fi
    ;;
  "pane send-text"|"pane run"|"pane send-keys")
    if [ "\$arg" = "${stale#*:}" ]; then
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

test_nudge_retry_uses_fresh_herdr_endpoint_after_respawn() {
  local w c1 stale fresh fakebin herdrfb toolchain out meta window resolved stale_send fresh_send spawn_stub marker
  stale=default:w9:pY
  fresh=default:wA:p2
  w=$(new_world nudge-herdr-rotate)
  c1=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-instr "$c1"
  bump_primary "$w" instr

  meta="$w/home/state/copilot-instr.meta"
  {
    printf 'window=%s\n' "$stale"
    printf 'backend=herdr\n'
    printf 'kind=copilot\n'
    printf 'harness=claude\n'
    printf 'home=%s/copilot-instr\n' "$w"
  } > "$meta"

  spawn_stub="$w/spawn-stub.sh"
  cat > "$spawn_stub" <<SH
#!/usr/bin/env bash
set -u
id=\${1:-}
meta="\$AP_HOME/state/\$id.meta"
[ -f "\$meta" ] || exit 1
sed -i.bak "s/^window=.*/window=$fresh/" "\$meta" 2>/dev/null || \
  sed -i "s/^window=.*/window=$fresh/" "\$meta"
rm -f "\$meta.bak"
exit 0
SH
  chmod +x "$spawn_stub"
  cp "$spawn_stub" "$w/main/bin/ap-spawn.sh"

  herdrfb=$(make_nudge_herdr_fake "$w/herdr" "$stale" "$fresh")
  toolchain=$(make_fake_toolchain "$w")
  if ! add_real_jq "$toolchain"; then
    pass "T8b nudge selector herdr respawn skipped without jq"
    return
  fi
  out=$(PATH="$herdrfb:$toolchain:$BASE_PATH" HERDR_ENV=1 AP_BACKEND=herdr \
    AP_SEND_SETTLE=0 \
    AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "NUDGE_COPILOTS: copilot copilot-instr: send failed:" \
    "stale herdr endpoint should surface a failed immediate nudge"

  window=$(grep '^window=' "$meta" | tail -1 | cut -d= -f2-)
  [ "$window" = "$fresh" ] || fail "respawn stub did not rotate meta window to '$fresh' (got '$window')"
  marker="$w/home/state/.copilot-nudge-pending/copilot-instr.pending"
  assert_present "$marker" "failed stale herdr nudge should leave a retry marker"

  # shellcheck disable=SC2016  # $0/$1 belong to the inner bash -c process.
  resolved=$(bash -c '. "$0/bin/ap-backend.sh"; ap_backend_resolve_selector ap-copilot-instr "$1"' "$ROOT" "$w/home/state")
  [ "$resolved" = "$fresh" ] || fail "ap-<id> should resolve through post-respawn meta, got '$resolved'"

  # shellcheck disable=SC2016  # $0/$1 belong to the inner bash -c process.
  stale_send=$(PATH="$herdrfb:$toolchain:$BASE_PATH" bash -c \
    '. "$0/bin/ap-backend.sh"; ap_backend_source herdr; ap_backend_herdr_send_literal "$1" "nudge"' "$ROOT" "$stale" 2>/dev/null; printf '%s' "$?")
  [ "$stale_send" != 0 ] || fail "explicit stale herdr endpoint send should fail"

  # shellcheck disable=SC2016  # $0/$1 belong to the inner bash -c process.
  fresh_send=$(PATH="$herdrfb:$toolchain:$BASE_PATH" bash -c \
    '. "$0/bin/ap-backend.sh"; ap_backend_source herdr; ap_backend_herdr_send_literal "$1" "nudge"' "$ROOT" "$fresh" 2>/dev/null; printf '%s' "$?")
  [ "$fresh_send" = 0 ] || fail "send through ap-<id>-resolved fresh endpoint should succeed"

  pass "T8b stale herdr nudge failures leave a retry marker after respawn rotates ap-<id> metadata"
}

# --- T9: bootstrap surfaces a skipped dirty live copilot home --------------
test_bootstrap_sweep_surfaces_skipped_home() {
  local w c1 base before fakebin out skip_line
  w=$(new_world boot-skip)
  c1=$(head_of "$w/main")
  add_copilot_worktree "$w" copilot-dirty "$c1"
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")
  printf 'uncommitted local edit\n' >> "$w/copilot-dirty/AGENTS.md"
  before=$(head_of "$w/copilot-dirty")

  fakebin=$(make_fake_toolchain "$w")
  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$w/home" AP_ROOT_OVERRIDE="$w/main" \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)

  skip_line=$(printf '%s\n' "$out" | grep '^COPILOT_SYNC: copilot copilot-dirty: skipped:' || true)
  [ -n "$skip_line" ] || fail "no COPILOT_SYNC skip line emitted (got: $out)"
  assert_contains "$skip_line" "dirty working tree" "dirty skipped home reports the actionable reason"
  [ "$(head_of "$w/copilot-dirty")" = "$before" ] || fail "dirty home HEAD moved"
  [ "$(head_of "$w/main")" = "$base" ] || fail "primary HEAD changed during bootstrap"
  grep -q 'uncommitted local edit' "$w/copilot-dirty/AGENTS.md" || fail "dirty edit was discarded"
  pass "T9 bootstrap surfaces a skipped dirty live copilot home"
}

# --- T10: spawning a copilot fast-forwards its worktree before launch ------
test_spawn_fast_forwards_before_launch() {
  local w c1 c2 fakebin
  w=$(new_world spawn-ff)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/copilot" "$c1"
  printf 'copilot\n' > "$w/copilot/.ap-copilot-home"
  mkdir -p "$w/copilot/data"
  printf 'charter\n' > "$w/copilot/data/charter.md"
  bump_primary "$w" instr
  c2=$(head_of "$w/main")
  [ "$(head_of "$w/copilot")" = "$c1" ] || fail "precondition: home should start behind the primary"

  # tmux stub: accept every subcommand, print nothing (so no window pre-exists).
  fakebin="$w/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"

  PATH="$fakebin:$BASE_PATH" TMUX='' \
    AP_ROOT_OVERRIDE="$w/main" AP_HOME="$w/home" \
    AP_STATE_OVERRIDE="$w/home/state" AP_DATA_OVERRIDE="$w/home/data" \
    AP_PROJECTS_OVERRIDE="$w/home/projects" AP_CONFIG_OVERRIDE="$w/home/config" \
    AP_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/ap-spawn.sh" copilot "$w/copilot" codex --copilot >/dev/null 2>&1 || true

  [ "$(head_of "$w/copilot")" = "$c2" ] \
    || fail "spawn did not fast-forward the copilot worktree to the primary's HEAD"
  pass "T10 spawn fast-forwards a copilot worktree to the primary's local HEAD before launch"
}

# --- T11: spawn warns when pre-launch sync is skipped ------------------------
test_spawn_warns_when_sync_skipped_before_launch() {
  local w c1 before fakebin err
  w=$(new_world spawn-skip)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/copilot" "$c1"
  printf 'copilot\n' > "$w/copilot/.ap-copilot-home"
  mkdir -p "$w/copilot/data"
  printf 'charter\n' > "$w/copilot/data/charter.md"
  bump_primary "$w" instr
  printf 'uncommitted local edit\n' >> "$w/copilot/AGENTS.md"
  before=$(head_of "$w/copilot")

  fakebin="$w/fakebin"
  err="$w/spawn.err"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"

  PATH="$fakebin:$BASE_PATH" TMUX='' \
    AP_ROOT_OVERRIDE="$w/main" AP_HOME="$w/home" \
    AP_STATE_OVERRIDE="$w/home/state" AP_DATA_OVERRIDE="$w/home/data" \
    AP_PROJECTS_OVERRIDE="$w/home/projects" AP_CONFIG_OVERRIDE="$w/home/config" \
    AP_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/ap-spawn.sh" copilot "$w/copilot" codex --copilot >/dev/null 2>"$err" || true

  assert_contains "$(cat "$err")" \
    "warning: copilot copilot sync skipped before launch: dirty working tree" \
    "spawn warning reports the skipped sync reason"
  [ "$(head_of "$w/copilot")" = "$before" ] || fail "dirty spawn home HEAD moved"
  grep -q 'uncommitted local edit' "$w/copilot/AGENTS.md" || fail "dirty spawn edit was discarded"
  pass "T11 spawn warns when pre-launch sync is skipped"
}

# --- T12: a freshly seeded home reads clean once the primary ignores the marker -
# The seed marker used to leave every home permanently dirty: bin/ap-fleet-sync.sh
# and any other plain `git status --porcelain` check counts the untracked marker,
# so a seeded home reported STUCK/dirty forever. With the marker in .gitignore, a
# home seeded from a primary that carries the fix reads clean to that exact signal.
test_seed_marker_clean_when_gitignored() {
  local w base
  w=$(new_world marker-clean)
  ignore_marker_commit "$w"                 # primary now ignores the marker
  base=$(primary_head_commit "$w/main")
  seed_marked_home "$w" copilot "$base"          # fresh home at the post-fix HEAD

  # The exact dirtiness signal bin/ap-fleet-sync.sh reads (its line: dirty=yes when
  # `git status --porcelain | head -1` is non-empty).
  [ -z "$(git -C "$w/copilot" status --porcelain)" ] \
    || fail "seed marker still dirties a fresh home: $(git -C "$w/copilot" status --porcelain)"
  # And the copilot ff sweep sees no dirt: an at-HEAD home is a clean no-op.
  run_ff "$w/copilot" "$base"
  [ "$FF_STATUS" = current ] || fail "fresh home not read as clean/current, got '$FF_STATUS': $FF_OUT"
  pass "T12 gitignored marker: a freshly seeded home reads clean to fleet-sync and the ff sweep"
}

# --- T13: an existing marker-only-dirty home converges on the next sweep --------
# The convergence chicken-and-egg: existing homes predate the fix, so their marker
# is still untracked-and-unignored, and the fix itself only arrives by fast-forward.
# The marker-tolerant ff-skip (ignore_seed_marker=yes) bridges the gap for
# linked-worktree homes, which bootstrap/spawn fast-forward from the primary's local HEAD.
# Standalone-clone homes converge through /updateautopilot's origin fetch instead.
# Once advanced, the now-ignored marker reads clean with no hand intervention.
test_seed_marker_converges_existing_home() {
  local w c0 base
  w=$(new_world marker-converge)            # primary does NOT ignore the marker yet
  c0=$(head_of "$w/main")
  seed_marked_home "$w" copilot "$c0"            # existing home predates the fix
  [ -n "$(git -C "$w/copilot" status --porcelain)" ] \
    || fail "precondition: the untracked marker should dirty a pre-fix home"
  ignore_marker_commit "$w"                 # THE FIX lands as a later commit
  base=$(primary_head_commit "$w/main")

  run_ff "$w/copilot" "$base"                     # the marker-tolerant convergence sweep

  [ "$FF_STATUS" = updated ] || fail "existing marker-only home did not converge, got '$FF_STATUS': $FF_OUT"
  [ "$(head_of "$w/copilot")" = "$base" ] || fail "home did not fast-forward to the fix commit"
  [ -z "$(git -C "$w/copilot" status --porcelain)" ] \
    || fail "marker still dirty after convergence: $(git -C "$w/copilot" status --porcelain)"
  pass "T13 gitignored marker: an existing marker-only-dirty home converges, then reads clean"
}

# --- T14: marker tolerance does not mask a genuinely dirty home -----------------
# The ff-skip only forgives the seed marker; a real uncommitted change alongside the
# marker must still refuse the fast-forward and leave the work untouched, exactly as
# before this fix.
test_seed_marker_does_not_mask_real_dirt() {
  local w c0 base before
  w=$(new_world marker-real-dirt)
  c0=$(head_of "$w/main")
  seed_marked_home "$w" copilot "$c0"
  printf 'real local change\n' >> "$w/copilot/AGENTS.md"   # genuine tracked-file edit + the marker
  before=$(head_of "$w/copilot")
  ignore_marker_commit "$w"
  base=$(primary_head_commit "$w/main")

  run_ff "$w/copilot" "$base"

  [ "$FF_STATUS" = skipped ] || fail "a genuinely dirty home must skip, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "copilot copilot: skipped: dirty working tree" \
    "a genuinely dirty home is skipped even with the marker present"
  [ "$(head_of "$w/copilot")" = "$before" ] || fail "genuinely dirty home HEAD moved (work at risk)"
  grep -q 'real local change' "$w/copilot/AGENTS.md" || fail "genuine local edit was discarded"
  pass "T14 marker tolerance does not mask a genuinely dirty home"
}

test_ff_updated
test_ff_current
test_ff_dirty
test_ff_diverged
test_ff_inflight_feature_branch
test_no_fetch_in_local_path
test_sweep_nudge_requires_instruction_change
test_bootstrap_sweep_nudges_only_instruction_change
test_bootstrap_nudge_send_uses_state_override
test_bootstrap_nudge_retry_rejects_malformed_marker_id
test_bootstrap_nudge_failure_records_retry_marker
test_bootstrap_nudge_retry_is_idempotent
test_bootstrap_nudge_retry_refuses_changed_home
test_nudge_retry_uses_fresh_herdr_endpoint_after_respawn
test_bootstrap_sweep_surfaces_skipped_home
test_spawn_fast_forwards_before_launch
test_spawn_warns_when_sync_skipped_before_launch
test_seed_marker_clean_when_gitignored
test_seed_marker_converges_existing_home
test_seed_marker_does_not_mask_real_dirt

echo "# all ap-copilot-sync tests passed"
