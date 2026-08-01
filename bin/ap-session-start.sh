#!/usr/bin/env bash
# ap-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# ap-bootstrap.sh, then separately read data/projects.md, data/copilots.md,
# data/pilot.md, data/pilot-shared.md, data/learnings.md, then run
# ap-lock.sh, ap-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls ap-lock.sh, ap-bootstrap.sh,
# and ap-wake-drain.sh as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Those three scripts remain fully working
# standalone with unchanged default behavior - other flows (ap-bootstrap.sh
# install <tools> after consent, /updateautopilot, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its five mutating
# sweeps - is an opt-in AP_BOOTSTRAP_DETECT_ONLY=1 flag on ap-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's five MUTATING sweeps
#                       (legacy PR-check migration, copilot fast-forward,
#                       copilot liveness and fleet sync)
#                       also run only when locked.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked.
#   4. context digest - data/projects.md, data/copilots.md, data/pilot.md,
#                       data/pilot-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   5. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       every state/*.meta, a bounded state/*.status tail,
#                       state/.afk, and a cheap per-task endpoint-liveness read:
#                       read-only, always runs.
#   6. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - fast-forwarding
# copilot homes, fetching/fast-forwarding every
# project clone - before ever discovering another session already holds the
# lock. Two sessions racing those sweeps is exactly the hazard the lock
# exists to prevent, so locking first closes the hole outright: only the
# session that actually wins the lock ever touches shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in AP_BOOTSTRAP_DETECT_ONLY=1
# mode) for its read-only detect lines - missing tools, gh auth, the
# worktree-tangle check, the harness override, flight-crew-dispatch validation,
# tasks-axi and quota-axi tool checks, and tasks-axi availability - none of
# which mutate shared state and all of which are safe to compute without
# verified lock ownership.
# Only projection cleanup, the five bootstrap mutating sweeps, and the
# wake-queue drain are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: AP_SESSION_START_BACKLOG_LIMIT bounds the startup backlog
# listing, default 80 items.
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# Usage: ap-session-start.sh
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
STATE="${AP_STATE_OVERRIDE:-$AP_HOME/state}"
DATA="${AP_DATA_OVERRIDE:-$AP_HOME/data}"
CONFIG="${AP_CONFIG_OVERRIDE:-$AP_HOME/config}"
PRIMARY_HARNESS=$("$SCRIPT_DIR/ap-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/ap-backend.sh
. "$SCRIPT_DIR/ap-backend.sh"
# shellcheck source=bin/ap-tasks-axi-lib.sh
. "$SCRIPT_DIR/ap-tasks-axi-lib.sh"

STATUS_TAIL=${AP_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
BACKLOG_LIMIT=${AP_SESSION_START_BACKLOG_LIMIT:-80}
case "$BACKLOG_LIMIT" in ''|*[!0-9]*|0) BACKLOG_LIMIT=80 ;; esac

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (pilot.md absent = autopilot
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; max %s item(s); indented task bodies omitted)\n' "$reason" "$BACKLOG_LIMIT"
  awk -v max="$BACKLOG_LIMIT" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      if (state != "") print $0
      next
    }
    state != "" && /^[-*][[:space:]]+/ {
      total++
      if (shown < max) {
        print $0
        shown++
      }
      next
    }
    END {
      if (total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d of %d backlog item title line(s))\n", shown, total
        if (total > shown) {
          printf "(truncated %d item(s); increase AP_SESSION_START_BACKLOG_LIMIT for a larger startup listing)\n", total - shown
        }
      }
    }
  ' "$path"
}

print_backlog_tasks_axi_compact() {
  local path=$1 out rc
  printf 'compact backlog listing (tasks-axi; max %s item(s); task bodies omitted)\n' "$BACKLOG_LIMIT"
  out=$(tasks-axi list --file "$path" --limit "$BACKLOG_LIMIT" --fields blocked_by,hold_kind,hold_reason 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
  else
    printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
    printf '%s\n' "$out"
    print_backlog_manual_compact "$path" "fallback"
  fi
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if ap_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif ap_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1
  printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' "$STATUS_TAIL" "$status"
  tail -n "$STATUS_TAIL" "$status"
}

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

section "SESSION START - $AP_HOME"

# --- 1. lock -----------------------------------------------------------
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/ap-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: PR-check migration, stale Herdr child cleanup,\n'
    printf '●  copilot sync, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi

# --- 2. bootstrap --------------------------------------------------------
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(AP_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/ap-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/ap-herdr-session-cleanup.sh" 2>&1 || true
    "$SCRIPT_DIR/ap-bootstrap.sh" 2>&1
  )
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain -------------------------------------------------------
# Drained records are this turn's first work queue (AGENTS.md section 8); the
# drain also runs ap-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively draining it. It still runs
# ap-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(AP_GUARD_READ_ONLY=1 "$SCRIPT_DIR/ap-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  DRAIN_OUT=$("$SCRIPT_DIR/ap-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$AP_ROOT/.pi/extensions/ap-primary-pi-watch.ts"
  PI_TURNEND_EXT="$AP_ROOT/.pi/extensions/ap-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
"$SCRIPT_DIR/ap-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT"

# --- 4. context digest -----------------------------------------------------
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/copilots.md" "data/copilots.md"
print_file_or_absent "$DATA/pilot.md" "data/pilot.md"
print_file_or_absent "$DATA/pilot-shared.md" "data/pilot-shared.md (shared, main-authoritative, read-only in copilot homes)"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"

# --- 5. fleet-state digest ---------------------------------------------
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

subsection "Work under way (state/*.meta)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  window=$(ap_meta_get "$meta" window)
  target=$(ap_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(ap_backend_of_meta "$meta")
    if ap_backend_target_exists "$backend" "${target:-$window}" "ap-$id"; then
      printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window"
    else
      printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window"
    fi
  else
    printf 'endpoint: unknown (no window recorded)\n'
  fi

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
else
  printf 'absent\n'
fi

# --- 6. closing reminder -----------------------------------------------
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. Do NOT re-read
data/projects.md, data/copilots.md, data/pilot.md,
data/pilot-shared.md, data/learnings.md,
or state/*.meta now - they were just printed in full.
Do NOT bulk-read data/backlog.md now either: the compact identity/metadata
listing was just printed with a pointer for targeted full-body follow-up.
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed with full log paths for targeted follow-up when older wake-event
history is actually needed. Re-reading everything defeats the entire point
of this command. Re-read a file only if this digest flagged it ABSENT (then
rebuild or create it per AGENTS.md), its contents looked unparseable/corrupt,
or an individual full status log is needed for older wake-event history.
EOF

exit 0
