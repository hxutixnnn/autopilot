#!/usr/bin/env bash
# Read and account for the local startup-memory budget.
# Usage:
#   ap-startup-memory-budget.sh read
#   ap-startup-memory-budget.sh report
#
# `read` prints the one validated effective budget from
# config/startup-memory-budget.  `report` prints the stable local estimate for
# data/pilot.md, data/pilot-shared.md, and data/learnings.md together.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent, malformed, symlinked, hardlinked, or otherwise
# unsafe value is a concrete error rather than an inferred default.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
CONFIG="${AP_CONFIG_OVERRIDE:-$AP_HOME/config}"
DATA="${AP_DATA_OVERRIDE:-$AP_HOME/data}"

# shellcheck source=bin/ap-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/ap-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,11{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'startup-memory-budget: %s\n' "$1" >&2
}

read_budget() {
  if ! ap_startup_memory_budget_read "$CONFIG" >/dev/null; then
    print_error "invalid config/$AP_STARTUP_MEMORY_BUDGET_FILE - $AP_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$AP_STARTUP_MEMORY_BUDGET_VALUE"
}

report() {
  local budget bytes tokens presence total=0 shared_tokens=0 role=primary
  if ! budget=$(read_budget); then
    return 2
  fi

  if [ -e "$AP_HOME/.ap-copilot-home" ] || [ -L "$AP_HOME/.ap-copilot-home" ]; then
    role=copilot
  fi

  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'role=%s\n' "$role"
  printf 'effective_budget_tokens=%s\n' "$budget"
  for file in pilot.md pilot-shared.md learnings.md; do
    if ! ap_startup_memory_measure_file "$DATA/$file" >/dev/null; then
      print_error "$AP_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    bytes=$AP_STARTUP_MEMORY_MEASURE_BYTES
    tokens=$AP_STARTUP_MEMORY_MEASURE_TOKENS
    presence=$AP_STARTUP_MEMORY_MEASURE_PRESENCE
    total=$((total + tokens))
    [ "$file" != pilot-shared.md ] || shared_tokens=$tokens
    printf 'file=data/%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$file" "$bytes" "$tokens" "$presence"
  done
  printf 'total_estimated_tokens=%s\n' "$total"
  if ap_startup_memory_decimal_le "$total" "$budget"; then
    printf 'budget_status=within-budget\n'
  else
    printf 'budget_status=over-budget\n'
  fi
  if [ "$role" = copilot ] \
    && ! ap_startup_memory_decimal_le "$shared_tokens" "$budget"; then
    printf 'exception=primary-owned-shared-file-alone-exceeds-budget\n'
  fi
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
