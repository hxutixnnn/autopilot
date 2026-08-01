# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/ap-supervision-lib.sh
#
# Reports whether an autopilot home needs supervision because it has in-flight
# work (a state/<id>.meta exists), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/ap-guard.sh keeps its task-specific grace-based warning predicate;
# bin/ap-turnend-guard.sh uses the status fields here for its banner but performs
# its end-of-turn block decision with the live watcher lock check in
# bin/ap-wake-lib.sh.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
ap_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# ap_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   AP_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   AP_SUP_NEEDED         true/false - in-flight work
#   AP_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   AP_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   AP_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $AP_GUARD_GRACE, then 300, matching ap-guard.sh.
# Always returns 0; callers read the vars, or use ap_supervision_unhealthy below.
ap_supervision_status() {
  local state=$1 grace=${2:-${AP_GUARD_GRACE:-300}} meta beat m age
  AP_SUP_IN_FLIGHT=0
  AP_SUP_NEEDED=false
  AP_SUP_WATCHER_FRESH=false
  AP_SUP_BEACON_DESC=never
  AP_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    AP_SUP_IN_FLIGHT=$((AP_SUP_IN_FLIGHT + 1))
  done
  if [ "$AP_SUP_IN_FLIGHT" -gt 0 ]; then
    AP_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(ap_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      AP_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && AP_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (ap-guard.sh) after sourcing.
      AP_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (ap-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && AP_SUP_QUEUE_PENDING=true
  return 0
}

# ap_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when in-flight work needs a
# watcher. Exit 1 (false) for an idle home.
ap_supervision_needed() {
  ap_supervision_status "$@"
  [ "$AP_SUP_NEEDED" = true ]
}

# ap_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
ap_supervision_unhealthy() {
  ap_supervision_status "$@"
  [ "$AP_SUP_IN_FLIGHT" -gt 0 ] && [ "$AP_SUP_WATCHER_FRESH" = false ]
}
