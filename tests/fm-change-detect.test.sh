#!/usr/bin/env bash
# Behavioral coverage for deterministic zero-token change detection and
# pre-LLM wake absorption across bin/fm-change-detect.sh, bin/fm-watch.sh,
# bin/fm-inactive-reconcile.sh, bin/fm-wake-drain.sh, bin/fm-wake-lib.sh,
# bin/fm-push-transition-lib.sh, and .pi/extensions/fm-primary-pi-watch.ts.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-change-detect.sh"

DETECT="$ROOT/bin/fm-change-detect.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
RECON="$ROOT/bin/fm-inactive-reconcile.sh"
PR_POLL="$ROOT/bin/fm-pr-poll.sh"

TMP_ROOT=$(fm_test_tmproot fm-change-detect-tests)
fm_git_identity fmtest fmtest@example.invalid

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

file_mtime() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

set_mtime() {  # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

mark_status_seen() {  # <state> <status-file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

mark_hb_surfaced() {  # <state> <task>
  local state=$1 task=$2 status size ident marker
  status="$state/$task.status"
  size=$(size_of "$status")
  ident=$(_fm_open_decisions_file_ident "$status")
  marker=$(status_heartbeat_seen_marker_path "$state" "$task")
  status_presentation_marker_commit "$marker" "$status" "$size" "$ident"
}

arm_pr_poll() {  # <state> <task> <url>
  local state=$1 task=$2 url=$3
  FM_STATE_OVERRIDE="$state" bash -c '
    set -eu
    . "$1"
    fm_pr_url_parse "$4"
    fm_pr_poll_prepare "$2" "$3" "$FM_PR_PROVIDER" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$5"
    fm_pr_poll_publish_prepared
  ' _ "$ROOT/bin/fm-pr-lib.sh" "$state" "$task" "$url" "$PR_POLL"
}

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-200} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

watch_bg() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$WATCH" > "$out" &
}

# --- Case (a): pure *.turn-ended zero-change absorption ---------------------

test_turnend_paused_worker_absorbed_and_expired_until_surfaces() {
  local dir state fakebin out pid future_iso past_iso
  dir=$(make_case turnend-paused); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'window=test:fm-waiter\nkind=ship\n' > "$state/waiter.meta"
  future_iso=$(date -u -r "$(( $(date +%s) + 3600 ))" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
    || date -u -d "@$(( $(date +%s) + 3600 ))" '+%Y-%m-%dT%H:%MZ')
  printf 'paused: waiting on background validation until %s\n' "$future_iso" > "$state/waiter.status"
  mark_status_seen "$state" "$state/waiter.status"
  : > "$state/waiter.turn-ended"

  export FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting on background validation'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "watcher woke on bare turn-ended for an active declared paused worker: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "absorbed paused turn-ended printed output: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "absorbed paused turn-ended queued a wake"
  [ -s "$state/.seen-waiter_turn-ended" ] || fail "absorbed paused turn-ended did not advance seen marker"
  reap "$pid"

  # Once the declared `until` clearing time has passed, a bare turn-ended MUST surface.
  past_iso=$(date -u -r "$(( $(date +%s) - 120 ))" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
    || date -u -d "@$(( $(date +%s) - 120 ))" '+%Y-%m-%dT%H:%MZ')
  printf 'paused: waiting on background validation until %s\n' "$past_iso" > "$state/waiter.status"
  mark_status_seen "$state" "$state/waiter.status"
  printf 'expired\n' > "$state/waiter.turn-ended"
  rm -f "$state/.watcher-down"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "watcher did not surface turn-ended after paused until passed"; }
  grep -F "signal: $state/waiter.turn-ended" "$out" >/dev/null \
    || fail "expired paused until turn-ended did not print expected signal: $(cat "$out")"

  # A paused worker whose authoritative run-step transitioned to failed MUST surface.
  printf 'paused: waiting on background validation until %s\n' "$future_iso" > "$state/waiter.status"
  mark_status_seen "$state" "$state/waiter.status"
  printf 'failed-run\n' > "$state/waiter.turn-ended"
  rm -f "$state/.wake-queue" "$state/.watcher-down"
  : > "$out"
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · validation failed'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "watcher did not surface turn-ended when paused worker failed"; }
  grep -F "signal: $state/waiter.turn-ended" "$out" >/dev/null \
    || fail "failed-run turn-ended did not print expected signal: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "pure turn-ended on active declared pause absorbs; expired until and failed run surface"
}

test_turnend_captain_held_and_pr_ready_parked_absorbed_unless_actionable() {
  local dir state fakebin out pid url
  url='https://github.com/example/repo/pull/42'

  # 1. captain-held bare turn-ended absorbs when idle/unknown, surfaces on failure.
  dir=$(make_case turnend-held); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'window=test:fm-held\nkind=ship\n' > "$state/held.meta"
  printf 'captain-held: waiting for captain decision\n' > "$state/held.status"
  mark_status_seen "$state" "$state/held.status"
  : > "$state/held.turn-ended"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "watcher woke on bare turn-ended for captain-held worker: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "captain-held turn-ended printed output: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "captain-held turn-ended queued a wake"
  reap "$pid"

  # 2. PR-ready parked worker bare turn-ended absorbs.
  dir=$(make_case turnend-pr-ready); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'window=test:fm-ship\nkind=ship\npr=%s\n' "$url" > "$state/ship.meta"
  printf 'done: PR %s checks green\n' "$url" > "$state/ship.status"
  mark_status_seen "$state" "$state/ship.status"
  mark_hb_surfaced "$state" ship
  arm_pr_poll "$state" ship "$url"
  : > "$state/ship.turn-ended"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · run passed: PR open'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "watcher woke on bare turn-ended for PR-ready parked worker: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "PR-ready turn-ended printed output: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "PR-ready turn-ended queued a wake"
  reap "$pid"

  # 3. With an unread steering inbox message, the same PR-ready turn-ended MUST surface.
  mkdir -p "$state/ship.inbox"
  printf 'please address review comment\n' > "$state/ship.inbox/001.msg"
  printf 'after-steer\n' > "$state/ship.turn-ended"
  rm -f "$state/.watcher-down"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "watcher suppressed turn-ended while steering inbox had unread msg"; }
  grep -F "signal: $state/ship.turn-ended" "$out" >/dev/null \
    || fail "turn-ended with unread inbox did not surface expected signal: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "pure turn-ended on captain-held or PR-ready parked absorbs; unread steer surfaces"
}

# --- Case (b): stale on PR-ready parked worker (poll & Herdr push) ----------

test_stale_on_pr_ready_parked_absorbs_pane_ticks_while_unarmed_surfaces() {
  local dir state fakebin out capture window url pid tick
  url='https://github.com/example/repo/pull/77'
  dir=$(make_case stale-pr-ready); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  window='test:fm-prship'

  printf 'window=%s\nkind=ship\npr=%s\n' "$window" "$url" > "$state/prship.meta"
  printf 'done: PR %s checks green\n' "$url" > "$state/prship.status"
  mark_status_seen "$state" "$state/prship.status"
  mark_hb_surfaced "$state" prship
  arm_pr_poll "$state" prship "$url"
  printf 'idle prompt tick 0\n' > "$capture"

  export FM_FAKE_CREW_STATE='state: done · source: run-step · run passed: PR open'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" > "$out" &
  pid=$!
  for tick in 1 2 3; do
    printf 'idle prompt tick %s\n' "$tick" > "$capture"
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher woke on PR-ready pane tick $tick: $(cat "$out")"; }
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher woke on PR-ready stale tick $tick: $(cat "$out")"; }
  done
  [ ! -s "$out" ] || fail "PR-ready stale pane produced output: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "PR-ready stale pane queued a wake"
  grep -Fq 'absorbed stale (PR-ready and merge-poll armed, waiting for merge)' "$state/.watch-triage.log" \
    || fail "triage log did not record PR-ready stale absorption"
  reap "$pid"

  # Once a new blocked: status lands, it MUST wake immediately!
  printf 'blocked: merge conflict appeared on main\n' >> "$state/prship.status"
  rm -f "$state/.watcher-down"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "new blocked: status on PR-ready worker did not wake"; }
  grep -F "signal: $state/prship.status" "$out" >/dev/null \
    || fail "blocked: status did not wake as signal: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "stale pane on PR-ready parked worker absorbs repeated ticks; new blocked: wakes immediately"
}

test_push_transition_on_pr_ready_parked_absorbs() {
  local dir state url out
  url='https://github.com/example/repo/pull/88'
  dir=$(make_case push-pr-ready); state="$dir/state"
  printf 'window=lab:w1:p1\nbackend=herdr\nkind=ship\npr=%s\n' "$url" > "$state/herdrship.meta"
  printf 'done: PR %s checks green\n' "$url" > "$state/herdrship.status"
  mark_status_seen "$state" "$state/herdrship.status"
  mark_hb_surfaced "$state" herdrship
  arm_pr_poll "$state" herdrship "$url"

  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    STATE=$FM_STATE_OVERRIDE
    . "$1/bin/fm-push-transition-lib.sh"
    . "$1/bin/fm-change-detect.sh"
    fm_backend_commit_transition() { printf "committed:%s:%s\n" "$1" "$3"; }
    wake() { printf "WOKE:%s\n" "$1"; exit 99; }
    rec=$(fm_transition_record "w1:p1" "w1" "working" "blocked" "codex")
    handle_push_transition herdr lab "$rec"
  ' _ "$ROOT") || fail "handle_push_transition failed on PR-ready parked worker: $out"
  printf '%s\n' "$out" | grep -Fq 'committed:herdr:lab' \
    || fail "absorbed push transition did not commit cursor: $out"
  printf '%s\n' "$out" | grep -Fq 'WOKE:' \
    && fail "PR-ready parked push transition woke supervisor: $out"
  [ ! -s "$state/.wake-queue" ] || fail "PR-ready parked push transition queued a wake"
  pass "Herdr push transition absorbs on PR-ready parked worker and commits transition cursor"
}

# --- Case (c): inactive-outcome and teardown pruning ------------------------

test_inactive_reconcile_skips_pr_ready_and_presented_but_catches_silent() {
  local dir state fakebin url out
  url='https://github.com/example/repo/pull/99'
  dir=$(make_case inactive-skip); state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$dir/projects/prdone" "$dir/projects/presented" "$dir/projects/silent"

  # 1. PR-ready parked task (done + pr= + armed merge poll + seen) -> skipped.
  printf 'window=test:fm-prdone\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nspawn_gen=g1\npr=%s\n' \
    "$dir/projects/prdone" "$dir/projects/prdone" "$url" > "$state/prdone.meta"
  printf 'done: PR %s checks green\n' "$url" > "$state/prdone.status"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/prdone.meta"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/prdone.status"
  mark_status_seen "$state" "$state/prdone.status"
  mark_hb_surfaced "$state" prdone
  arm_pr_poll "$state" prdone "$url"

  # 2. Scout whose done: was already surfaced AND presented via drain -> skipped.
  printf 'window=test:fm-presented\nworktree=%s\nproject=%s\nkind=scout\nspawn_gen=g2\n' \
    "$dir/projects/presented" "$dir/projects/presented" > "$state/presented.meta"
  printf 'done: report ready at data/presented/report.md\n' > "$state/presented.status"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/presented.meta"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/presented.status"
  mark_status_seen "$state" "$state/presented.status"
  mark_hb_surfaced "$state" presented
  append_wake "$state" signal 'presented.status' "signal: $state/presented.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$dir/presented-drain.err" || true
  local pseq pgen
  pseq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$dir/presented-drain.err")
  pgen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/presented-drain.err")
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$pseq" --recovery-generation "$pgen" || fail "presented drain ack failed"

  # 3. Silent run-step completion (status still says working:) -> MUST wake!
  printf 'window=test:fm-silent\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nspawn_gen=g3\n' \
    "$dir/projects/silent" "$dir/projects/silent" > "$state/silent.meta"
  printf 'working: validating\n' > "$state/silent.status"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/silent.meta"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/silent.status"
  mark_status_seen "$state" "$state/silent.status"
  mark_hb_surfaced "$state" silent
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || true

  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: done · source: run-step · run passed' \
    "$RECON" scan --startup) || fail "inactive reconcile failed: $out"

  printf '%s\n' "$out" | grep -Fq 'child=prdone' \
    && fail "inactive reconcile re-woke on already PR-ready parked task: $out"
  printf '%s\n' "$out" | grep -Fq 'child=presented' \
    && fail "inactive reconcile re-woke on already-presented terminal outcome: $out"
  printf '%s\n' "$out" | grep -Fq 'child=silent' \
    || fail "inactive reconcile missed genuine silent run-step completion: $out"
  pass "inactive reconcile skips PR-ready parked and already-presented tasks while catching silent completions"
}

test_teardown_prune_removes_merged_and_inactive_outcome_rows_for_task_only() {
  local dir state queue
  dir=$(make_case prune-merged); state="$dir/state"; queue="$state/.wake-queue"
  append_wake "$state" check 'merged-foo-https://github.com/o/r/pull/1' 'check: merge landed: foo https://github.com/o/r/pull/1'
  append_wake "$state" check 'merged-foo-bar-https://github.com/o/r/pull/2' 'check: merge landed: foo-bar https://github.com/o/r/pull/2'
  append_wake "$state" check 'inactive-outcome:abcd1234' 'inactive terminal outcome awaiting captain presentation: child=foo state=done'
  append_wake "$state" check 'inactive-outcome:ef567890' 'inactive terminal outcome awaiting captain presentation: child=foo-bar state=done'

  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_queue_prune_task "$2" "$3" "$4"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state" foo 'test:fm-foo' \
    || fail "fm_wake_queue_prune_task failed"

  grep -Fq 'merged-foo-https://' "$queue" && fail "prune left merged check row for foo"
  grep -Fq 'child=foo state=done' "$queue" && fail "prune left inactive-outcome row for foo"
  grep -Fq 'merged-foo-bar-https://' "$queue" || fail "prune wrongly removed merged check row for sibling foo-bar"
  grep -Fq 'child=foo-bar state=done' "$queue" || fail "prune wrongly removed inactive-outcome row for sibling foo-bar"
  pass "fm_wake_queue_prune_task prunes merged and inactive-outcome rows for torn-down task only"
}

# --- Case (d): deterministic fleet state digest & heartbeat auto-ack --------

test_fleet_digest_determinism_and_change_sensitivity() {
  local dir state d1 d2 d3 out rc
  dir=$(make_case fleet-digest); state="$dir/state"
  printf 'window=test:fm-alpha\nkind=ship\nmode=no-mistakes\nyolo=off\n' > "$state/alpha.meta"
  printf 'working: step 1\n' > "$state/alpha.status"
  mark_status_seen "$state" "$state/alpha.status"
  mark_hb_surfaced "$state" alpha

  # Before mark-reviewed, check reports changed (exit 1).
  rc=0
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" check) || rc=$?
  expect_code 1 "$rc" "unreviewed home must report changed"

  # Mark reviewed; check and check --heartbeat now return 0 (unchanged).
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" mark-reviewed || fail "mark-reviewed failed"
  d1=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" digest)
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" check >/dev/null || fail "check failed immediately after mark-reviewed"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" check --heartbeat >/dev/null || fail "check --heartbeat failed on unchanged fleet"

  # Volatile watcher files (beacon, pane hashes, poll counts) must NOT change digest.
  touch "$state/.last-watcher-beat"
  printf 'deadbeef\n' > "$state/.hash-test_fm-alpha"
  printf '3\n' > "$state/.count-test_fm-alpha"
  d2=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" digest)
  [ "$d1" = "$d2" ] || fail "volatile watcher files altered deterministic fleet digest"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" check --heartbeat >/dev/null \
    || fail "volatile watcher files broke check --heartbeat"

  # New status event MUST change digest.
  printf 'needs-decision [key=q1]: pick A or B\n' >> "$state/alpha.status"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" check >/dev/null || rc=$?
  expect_code 1 "$rc" "new needs-decision did not invalidate fleet digest"

  # Re-mark reviewed after handling, then add a captain inbox note -> MUST change digest.
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" mark-reviewed || fail "second mark-reviewed failed"
  mkdir -p "$state/inbox"
  printf 'captain note body\n' > "$state/inbox/note-1.note"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" check --heartbeat >/dev/null || rc=$?
  expect_code 1 "$rc" "new captain inbox note did not invalidate heartbeat check"
  rm -f "$state/inbox/note-1.note"

  # Adding an unread steering inbox message -> MUST change digest.
  d3=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" digest)
  mkdir -p "$state/alpha.inbox"
  printf 'steer\n' > "$state/alpha.inbox/001.msg"
  local d4
  d4=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" digest)
  [ "$d3" != "$d4" ] \
    || fail "new unread steering inbox message did not change fleet digest"

  # Replacing 001.msg with 002.msg (count remains 1) -> MUST change digest.
  rm -f "$state/alpha.inbox/001.msg"
  printf 'steer\n' > "$state/alpha.inbox/002.msg"
  [ "$d4" != "$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" digest)" ] \
    || fail "replacing steering inbox 001.msg with 002.msg collided in fleet digest"

  # Unsupported --with-crew-state option must be rejected with usage exit 2.
  rc=0; FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" snapshot --with-crew-state >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "snapshot --with-crew-state must exit 2"
  rc=0; FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" digest --with-crew-state >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "digest --with-crew-state must exit 2"
  rc=0; FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" check --with-crew-state >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "check --with-crew-state must exit 2"
  pass "fleet state digest is stable across volatile files and sensitive to every actionable change"
}

test_drain_ack_records_digest_and_auto_ack_noop_heartbeat() {
  local dir state err seq gen rc
  dir=$(make_case noop-hb-auto-ack); state="$dir/state"
  printf 'window=test:fm-alpha\nkind=ship\n' > "$state/alpha.meta"
  printf 'working: building\n' > "$state/alpha.status"
  mark_status_seen "$state" "$state/alpha.status"
  mark_hb_surfaced "$state" alpha

  # Drain + ack records state/.fleet-state-digest when the queue empties.
  append_wake "$state" signal 'alpha.status' "signal: $state/alpha.status"
  err="$dir/drain.err"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    || fail "drain ack failed"
  [ -s "$state/.fleet-state-digest" ] || fail "drain ack did not record .fleet-state-digest"

  # 1. Pure heartbeat row with unchanged fleet digest -> auto-acked cleanly.
  append_wake "$state" heartbeat heartbeat heartbeat
  rm -f "$state/.watcher-down"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat \
    || fail "auto-ack-noop-heartbeat refused a pure unchanged heartbeat"
  [ ! -s "$state/.wake-queue" ] || fail "auto-ack-noop-heartbeat left rows in .wake-queue"

  # 2. Mixed queue (heartbeat + signal) -> refused, rows preserved!
  append_wake "$state" heartbeat heartbeat heartbeat
  append_wake "$state" signal 'alpha.status' "signal: $state/alpha.status"
  rm -f "$state/.watcher-down"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat || rc=$?
  expect_code 1 "$rc" "auto-ack-noop-heartbeat must refuse when non-heartbeat rows are queued"
  [ "$(wc -l < "$state/.wake-queue" | tr -d ' ')" -eq 2 ] || fail "mixed queue rows were mutated on refusal"

  # 3. Pure heartbeat with announced OR pending downtime recovery -> refused!
  : > "$state/.wake-queue"
  append_wake "$state" heartbeat heartbeat heartbeat
  printf 'announced:downtime:gen-123\n' > "$state/.watcher-down"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat || rc=$?
  expect_code 1 "$rc" "auto-ack-noop-heartbeat must refuse while downtime recovery is announced"
  [ -s "$state/.wake-queue" ] || fail "downtime-pending heartbeat was wrongly consumed"
  printf 'pending:downtime:gen-124\n' > "$state/.watcher-down"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat || rc=$?
  expect_code 1 "$rc" "auto-ack-noop-heartbeat must refuse while downtime recovery is pending"
  [ -s "$state/.wake-queue" ] || fail "pending-downtime heartbeat was wrongly consumed"
  grep -Fq 'pending:downtime:gen-124' "$state/.watcher-down" || fail "pending:downtime marker was altered on refusal"

  # 3b. Pure heartbeat with announced:handling:* -> auto-acked AND handling marker retired!
  printf 'announced:handling:gen-125\n' > "$state/.watcher-down"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat \
    || fail "auto-ack-noop-heartbeat refused announced:handling:* on unchanged fleet"
  [ ! -s "$state/.wake-queue" ] || fail "auto-ack-noop-heartbeat left rows with announced:handling:*"
  grep -Fq 'acked:handling:gen-125' "$state/.watcher-down" \
    || fail "auto-ack-noop-heartbeat did not retire announced:handling:*: $(cat "$state/.watcher-down")"
  rm -f "$state/.watcher-down"

  # 3c. ack-already-drained retires announced:handling:* on empty queue and refuses pending:downtime:*.
  : > "$state/.wake-queue"
  printf 'announced:handling:gen-126\n' > "$state/.watcher-down"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" ack-already-drained \
    || fail "ack-already-drained refused empty queue with announced:handling:*"
  grep -Fq 'acked:handling:gen-126' "$state/.watcher-down" \
    || fail "ack-already-drained did not retire announced:handling:*"
  printf 'pending:downtime:gen-127\n' > "$state/.watcher-down"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" ack-already-drained || rc=$?
  expect_code 1 "$rc" "ack-already-drained must refuse pending:downtime:*"

  # 3c2. Valid acked:* markers pass both ack-already-drained and auto-ack-noop-heartbeat.
  printf 'acked:handling:gen-128\n' > "$state/.watcher-down"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" ack-already-drained \
    || fail "ack-already-drained refused valid acked:handling:*"
  append_wake "$state" heartbeat heartbeat heartbeat
  printf 'acked:downtime:gen-129\n' > "$state/.watcher-down"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat \
    || fail "auto-ack-noop-heartbeat refused valid acked:downtime:*"
  [ ! -s "$state/.wake-queue" ] || fail "auto-ack-noop-heartbeat left rows with acked:downtime:*"

  # 3c3. Corrupt, empty, and symlink .watcher-down MUST fail closed on both paths.
  printf 'acked:handling:gen-target\n' > "$dir/valid-marker-target"
  local bad_kind
  for bad_kind in empty corrupt symlink; do
    rm -f "$state/.watcher-down"
    case "$bad_kind" in
      empty) : > "$state/.watcher-down" ;;
      corrupt) printf 'not-a-valid-token\n' > "$state/.watcher-down" ;;
      symlink) ln -s "$dir/valid-marker-target" "$state/.watcher-down" ;;
    esac
    : > "$state/.wake-queue"
    rc=0
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" ack-already-drained || rc=$?
    expect_code 1 "$rc" "ack-already-drained must fail closed on $bad_kind .watcher-down"
    rc=0
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat || rc=$?
    expect_code 1 "$rc" "auto-ack-noop-heartbeat (empty queue) must fail closed on $bad_kind .watcher-down"
    append_wake "$state" heartbeat heartbeat heartbeat
    rc=0
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat || rc=$?
    expect_code 1 "$rc" "auto-ack-noop-heartbeat (heartbeat row) must fail closed on $bad_kind .watcher-down"
    [ -s "$state/.wake-queue" ] || fail "auto-ack-noop-heartbeat consumed queue on $bad_kind .watcher-down"
  done
  rm -f "$state/.watcher-down"

  # 3c4. Concurrent marker rotation causing fm_recovery_marker_ack failure MUST return 1.
  : > "$state/.wake-queue"
  printf 'announced:handling:gen-old\n' > "$state/.watcher-down"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1"
    fm_recovery_marker_ack() {
      printf "pending:downtime:gen-rotated\n" > "$1"
      _fm_recovery_marker_ack "$@"
    }
    fm_change_ack_already_drained "$2"
  ' _ "$DETECT" "$state" || rc=$?
  expect_code 1 "$rc" "fm_change_ack_already_drained must fail closed when ack fails on rotated generation"
  grep -Fq 'pending:downtime:gen-rotated' "$state/.watcher-down" \
    || fail "rotated recovery marker was overwritten during ack-already-drained"

  append_wake "$state" heartbeat heartbeat heartbeat
  printf 'announced:handling:gen-old2\n' > "$state/.watcher-down"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1"
    fm_recovery_marker_ack() {
      printf "pending:downtime:gen-rotated2\n" > "$1"
      _fm_recovery_marker_ack "$@"
    }
    fm_change_auto_ack_noop_heartbeat "$2"
  ' _ "$DETECT" "$state" || rc=$?
  expect_code 1 "$rc" "fm_change_auto_ack_noop_heartbeat must fail closed when ack fails on rotated generation"
  grep -Fq 'pending:downtime:gen-rotated2' "$state/.watcher-down" \
    || fail "rotated recovery marker was overwritten during auto-ack-noop-heartbeat"
  rm -f "$state/.watcher-down"

  # 3d. Expired paused: ... until <past> with unchanged digest & EOF marker -> refused!
  local past_iso
  past_iso=$(date -u -r "$(( $(date +%s) - 120 ))" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
    || date -u -d "@$(( $(date +%s) - 120 ))" '+%Y-%m-%dT%H:%MZ')
  printf 'paused: waiting on timer until %s\n' "$past_iso" > "$state/alpha.status"
  mark_status_seen "$state" "$state/alpha.status"
  mark_hb_surfaced "$state" alpha
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" mark-reviewed || fail "mark-reviewed failed for paused until test"
  append_wake "$state" heartbeat heartbeat heartbeat
  rm -f "$state/.watcher-down"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" check --heartbeat >/dev/null || rc=$?
  expect_code 1 "$rc" "check --heartbeat must report changed when paused until expired"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat || rc=$?
  expect_code 1 "$rc" "auto-ack-noop-heartbeat must refuse when paused until expired"
  [ -s "$state/.wake-queue" ] || fail "expired-paused heartbeat was wrongly consumed"
  : > "$state/.wake-queue"
  printf 'working: building\n' > "$state/alpha.status"
  mark_status_seen "$state" "$state/alpha.status"
  mark_hb_surfaced "$state" alpha
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" mark-reviewed || fail "mark-reviewed restore failed"
  append_wake "$state" heartbeat heartbeat heartbeat
  rm -f "$state/.watcher-down"

  # 4. Pure heartbeat after a real actionable status change -> refused!
  printf 'failed: unit tests broke\n' >> "$state/alpha.status"
  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DETECT" auto-ack-noop-heartbeat || rc=$?
  expect_code 1 "$rc" "auto-ack-noop-heartbeat must refuse after a real status failure"
  [ -s "$state/.wake-queue" ] || fail "changed-fleet heartbeat was wrongly consumed"
  pass "drain ack records reviewed digest and auto-ack-noop-heartbeat consumes only true no-op heartbeats"
}

# --- Cases (d) & (e) at the Pi extension pre-delivery boundary --------------

test_pi_extension_skips_already_drained_and_noop_heartbeat_but_delivers_real_wakes() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-zero-token-root"
  home="$TMP_ROOT/pi-zero-token-home"
  log="$TMP_ROOT/pi-zero-token.log"
  stop="$TMP_ROOT/pi-zero-token.stop"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state" "$home/config"
  mkdir -p "$repo/node_modules/@earendil-works/pi-coding-agent" \
           "$repo/node_modules/@earendil-works/pi-tui" \
           "$repo/node_modules/typebox"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-change-detect.sh" "$repo/bin/fm-change-detect.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$repo/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$repo/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-pr-lib.sh" "$repo/bin/fm-pr-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-lock-lib.sh" "$repo/bin/fm-lock-lib.sh"
  cp "$ROOT/bin/fm-marker-lib.sh" "$repo/bin/fm-marker-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$repo/bin/fm-path-lib.sh"
  chmod +x "$repo/bin"/*.sh
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent { render() { return []; } invalidate() {} }
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box { constructor() {} setBgFn() {} clear() {} addChild() {} }
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = { Object: () => ({}) };
JS

  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf '%s\n' "${FM_TEST_CLOSE_LINE:?}"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-gen\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  # Seed one clean task and mark its digest reviewed.
  printf 'window=test:fm-alpha\nproject=/projects/demo\nkind=ship\n' > "$home/state/alpha.meta"
  printf 'working: step 1\n' > "$home/state/alpha.status"
  mark_status_seen "$home/state" "$home/state/alpha.status"
  mark_hb_surfaced "$home/state" alpha
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DETECT" mark-reviewed || fail "mark-reviewed failed"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
    FM_WATCH_EXTENSION_LOG_KEEP_LINES=50 node --input-type=module 2>&1 <<'EOF'
import { mkdirSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";

const home = process.env.FM_HOME;
const state = `${home}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);

async function runCase(name, closeLine, queueContent, setup = () => {}) {
  writeFileSync(process.env.FM_ARM_LOG, "");
  try { unlinkSync(process.env.FM_STOP_FILE); } catch {}
  try { unlinkSync(`${state}/.watcher-down`); } catch {}
  try { unlinkSync(`${state}/.watch-extension.log`); } catch {}
  writeFileSync(`${state}/.wake-queue`, queueContent);
  setup();
  process.env.FM_TEST_CLOSE_LINE = closeLine;
  const offers = [];
  const mainPrompts = [];
  let tool = null;
  const handlers = new Map();
  const bus = {
    on(ch, fn) { handlers.set(ch, [...(handlers.get(ch) ?? []), fn]); return () => {}; },
    emit(ch, data) { for (const fn of handlers.get(ch) ?? []) fn(data); },
  };
  bus.on("fm-branch-supervision:dispatch", (offer) => {
    offers.push(offer);
    if (offer.eligible) offer.accept();
  });
  const pi = {
    on() {},
    events: bus,
    registerCommand() {},
    registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
    sendUserMessage: async (msg) => { mainPrompts.push(msg); },
  };
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?case=${name}`);
  mod.default(pi);
  await tool.execute(`arm-${name}`, {}, undefined, undefined, {});
  for (let i = 0; i < 200; i += 1) {
    const arms = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((r) => r.startsWith("arm=")).length;
    const ext = (() => { try { return readFileSync(`${state}/.watch-extension.log`, "utf8"); } catch { return ""; } })();
    if (arms >= 2 && (offers.length > 0 || mainPrompts.length > 0 || ext.includes("absorbed wake reason="))) break;
    await new Promise((r) => setTimeout(r, 15));
  }
  writeFileSync(process.env.FM_STOP_FILE, "stop\n");
  await new Promise((r) => setTimeout(r, 50));
  return {
    offers,
    mainPrompts,
    queueAfter: readFileSync(`${state}/.wake-queue`, "utf8"),
    extLog: (() => { try { return readFileSync(`${state}/.watch-extension.log`, "utf8"); } catch { return ""; } })(),
    watcherDown: (() => { try { return readFileSync(`${state}/.watcher-down`, "utf8").trim(); } catch { return ""; } })(),
  };
}

// 1. Already-drained wake queue on a signal close with announced:handling:* -> zero LLM turns AND retires handling marker!
const drained = await runCase("already-drained", `signal: ${state}/alpha.status`, "", () => {
  writeFileSync(`${state}/.watcher-down`, "announced:handling:fixture-gen\n");
});
if (drained.offers.length !== 0 || drained.mainPrompts.length !== 0) {
  throw new Error(`already-drained signal woke an LLM: offers=${drained.offers.length} main=${drained.mainPrompts.length}`);
}
if (!drained.extLog.includes("absorbed wake reason=already-drained")) {
  throw new Error(`expected already-drained absorption log, got: ${drained.extLog}`);
}
if (drained.watcherDown !== "acked:handling:fixture-gen") {
  throw new Error(`already-drained left .watcher-down un-acked: ${drained.watcherDown}`);
}

// 1b. Pure heartbeat with pending:downtime:* MUST deliver (never swallowed)!
const pendingDowntimeHb = await runCase("pending-downtime-hb", "heartbeat", "1\t10\theartbeat\theartbeat\theartbeat\n", () => {
  writeFileSync(`${state}/.watcher-down`, "pending:downtime:dt-gen\n");
});
if (pendingDowntimeHb.offers.length !== 1 || pendingDowntimeHb.queueAfter.trim() === "") {
  throw new Error(`pending:downtime heartbeat was wrongly swallowed: offers=${pendingDowntimeHb.offers.length} queue=${pendingDowntimeHb.queueAfter}`);
}

// 2. Pure no-op heartbeat with reviewed digest -> auto-acked, zero LLM turns!
const noopHb = await runCase("noop-hb", "heartbeat", "1\t1\theartbeat\theartbeat\theartbeat\n");
if (noopHb.offers.length !== 0 || noopHb.mainPrompts.length !== 0) {
  throw new Error(`no-op heartbeat woke an LLM: offers=${noopHb.offers.length} main=${noopHb.mainPrompts.length}`);
}
if (noopHb.queueAfter.trim() !== "") {
  throw new Error(`no-op heartbeat was not auto-acked from queue: ${noopHb.queueAfter}`);
}
if (!noopHb.extLog.includes("absorbed wake reason=noop-heartbeat")) {
  throw new Error(`expected noop-heartbeat absorption log, got: ${noopHb.extLog}`);
}

// 3. check: rearm-resurface on empty queue MUST still deliver to main!
const rearm = await runCase("rearm-resurface", "check: rearm-resurface", "");
if (rearm.mainPrompts.length !== 1) {
  throw new Error(`rearm-resurface was wrongly absorbed: main=${rearm.mainPrompts.length}`);
}

// 4. Heartbeat after a real status failure MUST deliver (digest changed)!
const changedHb = await runCase("changed-hb", "heartbeat", "1\t2\theartbeat\theartbeat\theartbeat\n", () => {
  writeFileSync(`${state}/alpha.status`, "working: step 1\nfailed: build broke\n");
});
if (changedHb.offers.length !== 1) {
  throw new Error(`changed heartbeat did not reach branch/main: offers=${changedHb.offers.length} main=${changedHb.mainPrompts.length}`);
}

// 5. Real needs-decision signal MUST reach main!
const decision = await runCase(
  "real-decision",
  `signal: ${state}/alpha.status`,
  `1\t3\tsignal\talpha.status\tneeds-decision: ${state}/alpha.status\n`,
);
if (decision.mainPrompts.length !== 1) {
  throw new Error(`real needs-decision did not wake main: main=${decision.mainPrompts.length}`);
}

// 6. Direct preDeliveryZeroChangeCheck fail-closed behavior on corrupt/empty/symlink/unackable markers
//    even when bin/fm-change-detect.sh is absent.
const dispatch = await import(pathToFileURL(`${dirname(process.env.PLUGIN)}/lib/fm-branch-dispatch.ts`).href);
const noDetectRoot = `${home}/no-detect-root`;
mkdirSync(noDetectRoot, { recursive: true });
const emptyScope = {
  status: "empty",
  eligible: false,
  projects: [],
  eligibleSeqs: [],
  eligibleTasks: [],
  corrupted: false,
  needsDecisionKeys: [],
  checkSeqs: [],
  heartbeatSeqs: [],
  totalRows: 0,
  taskByWakeKey: {},
};
writeFileSync(`${home}/valid-marker`, "acked:handling:gen-sym\n");
for (const [label, prep] of [
  ["empty", () => writeFileSync(`${state}/.watcher-down`, "")],
  ["corrupt", () => writeFileSync(`${state}/.watcher-down`, "garbage\n")],
  ["missing-newline", () => writeFileSync(`${state}/.watcher-down`, "acked:handling:gen-1")],
  ["symlink", () => symlinkSync(`${home}/valid-marker`, `${state}/.watcher-down`)],
  ["unackable-handling", () => writeFileSync(`${state}/.watcher-down`, "announced:handling:gen-2\n")],
  ["pending-downtime", () => writeFileSync(`${state}/.watcher-down`, "pending:downtime:gen-3\n")],
]) {
  try { unlinkSync(`${state}/.watcher-down`); } catch {}
  prep();
  const verdict = await dispatch.preDeliveryZeroChangeCheck(state, `signal: ${state}/alpha.status`, emptyScope, noDetectRoot, home);
  if (verdict !== "deliver") {
    throw new Error(`preDeliveryZeroChangeCheck failed open on ${label} marker without detect script: got ${verdict}`);
  }
}
try { unlinkSync(`${state}/.watcher-down`); } catch {}
writeFileSync(`${state}/.watcher-down`, "acked:handling:gen-ok\n");
const ackedVerdict = await dispatch.preDeliveryZeroChangeCheck(state, `signal: ${state}/alpha.status`, emptyScope, noDetectRoot, home);
if (ackedVerdict !== "already-drained") {
  throw new Error(`preDeliveryZeroChangeCheck rejected valid acked:handling marker: got ${ackedVerdict}`);
}
try { unlinkSync(`${state}/.watcher-down`); } catch {}

process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi pre-delivery zero-change gate test failed: $out"
  pass "Pi watcher extension skips already-drained wakes and no-op heartbeats while delivering real wakes"
}

test_turnend_paused_worker_absorbed_and_expired_until_surfaces
test_turnend_captain_held_and_pr_ready_parked_absorbed_unless_actionable
test_stale_on_pr_ready_parked_absorbs_pane_ticks_while_unarmed_surfaces
test_push_transition_on_pr_ready_parked_absorbs
test_inactive_reconcile_skips_pr_ready_and_presented_but_catches_silent
test_teardown_prune_removes_merged_and_inactive_outcome_rows_for_task_only
test_fleet_digest_determinism_and_change_sensitivity
test_drain_ack_records_digest_and_auto_ack_noop_heartbeat
test_pi_extension_skips_already_drained_and_noop_heartbeat_but_delivers_real_wakes
echo "all deterministic zero-token change detection tests passed"
