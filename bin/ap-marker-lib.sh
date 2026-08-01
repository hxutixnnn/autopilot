#!/usr/bin/env bash
# ap-marker-lib.sh - compatibility entry point for from-autopilot routing.
#
# bin/ap-operational-input.sh owns current operational-input construction,
# parsing, marker bytes, and the established from-autopilot compatibility
# carrier. Existing callers source this path so they do not need a flag-day
# migration. No side effects on source. set -u / set -e safe.

_AP_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/ap-operational-input.sh
. "$_AP_MARKER_LIB_DIR/ap-operational-input.sh"
unset _AP_MARKER_LIB_DIR
