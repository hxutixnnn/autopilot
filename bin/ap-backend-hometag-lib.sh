#!/usr/bin/env bash
# bin/ap-backend-hometag-lib.sh - shared per-installation home-tag derivation
# for session-provider backends whose container has ONE namespace shared by
# every autopilot home on the machine, with no native per-home split (cmux's
# one app-global workspace list, zellij's one shared "autopilot" session's
# tab bar). Without a per-home discriminator embedded in the actual
# title/name, two autopilot homes (two copilots, a primary plus a
# copilot, or two independent primary installations) whose task ids
# happen to collide can send/peek/close each other's tabs - the gap a
# pilot-directed no-mistakes review gate caught for cmux
# (docs/cmux-backend.md) and this same tag mechanism was later ported to
# zellij to close for the same reason (docs/zellij-backend.md "Home-scoped
# tab titles").
#
# ap_backend_hometag() derives a short, stable tag: a readable prefix
# ("autopilot" for the primary home, "copilot-<id>" for a copilot home
# carrying .ap-copilot-home) plus a short hash of the resolved AP_ROOT
# path, so distinct installations - including multiple primaries on one
# machine - never collide even though they share one backend-global
# namespace. Callers source this file AFTER resolving their own
# AP_HOME/AP_ROOT fallbacks (both adapters already do this for their own
# purposes before any other function runs).
#
# Moving/relocating an autopilot installation changes its AP_ROOT path and
# therefore its tag; titles created under the old tag simply stop matching -
# an accepted limitation, no worse than the existing fact that a task's
# recorded absolute worktree path does not survive a move either.

AP_BACKEND_HOMETAG_COPILOT_MARKER=".ap-copilot-home"

ap_backend_hometag() {
  local marker="$AP_HOME/$AP_BACKEND_HOMETAG_COPILOT_MARKER" id prefix root hash
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="copilot-$id"
    else
      prefix="autopilot"
    fi
  else
    prefix="autopilot"
  fi
  root=$(cd "$AP_ROOT" 2>/dev/null && pwd -P) || root=$AP_ROOT
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$root" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}
