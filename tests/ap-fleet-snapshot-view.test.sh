#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/ap-fleet-snapshot.sh"
VIEW="$ROOT/bin/ap-fleet-view.sh"
TMP_ROOT=$(ap_test_tmproot ap-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(ap_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${AP_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-copilot*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *flight-task*|*active-copilot*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_idle() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/ap-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/ap-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/recon-worktree" "$home/copilot-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] recon-task - Recon Task data/recon-task/report.md (repo: alpha) (kind: recon) (since 2026-07-07)
- [ ] flight-task - Flight Task https://github.com/hxutixnnn/autopilot/pull/9 (repo: alpha) (kind: flight) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: flight-task (repo: alpha) (kind: flight) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/hxutixnnn/autopilot/pull/7 (repo: alpha) (kind: flight) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/recon-task"
  printf '# Recon\n' > "$home/data/recon-task/report.md"
  ap_write_meta "$home/state/flight-task.meta" \
    "window=autopilot:ap-flight-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=flight" \
    "mode=flight" \
    "yolo=off" \
    "pr=https://github.com/hxutixnnn/autopilot/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/flight-task.status"
  # A working flight task proves it through its own semantic busy-state record
  # (bin/ap-busy-lib.sh), which is what the snapshot's current-state read
  # consults; rendered pane text is no longer a state source.
  fixture_gen=$("$ROOT/bin/ap-busy-event.sh" arm "$home/state" flight-task)
  "$ROOT/bin/ap-busy-event.sh" apply "$home/state" flight-task busy --gen "$fixture_gen" \
    --source claude-hook --event user-prompt-submit
  ap_write_meta "$home/state/recon-task.meta" \
    "window=autopilot:ap-recon-task" \
    "worktree=$home/projects/recon-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=recon" \
    "mode=recon" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/recon-task.status"
  ap_write_meta "$home/state/copilot-task.meta" \
    "window=autopilot:ap-copilot-task" \
    "worktree=$home/copilot-home" \
    "project=$home/copilot-home" \
    "harness=codex" \
    "kind=copilot" \
    "mode=copilot" \
    "home=$home/copilot-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/copilot-task.status"
  ap_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=flight" \
    "mode=flight"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .schema == "ap-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(AP_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,copilot-task,flight-task,recon-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "flight-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/hxutixnnn/autopilot/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "flight task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "recon-task")
    | .paths.report.present == true
      and .hints.recon_report_present == true
  ' >/dev/null || fail "recon report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "copilot-task")
    | .copilot_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely ap-peek"))
  ' >/dev/null || fail "copilot return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/hxutixnnn/autopilot/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-flight - Structured without meta (repo: alpha) (kind: flight) (since 2026-07-11)
- [ ] visible-flight - Structured with meta (repo: alpha) (kind: flight) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-flight - Structured queued (repo: alpha) (kind: flight)

## Done
EOF
  ap_write_meta "$home/state/visible-flight.meta" \
    "window=autopilot:ap-visible-flight" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=flight" \
    "mode=flight"
  printf 'working: visible\n' > "$home/state/visible-flight.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-flight"])
      and ([.tasks[].id] == ["visible-flight"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-flight - Structured without meta (repo: alpha) (kind: flight) (since 2026-07-11)
- [ ] visible-flight - Structured with meta (repo: alpha) (kind: flight) (since 2026-07-11)

## Queued
- [ ] queued-flight - Structured queued (repo: alpha) (kind: flight)

## Done
EOF
  ap_write_meta "$home/state/orphan-flight.meta" \
    "window=autopilot:ap-orphan-flight" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=flight" \
    "mode=flight"
  printf 'working: orphan now live\n' > "$home/state/orphan-flight.status"
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-flight", "visible-flight"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: recon) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: flight)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: flight)

## Queued
- [ ] review - Security review (repo: alpha) (kind: flight)
- [ ] pilot-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: pilot) (hold: pilot runs canary) (hold-kind: external)

## Done
EOF
  ap_write_meta "$home/state/worker.meta" \
    "window=autopilot:ap-worker" "worktree=$home/projects/worker" "project=alpha" \
    "harness=codex" "kind=flight" "mode=flight"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "pilot-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .pilot_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: recon) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: flight)
- [ ] pilot-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: pilot) (hold: pilot runs canary) (hold-kind: external)

## Done
- [x] worker - Real worker (repo: alpha) (kind: flight) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "pilot-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .pilot_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: recon) (hold: watch production) (hold-kind: external)

## Queued
- [ ] pilot-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: pilot) (hold: pilot runs canary) (hold-kind: external)

## Done
- [x] worker - Real worker (repo: alpha) (kind: flight) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: flight) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "pilot-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .pilot_actionable == true
  ' >/dev/null || fail "completed blockers did not make the pilot hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "pilot-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == ["missing"]
      and .pilot_actionable == false
  ' >/dev/null || fail "a missing blocker was incorrectly treated as resolved: $out"
  pass "backlog normalization preserves strict roles and resolves every blocker compatibly"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out hint_gen
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  ap_write_meta "$home/state/active-decision.meta" \
    "window=autopilot:ap-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=flight" \
    "mode=flight"
  record_claude_idle "$home/state" active-decision
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  ap_write_meta "$home/state/active-blocked.meta" \
    "window=autopilot:ap-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=flight" \
    "mode=flight"
  record_claude_idle "$home/state" active-blocked
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  ap_write_meta "$home/state/stale-decision.meta" \
    "window=autopilot:ap-stale-decision-flight-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=flight" \
    "mode=flight"
  hint_gen=$("$ROOT/bin/ap-busy-event.sh" arm "$home/state" stale-decision)
  "$ROOT/bin/ap-busy-event.sh" apply "$home/state" stale-decision busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  ap_write_meta "$home/state/stale-blocked.meta" \
    "window=autopilot:ap-stale-blocked-flight-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=flight" \
    "mode=flight"
  hint_gen=$("$ROOT/bin/ap-busy-event.sh" arm "$home/state" stale-blocked)
  "$ROOT/bin/ap-busy-event.sh" apply "$home/state" stale-blocked busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_recon_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-recon" "$home/data/untracked-recon"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-recon - Reported Recon data/reported-recon/report.md (repo: alpha, reported 2026-07-07) (kind: recon)
EOF
  printf '# Reported Recon\n' > "$home/data/reported-recon/report.md"
  printf '# Untracked Recon\n' > "$home/data/untracked-recon/report.md"
  out=$(AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .recon_reports == [
        {id:"reported-recon",path:($home + "/data/reported-recon/report.md"),kind:"recon"},
        {id:"untracked-recon",path:($home + "/data/untracked-recon/report.md"),kind:"recon"}
      ]
  ' >/dev/null || fail "durable recon reports should remain visible after meta teardown"
  pass "snapshot includes durable recon reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: recon)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: flight)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: flight)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: flight) blocked-by: queued-comma - waits on queued-comma
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: pilot) (since 2026-07-14) (hold: pilot route choice pending) (hold-kind: external)

## Done
- [x] done-comma - Done Comma Task https://github.com/hxutixnnn/autopilot/pull/42 (repo: gamma, merged 2026-07-09) (kind: flight)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/hxutixnnn/autopilot/pull/43> (repo: gamma, merged 2026-07-12) (kind: flight)
- [x] reported-comma - Reported Recon data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: recon)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: flight)
EOF
  printf '# Bold Recon\n' > "$data/bold-task/report.md"
  ap_write_meta "$home/state/bold-task.meta" \
    "window=autopilot:ap-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=recon" \
    "mode=recon"
  record_claude_idle "$home/state" bold-task
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" AP_DATA_OVERRIDE="$data" AP_PROJECTS_OVERRIDE="$projects" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "recon"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "pilot"
      and .hold_reason == "pilot route choice pending"
      and .hold_kind == "external"
  ' >/dev/null || fail "tasks-axi pilot-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/hxutixnnn/autopilot/pull/43"
      and .links == ["https://github.com/hxutixnnn/autopilot/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Recon"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" AP_HOME="$home" AP_DATA_OVERRIDE="$data" AP_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log | recon | alpha | tmux | present | $data/bold-task/report.md" \
    "view should render bold in-flight row from snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | flight | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | flight | - | https://github.com/hxutixnnn/autopilot/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | flight | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$VIEW")
  assert_contains "$view" "| flight-task | working / pane | flight | alpha | tmux | present | https://github.com/hxutixnnn/autopilot/pull/9" \
    "view should render flight row from snapshot"
  assert_contains "$view" "| queued-task | Queued Task | alpha | flight | flight-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | flight | - | https://github.com/hxutixnnn/autopilot/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/ap-send.sh ap-copilot-task" \
    "view should show copilot send guidance"
  assert_contains "$view" "| copilot-task | working / status-log | copilot | $home/copilot-home | tmux | present / alive |" \
    "view should show copilot endpoint agent liveness"
  assert_not_contains "$view" "ap-peek.sh ap-copilot-task" \
    "view must not tell autopilot to routinely peek copilots"
  pass "fleet view renders the snapshot without copilot peek guidance"
}

test_view_renders_dead_copilot_agent_status() {
  local home fakebin view
  home=$(make_home dead-copilot)
  ap_write_meta "$home/state/dead-copilot.meta" \
    "window=autopilot:ap-dead-copilot" \
    "project=$home/copilot-home" \
    "harness=codex" \
    "kind=copilot" \
    "mode=copilot" \
    "home=$home/copilot-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-copilot.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-copilot | unknown / none | copilot | $home/copilot-home | tmux | present / dead |" \
    "view should distinguish a present copilot endpoint from a dead agent"
  assert_contains "$view" "| dead-copilot | unknown / none | copilot | $home/copilot-home | tmux | present / dead | - | $home/copilot-home (absent) |" \
    "view should show a recorded missing copilot home path"
  pass "fleet view renders copilot agent liveness"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (ap-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/copilot-home"
  ap_write_meta "$home/state/masked-decision.meta" \
    "window=autopilot:ap-masked-decision" \
    "worktree=$home/copilot-home" \
    "project=$home/copilot-home" \
    "harness=codex" \
    "kind=copilot" \
    "mode=copilot" \
    "home=$home/copilot-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_copilot_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-copilot)
  mkdir -p "$home/copilot-home"
  ap_write_meta "$home/state/active-copilot.meta" \
    "window=autopilot:ap-active-copilot" \
    "worktree=$home/copilot-home" \
    "project=$home/copilot-home" \
    "harness=codex" \
    "kind=copilot" \
    "mode=copilot" \
    "home=$home/copilot-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-copilot.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-copilot")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live copilot endpoint must not clear an unrelated keyed decision: $out"
  pass "a live copilot endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_transfers_to_pilot_hold() {
  local home fakebin out
  home=$(make_home pilot-held-transfer)
  mkdir -p "$home/copilot-home"
  ap_write_meta "$home/state/transferred-decision.meta" \
    "window=autopilot:ap-transferred-decision" \
    "worktree=$home/copilot-home" \
    "project=$home/copilot-home" \
    "harness=codex" \
    "kind=copilot" \
    "mode=copilot" \
    "home=$home/copilot-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'pilot-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "pilot-held transfer must close only the duplicate status copy: $out"
  pass "durable pilot-held transfer closes the duplicate live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/copilot-home"
  ap_write_meta "$home/state/resolved-decision.meta" \
    "window=autopilot:ap-resolved-decision" \
    "worktree=$home/copilot-home" \
    "project=$home/copilot-home" \
    "harness=codex" \
    "kind=copilot" \
    "mode=copilot" \
    "home=$home/copilot-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: pilot chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED recon report must never be read as a pending decision. A recon that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the pilot - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the flight crew lifecycle; report prose never opens or reopens a decision.
test_completed_recon_report_is_pointer_not_pending() {
  local home fakebin out
  home=$(make_home completed-recon)
  mkdir -p "$home/projects/recon-wt" "$home/data/lavish-103"
  ap_write_meta "$home/state/lavish-103.meta" \
    "window=autopilot:ap-lavish-103" \
    "worktree=$home/projects/recon-wt" \
    "project=autopilot" \
    "harness=claude" \
    "kind=recon" \
    "mode=recon"
  record_claude_idle "$home/state" lavish-103
  # Stale needs-decision, then the recon finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a pilot decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.recon_report_present == true
  ' >/dev/null || fail "a completed recon report must be a pointer, not a pending decision: $out"
  pass "a completed recon's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a recon still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided recon.
test_parked_recon_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-recon)
  mkdir -p "$home/projects/recon-wt2"
  ap_write_meta "$home/state/parked-recon.meta" \
    "window=autopilot:ap-parked-recon" \
    "worktree=$home/projects/recon-wt2" \
    "project=autopilot" \
    "harness=claude" \
    "kind=recon" \
    "mode=recon"
  record_claude_idle "$home/state" parked-recon
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-recon.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" AP_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-recon")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a recon still parked at a decision must stay pending: $out"
  pass "a recon still parked at a decision stays pending (terminal clear does not over-fire)"
}

test_empty_fleet_json
test_fixture_snapshot_json
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_copilot_open_decision_survives_live_endpoint
test_open_decision_transfers_to_pilot_hold
test_open_decision_clears_on_keyed_resolution
test_completed_recon_report_is_pointer_not_pending
test_parked_recon_decision_stays_pending
test_recon_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_view_renders_dead_copilot_agent_status
