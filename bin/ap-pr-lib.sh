#!/usr/bin/env bash
# Shared validation and atomic artifact helpers for merge polling on the
# supported forges. Callers must validate task IDs and raw PR/MR URLs before
# constructing task paths or performing any side effect.
#
# The stored identity is provider-tagged: provider, url, host, path, number.
# "path" is the full project path, which is owner/repository on GitHub and an
# arbitrarily nested group/subgroup/project namespace on GitLab. A GitLab
# project can sit at any depth, so no owner/repository pair can address one and
# the sidecar carries the whole path instead. GitLab also runs on self-hosted
# instances, so the host is part of that identity rather than a constant. Every
# consumer re-derives the identity from the stored URL and refuses any record
# whose parts do not reconstruct that exact URL.
#
# A validated exact merged result is retired through a private receipt only
# after its durable wake is appended.
# The receipt binds the terminal observation to the canonical registration and
# lets a restart finish fixed-path removal without executing state-file bytes.

AP_PR_PROVIDER=
AP_PR_URL=
AP_PR_HOST=
AP_PR_PATH=
AP_PR_OWNER=
AP_PR_REPO=
AP_PR_NUMBER=
AP_PR_DATA_PROVIDER=
AP_PR_DATA_URL=
AP_PR_DATA_HOST=
AP_PR_DATA_PATH=
AP_PR_DATA_NUMBER=
AP_PR_META_PROVIDER=
AP_PR_META_URL=
AP_PR_META_HOST=
AP_PR_META_PATH=
AP_PR_META_NUMBER=
AP_PR_REG_ID=
AP_PR_REG_PROVIDER=
AP_PR_REG_URL=
AP_PR_REG_HOST=
AP_PR_REG_PATH=
AP_PR_REG_NUMBER=
AP_PR_REG_DATA_HASH=
AP_PR_REG_TEMPLATE_HASH=
AP_PR_REG_DATA_IDENTITY=
AP_PR_REG_CHECK_IDENTITY=
AP_PR_POLL_DATA_TMP=
AP_PR_POLL_CHECK_TMP=
AP_PR_POLL_REG_TMP=
AP_PR_POLL_DATA_DEST=
AP_PR_POLL_CHECK_DEST=
AP_PR_POLL_REG_DEST=
AP_PR_POLL_EXPECT_ID=
AP_PR_POLL_EXPECT_PROVIDER=
AP_PR_POLL_EXPECT_URL=
AP_PR_POLL_EXPECT_HOST=
AP_PR_POLL_EXPECT_PATH=
AP_PR_POLL_EXPECT_NUMBER=
AP_PR_POLL_EXPECT_DATA_HASH=
AP_PR_POLL_EXPECT_TEMPLATE_HASH=
AP_PR_POLL_EXPECT_DATA_IDENTITY=
AP_PR_POLL_EXPECT_CHECK_IDENTITY=
AP_PR_POLL_TEMPLATE=
AP_PR_POLL_STATE_DEVICE=
AP_PR_POLL_SNAPSHOT_ID=
AP_PR_POLL_SNAPSHOT_PROVIDER=
AP_PR_POLL_SNAPSHOT_URL=
AP_PR_POLL_SNAPSHOT_HOST=
AP_PR_POLL_SNAPSHOT_PATH=
AP_PR_POLL_SNAPSHOT_NUMBER=
AP_PR_POLL_SNAPSHOT_DATA_HASH=
AP_PR_POLL_SNAPSHOT_TEMPLATE_HASH=
AP_PR_POLL_SNAPSHOT_DATA_IDENTITY=
AP_PR_POLL_SNAPSHOT_CHECK_IDENTITY=
AP_PR_POLL_SNAPSHOT_REG_HASH=
AP_PR_POLL_SNAPSHOT_REG_IDENTITY=
AP_PR_RETIRE_ID=
AP_PR_RETIRE_PROVIDER=
AP_PR_RETIRE_URL=
AP_PR_RETIRE_HOST=
AP_PR_RETIRE_PATH=
AP_PR_RETIRE_NUMBER=
AP_PR_RETIRE_DATA_HASH=
AP_PR_RETIRE_TEMPLATE_HASH=
AP_PR_RETIRE_DATA_IDENTITY=
AP_PR_RETIRE_CHECK_IDENTITY=
AP_PR_RETIRE_REG_HASH=
AP_PR_RETIRE_REG_IDENTITY=
AP_PR_RETIRE_RECEIPT_HASH=
AP_PR_RETIRE_RECEIPT_IDENTITY=
AP_PR_POLL_RETIREMENT_REJECTED=

ap_task_id_path_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

ap_pr_task_id_valid() {
  local id=${1-}
  ap_task_id_path_safe "$id"
}

ap_task_id_creation_valid() {
  local id=${1-}
  ap_pr_task_id_valid "$id" || return 1
  [ "${#id}" -le 64 ]
}

# GitLab serves self-hosted instances, so the host is part of the identity
# rather than a constant. It is accepted only as a lowercase DNS name with no
# userinfo, port, or trailing dot, which keeps one canonical spelling per MR.
# github.com is refused here even though its shape is otherwise valid: it is
# GitHub's own host and never a GitLab instance, so a URL like
# https://github.com/o/r/-/merge_requests/1 (a typo'd or spoofed GitHub URL)
# would otherwise be armed as a GitLab watch that can never succeed.
ap_pr_gitlab_host_valid() {
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  [ "$host" != github.com ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

# A GitLab project path is group[/subgroup...]/project, so at least two
# segments and no fixed depth. GitLab reserves "-" as its route separator and
# forbids a leading hyphen, ".git", and ".atom", so none of those can name a
# real namespace and each is refused here.
ap_pr_gitlab_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# Parse a canonical PR or MR URL into the provider-tagged identity. Validation
# is strict and per provider: the GitHub username and repository rules are
# unchanged, and GitLab gets its own host and namespace rules rather than a
# loosened GitHub rule.
#
# AP_PR_OWNER and AP_PR_REPO are additionally set for github because
# bin/ap-pr-merge.sh addresses GitHub by owner/repository. A gitlab URL leaves
# them empty; teaching the merge path about GitLab is a separate change, and
# until then it refuses a GitLab URL rather than merging anything.
ap_pr_url_parse() {
  local raw=${1-} pattern host path
  local LC_ALL=C
  AP_PR_PROVIDER=
  AP_PR_URL=
  AP_PR_HOST=
  AP_PR_PATH=
  AP_PR_OWNER=
  AP_PR_REPO=
  AP_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    AP_PR_PROVIDER=github
    AP_PR_URL=$raw
    AP_PR_HOST=github.com
    AP_PR_PATH="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    # Consumed by bin/ap-pr-merge.sh, which addresses GitHub by owner/repository.
    # shellcheck disable=SC2034
    AP_PR_OWNER=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034
    AP_PR_REPO=${BASH_REMATCH[2]}
    AP_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/merge_requests/". Any earlier separator therefore lands inside the
  # captured path, where the reserved "-" segment is refused.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  path=${BASH_REMATCH[2]}
  ap_pr_gitlab_host_valid "$host" || return 1
  ap_pr_gitlab_path_valid "$path" || return 1
  AP_PR_PROVIDER=gitlab
  AP_PR_URL=$raw
  AP_PR_HOST=$host
  AP_PR_PATH=$path
  AP_PR_NUMBER=${BASH_REMATCH[3]}
}

ap_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

ap_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

ap_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

ap_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

ap_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

ap_pr_file_identity() {
  local device inode
  device=$(ap_pr_file_device "$1") || return 1
  inode=$(ap_pr_file_inode "$1") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

ap_pr_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

ap_pr_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(ap_pr_file_mode "$path")" = "$mode" ] || return 1
  [ "$(ap_pr_file_device "$path")" = "$device" ] || return 1
  [ "$(ap_pr_file_link_count "$path")" = 1 ]
}

ap_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(ap_pr_file_link_count "$path")" = 1 ]
  fi
}

ap_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  ap_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(ap_pr_file_device "$path")" = "$device" ]
}

ap_pr_metadata_identity_parse() {
  local file=$1 line value pr_count=0 seen_pr=0 post_pr_invalid=0
  AP_PR_META_PROVIDER=
  AP_PR_META_URL=
  AP_PR_META_HOST=
  AP_PR_META_PATH=
  AP_PR_META_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(ap_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if ap_pr_url_parse "$value"; then
          AP_PR_META_PROVIDER=$AP_PR_PROVIDER
          AP_PR_META_URL=$AP_PR_URL
          AP_PR_META_HOST=$AP_PR_HOST
          AP_PR_META_PATH=$AP_PR_PATH
          AP_PR_META_NUMBER=$AP_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          ap_pr_head_valid "$value" || post_pr_invalid=1
        fi
        ;;
      x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*)
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$AP_PR_META_URL" ]
}

# Sidecar layout: provider, url, host, path, number, one per line. A sidecar
# written before the provider tag existed has a URL on its first line and one
# line fewer, so it fails both the field count and the provider comparison and
# is refused rather than misread as a provider-tagged record.
ap_pr_poll_data_parse() {
  local file=$1 provider url host path number
  AP_PR_DATA_PROVIDER=
  AP_PR_DATA_URL=
  AP_PR_DATA_HOST=
  AP_PR_DATA_PATH=
  AP_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  ap_pr_url_parse "$url" || return 1
  [ "$provider" = "$AP_PR_PROVIDER" ] || return 1
  [ "$host" = "$AP_PR_HOST" ] || return 1
  [ "$path" = "$AP_PR_PATH" ] || return 1
  [ "$number" = "$AP_PR_NUMBER" ] || return 1
  AP_PR_DATA_PROVIDER=$AP_PR_PROVIDER
  AP_PR_DATA_URL=$AP_PR_URL
  AP_PR_DATA_HOST=$AP_PR_HOST
  AP_PR_DATA_PATH=$AP_PR_PATH
  AP_PR_DATA_NUMBER=$AP_PR_NUMBER
}

# Registration layout: version tag, task id, then the same provider-tagged
# identity as the sidecar, then the two hashes and the two file identities.
# The version tag moved to v2 with the provider tag, so a registration written
# by the previous release is recognised as old and refused. The non-executing
# migration in bin/ap-pr-check-migrate.sh then rebuilds that poll from the
# task's recorded pull request URL.
ap_pr_poll_registration_parse() {
  local file=$1 version id provider url host path number data_hash template_hash data_identity check_identity
  AP_PR_REG_ID=
  AP_PR_REG_PROVIDER=
  AP_PR_REG_URL=
  AP_PR_REG_HOST=
  AP_PR_REG_PATH=
  AP_PR_REG_NUMBER=
  AP_PR_REG_DATA_HASH=
  AP_PR_REG_TEMPLATE_HASH=
  AP_PR_REG_DATA_IDENTITY=
  AP_PR_REG_CHECK_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r id <&7 || { exec 7<&-; return 1; }
  IFS= read -r provider <&7 || { exec 7<&-; return 1; }
  IFS= read -r url <&7 || { exec 7<&-; return 1; }
  IFS= read -r host <&7 || { exec 7<&-; return 1; }
  IFS= read -r path <&7 || { exec 7<&-; return 1; }
  IFS= read -r number <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r template_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_identity <&7 || { exec 7<&-; return 1; }
  IFS= read -r check_identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = ap-pr-poll-registration-v2 ] || return 1
  ap_pr_task_id_valid "$id" || return 1
  ap_pr_url_parse "$url" || return 1
  [ "$provider" = "$AP_PR_PROVIDER" ] || return 1
  [ "$host" = "$AP_PR_HOST" ] || return 1
  [ "$path" = "$AP_PR_PATH" ] || return 1
  [ "$number" = "$AP_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  AP_PR_REG_ID=$id
  AP_PR_REG_PROVIDER=$AP_PR_PROVIDER
  AP_PR_REG_URL=$AP_PR_URL
  AP_PR_REG_HOST=$AP_PR_HOST
  AP_PR_REG_PATH=$AP_PR_PATH
  AP_PR_REG_NUMBER=$AP_PR_NUMBER
  AP_PR_REG_DATA_HASH=$data_hash
  AP_PR_REG_TEMPLATE_HASH=$template_hash
  AP_PR_REG_DATA_IDENTITY=$data_identity
  AP_PR_REG_CHECK_IDENTITY=$check_identity
}

ap_pr_poll_cleanup() {
  [ -z "$AP_PR_POLL_DATA_TMP" ] || rm -f -- "$AP_PR_POLL_DATA_TMP"
  [ -z "$AP_PR_POLL_CHECK_TMP" ] || rm -f -- "$AP_PR_POLL_CHECK_TMP"
  [ -z "$AP_PR_POLL_REG_TMP" ] || rm -f -- "$AP_PR_POLL_REG_TMP"
  AP_PR_POLL_DATA_TMP=
  AP_PR_POLL_CHECK_TMP=
  AP_PR_POLL_REG_TMP=
}

ap_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume state
  # whose transactional registration did not commit successfully.
  if [ -e "$AP_PR_POLL_CHECK_DEST" ] || [ -L "$AP_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$AP_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$AP_PR_POLL_REG_DEST" ] || [ -L "$AP_PR_POLL_REG_DEST" ]; then
    rm -f -- "$AP_PR_POLL_REG_DEST" || failed=1
  fi
  if [ -e "$AP_PR_POLL_DATA_DEST" ] || [ -L "$AP_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$AP_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$AP_PR_POLL_CHECK_DEST" ] && [ ! -L "$AP_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$AP_PR_POLL_REG_DEST" ] && [ ! -L "$AP_PR_POLL_REG_DEST" ] || failed=1
  [ ! -e "$AP_PR_POLL_DATA_DEST" ] && [ ! -L "$AP_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

ap_pr_poll_prepare() {
  local state=$1 id=$2 provider=$3 url=$4 host=$5 path=$6 number=$7 template=$8
  ap_pr_task_id_valid "$id" || return 1
  ap_pr_url_parse "$url" || return 1
  [ "$provider" = "$AP_PR_PROVIDER" ] || return 1
  [ "$host" = "$AP_PR_HOST" ] || return 1
  [ "$path" = "$AP_PR_PATH" ] || return 1
  [ "$number" = "$AP_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  AP_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  AP_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  AP_PR_POLL_REG_DEST="$state/$id.pr-poll-registration"
  AP_PR_POLL_EXPECT_ID=$id
  AP_PR_POLL_EXPECT_PROVIDER=$provider
  AP_PR_POLL_EXPECT_URL=$url
  AP_PR_POLL_EXPECT_HOST=$host
  AP_PR_POLL_EXPECT_PATH=$path
  AP_PR_POLL_EXPECT_NUMBER=$number
  AP_PR_POLL_TEMPLATE=$template
  AP_PR_POLL_STATE_DEVICE=$(ap_pr_file_device "$state") || return 1
  [ -n "$AP_PR_POLL_STATE_DEVICE" ] || return 1
  AP_PR_POLL_DATA_TMP=$(mktemp "$state/.ap-pr-poll-data.XXXXXX") || return 1
  AP_PR_POLL_CHECK_TMP=$(mktemp "$state/.ap-pr-poll-check.XXXXXX") || {
    ap_pr_poll_cleanup
    return 1
  }
  AP_PR_POLL_REG_TMP=$(mktemp "$state/.ap-pr-poll-registration.XXXXXX") || {
    ap_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n%s\n' "$provider" "$url" "$host" "$path" "$number" > "$AP_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$AP_PR_POLL_DATA_TMP" \
    || ! ap_pr_private_file_valid "$AP_PR_POLL_DATA_TMP" 600 "$AP_PR_POLL_STATE_DEVICE" \
    || ! ap_pr_poll_data_parse "$AP_PR_POLL_DATA_TMP" \
    || [ "$AP_PR_DATA_PROVIDER" != "$provider" ] \
    || [ "$AP_PR_DATA_URL" != "$url" ] \
    || [ "$AP_PR_DATA_HOST" != "$host" ] \
    || [ "$AP_PR_DATA_PATH" != "$path" ] \
    || [ "$AP_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$AP_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$AP_PR_POLL_CHECK_TMP" \
    || ! ap_pr_private_file_valid "$AP_PR_POLL_CHECK_TMP" 600 "$AP_PR_POLL_STATE_DEVICE" \
    || ! cmp -s "$template" "$AP_PR_POLL_CHECK_TMP"; then
    ap_pr_poll_cleanup
    return 1
  fi
  AP_PR_POLL_EXPECT_DATA_HASH=$(ap_pr_sha256 "$AP_PR_POLL_DATA_TMP") || { ap_pr_poll_cleanup; return 1; }
  AP_PR_POLL_EXPECT_TEMPLATE_HASH=$(ap_pr_sha256 "$AP_PR_POLL_CHECK_TMP") || { ap_pr_poll_cleanup; return 1; }
  AP_PR_POLL_EXPECT_DATA_IDENTITY=$(ap_pr_file_identity "$AP_PR_POLL_DATA_TMP") || { ap_pr_poll_cleanup; return 1; }
  AP_PR_POLL_EXPECT_CHECK_IDENTITY=$(ap_pr_file_identity "$AP_PR_POLL_CHECK_TMP") || { ap_pr_poll_cleanup; return 1; }
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      ap-pr-poll-registration-v2 "$id" "$provider" "$url" "$host" "$path" "$number" \
      "$AP_PR_POLL_EXPECT_DATA_HASH" "$AP_PR_POLL_EXPECT_TEMPLATE_HASH" \
      "$AP_PR_POLL_EXPECT_DATA_IDENTITY" "$AP_PR_POLL_EXPECT_CHECK_IDENTITY" \
      > "$AP_PR_POLL_REG_TMP" \
    || ! chmod 0600 "$AP_PR_POLL_REG_TMP" \
    || ! ap_pr_private_file_valid "$AP_PR_POLL_REG_TMP" 600 "$AP_PR_POLL_STATE_DEVICE" \
    || ! ap_pr_poll_registration_parse "$AP_PR_POLL_REG_TMP" \
    || [ "$AP_PR_REG_ID" != "$id" ] \
    || [ "$AP_PR_REG_DATA_HASH" != "$AP_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$AP_PR_REG_TEMPLATE_HASH" != "$AP_PR_POLL_EXPECT_TEMPLATE_HASH" ]; then
    ap_pr_poll_cleanup
    return 1
  fi
}

ap_pr_poll_publish_prepared() {
  [ -n "$AP_PR_POLL_DATA_TMP" ] && [ -n "$AP_PR_POLL_CHECK_TMP" ] \
    && [ -n "$AP_PR_POLL_REG_TMP" ] || return 1
  ap_pr_regular_destination_on_device_or_absent "$AP_PR_POLL_DATA_DEST" "$AP_PR_POLL_STATE_DEVICE" || return 1
  ap_pr_regular_destination_on_device_or_absent "$AP_PR_POLL_REG_DEST" "$AP_PR_POLL_STATE_DEVICE" || return 1
  ap_pr_regular_destination_on_device_or_absent "$AP_PR_POLL_CHECK_DEST" "$AP_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$AP_PR_POLL_DATA_TMP" "$AP_PR_POLL_DATA_DEST"; then
    ap_pr_poll_revoke_final || true
    return 1
  fi
  AP_PR_POLL_DATA_TMP=
  if ! ap_pr_private_file_valid "$AP_PR_POLL_DATA_DEST" 600 "$AP_PR_POLL_STATE_DEVICE" \
    || [ "$(ap_pr_file_identity "$AP_PR_POLL_DATA_DEST")" != "$AP_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$(ap_pr_sha256 "$AP_PR_POLL_DATA_DEST")" != "$AP_PR_POLL_EXPECT_DATA_HASH" ] \
    || ! ap_pr_poll_data_parse "$AP_PR_POLL_DATA_DEST" \
    || [ "$AP_PR_DATA_PROVIDER" != "$AP_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$AP_PR_DATA_URL" != "$AP_PR_POLL_EXPECT_URL" ] \
    || [ "$AP_PR_DATA_HOST" != "$AP_PR_POLL_EXPECT_HOST" ] \
    || [ "$AP_PR_DATA_PATH" != "$AP_PR_POLL_EXPECT_PATH" ] \
    || [ "$AP_PR_DATA_NUMBER" != "$AP_PR_POLL_EXPECT_NUMBER" ]; then
    ap_pr_poll_revoke_final || true
    return 1
  fi

  if ! mv -f -- "$AP_PR_POLL_REG_TMP" "$AP_PR_POLL_REG_DEST"; then
    ap_pr_poll_revoke_final || true
    return 1
  fi
  AP_PR_POLL_REG_TMP=
  if ! ap_pr_private_file_valid "$AP_PR_POLL_REG_DEST" 600 "$AP_PR_POLL_STATE_DEVICE" \
    || ! ap_pr_poll_registration_parse "$AP_PR_POLL_REG_DEST" \
    || [ "$AP_PR_REG_ID" != "$AP_PR_POLL_EXPECT_ID" ] \
    || [ "$AP_PR_REG_PROVIDER" != "$AP_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$AP_PR_REG_URL" != "$AP_PR_POLL_EXPECT_URL" ] \
    || [ "$AP_PR_REG_HOST" != "$AP_PR_POLL_EXPECT_HOST" ] \
    || [ "$AP_PR_REG_PATH" != "$AP_PR_POLL_EXPECT_PATH" ] \
    || [ "$AP_PR_REG_NUMBER" != "$AP_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$AP_PR_REG_DATA_HASH" != "$AP_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$AP_PR_REG_TEMPLATE_HASH" != "$AP_PR_POLL_EXPECT_TEMPLATE_HASH" ] \
    || [ "$AP_PR_REG_DATA_IDENTITY" != "$AP_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$AP_PR_REG_CHECK_IDENTITY" != "$AP_PR_POLL_EXPECT_CHECK_IDENTITY" ]; then
    ap_pr_poll_revoke_final || true
    return 1
  fi

  if ! ap_pr_regular_destination_on_device_or_absent "$AP_PR_POLL_CHECK_DEST" "$AP_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$AP_PR_POLL_CHECK_TMP" "$AP_PR_POLL_CHECK_DEST"; then
    ap_pr_poll_revoke_final || true
    return 1
  fi
  AP_PR_POLL_CHECK_TMP=
  if ! ap_pr_poll_artifacts_valid "${AP_PR_POLL_CHECK_DEST%/*}" "$AP_PR_POLL_EXPECT_ID" "$AP_PR_POLL_TEMPLATE"; then
    ap_pr_poll_revoke_final || true
    return 1
  fi
}

ap_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash data_identity check_identity
  ap_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(ap_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  ap_pr_private_file_valid "$check" 600 "$state_device" || return 1
  ap_pr_private_file_valid "$data" 600 "$state_device" || return 1
  ap_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(ap_pr_file_link_count "$meta")" = 1 ] || return 1
  cmp -s "$template" "$check" || return 1
  ap_pr_poll_data_parse "$data" || return 1
  data_hash=$(ap_pr_sha256 "$data") || return 1
  template_hash=$(ap_pr_sha256 "$check") || return 1
  data_identity=$(ap_pr_file_identity "$data") || return 1
  check_identity=$(ap_pr_file_identity "$check") || return 1
  ap_pr_poll_registration_parse "$registration" || return 1
  [ "$AP_PR_REG_ID" = "$id" ] || return 1
  [ "$AP_PR_REG_PROVIDER" = "$AP_PR_DATA_PROVIDER" ] || return 1
  [ "$AP_PR_REG_URL" = "$AP_PR_DATA_URL" ] || return 1
  [ "$AP_PR_REG_HOST" = "$AP_PR_DATA_HOST" ] || return 1
  [ "$AP_PR_REG_PATH" = "$AP_PR_DATA_PATH" ] || return 1
  [ "$AP_PR_REG_NUMBER" = "$AP_PR_DATA_NUMBER" ] || return 1
  [ "$AP_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$AP_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  [ "$AP_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$AP_PR_REG_CHECK_IDENTITY" = "$check_identity" ] || return 1
  ap_pr_metadata_identity_parse "$meta" || return 1
  [ "$AP_PR_META_PROVIDER" = "$AP_PR_DATA_PROVIDER" ] || return 1
  [ "$AP_PR_META_URL" = "$AP_PR_DATA_URL" ] || return 1
  [ "$AP_PR_META_HOST" = "$AP_PR_DATA_HOST" ] || return 1
  [ "$AP_PR_META_PATH" = "$AP_PR_DATA_PATH" ] || return 1
  [ "$AP_PR_META_NUMBER" = "$AP_PR_DATA_NUMBER" ]
}

ap_pr_poll_snapshot_capture() {
  local state=$1 id=$2 template=$3 registration
  ap_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  AP_PR_POLL_SNAPSHOT_REG_HASH=$(ap_pr_sha256 "$registration") || return 1
  AP_PR_POLL_SNAPSHOT_REG_IDENTITY=$(ap_pr_file_identity "$registration") || return 1
  AP_PR_POLL_SNAPSHOT_ID=$id
  AP_PR_POLL_SNAPSHOT_PROVIDER=$AP_PR_DATA_PROVIDER
  AP_PR_POLL_SNAPSHOT_URL=$AP_PR_DATA_URL
  AP_PR_POLL_SNAPSHOT_HOST=$AP_PR_DATA_HOST
  AP_PR_POLL_SNAPSHOT_PATH=$AP_PR_DATA_PATH
  AP_PR_POLL_SNAPSHOT_NUMBER=$AP_PR_DATA_NUMBER
  AP_PR_POLL_SNAPSHOT_DATA_HASH=$AP_PR_REG_DATA_HASH
  AP_PR_POLL_SNAPSHOT_TEMPLATE_HASH=$AP_PR_REG_TEMPLATE_HASH
  AP_PR_POLL_SNAPSHOT_DATA_IDENTITY=$AP_PR_REG_DATA_IDENTITY
  AP_PR_POLL_SNAPSHOT_CHECK_IDENTITY=$AP_PR_REG_CHECK_IDENTITY
}

ap_pr_poll_snapshot_matches() {
  local state=$1 id=$2 template=$3 registration reg_hash reg_identity
  [ -n "$AP_PR_POLL_SNAPSHOT_ID" ] && [ "$id" = "$AP_PR_POLL_SNAPSHOT_ID" ] || return 1
  ap_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  reg_hash=$(ap_pr_sha256 "$registration") || return 1
  reg_identity=$(ap_pr_file_identity "$registration") || return 1
  [ "$AP_PR_DATA_PROVIDER" = "$AP_PR_POLL_SNAPSHOT_PROVIDER" ] || return 1
  [ "$AP_PR_DATA_URL" = "$AP_PR_POLL_SNAPSHOT_URL" ] || return 1
  [ "$AP_PR_DATA_HOST" = "$AP_PR_POLL_SNAPSHOT_HOST" ] || return 1
  [ "$AP_PR_DATA_PATH" = "$AP_PR_POLL_SNAPSHOT_PATH" ] || return 1
  [ "$AP_PR_DATA_NUMBER" = "$AP_PR_POLL_SNAPSHOT_NUMBER" ] || return 1
  [ "$AP_PR_REG_DATA_HASH" = "$AP_PR_POLL_SNAPSHOT_DATA_HASH" ] || return 1
  [ "$AP_PR_REG_TEMPLATE_HASH" = "$AP_PR_POLL_SNAPSHOT_TEMPLATE_HASH" ] || return 1
  [ "$AP_PR_REG_DATA_IDENTITY" = "$AP_PR_POLL_SNAPSHOT_DATA_IDENTITY" ] || return 1
  [ "$AP_PR_REG_CHECK_IDENTITY" = "$AP_PR_POLL_SNAPSHOT_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$AP_PR_POLL_SNAPSHOT_REG_HASH" ] || return 1
  [ "$reg_identity" = "$AP_PR_POLL_SNAPSHOT_REG_IDENTITY" ]
}

ap_pr_poll_retirement_parse() {
  local file=$1 version id provider url host path number data_hash template_hash
  local data_identity check_identity reg_hash reg_identity result _extra
  AP_PR_RETIRE_ID=
  AP_PR_RETIRE_PROVIDER=
  AP_PR_RETIRE_URL=
  AP_PR_RETIRE_HOST=
  AP_PR_RETIRE_PATH=
  AP_PR_RETIRE_NUMBER=
  AP_PR_RETIRE_DATA_HASH=
  AP_PR_RETIRE_TEMPLATE_HASH=
  AP_PR_RETIRE_DATA_IDENTITY=
  AP_PR_RETIRE_CHECK_IDENTITY=
  AP_PR_RETIRE_REG_HASH=
  AP_PR_RETIRE_REG_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 9< "$file" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r id <&9 || { exec 9<&-; return 1; }
  IFS= read -r provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r host <&9 || { exec 9<&-; return 1; }
  IFS= read -r path <&9 || { exec 9<&-; return 1; }
  IFS= read -r number <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r template_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r result <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = ap-pr-poll-retirement-v1 ] || return 1
  ap_pr_task_id_valid "$id" || return 1
  ap_pr_url_parse "$url" || return 1
  [ "$provider" = "$AP_PR_PROVIDER" ] || return 1
  [ "$host" = "$AP_PR_HOST" ] || return 1
  [ "$path" = "$AP_PR_PATH" ] || return 1
  [ "$number" = "$AP_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$reg_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$reg_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [ "$result" = merged ] || return 1
  AP_PR_RETIRE_ID=$id
  AP_PR_RETIRE_PROVIDER=$provider
  AP_PR_RETIRE_URL=$url
  AP_PR_RETIRE_HOST=$host
  AP_PR_RETIRE_PATH=$path
  AP_PR_RETIRE_NUMBER=$number
  AP_PR_RETIRE_DATA_HASH=$data_hash
  AP_PR_RETIRE_TEMPLATE_HASH=$template_hash
  AP_PR_RETIRE_DATA_IDENTITY=$data_identity
  AP_PR_RETIRE_CHECK_IDENTITY=$check_identity
  AP_PR_RETIRE_REG_HASH=$reg_hash
  AP_PR_RETIRE_REG_IDENTITY=$reg_identity
}

ap_pr_poll_retirement_receipt_valid() {
  local state=$1 id=$2 receipt state_device meta
  ap_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(ap_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  ap_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  ap_pr_poll_retirement_parse "$receipt" || return 1
  [ "$AP_PR_RETIRE_ID" = "$id" ] || return 1
  meta="$state/$id.meta"
  ap_pr_metadata_identity_parse "$meta" || return 1
  [ "$AP_PR_META_PROVIDER" = "$AP_PR_RETIRE_PROVIDER" ] || return 1
  [ "$AP_PR_META_URL" = "$AP_PR_RETIRE_URL" ] || return 1
  [ "$AP_PR_META_HOST" = "$AP_PR_RETIRE_HOST" ] || return 1
  [ "$AP_PR_META_PATH" = "$AP_PR_RETIRE_PATH" ] || return 1
  [ "$AP_PR_META_NUMBER" = "$AP_PR_RETIRE_NUMBER" ] || return 1
  AP_PR_RETIRE_RECEIPT_HASH=$(ap_pr_sha256 "$receipt") || return 1
  AP_PR_RETIRE_RECEIPT_IDENTITY=$(ap_pr_file_identity "$receipt") || return 1
}

ap_pr_poll_retirement_data_valid() {
  local state=$1 id=$2 state_device data data_hash data_identity
  state_device=$(ap_pr_file_device "$state") || return 1
  data="$state/$id.pr-poll"
  ap_pr_private_file_valid "$data" 600 "$state_device" || return 1
  ap_pr_poll_data_parse "$data" || return 1
  data_hash=$(ap_pr_sha256 "$data") || return 1
  data_identity=$(ap_pr_file_identity "$data") || return 1
  [ "$AP_PR_DATA_PROVIDER" = "$AP_PR_RETIRE_PROVIDER" ] || return 1
  [ "$AP_PR_DATA_URL" = "$AP_PR_RETIRE_URL" ] || return 1
  [ "$AP_PR_DATA_HOST" = "$AP_PR_RETIRE_HOST" ] || return 1
  [ "$AP_PR_DATA_PATH" = "$AP_PR_RETIRE_PATH" ] || return 1
  [ "$AP_PR_DATA_NUMBER" = "$AP_PR_RETIRE_NUMBER" ] || return 1
  [ "$data_hash" = "$AP_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$data_identity" = "$AP_PR_RETIRE_DATA_IDENTITY" ]
}

ap_pr_poll_retirement_registration_valid() {
  local state=$1 id=$2 state_device registration reg_hash reg_identity
  state_device=$(ap_pr_file_device "$state") || return 1
  registration="$state/$id.pr-poll-registration"
  ap_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  ap_pr_poll_registration_parse "$registration" || return 1
  reg_hash=$(ap_pr_sha256 "$registration") || return 1
  reg_identity=$(ap_pr_file_identity "$registration") || return 1
  [ "$AP_PR_REG_ID" = "$id" ] || return 1
  [ "$AP_PR_REG_PROVIDER" = "$AP_PR_RETIRE_PROVIDER" ] || return 1
  [ "$AP_PR_REG_URL" = "$AP_PR_RETIRE_URL" ] || return 1
  [ "$AP_PR_REG_HOST" = "$AP_PR_RETIRE_HOST" ] || return 1
  [ "$AP_PR_REG_PATH" = "$AP_PR_RETIRE_PATH" ] || return 1
  [ "$AP_PR_REG_NUMBER" = "$AP_PR_RETIRE_NUMBER" ] || return 1
  [ "$AP_PR_REG_DATA_HASH" = "$AP_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$AP_PR_REG_TEMPLATE_HASH" = "$AP_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$AP_PR_REG_DATA_IDENTITY" = "$AP_PR_RETIRE_DATA_IDENTITY" ] || return 1
  [ "$AP_PR_REG_CHECK_IDENTITY" = "$AP_PR_RETIRE_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$AP_PR_RETIRE_REG_HASH" ] || return 1
  [ "$reg_identity" = "$AP_PR_RETIRE_REG_IDENTITY" ]
}

ap_pr_poll_retirement_check_valid() {
  local state=$1 id=$2 state_device check check_hash check_identity
  state_device=$(ap_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  ap_pr_private_file_valid "$check" 600 "$state_device" || return 1
  check_hash=$(ap_pr_sha256 "$check") || return 1
  check_identity=$(ap_pr_file_identity "$check") || return 1
  [ "$check_hash" = "$AP_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$check_identity" = "$AP_PR_RETIRE_CHECK_IDENTITY" ]
}

ap_pr_poll_retirement_state_valid() {
  local state=$1 id=$2 check data registration has_check=0 has_data=0 has_registration=0
  ap_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] || has_check=1
  [ ! -e "$data" ] && [ ! -L "$data" ] || has_data=1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || has_registration=1
  if [ "$has_check" -eq 1 ]; then
    [ "$has_data" -eq 1 ] && [ "$has_registration" -eq 1 ] || return 1
    ap_pr_poll_retirement_check_valid "$state" "$id" || return 1
    ap_pr_poll_retirement_data_valid "$state" "$id" || return 1
    ap_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  if [ "$has_registration" -eq 1 ]; then
    [ "$has_data" -eq 1 ] || return 1
    ap_pr_poll_retirement_data_valid "$state" "$id" || return 1
    ap_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  [ "$has_data" -eq 0 ] || ap_pr_poll_retirement_data_valid "$state" "$id"
}

ap_pr_poll_retirement_remove_exact() {
  local path=$1 state_device=$2 expected_identity=$3 expected_hash=$4
  ap_pr_private_file_valid "$path" 600 "$state_device" || return 1
  [ "$(ap_pr_file_identity "$path")" = "$expected_identity" ] || return 1
  [ "$(ap_pr_sha256 "$path")" = "$expected_hash" ] || return 1
  rm -f -- "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

ap_pr_poll_retirement_discard_obsolete() {
  local state=$1 id=$2 template=$3 receipt registration state_device
  local receipt_hash receipt_identity current_reg_hash current_reg_identity
  ap_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(ap_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  ap_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  ap_pr_poll_retirement_parse "$receipt" || return 1
  [ "$AP_PR_RETIRE_ID" = "$id" ] || return 1
  receipt_hash=$(ap_pr_sha256 "$receipt") || return 1
  receipt_identity=$(ap_pr_file_identity "$receipt") || return 1
  ap_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  current_reg_hash=$(ap_pr_sha256 "$registration") || return 1
  current_reg_identity=$(ap_pr_file_identity "$registration") || return 1
  if [ "$current_reg_hash" = "$AP_PR_RETIRE_REG_HASH" ] \
    && [ "$current_reg_identity" = "$AP_PR_RETIRE_REG_IDENTITY" ] \
    && [ "$AP_PR_REG_DATA_IDENTITY" = "$AP_PR_RETIRE_DATA_IDENTITY" ] \
    && [ "$AP_PR_REG_CHECK_IDENTITY" = "$AP_PR_RETIRE_CHECK_IDENTITY" ]; then
    return 1
  fi
  ap_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash"
}

ap_pr_poll_retirement_publish() {
  local state=$1 id=$2 template=$3 result=$4 receipt state_device tmp
  [ "$result" = merged ] || return 1
  ap_pr_poll_snapshot_matches "$state" "$id" "$template" || return 1
  state_device=$(ap_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  ap_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  umask 077
  tmp=$(mktemp "$state/.ap-pr-poll-retirement.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      ap-pr-poll-retirement-v1 \
      "$AP_PR_POLL_SNAPSHOT_ID" \
      "$AP_PR_POLL_SNAPSHOT_PROVIDER" \
      "$AP_PR_POLL_SNAPSHOT_URL" \
      "$AP_PR_POLL_SNAPSHOT_HOST" \
      "$AP_PR_POLL_SNAPSHOT_PATH" \
      "$AP_PR_POLL_SNAPSHOT_NUMBER" \
      "$AP_PR_POLL_SNAPSHOT_DATA_HASH" \
      "$AP_PR_POLL_SNAPSHOT_TEMPLATE_HASH" \
      "$AP_PR_POLL_SNAPSHOT_DATA_IDENTITY" \
      "$AP_PR_POLL_SNAPSHOT_CHECK_IDENTITY" \
      "$AP_PR_POLL_SNAPSHOT_REG_HASH" \
      "$AP_PR_POLL_SNAPSHOT_REG_IDENTITY" \
      merged > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! ap_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! ap_pr_poll_retirement_parse "$tmp" \
    || [ "$AP_PR_RETIRE_ID" != "$id" ] \
    || ! ap_pr_poll_snapshot_matches "$state" "$id" "$template" \
    || ! ap_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" \
    || [ -e "$receipt" ] || [ -L "$receipt" ] \
    || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  ap_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
}

ap_pr_poll_retirement_recover_one() {
  local state=$1 id=$2 template=$3 receipt state_device check data registration
  local receipt_hash receipt_identity
  ap_pr_task_id_valid "$id" || return 1
  receipt="$state/$id.pr-poll-retirement"
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  if ! ap_pr_poll_retirement_state_valid "$state" "$id"; then
    ap_pr_poll_retirement_discard_obsolete "$state" "$id" "$template" && return 0
    return 1
  fi
  state_device=$(ap_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  receipt_hash=$AP_PR_RETIRE_RECEIPT_HASH
  receipt_identity=$AP_PR_RETIRE_RECEIPT_IDENTITY
  if [ -e "$check" ] || [ -L "$check" ]; then
    ap_pr_poll_retirement_remove_exact "$check" "$state_device" \
      "$AP_PR_RETIRE_CHECK_IDENTITY" "$AP_PR_RETIRE_TEMPLATE_HASH" || return 1
  fi
  if [ -e "$registration" ] || [ -L "$registration" ]; then
    ap_pr_poll_retirement_remove_exact "$registration" "$state_device" \
      "$AP_PR_RETIRE_REG_IDENTITY" "$AP_PR_RETIRE_REG_HASH" || return 1
  fi
  if [ -e "$data" ] || [ -L "$data" ]; then
    ap_pr_poll_retirement_remove_exact "$data" "$state_device" \
      "$AP_PR_RETIRE_DATA_IDENTITY" "$AP_PR_RETIRE_DATA_HASH" || return 1
  fi
  ap_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash" || return 1
  [ ! -e "$check" ] && [ ! -L "$check" ] \
    && [ ! -e "$registration" ] && [ ! -L "$registration" ] \
    && [ ! -e "$data" ] && [ ! -L "$data" ] \
    && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
}

ap_pr_poll_retirement_recover_all() {
  local state=$1 template=$2 receipt id
  AP_PR_POLL_RETIREMENT_REJECTED=
  for receipt in "$state"/*.pr-poll-retirement; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=$(basename "$receipt" .pr-poll-retirement)
    if ! ap_pr_task_id_valid "$id" \
      || ! ap_pr_poll_retirement_recover_one "$state" "$id" "$template"; then
      AP_PR_POLL_RETIREMENT_REJECTED="$AP_PR_POLL_RETIREMENT_REJECTED $receipt"
    fi
  done
  [ -z "$AP_PR_POLL_RETIREMENT_REJECTED" ]
}
