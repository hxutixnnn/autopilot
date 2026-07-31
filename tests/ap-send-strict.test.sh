#!/usr/bin/env bash
# ap-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing AP_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/ap-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/ap-send.sh"
TMP_ROOT=$(ap_test_tmproot ap-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$AP_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${AP_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$AP_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${AP_FAKE_TMUX_WINDOW:-ap-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  ap_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:ap-mpf-lane-m8" "kind=flight"

  PATH="$fb:$PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$home" AP_TMUX_LOG="$log" AP_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:ap-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:ap-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "ap-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_ap_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u AP_HOME PATH="$fb:$PATH" AP_ROOT_OVERRIDE="$dir" AP_TMUX_LOG="$log" AP_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset AP_HOME should fail"
  assert_contains "$(cat "$err")" "AP_HOME is not set" "unset AP_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset AP_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "ap-send strict: unset AP_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$home" AP_TMUX_LOG="$log" AP_FAKE_TMUX_WINDOW=lost-target AP_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "ap-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  ap_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=flight"

  PATH="$fb:$PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$home" AP_TMUX_LOG="$log" AP_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "ap-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$home" AP_TMUX_LOG="$log" AP_FAKE_TMUX_DEAD_TARGET=sess:missing AP_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "ap-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_healthy_ap_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  ap_write_meta "$home/state/lane-ok.meta" "window=sess:ap-lane-ok" "kind=flight" "harness=codex"

  PATH="$fb:$PATH" AP_HOME="$home" AP_ROOT_OVERRIDE="$home" AP_TMUX_LOG="$log" AP_SEND_SETTLE=0 \
    "$SEND" ap-lane-ok "hello pilot" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy ap-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:ap-lane-ok literal=1 arg=hello pilot" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:ap-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "ap-send guard banner should keep send-specific continuation wording"
  pass "ap-send strict: healthy ap-<id> sends still type once and submit"
}

test_exact_lane_id_send_still_works
test_unset_ap_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_healthy_ap_id_send_still_works
