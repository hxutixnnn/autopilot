#!/usr/bin/env bash
# tests/ap-copilot-safety.test.sh - copilot home safety invariants:
# the path-boundary matrices (seed/spawn/teardown), registry/charter/origin
# validation, treehouse lease handling, no-mistakes initialization of new
# clones, child-worktree protection, and backlog-handoff safety. The happy-path
# operator flow lives in ap-copilot-lifecycle-e2e.test.sh; this file keeps the
# destructive-invariant coverage that an e2e run cannot deterministically reach.
set -u

# shellcheck source=tests/copilot-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/copilot-helpers.sh"

TMP_ROOT=$(ap_test_tmproot ap-copilot-safety)
export AP_BACKEND=tmux

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_ap_home_parameterization() {
  local brief home_one home_two out
  home_one="$TMP_ROOT/home one"
  home_two="$TMP_ROOT/home-two"
  mkdir -p "$home_one/data" "$home_one/state" "$home_two/data" "$home_two/state"
  printf '%s\n' '- app [local-only +yolo] - test app (added 2026-06-22)' > "$home_one/data/projects.md"

  out=$(AP_HOME="$home_one" "$ROOT/bin/ap-project-mode.sh" app)
  [ "$out" = "local-only on" ] || fail "ap-project-mode did not read projects.md from AP_HOME"
  out=$(AP_HOME="$home_two" "$ROOT/bin/ap-project-mode.sh" app 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "ap-project-mode did not isolate missing registry by home"

  AP_HOME="$home_one" "$ROOT/bin/ap-brief.sh" task-a app >/dev/null || fail "brief scaffold failed under AP_HOME"
  brief="$home_one/data/task-a/brief.md"
  [ -f "$brief" ] || fail "brief was not written under AP_HOME/data"
  grep -F ">> '$home_one/state/task-a.status'" "$brief" >/dev/null || fail "brief did not shell-quote AP_HOME state path"

  AP_HOME="$home_one" "$ROOT/bin/ap-brief.sh" task-b app --recon >/dev/null || fail "recon brief scaffold failed under AP_HOME"
  brief="$home_one/data/task-b/brief.md"
  grep -F ">> '$home_one/state/task-b.status'" "$brief" >/dev/null || fail "recon brief did not shell-quote AP_HOME state path"

  AP_HOME="$home_one" AP_COPILOT_CHARTER='ops domain' "$ROOT/bin/ap-brief.sh" task-c --copilot app >/dev/null \
    || fail "copilot brief scaffold failed under AP_HOME"
  brief="$home_one/data/task-c/brief.md"
  grep -F ">> '$home_one/state/task-c.status'" "$brief" >/dev/null || fail "copilot brief did not shell-quote AP_HOME state path"

  printf 'project=x\n' > "$home_one/state/task-a.meta"
  AP_HOME="$home_one" AP_GUARD_GRACE=999999 "$ROOT/bin/ap-pr-check.sh" task-a https://github.com/example/repo/pull/1 >/dev/null 2>/dev/null \
    || fail "ap-pr-check failed under AP_HOME"
  [ -f "$home_one/state/task-a.check.sh" ] || fail "pr check was not written under AP_HOME/state"
  [ ! -e "$home_two/state/task-a.check.sh" ] || fail "pr check leaked into another home"
  pass "AP_HOME parameterizes data and state paths"
}

test_lock_status_is_per_home() {
  local home_one home_two out
  home_one="$TMP_ROOT/lock-one"
  home_two="$TMP_ROOT/lock-two"
  mkdir -p "$home_one/state" "$home_two/state"
  printf '999999\n' > "$home_one/state/.lock"
  out=$(AP_HOME="$home_one" "$ROOT/bin/ap-lock.sh" status)
  printf '%s\n' "$out" | grep -F 'lock: stale' >/dev/null || fail "home one lock status did not read its own lock"
  out=$(AP_HOME="$home_two" "$ROOT/bin/ap-lock.sh" status)
  [ "$out" = "lock: free" ] || fail "home two lock status was affected by home one"
  pass "ap-lock status is scoped per home"
}

test_seed_allows_overlapping_clones_and_drops_owner() {
  # A project may appear in several copilots' (non-exclusive) clone lists; the
  # registry never uses the legacy owns: field, and the removed `owner` subcommand
  # stays gone. The full happy seed - charter copied, clones+origins, no-mistakes
  # init, modes preserved - is asserted by ap-copilot-lifecycle-e2e.
  local home design other
  home="$TMP_ROOT/overlap-main"
  design="$TMP_ROOT/overlap-design"
  other="$TMP_ROOT/overlap-other"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_init_commit "$home/projects/beta"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/seed-overlap-alpha.git"
  ap_git_add_origin "$home/projects/beta" "$TMP_ROOT/remotes/seed-overlap-beta.git"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  AP_HOME="$home" AP_COPILOT_CHARTER='feature design for alpha beta' \
    AP_COPILOT_SCOPE='feature design for alpha beta' \
    "$ROOT/bin/ap-home-seed.sh" design "$design" alpha beta >/dev/null \
    || fail "initial seed failed"
  assert_grep '- design - feature design for alpha beta' "$home/data/copilots.md" "design registry line missing"
  assert_grep 'projects: alpha, beta' "$home/data/copilots.md" "design project clone list missing"
  assert_no_grep 'owns:' "$home/data/copilots.md" "registry used the legacy owns field"

  # beta is shared with a second copilot of a different scope (overlap allowed).
  AP_HOME="$home" AP_COPILOT_CHARTER='issue triage for beta' \
    AP_COPILOT_SCOPE='issue triage for beta' \
    "$ROOT/bin/ap-home-seed.sh" other "$other" beta >/dev/null 2>&1 \
    || fail "seed refused overlapping project clones across different scopes"
  assert_grep '- other - issue triage for beta' "$home/data/copilots.md" "overlapping registry line missing"
  AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" validate >/dev/null || fail "registry validation rejected overlapping clones"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" owner alpha >/dev/null 2>&1; then
    fail "owner subcommand still succeeded after routing moved to scopes"
  fi
  pass "seed allows overlapping project clone lists and drops the owns/owner routing"
}

test_home_seed_validate_rejects_duplicate_homes() {
  local home copilot_home subhome_abs err
  home="$TMP_ROOT/duplicate-home"
  copilot_home="$TMP_ROOT/duplicate-copilot_home"
  err="$TMP_ROOT/duplicate-home.err"
  mkdir -p "$home/data" "$copilot_home"
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  cat > "$home/data/copilots.md" <<EOF
- design - design domain mentions home: $TMP_ROOT/ignored-summary-home (home: $subhome_abs; scope: design work mentions home: $TMP_ROOT/ignored-scope-home; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $subhome_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two copilots with the same home"
  fi
  grep -F 'duplicate copilot home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate home assignment"
  pass "home seed validation rejects duplicate home routes"
}

test_home_seed_validate_rejects_duplicate_ids() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/duplicate-id-home"
  first="$TMP_ROOT/duplicate-id-first"
  second="$TMP_ROOT/duplicate-id-second"
  err="$TMP_ROOT/duplicate-id.err"
  mkdir -p "$home/data" "$first" "$second"
  first_abs=$(cd "$first" && pwd -P)
  second_abs=$(cd "$second" && pwd -P)
  cat > "$home/data/copilots.md" <<EOF
- design - design domain (home: $first_abs; scope: design work; projects: alpha; added 2026-06-22)
- design - design domain (home: $second_abs; scope: design work; projects: beta; added 2026-06-22)
EOF

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two homes for the same copilot id"
  fi
  grep -F 'duplicate copilot id assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate id assignment"
  pass "home seed validation rejects duplicate id routes"
}

test_home_seed_validate_rejects_nested_homes() {
  local home ancestor descendant ancestor_abs descendant_abs err
  home="$TMP_ROOT/nested-home"
  ancestor="$TMP_ROOT/nested-domain-a"
  descendant="$ancestor/domain-b"
  err="$TMP_ROOT/nested-home.err"
  mkdir -p "$home/data" "$ancestor" "$descendant"
  ancestor_abs=$(cd "$ancestor" && pwd -P)
  descendant_abs=$(cd "$descendant" && pwd -P)
  cat > "$home/data/copilots.md" <<EOF
- design - design domain (home: $ancestor_abs; scope: design work; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $descendant_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted nested copilot homes"
  fi
  grep -F 'overlapping copilot home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain nested home assignment"
  pass "home seed validation rejects nested home routes"
}

test_home_seed_uses_treehouse_acquired_home() {
  local home acquired acquired_abs fakebin log lease out
  home="$TMP_ROOT/dash-home"
  acquired="$TMP_ROOT/dash-acquired-home"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fake")
  log="$TMP_ROOT/dash-fake/tmux.log"
  lease="$TMP_ROOT/dash-fake/lease"

  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TREEHOUSE_HOME="$acquired" AP_FAKE_TMUX_LOG="$log" \
    AP_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    AP_COPILOT_CHARTER='dash acquired scope' AP_COPILOT_SCOPE='dash acquired scope' \
    "$ROOT/bin/ap-home-seed.sh" dash - alpha) \
    || fail "seed failed for a treehouse-acquired home"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$acquired_abs" >/dev/null || fail "seed did not report acquired home"
  grep -F 'treehouse get --lease --lease-holder dash' "$log" >/dev/null || fail "seed did not durably lease a home under the copilot id"
  [ -f "$lease" ] || fail "seed did not record a treehouse lease"
  [ "$(cat "$lease")" = dash ] || fail "seed did not set the lease holder to the copilot id"
  [ -f "$acquired/.ap-copilot-home" ] || fail "seed did not mark acquired home"
  [ "$(cat "$acquired/.ap-copilot-home")" = dash ] || fail "seed wrote wrong acquired-home marker"
  [ -d "$acquired/projects/alpha/.git" ] || fail "seed did not clone project into acquired home"
  grep -F "home: $acquired_abs" "$home/data/copilots.md" >/dev/null || fail "registry did not record acquired home"
  pass "home seeding durably leases treehouse-acquired dash homes under the copilot id"
}

test_home_seed_returns_treehouse_acquired_home_on_assignment_failure() {
  local home acquired acquired_abs fakebin log err
  home="$TMP_ROOT/dash-fail-home"
  acquired="$TMP_ROOT/dash-fail-acquired-home"
  err="$TMP_ROOT/dash-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.ap-copilot-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fail-fake")
  log="$TMP_ROOT/dash-fail-fake/tmux.log"

  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TREEHOUSE_HOME="$acquired" AP_FAKE_TMUX_LOG="$log" \
    AP_COPILOT_CHARTER='dash acquired scope' AP_COPILOT_SCOPE='dash acquired scope' \
    "$ROOT/bin/ap-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home marked for another copilot"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain acquired marked-home rejection"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed acquired seed did not return the home through treehouse"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- dash ' "$home/data/copilots.md" >/dev/null; then
    fail "failed acquired seed left a registry route"
  fi
  pass "home seeding returns rejected acquired homes through treehouse"
}

test_home_seed_warns_when_acquired_home_return_fails() {
  local home acquired acquired_abs fakebin log err lease
  home="$TMP_ROOT/dash-return-fail-home"
  acquired="$TMP_ROOT/dash-return-fail-acquired-home"
  err="$TMP_ROOT/dash-return-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-return-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.ap-copilot-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-return-fail-fake")
  log="$TMP_ROOT/dash-return-fail-fake/tmux.log"
  lease="$TMP_ROOT/dash-return-fail-fake/lease"

  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TREEHOUSE_HOME="$acquired" AP_FAKE_TMUX_LOG="$log" \
    AP_FAKE_TREEHOUSE_LEASE_FILE="$lease" AP_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    AP_COPILOT_CHARTER='dash acquired scope' AP_COPILOT_SCOPE='dash acquired scope' \
    "$ROOT/bin/ap-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home after return failure setup"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not report original acquired-home rejection"
  grep -F "warning: failed to return treehouse-acquired home $acquired_abs during seed rollback" "$err" >/dev/null \
    || fail "seed rollback did not warn when treehouse return failed"
  [ -f "$lease" ] || fail "failed rollback return did not preserve lease evidence"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed rollback did not attempt to return the acquired home"
  pass "home seed rollback warns when treehouse-acquired return fails"
}

test_home_seed_does_not_return_unsafe_acquired_home() {
  local home descendant fakebin log err
  home="$TMP_ROOT/dash-active-home"
  descendant="$home/data/dash-descendant-home"
  err="$TMP_ROOT/dash-active.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-active-fake")
  log="$TMP_ROOT/dash-active-fake/tmux.log"

  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TREEHOUSE_HOME="$home" AP_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/ap-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home matching the active autopilot home"
  fi
  grep -F 'copilot home cannot be the active autopilot home' "$err" >/dev/null \
    || fail "seed did not explain active acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active home through treehouse"
  [ -d "$home/projects/alpha" ] || fail "unsafe acquired-home rollback removed the active home"

  : > "$log"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TREEHOUSE_HOME="$descendant" AP_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/ap-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home inside the active autopilot home"
  fi
  grep -F 'copilot home cannot be inside the active autopilot home' "$err" >/dev/null \
    || fail "seed did not explain active descendant acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active descendant through treehouse"
  [ -d "$descendant" ] || fail "unsafe acquired-home rollback removed the active descendant"
  pass "home seeding leaves unsafe acquired active homes untouched"
}

test_home_seed_rolls_back_failed_clone() {
  local home copilot_home err missing_remote
  home="$TMP_ROOT/rollback-home"
  copilot_home="$TMP_ROOT/rollback-copilot_home"
  err="$TMP_ROOT/rollback-home.err"
  missing_remote="$TMP_ROOT/remotes/missing-beta.git"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_init_commit "$home/projects/beta"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/rollback-alpha.git"
  git -C "$home/projects/beta" remote add origin "file://$missing_remote"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  if AP_HOME="$home" AP_COPILOT_CHARTER='rollback scope' AP_COPILOT_SCOPE='rollback scope' \
    "$ROOT/bin/ap-home-seed.sh" rollback "$copilot_home" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though the second project clone failed"
  fi
  grep -F 'does not appear to be a git repository' "$err" >/dev/null \
    || grep -F 'repository' "$err" >/dev/null \
    || fail "seed failure did not include the clone error"
  [ ! -e "$copilot_home" ] || fail "failed seed left the newly created copilot home behind"
  [ ! -e "$copilot_home/.ap-copilot-home" ] || fail "failed seed left a copilot_home marker"
  [ ! -e "$copilot_home/projects/alpha" ] || fail "failed seed left a previously cloned project"
  [ ! -e "$home/data/rollback/brief.md" ] || fail "failed seed left a generated charter brief"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- rollback ' "$home/data/copilots.md" >/dev/null; then
    fail "failed seed left a registry route"
  fi
  pass "home seeding rolls back failed clone attempts without residue"
}

test_home_seed_refuses_missing_filled_charter() {
  local home copilot_home err
  home="$TMP_ROOT/missing-charter-home"
  copilot_home="$TMP_ROOT/missing-charter-copilot_home"
  err="$TMP_ROOT/missing-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/missing-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a direct seed without a filled charter"
  fi
  grep -F 'no filled copilot charter brief' "$err" >/dev/null \
    || fail "seed did not explain missing filled charter refusal"
  [ ! -e "$copilot_home" ] || fail "missing charter seed left a generated copilot_home"
  [ ! -e "$home/data/design/brief.md" ] || fail "missing charter seed generated a placeholder charter"
  pass "home seeding refuses direct seed without filled charter text"
}

test_home_seed_refuses_placeholder_charter() {
  local home copilot_home err
  home="$TMP_ROOT/placeholder-charter-home"
  copilot_home="$TMP_ROOT/placeholder-charter-copilot_home"
  err="$TMP_ROOT/placeholder-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/placeholder-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  AP_HOME="$home" "$ROOT/bin/ap-brief.sh" design --copilot alpha >/dev/null \
    || fail "placeholder charter scaffold failed"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an unfilled placeholder charter"
  fi
  grep -F 'still contains {TASK}' "$err" >/dev/null \
    || fail "seed did not explain placeholder charter refusal"
  [ ! -e "$copilot_home" ] || fail "placeholder charter seed left a generated copilot_home"
  [ ! -e "$copilot_home/projects/alpha" ] || fail "placeholder charter seed cloned before refusing"
  pass "home seeding refuses unfilled placeholder charters"
}

test_home_seed_refuses_empty_charter_fields() {
  local home copilot_home err
  home="$TMP_ROOT/empty-charter-home"
  copilot_home="$TMP_ROOT/empty-charter-copilot_home"
  err="$TMP_ROOT/empty-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/empty-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if AP_HOME="$home" AP_COPILOT_CHARTER='   ' "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a whitespace-only charter"
  fi
  grep -F 'empty Charter section' "$err" >/dev/null \
    || fail "seed did not explain empty charter refusal"
  [ ! -e "$copilot_home" ] || fail "empty charter seed left a generated copilot_home"

  rm -rf "$home/data/design" "$copilot_home" "$err"
  AP_COPILOT_SCOPE='   ' scaffold_copilot_charter "$home" design 'filled charter' alpha \
    || fail "empty scope fixture scaffold failed"
  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an empty routing scope"
  fi
  grep -F 'empty Routing scope section' "$err" >/dev/null \
    || fail "seed did not explain empty routing scope refusal"
  [ ! -e "$copilot_home" ] || fail "empty routing scope seed left a generated copilot_home"
  pass "home seeding refuses empty normalized charter fields"
}

test_home_seed_no_projects_end_to_end() {
  # A domain whose subject is the autopilot repo itself needs no project clones:
  # the deliberate --no-projects signal scaffolds, seeds, registers, and spawns a
  # project-less home end to end with no placeholder clone.
  local home sub sub_abs fakebin log meta proj_val out
  home="$TMP_ROOT/no-projects-seed-home"
  sub="$TMP_ROOT/no-projects-seed-copilot_home"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fakebin=$(make_fake_tmux "$TMP_ROOT/no-projects-fake")
  log="$TMP_ROOT/no-projects-fake/tmux.log"

  out=$(AP_HOME="$home" AP_COPILOT_CHARTER='autopilot self-development' \
    AP_COPILOT_SCOPE='autopilot repo work' \
    "$ROOT/bin/ap-home-seed.sh" fdev "$sub" --no-projects) \
    || fail "project-less seed failed"
  sub_abs=$(cd "$sub" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$sub_abs" >/dev/null || fail "seed did not report the project-less copilot_home"

  # Registered with an empty projects field, marked, charter copied, no clones.
  assert_grep '- fdev - autopilot self-development' "$home/data/copilots.md" "project-less registry line missing"
  assert_grep 'scope: autopilot repo work' "$home/data/copilots.md" "project-less registry scope missing"
  assert_grep 'projects: ;' "$home/data/copilots.md" "project-less registry did not render an empty projects field"
  [ "$(cat "$sub/.ap-copilot-home")" = fdev ] || fail "project-less seed did not mark the copilot_home"
  assert_present "$sub/data/charter.md" "project-less seed did not copy the charter"
  [ -z "$(ls -A "$sub/projects" 2>/dev/null)" ] || fail "project-less seed cloned a project"
  AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" validate >/dev/null || fail "registry validation failed after project-less seed"

  # Spawn tolerates the empty projects field: the home resolves from the registry
  # and the projects meta is recorded empty rather than breaking the launch.
  : > "$log"
  PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" \
    AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/no-projects-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" fdev "$sub" codex --copilot >/dev/null 2>&1 \
    || fail "project-less copilot spawn failed"
  meta="$home/state/fdev.meta"
  assert_grep 'kind=copilot' "$meta" "project-less spawn meta lost kind=copilot"
  assert_grep "home=$sub_abs" "$meta" "project-less spawn meta lost the copilot_home"
  proj_val=$(grep '^projects=' "$meta" | head -1 | cut -d= -f2-)
  [ -z "$proj_val" ] || fail "project-less spawn recorded a non-empty projects meta: '$proj_val'"
  pass "home seeding scaffolds, registers, and spawns a project-less home end to end"
}

test_home_seed_refuses_projectful_reused_charter_for_projectless_home() {
  local home reusable_sub stale_sub stale_brief stale_brief_before err
  home="$TMP_ROOT/no-projects-reused-charter-home"
  reusable_sub="$TMP_ROOT/no-projects-reused-charter-valid-copilot_home"
  stale_sub="$TMP_ROOT/no-projects-reused-charter-stale-copilot_home"
  stale_brief="$home/data/stale/brief.md"
  stale_brief_before="$TMP_ROOT/no-projects-reused-charter.before"
  err="$TMP_ROOT/no-projects-reused-charter.err"
  mkdir -p "$home/data" "$home/state" "$reusable_sub/data" "$stale_sub/data"
  mark_autopilot_home "$reusable_sub"
  mark_autopilot_home "$stale_sub"

  scaffold_copilot_charter "$home" reusable 'autopilot self-development' --no-projects \
    || fail "project-less charter scaffold failed"
  printf '\n# Custom note\nThe projects above are local clones for work you supervise.\n' >> "$home/data/reusable/brief.md"
  AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" reusable "$reusable_sub" --no-projects >/dev/null \
    || fail "project-less seed rejected a reused project-less charter"
  assert_grep 'None. This is a project-less domain' "$reusable_sub/data/charter.md" \
    "reused project-less charter was not copied"

  scaffold_copilot_charter "$home" stale 'autopilot self-development. None. This is a project-less domain.' alpha \
    || fail "projectful charter scaffold failed"
  sed 's/The projects above are local clones for work you supervise; they are not an exclusive ownership claim./Project clone details are customized for this domain./' \
    "$stale_brief" > "$stale_brief_before"
  mv "$stale_brief_before" "$stale_brief"
  cp "$stale_brief" "$stale_brief_before"
  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" stale "$stale_sub" --no-projects >/dev/null 2>"$err"; then
    fail "project-less seed accepted a reused charter with project clones"
  fi
  grep -F 'existing charter brief' "$err" >/dev/null \
    || fail "project-less charter refusal did not name the stale charter conflict"
  grep -F 'ap-brief.sh stale --copilot --no-projects' "$err" >/dev/null \
    || fail "project-less charter refusal did not explain how to re-scaffold"
  cmp -s "$stale_brief_before" "$stale_brief" \
    || fail "project-less charter refusal changed the reused charter"
  assert_absent "$stale_sub/.ap-copilot-home" "project-less charter refusal wrote a home marker"
  assert_absent "$stale_sub/data/charter.md" "project-less charter refusal copied a charter"
  assert_absent "$stale_sub/projects" "project-less charter refusal created a projects directory"
  if grep -F -- '- stale ' "$home/data/copilots.md" >/dev/null; then
    fail "project-less charter refusal wrote a parent registry route"
  fi
  pass "home seeding validates reused project-less charters before mutation"
}

test_home_seed_refuses_projectless_conversion_of_populated_home() {
  local home sub err registry_before
  home="$TMP_ROOT/no-projects-conversion-home"
  sub="$TMP_ROOT/no-projects-conversion-copilot_home"
  err="$TMP_ROOT/no-projects-conversion.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$sub/projects/existing-clone"
  mark_autopilot_home "$sub"
  ap_git_init_commit "$sub/projects/existing-clone"
  cat > "$sub/data/projects.md" <<EOF
- registry-only [direct-PR] - retained project entry (added 2026-06-22)
EOF
  registry_before=$(cat "$sub/data/projects.md")

  if AP_HOME="$home" AP_COPILOT_CHARTER='autopilot self-development' \
    AP_COPILOT_SCOPE='autopilot repo work' \
    "$ROOT/bin/ap-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    fail "project-less seed converted a populated copilot home"
  fi
  grep -F 'existing-clone' "$err" >/dev/null \
    || fail "project-less conversion refusal did not name the existing clone"
  grep -F 'registry-only' "$err" >/dev/null \
    || fail "project-less conversion refusal did not name the registry entry"
  grep -F 'retire or clean this home first' "$err" >/dev/null \
    || fail "project-less conversion refusal did not explain the required cleanup"
  assert_present "$sub/projects/existing-clone/.git" "project-less conversion refusal removed the existing clone"
  [ "$registry_before" = "$(cat "$sub/data/projects.md")" ] \
    || fail "project-less conversion refusal changed the project registry"
  assert_absent "$sub/.ap-copilot-home" "project-less conversion refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less conversion refusal copied a charter"
  assert_absent "$sub/state" "project-less conversion refusal left an operational directory"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- fdev ' "$home/data/copilots.md" >/dev/null; then
    fail "project-less conversion refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less conversion of a populated home"
}

test_home_seed_refuses_projectless_home_with_uninspectable_projects() {
  local home sub err
  home="$TMP_ROOT/no-projects-uninspectable-home"
  sub="$TMP_ROOT/no-projects-uninspectable-copilot_home"
  err="$TMP_ROOT/no-projects-uninspectable.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$sub/projects/hidden-clone"
  mark_autopilot_home "$sub"
  ap_git_init_commit "$sub/projects/hidden-clone"
  chmod 311 "$sub/projects"

  if AP_HOME="$home" AP_COPILOT_CHARTER='autopilot self-development' \
    AP_COPILOT_SCOPE='autopilot repo work' \
    "$ROOT/bin/ap-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 700 "$sub/projects"
    fail "project-less seed accepted a home whose projects directory could not be inspected"
  fi
  chmod 700 "$sub/projects"
  grep -F 'cannot inspect existing projects directory' "$err" >/dev/null \
    || fail "project-less seed did not explain the projects inspection failure"
  grep -F 'resolve its access permissions or retire or clean this home' "$err" >/dev/null \
    || fail "project-less seed did not explain how to resolve the inspection failure"
  assert_present "$sub/projects/hidden-clone/.git" "project-less inspection refusal removed the existing clone"
  assert_absent "$sub/.ap-copilot-home" "project-less inspection refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less inspection refusal copied a charter"
  assert_absent "$sub/state" "project-less inspection refusal left an operational directory"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- fdev ' "$home/data/copilots.md" >/dev/null; then
    fail "project-less inspection refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes whose projects directory cannot be inspected"
}

test_home_seed_refuses_projectless_home_with_symlinked_projects() {
  local home sub target err
  home="$TMP_ROOT/no-projects-symlinked-projects-home"
  sub="$TMP_ROOT/no-projects-symlinked-projects-copilot_home"
  target="$sub/retained-projects"
  err="$TMP_ROOT/no-projects-symlinked-projects.err"
  mkdir -p "$home/data" "$home/state" "$sub/data" "$target/hidden-clone"
  mark_autopilot_home "$sub"
  ap_git_init_commit "$target/hidden-clone"
  ln -s "$target" "$sub/projects"
  chmod 311 "$target"

  if AP_HOME="$home" AP_COPILOT_CHARTER='autopilot self-development' \
    AP_COPILOT_SCOPE='autopilot repo work' \
    "$ROOT/bin/ap-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 700 "$target"
    fail "project-less seed accepted a home whose projects directory is a symlink"
  fi
  chmod 700 "$target"
  grep -F 'projects directory' "$err" >/dev/null \
    || fail "project-less seed did not identify the symlinked projects directory"
  grep -F 'it is a symlink' "$err" >/dev/null \
    || fail "project-less seed did not explain the symlinked projects directory refusal"
  assert_present "$target/hidden-clone/.git" "project-less symlink refusal removed the target clone"
  [ -L "$sub/projects" ] || fail "project-less symlink refusal changed the projects symlink"
  [ "$(readlink "$sub/projects")" = "$target" ] \
    || fail "project-less symlink refusal retargeted the projects symlink"
  assert_absent "$sub/.ap-copilot-home" "project-less symlink refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less symlink refusal copied a charter"
  assert_absent "$sub/state" "project-less symlink refusal left an operational directory"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- fdev ' "$home/data/copilots.md" >/dev/null; then
    fail "project-less symlink refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes with symlinked projects directories"
}

test_home_seed_refuses_projectless_home_with_non_directory_projects() {
  local home sub err projects_before
  home="$TMP_ROOT/no-projects-nondirectory-projects-home"
  sub="$TMP_ROOT/no-projects-nondirectory-projects-copilot_home"
  err="$TMP_ROOT/no-projects-nondirectory-projects.err"
  mkdir -p "$home/data" "$home/state" "$sub/data"
  mark_autopilot_home "$sub"
  printf '%s\n' 'retained project path' > "$sub/projects"
  projects_before=$(cat "$sub/projects")

  if AP_HOME="$home" AP_COPILOT_CHARTER='autopilot self-development' \
    AP_COPILOT_SCOPE='autopilot repo work' \
    "$ROOT/bin/ap-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    fail "project-less seed accepted a home whose projects path is not a directory"
  fi
  grep -F 'projects directory' "$err" >/dev/null \
    || fail "project-less seed did not identify the non-directory projects path"
  grep -F 'it is not a directory' "$err" >/dev/null \
    || fail "project-less seed did not explain the non-directory projects path refusal"
  [ "$projects_before" = "$(cat "$sub/projects")" ] \
    || fail "project-less non-directory refusal changed the projects path"
  assert_absent "$sub/.ap-copilot-home" "project-less non-directory refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less non-directory refusal copied a charter"
  assert_absent "$sub/state" "project-less non-directory refusal left an operational directory"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- fdev ' "$home/data/copilots.md" >/dev/null; then
    fail "project-less non-directory refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes with non-directory projects paths"
}

test_home_seed_refuses_projectless_home_with_uninspectable_registry() {
  local home sub err registry_before
  home="$TMP_ROOT/no-projects-uninspectable-registry-home"
  sub="$TMP_ROOT/no-projects-uninspectable-registry-copilot_home"
  err="$TMP_ROOT/no-projects-uninspectable-registry.err"
  mkdir -p "$home/data" "$home/state" "$sub/data"
  mark_autopilot_home "$sub"
  printf '%s\n' '- hidden-registry [direct-PR] - retained project entry (added 2026-06-22)' > "$sub/data/projects.md"
  registry_before=$(cat "$sub/data/projects.md")
  chmod 000 "$sub/data/projects.md"

  if AP_HOME="$home" AP_COPILOT_CHARTER='autopilot self-development' \
    AP_COPILOT_SCOPE='autopilot repo work' \
    "$ROOT/bin/ap-home-seed.sh" fdev "$sub" --no-projects >/dev/null 2>"$err"; then
    chmod 600 "$sub/data/projects.md"
    fail "project-less seed accepted a home whose project registry could not be inspected"
  fi
  chmod 600 "$sub/data/projects.md"
  grep -F 'cannot inspect existing project registry' "$err" >/dev/null \
    || fail "project-less seed did not explain the project registry inspection failure"
  grep -F 'resolve its access permissions or retire or clean this home' "$err" >/dev/null \
    || fail "project-less seed did not explain how to resolve the project registry inspection failure"
  [ "$registry_before" = "$(cat "$sub/data/projects.md")" ] \
    || fail "project-less inspection refusal changed the project registry"
  assert_absent "$sub/.ap-copilot-home" "project-less registry inspection refusal wrote a home marker"
  assert_absent "$sub/data/charter.md" "project-less registry inspection refusal copied a charter"
  assert_absent "$sub/state" "project-less registry inspection refusal left an operational directory"
  assert_absent "$sub/projects" "project-less registry inspection refusal created a projects directory"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- fdev ' "$home/data/copilots.md" >/dev/null; then
    fail "project-less registry inspection refusal wrote a parent registry route"
  fi
  pass "home seeding refuses project-less homes whose project registry cannot be inspected"
}

test_home_seed_refuses_missing_projects_without_signal() {
  # Accidental omission of the project list, with no deliberate --no-projects
  # signal, must fail loudly and leave nothing behind, so a forgotten argument is
  # never mistaken for an intentional project-less seed.
  local home sub err
  home="$TMP_ROOT/missing-projects-home"
  sub="$TMP_ROOT/missing-projects-copilot_home"
  err="$TMP_ROOT/missing-projects.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"

  if AP_HOME="$home" AP_COPILOT_CHARTER='some scope' \
    "$ROOT/bin/ap-home-seed.sh" fdev "$sub" >/dev/null 2>"$err"; then
    fail "seed accepted a project-less home without the deliberate --no-projects signal"
  fi
  assert_absent "$sub" "loud-failure seed created a copilot_home"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- fdev ' "$home/data/copilots.md" >/dev/null; then
    fail "loud-failure seed left a registry route"
  fi

  # The deliberate signal is mutually exclusive with a project list.
  if AP_HOME="$home" AP_COPILOT_CHARTER='some scope' \
    "$ROOT/bin/ap-home-seed.sh" fdev "$sub" --no-projects alpha >/dev/null 2>"$err"; then
    fail "seed accepted --no-projects combined with a project list"
  fi
  grep -F 'cannot be combined with a project list' "$err" >/dev/null \
    || fail "seed did not explain the --no-projects mutual-exclusion rejection"
  pass "home seeding fails loudly on accidental project omission and rejects mixed --no-projects"
}

test_home_seed_refuses_local_only_project() {
  local home copilot_home err
  home="$TMP_ROOT/local-only-seed-home"
  copilot_home="$TMP_ROOT/local-only-seed-copilot_home"
  err="$TMP_ROOT/local-only-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed a local-only project into a copilot home"
  fi
  grep -F 'project alpha is local-only; copilot routes support only no-mistakes and direct-PR projects' "$err" >/dev/null \
    || fail "seed did not explain local-only project rejection"
  [ ! -e "$copilot_home" ] || fail "seed created a copilot_home before rejecting a local-only project"
  pass "home seeding refuses local-only projects"
}

test_home_seed_refuses_registry_delimiter_home() {
  local home copilot_home err
  home="$TMP_ROOT/delimiter-home"
  copilot_home="$TMP_ROOT/delimiter)copilot_home"
  err="$TMP_ROOT/delimiter-home.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/delimiter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if AP_HOME="$home" AP_COPILOT_CHARTER='delimiter charter' "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home path with registry delimiters"
  fi
  grep -F 'copilot home path contains registry delimiters' "$err" >/dev/null \
    || fail "seed did not explain delimiter home refusal"
  [ ! -e "$copilot_home/.ap-copilot-home" ] || fail "delimiter home seed wrote a marker"
  if [ -f "$home/data/copilots.md" ] && grep -F -- '- design ' "$home/data/copilots.md" >/dev/null; then
    fail "delimiter home seed wrote a registry route"
  fi
  pass "home seeding refuses registry delimiter home paths"
}

test_home_seed_refuses_active_home_and_root() {
  local home err active_ancestor active_descendant root_clone root_descendant root_ancestor root_inside
  active_ancestor="$TMP_ROOT/active-seed-ancestor"
  home="$active_ancestor/main-home"
  err="$TMP_ROOT/active-seed.err"
  active_descendant="$home/nested/design-home"
  root_clone="$TMP_ROOT/active-seed-root"
  root_descendant="$root_clone/tmp/design-home"
  root_ancestor="$TMP_ROOT/active-seed-root-ancestor"
  root_inside="$root_ancestor/nested-root"
  git clone --quiet "$ROOT" "$active_ancestor"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for active-home seed test"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed copilot home to reuse active AP_HOME"
  fi
  grep -F 'copilot home cannot be the active autopilot home' "$err" >/dev/null \
    || fail "seed did not explain active AP_HOME rejection"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$active_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed copilot home inside active AP_HOME"
  fi
  grep -F 'copilot home cannot be inside the active autopilot home' "$err" >/dev/null \
    || fail "seed did not explain active AP_HOME descendant rejection"
  [ ! -e "$home/nested" ] || fail "seed created a directory inside active AP_HOME before descendant rejection"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$active_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed copilot home to contain active AP_HOME"
  fi
  grep -F 'copilot home cannot be an ancestor of the active autopilot home' "$err" >/dev/null \
    || fail "seed did not explain active AP_HOME ancestor rejection"
  [ ! -f "$active_ancestor/.ap-copilot-home" ] || fail "seed marked an ancestor of active AP_HOME"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$ROOT" alpha >/dev/null 2>"$err"; then
    fail "seed allowed copilot home to reuse AP_ROOT"
  fi
  grep -F 'copilot home cannot be the autopilot repo' "$err" >/dev/null \
    || fail "seed did not explain AP_ROOT rejection"

  git clone --quiet "$ROOT" "$root_clone"
  if AP_HOME="$home" AP_ROOT_OVERRIDE="$root_clone" "$ROOT/bin/ap-home-seed.sh" design "$root_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed copilot home inside AP_ROOT"
  fi
  grep -F 'copilot home cannot be inside the autopilot repo' "$err" >/dev/null \
    || fail "seed did not explain AP_ROOT descendant rejection"
  [ ! -e "$root_clone/tmp" ] || fail "seed created a directory inside AP_ROOT before descendant rejection"

  git clone --quiet "$ROOT" "$root_ancestor"
  git clone --quiet "$ROOT" "$root_inside"
  if AP_HOME="$home" AP_ROOT_OVERRIDE="$root_inside" "$ROOT/bin/ap-home-seed.sh" design "$root_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed copilot home to contain AP_ROOT"
  fi
  grep -F 'copilot home cannot be an ancestor of the autopilot repo' "$err" >/dev/null \
    || fail "seed did not explain AP_ROOT ancestor rejection"
  [ ! -f "$root_ancestor/.ap-copilot-home" ] || fail "seed marked an ancestor of AP_ROOT"
  pass "home seeding refuses active home and repo root"
}

test_home_seed_refuses_home_marked_for_another_id() {
  local home copilot_home err
  home="$TMP_ROOT/marked-seed-home"
  copilot_home="$TMP_ROOT/marked-seed-copilot_home"
  err="$TMP_ROOT/marked-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/marked-alpha.git"
  git clone --quiet "$ROOT" "$copilot_home"
  printf 'other\n' > "$copilot_home/.ap-copilot-home"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for marked-home seed test"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home marked for another copilot"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain marked-home rejection"
  [ "$(cat "$copilot_home/.ap-copilot-home")" = "other" ] || fail "seed overwrote another copilot marker"
  pass "home seeding refuses homes marked for another id"
}

test_home_seed_refuses_home_registered_to_another_id() {
  local home copilot_home subhome_abs err
  home="$TMP_ROOT/registered-seed-home"
  copilot_home="$TMP_ROOT/registered-seed-copilot_home"
  err="$TMP_ROOT/registered-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/registered-alpha.git"
  git clone --quiet "$ROOT" "$copilot_home"
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  printf '%s\n' '- other - other domain (home: '"$subhome_abs"'; scope: other domain; projects: beta; added 2026-06-22)' > "$home/data/copilots.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for registered-home seed test"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home registered to another copilot"
  fi
  grep -F 'already registered to other' "$err" >/dev/null || fail "seed did not explain registered-home rejection"
  [ ! -e "$copilot_home/.ap-copilot-home" ] || fail "seed wrote a marker before rejecting a registered home"
  pass "home seeding refuses homes registered to another id"
}

test_home_seed_refuses_reassigning_existing_id_to_different_home() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/reassign-id-home"
  first="$TMP_ROOT/reassign-id-first"
  second="$TMP_ROOT/reassign-id-second"
  err="$TMP_ROOT/reassign-id.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/reassign-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  AP_HOME="$home" AP_COPILOT_CHARTER='design domain' AP_COPILOT_SCOPE='design domain' \
    "$ROOT/bin/ap-home-seed.sh" design "$first" alpha >/dev/null \
    || fail "initial seed failed for reassigning-id test"
  first_abs=$(cd "$first" && pwd -P)

  if AP_HOME="$home" AP_COPILOT_CHARTER='design domain' AP_COPILOT_SCOPE='design domain' \
    "$ROOT/bin/ap-home-seed.sh" design "$second" alpha >/dev/null 2>"$err"; then
    fail "seed reassigned an existing copilot id to a different home"
  fi
  grep -F "copilot id design is already registered to home $first_abs" "$err" >/dev/null \
    || fail "seed did not explain same-id different-home rejection"
  [ ! -e "$second" ] || fail "failed id reassignment created the new copilot_home"
  [ "$(cat "$first/.ap-copilot-home")" = design ] || fail "failed id reassignment changed the original marker"
  grep -F "home: $first_abs" "$home/data/copilots.md" >/dev/null \
    || fail "failed id reassignment did not preserve the original registry route"
  second_abs=$(cd "$(dirname "$second")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$second")")
  grep -F "home: $second_abs" "$home/data/copilots.md" >/dev/null \
    && fail "failed id reassignment recorded the rejected home"
  pass "home seeding refuses same-id reassignment to a different home"
}

test_home_seed_refuses_home_overlapping_registered_home() {
  local home registered_parent registered_child nested parent err
  home="$TMP_ROOT/overlap-seed-home"
  registered_parent="$TMP_ROOT/overlap-registered-parent"
  registered_child="$TMP_ROOT/overlap-registered-child-parent/child"
  nested="$registered_parent/nested"
  parent="$TMP_ROOT/overlap-registered-child-parent"
  err="$TMP_ROOT/overlap-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/overlap-alpha.git"
  git clone --quiet "$ROOT" "$registered_parent"
  git clone --quiet "$ROOT" "$registered_child"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  cat > "$home/data/copilots.md" <<EOF
- parent - parent domain (home: $registered_parent; scope: parent domain; projects: beta; added 2026-06-22)
- child - child domain (home: $registered_child; scope: child domain; projects: gamma; added 2026-06-22)
EOF

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$nested" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home inside a registered copilot home"
  fi
  grep -F 'overlaps registered copilot home' "$err" >/dev/null \
    || fail "seed did not explain registered ancestor overlap"
  [ ! -e "$nested" ] || fail "seed created a nested home inside a registered home"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$parent" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home containing a registered copilot home"
  fi
  grep -F 'overlaps registered copilot home' "$err" >/dev/null \
    || fail "seed did not explain registered descendant overlap"
  [ ! -f "$parent/.ap-copilot-home" ] || fail "seed marked a home containing a registered home"
  pass "home seeding refuses registered home overlaps"
}

test_home_seed_refuses_remote_backed_project_without_origin() {
  local home copilot_home err
  home="$TMP_ROOT/no-origin-home"
  copilot_home="$TMP_ROOT/no-origin-copilot_home"
  err="$TMP_ROOT/no-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for no-origin seed test"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed remote-backed project without origin"
  fi
  grep -F 'project alpha is direct-PR but has no origin remote' "$err" >/dev/null || fail "seed did not explain missing origin for remote-backed project"
  pass "remote-backed copilot_home seeding requires a source origin"
}

test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin() {
  local home copilot_home subhome_abs err expected
  home="$TMP_ROOT/wrong-origin-home"
  copilot_home="$TMP_ROOT/wrong-origin-copilot_home"
  err="$TMP_ROOT/wrong-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/wrong-alpha.git"
  git clone --quiet "$ROOT" "$copilot_home"
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  mkdir -p "$copilot_home/projects"
  git clone --quiet "$home/projects/alpha" "$copilot_home/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for wrong-origin seed test"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed accepted existing remote-backed project with wrong origin"
  fi
  expected=$(git -C "$home/projects/alpha" remote get-url origin)
  grep -F "seeded project alpha at $subhome_abs/projects/alpha has origin" "$err" >/dev/null \
    || fail "seed did not identify wrong origin for existing remote-backed project"
  grep -F "expected $expected" "$err" >/dev/null \
    || fail "seed did not report expected origin for existing remote-backed project"
  pass "remote-backed copilot_home seeding validates existing destination origins"
}

test_home_seed_resolves_relative_source_origins() {
  local home copilot_home subhome_abs expected out actual
  home="$TMP_ROOT/relative-origin-home"
  copilot_home="$TMP_ROOT/relative-origin-copilot_home"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$home/remotes"
  ap_git_init_commit "$home/projects/alpha"
  git clone --quiet --bare "$home/projects/alpha" "$home/remotes/relative-alpha.git"
  git -C "$home/projects/alpha" remote add origin ../../remotes/relative-alpha.git
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for relative origin seed test"

  out=$(AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha)
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  expected=$(cd "$home/remotes/relative-alpha.git" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$subhome_abs" >/dev/null || fail "seed did not report relative-origin copilot_home"
  [ -d "$copilot_home/projects/alpha/.git" ] || fail "relative source origin was not cloned"
  actual=$(git -C "$copilot_home/projects/alpha" remote get-url origin)
  [ "$actual" = "$expected" ] || fail "relative source origin was not cloned through the resolved path"
  AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null \
    || fail "relative source origin did not compare equal on reseed"
  pass "home seeding resolves relative source origins against the source project"
}

test_home_seed_skips_initialized_existing_no_mistakes_projects() {
  local home copilot_home err fakebin log origin
  home="$TMP_ROOT/existing-initialized-home"
  copilot_home="$TMP_ROOT/existing-initialized-copilot_home"
  err="$TMP_ROOT/existing-initialized.err"
  log="$TMP_ROOT/existing-initialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_init_commit "$home/projects/beta"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/existing-alpha.git"
  ap_git_add_origin "$home/projects/beta" "$TMP_ROOT/remotes/existing-beta.git"
  git clone --quiet "$ROOT" "$copilot_home"
  mkdir -p "$copilot_home/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$copilot_home/projects/alpha"
  git -C "$copilot_home/projects/alpha" remote add no-mistakes "$TMP_ROOT/no-mistakes-alpha.git"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' '- beta - beta project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-initialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" AP_FAKE_NO_MISTAKES_LOG="$log" AP_FAKE_NO_MISTAKES_FAIL_PROJECT=beta \
    AP_HOME="$home" AP_COPILOT_CHARTER='existing init rollback scope' AP_COPILOT_SCOPE='existing init rollback scope' \
    "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though later no-mistakes initialization failed"
  fi
  grep -F 'failed to initialize no-mistakes for beta' "$err" >/dev/null \
    || fail "seed did not explain later no-mistakes initialization failure"
  grep -F "$copilot_home/projects/alpha" "$log" >/dev/null \
    && fail "seed ran no-mistakes against an initialized existing clone"
  [ ! -f "$copilot_home/projects/alpha/.no-mistakes-init" ] || fail "seed mutated initialized existing clone with no-mistakes init"
  [ ! -f "$copilot_home/projects/alpha/.no-mistakes-doctor" ] || fail "seed mutated initialized existing clone with no-mistakes doctor"
  [ ! -e "$copilot_home/projects/beta" ] || fail "failed seed left a newly cloned project after no-mistakes failure"
  pass "home seeding skips initialized existing no-mistakes clones"
}

test_home_seed_refuses_uninitialized_existing_no_mistakes_project() {
  local home copilot_home err fakebin log origin
  home="$TMP_ROOT/existing-uninitialized-home"
  copilot_home="$TMP_ROOT/existing-uninitialized-copilot_home"
  err="$TMP_ROOT/existing-uninitialized.err"
  log="$TMP_ROOT/existing-uninitialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/uninitialized-alpha.git"
  git clone --quiet "$ROOT" "$copilot_home"
  mkdir -p "$copilot_home/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$copilot_home/projects/alpha"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-uninitialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" AP_FAKE_NO_MISTAKES_LOG="$log" \
    AP_HOME="$home" AP_COPILOT_CHARTER='existing uninitialized scope' \
    "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed initialized a preexisting no-mistakes clone"
  fi
  grep -F 'refusing to mutate preexisting clone' "$err" >/dev/null \
    || fail "seed did not explain uninitialized existing no-mistakes clone refusal"
  [ ! -s "$log" ] || fail "seed ran no-mistakes before refusing an uninitialized existing clone"
  [ ! -f "$copilot_home/projects/alpha/.no-mistakes-init" ] || fail "seed mutated uninitialized existing clone"
  pass "home seeding refuses uninitialized existing no-mistakes clones"
}

test_home_seed_refuses_project_destinations_outside_subhome() {
  local home copilot_home sink err
  home="$TMP_ROOT/symlink-project-home"
  copilot_home="$TMP_ROOT/symlink-project-copilot_home"
  sink="$home/data/symlink-projects"
  err="$TMP_ROOT/symlink-project.err"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$sink"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-alpha.git"
  git clone --quiet "$ROOT" "$copilot_home"
  rm -rf "$copilot_home/projects"
  ln -s "$sink" "$copilot_home/projects"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink destination seed test"

  if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
    fail "seed followed a copilot_home projects symlink outside the copilot_home"
  fi
  grep -F 'copilot projects directory must resolve inside the copilot home' "$err" >/dev/null \
    || fail "seed did not explain unsafe project destination rejection"
  [ ! -e "$sink/alpha" ] || fail "seed cloned a project through an unsafe projects symlink"
  [ ! -f "$copilot_home/.ap-copilot-home" ] || fail "seed marked copilot_home after unsafe project destination rejection"
  pass "home seeding refuses project destinations outside the copilot_home"
}

test_home_seed_refuses_operational_dirs_outside_subhome() {
  local home copilot_home sink err opdir
  home="$TMP_ROOT/symlink-opdir-home"
  err="$TMP_ROOT/symlink-opdir.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-opdir-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink operational dir seed test"

  for opdir in data state config; do
    copilot_home="$TMP_ROOT/symlink-opdir-copilot_home-$opdir"
    sink="$home/data/symlink-opdir-$opdir"
    rm -rf "$copilot_home" "$sink"
    git clone --quiet "$ROOT" "$copilot_home"
    mkdir -p "$sink"
    rm -rf "${copilot_home:?}/${opdir:?}"
    ln -s "$sink" "$copilot_home/$opdir"
    if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
      fail "seed accepted a copilot_home with $opdir symlinked outside the copilot_home"
    fi
    grep -F "copilot $opdir directory must resolve inside the copilot home" "$err" >/dev/null \
      || fail "seed did not explain unsafe $opdir directory rejection"
    [ ! -f "$copilot_home/.ap-copilot-home" ] || fail "seed marked copilot_home after unsafe $opdir directory rejection"
  done
  pass "home seeding refuses operational directories outside the copilot_home"
}

test_home_seed_refuses_symlinked_leaf_files() {
  local home copilot_home sink err leaf target expected
  home="$TMP_ROOT/symlink-leaf-home"
  err="$TMP_ROOT/symlink-leaf.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  ap_git_init_commit "$home/projects/alpha"
  ap_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-leaf-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_copilot_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink leaf seed test"

  for leaf in data/projects.md data/charter.md .ap-copilot-home; do
    copilot_home="$TMP_ROOT/symlink-leaf-copilot_home-${leaf//\//-}"
    sink="$home/data/symlink-leaf-${leaf//\//-}"
    rm -rf "$copilot_home" "$sink"
    git clone --quiet "$ROOT" "$copilot_home"
    mkdir -p "$(dirname "$copilot_home/$leaf")" "$(dirname "$sink")"
    expected=outside
    if [ "$leaf" = ".ap-copilot-home" ]; then
      expected=design
    fi
    printf '%s\n' "$expected" > "$sink"
    ln -s "$sink" "$copilot_home/$leaf"
    if AP_HOME="$home" "$ROOT/bin/ap-home-seed.sh" design "$copilot_home" alpha >/dev/null 2>"$err"; then
      fail "seed accepted symlinked leaf file $leaf"
    fi
    grep -F 'copilot leaf file must not be a symlink:' "$err" >/dev/null \
      || fail "seed did not explain symlinked leaf refusal for $leaf"
    target=$(cat "$sink")
    [ "$target" = "$expected" ] || fail "seed overwrote outside symlink target for $leaf"
    [ ! -f "$copilot_home/.ap-copilot-home" ] || [ "$leaf" = ".ap-copilot-home" ] || fail "seed marked copilot_home after symlinked leaf refusal"
  done
  pass "home seeding refuses symlinked leaf files"
}

test_copilot_spawn_requires_seeded_matching_home() {
  local home copilot_home wronghome marker_only active_descendant active_ancestor ancestor_active_home fakeroot root_descendant root_ancestor root_inside fakebin log err
  home="$TMP_ROOT/spawn-validate-home"
  copilot_home="$TMP_ROOT/spawn-validate-copilot_home"
  wronghome="$TMP_ROOT/spawn-validate-wronghome"
  marker_only="$TMP_ROOT/spawn-validate-marker-only"
  active_descendant="$home/data/spawn-descendant-home"
  active_ancestor="$TMP_ROOT/spawn-active-ancestor"
  ancestor_active_home="$active_ancestor/main-home"
  fakeroot="$TMP_ROOT/spawn-validate-root"
  root_descendant="$fakeroot/tmp/spawn-descendant-home"
  root_ancestor="$TMP_ROOT/spawn-root-ancestor"
  root_inside="$root_ancestor/repo"
  mkdir -p "$home/data" "$home/state" "$copilot_home/data" "$wronghome/data" "$marker_only/data" "$active_descendant/data" "$root_descendant/data" "$fakeroot/bin"
  cat > "$fakeroot/bin/ap-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/ap-guard.sh"
  mkdir -p "$ancestor_active_home/data" "$ancestor_active_home/state" "$active_ancestor/data" "$root_ancestor/data" "$root_inside/bin"
  cat > "$root_inside/bin/ap-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root_inside/bin/ap-guard.sh"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-validate-fake")
  log="$TMP_ROOT/spawn-validate-fake/tmux.log"
  err="$TMP_ROOT/spawn-validate.err"

  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$copilot_home" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted an unseeded home"
  fi
  grep -F 'not a seeded copilot home' "$err" >/dev/null || fail "spawn did not explain missing seed marker"
  # Canonical ordering proof: validation runs before any tmux side-effect. Every rejection
  # reason below shares this one linear pre-launch path, so they each assert only their own
  # refusal message rather than re-proving "no window created before validation" each time.
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before validation"

  printf 'other\n' > "$wronghome/.ap-copilot-home"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$wronghome" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted a home marked for another copilot"
  fi
  grep -F 'marked for copilot other, expected domain' "$err" >/dev/null || fail "spawn did not explain marker mismatch"

  printf 'domain\n' > "$marker_only/.ap-copilot-home"
  printf 'charter\n' > "$marker_only/data/charter.md"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$marker_only" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted a marked home missing AGENTS.md"
  fi
  grep -F 'not an autopilot home (missing AGENTS.md)' "$err" >/dev/null || fail "spawn did not explain missing AGENTS.md"

  printf '# Autopilot\n' > "$marker_only/AGENTS.md"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$marker_only" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted a marked home missing bin"
  fi
  grep -F 'not an autopilot home (missing bin/)' "$err" >/dev/null || fail "spawn did not explain missing bin"

  printf 'domain\n' > "$home/.ap-copilot-home"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$home" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted the active home"
  fi
  grep -F 'copilot home cannot be the active autopilot home' "$err" >/dev/null || fail "spawn did not reject active home"

  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$ROOT" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted the autopilot repo root"
  fi
  grep -F 'copilot home cannot be the autopilot repo' "$err" >/dev/null || fail "spawn did not reject autopilot repo root"

  printf 'domain\n' > "$active_descendant/.ap-copilot-home"
  printf 'charter\n' > "$active_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$active_descendant" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted a home inside the active autopilot home"
  fi
  grep -F 'copilot home cannot be inside the active autopilot home' "$err" >/dev/null || fail "spawn did not reject active home descendant"

  printf 'domain\n' > "$active_ancestor/.ap-copilot-home"
  printf 'charter\n' > "$active_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" AP_HOME="$ancestor_active_home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$active_ancestor" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted a home containing the active autopilot home"
  fi
  grep -F 'copilot home cannot be an ancestor of the active autopilot home' "$err" >/dev/null || fail "spawn did not reject active home ancestor"

  printf 'domain\n' > "$root_descendant/.ap-copilot-home"
  printf 'charter\n' > "$root_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" AP_ROOT_OVERRIDE="$fakeroot" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$root_descendant" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted a home inside the autopilot repo"
  fi
  grep -F 'copilot home cannot be inside the autopilot repo' "$err" >/dev/null || fail "spawn did not reject repo root descendant"

  printf 'domain\n' > "$root_ancestor/.ap-copilot-home"
  printf 'charter\n' > "$root_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" AP_ROOT_OVERRIDE="$root_inside" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/ap-spawn.sh" domain "$root_ancestor" codex --copilot >/dev/null 2>"$err"; then
    fail "copilot spawn accepted a home containing the autopilot repo"
  fi
  grep -F 'copilot home cannot be an ancestor of the autopilot repo' "$err" >/dev/null || fail "spawn did not reject repo ancestor"

  pass "copilot spawn validates homes before launch"
}

test_copilot_spawn_refuses_operational_dirs_outside_subhome() {
  local home copilot_home sink fakebin log err opdir
  home="$TMP_ROOT/spawn-opdir-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-opdir-fake")
  log="$TMP_ROOT/spawn-opdir-fake/tmux.log"
  err="$TMP_ROOT/spawn-opdir.err"
  mkdir -p "$home/data" "$home/state"

  for opdir in data state config projects; do
    copilot_home="$TMP_ROOT/spawn-opdir-copilot_home-$opdir"
    sink="$home/data/spawn-opdir-$opdir"
    rm -rf "$copilot_home" "$sink"
    mkdir -p "$copilot_home/data" "$copilot_home/state" "$copilot_home/config" "$copilot_home/projects" "$sink"
    printf 'domain\n' > "$copilot_home/.ap-copilot-home"
    printf 'charter\n' > "$copilot_home/data/charter.md"
    rm -rf "${copilot_home:?}/${opdir:?}"
    ln -s "$sink" "$copilot_home/$opdir"
    if [ "$opdir" = data ]; then
      printf 'charter\n' > "$sink/charter.md"
    fi
    : > "$log"
    if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-opdir-fake/pane.txt" \
      "$ROOT/bin/ap-spawn.sh" domain "$copilot_home" codex --copilot >/dev/null 2>"$err"; then
      fail "copilot spawn accepted a copilot_home with $opdir symlinked outside the copilot_home"
    fi
    grep -F "copilot $opdir directory must resolve inside the copilot home" "$err" >/dev/null \
      || fail "spawn did not explain unsafe $opdir directory rejection"
    grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before unsafe $opdir directory validation"
  done
  pass "copilot spawn refuses operational directories outside the copilot_home"
}

test_ap_send_refuses_bare_window_without_home_meta() {
  # The happy path (a bare ap-<id> resolves the window recorded in THIS home's
  # meta and never a foreign same-named window) is asserted in the lifecycle e2e.
  # Here: with NO meta for the id, send must refuse rather than fall back to a
  # foreign same-named window that list-windows happens to return.
  local home fakebin log err
  home="$TMP_ROOT/send-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_fake_tmux "$TMP_ROOT/send-fake")
  log="$TMP_ROOT/send-fake/tmux.log"
  err="$TMP_ROOT/send-fake/send.err"

  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_WINDOW="other-session:ap-missing" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/send-fake/pane.txt" \
    "$ROOT/bin/ap-send.sh" ap-missing 'wrong home' >/dev/null 2>"$err"; then
    fail "ap-send sent to a bare autopilot window without home metadata"
  fi
  grep -F "no metadata for ap-missing in $home/state" "$err" >/dev/null \
    || fail "ap-send did not explain missing home metadata"
  grep -F 'send-keys -t other-session:ap-missing' "$log" >/dev/null \
    && fail "ap-send fell back to a foreign same-name window"
  pass "ap-send refuses a bare autopilot window with no metadata in this home"
}

test_copilot_teardown_retires_empty_home() {
  local home copilot_home subhome_abs fakebin log lease fmroot
  home="$TMP_ROOT/teardown-home"
  copilot_home="$TMP_ROOT/teardown-copilot_home"
  fmroot="$TMP_ROOT/teardown-fmroot"
  make_autopilot_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$copilot_home" HEAD
  mkdir -p "$home/state" "$home/data" "$copilot_home/state"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-fake")
  log="$TMP_ROOT/teardown-fake/tmux.log"
  lease="$TMP_ROOT/teardown-fake/lease"
  printf 'domain\n' > "$lease"
  PATH="$fakebin:$PATH" AP_ROOT_OVERRIDE="$fmroot" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-fake/pane.txt" \
    AP_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    "$ROOT/bin/ap-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for empty copilot home"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not release the copilot home lease via treehouse return"
  [ ! -e "$lease" ] || fail "teardown left the copilot home lease held after retirement"
  [ ! -d "$copilot_home" ] || fail "teardown did not remove the retired copilot home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/copilots.md" >/dev/null && fail "teardown did not remove copilot registry route"
  pass "copilot teardown retires empty homes and releases routing"
}

test_copilot_teardown_refuses_failed_leased_home_return() {
  local home copilot_home subhome_abs fakebin log fmroot err rc
  home="$TMP_ROOT/teardown-return-fail-home"
  copilot_home="$TMP_ROOT/teardown-return-fail-copilot_home"
  fmroot="$TMP_ROOT/teardown-return-fail-fmroot"
  err="$TMP_ROOT/teardown-return-fail.err"
  make_autopilot_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$copilot_home" HEAD
  mkdir -p "$home/state" "$home/data" "$copilot_home/state"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-return-fail-fake")
  log="$TMP_ROOT/teardown-return-fail-fake/tmux.log"

  set +e
  PATH="$fakebin:$PATH" AP_ROOT_OVERRIDE="$fmroot" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-return-fail-fake/pane.txt" \
    AP_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    "$ROOT/bin/ap-teardown.sh" domain >/dev/null 2>"$err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown succeeded despite failed treehouse return"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not try to return the leased home"
  grep -F 'treehouse return failed for copilot home' "$err" >/dev/null || fail "teardown did not report failed leased home return"
  [ -d "$copilot_home" ] || fail "teardown removed a leased home after return failed"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared meta after leased home return failed"
  grep -F -- '- domain ' "$home/data/copilots.md" >/dev/null || fail "teardown removed registry route after leased home return failed"
  pass "copilot teardown refuses to hide failed leased-home return"
}

test_copilot_teardown_removes_plain_clone_home_without_treehouse_return() {
  local home copilot_home subhome_abs fakebin log
  home="$TMP_ROOT/plain-clone-teardown-home"
  copilot_home="$TMP_ROOT/plain-clone-teardown-copilot_home"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state"
  mark_autopilot_home "$copilot_home"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/plain-clone-teardown-fake")
  log="$TMP_ROOT/plain-clone-teardown-fake/tmux.log"

  PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/plain-clone-teardown-fake/pane.txt" \
    AP_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    "$ROOT/bin/ap-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for plain-clone copilot home"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null && fail "teardown tried to return a plain-clone home through treehouse"
  [ ! -d "$copilot_home" ] || fail "teardown did not remove the plain-clone copilot home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta for plain-clone home"
  grep -F -- '- domain ' "$home/data/copilots.md" >/dev/null && fail "teardown did not remove plain-clone registry route"
  pass "copilot teardown raw-removes plain-clone homes"
}

test_copilot_force_teardown_discards_child_work() {
  local home copilot_home childproj childwt fakebin log
  home="$TMP_ROOT/force-teardown-home"
  copilot_home="$TMP_ROOT/force-teardown-copilot_home"
  childproj="$copilot_home/projects/alpha"
  childwt="$TMP_ROOT/force-child-worktree"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state"
  ap_git_worktree "$childproj" "$childwt" force-child
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  cat > "$copilot_home/state/child.meta" <<EOF
window=autopilot:ap-child
worktree=$childwt
project=$childproj
harness=echo
kind=flight
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/force-teardown-fake")
  log="$TMP_ROOT/force-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain >/dev/null 2>&1; then
    fail "teardown allowed a copilot with in-flight child work"
  fi
  PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2>/dev/null \
    || fail "force teardown failed to discard child work"
  [ ! -d "$copilot_home" ] || fail "force teardown did not remove the retired copilot home"
  [ ! -d "$childwt" ] || fail "force teardown did not remove child worktree"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/copilots.md" >/dev/null && fail "force teardown did not remove copilot registry route"
  grep -F 'kill-window -t =autopilot:=ap-child' "$log" >/dev/null || fail "force teardown did not kill child window"
  grep -F 'kill-window -t =autopilot:=ap-domain' "$log" >/dev/null || fail "force teardown did not kill parent window"
  pass "copilot force teardown discards child work"
}

test_copilot_force_teardown_refuses_child_quarantine_symlink() {
  local home copilot_home childproj childwt external fakebin log err rc
  home="$TMP_ROOT/force-quarantine-home"
  copilot_home="$TMP_ROOT/force-quarantine-copilot_home"
  childproj="$copilot_home/projects/alpha"
  childwt="$TMP_ROOT/force-quarantine-child-worktree"
  external="$TMP_ROOT/force-quarantine-external"
  err="$TMP_ROOT/force-quarantine.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state" "$external"
  ap_git_worktree "$childproj" "$childwt" force-quarantine-child
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  cat > "$copilot_home/state/child.meta" <<EOF
window=autopilot:ap-child
worktree=$childwt
project=$childproj
harness=echo
kind=flight
mode=no-mistakes
yolo=off
EOF
  printf 'child check\n' > "$copilot_home/state/child.check.sh"
  printf 'external quarantine artifact\n' > "$external/child.check.protected"
  chmod 0640 "$external/child.check.protected"
  ln -s "$external" "$copilot_home/state/.pr-check-quarantine"
  fakebin=$(make_fake_tmux "$TMP_ROOT/force-quarantine-fake")
  log="$TMP_ROOT/force-quarantine-fake/tmux.log"

  set +e
  PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" \
    AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-quarantine-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2> "$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "force teardown accepted a child quarantine-directory symlink"
  [ -d "$copilot_home" ] || fail "force teardown removed the copilot_home before quarantine refusal"
  [ -d "$childwt" ] || fail "force teardown removed child work before quarantine refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta before quarantine refusal"
  [ -e "$copilot_home/state/child.meta" ] || fail "force teardown cleared child meta before quarantine refusal"
  [ "$(cat "$copilot_home/state/child.check.sh")" = 'child check' ] || fail "force teardown removed the child check before quarantine refusal"
  [ "$(cat "$external/child.check.protected")" = 'external quarantine artifact' ] \
    || fail "force teardown changed the child quarantine symlink target"
  [ "$(file_mode "$external/child.check.protected")" = 640 ] \
    || fail "force teardown changed the child quarantine target mode"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed a window before child quarantine validation"
  pass "copilot force teardown prevalidates child quarantine cleanup without following symlinks"
}

test_copilot_force_teardown_preserves_child_on_unproven_lock() {
  local home copilot_home childproj childwt fakebin log err rc lock
  home="$TMP_ROOT/force-lock-home"
  copilot_home="$TMP_ROOT/force-lock-copilot_home"
  childproj="$copilot_home/projects/alpha"
  childwt="$TMP_ROOT/force-lock-child-worktree"
  err="$TMP_ROOT/force-lock-child.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state"
  ap_git_worktree "$childproj" "$childwt" force-child-lock
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  cat > "$copilot_home/state/child.meta" <<EOF
window=autopilot:ap-child
worktree=$childwt
project=$childproj
harness=echo
kind=flight
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/force-lock-child-fake")
  log="$TMP_ROOT/force-lock-child-fake/tmux.log"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${AP_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    lock=$(git -C "$target" rev-parse --git-path index.lock 2>/dev/null || true)
    if [ -n "$lock" ] && [ -e "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      exit 128
    fi
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/lsof"
  lock=$(git -C "$childwt" rev-parse --git-path index.lock)
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-lock-child-fake/pane.txt" \
    AP_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 AP_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2>"$err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "force teardown succeeded after child treehouse refused an unproven lock"
  [ -d "$childwt" ] || fail "force teardown raw-removed child worktree after unproven lock refusal"
  [ -e "$lock" ] || fail "force teardown removed unproven child index.lock"
  [ -d "$copilot_home" ] || fail "force teardown removed copilot_home after child lock refusal"
  [ -e "$copilot_home/state/child.meta" ] || fail "force teardown cleared child meta after child lock refusal"
  grep -F 'not provably stale' "$err" >/dev/null || fail "force teardown did not explain unproven child lock refusal"
  pass "copilot force teardown preserves child worktree after unproven lock refusal"
}

test_copilot_force_teardown_allows_operational_dir_symlinks_inside_home() {
  local opdir home copilot_home target fakebin err log
  for opdir in data state config projects; do
    home="$TMP_ROOT/symlink-inside-teardown-home-$opdir"
    copilot_home="$TMP_ROOT/symlink-inside-teardown-copilot_home-$opdir"
    target="$copilot_home/internal-$opdir"
    err="$TMP_ROOT/symlink-inside-teardown-$opdir.err"
    rm -rf "$home" "$copilot_home"
    mkdir -p "$home/state" "$home/data" "$copilot_home" "$target"
    printf 'domain\n' > "$copilot_home/.ap-copilot-home"
    ln -s "$target" "$copilot_home/$opdir"
    cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
    printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
    fakebin=$(make_fake_tmux "$TMP_ROOT/symlink-inside-teardown-fake-$opdir")
    log="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/tmux.log"
    PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/pane.txt" \
      "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2>"$err" \
      || fail "force teardown refused $opdir symlinked inside the copilot home"
    [ ! -e "$copilot_home" ] || fail "force teardown did not remove copilot_home with inside $opdir symlink"
    [ ! -e "$home/state/domain.meta" ] || fail "force teardown did not clear parent meta for inside $opdir symlink"
    grep -F 'kill-window -t =autopilot:=ap-domain' "$log" >/dev/null || fail "force teardown did not kill parent window for inside $opdir symlink"
  done
  pass "force teardown allows operational directory symlinks inside the copilot_home"
}

test_copilot_force_teardown_refuses_operational_dir_symlink_outside_home() {
  local home copilot_home external_state fakebin err log
  home="$TMP_ROOT/symlink-state-teardown-home"
  copilot_home="$TMP_ROOT/symlink-state-teardown-copilot_home"
  external_state="$home/data/external-state"
  err="$TMP_ROOT/symlink-state-teardown.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home" "$external_state"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  ln -s "$external_state" "$copilot_home/state"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/symlink-state-teardown-fake")
  log="$TMP_ROOT/symlink-state-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/symlink-state-teardown-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown accepted a symlinked copilot state directory"
  fi
  [ -d "$copilot_home" ] || fail "force teardown removed copilot_home after symlinked state refusal"
  [ -d "$external_state" ] || fail "force teardown removed external symlink target"
  grep -F 'state directory' "$err" >/dev/null || fail "teardown did not explain symlinked state refusal"
  grep -F 'resolves outside the copilot home' "$err" >/dev/null || fail "teardown did not identify unsafe state symlink"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before symlinked state refusal"
  pass "force teardown refuses operational directory symlinks outside the copilot_home"
}

test_copilot_teardown_path_boundary_matrix() {
  # The teardown path-boundary matrix: a copilot home is refused (and left
  # fully intact, with no window killed before validation) when it is unmarked,
  # an ancestor of the active autopilot home, inside the active autopilot home,
  # or inside the autopilot repo. One row per hazard, one shared assertion block.
  local row base home copilot_home fmroot fakebin log err expect tid
  while IFS='|' read -r row expect; do
    [ -n "$row" ] || continue
    base="$TMP_ROOT/td-pb-$row"
    fmroot="$ROOT"   # real autopilot repo unless a row overrides it
    tid=domain
    case "$row" in
      unmarked)
        home="$base/main"; copilot_home="$base/sub"
        mkdir -p "$home/state" "$home/data" "$copilot_home/state"
        # No .ap-copilot-home marker on purpose.
        ;;
      ancestor)
        # The home being torn down is an ANCESTOR of the active autopilot home.
        copilot_home="$base/anc"; home="$copilot_home/main-home"
        mkdir -p "$home/state" "$home/data" "$copilot_home/state"
        printf 'domain\n' > "$copilot_home/.ap-copilot-home"
        ;;
      active-descendant)
        home="$base/desc"; copilot_home="$home/data/domain-home"
        mkdir -p "$home/state" "$home/data" "$copilot_home/state"
        printf 'domain\n' > "$copilot_home/.ap-copilot-home"
        ;;
      repo-descendant)
        home="$base/home"; fmroot="$base/root"; copilot_home="$fmroot/tmp/domain-home"; tid='repo-domain'
        mkdir -p "$home/state" "$home/data" "$copilot_home/state" "$fmroot/bin"
        cat > "$fmroot/bin/ap-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
        chmod +x "$fmroot/bin/ap-guard.sh"
        printf 'repo-domain\n' > "$copilot_home/.ap-copilot-home"
        ;;
    esac
    ap_write_copilot_meta "$home/state/$tid.meta" "$copilot_home"
    printf -- '- %s - design domain (home: %s; scope: design domain; projects: alpha; added 2026-06-22)\n' \
      "$tid" "$copilot_home" > "$home/data/copilots.md"
    fakebin=$(make_fake_tmux "$base/fake")
    log="$base/fake/tmux.log"
    err="$base/teardown.err"
    if PATH="$fakebin:$PATH" AP_ROOT_OVERRIDE="$fmroot" AP_HOME="$home" \
      AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$base/fake/pane.txt" \
      "$ROOT/bin/ap-teardown.sh" "$tid" >/dev/null 2>"$err"; then
      fail "teardown ($row) accepted a hazardous copilot home"
    fi
    grep -F "$expect" "$err" >/dev/null || fail "teardown ($row) did not explain the refusal (expected '$expect'): $(cat "$err")"
    [ -d "$copilot_home" ] || fail "teardown ($row) removed the protected home after refusal"
    [ -e "$home/state/$tid.meta" ] || fail "teardown ($row) cleared the parent meta after refusal"
    grep -F -- "- $tid " "$home/data/copilots.md" >/dev/null || fail "teardown ($row) removed the registry route after refusal"
    grep -F 'kill-window' "$log" >/dev/null && fail "teardown ($row) killed a window before validation"
  done <<'ROWS'
unmarked|not a seeded copilot home
ancestor|ancestor of the active autopilot home
active-descendant|inside the active autopilot home
repo-descendant|inside the autopilot repo
ROWS
  pass "copilot teardown path-boundary matrix refuses unmarked/ancestor/active-descendant/repo-descendant homes"
}

test_copilot_teardown_refuses_registered_nested_home() {
  local home copilot_home nested fakebin err log
  home="$TMP_ROOT/nested-teardown-home"
  copilot_home="$TMP_ROOT/nested-teardown-copilot_home"
  nested="$copilot_home/nested-domain"
  err="$TMP_ROOT/nested-teardown.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state" "$nested/state"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  printf 'nested\n' > "$nested/.ap-copilot-home"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  cat > "$home/state/nested.meta" <<EOF
window=autopilot:ap-nested
worktree=$nested
project=$nested
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$nested
projects=beta
EOF
  cat > "$home/data/copilots.md" <<EOF
- domain - design domain (home: $copilot_home; scope: design domain; projects: alpha; added 2026-06-22)
- nested - nested domain mentions home: $TMP_ROOT/ignored-summary-home (home: $nested; scope: nested domain mentions home: $TMP_ROOT/ignored-scope-home; projects: beta; added 2026-06-22)
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/nested-teardown-fake")
  log="$TMP_ROOT/nested-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/nested-teardown-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing another registered copilot home"
  fi
  [ -d "$copilot_home" ] || fail "teardown removed registered ancestor home after refusal"
  [ -d "$nested" ] || fail "teardown removed registered nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared ancestor meta after nested-home refusal"
  [ -e "$home/state/nested.meta" ] || fail "teardown cleared nested meta after nested-home refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before nested-home refusal"
  grep -F 'contains registered copilot home' "$err" >/dev/null || fail "teardown did not explain registered nested-home refusal"
  pass "copilot teardown refuses homes containing registered nested homes"
}

test_copilot_teardown_refuses_child_registry_nested_home() {
  local home copilot_home nested fakebin err log
  home="$TMP_ROOT/child-registry-teardown-home"
  copilot_home="$TMP_ROOT/child-registry-teardown-copilot_home"
  nested="$copilot_home/nested-domain"
  err="$TMP_ROOT/child-registry-teardown.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state" "$copilot_home/data" "$nested/state"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  printf 'nested\n' > "$nested/.ap-copilot-home"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  printf '%s\n' '- nested - nested domain (home: '"$nested"'; scope: nested domain; projects: beta; added 2026-06-22)' > "$copilot_home/data/copilots.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-registry-teardown-fake")
  log="$TMP_ROOT/child-registry-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-registry-teardown-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing a child-registry copilot home"
  fi
  [ -d "$copilot_home" ] || fail "teardown removed ancestor home after child-registry refusal"
  [ -d "$nested" ] || fail "teardown removed child-registry nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared parent meta after child-registry refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before child-registry refusal"
  grep -F 'contains registered copilot home' "$err" >/dev/null || fail "teardown did not explain child-registry nested-home refusal"
  pass "copilot teardown refuses nested homes from the child registry"
}

test_copilot_force_teardown_prevalidates_before_child_cleanup() {
  local home copilot_home childproj childwt fakebin err log
  home="$TMP_ROOT/prevalidate-teardown-home"
  copilot_home="$TMP_ROOT/prevalidate-teardown-copilot_home"
  childproj="$copilot_home/projects/alpha"
  childwt="$TMP_ROOT/prevalidate-child-worktree"
  err="$TMP_ROOT/prevalidate-teardown.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state" "$childproj" "$childwt"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  cat > "$copilot_home/state/child.meta" <<EOF
window=autopilot:ap-child
worktree=$childwt
project=$childproj
harness=echo
kind=flight
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/prevalidate-teardown-fake")
  log="$TMP_ROOT/prevalidate-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/prevalidate-teardown-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown discarded child work before validating copilot_home"
  fi
  [ -d "$copilot_home" ] || fail "force teardown removed unmarked copilot_home after refusal"
  [ -d "$childwt" ] || fail "force teardown removed child worktree before validation"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta before validation"
  [ -e "$copilot_home/state/child.meta" ] || fail "force teardown cleared child meta before validation"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before copilot_home validation"
  grep -F 'not a seeded copilot home' "$err" >/dev/null || fail "force teardown did not explain missing seed marker"
  pass "force teardown validates copilot_home before child cleanup"
}

test_copilot_force_teardown_refuses_child_active_home_descendant() {
  local home copilot_home childproj childwt fakebin err log
  home="$TMP_ROOT/child-active-descendant-home"
  copilot_home="$TMP_ROOT/child-active-descendant-copilot_home"
  childproj="$copilot_home/projects/alpha"
  childwt="$home/data"
  err="$TMP_ROOT/child-active-descendant.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state" "$childproj"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  cat > "$copilot_home/state/child.meta" <<EOF
window=autopilot:ap-child
worktree=$childwt
project=$childproj
harness=echo
kind=flight
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-active-descendant-fake")
  log="$TMP_ROOT/child-active-descendant-fake/tmux.log"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-active-descendant-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside active AP_HOME"
  fi
  [ -d "$home/data" ] || fail "force teardown removed active home data"
  [ -d "$copilot_home" ] || fail "force teardown removed copilot_home after child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after child validation refusal"
  [ -e "$copilot_home/state/child.meta" ] || fail "force teardown cleared child meta after child validation refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before child validation refusal"
  grep -F 'inside the active autopilot home' "$err" >/dev/null || fail "force teardown did not explain active home descendant rejection"
  pass "force teardown refuses child worktrees inside the active home"
}

test_copilot_force_teardown_refuses_child_repo_descendant() {
  local home copilot_home childproj childwt fakeroot fakebin err log
  home="$TMP_ROOT/child-repo-descendant-home"
  copilot_home="$TMP_ROOT/child-repo-descendant-copilot_home"
  childproj="$copilot_home/projects/alpha"
  fakeroot="$TMP_ROOT/child-repo-descendant-root"
  childwt="$fakeroot/data"
  err="$TMP_ROOT/child-repo-descendant.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state" "$childproj" "$childwt" "$fakeroot/bin"
  cat > "$fakeroot/bin/ap-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/ap-guard.sh"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  cat > "$copilot_home/state/child.meta" <<EOF
window=autopilot:ap-child
worktree=$childwt
project=$childproj
harness=echo
kind=flight
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-repo-descendant-fake")
  log="$TMP_ROOT/child-repo-descendant-fake/tmux.log"
  if PATH="$fakebin:$PATH" AP_ROOT_OVERRIDE="$fakeroot" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-repo-descendant-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside AP_ROOT"
  fi
  [ -d "$childwt" ] || fail "force teardown removed repo descendant worktree"
  [ -d "$copilot_home" ] || fail "force teardown removed copilot_home after repo child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after repo child validation refusal"
  [ -e "$copilot_home/state/child.meta" ] || fail "force teardown cleared child meta after repo child validation refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before repo child validation refusal"
  grep -F 'inside the autopilot repo' "$err" >/dev/null || fail "force teardown did not explain repo descendant rejection"
  pass "force teardown refuses child worktrees inside the autopilot repo"
}

test_copilot_force_teardown_refuses_unregistered_child_worktree() {
  local home copilot_home childproj childwt fakebin err log
  home="$TMP_ROOT/unregistered-child-home"
  copilot_home="$TMP_ROOT/unregistered-child-copilot_home"
  childproj="$copilot_home/projects/alpha"
  childwt="$TMP_ROOT/unregistered-child-worktree"
  err="$TMP_ROOT/unregistered-child.err"
  mkdir -p "$home/state" "$home/data" "$copilot_home/state" "$childproj" "$childwt"
  printf 'domain\n' > "$copilot_home/.ap-copilot-home"
  cat > "$home/state/domain.meta" <<EOF
window=autopilot:ap-domain
worktree=$copilot_home
project=$copilot_home
harness=echo
kind=copilot
mode=copilot
yolo=off
home=$copilot_home
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$copilot_home"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/copilots.md"
  cat > "$copilot_home/state/child.meta" <<EOF
window=autopilot:ap-child
worktree=$childwt
project=$childproj
harness=echo
kind=flight
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/unregistered-child-fake")
  log="$TMP_ROOT/unregistered-child-fake/tmux.log"
  if PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_LOG="$log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/unregistered-child-fake/pane.txt" \
    "$ROOT/bin/ap-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed an unregistered child worktree"
  fi
  [ -d "$childwt" ] || fail "force teardown removed unregistered child worktree"
  [ -d "$copilot_home" ] || fail "force teardown removed copilot_home after unregistered child refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after unregistered child refusal"
  [ -e "$copilot_home/state/child.meta" ] || fail "force teardown cleared child meta after unregistered child refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before unregistered child refusal"
  grep -F 'is not a git worktree for' "$err" >/dev/null || fail "force teardown did not explain unregistered child rejection"
  pass "force teardown refuses unregistered child worktree paths"
}

test_copilot_idle_pane_is_not_stale() {
  local home fakebin out pid window
  home="$TMP_ROOT/watch-home"
  mkdir -p "$home/state"
  window="autopilot:ap-domain"
  cat > "$home/state/domain.meta" <<EOF
window=$window
worktree=$TMP_ROOT/watch-copilot_home
project=$TMP_ROOT/watch-copilot_home
harness=echo
kind=copilot
home=$TMP_ROOT/watch-copilot_home
projects=alpha
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/watch-fake")
  out="$TMP_ROOT/watch-fake/watch.out"
  PATH="$fakebin:$PATH" AP_HOME="$home" AP_FAKE_TMUX_WINDOW="$window" AP_FAKE_TMUX_LOG="$TMP_ROOT/watch-fake/tmux.log" AP_FAKE_TMUX_CAPTURE="$TMP_ROOT/watch-fake/pane.txt" \
    AP_POLL=1 AP_SIGNAL_GRACE=1 AP_CHECK_INTERVAL=999999 AP_HEARTBEAT=999999 "$ROOT/bin/ap-watch.sh" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then
    wait "$pid" || true
    grep -F "stale: $window" "$out" >/dev/null && fail "idle copilot pane triggered stale wake"
    fail "watcher exited unexpectedly while supervising idle copilot"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null && fail "idle copilot pane triggered stale wake"
  pass "idle kind=copilot pane is healthy and not stale"
}

test_copilot_charter_brief_is_idle_by_default() {
  local home brief
  home="$TMP_ROOT/idle-charter-home"
  mkdir -p "$home/data" "$home/state"
  scaffold_copilot_charter "$home" idle-copilot 'feature work for alpha' alpha
  brief="$home/data/idle-copilot/brief.md"
  [ -f "$brief" ] || fail "copilot charter brief was not scaffolded"
  # Idle contract: waits for routed work, never self-initiates.
  grep -F 'go idle and wait silently for the main autopilot' "$brief" >/dev/null \
    || fail "charter brief does not tell the copilot to go idle and wait for routed work"
  grep -F 'Act only on tasks the main autopilot routes to you' "$brief" >/dev/null \
    || fail "charter brief does not restrict work to routed tasks"
  grep -F 'never spawn a survey, audit, or any self-directed' "$brief" >/dev/null \
    || fail "charter brief does not forbid self-initiated survey/audit work"
  # Reconcile-on-startup must remain: bootstrap and recovery still run, scoped to own work.
  grep -F 'run normal autopilot bootstrap and recovery' "$brief" >/dev/null \
    || fail "charter brief dropped the bootstrap/recovery reconciliation step"
  grep -F 'only to RECONCILE work that is already yours' "$brief" >/dev/null \
    || fail "charter brief does not scope startup work to reconciling existing work"
  # Regression guard: the over-broad phrasing that got misread as "go find work" is gone.
  if grep -F 'then supervise work that matches your scope' "$brief" >/dev/null; then
    fail "charter brief still uses the over-broad 'supervise work that matches your scope' phrasing"
  fi
  pass "copilot charter brief is idle by default and does not self-initiate work"
}

test_backlog_handoff_aborts_safely() {
  # The happy move (verbatim into the Queued section, out-of-scope left alone,
  # idempotent re-run) is asserted in the lifecycle e2e. Here: every refusal path
  # aborts atomically and mutates neither backlog.
  local home copilot_home subhome_abs before
  home="$TMP_ROOT/handoff-main"
  copilot_home="$TMP_ROOT/handoff-sub"
  mkdir -p "$home/data" "$home/state"
  seed_copilot_home_marker "$copilot_home" design
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/copilots.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - active work (repo: alpha, since 2026-06-20)

## Queued
- [ ] bug-z - fix bug z (repo: gamma)

## Done
- [x] old-task - delivered thing - local main (merged 2026-06-19)
EOF

  # A key matching neither backlog aborts atomically: nothing moves.
  before=$(cat "$home/data/backlog.md")
  if AP_HOME="$home" "$ROOT/bin/ap-backlog-handoff.sh" design bug-z no-such-key >/dev/null 2>&1; then
    fail "handoff succeeded despite an unmatched key"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an unmatched key still mutated the main backlog"
  grep -F 'bug-z' "$home/data/backlog.md" >/dev/null || fail "atomic abort lost the valid bug-z item"

  # An in-flight item is refused (active ownership lives in tmux + state too).
  before=$(cat "$home/data/backlog.md")
  if AP_HOME="$home" "$ROOT/bin/ap-backlog-handoff.sh" design live-task >/dev/null 2>&1; then
    fail "handoff accepted an in-flight backlog item"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an in-flight key mutated the main backlog"
  grep -F 'live-task' "$home/data/backlog.md" >/dev/null || fail "in-flight refusal lost the live task"
  [ ! -e "$copilot_home/data/backlog.md" ] || ! grep -F 'live-task' "$copilot_home/data/backlog.md" >/dev/null     || fail "in-flight refusal copied the live task into the copilot backlog"

  # An unregistered copilot id is refused.
  if AP_HOME="$home" "$ROOT/bin/ap-backlog-handoff.sh" ghost bug-z >/dev/null 2>&1; then
    fail "handoff accepted an unregistered copilot id"
  fi
  pass "ap-backlog-handoff aborts atomically on unmatched, in-flight, and unregistered targets"
}

test_backlog_handoff_refuses_done_items_and_non_copilot_homes() {
  local home copilot_home subhome_abs projhome projhome_abs markerhome markerhome_abs symlinkhome symlinkhome_abs outside before_main before_sub out
  home="$TMP_ROOT/handoff-safety-main"
  copilot_home="$TMP_ROOT/handoff-safety-sub"
  projhome="$TMP_ROOT/handoff-safety-proj"
  markerhome="$TMP_ROOT/handoff-safety-marker"
  symlinkhome="$TMP_ROOT/handoff-safety-symlink"
  outside="$TMP_ROOT/handoff-safety-outside"
  mkdir -p "$home/data" "$home/state"

  seed_copilot_home_marker "$copilot_home" archive
  subhome_abs=$(cd "$copilot_home" && pwd -P)
  printf '## Queued\n- [ ] keep-me - stays (repo: alpha)\n' > "$copilot_home/data/backlog.md"
  printf -- '- archive - archival (home: %s; scope: archival; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/copilots.md"
  printf '##\tDone\n- [x] delivered-task - delivered thing - local main (merged 2026-06-19)\n' > "$home/data/backlog.md"
  before_main="$TMP_ROOT/handoff-safety-main.before"
  before_sub="$TMP_ROOT/handoff-safety-sub.before"
  cp "$home/data/backlog.md" "$before_main"
  cp "$copilot_home/data/backlog.md" "$before_sub"
  if out=$(AP_HOME="$home" "$ROOT/bin/ap-backlog-handoff.sh" archive delivered-task 2>&1); then
    fail "handoff accepted a Done backlog item"
  fi
  printf '%s\n' "$out" | grep -F 'delivered-task' >/dev/null \
    || fail "Done-item refusal did not name the selected item"
  printf '%s\n' "$out" | grep -F 'queued work only' >/dev/null \
    || fail "Done-item refusal did not state the queued-only contract"
  cmp -s "$before_main" "$home/data/backlog.md" \
    || fail "Done-item refusal mutated the main backlog"
  cmp -s "$before_sub" "$copilot_home/data/backlog.md" \
    || fail "Done-item refusal mutated the copilot backlog"

  # A registered home that is not a seeded copilot home (e.g. a project clone)
  # is refused, and nothing is written into it.
  ap_git_init_commit "$projhome"
  projhome_abs=$(cd "$projhome" && pwd -P)
  printf -- '- proj-copilot - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$projhome_abs" >> "$home/data/copilots.md"
  if AP_HOME="$home" "$ROOT/bin/ap-backlog-handoff.sh" proj-copilot delivered-task >/dev/null 2>&1; then
    fail "handoff wrote into a destination that is not a seeded copilot home"
  fi
  [ ! -e "$projhome/data/backlog.md" ] || fail "handoff created a backlog inside a non-copilot home"

  mkdir -p "$markerhome/data"
  markerhome_abs=$(cd "$markerhome" && pwd -P)
  printf 'marker-copilot\n' > "$markerhome/.ap-copilot-home"
  printf -- '- marker-copilot - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$markerhome_abs" >> "$home/data/copilots.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] marker-task - should not move (repo: alpha)
EOF
  if AP_HOME="$home" "$ROOT/bin/ap-backlog-handoff.sh" marker-copilot marker-task >/dev/null 2>&1; then
    fail "handoff accepted a marker-only directory as a copilot home"
  fi
  [ ! -e "$markerhome/data/backlog.md" ] || fail "handoff wrote into a marker-only directory"
  grep -F 'marker-task' "$home/data/backlog.md" >/dev/null || fail "marker-only refusal lost the main backlog item"

  seed_copilot_home_marker "$symlinkhome" symlink-copilot
  symlinkhome_abs=$(cd "$symlinkhome" && pwd -P)
  mkdir -p "$outside"
  rm -rf "$symlinkhome/data"
  ln -s "$outside" "$symlinkhome/data"
  printf -- '- symlink-copilot - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$symlinkhome_abs" >> "$home/data/copilots.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] symlink-task - should not move (repo: alpha)
EOF
  if AP_HOME="$home" "$ROOT/bin/ap-backlog-handoff.sh" symlink-copilot symlink-task >/dev/null 2>&1; then
    fail "handoff accepted a copilot home with data outside the home"
  fi
  [ ! -e "$outside/backlog.md" ] || fail "handoff wrote through a symlinked copilot data directory"
  grep -F 'symlink-task' "$home/data/backlog.md" >/dev/null || fail "symlink refusal lost the main backlog item"
  pass "ap-backlog-handoff refuses Done items under whitespace section headings and unsafe homes"
}

test_ap_home_parameterization
test_lock_status_is_per_home
test_seed_allows_overlapping_clones_and_drops_owner
test_home_seed_validate_rejects_duplicate_homes
test_home_seed_validate_rejects_duplicate_ids
test_home_seed_validate_rejects_nested_homes
test_home_seed_uses_treehouse_acquired_home
test_home_seed_returns_treehouse_acquired_home_on_assignment_failure
test_home_seed_warns_when_acquired_home_return_fails
test_home_seed_does_not_return_unsafe_acquired_home
test_home_seed_rolls_back_failed_clone
test_home_seed_refuses_missing_filled_charter
test_home_seed_refuses_placeholder_charter
test_home_seed_refuses_empty_charter_fields
test_home_seed_no_projects_end_to_end
test_home_seed_refuses_projectful_reused_charter_for_projectless_home
test_home_seed_refuses_projectless_conversion_of_populated_home
test_home_seed_refuses_projectless_home_with_uninspectable_projects
test_home_seed_refuses_projectless_home_with_symlinked_projects
test_home_seed_refuses_projectless_home_with_non_directory_projects
test_home_seed_refuses_projectless_home_with_uninspectable_registry
test_home_seed_refuses_missing_projects_without_signal
test_home_seed_refuses_local_only_project
test_home_seed_refuses_registry_delimiter_home
test_home_seed_refuses_active_home_and_root
test_home_seed_refuses_home_marked_for_another_id
test_home_seed_refuses_home_registered_to_another_id
test_home_seed_refuses_reassigning_existing_id_to_different_home
test_home_seed_refuses_home_overlapping_registered_home
test_home_seed_refuses_remote_backed_project_without_origin
test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin
test_home_seed_resolves_relative_source_origins
test_home_seed_skips_initialized_existing_no_mistakes_projects
test_home_seed_refuses_uninitialized_existing_no_mistakes_project
test_home_seed_refuses_project_destinations_outside_subhome
test_home_seed_refuses_operational_dirs_outside_subhome
test_home_seed_refuses_symlinked_leaf_files
test_copilot_spawn_requires_seeded_matching_home
test_copilot_spawn_refuses_operational_dirs_outside_subhome
test_ap_send_refuses_bare_window_without_home_meta
test_copilot_teardown_retires_empty_home
test_copilot_teardown_refuses_failed_leased_home_return
test_copilot_teardown_removes_plain_clone_home_without_treehouse_return
test_copilot_force_teardown_discards_child_work
test_copilot_force_teardown_refuses_child_quarantine_symlink
test_copilot_force_teardown_preserves_child_on_unproven_lock
test_copilot_force_teardown_allows_operational_dir_symlinks_inside_home
test_copilot_force_teardown_refuses_operational_dir_symlink_outside_home
test_copilot_teardown_refuses_registered_nested_home
test_copilot_teardown_refuses_child_registry_nested_home
test_copilot_force_teardown_prevalidates_before_child_cleanup
test_copilot_force_teardown_refuses_child_active_home_descendant
test_copilot_force_teardown_refuses_child_repo_descendant
test_copilot_force_teardown_refuses_unregistered_child_worktree
test_copilot_teardown_path_boundary_matrix
test_copilot_idle_pane_is_not_stale
test_copilot_charter_brief_is_idle_by_default
test_backlog_handoff_aborts_safely
test_backlog_handoff_refuses_done_items_and_non_copilot_homes
