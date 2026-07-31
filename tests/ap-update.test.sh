#!/usr/bin/env bash
# Tests for bin/ap-update.sh: fast-forward-only self-update of a running
# autopilot repo and every registered copilot home.
#
# The guarantees under test mirror ap-fleet-sync.sh and prime directive #3:
#   - The running autopilot repo (on its default branch) fast-forwards from
#     origin; a leased copilot home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-autopilot flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-copilots lists exactly the live copilots that advanced.
#   - Copilot homes resolve from both state/<id>.meta and the
#     data/copilots.md registry, deduped, and the autopilot repo is never
#     re-processed as one of its own copilots.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/ap-update.sh"

# Deterministic, isolated git identity for fixture commits.
ap_git_identity fmtest fmtest@example.com

TMP_ROOT=$(ap_test_tmproot ap-update-tests)
REAL_GIT=$(command -v git)

# Build a fresh world: a bare origin seeded with one commit, an autopilot repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps ap-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$w/main" remote set-url origin https://github.com/hxutixnnn/autopilot.git
  mkdir -p "$w/fakebin"
  cat > "$w/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = -C ] && [ "${3:-}" = fetch ] && [ "${4:-}" = origin ]; then
  printf '%s\n' 'fetch origin' >> "${AP_TEST_FETCH_LOG:?}"
  exec "${AP_TEST_REAL_GIT:?}" -C "$2" fetch "${AP_TEST_FETCH_SOURCE:?}" \
    '+refs/heads/*:refs/remotes/origin/*' --prune --quiet
fi
exec "${AP_TEST_REAL_GIT:?}" "$@"
SH
  chmod +x "$w/fakebin/git"

  printf '%s\n' "$w"
}

# Add a copilot home as a DETACHED worktree of the autopilot repo (matching
# how treehouse leases a copilot home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:ap-%s\n' "$id"
    printf 'kind=copilot\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.ap-copilot-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  : > "$w/fetch.log"
  AP_TEST_REAL_GIT="$REAL_GIT" AP_TEST_FETCH_SOURCE="$w/origin.git" \
    AP_TEST_FETCH_LOG="$w/fetch.log" PATH="$w/fakebin:$PATH" \
    AP_ROOT_OVERRIDE="$w/main" AP_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + copilot behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_copilot() {
  local w out
  w=$(new_world t1)
  add_sm "$w" copilot1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "autopilot: updated " "autopilot fast-forwarded"
  assert_contains "$out" "copilot copilot1: updated " "copilot fast-forwarded"
  assert_contains "$out" "reread-autopilot: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-copilots: ap-copilot1" "updated copilot is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "autopilot HEAD not at origin/main"
  [ "$(git -C "$w/copilot1" rev-parse HEAD)" = "$(git -C "$w/copilot1" rev-parse origin/main)" ] \
    || fail "copilot HEAD not at origin/main"
  # Autopilot stays on its default branch; copilot stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "autopilot left its default branch"
  git -C "$w/copilot1" symbolic-ref -q HEAD >/dev/null \
    && fail "copilot worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "autopilot tip is not a single-parent fast-forward"
  [ "$(git -C "$w/copilot1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "copilot tip is not a single-parent fast-forward"
  pass "T1 main + copilot fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" copilot1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "autopilot: updated " "autopilot still advanced"
  assert_contains "$out" "reread-autopilot: no" "non-instruction change skips reread"
  # The copilot still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-copilots: ap-copilot1" "advanced copilot still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty copilot is skipped, its edit preserved -------------------
test_dirty_copilot_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" copilot1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/copilot1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "copilot copilot1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "ap-copilot1" "skipped copilot is not nudged"
  grep -q 'uncommitted local edit' "$w/copilot1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty copilot skipped, local edit preserved"
}

# --- T5: diverged copilot is skipped, its commit preserved --------------
test_diverged_copilot_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" copilot1
  # Local commit on the copilot's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/copilot1/AGENTS.md"
  git -C "$w/copilot1" add -A
  git -C "$w/copilot1" commit -qm local-work
  before=$(git -C "$w/copilot1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "copilot copilot1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "ap-copilot1" "diverged copilot is not nudged"
  [ "$(git -C "$w/copilot1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged copilot HEAD moved (unlanded work at risk)"
  pass "T5 diverged copilot skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" copilot1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "autopilot: already current" "autopilot already current"
  assert_contains "$out" "copilot copilot1: already current" "copilot already current"
  assert_contains "$out" "reread-autopilot: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-copilots: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every copilot-resolution edge at once:
#   reg1 - registered in copilots.md only, NO live meta (registry backstop);
#   copilot1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the autopilot repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); copilot1 advances,
# is processed once, and IS nudged; the autopilot repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" copilot1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.ap-copilot-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- copilot1 - dup (home: %s/copilot1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/copilots.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "copilot reg1: updated " "registry-only copilot fast-forwarded"
  assert_contains "$out" "copilot copilot1: updated " "meta+registry copilot fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^copilot copilot1:' || true)
  [ "$count" -eq 1 ] || fail "copilot copilot1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "copilot selfish" "autopilot repo re-processed as its own copilot"
  # copilot1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'copilot reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-copilots:')
  assert_contains "$nudge_line" "ap-copilot1" "live-meta copilot is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only copilot without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the autopilot repo"
}

# --- T9: autopilot repo on a feature branch is skipped ---------------------
test_autopilot_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate autopilot mid-delivery its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "autopilot: skipped: on feature/wip, expected main" "off-default autopilot skipped"
  assert_contains "$out" "reread-autopilot: no" "no reread when autopilot was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped autopilot HEAD moved"
  pass "T9 autopilot off its default branch is skipped, not forced"
}

test_autopilot_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "autopilot: skipped: detached HEAD, expected main" "detached autopilot skipped"
  assert_contains "$out" "reread-autopilot: no" "no reread when detached autopilot was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached autopilot HEAD moved"
  pass "T10 autopilot detached HEAD is skipped"
}

test_unsafe_copilot_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.ap-copilot-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/copilots.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "copilot bad: skipped: unsafe home: copilot home cannot be inside the active autopilot home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-copilots: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe copilot home HEAD moved"
  pass "T11 unsafe copilot home is not fast-forwarded"
}

test_refuses_noncanonical_origins_without_fallback() {
  local w out before
  w=$(new_world canonical-refusal)
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" remote set-url origin "https://github.com/unrelated/autopilot.git"
  git -C "$w/main" remote add upstream "$w/origin.git"

  out=$(run_update "$w")

  assert_contains "$out" "autopilot: skipped: origin is not canonical hxutixnnn/autopilot" \
    "noncanonical owner was not refused clearly"
  [ ! -s "$w/fetch.log" ] || fail "refused noncanonical owner still reached fetch"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "refused source moved HEAD"

  git -C "$w/main" remote set-url origin https://github.com/hxutixnnn/not-autopilot.git
  out=$(run_update "$w")
  assert_contains "$out" "autopilot: skipped: origin is not canonical hxutixnnn/autopilot" \
    "unrelated source was not refused clearly"
  [ ! -s "$w/fetch.log" ] || fail "refused unrelated source still reached fetch"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "refused source moved HEAD"
  [ -z "$(git -C "$w/main" show-ref refs/remotes/upstream/main 2>/dev/null || true)" ] \
    || fail "self-update fetched fallback upstream"
  pass "canonical source validation refuses old and unrelated origins without upstream fallback"
}

test_updates_main_and_copilot
test_reread_gate_is_instruction_only
test_dirty_copilot_skipped
test_diverged_copilot_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_autopilot_wrong_branch_skipped
test_autopilot_detached_head_skipped
test_unsafe_copilot_home_skipped_before_git_update
test_refuses_noncanonical_origins_without_fallback

echo "# all ap-update tests passed"
