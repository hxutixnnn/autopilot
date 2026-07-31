#!/usr/bin/env bash
# Behavioral coverage for the visible startup-memory budget, its safe parser,
# accounting command, primary-to-copilot convergence, and exact reread bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${AP_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(ap_test_tmproot ap-startup-memory-budget)
BUDGET="$ROOT/bin/ap-startup-memory-budget.sh"
BOOTSTRAP="$ROOT/bin/ap-bootstrap.sh"
CONFIG_PUSH="$ROOT/bin/ap-config-push.sh"

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(ap_fakebin "$dir")
  ap_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi quota-axi
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'quota-axi 0.1.16 (fake)'
fi
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' '0.2.3' ;;
  update:--help) printf '%s\n' '--archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ -z "${AP_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$AP_FAKE_TMUX_LOG"
case "$*" in
  *display-message*'#{pane_current_command}'*) printf '%s\n' codex ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1' ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0 ;;
  *capture-pane*) printf '\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

new_bootstrap_world() {
  local name=$1 world root home
  world="$TMP_ROOT/$name"
  root="$world/root"
  home="$world/home"
  mkdir -p "$home/config" "$home/data" "$home/state" "$root/bin"
  git init -q -b main "$root"
  printf '%s\n' 'config/' > "$root/.gitignore"
  printf '%s\n' '# Autopilot test root' > "$root/AGENTS.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/bin/placeholder.sh"
  chmod +x "$root/bin/placeholder.sh"
  git -C "$root" add -A
  git -C "$root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm initial
  printf '%s|%s\n' "$root" "$home"
}

run_bootstrap() {
  local root=$1 home=$2 fakebin=$3
  PATH="$fakebin:$BASE_PATH" AP_BACKEND=tmux AP_HOME="$home" AP_ROOT_OVERRIDE="$root" \
    "$BOOTSTRAP"
}

test_primary_bootstrap_materializes_visible_default() {
  local rec root home fakebin out second
  rec=$(new_bootstrap_world materialize)
  root=${rec%%|*}
  home=${rec#*|}
  fakebin=$(make_fake_toolchain "$TMP_ROOT/materialize")

  out=$(run_bootstrap "$root" "$home" "$fakebin")
  [ -z "$out" ] || fail "default materialization should stay quiet, got: $out"
  [ "$(<"$home/config/startup-memory-budget")" = 7500 ] \
    || fail "bootstrap did not materialize the visible 7500 default"
  [ "$(AP_HOME="$home" "$BUDGET" read)" = 7500 ] \
    || fail "read command did not expose the generated default"

  printf '321\n' > "$home/config/startup-memory-budget"
  run_bootstrap "$root" "$home" "$fakebin" >/dev/null
  [ "$(<"$home/config/startup-memory-budget")" = 321 ] \
    || fail "bootstrap replaced a valid pilot-selected budget"

  second="$TMP_ROOT/materialize/copilot"
  mkdir -p "$second/config" "$second/data" "$second/state"
  printf '%s\n' copilot > "$second/.ap-copilot-home"
  run_bootstrap "$root" "$second" "$fakebin" >/dev/null
  [ ! -e "$second/config/startup-memory-budget" ] \
    || fail "copilot bootstrap created an independent budget instead of awaiting inheritance"
  pass "primary bootstrap materializes only the visible default and preserves valid pilot choices"
}

expect_rejected_read() {
  local home=$1 expected=$2 out rc
  set +e
  out=$(AP_HOME="$home" "$BUDGET" read 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe budget unexpectedly parsed: $expected"
  assert_contains "$out" "$expected" "unsafe budget rejection was not specific"
}

test_safe_parser_rejects_ambiguous_and_unsafe_values() {
  local home outside
  home="$TMP_ROOT/parser-home"
  mkdir -p "$home/config" "$home/data"
  printf '42\n' > "$home/config/startup-memory-budget"
  [ "$(AP_HOME="$home" "$BUDGET" read)" = 42 ] || fail "valid positive decimal budget was rejected"

  printf '0\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'
  printf '42\nextra\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'
  printf '+42\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'

  outside="$TMP_ROOT/parser-outside"
  printf '77\n' > "$outside"
  rm -f "$home/config/startup-memory-budget"
  ln -s "$outside" "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'file is symlinked'
  [ "$(<"$outside")" = 77 ] || fail "symlink rejection changed its external target"

  rm -f "$home/config/startup-memory-budget"
  ln "$outside" "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'file is hardlinked'
  [ "$(<"$outside")" = 77 ] || fail "hardlink rejection changed its external source"

  rm -f "$home/config/startup-memory-budget"
  rm -rf "$home/config"
  ln -s "$TMP_ROOT/parser-config-target" "$home/config"
  mkdir -p "$TMP_ROOT/parser-config-target"
  printf '88\n' > "$TMP_ROOT/parser-config-target/startup-memory-budget"
  expect_rejected_read "$home" 'config directory is symlinked'
  pass "budget parser accepts one exact positive value and rejects malformed or unsafe inputs"
}

test_budget_accounting_reports_all_three_files_and_safe_failure() {
  local home out rc outside
  home="$TMP_ROOT/accounting-home"
  mkdir -p "$home/config" "$home/data"
  printf '10\n' > "$home/config/startup-memory-budget"
  printf 'abc\n' > "$home/data/pilot.md"
  printf 'abcdef\n' > "$home/data/pilot-shared.md"

  out=$(AP_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate' \
    "report did not name the stable estimator"
  assert_contains "$out" 'file=data/pilot.md bytes=4 estimated_tokens=2 status=present' \
    "report did not account for pilot memory"
  assert_contains "$out" 'file=data/pilot-shared.md bytes=7 estimated_tokens=3 status=present' \
    "report did not account for shared memory"
  assert_contains "$out" 'file=data/learnings.md bytes=0 estimated_tokens=0 status=absent' \
    "report did not account for absent learnings"
  assert_contains "$out" 'total_estimated_tokens=5' "report total was not the sum of all three files"
  assert_contains "$out" 'budget_status=within-budget' "report did not classify the initial total"

  printf 'abcdefabcdefabcdefabcdef\n' > "$home/data/learnings.md"
  out=$(AP_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'budget_status=over-budget' "report did not surface an over-budget total"

  outside="$TMP_ROOT/accounting-outside"
  printf 'outside\n' > "$outside"
  rm -f "$home/data/pilot.md"
  ln -s "$outside" "$home/data/pilot.md"
  set +e
  out=$(AP_HOME="$home" "$BUDGET" report 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "unsafe memory input should fail the accounting command"
  assert_contains "$out" 'memory file is not an ordinary regular file' \
    "accounting failure did not identify the unsafe memory file"
  [ "$(<"$outside")" = outside ] || fail "accounting failure changed a symlink target"
  pass "budget accounting sums the three startup files and reports safe failures"
}

new_propagation_world() {
  local world=$1 root="$1/root" home="$1/home" copilot="$1/copilot" head
  mkdir -p "$home/config" "$home/data" "$home/state" "$root/bin"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  printf '%s\n' 'config/' > "$root/.gitignore"
  printf '%s\n' '# Autopilot test root' > "$root/AGENTS.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/bin/placeholder.sh"
  chmod +x "$root/bin/placeholder.sh"
  git -C "$root" add -A
  git -C "$root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm initial
  head=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$copilot" "$head"
  printf '%s\n' copilot > "$copilot/.ap-copilot-home"
  mkdir -p "$copilot/config" "$copilot/data" "$copilot/state" "$copilot/projects"
  {
    printf 'window=autopilot:ap-copilot\n'
    printf 'kind=copilot\n'
    printf 'harness=codex\n'
    printf 'home=%s\n' "$copilot"
  } > "$home/state/copilot.meta"
  printf '%s|%s|%s\n' "$root" "$home" "$copilot"
}

latest_reread_instruction() {
  local home=$1 state path latest=
  state=$(cd "$home/state" && pwd -P) || return 1
  for path in "$state"/.ap-inherited-config-reread.*; do
    case "$path" in *.pending) continue ;; esac
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    latest=$path
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

run_config_push() {
  local root=$1 home=$2 fakebin=$3 log=$4
  PATH="$fakebin:$BASE_PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$root" AP_SEND_SETTLE=0 \
    AP_FAKE_TMUX_LOG="$log" "$CONFIG_PUSH"
}

test_primary_budget_converges_with_exact_reread_and_safe_failures() {
  local world="$TMP_ROOT/propagation" rec root home copilot fakebin log out rc instruction expected outside
  mkdir -p "$world"
  rec=$(new_propagation_world "$world")
  root=${rec%%|*}
  rec=${rec#*|}
  home=${rec%%|*}
  copilot=${rec#*|}
  fakebin=$(make_fake_toolchain "$world")
  log="$world/tmux.log"

  printf '321\n' > "$home/config/startup-memory-budget"
  out=$(run_config_push "$root" "$home" "$fakebin" "$log")
  assert_contains "$out" 'startup-memory-budget: pushed' \
    "config push did not report the new budget as inherited"
  [ "$(<"$copilot/config/startup-memory-budget")" = 321 ] \
    || fail "copilot did not receive the primary budget bytes"
  instruction=$(latest_reread_instruction "$copilot") || fail "budget propagation did not publish a reread instruction"
  expected=$(printf '%s\n\n%s\n%s\n321\n%s' \
    'These inherited config files changed. Re-read and apply their exact contents at every future intake. They are defaults/rules and do not remove your judgment to choose differently when warranted.' \
    'config/startup-memory-budget' \
    '-----BEGIN config/startup-memory-budget-----' \
    '-----END config/startup-memory-budget-----')
  [ "$(<"$instruction")" = "$expected" ] \
    || fail "budget reread payload was not the exact destination bytes"
  assert_contains "$(<"$log")" "CONFIG_REREAD: $instruction" \
    "budget propagation did not send the pointer to its exact reread generation"

  outside="$world/unsafe-budget"
  printf '555\n' > "$outside"
  rm -f "$copilot/config/startup-memory-budget"
  ln "$outside" "$copilot/config/startup-memory-budget"
  set +e
  out=$(run_config_push "$root" "$home" "$fakebin" "$log" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unsafe inherited destination should stop propagation"
  assert_contains "$out" 'startup-memory-budget: error - unsafe or invalid destination: file is hardlinked' \
    "unsafe inherited destination did not produce a concrete propagation error"
  [ "$(<"$outside")" = 555 ] || fail "unsafe destination handling changed its hardlinked source"
  rm -f "$copilot/config/startup-memory-budget"
  run_config_push "$root" "$home" "$fakebin" "$log" >/dev/null
  [ "$(<"$copilot/config/startup-memory-budget")" = 321 ] \
    || fail "safe retry did not restore the converged primary budget"

  rm -f "$home/config/startup-memory-budget"
  out=$(run_config_push "$root" "$home" "$fakebin" "$log")
  assert_contains "$out" 'startup-memory-budget: pushed - mirrored primary absence' \
    "primary absence was not reported as a converging removal"
  [ ! -e "$copilot/config/startup-memory-budget" ] \
    || fail "primary absence did not remove the inherited budget"
  instruction=$(latest_reread_instruction "$copilot") || fail "budget absence did not publish a reread instruction"
  assert_contains "$(<"$instruction")" $'-----BEGIN config/startup-memory-budget-----\nABSENT\n-----END config/startup-memory-budget-----' \
    "budget absence reread did not use the explicit ABSENT payload"

  rm -f "$copilot/config/startup-memory-budget"
  printf '555\n' > "$outside"
  ln -s "$outside" "$home/config/startup-memory-budget"
  set +e
  out=$(run_config_push "$root" "$home" "$fakebin" "$log" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unsafe primary budget should stop propagation"
  assert_contains "$out" 'startup-memory-budget: error - unsafe or invalid primary source: file is symlinked' \
    "unsafe primary budget did not produce a concrete propagation error"
  [ ! -e "$copilot/config/startup-memory-budget" ] \
    || fail "unsafe primary budget changed the converged copilot copy"
  [ "$(<"$outside")" = 555 ] || fail "unsafe primary budget handling changed its symlink target"
  pass "budget propagation converges through config push with exact rereads, absence, and safe rejection"
}

test_primary_bootstrap_materializes_visible_default
test_safe_parser_rejects_ambiguous_and_unsafe_values
test_budget_accounting_reports_all_three_files_and_safe_failure
test_primary_budget_converges_with_exact_reread_and_safe_failures

echo '# all ap-startup-memory-budget tests passed'
