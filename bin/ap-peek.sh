#!/usr/bin/env bash
# Print the tail of a flight crew member endpoint (bounded, for cheap diagnosis).
# Usage: ap-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy ap-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
STATE="${AP_STATE_OVERRIDE:-$AP_HOME/state}"

# shellcheck source=bin/ap-backend.sh
. "$SCRIPT_DIR/ap-backend.sh"

"$SCRIPT_DIR/ap-guard.sh" || true

RAW_TARGET=$1
T=$(ap_backend_resolve_selector "$RAW_TARGET" "$STATE")
N=${2:-40}

BACKEND=$(ap_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(ap_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

ap_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
