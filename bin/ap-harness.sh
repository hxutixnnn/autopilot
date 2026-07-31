#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: ap-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|unknown
#        ap-harness.sh flight-crew      print the effective FLIGHT_CREW harness
#                                        (config/flight-crew-harness; "default" resolves to own)
#        ap-harness.sh copilot       print the harness the PRIMARY uses to launch
#                                        COPILOT agents: config/copilot-harness ->
#                                        config/flight-crew-harness -> own. "default" or absent
#                                        defers to the flight crew resolution, so an unset
#                                        copilot-harness behaves exactly as the flight crew
#                                        harness did before this knob existed.
#        ap-harness.sh copilot-model    print the optional MODEL token from
#                                        config/copilot-harness, or empty when absent.
#        ap-harness.sh copilot-effort   print the optional EFFORT token from
#                                        config/copilot-harness, or empty when absent.
# config/copilot-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/flight-crew-harness stays a bare adapter
# name and is never parsed for a model.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
CONFIG="${AP_CONFIG_OVERRIDE:-$AP_HOME/config}"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  # Keep marker detection before ancestry detection as an explicit precedence rule.
  # Only claude, pi, and grok set verified markers of their own; codex, opencode,
  # and kimi are markerless, so a foreign marker retained in a terminal
  # multiplexer's stored environment can silently misidentify one of them before
  # ancestry is consulted. This is a precedence hazard, not evidence that
  # CLAUDECODE inheritance into a kimi child was observed; it was not observed.
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${AP_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok sets GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so this marker
  # is unambiguous when autopilot runs natively on grok.
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "$(basename -- "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      *grok*) echo grok; return ;;
      kimi) echo kimi; return ;;
      pi-signed) echo pi; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *grok*) echo grok; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

# Resolve the effective flight crew member harness: config/flight-crew-harness (a bare adapter
# name) wins; absent or "default" mirrors autopilot's own harness.
resolve_flight_crew() {
  local flight_crew=
  [ -f "$CONFIG/flight-crew-harness" ] && flight_crew=$(tr -d '[:space:]' < "$CONFIG/flight-crew-harness" || true)
  if [ -z "$flight_crew" ] || [ "$flight_crew" = "default" ]; then detect_own; else echo "$flight_crew"; fi
}

# Print the first non-empty, non-comment line of config/copilot-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
copilot_line() {
  local line
  [ -f "$CONFIG/copilot-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/copilot-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved copilot_line, or nothing if the line or that field is absent.
copilot_field() {
  local idx=$1 line
  line=$(copilot_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch COPILOT agents: a fallback
# chain config/copilot-harness -> config/flight-crew-harness -> own. An absent or
# "default" copilot-harness token defers to the flight crew resolution, so an unset
# copilot-harness behaves exactly as before this knob existed (a copilot
# launched on the flight crew harness). config/copilot-harness is the PRIMARY's own
# setting and is never inherited downstream - copilots do not spawn copilots.
resolve_copilot() {
  local copilot
  copilot=$(copilot_field 1)
  if [ -z "$copilot" ] || [ "$copilot" = "default" ]; then resolve_flight_crew; else echo "$copilot"; fi
}

# Print the optional model token (2nd field) from config/copilot-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_copilot_model() {
  local copilot
  copilot=$(copilot_field 1)
  [ -n "$copilot" ] && [ "$copilot" != "default" ] || return 0
  copilot_field 2
}

# Print the optional effort token (3rd field) from config/copilot-harness,
# the same way.
resolve_copilot_effort() {
  local copilot
  copilot=$(copilot_field 1)
  [ -n "$copilot" ] && [ "$copilot" != "default" ] || return 0
  copilot_field 3
}

case "${1:-}" in
  flight-crew) resolve_flight_crew ;;
  copilot) resolve_copilot ;;
  copilot-model) resolve_copilot_model ;;
  copilot-effort) resolve_copilot_effort ;;
  *) detect_own ;;
esac
