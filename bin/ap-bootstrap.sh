#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: ap-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>",
#                 "FLIGHT_CREW_DISPATCH: invalid config/flight-crew-dispatch.json - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "TANGLE: <remediation>",
#                 "COPILOT_SYNC: copilot <id>: skipped: <reason>",
#                 "NUDGE_COPILOTS: copilot <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged ap-<id> with '<message>'",
#                 "COPILOT_LIVENESS: copilot <id>: skipped: <reason>|respawn failed after <cause>: <reason>",
#          When a RUNNING copilot worktree is fast-forwarded to autopilot's
#          own current default-branch commit (a purely LOCAL fast-forward, never
#          an origin fetch) AND its loaded instruction surface (AGENTS.md, bin/,
#          or .agents/skills/) actually changed, bootstrap immediately nudges it
#          via AP_HOME=<active-home> bin/ap-send.sh ap-<id> so meta resolves the
#          current backend target and the standard from-autopilot marker is
#          applied. A successful send prints one BOOTSTRAP_INFO line with the
#          exact target and message sent; a failed send leaves an idempotent
#          retry marker under state/.copilot-nudge-pending/ and prints an
#          actionable NUDGE_COPILOTS line.
#          Already-current or no-instruction-change homes are silently left alone.
#          The copilot sweep also propagates declared inherited local material
#          into each validated live copilot home.
#          COPILOT_SYNC lines report actionable skipped local-HEAD syncs or
#          inheritance failures for live copilot homes, plus quarantine
#          diagnostics for divergent shared pilot-preference copies;
#          no-op/current and successful updates stay quiet.
#          COPILOT_LIVENESS lines report only actionable failures from the
#          recovery-grade state owned by bin/ap-backend.sh's
#          ap_backend_agent_state: skipped distinguishes an existing ambiguous
#          process, an unreadable target, and an unverified backend; respawn
#          failed names whether the endpoint was missing or agent-less.
#          Already-live and successfully relaunched copilots are silent
#          unless AP_BOOTSTRAP_VERBOSE_FACTS=1 requests BOOTSTRAP_INFO facts.
#          A TANGLE line means the autopilot primary checkout (AP_ROOT) is stranded
#          on a feature branch instead of its default branch - a flight crew member's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). tasks-axi is also version and feature gated (0.1.1+
#          with update --archive-body and mv [<id>...]); an installed but
#          incompatible build reports MISSING like no-mistakes. A compatible
#          tasks-axi default backend is silent. quota-axi is required for the
#          agent-owned dispatch-profile array procedure in AGENTS.md section 4
#          and .agents/skills/quota-array-dispatch/SKILL.md, and is also version
#          gated by ap-quota-axi-lib.sh, which owns that floor and its rationale.
#          An older build reports MISSING like no-mistakes rather than passing
#          silently while emitting auth semantics dispatch cannot scope.
#          On a primary home, the locked mutable path materializes the visible
#          default config/startup-memory-budget=7500 when absent. It never
#          guesses at malformed or unsafe existing files, and copilot homes
#          await the primary-authoritative inherited value instead of creating
#          their own.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by AP_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed ap-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set AP_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          Set AP_BOOTSTRAP_DETECT_ONLY=1 to skip the four MUTATING sweeps
#          (PR-check migration, copilot_sync, copilot_liveness_sweep, and
#          fleet_sync) while still printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          ap-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          PR-check artifacts, copilot homes, project
#          clones, or repair instructions.
#          Unset/0 (the default) runs every sweep exactly as before - this flag
#          is purely additive.
#        ap-bootstrap.sh install <tool>...
#          Install the named tools (only ones the pilot approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
PROJECTS="${AP_PROJECTS_OVERRIDE:-$AP_HOME/projects}"
CONFIG="${AP_CONFIG_OVERRIDE:-$AP_HOME/config}"
STATE="${AP_STATE_OVERRIDE:-$AP_HOME/state}"
DATA="${AP_DATA_OVERRIDE:-$AP_HOME/data}"
# shellcheck source=bin/ap-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/ap-tasks-axi-lib.sh"
# shellcheck source=bin/ap-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/ap-quota-axi-lib.sh"
# shellcheck source=bin/ap-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/ap-tangle-lib.sh"
# shellcheck source=bin/ap-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/ap-ff-lib.sh"
# shellcheck source=bin/ap-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/ap-config-inherit-lib.sh"
# shellcheck source=bin/ap-startup-memory-budget-lib.sh disable=SC1091
. "$SCRIPT_DIR/ap-startup-memory-budget-lib.sh"
# shellcheck source=bin/ap-backend.sh disable=SC1091
. "$SCRIPT_DIR/ap-backend.sh"

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${AP_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$AP_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$AP_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$AP_ROOT/bin/ap-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/ap-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$AP_ROOT/bin/ap-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

copilot_sync() {
  # shellcheck source=bin/ap-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/ap-wake-lib.sh"
  # Local-HEAD copilot sync: fast-forward every LIVE copilot home
  # to the primary checkout's current default-branch commit. Purely LOCAL - no
  # fetch, no origin dependency: a linked-worktree home already holds the primary's
  # commit (ap-ff-lib.sh), while a standalone clone without it is skipped until
  # /updateautopilot refreshes it from origin. Startup sends reread nudges only
  # for RUNNING copilots whose instruction surface (AGENTS.md, bin/, or
  # .agents/skills/) actually changed, so a copilot already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Unlike
  # /updateautopilot, startup owns the live-convergence send itself because it is
  # a deterministic locked sweep and can report success as BOOTSTRAP_INFO while
  # preserving failed sends as NUDGE_COPILOTS retry markers.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$AP_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=copilot' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "COPILOT_SYNC: copilot $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  COPILOT_NUDGE_MESSAGE='autopilot was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
  COPILOT_NUDGE_PENDING_DIR="$STATE/.copilot-nudge-pending"

  copilot_nudge_marker_path() {
    case "$1" in
      *[!/A-Za-z0-9._-]*|""|*/*) return 1 ;;
    esac
    printf '%s/%s.pending' "$COPILOT_NUDGE_PENDING_DIR" "$1"
  }

  copilot_write_nudge_marker() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker tmp parent
    selector="ap-$id"
    marker=$(copilot_nudge_marker_path "$id") || return 1
    parent=${marker%/*}
    mkdir -p "$parent" || return 1
    tmp=$(mktemp "$parent/.nudge.XXXXXX" 2>/dev/null) || return 1
    {
      printf 'id=%s\n' "$id"
      printf 'selector=%s\n' "$selector"
      printf 'home=%s\n' "$home"
      printf 'commit=%s\n' "$commit"
      printf 'instructions=%s\n' "$instr"
      printf 'message=%s\n' "$COPILOT_NUDGE_MESSAGE"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
  }

  copilot_send_nudge() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker out
    selector="ap-$id"
    marker=$(copilot_nudge_marker_path "$id") || {
      echo "NUDGE_COPILOTS: copilot $id: send failed: unsafe id"
      return 0
    }
    if ! copilot_write_nudge_marker "$id" "$home" "$commit" "$instr"; then
      echo "NUDGE_COPILOTS: copilot $id: send failed: cannot record retry marker"
      return 0
    fi
    if out=$(AP_HOME="$AP_HOME" AP_ROOT_OVERRIDE="$AP_ROOT" AP_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/ap-send.sh" "$selector" "$COPILOT_NUDGE_MESSAGE" 2>&1); then
      rm -f "$marker"
      echo "BOOTSTRAP_INFO: nudged $selector with '$COPILOT_NUDGE_MESSAGE'"
    else
      echo "NUDGE_COPILOTS: copilot $id: send failed: $(first_line "$out")"
    fi
  }

  ap_ff_after_instruction_update() {
    local id=$1 home=$2 _window=$3 instr=$4
    copilot_send_nudge "$id" "$home" "$primary_head" "$instr"
  }

  copilot_retry_pending_nudges() {
    local marker id selector home commit message expected_marker meta meta_home home_real head
    [ -d "$COPILOT_NUDGE_PENDING_DIR" ] || return 0
    for marker in "$COPILOT_NUDGE_PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      id=$(ap_meta_get "$marker" id)
      if ! expected_marker=$(copilot_nudge_marker_path "$id"); then
        echo "NUDGE_COPILOTS: copilot ${id:-unknown}: send failed: retry marker has unsafe id"
        continue
      fi
      [ "$expected_marker" = "$marker" ] || {
        echo "NUDGE_COPILOTS: copilot $id: send failed: retry marker filename mismatch"
        continue
      }
      selector=$(ap_meta_get "$marker" selector)
      home=$(ap_meta_get "$marker" home)
      commit=$(ap_meta_get "$marker" commit)
      message=$(ap_meta_get "$marker" message)
      [ "$selector" = "ap-$id" ] || {
        echo "NUDGE_COPILOTS: copilot ${id:-unknown}: send failed: retry marker selector mismatch"
        continue
      }
      [ "$message" = "$COPILOT_NUDGE_MESSAGE" ] || {
        echo "NUDGE_COPILOTS: copilot ${id:-unknown}: send failed: retry marker message mismatch"
        continue
      }
      meta="$STATE/$id.meta"
      [ -f "$meta" ] && [ "$(ap_meta_get "$meta" kind)" = copilot ] || {
        echo "NUDGE_COPILOTS: copilot ${id:-unknown}: send failed: retry target has no live copilot metadata"
        continue
      }
      meta_home=$(ap_meta_get "$meta" home)
      [ -n "$meta_home" ] || meta_home=$(copilot_registry_field "$DATA/copilots.md" "$id" home || true)
      if ! validate_copilot_home "$id" "$meta_home"; then
        echo "NUDGE_COPILOTS: copilot $id: send failed: retry target home unsafe: $VALIDATION_ERROR"
        continue
      fi
      home_real="$VALIDATED_HOME"
      [ "$home_real" = "$home" ] || {
        echo "NUDGE_COPILOTS: copilot $id: send failed: retry target home changed"
        continue
      }
      head=$(git -C "$home_real" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || {
        echo "NUDGE_COPILOTS: copilot $id: send failed: retry target is not at recorded instruction commit"
        continue
      }
      if out=$(AP_HOME="$AP_HOME" AP_ROOT_OVERRIDE="$AP_ROOT" AP_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/ap-send.sh" "$selector" "$COPILOT_NUDGE_MESSAGE" 2>&1); then
        rm -f "$marker"
        echo "BOOTSTRAP_INFO: nudged $selector with '$COPILOT_NUDGE_MESSAGE'"
      else
        echo "NUDGE_COPILOTS: copilot $id: send failed: $(first_line "$out")"
      fi
    done
  }

  local tmp line
  copilot_retry_pending_nudges
  tmp=$(mktemp "${TMPDIR:-/tmp}/ap-copilot-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_copilot_metas "$STATE" "$primary_head" yes "$DATA/copilots.md" >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      copilot\ *': skipped:'*) echo "COPILOT_SYNC: $line" ;;
      BOOTSTRAP_INFO:\ *) echo "$line" ;;
      NUDGE_COPILOTS:\ *) echo "$line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  unset -f ap_ff_after_instruction_update
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into every VALIDATED live copilot home swept above.
  # FF_SEEN_HOMES is exactly that set, and ap-config-inherit-lib.sh owns the
  # declared config items plus data/pilot-shared.md.
  # After a successful push that changes allowlisted config/* for an already-
  # running home, send its literal-content reread instruction pointer so the
  # live agent does not keep applying stale defaults. Spawn/respawn already
  # re-reads at launch and needs no redundant nudge unless files changed after launch.
  local id home home_real home_lock propagated_homes report reread_out reread_skip_pending
  propagated_homes=""
  COPILOT_RESPAWNED_IDS=${COPILOT_RESPAWNED_IDS:-}
  while IFS='|' read -r id home _window _meta; do
    validate_copilot_home "$id" "$home" || continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    mkdir -p "$home_real/state" || {
      echo "CONFIG_REREAD: copilot $id: send failed: could not create state directory"
      continue
    }
    home_lock=$(ap_config_inherit_lock_path "$home_real") || {
      echo "CONFIG_REREAD: copilot $id: send failed: could not resolve per-home lock"
      continue
    }
    ap_lock_acquire_wait "$home_lock" || {
      echo "CONFIG_REREAD: copilot $id: send failed: could not acquire per-home lock"
      continue
    }
    reread_skip_pending=0
    case " $COPILOT_RESPAWNED_IDS " in
      *" $id "*) reread_skip_pending=1 ;;
    esac
    if [ "$reread_skip_pending" -eq 0 ] \
      && ap_config_reread_retry_queue_is_full "$AP_HOME" "$id"; then
      ap_config_reread_retry_pending "$id" "$home_real" || true
      if ap_config_reread_retry_queue_is_full "$AP_HOME" "$id"; then
        echo "CONFIG_REREAD: copilot $id: send failed: retry instruction queue is full"
        ap_lock_release "$home_lock" || true
        continue
      fi
    fi
    report=$(mktemp "${TMPDIR:-/tmp}/ap-bootstrap-inherit.XXXXXX" 2>/dev/null) || {
      echo "COPILOT_SYNC: copilot $id: skipped: inheritance failed"
      ap_lock_release "$home_lock" || true
      continue
    }
    if AP_CONFIG_INHERIT_REPORT="$report" \
      propagate_copilot_inheritance "$AP_HOME" "$home_real" "$CONFIG" "$DATA"; then
      :
    else
      echo "COPILOT_SYNC: copilot $id: skipped: inheritance failed"
    fi
    if ! reread_out=$(AP_HOME="$AP_HOME" AP_ROOT_OVERRIDE="$AP_ROOT" \
      AP_STATE_OVERRIDE="$STATE" \
      AP_CONFIG_REREAD_SKIP_PENDING="$reread_skip_pending" \
      ap_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
      if [ -n "$reread_out" ]; then
        printf '%s\n' "$reread_out"
      else
        echo "CONFIG_REREAD: copilot $id: send failed: unknown error"
      fi
    elif [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    fi
    rm -f "$report"
    ap_lock_release "$home_lock" || true
  done < <(live_copilot_meta_records "$STATE" "$DATA/copilots.md")
  return 0
}

copilot_liveness_sweep() {
  # Idempotent copilot liveness guarantee - SESSION START ONLY. The detailed
  # state machine and its only recovery-authorizing states are owned by
  # ap_backend_agent_state. A missing tmux pane is not enough: tmux must prove
  # the window or session absent. This preserves duplicate prevention for
  # existing ambiguous processes and every transiently unreadable target while
  # adding the missing-session path the original bare-shell and Herdr-husk sweep
  # lacked.
  # A meta with no window remains owned by copilot-provisioning recovery.
  # Copilot homes never contain kind=copilot meta, so this is naturally a
  # primary-only no-op there. Mid-session liveness remains explicitly out of
  # scope and requires a separate periodic signal.
  [ -d "$STATE" ] || return 0
  local meta id window harness backend target agent_state out cause
  COPILOT_RESPAWNED_IDS=""
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=copilot$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    window=$(ap_meta_get "$meta" window)
    [ -n "$window" ] || continue
    harness=$(ap_meta_get "$meta" harness)
    backend=$(ap_backend_of_meta "$meta")
    target=$(ap_backend_target_of_meta "$meta")
    [ -n "$target" ] || target="$window"
    agent_state=$(ap_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
    case "$harness" in
      claude|codex|opencode|pi|pi-signed|grok|kimi) ;;
      *)
        case "$agent_state" in dead|missing) agent_state=unverified-harness ;; esac
        ;;
    esac
    case "$agent_state" in
      alive)
        if [ "${AP_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
          echo "BOOTSTRAP_INFO: copilot $id already live (backend=$backend)"
        fi
        ;;
      dead|missing)
        if [ "$agent_state" = dead ]; then
          cause="confirmed agent absence on existing endpoint"
          ap_backend_kill "$backend" "$target" 2>/dev/null || true
        else
          cause="recorded endpoint confidently missing"
        fi
        if out=$(AP_SPAWN_NO_GUARD=1 "$AP_ROOT/bin/ap-spawn.sh" "$id" --copilot 2>&1); then
          COPILOT_RESPAWNED_IDS="$COPILOT_RESPAWNED_IDS $id"
          if [ "${AP_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
            echo "BOOTSTRAP_INFO: copilot $id relaunched after $cause (backend=$backend)"
          fi
        else
          echo "COPILOT_LIVENESS: copilot $id: respawn failed after $cause: $(first_line "$out")"
        fi
        ;;
      ambiguous)
        echo "COPILOT_LIVENESS: copilot $id: skipped: existing endpoint has ambiguous agent process (backend=$backend)"
        ;;
      unreadable)
        echo "COPILOT_LIVENESS: copilot $id: skipped: endpoint probe unreadable (backend=$backend)"
        ;;
      unverified-harness)
        echo "COPILOT_LIVENESS: copilot $id: skipped: recorded harness '$harness' is unverified for recovery (backend=$backend)"
        ;;
      *)
        echo "COPILOT_LIVENESS: copilot $id: skipped: agent recovery classifier unverified (backend=$backend)"
        ;;
    esac
  done
  return 0
}

install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# ap_backend_required_tools (bin/ap-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
BACKEND=$(ap_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(ap_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN=1.31.2

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# Shared semantic-version floor for the tool gates below. A version string that
# cannot be parsed into exactly one major.minor.patch triple is incompatible,
# never assumed current, so a development or vendored build cannot pass a floor
# it was never checked against.
tool_version_at_least() {  # <tool> <min-version>
  local tool=$1 min=$2 output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

flight_crew_dispatch_validate() {
  local file err
  file="$CONFIG/flight-crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "FLIGHT_CREW_DISPATCH: invalid config/flight-crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","pi-signed","grok","kimi"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "FLIGHT_CREW_DISPATCH: invalid config/flight-crew-dispatch.json - $err"
    return 0
  fi
  if [ "${AP_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: flight crew dispatch active config/flight-crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: flight crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: flight crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

startup_memory_budget_setup() {
  # Primary bootstrap owns default publication. A copilot is deliberately
  # passive here because its setting must converge from the primary through the
  # inherited-local-material contract rather than becoming a local authority.
  if [ -e "$AP_HOME/.ap-copilot-home" ] || [ -L "$AP_HOME/.ap-copilot-home" ]; then
    return 0
  fi
  if ! ap_startup_memory_budget_materialize "$CONFIG"; then
    echo "STARTUP_MEMORY_BUDGET: invalid config/$AP_STARTUP_MEMORY_BUDGET_FILE - $AP_STARTUP_MEMORY_BUDGET_ERROR"
  fi
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: ap-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. It pauses an
# identity-matched watcher, holds its lock, and neutralizes legacy PR checks
# before any tool detection or later bootstrap mutation can leave old artifacts
# runnable. Detect-only sessions never touch state.
if [ "${AP_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  "$SCRIPT_DIR/ap-pr-check-migrate.sh" || true
  startup_memory_budget_setup
fi

if [ "$BACKEND_VALID" -eq 0 ]; then
  echo "BACKEND_INVALID: $BACKEND (known: $AP_BACKEND_KNOWN)"
fi
for t in $BACKEND_TOOLS; do
  ap_backend_required_tool_available "$BACKEND" "$t" \
    || missing_tool_diagnostic "$t"
done
for t in $COMMON_TOOLS; do
  command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
done
# The treehouse lease-support upgrade check is only relevant when the resolved
# backend actually requires treehouse (every backend except orca, which owns its
# own worktrees); an orca home must not be told to upgrade a provider it never uses.
if ap_backend_list_contains "$TOOLS" treehouse \
  && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
  echo "MISSING: treehouse (install: $(install_cmd treehouse))"
fi
if command -v no-mistakes >/dev/null 2>&1 && ! tool_version_at_least no-mistakes "$NO_MISTAKES_MIN"; then
  echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
fi
if command -v quota-axi >/dev/null 2>&1 && ! ap_quota_axi_compatible; then
  echo "MISSING: quota-axi (install: $(install_cmd quota-axi))"
fi
if command -v tasks-axi >/dev/null 2>&1 && ! ap_tasks_axi_compatible; then
  echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
fi
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
# Worktree-tangle check: the autopilot primary checkout (AP_ROOT) must sit on its
# default branch, not a feature branch (see ap-tangle-lib.sh). Scoped to the
# primary only; detached-HEAD worktrees and copilot homes never trip it.
tangle_branch=$(ap_primary_tangle_branch "$AP_ROOT" 2>/dev/null || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(ap_default_branch "$AP_ROOT" 2>/dev/null || echo main)
  if [ "${AP_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
  else
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $AP_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
  fi
fi
flight_crew=
[ -f "$CONFIG/flight-crew-harness" ] && flight_crew=$(tr -d '[:space:]' < "$CONFIG/flight-crew-harness" || true)
if [ "${AP_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$flight_crew" ] && [ "$flight_crew" != "default" ]; then
  echo "BOOTSTRAP_INFO: flight crew harness override active: $flight_crew"
fi
flight_crew_dispatch_validate
if [ "${AP_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
  && ! ap_backlog_backend_manual "$CONFIG" && ap_tasks_axi_compatible; then
  echo "BOOTSTRAP_INFO: tasks-axi available"
fi
if [ "${AP_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  copilot_liveness_sweep
  copilot_sync
  fleet_sync
fi
exit 0
