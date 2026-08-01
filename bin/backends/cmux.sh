#!/usr/bin/env bash
# bin/backends/cmux.sh - the cmux session-provider adapter (EXPERIMENTAL).
#
# Design: data/cmux-backend-feasibility-c7/report.md (adapter design sketch,
# section 4) plus the live-app verification pass recorded in
# docs/cmux-backend.md (real cmux 0.64.17, macOS aarch64, 2026-07-03). cmux is
# a session provider ONLY, exactly like herdr/zellij: the worktree provider
# stays treehouse. Sourced only through bin/ap-backend.sh's ap_backend_source
# in normal operation; the unit tests source it directly.
#
# Container shape: cmux has no "session" layer to multiplex the way
# tmux/herdr/zellij do - there is just "the app" (one running GUI instance).
# ONE cmux workspace PER TASK (mirrors tmux's one-window-per-task / zellij's
# one-tab-per-task), with exactly one surface inside it. cmux has no session
# layer, so workspace titles are scoped by autopilot home and installation
# path inside this adapter.
#
# Target string shape: "<workspace_uuid>:<surface_uuid>" - both bare UUIDs
# with no embedded colon, so splitting on the FIRST colon is trivially
# correct (mirrors herdr's/zellij's target-string convention).
#
# GUI-first, macOS-only (docs/cmux-backend.md "Setup"): explicit selection or
# runtime auto-detection when autopilot itself is already running inside a
# cmux-spawned terminal (primary CMUX_WORKSPACE_ID marker, with documented
# macOS fallback signals for wrapper-stripped claude). Unlike Orca, cmux is a
# pure session provider (treehouse still owns the worktree) and Escape IS
# natively supported.
#
# Empirical findings from the live verification pass (docs/cmux-backend.md has
# the full evidence log) that shaped this adapter, several of which diverge
# from the original design sketch's speculation:
#
#   1. `send` (literal) does NOT auto-submit - confirmed, matches every other
#      backend's "literal-then-separate-Enter" contract.
#   2. Surface cwd is CREATION-TIME-FROZEN (zellij-shape), not live-tracking
#      (herdr-shape): `workspace list`'s `current_directory` field reflects a
#      `cd` run directly in the surface's own top-level shell, but stays
#      frozen at wherever that shell was when it launched a foreground
#      subshell (exactly what `treehouse get` does) - verified live: a nested
#      `bash -c 'cd /Users && exec bash'` left `current_directory` reporting
#      the PARENT shell's last cwd, never following into the subshell. Fixed
#      with zellij's own pwd-marker-probe workaround, reused verbatim in
#      spirit (ap_backend_cmux_current_path below).
#   3. `read-screen --lines N` has NO herdr-style small-N empty-result bug -
#      verified N=1..10 all return correctly-clamped, non-empty content. The
#      "fetch generous, trim locally" pattern is still used for consistency
#      and because the actual viewport height (not a bug - real behavior) can
#      still cap a single `read-screen` call below a caller's requested bound.
#      A DIFFERENT, unanticipated read-screen pitfall surfaced only once real
#      spawn-shaped call sequences were exercised (not caught by the original
#      Phase 1 pass, which happened to test against surfaces that already had
#      output): read-screen against a genuinely FRESH surface that has never
#      been written to yet fails outright with `internal_error: Failed to
#      read terminal text`, for every --lines value and no matter how long
#      you wait, until at least one `send` actually writes to it - after
#      which it becomes reliably readable forever. This ruled out read-screen
#      as ap_backend_cmux_target_ready's liveness probe (the design sketch's
#      original suggestion): the very first send on a freshly created task
#      would fail its own pre-flight readiness check. `list-panes` has no such
#      gap and is used instead (ap_backend_cmux_surface_exists), mirroring
#      zellij's own structural pane_exists check.
#   4. Closing a workspace's LAST surface is a THIRD shape, matching neither
#      herdr (auto-closes the workspace) nor zellij (leaves a ghost tab):
#      `close-surface` REFUSES outright with a typed error
#      (`invalid_state: Cannot close the last surface`), leaving both the
#      surface and the workspace untouched. `close-workspace` removes the
#      whole workspace (surface included) only when it is not the last
#      workspace in its window. `ap_backend_cmux_kill` handles the documented
#      last-in-window exception below, while still reclaiming every surface in
#      the task workspace.
#   5. Workspace ids do NOT survive an app relaunch - verified via source
#      (`Sources/Workspace.swift`'s only initializer unconditionally sets
#      `self.id = UUID()`, with no restored-id parameter, unlike surfaces'
#      `restoredSurfaceId ?? UUID()` path scoped to same-run object reuse).
#      No live app restart of the pilot's own content was performed to
#      confirm this; see docs/cmux-backend.md for the reasoning. Recovery
#      therefore uses scoped-title matching from the caller-facing ap-<id>
#      label, never a stored uuid, mirroring herdr's/zellij's own recovery
#      posture.
#   6. NO title uniqueness enforcement for workspaces OR surfaces/tabs -
#      verified live (two workspaces, and two surfaces in one workspace, all
#      created successfully sharing one title). The duplicate check below is
#      ours, mirroring every other adapter, and uses home-scoped titles so a
#      shared cmux app cannot cross-match another autopilot home's task.
#
#   Unanticipated finding, load-bearing for this adapter: the control socket
#   defaults to `socketControlMode=cmuxOnly`, which REJECTS any CLI process
#   not spawned inside cmux itself ("Access denied - only processes started
#   inside cmux can connect"). Since autopilot always drives cmux from an
#   external shell, `automation.socketControlMode` must be one of the three
#   externally-viable modes (docs/cmux-backend.md "Setup" owns the full
#   matrix, verified from cmux source): `automation` (RECOMMENDED - same-user
#   external clients, no shared secret), `password` (works, needs
#   config/cmux-socket-password or CMUX_SOCKET_PASSWORD supplied on every
#   invocation), or `allowAll` (works, but opens the socket to every local
#   user - not recommended). `off` and `cmuxOnly` can never work externally.
#   A configured password is harmless under non-password modes: cmux's own
#   CLI sends `auth` preemptively and tolerates the server's "Unknown
#   command 'auth'" reply (cli/cmux.swift, authenticateSocketClientIfNeeded).
#
# Requires: cmux (CLI, bundled inside cmux.app - not guaranteed to be on PATH;
# see ap_backend_cmux_bin), jq (JSON parsing). Bootstrap detects these through
# ap_backend_required_tools only when cmux is the resolved backend; this adapter
# also gates them again before spawning.

# AP_HOME fallback: every real caller already sets AP_HOME as a global before
# sourcing ap-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/zellij.sh's identical fallback.
AP_BACKEND_CMUX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-${AP_ROOT:-$AP_BACKEND_CMUX_ROOT}}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"

# shellcheck source=bin/ap-backend-hometag-lib.sh
. "$AP_BACKEND_CMUX_ROOT/bin/ap-backend-hometag-lib.sh"

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/ap-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/ap-composer-lib.sh
. "$AP_BACKEND_CMUX_ROOT/bin/ap-composer-lib.sh"

# Verified minimum: the version the live pass ran against (docs/cmux-backend.md).
AP_BACKEND_CMUX_MIN_MAJOR=0
AP_BACKEND_CMUX_MIN_MINOR=64

# ap_backend_cmux_bin: resolve the cmux CLI binary. cmux does not reliably
# land on PATH after a plain app install - it flights an OPTIONAL "install CLI"
# action (`Sources/App/CmuxCLIPathInstaller.swift`, symlinking
# /usr/local/bin/cmux -> the bundled binary) that a fresh install has not
# necessarily run. Prefer PATH (respects an operator's own setup, e.g. after
# running that install action), fall back to the well-known bundle path.
AP_BACKEND_CMUX_BUNDLE_BIN="${AP_BACKEND_CMUX_BUNDLE_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
ap_backend_cmux_bin() {
  if command -v cmux >/dev/null 2>&1; then
    printf 'cmux'
    return 0
  fi
  if [ -x "$AP_BACKEND_CMUX_BUNDLE_BIN" ]; then
    printf '%s' "$AP_BACKEND_CMUX_BUNDLE_BIN"
    return 0
  fi
  return 1
}

ap_backend_cmux_tool_check() {
  ap_backend_cmux_bin >/dev/null 2>&1 || { echo "error: backend=cmux selected but the 'cmux' CLI was not found on PATH or at $AP_BACKEND_CMUX_BUNDLE_BIN (https://cmux.com)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=cmux selected but 'jq' is not installed (required to parse cmux's JSON output)" >&2; return 1; }
  return 0
}

# ap_backend_cmux_password: the optional socket password from
# config/cmux-socket-password (first non-empty line), or empty. Read fresh
# from the effective config dir on every call, mirroring the rest of backend
# config resolution.
# Never overrides an operator's own ambient CMUX_SOCKET_PASSWORD when the file
# is absent - ap_backend_cmux_cli only exports this when it resolves non-empty.
ap_backend_cmux_password() {
  local config_dir="${AP_CONFIG_OVERRIDE:-$AP_HOME/config}" f line
  f="$config_dir/cmux-socket-password"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
  done < "$f"
}

# ap_backend_cmux_cli: run `cmux <args...>`, quieted (suppresses legacy-alias
# notices) and with the configured socket password exported only when one is
# actually configured, so an operator's own ambient CMUX_SOCKET_PASSWORD is
# never clobbered with an empty value.
ap_backend_cmux_cli() {  # <cmux-subcommand-and-args...>
  local bin pw
  bin=$(ap_backend_cmux_bin) || return 1
  pw=$(ap_backend_cmux_password)
  if [ -n "$pw" ]; then
    CMUX_QUIET=1 CMUX_SOCKET_PASSWORD="$pw" "$bin" "$@"
  else
    CMUX_QUIET=1 "$bin" "$@"
  fi
}

# ap_backend_cmux_version_check: refuse loudly on a missing/incompatible cmux
# client. `cmux version` needs no socket (verified: works even when the
# control socket is unreachable), so this is a pure client-version gate,
# separate from reachability/auth (ap_backend_cmux_ping_state below).
ap_backend_cmux_version_check() {
  ap_backend_cmux_tool_check || return 1
  local raw ver major rest minor
  raw=$(ap_backend_cmux_cli version 2>/dev/null) || { echo "error: 'cmux version' failed; is cmux installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | awk '{print $2}')
  case "$ver" in
    ''|*[!0-9.]*)
      echo "error: could not parse a cmux version from '$raw'; refusing to use an unverified cmux build" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -lt "$AP_BACKEND_CMUX_MIN_MAJOR" ] || { [ "$major" -eq "$AP_BACKEND_CMUX_MIN_MAJOR" ] && [ "$minor" -lt "$AP_BACKEND_CMUX_MIN_MINOR" ]; }; then
    echo "error: cmux $ver is older than the verified minimum $AP_BACKEND_CMUX_MIN_MAJOR.$AP_BACKEND_CMUX_MIN_MINOR; update cmux before using backend=cmux" >&2
    return 1
  fi
  return 0
}

# ap_backend_cmux_ping_state: classify socket reachability/auth from `cmux
# ping`'s own text, since a missing/rejected connection is a normal, expected
# outcome here (never treated as a scripting bug) - ok|denied|unauth|down|error.
# The three auth-shaped server replies (verified from cmux source,
# Sources/TerminalController.swift): "Authentication required" (password mode,
# no password presented), "Password mode is enabled but no socket password"
# (password mode, app side has no password configured), and "Invalid password"
# (password mode, wrong password presented) all classify as unauth - each is a
# password-configuration problem on one side or the other, never fixable by
# relaunching the app.
ap_backend_cmux_ping_state() {
  local out
  out=$(ap_backend_cmux_cli ping 2>&1)
  if [ "$out" = "PONG" ]; then
    printf 'ok'
    return 0
  fi
  case "$out" in
    *'only processes started inside cmux can connect'*) printf 'denied' ;;
    *'Password mode is enabled but no socket password'*|*'Authentication required'*|*'Invalid password'*) printf 'unauth' ;;
    *'Socket not found'*) printf 'down' ;;
    *) printf 'error' ;;
  esac
}

# ap_backend_cmux_refuse_denied / ap_backend_cmux_refuse_unauth: the two
# fail-fast auth refusals, factored so the pre-launch and post-launch checks
# cannot drift. Each names every externally-viable socket mode (automation
# RECOMMENDED, password, allowAll - docs/cmux-backend.md "Setup" owns the
# matrix) plus the config/backend opt-out for a caller who only landed on
# cmux via auto-detection.
ap_backend_cmux_refuse_denied() {
  echo "error: backend=cmux socket rejected the connection (automation.socketControlMode is cmuxOnly, the default, which never admits an external CLI like autopilot). In cmux Settings > Automation set Socket Control Mode to 'Automation mode' (recommended - same-user external clients, no password), or 'Password mode' plus config/cmux-socket-password/CMUX_SOCKET_PASSWORD, or 'Full open access' (NOT recommended - admits every local user) - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
}

ap_backend_cmux_refuse_unauth() {
  echo "error: backend=cmux socket requires a password (automation.socketControlMode=password) but none is configured for this caller, or the configured one was rejected. Set config/cmux-socket-password or export CMUX_SOCKET_PASSWORD to the password from cmux Settings > Automation, or switch Socket Control Mode to 'Automation mode' (recommended - no password needed) - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
}

# ap_backend_cmux_ensure_running: launch cmux (mirrors the CLI's own
# `connectClient`/`launchApp` `open -a cmux` fallback) only when the socket is
# simply not up yet (`down`); an auth failure (`denied`/`unauth`) is a
# configuration problem a relaunch cannot fix, so it fails fast with an
# actionable pointer to docs/cmux-backend.md instead of retry-looping. A
# launch that never becomes reachable also names the `off` mode (socket
# listener disabled entirely - no listener ever comes up, no matter how long
# the app has been running), since that is indistinguishable from a slow
# launch on the wire.
ap_backend_cmux_ensure_running() {
  local state i
  state=$(ap_backend_cmux_ping_state)
  case "$state" in
    ok) return 0 ;;
    denied)
      ap_backend_cmux_refuse_denied
      return 1
      ;;
    unauth)
      ap_backend_cmux_refuse_unauth
      return 1
      ;;
  esac
  open -a cmux >/dev/null 2>&1 || { echo "error: failed to launch cmux ('open -a cmux' failed)" >&2; return 1; }
  for i in $(seq 1 20); do
    state=$(ap_backend_cmux_ping_state)
    case "$state" in
      ok) return 0 ;;
      denied)
        ap_backend_cmux_refuse_denied
        return 1
        ;;
      unauth)
        ap_backend_cmux_refuse_unauth
        return 1
        ;;
    esac
    sleep 0.5
  done
  echo "error: cmux did not become reachable within 10s of launch. If the app is already running, its Socket Control Mode may be 'Off' (no control socket at all) - set it to 'Automation mode' (recommended) in Settings > Automation, see docs/cmux-backend.md 'Setup'." >&2
  return 1
}

# ap_backend_cmux_container_ensure: the full spawn-time container-ensure
# sequence (version gate, reachability/launch-if-needed). No per-home
# container to stand up - cmux has no session layer (unlike herdr/zellij),
# the app itself is the only container. Nothing to echo; callers proceed
# straight to ap_backend_cmux_create_task.
ap_backend_cmux_container_ensure() {
  ap_backend_cmux_version_check || return 1
  ap_backend_cmux_ensure_running || return 1
  return 0
}

# ap_backend_cmux_home_label: readable home prefix plus a short hash of the
# resolved AP_ROOT path. cmux has one app-global workspace namespace, so the
# path hash distinguishes every autopilot installation, including multiple
# primary homes. Moving an installation changes this tag and old cmux titles
# stop matching; task meta already records absolute worktree paths, so repo
# relocation is already outside the supported recovery contract. Derivation
# itself lives in bin/ap-backend-hometag-lib.sh, shared with zellij's
# identical shared-namespace collision fix (docs/zellij-backend.md
# "Home-scoped tab titles").
ap_backend_cmux_home_label() {
  ap_backend_hometag
}

ap_backend_cmux_scoped_title() {  # <ap-task-label>
  local label=$1 rest home
  home=$(ap_backend_cmux_home_label)
  case "$label" in
    ap-*) rest=${label#ap-} ;;
    *) rest=$label ;;
  esac
  printf 'ap-%s-%s' "$home" "$rest"
}

# ap_backend_cmux_workspace_id_for_label: the live workspace id whose title
# equals <label>, or empty. cmux enforces no title uniqueness (finding #6),
# so this adopts the FIRST match `jq` returns, mirroring herdr's/zellij's own
# duplicate-check posture.
ap_backend_cmux_workspace_id_for_label() {  # <label>
  local label=$1
  ap_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null \
    | jq -r --arg want "$label" '.workspaces[]? | select(.title == $want) | .id' 2>/dev/null | head -1
}

ap_backend_cmux_surface_id_for_workspace() {  # <workspace_id>
  local wsid=$1
  ap_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>/dev/null \
    | jq -r '.panes[0] // {} | .selected_surface_id // (.surface_ids[0] // empty)' 2>/dev/null
}

# ap_backend_cmux_create_task: create the task's workspace (one surface),
# refusing an existing live <label> (finding #6: cmux enforces no uniqueness
# itself). Resolves the fresh workspace's default surface via one list-panes
# call (finding: a freshly created workspace already has exactly one surface,
# so no separate new-surface call is needed). --focus false is passed for
# defense in depth though verified to already be the default (finding:
# workspace/surface/pane create all default focus to false) - no
# focus-restore dance is needed, unlike zellij. Echoes "<workspace_id>
# <surface_id>" on success.
ap_backend_cmux_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 title dup out wsid sfid
  title=$(ap_backend_cmux_scoped_title "$label")
  dup=$(ap_backend_cmux_workspace_id_for_label "$title")
  if [ -n "$dup" ]; then
    echo "error: cmux workspace '$title' already exists" >&2
    return 1
  fi
  out=$(ap_backend_cmux_cli new-workspace --name "$title" --cwd "$cwd" --focus false --id-format uuids 2>&1) || {
    echo "error: cmux new-workspace failed for '$title': $out" >&2
    return 1
  }
  wsid=$(ap_backend_cmux_workspace_id_for_label "$title")
  [ -n "$wsid" ] || { echo "error: could not resolve a cmux workspace id for '$title' after creation" >&2; return 1; }
  sfid=$(ap_backend_cmux_surface_id_for_workspace "$wsid")
  [ -n "$sfid" ] || { echo "error: could not resolve the default surface for cmux workspace '$title' ($wsid)" >&2; return 1; }
  printf '%s %s' "$wsid" "$sfid"
}

# ap_backend_cmux_parse_target: split "<workspace_uuid>:<surface_uuid>" on the
# FIRST colon (neither UUID contains a colon, so this is unambiguous). Sets
# AP_BACKEND_CMUX_WORKSPACE and AP_BACKEND_CMUX_SURFACE for the caller.
ap_backend_cmux_parse_target() {  # <target>
  local target=$1
  AP_BACKEND_CMUX_WORKSPACE=${target%%:*}
  AP_BACKEND_CMUX_SURFACE=${target#*:}
  [ -n "$AP_BACKEND_CMUX_WORKSPACE" ] && [ -n "$AP_BACKEND_CMUX_SURFACE" ] && [ "$AP_BACKEND_CMUX_SURFACE" != "$target" ]
}

# ap_backend_cmux_surface_exists: does <surface_id> currently appear as one of
# <workspace_id>'s surfaces, per list-panes? Structural existence check, never
# a content read.
#
# Verified real-cmux pitfall NOT anticipated by the design sketch: read-screen
# against a genuinely fresh surface that has never been written to yet fails
# with a typed `internal_error: Failed to read terminal text` - EVERY
# read-screen call fails this way (with or without --lines, any value,
# regardless of how long you wait) until at least one `send` has actually
# written to the surface, at which point it becomes reliably readable. This
# would make read-screen unusable as ap_backend_cmux_target_ready's liveness
# probe: the very first send_literal on a freshly created task's surface
# would fail its own readiness pre-check before ever getting to write
# anything. list-panes has no such gap (verified: correct, immediate output
# on a completely untouched fresh surface), so it is the liveness primitive
# instead - mirroring zellij's own pane_exists check
# (ap_backend_zellij_pane_exists) rather than the design sketch's original
# read-screen-based suggestion.
ap_backend_cmux_surface_exists() {  # <workspace_id> <surface_id>
  local wsid=$1 sfid=$2
  ap_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>/dev/null \
    | jq -e --arg s "$sfid" '[.panes[]? | select(.surface_ids // [] | index($s))] | length > 0' >/dev/null 2>&1
}

# ap_backend_cmux_target_ready: parse the target and verify it is live via
# ap_backend_cmux_surface_exists (never read-screen - see that function's
# header for the fresh-surface pitfall this avoids). When the caller knows
# the owning autopilot task label, refresh stale workspace/surface ids by label.
ap_backend_cmux_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} expected_title title wsid sfid
  ap_backend_cmux_parse_target "$1" || return 1
  if [ -n "$expected_label" ]; then
    expected_title=$(ap_backend_cmux_scoped_title "$expected_label")
    title=$(ap_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$AP_BACKEND_CMUX_WORKSPACE" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
    if [ "$title" = "$expected_title" ]; then
      ap_backend_cmux_surface_exists "$AP_BACKEND_CMUX_WORKSPACE" "$AP_BACKEND_CMUX_SURFACE" && return 0
      wsid=$AP_BACKEND_CMUX_WORKSPACE
    elif [ -n "$title" ]; then
      return 1
    else
      wsid=$(ap_backend_cmux_workspace_id_for_label "$expected_title")
      [ -n "$wsid" ] || return 1
    fi
    sfid=$(ap_backend_cmux_surface_id_for_workspace "$wsid")
    [ -n "$sfid" ] || return 1
    AP_BACKEND_CMUX_WORKSPACE=$wsid
    AP_BACKEND_CMUX_SURFACE=$sfid
    return 0
  fi
  ap_backend_cmux_surface_exists "$AP_BACKEND_CMUX_WORKSPACE" "$AP_BACKEND_CMUX_SURFACE"
}

# ap_backend_cmux_current_path: the live foreground process's cwd, or empty on
# any error. Mirrors ap_backend_zellij_current_path's active pwd-marker-probe
# workaround (bin/backends/zellij.sh:306-347) verbatim in spirit.
#
# Verified pitfall (finding #2 above): cmux's `current_directory` field DOES
# reflect a `cd` run directly in the surface's own top-level shell, but stays
# FROZEN at whatever directory that shell was in when it launched `treehouse
# get` as a foreground command - it never follows that command's own internal
# `cd` into the acquired worktree. cmux's control socket exposes no
# live-process cwd field either (unlike herdr's `foreground_cwd`), so passive
# polling cannot solve this here any more than it could for zellij. Active
# probe instead: print the surface's `$PWD` with a unique marker (atomically
# submitted via send_text_line), briefly settle, then capture and read only
# that marker line. Scoped to ap-spawn.sh's own worktree-discovery poll loop.
ap_backend_cmux_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} out line marker_begin="__AP_CMUX_CWD_BEGIN__" marker_end="__AP_CMUX_CWD_END__" in_block=0 chunk="" last=""
  ap_backend_cmux_target_ready "$target" "$expected_label" || return 0
  ap_backend_cmux_send_text_line "$target" "printf '%s\n' '$marker_begin'; pwd; printf '%s\n' '$marker_end'" "$expected_label" || return 0
  sleep 0.3
  out=$(ap_backend_cmux_capture "$target" 200 "$expected_label") || return 0
  while IFS= read -r line; do
    if [ "$line" = "$marker_begin" ]; then
      in_block=1
      chunk=""
      continue
    fi
    if [ "$line" = "$marker_end" ]; then
      case "$chunk" in /*) last=$chunk ;; esac
      in_block=0
      continue
    fi
    [ "$in_block" -eq 1 ] && chunk="$chunk$line"
  done <<EOF
$out
EOF
  printf '%s' "$last"
}

# ap_backend_cmux_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Verified live (finding #1): `send` does NOT
# auto-submit, matching every other backend's contract exactly.
ap_backend_cmux_send_literal() {  # <target> <text> [expected-label]
  ap_backend_cmux_target_ready "$1" "${3:-}" || return 1
  ap_backend_cmux_cli send --workspace "$AP_BACKEND_CMUX_WORKSPACE" --surface "$AP_BACKEND_CMUX_SURFACE" -- "$2" >/dev/null 2>&1
}

# ap_backend_cmux_normalize_key: map autopilot's key vocabulary (Enter,
# Escape, C-c) onto cmux's `send-key` names. Verified empirically: enter,
# escape, and ctrl-c all work directly (lowercase, hyphenated). cmux's own
# key vocabulary is genuinely richer (ctrl-d/ctrl-z/ctrl-\\, semantic aliases
# sigint/sigtstp/sigquit - `TerminalSurface+Input.swift`), but autopilot's
# shared vocabulary across backends only needs these three today.
ap_backend_cmux_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl-c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ap_backend_cmux_send_key: one named special key. Escape IS natively
# supported here (unlike Orca, docs/orca-backend.md), so it is wired directly.
ap_backend_cmux_send_key() {  # <target> <key> [expected-label]
  ap_backend_cmux_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(ap_backend_cmux_normalize_key "$2")
  ap_backend_cmux_cli send-key --workspace "$AP_BACKEND_CMUX_WORKSPACE" --surface "$AP_BACKEND_CMUX_SURFACE" "$key" >/dev/null 2>&1
}

# ap_backend_cmux_send_text_line: send one line of TEXT then submit. cmux has
# no single-call atomic "run and submit" primitive (like herdr's `pane run`),
# so this composes send (literal) + send-key enter, exactly like zellij's
# equivalent - used for the fixed spawn-time commands (treehouse get, the
# GOTMPDIR export).
ap_backend_cmux_send_text_line() {  # <target> <text> [expected-label]
  ap_backend_cmux_send_literal "$1" "$2" "${3:-}" || return 1
  ap_backend_cmux_send_key "$1" Enter "${3:-}"
}

# ap_backend_cmux_capture: bounded plain-text surface capture. No herdr-style
# small-N empty-result bug was found (finding #3), but "fetch generous, trim
# locally" is kept anyway: a single read-screen call is still bounded by the
# surface's actual current viewport height regardless of the requested
# --lines value, so a caller asking for more than the viewport can see would
# otherwise silently get less than it asked for with no way to tell why.
ap_backend_cmux_capture() {  # <target> <lines> [expected-label]
  ap_backend_cmux_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} fetch raw out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  raw=$(ap_backend_cmux_cli read-screen --workspace "$AP_BACKEND_CMUX_WORKSPACE" --surface "$AP_BACKEND_CMUX_SURFACE" --scrollback --lines "$fetch" --json 2>/dev/null) || return 1
  out=$(printf '%s' "$raw" | jq -r '.text // empty' 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# ap_backend_cmux_composer_state: classify the composer's own row as
# empty|pending|unknown. Adapted from the bordered-row branch of herdr's
# structural classifier (ap_backend_herdr_composer_state) per the build task's
# explicit direction - this is the highest-risk piece of a new backend's
# send-and-verify logic, and cmux's `read-screen` gives plain-text capture
# with no cursor-row primitive and no ANSI style channel like herdr's newer
# `pane read --format ansi` path. The cmux classifier intentionally remains
# border-row based: locate the
# composer row as the only captured line whose TRIMMED content both STARTS and
# ENDS with the same border glyph (│, ┃, or a plain ASCII |), scanning forward
# and keeping the LAST match so an earlier border-shaped line (scrollback, a
# popup) never outranks the real bottom-anchored composer row.
AP_BACKEND_CMUX_COMPOSER_LINES=${AP_BACKEND_CMUX_COMPOSER_LINES:-20}
AP_BACKEND_CMUX_IDLE_RE=${AP_BACKEND_CMUX_IDLE_RE:-'^Type a message\.\.\.$'}

ap_backend_cmux_composer_state() {  # <target> [expected-label] -> empty|pending|unknown
  local target=$1 expected_label=${2:-} cap line trimmed stripped="" found=0
  cap=$(ap_backend_cmux_capture "$target" "$AP_BACKEND_CMUX_COMPOSER_LINES" "$expected_label") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') : ;;
      *) continue ;;
    esac
    stripped=$trimmed
    found=1
  done < <(printf '%s\n' "$cap")
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A row was found only by the bordered shape above, so content came from a
  # genuine composer box - delegate to the shared owner with bordered=1. A bare
  # dead-shell prompt has no bordered row and already returned 'unknown' above.
  ap_composer_classify_content 1 "$stripped" "$AP_BACKEND_CMUX_IDLE_RE"
}

# ap_backend_cmux_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until the composer's own row reads empty.
# Mirrors ap_backend_herdr_send_text_submit's ORIGINAL (composer-row)
# verification strategy: a slash-command popup's first Enter can close the
# popup and fill an argument-hint placeholder into the composer rather than
# submitting, which a raw-diff check would misread as "submitted" -
# classifying the composer row specifically avoids that false positive, so
# the retry loop correctly sends a second Enter when needed. Herdr's adapter
# has since moved its own confirmation to a native agent-state read instead
# (docs/herdr-backend.md "Native agent-state submit confirmation"); cmux has
# no analogous native primitive, so this composer-row approach remains
# cmux's own confirmation strategy. Echoes empty|pending|unknown|send-failed, a
# subset of the proof-carrying submit vocabulary.
ap_backend_cmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} i=0 state
  ap_backend_cmux_parse_target "$target" || { printf 'unknown'; return 0; }
  ap_backend_cmux_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    ap_backend_cmux_send_key "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
    state=$(ap_backend_cmux_composer_state "$target" "$expected_label")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# ap_backend_cmux_window_of_workspace: echo "<window_id> <workspace_count>" for
# the window that contains <workspace_id>, or nothing if it is not found live.
# `workspace list --json` with no `--window` is scoped to the CURRENT window
# only (verified live), so the containing window is found by walking every
# window from `list-windows --json` and asking each for its own scoped list.
# The count comes from the same scoped workspace list that confirms membership.
ap_backend_cmux_window_of_workspace() {  # <workspace_id> -> "<window_id> <count>"
  local wsid=$1 wins wid wss count
  wins=$(ap_backend_cmux_cli list-windows --json --id-format uuids 2>/dev/null) || return 0
  while IFS= read -r wid; do
    [ -n "$wid" ] || continue
    wss=$(ap_backend_cmux_cli workspace list --json --id-format uuids --window "$wid" 2>/dev/null) || continue
    count=$(printf '%s' "$wss" | jq -er --arg id "$wsid" '
      (.workspaces // []) as $workspaces
      | select(any($workspaces[]?; .id == $id))
      | ($workspaces | length)
    ' 2>/dev/null) || continue
    printf '%s %s' "$wid" "$count"
    return 0
  done < <(printf '%s' "$wins" | jq -r '.[]? | .id' 2>/dev/null)
}

# ap_backend_cmux_kill: remove the task's whole workspace, best-effort (mirrors
# every other backend's `kill` `|| true` contract). A cmux task owns one
# workspace, so teardown reclaims that workspace and all of its surfaces.
#
# The selected-workspace teardown bug (docs/cmux-backend.md "Closing the last
# workspace in a window"): cmux keeps every window at >=1 workspace, so
# `close-workspace` on the ONLY workspace in its window silently no-ops - it
# still returns `OK`, but the workspace stays, which is exactly what left a
# selected task workspace open at teardown (the last workspace in a window is
# always the selected one). `close-window`/`window.close` cannot rescue it
# either: a window holding a live terminal session cannot be closed over the
# control socket (verified: returns success-shaped output, closes nothing).
# The reliable primitive is close-workspace on a NON-last workspace, so when the
# target is the last one in its window a throwaway sibling is created first,
# leaving that window a fresh default workspace (never an ap-<home>- title, so
# recovery/list_live ignore it) - cmux's own "closed the last tab" outcome.
ap_backend_cmux_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-} wsid wininfo win count
  if [ -n "$expected_label" ]; then
    ap_backend_cmux_target_ready "$1" "$expected_label" || return 0
  else
    ap_backend_cmux_parse_target "$1" || return 0
  fi
  wsid=$AP_BACKEND_CMUX_WORKSPACE
  wininfo=$(ap_backend_cmux_window_of_workspace "$wsid")
  win=${wininfo%% *}
  count=${wininfo##* }
  if [ -n "$win" ] && [ "$count" = 1 ]; then
    ap_backend_cmux_cli new-workspace --window "$win" --focus false --id-format uuids >/dev/null 2>&1 || true
  fi
  ap_backend_cmux_cli close-workspace --workspace "$wsid" >/dev/null 2>&1 || true
}

# ap_backend_cmux_list_live: recovery/orphan discovery. Lists every workspace
# whose title is scoped to this autopilot home, by TITLE - never by trusting a
# stored uuid, since workspace ids do NOT survive an app relaunch (finding #5).
# One "<workspace_id>:<surface_id>\t<ap-id>" line per live task workspace.
# Read-only: an unreachable cmux simply lists nothing.
ap_backend_cmux_list_live() {
  local wss wsid title sfid home prefix plain
  home=$(ap_backend_cmux_home_label)
  prefix="ap-$home-"
  wss=$(ap_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null) || return 0
  while IFS=$'\t' read -r wsid title; do
    [ -n "$wsid" ] || continue
    plain=${title#"$prefix"}
    [ -n "$plain" ] || continue
    sfid=$(ap_backend_cmux_surface_id_for_workspace "$wsid")
    [ -n "$sfid" ] || continue
    printf '%s:%s\tap-%s\n' "$wsid" "$sfid" "$plain"
  done < <(printf '%s' "$wss" | jq -r --arg prefix "$prefix" '.workspaces[]? | select(.title | startswith($prefix)) | "\(.id)\t\(.title)"' 2>/dev/null)
}
