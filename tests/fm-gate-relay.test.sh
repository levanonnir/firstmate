#!/usr/bin/env bash
# Gate relay: a remote home's no-mistakes gate runs on the primary, queues while
# the primary is offline, and never falls back to the remote host.
# Real fm-gate-spool.sh and fm-gate-runner.sh run against fake no-mistakes, a fake
# fm-on.sh that stands in for the SSH hop, and a fake ssh for the branch fetch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gate-relay)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
fm_git_identity

SB="$TMP_ROOT/sandbox"             # the primary's code root: real scripts plus a fake fm-on.sh
MAC="$TMP_ROOT/mac"                # the primary's home
REMOTE="$TMP_ROOT/remote-home"     # the remote second mate's home (queue lives here)
SRC="$TMP_ROOT/src"
WT="$TMP_ROOT/lenovo-wt"
FAKE="$TMP_ROOT/mac-bin"
TRAP_BIN="$TMP_ROOT/lenovo-bin"
OFFLINE="$TMP_ROOT/offline"
NM_LOG="$TMP_ROOT/nm.log"
LENOVO_NM_LOG="$TMP_ROOT/lenovo-nm.log"
mkdir -p "$SB/bin" "$MAC/data" "$MAC/config" "$MAC/state" "$MAC/projects" "$REMOTE/state" "$FAKE" "$TRAP_BIN"

for f in fm-gate-runner.sh fm-gate-spool.sh fm-project-mode.sh fm-secondmate-registry-lib.sh; do
  cp "$ROOT/bin/$f" "$SB/bin/$f"
done
cat > "$SB/bin/fm-on.sh" <<EOF
#!/bin/sh
stdin=closed
[ "\$1" = --stdin ] && { stdin=caller; shift; }
route=\$1; cmd=\$2; shift 2
[ "\$route" = lenovo-mate ] || exit 1
[ -f "$OFFLINE" ] && exit 255
[ "\$stdin" = closed ] && exec </dev/null
FM_HOME="$REMOTE" exec "$SB/bin/\$cmd" "\$@"
EOF
chmod +x "$SB"/bin/*.sh

# Fake ssh for the branch fetch: skip -o options and the host, run the command locally.
cat > "$TMP_ROOT/fakessh" <<'EOF'
#!/bin/sh
while [ "$1" = -o ]; do shift 2; done
shift
exec sh -c "$*"
EOF
chmod +x "$TMP_ROOT/fakessh"

# The primary's no-mistakes: records every call; `axi run` commits a fix and pushes it to origin.
cat > "$FAKE/no-mistakes" <<EOF
#!/bin/sh
stdin=
case " \$* " in *" --intent - "*) stdin=\$(cat) ;; esac
printf '%s|%s|%s\n' "\$PWD" "\$*" "\$stdin" >> "$NM_LOG"
case "\$1 \$2" in
  "init --skip-user-skill") git remote add no-mistakes "\$PWD/.git"; exit 0 ;;
  "axi run")
    branch=\$(git symbolic-ref --short HEAD)
    while [ -f "$TMP_ROOT/hold-run" ]; do sleep 0.1; done
    if [ -f "$TMP_ROOT/rebase-run" ]; then
      new=\$(git commit-tree -p HEAD~1 -m rebased "HEAD^{tree}")
      git push -q -f origin "\$new:refs/heads/\$branch"
      echo "\$new" > "$TMP_ROOT/rebased-sha"
      echo "status: gate-reached"; exit 0
    fi
    echo fix > pipeline-fix.txt; git add pipeline-fix.txt; git commit -qm "pipeline fix"
    git push -q origin "HEAD:refs/heads/\$branch"
    echo "status: gate-reached"; exit 0 ;;
  "axi respond") echo "respond refused" >&2; exit 3 ;;
esac
echo "ok \$*"
EOF
chmod +x "$FAKE/no-mistakes"
# What the remote host must never run: a trap, so any fallback is caught.
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 99\n' "$LENOVO_NM_LOG" > "$TRAP_BIN/no-mistakes"
chmod +x "$TRAP_BIN/no-mistakes"

fm_git_init_commit "$SRC"
fm_git_add_origin "$SRC" "$TMP_ROOT/origin.git"
ORIGIN="file://$TMP_ROOT/origin.git"
git clone -q "$ORIGIN" "$MAC/projects/petit-core"
git clone -q "$ORIGIN" "$WT"
git -C "$WT" checkout -q -b fm/t1
echo work > "$WT/work.txt"; git -C "$WT" add work.txt; git -C "$WT" commit -qm work
git -C "$WT" push -q origin fm/t1
WORK_SHA=$(git -C "$WT" rev-parse HEAD)

printf '%s\n' '- lenovo-mate - helper (host: lenovohost; root: /x; home: /y; scope: s; projects: petit-core; added 2026-11-19)' > "$MAC/data/secondmates.md"
printf '%s\n' '- petit-core [no-mistakes] - core (added 2026-08-12)' > "$MAC/data/projects.md"
printf '# gates served here\nlenovo-mate\n' > "$MAC/config/gate-relay"

RUNNER_ID="gate-runner@$(hostname -s 2>/dev/null || echo primary)"
runner() { ( cd "$MAC" && env PATH="$FAKE:$PATH" FM_HOME="$MAC" GIT_SSH_COMMAND="$TMP_ROOT/fakessh" FM_GATE_RUNNER_INTERVAL=1 "$SB/bin/fm-gate-runner.sh" "$@" ) ; }
spool() { env FM_HOME="$REMOTE" "$SB/bin/fm-gate-spool.sh" "$@"; }
# Worker-side call, in its worktree, with the trap nm first on PATH. Backgrounded by callers that expect to wait.
client() { ( cd "$WT" && env PATH="$TRAP_BIN:$PATH" FM_HOME="$REMOTE" FM_GATE_POLL=0.2 "$SB/bin/fm-gate-spool.sh" nm --project petit-core -- "$@" ); }
wait_for() { local n=0; while ! "$@" 2>/dev/null; do n=$((n + 1)); [ "$n" -lt 100 ] || return 1; sleep 0.1; done; }
queued_count() { find "$REMOTE/state/gate-spool/queued" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
delivered_count() { find "$REMOTE/state/gate-spool/delivered" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
queued_is() { [ "$(queued_count)" = "$1" ]; }

# --- 1. Mac offline: the request queues and nothing runs anywhere -------------
: > "$OFFLINE"
client axi run --intent "ship the gate relay" > "$TMP_ROOT/c1.out" 2> "$TMP_ROOT/c1.err" &
C1=$!
wait_for queued_is 1 || fail "the worker's request was not queued while the primary is offline"
runner once 2> "$TMP_ROOT/offline-run.err" || fail "an offline poll must not fail the runner"
queued_is 1 || fail "the request must stay queued while the primary is unreachable"
kill -0 "$C1" 2>/dev/null || fail "the worker must keep waiting while the primary is offline"
[ ! -s "$NM_LOG" ] || fail "no gate may run while the primary is offline"
[ ! -s "$LENOVO_NM_LOG" ] || fail "the remote host must never run no-mistakes itself"
assert_grep 'no local fallback' "$TMP_ROOT/c1.err" "the queued worker must say there is no local fallback"
pass "offline primary: request queues, worker waits, nothing runs, no remote fallback"

# --- 2. Only listed routes are served ----------------------------------------
rm -f "$OFFLINE"
printf 'some-other-mate\n' > "$MAC/config/gate-relay"
runner once 2>/dev/null
queued_is 1 || fail "a route absent from config/gate-relay must not be served (queued=$(queued_count): $(find "$REMOTE/state/gate-spool" -maxdepth 2 | tr "\n" " "))"
printf '# gates served here\nlenovo-mate\n' > "$MAC/config/gate-relay"
pass "only routes named in config/gate-relay are served"

# --- 3. Primary back: the queued request runs on the primary ------------------
runner once 2> "$TMP_ROOT/online-run.err" || fail "runner once failed: $(cat "$TMP_ROOT/online-run.err")"
wait "$C1"; C1_RC=$?
assert_equals 0 "$C1_RC" "worker exit status"
assert_contains "$(cat "$TMP_ROOT/c1.out")" "status: gate-reached" "expected text"
RUN_LINE=$(grep '|axi run --intent -|' "$NM_LOG") || fail "the primary never ran axi run: $(cat "$NM_LOG" 2>/dev/null)"
case "$RUN_LINE" in "$MAC/state/gate-runner/wt/petit-core/"*"|axi run --intent -|ship the gate relay") ;; *) fail "unexpected gate run: $RUN_LINE" ;; esac
assert_contains "$(cat "$NM_LOG")" "init --skip-user-skill" "expected text"
assert_equals 1 "$(delivered_count)" "delivered requests"
PRIMARY_WT=${RUN_LINE%%|*}
git -C "$PRIMARY_WT" merge-base --is-ancestor "$WORK_SHA" HEAD || fail "the primary's worktree does not hold the worker's commit"
assert_equals "$(git -C "$WT" rev-parse origin/fm/t1)" "$(git -C "$WT" rev-parse HEAD)" "worker branch fast-forwarded to the pipeline head"
[ -f "$WT/pipeline-fix.txt" ] || fail "the pipeline's fix commit did not reach the worker's copy"
[ ! -s "$LENOVO_NM_LOG" ] || fail "the remote host must never run no-mistakes itself"
pass "primary back: the gate ran on the primary and the worker received its output and the pipeline head"

# --- 4. Exit status and stderr pass through; reads reuse the branch's worktree -
client axi respond --action approve > "$TMP_ROOT/c4.out" 2> "$TMP_ROOT/c4.err" &
C4=$!
wait_for queued_is 1 || fail "respond was not queued"
runner once 2>/dev/null
wait "$C4"; C4_RC=$?
assert_equals 3 "$C4_RC" "respond exit status"
assert_contains "$(cat "$TMP_ROOT/c4.err")" "respond refused" "expected text"
grep -q "^$PRIMARY_WT|axi respond --action approve|" "$NM_LOG" || fail "respond must run in the branch's worktree on the primary"
pass "gate exit status and stderr pass through unchanged"

# --- 5. An identical request is reattached, never duplicated -------------------
: > "$OFFLINE"
client axi status > /dev/null 2>&1 &
D1=$!
wait_for queued_is 1 || fail "status was not queued"
client axi status > /dev/null 2> "$TMP_ROOT/dup.err" &
D2=$!
wait_for grep -q reattached "$TMP_ROOT/dup.err" || fail "an identical request must reattach"
queued_is 1 || fail "an identical request must not be queued twice"
rm -f "$OFFLINE"
runner once 2>/dev/null
wait "$D1" "$D2" || true
queued_is 0 || fail "the deduplicated request was not served"
pass "an identical in-flight request reattaches instead of duplicating"

# --- 6. Refusals ----------------------------------------------------------------
for refused in "axi run --yes" "axi run -y" "daemon restart" "init" "eject" "axi sync"; do
  # shellcheck disable=SC2086 # the words are the test input
  client $refused > /dev/null 2> "$TMP_ROOT/refuse.err" && fail "'$refused' must be refused"
  queued_is 0 || fail "'$refused' must not reach the queue"
done
assert_contains "$(client axi respond --yes 2>&1 || true)" "banned fleet-wide" "expected text"
pass "--yes and non-gate verbs are refused before anything is queued"

git -C "$WT" checkout -q -b release/not-a-task-branch
client axi status > "$TMP_ROOT/c6.out" 2> "$TMP_ROOT/c6.err" &
C6=$!
wait_for queued_is 1 || fail "off-prefix request was not queued"
runner once 2>/dev/null
wait "$C6"; C6_RC=$?
assert_equals 64 "$C6_RC" "off-prefix branch exit status"
assert_contains "$(cat "$TMP_ROOT/c6.err")" "registered ship-branch prefix" "expected text"
git -C "$WT" checkout -q fm/t1
pass "the primary refuses a branch outside the project's ship-branch prefix"

# --- 7. A dead runner's claimed work is reconciled ------------------------------
: > "$OFFLINE"
client axi status > "$TMP_ROOT/c7a.out" 2>/dev/null &
C7A=$!
wait_for queued_is 1 || fail "orphan fixture: status not queued"
ID_A=$(spool pending | awk -F'\t' '{print $1}')
spool claim "$ID_A" "$RUNNER_ID"
client axi respond --action approve > "$TMP_ROOT/c7b.out" 2>"$TMP_ROOT/c7b.err" &
C7B=$!
wait_for queued_is 1 || fail "orphan fixture: respond not queued"
ID_B=$(spool pending | awk -F'\t' '{print $1}')
spool claim "$ID_B" "$RUNNER_ID"
mkdir -p "$MAC/state/gate-runner/req/lenovo-mate.$ID_B"; : > "$MAC/state/gate-runner/req/lenovo-mate.$ID_B/exec"
rm -f "$OFFLINE"
runner once 2>/dev/null
wait "$C7A"; assert_equals 0 "$?" "a released read-only request is served after reconciliation"
wait "$C7B"; assert_equals 75 "$?" "an answer that may have been applied is failed, not repeated"
assert_contains "$(cat "$TMP_ROOT/c7b.err")" "before confirming" "expected text"
pass "a request orphaned by a dead runner is re-served when safe and failed when not"

# --- 9. A project outside the route's registered projects is refused -----------
git clone -q "$ORIGIN" "$MAC/projects/other-proj"
printf '%s\n' '- other-proj [no-mistakes] - other (added 2026-08-12)' >> "$MAC/data/projects.md"
( cd "$WT" && env PATH="$TRAP_BIN:$PATH" FM_HOME="$REMOTE" FM_GATE_POLL=0.2 "$SB/bin/fm-gate-spool.sh" nm --project other-proj -- axi run ) > "$TMP_ROOT/c9.out" 2> "$TMP_ROOT/c9.err" &
C9=$!
wait_for queued_is 1 || fail "foreign-project request was not queued"
runner once 2>/dev/null
wait "$C9"; assert_equals 64 "$?" "foreign project exit status"
assert_contains "$(cat "$TMP_ROOT/c9.err")" "not among the projects registered" "expected text"
pass "the primary refuses a project the route is not registered for"

# --- 10. A stale unread result never satisfies a later gate ----------------------
# The subshell execs the script, so ORPHAN is its pid and killing it leaves its finished result unread.
orphan_client() { ( cd "$WT" && exec env PATH="$TRAP_BIN:$PATH" FM_HOME="$REMOTE" FM_GATE_POLL=30 "$SB/bin/fm-gate-spool.sh" nm --project petit-core -- "$@" ) > /dev/null 2>&1 & ORPHAN=$!; }
kill_orphan() { kill -9 "$ORPHAN" 2>/dev/null; wait "$ORPHAN" 2>/dev/null || true; ! kill -0 "$ORPHAN" 2>/dev/null || fail "the orphaned waiter survived"; }
done_count() { find "$REMOTE/state/gate-spool/done" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
done_is() { [ "$(done_count)" = "$1" ]; }
orphan_client axi respond --action approve
wait_for queued_is 1 || fail "stale-answer fixture: respond not queued"
runner once 2>/dev/null
wait_for done_is 1 || fail "stale-answer fixture: respond did not finish"
kill_orphan
client axi status > /dev/null 2>&1 &
S1=$!
wait_for queued_is 1 || fail "a request after the stale answer was not queued"
runner once 2>/dev/null
wait "$S1"
RESPONDS_BEFORE=$(grep -c '|axi respond --action approve|' "$NM_LOG")
client axi respond --action approve > "$TMP_ROOT/c10.out" 2> "$TMP_ROOT/c10.err" &
C10=$!
wait_for queued_is 1 || fail "the next gate's answer must be queued, not satisfied by the stale result (got: $(cat "$TMP_ROOT/c10.err"))"
runner once 2>/dev/null
wait "$C10"
assert_equals "$((RESPONDS_BEFORE + 1))" "$(grep -c '|axi respond --action approve|' "$NM_LOG")" "the new answer must reach the primary"
rm -rf "$REMOTE/state/gate-spool/done"/*
orphan_client axi status
wait_for queued_is 1 || fail "read fixture: status not queued"
runner once 2>/dev/null
wait_for done_is 1 || fail "read fixture: status did not finish"
kill_orphan
client axi status > /dev/null 2>&1 &
S2=$!
wait_for queued_is 1 || fail "a repeated read must run fresh, not reattach to a finished result"
runner once 2>/dev/null
wait "$S2"
pass "a finished unread result is not reattached to a later gate or to a read"

# --- 11. Reads and abort pass a running gate; another answer waits for it ------
: > "$TMP_ROOT/hold-run"
client axi run > /dev/null 2>&1 &
R11=$!
wait_for queued_is 1 || fail "active-run fixture: run not queued"
runner once 2>/dev/null &
RUNNER11=$!
wait_for grep -q '|axi run|' "$NM_LOG" || fail "active-run fixture: run did not start"
client axi status > "$TMP_ROOT/c11s.out" 2>/dev/null &
S11=$!
client axi abort > "$TMP_ROOT/c11a.out" 2>/dev/null &
A11=$!
wait_for queued_is 2 || fail "active-run fixture: status and abort not queued"
client axi respond --action approve > /dev/null 2>&1 &
P11=$!
wait_for queued_is 3 || fail "active-run fixture: respond not queued"
runner once 2>/dev/null
wait "$S11"; assert_equals 0 "$?" "a read while a run is active"
wait "$A11"; assert_equals 0 "$?" "an abort while a run is active"
assert_contains "$(cat "$TMP_ROOT/c11a.out")" "ok axi abort" "expected text"
queued_is 1 || fail "a second gate-changing request must wait for the active run"
kill -0 "$R11" 2>/dev/null || fail "the held run must still be active"
rm -f "$TMP_ROOT/hold-run"
wait "$RUNNER11" "$R11"
runner once 2>/dev/null
wait "$P11" || true
queued_is 0 || fail "the held answer was not served after the run"
pass "reads and abort run while a gate run is active; another answer waits"

# --- 12. Following a rebasing pipeline, never a stale origin head ----------------
: > "$TMP_ROOT/rebase-run"
client axi run > /dev/null 2>&1 &
S12=$!
wait_for queued_is 1 || fail "rebase fixture: run not queued"
runner once 2>/dev/null
wait "$S12"
rm -f "$TMP_ROOT/rebase-run"
REBASED=$(cat "$TMP_ROOT/rebased-sha")
assert_equals "$REBASED" "$(git -C "$WT" rev-parse HEAD)" "worker follows a head the pipeline rebased during the request"
client axi run > "$TMP_ROOT/c12.out" 2> "$TMP_ROOT/c12.err" &
S12=$!
wait_for queued_is 1 || fail "rerun fixture: run not queued"
runner once 2>/dev/null
wait "$S12"; assert_equals 0 "$?" "re-running at the pushed head is not refused ($(cat "$TMP_ROOT/c12.err"))"
git -C "$WT" commit -q --amend -m "worker amend"
AMENDED=$(git -C "$WT" rev-parse HEAD)
client axi status > /dev/null 2> "$TMP_ROOT/c12s.err" &
S12=$!
wait_for queued_is 1 || fail "stale fixture: status not queued"
runner once 2>/dev/null
wait "$S12"
assert_equals "$AMENDED" "$(git -C "$WT" rev-parse HEAD)" "an unchanged origin head must not replace the worker's own rewrite"
assert_contains "$(cat "$TMP_ROOT/c12s.err")" "diverged" "expected text"
pass "a worker follows a rebase pushed during its request and keeps its own rewrites otherwise"

# --- 13. An abort queued while the primary sleeps cancels the queued run ---------
: > "$OFFLINE"
RUNS_BEFORE=$(grep -c '|axi run' "$NM_LOG")
client axi run --intent "torn-down task" > "$TMP_ROOT/c13r.out" 2> "$TMP_ROOT/c13r.err" &
R13=$!
wait_for queued_is 1 || fail "sleep fixture: run not queued"
client axi abort > "$TMP_ROOT/c13a.out" 2>/dev/null &
A13=$!
wait "$R13"; assert_equals 75 "$?" "a queued run cancelled by a later abort"
assert_contains "$(cat "$TMP_ROOT/c13r.err")" "cancelled by a later axi abort" "expected text"
queued_is 1 || fail "only the abort should remain queued"
rm -f "$OFFLINE"
runner once 2>/dev/null
wait "$A13"; assert_equals 0 "$?" "the abort is served once the primary is back"
assert_equals "$RUNS_BEFORE" "$(grep -c '|axi run' "$NM_LOG")" "no pipeline may start for the cancelled task"
pass "an abort queued while the primary sleeps cancels the branch's queued run"

# --- 8. Service definition ----------------------------------------------------------
PLIST=$(runner install --print)
assert_contains "$PLIST" "dev.firstmate.gate-runner" "expected text"
assert_contains "$PLIST" "<string>$MAC</string>" "expected text"
assert_contains "$PLIST" "<string>serve</string>" "expected text"
assert_contains "$PLIST" "<key>RunAtLoad</key>" "expected text"
pass "the LaunchAgent definition keeps the runner alive from this home"
