#!/usr/bin/env bash
# Push declared inherited local material to live copilot homes.
# Usage: ap-config-push.sh [--help]
#
# Mid-session convergence for inherited local material such as
# config/flight-crew-dispatch.json, config/backend, or data/pilot-shared.md updates.
# This discovers live copilot homes from state/*.meta, backfills
# home= from data/copilots.md for older meta records, and reuses the same
# propagation machinery as bootstrap, but deliberately does not
# fast-forward tracked files.
# After a successful per-home propagation that changes any allowlisted config/*
# item, writes a generation-specific literal-content reread instruction and
# sends its pointer to that live copilot via ap-config-inherit-lib.sh
# (ap_config_send_reread_nudge).
# Unchanged config and data/pilot-shared.md-only updates send no reread
# message unless a previous send failure is pending for that home.
# Warnings-only skips exit 0; real propagation or reread-send errors exit non-zero.
set -u

usage() {
  cat <<'EOF'
Usage: ap-config-push.sh [--help]

Push the primary autopilot home's declared inherited local material into each
live copilot home.

This is local-material-only:
  - does not fast-forward tracked files
  - after successful config/* changes, writes a generation-specific
    literal-content reread instruction and sends its pointer to that live copilot
    (no message when config is unchanged unless a previous send failure is pending)
  - reports each live home and each inheritable item as pushed, unchanged,
    skipped, or error
  - exits non-zero for real propagation errors or reread-send failures

Live homes come from state/*.meta records with kind=copilot.
data/copilots.md is only a fallback for missing home= fields in older or
incomplete meta records.

Environment overrides follow the rest of autopilot:
  AP_HOME            active autopilot home
  AP_ROOT_OVERRIDE  autopilot repo root
  AP_STATE_OVERRIDE state dir
  AP_DATA_OVERRIDE  data dir
  AP_CONFIG_OVERRIDE config dir
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: ap-config-push.sh [--help]" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
CONFIG="${AP_CONFIG_OVERRIDE:-$AP_HOME/config}"
STATE="${AP_STATE_OVERRIDE:-$AP_HOME/state}"
DATA="${AP_DATA_OVERRIDE:-$AP_HOME/data}"
COPILOTS_MD="$DATA/copilots.md"

"$SCRIPT_DIR/ap-guard.sh" || true

# shellcheck source=bin/ap-ff-lib.sh
. "$SCRIPT_DIR/ap-ff-lib.sh"
# shellcheck source=bin/ap-wake-lib.sh
. "$SCRIPT_DIR/ap-wake-lib.sh"
# shellcheck source=bin/ap-config-inherit-lib.sh
. "$SCRIPT_DIR/ap-config-inherit-lib.sh"

print_item_report() {
  local report=$1 item status reason
  while IFS=$'\t' read -r item status reason; do
    [ -n "$item" ] || continue
    if [ -n "$reason" ]; then
      printf '  %s: %s - %s\n' "$item" "$status" "$reason"
    else
      printf '  %s: %s\n' "$item" "$status"
    fi
  done < "$report"
}

records=$(mktemp "${TMPDIR:-/tmp}/ap-config-push-records.XXXXXX" 2>/dev/null) || exit 1
reports=""
# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local report_file
  rm -f "$records"
  for report_file in $reports; do
    rm -f "$report_file"
  done
}
trap cleanup EXIT

live_copilot_meta_records "$STATE" "$COPILOTS_MD" > "$records"
if [ ! -s "$records" ]; then
  echo "config-push: no live copilot homes found"
  exit 0
fi

echo "config-push: $AP_HOME -> live copilot homes"

seen_homes=""
errors=0
while IFS='|' read -r id home _window meta; do
  [ -n "$id" ] || continue
  if [ -z "$home" ]; then
    printf 'copilot %s: skipped - no home= in %s and no registry home\n' "$id" "$meta"
    continue
  fi
  if ! validate_copilot_home "$id" "$home"; then
    printf 'copilot %s (%s): skipped - unsafe home: %s\n' "$id" "$home" "$VALIDATION_ERROR"
    continue
  fi
  home_real="$VALIDATED_HOME"
  case " $seen_homes " in
    *" $home_real "*)
      printf 'copilot %s (%s): skipped - already processed for another live meta\n' "$id" "$home_real"
      continue
      ;;
  esac
  seen_homes="$seen_homes $home_real"

  printf 'copilot %s (%s):\n' "$id" "$home_real"
  dirty=$(dirty_status "$home_real" yes || true)
  if [ -n "$dirty" ]; then
    echo "  home: dirty working tree - local-material push continuing"
  fi

  mkdir -p "$home_real/state" || {
    echo "  config-reread: error - could not create state directory"
    errors=1
    continue
  }
  home_lock=$(ap_config_inherit_lock_path "$home_real") || {
    echo "  config-reread: error - could not resolve per-home lock"
    errors=1
    continue
  }
  ap_lock_acquire_wait "$home_lock" || {
    echo "  config-reread: error - could not acquire per-home lock"
    errors=1
    continue
  }
  if ap_config_reread_retry_queue_is_full "$AP_HOME" "$id"; then
    ap_config_reread_retry_pending "$id" "$home_real" || true
    if ap_config_reread_retry_queue_is_full "$AP_HOME" "$id"; then
      echo "  config-reread: error - retry instruction queue is full"
      errors=1
      ap_lock_release "$home_lock" || true
      continue
    fi
  fi

  report=$(mktemp "${TMPDIR:-/tmp}/ap-config-push-report.XXXXXX" 2>/dev/null) || {
    echo "  home: error - could not create report file"
    errors=1
    ap_lock_release "$home_lock" || true
    continue
  }
  reports="$reports $report"
  if AP_CONFIG_INHERIT_REPORT="$report" propagate_copilot_inheritance "$AP_HOME" "$home_real" "$CONFIG" "$DATA"; then
    :
  else
    errors=1
  fi
  print_item_report "$report"
  reread_pending=0
  if ap_config_reread_has_pending "$home_real" || ap_config_reread_has_staged "$AP_HOME" "$id"; then
    reread_pending=1
  fi
  if reread_out=$(AP_HOME="$AP_HOME" AP_ROOT_OVERRIDE="$AP_ROOT" \
    AP_STATE_OVERRIDE="$STATE" \
    ap_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
    if [ -n "$(ap_config_reread_changed_items "$report")" ] || [ "$reread_pending" -eq 1 ]; then
      printf '  config-reread: sent\n'
    fi
    [ -z "$reread_out" ] || printf '%s\n' "$reread_out"
  else
    errors=1
    if [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    else
      printf '  config-reread: send failed\n'
    fi
  fi
  ap_lock_release "$home_lock" || true
done < "$records"

[ "$errors" -eq 0 ] || exit 1
exit 0
