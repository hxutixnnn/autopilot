#!/usr/bin/env bash
# Self-update a running Autopilot and its copilots from hxutixnnn/autopilot.
#
# Mechanical half of the /updateautopilot skill. It validates every target's
# actual fetch source as the canonical Autopilot repository, never falls back
# to another remote, then fast-forwards the running repo and every registered
# copilot home (each a treehouse worktree of this same repo, or a standalone
# clone). FAST-FORWARD ONLY, exactly like
# ap-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a copilot's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Copilot homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/ap-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD copilot sync used by ap-spawn.sh and
# ap-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge copilots itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-autopilot: yes|no    (did the running autopilot's instructions change)
#   - nudge-copilots: ap-<id>...|none   (updated live copilots to nudge)
#
# Usage: ap-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_ROOT="${AP_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
AP_HOME="${AP_HOME:-${AP_ROOT_OVERRIDE:-$AP_ROOT}}"
STATE="${AP_STATE_OVERRIDE:-$AP_HOME/state}"
COPILOTS_MD="$AP_HOME/data/copilots.md"
# shellcheck source=bin/ap-ff-lib.sh
. "$SCRIPT_DIR/ap-ff-lib.sh"

"$SCRIPT_DIR/ap-guard.sh" || true

usage() { echo "usage: ap-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main autopilot repo ---------------------------------------------------

reread_autopilot="no"
ff_target "$AP_ROOT" "autopilot" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_autopilot="yes"
fi

# --- copilots -----------------------------------------------------------
# An updated live copilot is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updateautopilot's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=copilot carries the
# authoritative home= path.
sweep_live_copilot_metas "$STATE" origin no

# Registry backstop: a copilot registered in data/copilots.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$COPILOTS_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_copilot "$id" "$home" "" origin no
  done < "$COPILOTS_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-autopilot: $reread_autopilot"
echo "nudge-copilots:${FF_NUDGE_WINDOWS:- none}"
