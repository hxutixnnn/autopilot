#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: ap-check-register.sh <id>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
STATE="${AP_STATE_OVERRIDE:-$AP_HOME/state}"

# shellcheck source=bin/ap-pr-lib.sh
. "$SCRIPT_DIR/ap-pr-lib.sh"
# shellcheck source=bin/ap-check-lib.sh
. "$SCRIPT_DIR/ap-check-lib.sh"

if [ "$#" -ne 1 ] || ! ap_pr_task_id_valid "$1"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi

ID=$1
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
STATE_DEVICE=$(ap_pr_file_device "$STATE") || exit 1
ap_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: custom check is unavailable" >&2; exit 1; }
ap_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
HASH=$(ap_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.ap-custom-check-trust.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
printf '%s\n%s\n' ap-custom-check-v1 "$HASH" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
ap_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
ap_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
