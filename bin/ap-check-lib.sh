#!/usr/bin/env bash

AP_CUSTOM_CHECK_HASH=
AP_CUSTOM_CHECK_SNAPSHOT=

ap_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

ap_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  AP_CUSTOM_CHECK_HASH=
  ap_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(ap_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  ap_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = ap-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  AP_CUSTOM_CHECK_HASH=$hash
}

ap_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  ap_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(ap_pr_file_device "$state") || return 1
  ap_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(ap_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$AP_CUSTOM_CHECK_HASH" ]
}

ap_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  ap_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  ap_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(ap_pr_file_device "$state") || return 1
  ap_pr_private_file_valid "$check" 700 "$state_device" || return 1
  AP_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.ap-custom-check.XXXXXX") || return 1
  cp "$check" "$AP_CUSTOM_CHECK_SNAPSHOT" || { ap_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$AP_CUSTOM_CHECK_SNAPSHOT" || { ap_custom_check_snapshot_cleanup; return 1; }
  [ -f "$AP_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$AP_CUSTOM_CHECK_SNAPSHOT" ] \
    || { ap_custom_check_snapshot_cleanup; return 1; }
  [ "$(ap_pr_file_mode "$AP_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { ap_custom_check_snapshot_cleanup; return 1; }
  [ "$(ap_pr_file_device "$AP_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { ap_custom_check_snapshot_cleanup; return 1; }
  [ "$(ap_pr_file_link_count "$AP_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { ap_custom_check_snapshot_cleanup; return 1; }
  hash=$(ap_custom_check_sha256 "$AP_CUSTOM_CHECK_SNAPSHOT") \
    || { ap_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$AP_CUSTOM_CHECK_HASH" ] || { ap_custom_check_snapshot_cleanup; return 1; }
}

ap_custom_check_snapshot_cleanup() {
  [ -z "$AP_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$AP_CUSTOM_CHECK_SNAPSHOT"
  AP_CUSTOM_CHECK_SNAPSHOT=
}
