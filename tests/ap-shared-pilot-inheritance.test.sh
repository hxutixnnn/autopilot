#!/usr/bin/env bash
# Behavior tests for primary-authoritative shared pilot-preference inheritance.
#
# The narrow shared surface is exactly data/pilot-shared.md.
# data/pilot.md and data/learnings.md remain domain-local in every home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/ap-config-inherit-lib.sh"

BASE_PATH=${AP_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(ap_test_tmproot ap-shared-pilot)

ap_git_identity fmtest fmtest@example.invalid

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

shared_header() {
  cat <<'EOF'
# Shared pilot preferences

This file is main-authoritative in the main autopilot home.
In copilot homes it is read-only in copilot homes and must not be edited there.
Route new pilot-preference discoveries to the main autopilot through marked status or a document pointer.
EOF
}

write_shared() {
  local path=$1 body=$2
  shared_header > "$path"
  printf '%s\n' "$body" >> "$path"
}

new_home_pair() {
  local name=$1 base primary second
  base="$TMP_ROOT/$name"
  primary="$base/primary"
  second="$base/second"
  mkdir -p "$primary/data" "$primary/config" "$second/data" "$second/config"
  printf '%s\n' "primary local pilot" > "$primary/data/pilot.md"
  printf '%s\n' "second local pilot" > "$second/data/pilot.md"
  printf '%s\n' "primary local learning" > "$primary/data/learnings.md"
  printf '%s\n' "second local learning" > "$second/data/learnings.md"
  printf '%s\n' "$primary|$second"
}

assert_shared_readonly() {
  local path=$1
  [ "$(file_mode "$path")" = "$AP_SHARED_PILOT_MODE" ] \
    || fail "$path mode should be $AP_SHARED_PILOT_MODE, got $(file_mode "$path")"
}

assert_copilot_write_fails() {
  local path=$1
  if ( printf '%s\n' "copilot edit" >> "$path" ) 2>/dev/null; then
    fail "ordinary write unexpectedly succeeded for read-only shared pilot file"
  fi
}

test_first_copy_readonly_and_local_files_preserved() {
  local rec primary second report out
  rec=$(new_home_pair first-copy)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$primary/data/pilot-shared.md" "shared v1"
  report="$TMP_ROOT/first-copy.report"

  out=$(AP_CONFIG_INHERIT_REPORT="$report" propagate_copilot_inheritance "$primary" "$second")

  [ -z "$out" ] || fail "first copy should not emit a quarantine diagnostic: $out"
  cmp -s "$primary/data/pilot-shared.md" "$second/data/pilot-shared.md" \
    || fail "first copy did not converge copilot shared preferences"
  assert_shared_readonly "$second/data/pilot-shared.md"
  assert_copilot_write_fails "$second/data/pilot-shared.md"
  assert_grep $'data/pilot-shared.md\tpushed\t' "$report" "first copy should report pushed"
  assert_grep "second local pilot" "$second/data/pilot.md" "domain-local pilot.md was changed"
  assert_grep "second local learning" "$second/data/learnings.md" "domain-local learnings.md was changed"

  : > "$report"
  out=$(AP_CONFIG_INHERIT_REPORT="$report" propagate_copilot_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "unchanged convergence should stay quiet: $out"
  assert_grep $'data/pilot-shared.md\tunchanged\t' "$report" "unchanged bytes should report unchanged"
  assert_shared_readonly "$second/data/pilot-shared.md"
  pass "shared pilot first copy converges, is read-only, and preserves local pilot/learnings files"
}

test_drift_quarantine_collision_and_repeated_convergence() {
  local rec primary second fakebin hash collision report out diag qpath qcount
  rec=$(new_home_pair drift)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$primary/data/pilot-shared.md" "shared v2"
  write_shared "$second/data/pilot-shared.md" "local drift"
  chmod "$AP_SHARED_PILOT_MODE" "$second/data/pilot-shared.md"
  hash=$(ap_inherit_sha256 "$second/data/pilot-shared.md")
  collision="$second/data/.pilot-shared.md.quarantine.20260102T030405Z.$hash"
  printf '%s\n' "preexisting different artifact" > "$collision"
  chmod 0600 "$collision"

  fakebin="$TMP_ROOT/fake-date"
  mkdir -p "$fakebin"
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 20260102T030405Z
SH
  chmod +x "$fakebin/date"
  report="$TMP_ROOT/drift.report"

  out=$(PATH="$fakebin:$BASE_PATH" AP_CONFIG_INHERIT_REPORT="$report" \
    propagate_copilot_inheritance "$primary" "$second")

  diag=$(printf '%s\n' "$out" | grep '^COPILOT_SYNC: copilot home ' || true)
  [ -n "$diag" ] || fail "drift quarantine should emit a COPILOT_SYNC diagnostic"
  qpath=${diag##* at }
  [ "$qpath" = "$collision.1" ] || fail "collision-safe quarantine name should use .1, got $qpath"
  assert_grep "local drift" "$qpath" "quarantine artifact lost the copilot-local bytes"
  assert_grep $'data/pilot-shared.md\tpushed\tquarantined local drift at '"$qpath" "$report" \
    "drift push should name the quarantine artifact in the report"
  cmp -s "$primary/data/pilot-shared.md" "$second/data/pilot-shared.md" \
    || fail "drift convergence did not install primary bytes"
  assert_shared_readonly "$second/data/pilot-shared.md"

  : > "$report"
  out=$(PATH="$fakebin:$BASE_PATH" AP_CONFIG_INHERIT_REPORT="$report" \
    propagate_copilot_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "repeated convergence should not quarantine again: $out"
  qcount=$(find "$second/data" -name '.pilot-shared.md.quarantine.*' | wc -l | tr -d ' ')
  [ "$qcount" -eq 2 ] || fail "repeated convergence created extra quarantine artifacts"
  assert_grep $'data/pilot-shared.md\tunchanged\t' "$report" "repeated convergence should report unchanged"
  pass "shared pilot drift is quarantined collision-safely and repeated convergence is idempotent"
}

test_missing_source_mirrors_absence_without_losing_local_bytes() {
  local rec primary second out diag qpath
  rec=$(new_home_pair missing-source)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$second/data/pilot-shared.md" "orphaned local shared file"
  chmod "$AP_SHARED_PILOT_MODE" "$second/data/pilot-shared.md"

  out=$(propagate_copilot_inheritance "$primary" "$second")

  diag=$(printf '%s\n' "$out" | grep '^COPILOT_SYNC: copilot home ' || true)
  [ -n "$diag" ] || fail "primary absence with a local copy should quarantine before removal"
  qpath=${diag##* at }
  assert_absent "$second/data/pilot-shared.md" "primary absence should converge destination to absence"
  assert_grep "orphaned local shared file" "$qpath" "missing-source quarantine lost local bytes"
  assert_grep "second local pilot" "$second/data/pilot.md" "missing-source changed local pilot.md"
  assert_grep "second local learning" "$second/data/learnings.md" "missing-source changed local learnings.md"
  pass "missing primary shared file mirrors absence only after quarantining a local copy"
}

test_unsafe_artifacts_and_failure_restore_readonly_mode() {
  local rec primary second other err before_mode rc
  rec=$(new_home_pair unsafe)
  primary=${rec%%|*}
  second=${rec#*|}

  ln -s "$primary/data/pilot.md" "$primary/data/pilot-shared.md"
  err="$TMP_ROOT/unsafe-source.err"
  propagate_copilot_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked primary source should be rejected"
  assert_grep "unsafe primary source" "$err" "unsafe source error should be explicit"
  rm -f "$primary/data/pilot-shared.md"
  write_shared "$primary/data/pilot-shared.md" "safe source"

  ln -s "$second/data/pilot.md" "$second/data/pilot-shared.md"
  err="$TMP_ROOT/unsafe-dest-symlink.err"
  propagate_copilot_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked destination should be rejected"
  assert_grep "unsafe destination" "$err" "unsafe destination symlink error should be explicit"
  rm -f "$second/data/pilot-shared.md"

  write_shared "$second/data/pilot-shared.md" "hardlinked local drift"
  other="$second/data/hardlink-copy"
  ln "$second/data/pilot-shared.md" "$other"
  err="$TMP_ROOT/unsafe-dest-hardlink.err"
  propagate_copilot_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked destination should be rejected"
  assert_grep "unsafe destination" "$err" "unsafe destination hardlink error should be explicit"
  rm -f "$second/data/pilot-shared.md" "$other"

  write_shared "$second/data/pilot-shared.md" "permission drift"
  chmod "$AP_SHARED_PILOT_MODE" "$second/data/pilot-shared.md"
  before_mode=$(file_mode "$second/data/pilot-shared.md")
  chmod 500 "$second/data"
  err="$TMP_ROOT/restore-readonly.err"
  propagate_copilot_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  chmod 700 "$second/data"
  [ "$rc" -ne 0 ] || fail "unwritable destination directory should make quarantine fail"
  [ "$(file_mode "$second/data/pilot-shared.md")" = "$before_mode" ] \
    || fail "failed quarantine did not restore read-only mode"
  assert_grep "failed to quarantine divergent destination" "$err" \
    "recoverable failure should explain quarantine failure"
  pass "unsafe shared pilot artifacts are rejected and failure restores read-only mode"
}

make_fake_spawn_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

new_git_world() {
  local name=$1 w root home c1
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  {
    printf '%s\n' '.ap-copilot-home'
    printf '%s\n' 'data/'
    printf '%s\n' 'state/'
    printf '%s\n' 'config/'
    printf '%s\n' 'projects/'
  } > "$root/.gitignore"
  printf '%s\n' "instructions" > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' "echo spawn" > "$root/bin/ap-spawn.sh"
  printf '%s\n' "skill" > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$w/copilot" "$c1"
  printf '%s\n' copilot > "$w/copilot/.ap-copilot-home"
  mkdir -p "$w/copilot/data" "$w/copilot/state" "$w/copilot/config" "$w/copilot/projects"
  printf '%s\n' "charter" > "$w/copilot/data/charter.md"
  write_shared "$home/data/pilot-shared.md" "shared from primary"
  printf '%s|%s|%s|%s\n' "$w" "$root" "$home" "$w/copilot"
}

test_spawn_convergence_point_copies_shared_file() {
  local rec w root home copilot fakebin data_override
  rec=$(new_git_world spawn-point)
  IFS='|' read -r w root home copilot <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  write_shared "$data_override/pilot-shared.md" "shared from override"
  fakebin=$(make_fake_spawn_toolchain "$w")

  PATH="$fakebin:$BASE_PATH" TMUX='' \
    AP_ROOT_OVERRIDE="$root" AP_HOME="$home" \
    AP_STATE_OVERRIDE="$home/state" AP_DATA_OVERRIDE="$data_override" \
    AP_PROJECTS_OVERRIDE="$home/projects" AP_CONFIG_OVERRIDE="$home/config" \
    AP_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/ap-spawn.sh" copilot "$copilot" codex --copilot >/dev/null 2>&1 || true

  cmp -s "$data_override/pilot-shared.md" "$copilot/data/pilot-shared.md" \
    || fail "spawn convergence point did not copy shared pilot preferences from AP_DATA_OVERRIDE"
  assert_shared_readonly "$copilot/data/pilot-shared.md"
  pass "spawn convergence point propagates data/pilot-shared.md from AP_DATA_OVERRIDE"
}

test_bootstrap_convergence_point_copies_shared_file() {
  local rec w root home copilot fakebin data_override out
  rec=$(new_git_world bootstrap-point)
  IFS='|' read -r w root home copilot <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  write_shared "$data_override/pilot-shared.md" "shared from bootstrap override"
  {
    printf 'window=autopilot:ap-copilot\n'
    printf 'kind=copilot\n'
  } > "$home/state/copilot.meta"
  printf -- '- copilot - fixture copilot (home: %s; scope: fixture; projects: sample; added 2026-07-16)\n' "$copilot" \
    > "$data_override/copilots.md"
  fakebin=$(make_fake_spawn_toolchain "$w")
  ap_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi gh treehouse no-mistakes tasks-axi quota-axi

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$root" \
    AP_DATA_OVERRIDE="$data_override" \
    "$ROOT/bin/ap-bootstrap.sh" 2>/dev/null)

  assert_not_contains "$out" "COPILOT_SYNC: copilot copilot: skipped: inheritance failed" \
    "bootstrap inheritance should succeed"
  cmp -s "$data_override/pilot-shared.md" "$copilot/data/pilot-shared.md" \
    || fail "bootstrap convergence point did not copy shared pilot preferences from AP_DATA_OVERRIDE"
  assert_shared_readonly "$copilot/data/pilot-shared.md"
  pass "bootstrap convergence point propagates data/pilot-shared.md from AP_DATA_OVERRIDE"
}

test_config_push_convergence_point_updates_changed_source() {
  local rec w root home copilot data_override out
  rec=$(new_git_world config-push-point)
  IFS='|' read -r w root home copilot <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  {
    printf 'window=autopilot:ap-copilot\n'
    printf 'kind=copilot\n'
    printf 'home=%s\n' "$copilot"
  } > "$home/state/copilot.meta"
  write_shared "$copilot/data/pilot-shared.md" "old shared bytes"
  chmod "$AP_SHARED_PILOT_MODE" "$copilot/data/pilot-shared.md"
  write_shared "$data_override/pilot-shared.md" "changed override shared bytes"

  out=$(PATH="$BASE_PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$root" \
    AP_DATA_OVERRIDE="$data_override" \
    "$ROOT/bin/ap-config-push.sh" 2>/dev/null)

  assert_contains "$out" "data/pilot-shared.md: pushed - quarantined local drift at" \
    "config-push should report the shared file update and quarantine"
  cmp -s "$data_override/pilot-shared.md" "$copilot/data/pilot-shared.md" \
    || fail "config-push convergence point did not update shared pilot preferences from AP_DATA_OVERRIDE"
  assert_shared_readonly "$copilot/data/pilot-shared.md"
  pass "ap-config-push convergence point updates changed shared pilot source bytes from AP_DATA_OVERRIDE"
}

test_session_start_digest_labels_shared_file_and_read_once_rule() {
  local rec w root home _sm fakebin out
  rec=$(new_git_world session-start-label)
  IFS='|' read -r w root home _sm <<EOF
$rec
EOF
  fakebin=$(make_fake_spawn_toolchain "$w")
  ap_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi gh treehouse no-mistakes tasks-axi quota-axi pgrep

  out=$(PATH="$fakebin:$BASE_PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/ap-session-start.sh")

  assert_contains "$out" "data/pilot-shared.md (shared, main-authoritative, read-only in copilot homes)" \
    "session-start digest should label the shared pilot file unmistakably"
  assert_contains "$out" "shared from primary" "session-start digest should render the shared file"
  assert_contains "$out" "data/pilot-shared.md, data/learnings.md" \
    "read-once reminder should include pilot-shared.md"
  pass "session-start digest renders data/pilot-shared.md with the shared read-only label"
}

test_first_copy_readonly_and_local_files_preserved
test_drift_quarantine_collision_and_repeated_convergence
test_missing_source_mirrors_absence_without_losing_local_bytes
test_unsafe_artifacts_and_failure_restore_readonly_mode
test_spawn_convergence_point_copies_shared_file
test_bootstrap_convergence_point_copies_shared_file
test_config_push_convergence_point_updates_changed_source
test_session_start_digest_labels_shared_file_and_read_once_rule

echo "# all ap-shared-pilot-inheritance tests passed"
