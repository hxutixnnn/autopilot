#!/usr/bin/env bash
# ap-operational-input.sh - canonical Autopilot operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form:
#   U+2063 AUTOPILOT_OP: v1 <kind>: <body>
#
# The landed U+2063 + "AUTOPILOT_OP: " prefix is permanent compatibility.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-autopilot routing
# marker remains a current compatibility carrier because already-running
# copilots have its leading label in their charter context.
#
# CLI:
#   ap-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   ap-operational-input.sh kind           # current input on stdin, kind stdout
#   ap-operational-input.sh classify       # current or legacy input on stdin
#   ap-operational-input.sh body           # current generic input on stdin
#   ap-operational-input.sh --help
#
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

AP_OPERATIONAL_MARK=$'\xE2\x81\xA3'
AP_OPERATIONAL_PREFIX="${AP_OPERATIONAL_MARK}AUTOPILOT_OP: "
AP_OPERATIONAL_VERSION=v1
AP_OPERATIONAL_HEADER_PREFIX="${AP_OPERATIONAL_PREFIX}${AP_OPERATIONAL_VERSION} "
AP_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief'

# Compatibility name retained for the away-mode owner and its tests.
# shellcheck disable=SC2034 # Public source-library variable used by callers.
AP_INJECT_MARK=$AP_OPERATIONAL_MARK

# The from-autopilot carrier stays byte-compatible with live copilot charter
# context while this owner supplies its construction and structural kind.
AP_FROM_AUTOPILOT_LABEL='[ap-from-autopilot]'
AP_FROM_AUTOPILOT_SEPARATOR=$AP_OPERATIONAL_MARK
AP_FROM_AUTOPILOT_MARK="${AP_FROM_AUTOPILOT_LABEL}${AP_FROM_AUTOPILOT_SEPARATOR}"

ap_operational_kind_is_current() {  # <kind>
  case " $AP_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

ap_operational_input_encode() {  # <generic-kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  ap_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  printf -v "$result_var" '%s%s: %s' "$AP_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}

ap_operational_input_construct() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && [ -n "$body" ] || return 2
  if [ "$kind" = from-autopilot ]; then
    ap_message_mark_from_autopilot "$body" "$result_var"
    return
  fi
  ap_operational_input_encode "$kind" "$body" "$result_var"
}

ap_operational_generic_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} remainder parsed_kind body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$AP_OPERATIONAL_HEADER_PREFIX"*': '?*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$AP_OPERATIONAL_HEADER_PREFIX"}
  parsed_kind=${remainder%%': '*}
  ap_operational_kind_is_current "$parsed_kind" || return 1
  body=${remainder#"${parsed_kind}: "}
  [ "$body" != "$remainder" ] && [ -n "$body" ] || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

ap_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} current_kind
  [ -n "$result_var" ] || return 2
  if ap_operational_generic_kind "$message" current_kind; then
    printf -v "$result_var" '%s' "$current_kind"
    return 0
  fi
  case "$message" in
    "$AP_FROM_AUTOPILOT_MARK"?*)
      printf -v "$result_var" '%s' from-autopilot
      return 0
      ;;
  esac
  return 1
}

ap_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  if ap_operational_generic_kind "$message" current_kind; then
    parsed_body=${message#"${AP_OPERATIONAL_HEADER_PREFIX}${current_kind}: "}
    printf -v "$result_var" '%s' "$parsed_body"
    return 0
  fi
  case "$message" in
    "$AP_FROM_AUTOPILOT_MARK"?*)
      parsed_body=${message#"$AP_FROM_AUTOPILOT_MARK"}
      printf -v "$result_var" '%s' "$parsed_body"
      return 0
      ;;
  esac
  return 1
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup.
AP_LEGACY_SESSIONSTART='Run `bin/ap-session-start.sh` now, exactly once, before executing any other instructions.'
AP_LEGACY_WATCHER_PREFIX='AUTOPILOT WATCHER WAKE: '
AP_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/ap-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.'
AP_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n'
AP_LEGACY_AWAY_PREFIX="${AP_OPERATIONAL_MARK}Supervisor escalate ("

ap_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2

  # PR 899 landed an untyped AUTOPILOT_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$message" in
    "$AP_OPERATIONAL_PREFIX"?*)
      printf -v "$result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$message" = "$AP_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi
  case "$message" in
    "$AP_LEGACY_AWAY_PREFIX"*)
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
    "$AP_LEGACY_WATCHER_PREFIX"*"$AP_LEGACY_WATCHER_SUFFIX")
      [ "${#message}" -gt "$(( ${#AP_LEGACY_WATCHER_PREFIX} + ${#AP_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$AP_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

ap_operational_input_classify() {  # <message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if ap_operational_input_kind "$message" classified_kind ||
     ap_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

ap_message_from_autopilot() {  # <message>
  local kind
  ap_operational_input_kind "${1-}" kind && [ "$kind" = from-autopilot ]
}

ap_message_mark_from_autopilot() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if ap_message_from_autopilot "$message"; then
    transformed=$message
  else
    transformed="${AP_FROM_AUTOPILOT_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}

ap_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

ap_operational_usage() {
  cat <<'EOF'
Usage:
  bin/ap-operational-input.sh encode <kind>  # body on stdin
  bin/ap-operational-input.sh kind           # current input on stdin
  bin/ap-operational-input.sh classify       # current or legacy input on stdin
  bin/ap-operational-input.sh body           # current input on stdin

Current construction kinds:
  session-start watcher turn-end-guard away-supervisor from-autopilot launch-brief

The from-autopilot kind uses its established live-charter-compatible carrier.
EOF
}

ap_operational_main() {
  local command=${1-} argument=${2-} input output
  case "$command" in
    -h|--help|help)
      ap_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      ap_operational_read_stdin input || return 2
      ap_operational_input_construct "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      ap_operational_read_stdin input || return 2
      ap_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      ap_operational_read_stdin input || return 2
      ap_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      ap_operational_read_stdin input || return 2
      ap_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    *)
      ap_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ap_operational_main "$@"
  exit $?
fi
