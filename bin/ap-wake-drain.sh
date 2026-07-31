#!/usr/bin/env bash
# Atomically drain durable watcher wake records, optionally annotate validated
# signal status keys after raw consumption commits, then assert liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/ap-wake-lib.sh
. "$SCRIPT_DIR/ap-wake-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (ap-peek/ap-send/...) happens to run.
# Reuse ap-guard.sh's existing graced, beacon-based alarm (AP_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/ap-guard.sh" || true
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    ap_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    ap_lock_release "$AP_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ap_lock_acquire_wait "$AP_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if [ ! -s "$AP_WAKE_QUEUE" ]; then
  : > "$AP_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(ap_current_pid)"
rm -f "$DRAIN_TMP"
mv "$AP_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$AP_WAKE_QUEUE" || exit 1

RAW_ROWS=$(ap_wake_print_deduped "$DRAIN_TMP") || exit "$?"
case "${AP_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
  0) ;;
  ''|*[!0-9]*) ;;
  *) sleep "$AP_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
esac
if [ -n "$RAW_ROWS" ]; then
  # Print-before-delete is the deliberate at-least-once no-loss boundary: a
  # crash in this micro-gap may replay a wake, and annotations stay outside it.
  printf '%s\n' "$RAW_ROWS" || exit "$?"
fi
rm -f "$DRAIN_TMP" || exit "$?"
DRAIN_TMP=
ap_lock_release "$AP_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false

# Raw output and queue deletion are authoritative. Everything below is
# best-effort and cannot restore, duplicate, hide, or fail the consumed rows.
(ap_wake_print_annotations "$RAW_ROWS") || true
assert_watcher_liveness
exit 0
