#!/usr/bin/env bash
# Behavioral tests for the relocation-safe Autopilot command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(ap_test_tmproot autopilot-command)
COMMAND="$ROOT/autopilot"

help=$($COMMAND --help) || fail "autopilot --help failed"
assert_contains "$help" "autopilot launch" "help omits launch syntax"
assert_contains "$help" "autopilot update" "help omits update syntax"

fixture="$TMP_ROOT/relocated/repo"
install_bin="$TMP_ROOT/installed/bin"
fakebin="$TMP_ROOT/fakebin"
log="$TMP_ROOT/command.log"
mkdir -p "$fixture/bin" "$install_bin" "$fakebin"
cp "$COMMAND" "$fixture/autopilot"
chmod +x "$fixture/autopilot"
cat > "$fixture/bin/ap-update.sh" <<'SH'
#!/usr/bin/env bash
printf 'update-root=%s\n' "${AP_ROOT_OVERRIDE:-missing}" >> "${AP_COMMAND_LOG:?}"
SH
cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
printf 'launch-cwd=%s\n' "$PWD" >> "${AP_COMMAND_LOG:?}"
printf 'launch-args=%s\n' "$*" >> "${AP_COMMAND_LOG:?}"
SH
chmod +x "$fixture/bin/ap-update.sh" "$fakebin/claude"
ln -s "$fixture/autopilot" "$install_bin/autopilot"
fixture=$(CDPATH='' cd -P -- "$fixture" && pwd)

AP_COMMAND_LOG="$log" PATH="$fakebin:$PATH" "$install_bin/autopilot" launch claude --model test-model \
  || fail "installed symlink could not launch a supported harness"
assert_contains "$(cat "$log")" "launch-cwd=$fixture" "launch did not resolve the relocated repository"
assert_contains "$(cat "$log")" "launch-args=--model test-model" "launch did not preserve harness arguments"

AP_COMMAND_LOG="$log" PATH="$fakebin:$PATH" "$install_bin/autopilot" update \
  || fail "installed symlink could not run guarded update"
assert_contains "$(cat "$log")" "update-root=$fixture" "update did not resolve the relocated repository"

set +e
AP_COMMAND_LOG="$log" PATH="$fakebin:$PATH" "$install_bin/autopilot" launch unsupported \
  >"$TMP_ROOT/unsupported.out" 2>"$TMP_ROOT/unsupported.err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unsupported harness returned $rc instead of 2"
assert_contains "$(cat "$TMP_ROOT/unsupported.err")" "unsupported harness" "unsupported harness refusal was unclear"

unsupported_command=update-autopilot
set +e
"$install_bin/autopilot" "$unsupported_command" >"$TMP_ROOT/unsupported-command.out" 2>"$TMP_ROOT/unsupported-command.err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unsupported command unexpectedly remained active"
assert_contains "$(cat "$TMP_ROOT/unsupported-command.err")" "unknown command" "unsupported command refusal was unclear"

pass "autopilot command help, relocation-safe launch/update, argument forwarding, and strict command refusal"
