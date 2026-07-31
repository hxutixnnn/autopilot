#!/usr/bin/env bash
# ap-send from-autopilot marker for copilot targets.
#
# A copilot is itself an autopilot, so a request relayed to it lands in its own
# chat - which the main autopilot never reads (the only channel back is the terse
# status file). ap-send therefore prepends a from-autopilot marker
# (bin/ap-marker-lib.sh) when, and only when, the resolved target is a task
# selector whose meta records kind=copilot, so the copilot can recognize
# the request and route its reply via the status path. These tests pin that
# behavior hermetically (stubbed tmux, no real agent):
#   1. Exact-id and stable-label kind=copilot selectors prepend the marker.
#   2. Exact-id and stable-label ordinary flight crew member selectors stay unmarked.
#   3. Explicit endpoints stay unmarked, with or without matching local meta.
#   4. The --key path never carries the marker.
#   5. Direct pilot text stays unmarked, and already-marked text is idempotent.
#   6. The marker is the label plus terminal-safe U+2063 INVISIBLE SEPARATOR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/ap-marker-lib.sh"

SEND="$ROOT/bin/ap-send.sh"

TMP_ROOT=$(ap_test_tmproot ap-send-marker)

# A fake tmux that (a) records the literal text of every `send-keys -l` to
# AP_SEND_LOG and (b) lets ap-send's submit path reach a clean "empty" verdict.
# display-message yields a numeric cursor_y; capture-pane returns an empty
# bordered composer so ap_tmux_composer_state reads "empty" (submit landed) on the
# first Enter. Only the literal (-l) text is logged; Enter retries and --key sends
# are not, so the log holds exactly what was typed into the composer.
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
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$AP_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
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

# run_send <fakebin> <home> <send-log> -- <ap-send args...>
# Runs ap-send.sh with the stubs on PATH against the given home (which holds
# state/<id>.meta). AP_ROOT_OVERRIDE points at the same non-repo home so
# ap-guard's tangle check stays silent; guard noise goes to stderr (discarded).
# AP_SEND_SETTLE=0 keeps the run fast. Truncates the log first; returns ap-send's
# exit code.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    AP_ROOT_OVERRIDE="$home" AP_HOME="$home" AP_SEND_LOG="$log" AP_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

# setup_home <name> -> echoes a fresh home dir with an empty state/.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_copilot_target_is_marked() {
  local dir fb log home rc got corr
  dir="$TMP_ROOT/copilot"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home copilot)
  ap_write_copilot_meta "$home/state/domain.meta" "$home" "sess:ap-domain"
  run_send "$fb" "$home" "$log" "ap-domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to a copilot target should succeed"
  got=$(cat "$log")
  case "$got" in
    "$AP_FROM_AUTOPILOT_MARK"corr=[a-f0-9][a-f0-9]*) : ;;
    *) fail "copilot send: literal text should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  case "$got" in
    *audit\ the\ build) : ;;
    *) fail "copilot send lost the request body"$'\n'"$got" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/ap-pending-reply-lib.sh"
  corr=$(ap_pending_reply_extract_corr "$got")
  [ -f "$(ap_pending_reply_path "$home/state" "$corr")" ] \
    || fail "marked copilot send should create a parent pending-reply record"
  pass "ap-send: a kind=copilot target gets the from-autopilot marker and corr prepended"
}

test_exact_copilot_task_id_is_marked() {
  local dir fb log home rc got already_marked corr
  dir="$TMP_ROOT/copilot-exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home copilot-exact)
  ap_write_copilot_meta "$home/state/domain.meta" "$home" "sess:ap-domain"
  run_send "$fb" "$home" "$log" "domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to an exact copilot task id should succeed"
  got=$(cat "$log")
  case "$got" in
    "$AP_FROM_AUTOPILOT_MARK"corr=[a-f0-9]*) : ;;
    *) fail "exact copilot send: literal text should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/ap-pending-reply-lib.sh"
  corr=$(ap_pending_reply_extract_corr "$got")
  # Resend with the same corr already present: embed is idempotent for that corr.
  already_marked="${AP_FROM_AUTOPILOT_MARK}corr=${corr} already routed"
  run_send "$fb" "$home" "$log" "domain" "$already_marked"; rc=$?
  expect_code 0 "$rc" "send of already-marked exact-id content should succeed"
  got=$(cat "$log")
  case "$got" in
    "${AP_FROM_AUTOPILOT_MARK}corr=${corr} already routed") : ;;
    *) fail "exact copilot send altered already-correlated content"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -tx1)" ;;
  esac
  pass "ap-send: an exact kind=copilot task id is marked with corr exactly once"
}

test_flight_crew_member_target_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/flight crew"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home flight crew)
  ap_write_meta "$home/state/build.meta" \
    "window=sess:ap-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=flight" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "ap-build" "fix the test"; rc=$?
  expect_code 0 "$rc" "send to a stable-label flight crew member target should succeed"
  got=$(cat "$log")
  [ "$got" = "fix the test" ] \
    || fail "stable-label flight crew member send: expected bare text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  run_send "$fb" "$home" "$log" "build" "fix the exact test"; rc=$?
  expect_code 0 "$rc" "send to an exact-id flight crew member target should succeed"
  got=$(cat "$log")
  [ "$got" = "fix the exact test" ] \
    || fail "exact-id flight crew member send: expected bare text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "ap-send: exact-id and stable-label kind=flight selectors are sent unmarked"
}

test_explicit_window_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home explicit)
  # An explicit endpoint is not a task selector, so even matching copilot
  # metadata must not make ap-send guess the caller's intent and mark it.
  ap_write_copilot_meta "$home/state/win.meta" "$home" "other:win"
  run_send "$fb" "$home" "$log" "other:win" "ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with matching meta should succeed"
  got=$(cat "$log")
  [ "$got" = "ping" ] \
    || fail "explicit session:window send with meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"

  home=$(setup_home explicit-no-meta)
  run_send "$fb" "$home" "$log" "outside:window" "outside ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with no local meta should succeed"
  got=$(cat "$log")
  [ "$got" = "outside ping" ] \
    || fail "explicit session:window send without meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "ap-send: explicit endpoints stay unmarked with or without local metadata"
}

test_key_path_is_not_marked() {
  local dir fb log home rc
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home key)
  ap_write_copilot_meta "$home/state/domain.meta" "$home" "sess:ap-domain"
  run_send "$fb" "$home" "$log" "ap-domain" --key Escape; rc=$?
  expect_code 0 "$rc" "--key send to a copilot should succeed"
  [ ! -s "$log" ] \
    || fail "--key path logged a literal send (marker leaked into a keypress)"$'\n'"--- bytes ---"$'\n'"$(od -An -c "$log")"
  pass "ap-send: the --key path carries no marker (no literal text is typed)"
}

test_marker_is_label_plus_invisible_separator() {
  local separator hex
  separator=$(printf '\342\201\243')
  [ "$AP_FROM_AUTOPILOT_MARK" = "[ap-from-autopilot]$separator" ] \
    || fail "marker is not the expected label + U+2063 sequence"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$AP_FROM_AUTOPILOT_MARK" | od -An -tx1)"
  hex=$(printf '%s' "$AP_FROM_AUTOPILOT_MARK" | od -An -tx1 | tr -d ' \n')
  case "$hex" in
    *e281a3) : ;;
    *) fail "marker does not end in UTF-8 U+2063 bytes e2 81 a3; bytes were: $hex" ;;
  esac
  ap_message_from_autopilot "${AP_FROM_AUTOPILOT_MARK}do the work" \
    || fail "detector should recognize a marked message"
  ap_message_from_autopilot "do the work" \
    && fail "direct pilot input must remain unmarked"
  ap_message_from_autopilot "[ap-from-autopilot]do the work" \
    && fail "detector must reject the label without U+2063"
  pass "ap-send: the marker is '[ap-from-autopilot]' + terminal-safe U+2063, while direct pilot text stays unmarked"
}

test_marker_transformation_is_idempotent() {
  local once twice
  ap_message_mark_from_autopilot "do the work" once
  ap_message_mark_from_autopilot "$once" twice
  [ "$once" = "$twice" ] \
    || fail "already-marked content was double-prefixed"$'\n'"--- once ---"$'\n'"$(printf '%s' "$once" | od -An -tx1)"$'\n'"--- twice ---"$'\n'"$(printf '%s' "$twice" | od -An -tx1)"
  [ "$once" = "${AP_FROM_AUTOPILOT_MARK}do the work" ] \
    || fail "marker transformation did not prefix bare content exactly once"
  pass "ap-marker: from-autopilot transformation is idempotent"
}

test_marked_send_preserves_trailing_newlines() {
  local dir fb log home rc payload got_hex body_hex corr
  dir="$TMP_ROOT/copilot-trailing-newlines"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home copilot-trailing-newlines)
  ap_write_copilot_meta "$home/state/domain.meta" "$home" "sess:ap-domain"
  payload=$'audit the build\n\n'
  run_send "$fb" "$home" "$log" "domain" "$payload"; rc=$?
  expect_code 0 "$rc" "marked send with trailing newlines should succeed"
  # shellcheck source=/dev/null
  . "$ROOT/bin/ap-pending-reply-lib.sh"
  corr=$(ap_pending_reply_extract_corr "$(cat "$log")")
  [ -n "$corr" ] || fail "marked send should embed a corr id"
  # Body after marker+corr+space must preserve the original trailing newlines.
  body_hex=$(printf '%s' "$payload" | od -An -tx1 | tr -d ' \n')
  got_hex=$(od -An -tx1 "$log" | tr -d ' \n')
  case "$got_hex" in
    *"$body_hex") : ;;
    *) fail "marked send lost trailing newline body bytes: got $got_hex expected to end with $body_hex" ;;
  esac
  pass "ap-send: marked copilot payload preserves trailing newline bytes"
}

test_copilot_target_is_marked
test_exact_copilot_task_id_is_marked
test_flight_crew_member_target_is_not_marked
test_explicit_window_is_not_marked
test_key_path_is_not_marked
test_marker_is_label_plus_invisible_separator
test_marker_transformation_is_idempotent
test_marked_send_preserves_trailing_newlines
