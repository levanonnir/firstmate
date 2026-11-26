#!/usr/bin/env bash
# fm-change-detect.sh - deterministic, zero-token fleet change detection and
# pre-LLM wake absorption.
#
# Single owner of:
#   - task-level zero-change predicates (PR-ready parked with armed merge poll,
#     active declared wait, pure *.turn-ended zero-change absorption, and
#     already-presented terminal outcome detection);
#   - deterministic fleet-state snapshots and SHA-256 digests over durable task
#     metadata, status logs, open decisions, PR poll/merge state, steering
#     inboxes, captain inbox notes, pending terminal outcomes, and process-event
#     records;
#   - locked auto-acknowledgement of pure no-op heartbeat rows when the current
#     fleet state digest is byte-identical to the last reviewed digest and no
#     actionable status span or pending work exists.
#
# Sourced as a library by bin/fm-watch.sh, bin/fm-inactive-reconcile.sh, and
# bin/fm-wake-drain.sh, and executable directly as a zero-token CLI tool:
#
# Usage:
#   fm-change-detect.sh snapshot [--with-crew-state]
#   fm-change-detect.sh digest [--with-crew-state]
#   fm-change-detect.sh check [--heartbeat] [--with-crew-state]
#   fm-change-detect.sh mark-reviewed
#   fm-change-detect.sh pr-ready-parked <task-id>
#   fm-change-detect.sh auto-ack-noop-heartbeat
#   fm-change-detect.sh --help
#
# Exit codes for `check`:
#   0  unchanged (current digest matches state/.fleet-state-digest, and for
#      --heartbeat no unsurfaced actionable status span or pending inbox/outcome
#      obligation exists)
#   1  changed (or no reviewed digest recorded yet)
#   2  usage error

_FM_CD_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
_FM_CD_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_FM_CD_DIR/.." && pwd)}"

# Preserve the caller's nounset option across helper sources.
case $- in *u*) _fm_cd_nounset=on ;; *) _fm_cd_nounset=off ;; esac
if ! command -v fm_wake_signal_seen_current >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_CD_DIR/fm-wake-lib.sh"
fi
if ! command -v status_span_first_actionable_record >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_CD_DIR/fm-classify-lib.sh"
fi
if ! command -v fm_pr_metadata_identity_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$_FM_CD_DIR/fm-pr-lib.sh"
fi
[ "$_fm_cd_nounset" = on ] || set +u
unset _fm_cd_nounset

_fm_cd_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{printf "%08x%08x\n", $1, $2}'
  fi
}

_fm_cd_file_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" 2>/dev/null | awk '{print $1}'
  else
    cksum -- "$1" 2>/dev/null | awk '{printf "%08x%08x\n", $1, $2}'
  fi
}

_fm_cd_file_size() {  # <file>
  LC_ALL=C wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

_fm_cd_file_lines() {  # <file>
  LC_ALL=C wc -l < "$1" 2>/dev/null | tr -d '[:space:]'
}

_fm_cd_meta_get() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

_fm_cd_crew_state_word() {  # <state> <task>
  local state=$1 task=$2 bin line
  bin="${FM_CREW_STATE_BIN:-$_FM_CD_DIR/fm-crew-state.sh}"
  line=$(FM_STATE_OVERRIDE="$state" FM_CREW_STATE_NO_FORGE=1 "$bin" "$task" 2>/dev/null) || true
  case "$line" in
    state:*)
      line=${line#state: }
      printf '%s' "${line%% *}"
      ;;
    *)
      printf 'unknown'
      ;;
  esac
}

# 0 iff <task>'s steering inbox contains at least one unhandled *.msg file.
fm_change_task_has_unread_inbox() {  # <state> <task>
  local state=$1 task=$2 msg
  [ -d "$state/$task.inbox" ] && [ ! -L "$state/$task.inbox" ] || return 1
  for msg in "$state/$task.inbox"/*.msg; do
    [ -f "$msg" ] && [ ! -L "$msg" ] && return 0
  done
  return 1
}

_fm_cd_task_unread_inbox_count() {  # <state> <task>
  local state=$1 task=$2 msg count=0
  if [ -d "$state/$task.inbox" ] && [ ! -L "$state/$task.inbox" ]; then
    for msg in "$state/$task.inbox"/*.msg; do
      [ -f "$msg" ] && [ ! -L "$msg" ] && count=$((count + 1))
    done
  fi
  printf '%s' "$count"
}

# 0 iff <task> is a finished, already-registered PR-ready ship waiting for
# merge with zero new actionable changes:
#   - ordinary ship task (not secondmate, not scout);
#   - valid canonical pr=<url> in state/<task>.meta;
#   - authenticated merge poll state/<task>.check.sh armed for that exact PR
#     identity, and that PR is not already merge-notified;
#   - readable non-symlink state/<task>.status with no unseen bytes, latest
#     recognized status verb `done`, zero open decisions, and zero unread
#     steering inbox messages;
#   - no unsurfaced actionable status span past .hb-surfaced-<task> (or when
#     that marker is absent, the latest done: line explicitly carries the armed
#     PR URL).
fm_change_task_pr_ready_parked() {  # <state> <task>
  local state=$1 task=$2 meta status kind poll_script last hb_marker hb_offset
  local provider url host path number
  [ -n "$state" ] && [ -n "$task" ] || return 1
  case "$task" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  meta="$state/$task.meta"
  status="$state/$task.status"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  kind=$(_fm_cd_meta_get "$meta" kind)
  case "$kind" in secondmate|scout) return 1 ;; esac

  fm_pr_metadata_identity_parse "$meta" || return 1
  provider=$FM_PR_META_PROVIDER
  url=$FM_PR_META_URL
  host=$FM_PR_META_HOST
  path=$FM_PR_META_PATH
  number=$FM_PR_META_NUMBER

  poll_script="${FM_CHANGE_PR_POLL_SCRIPT:-$_FM_CD_DIR/fm-pr-poll.sh}"
  fm_pr_poll_snapshot_capture "$state" "$task" "$poll_script" || return 1
  [ "$FM_PR_POLL_SNAPSHOT_PROVIDER" = "$provider" ] \
    && [ "$FM_PR_POLL_SNAPSHOT_URL" = "$url" ] \
    && [ "$FM_PR_POLL_SNAPSHOT_HOST" = "$host" ] \
    && [ "$FM_PR_POLL_SNAPSHOT_PATH" = "$path" ] \
    && [ "$FM_PR_POLL_SNAPSHOT_NUMBER" = "$number" ] || return 1
  if fm_pr_poll_merge_already_notified "$state" "$task" \
    "$provider" "$host" "$path" "$number"; then
    return 1
  fi

  [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ] || return 1
  fm_wake_signal_seen_current "$state" "$status" || return 1
  last=$(last_status_line "$status")
  [ "$(status_line_verb "$last")" = "done" ] || return 1
  [ -z "$(status_open_decisions "$status")" ] || return 1
  ! fm_change_task_has_unread_inbox "$state" "$task" || return 1

  hb_marker=$(status_heartbeat_seen_marker_path "$state" "$task")
  if [ -e "$hb_marker" ] || [ -L "$hb_marker" ]; then
    hb_offset=$(status_presentation_marker_offset "$hb_marker" "$status")
    ! status_span_has_actionable "$status" "$hb_offset" || return 1
  else
    case "$last" in
      *"$url"*) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# 0 iff a main-home task's terminal <expected-state> (`done` or `failed`) was
# already handled/presented so fm-inactive-reconcile.sh must not emit a
# duplicate `check: inactive-outcome` wake. Silent completions (where the
# status log never recorded <expected-state>) always return 1 so reconciliation
# keeps catching them.
fm_change_task_terminal_already_presented() {  # <state> <task> <done|failed>
  local state=$1 task=$2 expected=$3 status last size hb_marker hb_offset cursor_offset
  case "$expected" in done|failed) ;; *) return 1 ;; esac
  if [ "$expected" = "done" ] && fm_change_task_pr_ready_parked "$state" "$task"; then
    return 0
  fi
  status="$state/$task.status"
  [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ] || return 1
  last=$(last_status_line "$status")
  [ "$(status_line_verb "$last")" = "$expected" ] || return 1
  size=$(_fm_cd_file_size "$status")
  case "$size" in ''|*[!0-9]*|0) return 1 ;; esac
  hb_marker=$(status_heartbeat_seen_marker_path "$state" "$task")
  [ -f "$hb_marker" ] && [ ! -L "$hb_marker" ] || return 1
  hb_offset=$(status_presentation_marker_offset "$hb_marker" "$status")
  case "$hb_offset" in ''|*[!0-9]*) return 1 ;; esac
  [ "$hb_offset" -ge "$size" ] || return 1
  cursor_offset=$(status_presentation_cursor_offset "$status" 2>/dev/null) || return 1
  case "$cursor_offset" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cursor_offset" -ge "$size" ] || return 1
  return 0
}

# 0 iff <task> is in an active declared wait (`paused:` with non-expired
# `until`, or `captain-held:`), its wait line was already seen, no unread steer
# is waiting, and authoritative crew state has not transitioned to an
# actionable state (`failed`, `blocked`, `parked`, `done`, or for `paused:`
# `unknown`/dead).
fm_change_task_declared_wait_active() {  # <state> <task>
  local state=$1 task=$2 status last until now state_word absorb_class
  status="$state/$task.status"
  [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ] || return 1
  fm_wake_signal_seen_current "$state" "$status" || return 1
  ! fm_change_task_has_unread_inbox "$state" "$task" || return 1
  last=$(status_declared_wait_line "$status")
  if status_is_captain_held "$last"; then
    state_word=$(_fm_cd_crew_state_word "$state" "$task")
    case "$state_word" in
      failed|blocked|parked|done) return 1 ;;
    esac
    return 0
  fi
  if status_is_paused "$last"; then
    if until=$(status_paused_until "$last"); then
      now=$(date +%s)
      [ "$now" -lt "$until" ] || return 1
    fi
    [ -z "$(status_open_decisions "$status")" ] || return 1
    absorb_class=$(FM_STATE_OVERRIDE="$state" crew_absorb_class "$task")
    case "$absorb_class" in
      working|paused) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 1
}

# 0 (absorb, zero LLM tokens) iff EVERY argument is strictly a *.turn-ended
# marker whose referenced task has no unseen status changes, no unread steering
# inbox message, and is deterministically accounted for as:
#   - provably working (active no-mistakes run-step or busy pane), OR
#   - an active declared wait (paused: / captain-held: without state regression), OR
#   - PR-ready parked (pr= + armed merge poll + seen done: + no regression).
# Any *.status argument immediately returns 1 so authored status lines keep
# their existing surface contract.
fm_change_signal_turnend_zero_change() {  # <state> <file>...
  local state=$1 f base task seen='' status state_word
  shift
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.turn-ended) task=${base%.turn-ended} ;;
      *) return 1 ;;
    esac
    [ -n "$task" ] || return 1
    case "$task" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    [ -f "$state/$task.meta" ] && [ ! -L "$state/$task.meta" ] || return 1
    status="$state/$task.status"
    if [ -e "$status" ] || [ -L "$status" ]; then
      fm_wake_signal_seen_current "$state" "$status" || return 1
    fi
    ! fm_change_task_has_unread_inbox "$state" "$task" || return 1
    if FM_STATE_OVERRIDE="$state" crew_is_provably_working "$task"; then
      continue
    fi
    if fm_change_task_declared_wait_active "$state" "$task"; then
      continue
    fi
    if fm_change_task_pr_ready_parked "$state" "$task"; then
      state_word=$(_fm_cd_crew_state_word "$state" "$task")
      case "$state_word" in
        failed|blocked|parked) return 1 ;;
      esac
      continue
    fi
    return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# Print a canonical, sorted, deterministic snapshot of all actionable fleet
# state under <state>. Excludes volatile timestamps, liveness beacons, and pane
# hashes so idle clock ticks never cause false diffs, while capturing every
# actionable task, status, decision, PR, inbox, and pending-outcome fact.
fm_change_fleet_snapshot() {  # <state> [--with-crew-state]
  local state=$1 with_crew=0
  [ "${2:-}" = --with-crew-state ] && with_crew=1
  local LC_ALL=C exclude poll_script meta id kind mode yolo pr pr_head spawn_gen
  local status status_sig status_size status_lines status_hash last_line wait_line
  local open_dec open_hash hb_marker hb_off cur_off pr_armed pr_merged pr_retired
  local inbox_cnt crew_line f note_name note_size note_hash pending_name
  local seen_tasks=' '
  local -a meta_list=() status_list=() note_list=() pending_list=()

  exclude=$(status_scan_parent_channel_exclude "$state")
  poll_script="${FM_CHANGE_PR_POLL_SCRIPT:-$_FM_CD_DIR/fm-pr-poll.sh}"

  printf 'schema=fm-fleet-snapshot.v1\n'

  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    meta_list+=("${meta##*/}")
  done
  if [ "${#meta_list[@]}" -gt 0 ]; then
    while IFS= read -r meta; do
      [ -n "$meta" ] || continue
      id=${meta%.meta}
      seen_tasks="${seen_tasks}${id} "
      meta="$state/$meta"
      kind=$(_fm_cd_meta_get "$meta" kind); [ -n "$kind" ] || kind=ship
      mode=$(_fm_cd_meta_get "$meta" mode)
      yolo=$(_fm_cd_meta_get "$meta" yolo)
      pr=$(_fm_cd_meta_get "$meta" pr)
      pr_head=$(_fm_cd_meta_get "$meta" pr_head)
      spawn_gen=$(_fm_cd_meta_get "$meta" spawn_gen)

      status="$state/$id.status"
      if [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ]; then
        status_sig='file'
        status_size=$(_fm_cd_file_size "$status")
        status_lines=$(_fm_cd_file_lines "$status")
        status_hash=$(_fm_cd_file_sha256 "$status")
        last_line=$(last_status_line "$status" | tr '\t\r\n' '   ')
        wait_line=$(status_declared_wait_line "$status" | tr '\t\r\n' '   ')
        open_dec=$(status_open_decisions "$status" || true)
        if [ -n "$open_dec" ]; then
          open_hash=$(printf '%s' "$open_dec" | _fm_cd_sha256)
        else
          open_hash=none
        fi
        hb_marker=$(status_heartbeat_seen_marker_path "$state" "$id")
        hb_off=$(status_presentation_marker_offset "$hb_marker" "$status")
        cur_off=$(status_presentation_cursor_offset "$status" 2>/dev/null || printf '0')
      elif [ -e "$status" ] || [ -L "$status" ]; then
        status_sig="unreadable:$(status_observed_signature "$status")"
        status_size=0; status_lines=0; status_hash=unreadable
        last_line=''; wait_line=''; open_hash=unreadable; hb_off=0; cur_off=0
      else
        status_sig=absent
        status_size=0; status_lines=0; status_hash=absent
        last_line=''; wait_line=''; open_hash=none; hb_off=0; cur_off=0
      fi

      pr_armed=0; pr_merged=0; pr_retired=0
      if fm_pr_metadata_identity_parse "$meta"; then
        if fm_pr_poll_snapshot_capture "$state" "$id" "$poll_script" \
          && [ "$FM_PR_POLL_SNAPSHOT_URL" = "$FM_PR_META_URL" ]; then
          pr_armed=1
        fi
        if fm_pr_poll_merge_already_notified "$state" "$id" \
          "$FM_PR_META_PROVIDER" "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER"; then
          pr_merged=1
        fi
        if fm_pr_poll_retirement_receipt_valid "$state" "$id"; then
          pr_retired=1
        fi
      fi
      inbox_cnt=$(_fm_cd_task_unread_inbox_count "$state" "$id")

      printf 'task\t%s\tkind=%s\tmode=%s\tyolo=%s\tgen=%s\tpr=%s\tpr_head=%s\tpr_armed=%s\tpr_merged=%s\tpr_retired=%s\tinbox=%s\tstatus=%s:%s:%s:%s\topen=%s\thb=%s\tcur=%s\tlast=%s\twait=%s\n' \
        "$id" "$kind" "$mode" "$yolo" "$spawn_gen" "$pr" "$pr_head" \
        "$pr_armed" "$pr_merged" "$pr_retired" "$inbox_cnt" \
        "$status_sig" "$status_size" "$status_lines" "$status_hash" \
        "$open_hash" "$hb_off" "$cur_off" "$last_line" "$wait_line"
      if [ "$with_crew" -eq 1 ]; then
        crew_line=$(FM_STATE_OVERRIDE="$state" FM_CREW_STATE_NO_FORGE=1 "${FM_CREW_STATE_BIN:-$_FM_CD_DIR/fm-crew-state.sh}" "$id" 2>/dev/null | tr '\t\r\n' '   ' || true)
        printf 'crew_state\t%s\t%s\n' "$id" "$crew_line"
      fi
    done < <(printf '%s\n' "${meta_list[@]}" | LC_ALL=C sort)
  fi

  for f in "$state"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    id=${f##*/}
    id=${id%.status}
    case "$seen_tasks" in *" $id "*) continue ;; esac
    status_list+=("$id")
  done
  if [ "${#status_list[@]}" -gt 0 ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      status="$state/$id.status"
      if [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ]; then
        status_size=$(_fm_cd_file_size "$status")
        status_lines=$(_fm_cd_file_lines "$status")
        status_hash=$(_fm_cd_file_sha256 "$status")
        open_dec=$(status_open_decisions "$status" || true)
        if [ -n "$open_dec" ]; then
          open_hash=$(printf '%s' "$open_dec" | _fm_cd_sha256)
        else
          open_hash=none
        fi
        printf 'orphan_status\t%s\t%s:%s:%s\topen=%s\n' \
          "$id" "$status_size" "$status_lines" "$status_hash" "$open_hash"
      else
        printf 'orphan_status\t%s\tunreadable:%s\n' \
          "$id" "$(status_observed_signature "$status")"
      fi
    done < <(printf '%s\n' "${status_list[@]}" | LC_ALL=C sort)
  fi

  if [ -d "$state/inbox" ] && [ ! -L "$state/inbox" ]; then
    for f in "$state/inbox"/*.note; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      note_list+=("${f##*/}")
    done
  fi
  if [ "${#note_list[@]}" -gt 0 ]; then
    while IFS= read -r note_name; do
      [ -n "$note_name" ] || continue
      note_size=$(_fm_cd_file_size "$state/inbox/$note_name")
      note_hash=$(_fm_cd_file_sha256 "$state/inbox/$note_name")
      printf 'captain_inbox\t%s\t%s:%s\n' "$note_name" "$note_size" "$note_hash"
    done < <(printf '%s\n' "${note_list[@]}" | LC_ALL=C sort)
  fi

  if [ -d "$state/terminal-outcomes" ] && [ ! -L "$state/terminal-outcomes" ]; then
    for f in "$state/terminal-outcomes"/*.pending; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      pending_list+=("${f##*/}")
    done
  fi
  if [ "${#pending_list[@]}" -gt 0 ]; then
    while IFS= read -r pending_name; do
      [ -n "$pending_name" ] || continue
      printf 'pending_outcome\t%s\n' "$pending_name"
    done < <(printf '%s\n' "${pending_list[@]}" | LC_ALL=C sort)
  fi
}

fm_change_fleet_digest() {  # <state> [--with-crew-state]
  fm_change_fleet_snapshot "$@" | _fm_cd_sha256
}

fm_change_fleet_digest_path() {  # <state>
  printf '%s/.fleet-state-digest' "$1"
}

# 0 iff a reviewed digest exists at state/.fleet-state-digest and matches the
# current deterministic fleet state digest byte-for-byte.
fm_change_fleet_digest_matches_reviewed() {  # <state> [--with-crew-state]
  local state=$1 with_crew=${2:-} path stored current
  path=$(fm_change_fleet_digest_path "$state")
  [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 1
  stored=$(cat "$path" 2>/dev/null || true)
  case "$stored" in ''|*[!0-9a-f]*) return 1 ;; esac
  current=$(fm_change_fleet_digest "$state" ${with_crew:+"$with_crew"}) || return 1
  [ -n "$current" ] && [ "$stored" = "$current" ]
}

# Atomically record the current deterministic fleet state digest as reviewed.
fm_change_fleet_digest_record_reviewed() {  # <state>
  local state=$1 path digest tmp
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  path=$(fm_change_fleet_digest_path "$state")
  digest=$(fm_change_fleet_digest "$state") || return 1
  [ -n "$digest" ] || return 1
  tmp=$(umask 077; mktemp "$state/.fleet-state-digest.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$digest" > "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# 0 iff any status file carries an unsurfaced captain-relevant event or an
# unreported readability error past its .hb-surfaced-<task> marker.
_fm_cd_has_unsurfaced_actionable_status() {  # <state>
  local state=$1 f task exclude hb_marker hb_off rc sig
  exclude=$(status_scan_parent_channel_exclude "$state")
  for f in "$state"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    task=${f##*/}
    task=${task%.status}
    hb_marker=$(status_heartbeat_seen_marker_path "$state" "$task")
    hb_off=$(status_presentation_marker_offset "$hb_marker" "$f")
    status_span_first_actionable_record "$f" "$hb_off" >/dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
      if fm_change_task_pr_ready_parked "$state" "$task"; then
        continue
      fi
      return 0
    elif [ "$rc" -eq 2 ]; then
      sig=$(status_observed_signature "$f")
      status_presentation_marker_reported_matches "$hb_marker" "$sig" && continue
      return 0
    fi
  done
  return 1
}

# 0 iff a heartbeat tick is provably a zero-change no-op:
#   - current fleet state digest is byte-identical to state/.fleet-state-digest;
#   - zero pending captain inbox notes;
#   - zero pending terminal outcomes;
#   - zero unsurfaced actionable status spans.
fm_change_heartbeat_is_noop() {  # <state>
  local state=$1 f
  fm_change_fleet_digest_matches_reviewed "$state" || return 1
  if [ -d "$state/inbox" ] && [ ! -L "$state/inbox" ]; then
    for f in "$state/inbox"/*.note; do
      [ -f "$f" ] && [ ! -L "$f" ] && return 1
    done
  fi
  if [ -d "$state/terminal-outcomes" ] && [ ! -L "$state/terminal-outcomes" ]; then
    for f in "$state/terminal-outcomes"/*.pending; do
      [ -f "$f" ] && [ ! -L "$f" ] && return 1
    done
  fi
  ! _fm_cd_has_unsurfaced_actionable_status "$state" || return 1
  return 0
}

# Under the wake-queue lock, atomically consume pure heartbeat-only rows when
# fm_change_heartbeat_is_noop holds and no downtime recovery is pending.
# Returns 0 when the queue was already empty or auto-acknowledged cleanly,
# 1 when normal LLM delivery must proceed.
fm_change_auto_ack_noop_heartbeat() {  # <state>
  local state=$1 queue lock recovery token tmp
  # shellcheck disable=SC2034 # Used by sourced wake-lib helpers.
  local STATE=$state
  queue="$state/.wake-queue"
  lock="$state/.wake-queue.lock"
  recovery="$state/.watcher-down"

  [ -f "$queue" ] && [ ! -L "$queue" ] || return 1
  fm_lock_acquire_wait_bounded "$lock" 5 || return 1

  if [ ! -f "$queue" ] || [ -L "$queue" ]; then
    fm_lock_release "$lock"
    return 1
  fi
  if [ ! -s "$queue" ]; then
    fm_lock_release "$lock"
    return 0
  fi

  # Never consume rows currently granted to a live supervision branch turn.
  if fm_wake_branch_grant_live "$state/.branch-eligible-rows" "$state/.branch-eligible-owner"; then
    fm_lock_release "$lock"
    return 1
  fi

  # Every non-blank row must be a structurally valid heartbeat row.
  if ! awk -F '\t' '
    /^[[:space:]]*$/ { next }
    NF < 5 || $2 !~ /^[0-9]+$/ || $3 != "heartbeat" { bad = 1; exit 1 }
    { count++ }
    END { exit (bad || count == 0 ? 1 : 0) }
  ' "$queue"; then
    fm_lock_release "$lock"
    return 1
  fi

  # Never auto-ack when an announced downtime recovery is pending.
  if [ -e "$recovery" ] || [ -L "$recovery" ]; then
    if ! fm_recovery_marker_snapshot "$recovery"; then
      fm_lock_release "$lock"
      return 1
    fi
    token=$FM_RECOVERY_MARKER_TOKEN
    case "$token" in
      announced:downtime:*)
        fm_lock_release "$lock"
        return 1
        ;;
    esac
  else
    token=''
  fi

  if ! fm_change_heartbeat_is_noop "$state"; then
    fm_lock_release "$lock"
    return 1
  fi

  tmp=$(umask 077; mktemp "$state/.wake-queue.noop-hb.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  if ! _fm_atomic_replace "$tmp" "$queue"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  case "$token" in
    pending:downtime:*|pending:handling:*|announced:handling:*)
      fm_recovery_marker_ack "$recovery" "${token##*:}" >/dev/null 2>&1 || true
      ;;
  esac
  fm_lock_release "$lock"
  return 0
}

_fm_cd_usage() {
  cat <<'EOF'
usage: fm-change-detect.sh <command> [options]

Commands:
  snapshot [--with-crew-state]         Print deterministic fleet state snapshot
  digest [--with-crew-state]           Print SHA-256 digest of fleet state snapshot
  check [--heartbeat] [--with-crew-state]
                                       Exit 0 (unchanged) or 1 (changed) vs reviewed digest
  mark-reviewed                        Record current fleet digest as reviewed
  pr-ready-parked <task-id>            Exit 0 if task is PR-ready with armed merge poll
  auto-ack-noop-heartbeat              Locked auto-ack of pure no-op heartbeat queue rows
  --help                               Show this help
EOF
}

_fm_cd_main() {
  local home state cmd with_crew=0 heartbeat=0 stored current
  home="${FM_HOME:-$_FM_CD_ROOT}"
  state="${FM_STATE_OVERRIDE:-$home/state}"
  cmd=${1:-}
  [ -n "$cmd" ] || { _fm_cd_usage >&2; return 2; }
  shift

  case "$cmd" in
    snapshot)
      [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --with-crew-state ] && with_crew=1; } \
        || { _fm_cd_usage >&2; return 2; }
      if [ "$with_crew" -eq 1 ]; then
        fm_change_fleet_snapshot "$state" --with-crew-state
      else
        fm_change_fleet_snapshot "$state"
      fi
      ;;
    digest)
      [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --with-crew-state ] && with_crew=1; } \
        || { _fm_cd_usage >&2; return 2; }
      if [ "$with_crew" -eq 1 ]; then
        fm_change_fleet_digest "$state" --with-crew-state
      else
        fm_change_fleet_digest "$state"
      fi
      ;;
    check)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --heartbeat) heartbeat=1 ;;
          --with-crew-state) with_crew=1 ;;
          *) _fm_cd_usage >&2; return 2 ;;
        esac
        shift
      done
      if [ "$with_crew" -eq 1 ]; then
        current=$(fm_change_fleet_digest "$state" --with-crew-state) || return 1
      else
        current=$(fm_change_fleet_digest "$state") || return 1
      fi
      stored=$(cat "$(fm_change_fleet_digest_path "$state")" 2>/dev/null || true)
      if [ "$heartbeat" -eq 1 ]; then
        if fm_change_heartbeat_is_noop "$state"; then
          printf 'unchanged %s\n' "$current"
          return 0
        fi
        printf 'changed %s %s\n' "$current" "${stored:-none}"
        return 1
      fi
      if [ -n "$stored" ] && [ "$stored" = "$current" ]; then
        printf 'unchanged %s\n' "$current"
        return 0
      fi
      printf 'changed %s %s\n' "$current" "${stored:-none}"
      return 1
      ;;
    mark-reviewed)
      [ "$#" -eq 0 ] || { _fm_cd_usage >&2; return 2; }
      fm_change_fleet_digest_record_reviewed "$state"
      ;;
    pr-ready-parked)
      [ "$#" -eq 1 ] || { _fm_cd_usage >&2; return 2; }
      fm_change_task_pr_ready_parked "$state" "$1"
      ;;
    auto-ack-noop-heartbeat)
      [ "$#" -eq 0 ] || { _fm_cd_usage >&2; return 2; }
      fm_change_auto_ack_noop_heartbeat "$state"
      ;;
    -h|--help|help)
      _fm_cd_usage
      ;;
    *)
      _fm_cd_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  _fm_cd_main "$@"
fi
