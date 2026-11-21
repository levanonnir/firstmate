#!/usr/bin/env bash
# Run a remote home's no-mistakes gate on this primary machine.
#
# Usage:
#   fm-gate-runner.sh serve            long-lived loop: poll, run, report (what the LaunchAgent runs)
#   fm-gate-runner.sh once             one poll, run every claimable request to the end, report
#   fm-gate-runner.sh status           last poll time, running requests, and configured routes
#   fm-gate-runner.sh install [--print]  write and load the macOS LaunchAgent (--print only shows it)
#
# docs/remote-secondmates.md ("Gate on the primary") owns the design. A remote
# second mate's workers queue gate requests in their own home with
# bin/fm-gate-spool.sh; this runner is the only consumer. config/gate-relay lists
# the remote second-mate ids whose gate this primary serves, one per line, so a
# home that is not listed is never served. Every poll, claim, and result goes
# through fm-on.sh, so the primary reaches out over the existing SSH route and
# the remote host never gets any access to this machine. A sleeping or offline
# primary simply stops polling: requests stay queued on the remote host and are
# served in order when it returns, one gate-changing request (axi run, respond,
# answer, retry, handoff) at a time per branch; reads and axi abort go straight through. There is no fallback to the remote host.
#
# Per request the runner validates it again (project clone present under
# projects/, branch inside the project's registered ship-branch prefix, verb and
# flags through fm-gate-spool.sh check), fetches the worker's branch from the
# remote worktree over ssh with forwarding disabled, keeps one clone per project
# and one worktree per branch under state/gate-runner/, runs the same
# no-mistakes arguments there, and sends the stdout, stderr, and exit status back
# as the request's result. A result that cannot be delivered is kept and re-sent
# on later polls. A request left claimed by a dead runner is released when it had
# not started, or when its verb is safe to reattach (run, status, runs, logs,
# rounds); an answer that may already have been applied is failed with exit 75
# rather than sent twice.
#
# Environment: FM_GATE_RUNNER_INTERVAL (poll seconds, default 20),
# FM_GATE_RUNNER_MAX (concurrent requests, default 3), GIT_SSH_COMMAND (the
# hardened default disables agent and port forwarding).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RUN="${FM_GATE_RUNNER_STATE:-$FM_HOME/state/gate-runner}"
INTERVAL="${FM_GATE_RUNNER_INTERVAL:-20}"
MAX_INFLIGHT="${FM_GATE_RUNNER_MAX:-3}"
CAP_BYTES=200000
RUNNER_ID="gate-runner@$(hostname -s 2>/dev/null || echo primary)"
LABEL=dev.firstmate.gate-runner

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

log() { printf '%s fm-gate-runner: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; }
die() { printf 'fm-gate-runner: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

umask 077
b64() { base64 | tr -d '\n'; }
unb64() { base64 --decode 2>/dev/null || base64 -D; }
on() { "$SCRIPT_DIR/fm-on.sh" "$@"; }
spool() { on "$1" fm-gate-spool.sh "${@:2}"; }

routes() {
  [ -f "$CONFIG/gate-relay" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$CONFIG/gate-relay" | grep -v '^$' || true
}

route_field() { # <id> <host|projects>
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] && [ "$SECONDMATE_REGISTRY_ID" = "$1" ]; then
      case "$2" in host) printf '%s\n' "$SECONDMATE_REGISTRY_HOST" ;; projects) printf '%s\n' "$SECONDMATE_REGISTRY_PROJECTS" ;; esac
      return 0
    fi
  done < "$DATA/secondmates.md"
  return 1
}

route_host() { route_field "$1" host; }

route_serves_project() { # <id> <project>
  local entry
  entry=$(route_field "$1" projects) || return 1
  case ",$(printf '%s' "$entry" | tr -d '[:space:]')," in *",$2,"*) return 0 ;; esac
  return 1
}

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

inflight_count() {
  local d n=0
  for d in "$RUN/req"/*; do
    [ -d "$d" ] && pid_alive "$(cat "$d/pid" 2>/dev/null || true)" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

with_lock() { # <name> <command...>; the lock belongs to the request in $REQ_DIR
  local lock="$RUN/lock-$1" i=0 rc owner
  shift
  while ! mkdir "$lock" 2>/dev/null; do
    owner=$(cat "$lock/owner" 2>/dev/null || true)
    if pid_alive "$(cat "$owner/pid" 2>/dev/null || true)"; then
      i=0
    else
      i=$((i + 1)); [ "$i" -lt 3 ] || { rm -rf -- "$lock"; i=0; continue; }
    fi
    sleep 0.2
  done
  printf '%s\n' "$REQ_DIR" > "$lock/owner"
  rc=0; "$@" || rc=$?
  rm -rf -- "$lock"
  return "$rc"
}

# Compose the result frames fm-gate-spool.sh finish reads.
write_result() { # <request-dir> <rc> <out-file> <err-file>
  {
    printf 'rc=%s\n' "$2"
    printf 'out=%s\n' "$(tail -c "$CAP_BYTES" "$3" | b64)"
    printf 'err=%s\n' "$(tail -c "$CAP_BYTES" "$4" | b64)"
  } > "$1/result.tmp"
  mv "$1/result.tmp" "$1/result"
}

fail_request() { # <request-dir> <rc> <message>
  printf '%s\n' "$3" > "$1/err.txt"
  : > "$1/out.txt"
  write_result "$1" "$2" "$1/out.txt" "$1/err.txt"
}

safe_verb() { # <args...>: may be run again without side effects
  case "$1:${2:-}" in
    axi:|axi:run|axi:status|axi:logs|axi:rounds|runs:*|status:*) return 0 ;;
  esac
  return 1
}

meta_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

parse_argv() { # <base64> -> REQ_ARGS
  local arg
  REQ_ARGS=()
  while IFS= read -r -d '' arg; do REQ_ARGS+=("$arg"); done < <(printf '%s' "$1" | unb64)
}

ensure_clone() { # <project> <origin> -> prints the clone path
  local clone="$RUN/repo/$1"
  if [ ! -d "$clone/.git" ]; then
    mkdir -p "$RUN/repo"
    git clone --quiet -- "$2" "$clone" || return 1
  fi
  if ! git -C "$clone" remote get-url no-mistakes >/dev/null 2>&1; then
    (cd "$clone" && no-mistakes init --skip-user-skill) >&2 || return 1
  fi
  printf '%s\n' "$clone"
}

add_worktree() { # <clone> <project> <branch> <wt> <sha>
  mkdir -p "$RUN/wt/$2"
  git -C "$1" worktree prune
  git -C "$1" worktree add --quiet -B "$3" "$4" "$5"
}

prepare_worktree() { # <project> <branch> <sha> <route> <repo> <need-run> -> prints worktree path
  local project=$1 branch=$2 sha=$3 route=$4 repo=$5 need_run=$6 origin clone slug wt host ssh_cmd
  origin=$(git -C "$FM_HOME/projects/$project" remote get-url origin 2>/dev/null) || { echo "project $project has no clone with an origin on the primary" >&2; return 64; }
  clone=$(with_lock "clone-$project" ensure_clone "$project" "$origin") || { echo "could not prepare the primary's gate clone for $project" >&2; return 70; }
  slug=$(printf '%s' "$branch" | tr -c 'A-Za-z0-9._-' '-')-$(printf '%s' "$branch" | { shasum 2>/dev/null || sha1sum; } | cut -c1-8)
  wt="$RUN/wt/$project/$slug"
  if [ "$need_run" = 1 ]; then
    host=$(route_host "$route") || { echo "no remote route $route" >&2; return 64; }
    ssh_cmd=${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ForwardAgent=no -o ClearAllForwardings=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3}
    GIT_SSH_COMMAND=$ssh_cmd git -C "$clone" fetch --quiet -- "$host:$repo" "+refs/heads/$branch:refs/gate/$slug" >&2 \
      || { echo "could not fetch $branch from $route" >&2; return 70; }
    git -C "$clone" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "the worker branch no longer holds $sha" >&2; return 70; }
    if [ ! -d "$wt" ]; then
      with_lock "clone-$project" add_worktree "$clone" "$project" "$branch" "$wt" "$sha" >&2 || return 70
    elif ! git -C "$wt" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      if git -C "$clone" fetch --quiet origin "+refs/heads/$branch:refs/gate-origin/$slug" 2>/dev/null \
        && [ "$(git -C "$clone" rev-parse "refs/gate-origin/$slug")" != "$sha" ] \
        && git -C "$clone" merge-base --is-ancestor "$sha" "refs/gate-origin/$slug" 2>/dev/null; then
        echo "the pipeline already pushed a newer head for $branch than $sha; sync your branch to origin before running again" >&2
        return 70
      fi
      git -C "$wt" checkout --quiet -B "$branch" "$sha" >&2 || return 70
      git -C "$wt" reset --quiet --hard "$sha" >&2 || return 70
    fi
  else
    [ -d "$wt" ] || { echo "no gate run exists for $branch on the primary yet; start it with axi run" >&2; return 66; }
  fi
  printf '%s\n' "$wt"
}

send_result() { # <route> <id> <request-dir>
  local rc=0
  on --stdin "$1" fm-gate-spool.sh finish "$2" "$RUNNER_ID" < "$3/result" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0|3) rm -rf -- "$3" ;;   # delivered, or no longer ours to deliver
    *) log "result for $2 not delivered yet (exit $rc); kept for the next poll" ;;
  esac
}

run_request() { # <route> <id> <request-dir>; runs detached or inline
  local route=$1 id=$2 dir=$3 spec project branch sha repo prefix need_run=0 wt rc
  REQ_DIR=$dir
  if ! spec=$(spool "$route" show "$id" 2>/dev/null); then
    log "cannot read request $id from $route; leaving it claimed for reconciliation"
    rm -rf -- "$dir"
    return 0
  fi
  project=$(meta_field "$spec" project); branch=$(meta_field "$spec" branch)
  sha=$(meta_field "$spec" sha); repo=$(meta_field "$spec" repo)
  parse_argv "$(meta_field "$spec" argv_b64)"
  printf '%s' "$(meta_field "$spec" stdin_b64)" | unb64 > "$dir/stdin"
  if ! "$SCRIPT_DIR/fm-gate-spool.sh" check "${REQ_ARGS[@]}" 2> "$dir/err.txt"; then
    : > "$dir/out.txt"; write_result "$dir" 64 "$dir/out.txt" "$dir/err.txt"
  else
    case "$project" in ''|-*|*[!A-Za-z0-9._-]*) fail_request "$dir" 64 "unsafe project name"; project= ;; esac
    if [ -n "$project" ]; then
      prefix=$("$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$project" 2>/dev/null) || prefix=
      case "$branch" in "$prefix"?*) ;; *) prefix= ;; esac
      git check-ref-format --branch "$branch" >/dev/null 2>&1 || prefix=
      case "$repo" in /*) ;; *) prefix= ;; esac
      case "$sha" in ''|*[!0-9a-f]*) prefix= ;; esac
      if [ -z "$prefix" ] || [ -z "$branch" ]; then
        fail_request "$dir" 64 "refused: branch, repo, or head outside this project's registered ship-branch prefix"
      elif ! route_serves_project "$route" "$project"; then
        fail_request "$dir" 64 "refused: project $project is not among the projects registered for route $route"
      else
        [ "${REQ_ARGS[0]}:${REQ_ARGS[1]:-}" = axi:run ] && need_run=1
        rc=0
        wt=$(with_lock "$(printf '%s' "$project-$branch" | tr -c 'A-Za-z0-9._-' '-')" prepare_worktree "$project" "$branch" "$sha" "$route" "$repo" "$need_run" 2> "$dir/err.txt") || rc=$?
        if [ "$rc" -ne 0 ]; then
          : > "$dir/out.txt"; write_result "$dir" "$rc" "$dir/out.txt" "$dir/err.txt"
        else
          : > "$dir/exec"
          rc=0
          ( cd "$wt" && no-mistakes "${REQ_ARGS[@]}" < "$dir/stdin" ) > "$dir/out.txt" 2> "$dir/err.txt" || rc=$?
          write_result "$dir" "$rc" "$dir/out.txt" "$dir/err.txt"
        fi
      fi
    fi
  fi
  send_result "$route" "$id" "$dir"
}

# A request claimed by this runner that no live process owns: release it when it
# never started or is safe to reattach, otherwise fail it rather than answer twice.
reconcile_route() { # <route>
  local route=$1 id dir spec
  for id in $(spool "$route" claimed "$RUNNER_ID" 2>/dev/null || true); do
    dir="$RUN/req/$route.$id"
    pid_alive "$(cat "$dir/pid" 2>/dev/null || true)" && continue
    [ -f "$dir/result" ] && continue
    spec=$(spool "$route" show "$id" 2>/dev/null) || continue
    parse_argv "$(meta_field "$spec" argv_b64)"
    if [ ! -f "$dir/exec" ] || safe_verb "${REQ_ARGS[@]}"; then
      spool "$route" release "$id" "$RUNNER_ID" >/dev/null 2>&1 && rm -rf -- "$dir" && log "released orphaned request $id from $route"
    else
      mkdir -p "$dir"
      fail_request "$dir" 75 "the primary's gate runner stopped before confirming this answer was applied; check the gate state with axi status before answering again"
      send_result "$route" "$id" "$dir"
    fi
  done
}

resend_results() {
  local dir name route id
  for dir in "$RUN/req"/*; do
    [ -d "$dir" ] && [ -f "$dir/result" ] || continue
    pid_alive "$(cat "$dir/pid" 2>/dev/null || true)" && continue
    name=$(basename "$dir"); route=${name%.*}; id=${name##*.}
    send_result "$route" "$id" "$dir"
  done
}

serial_verb() { # <verb:subverb>: changes the gate, so runs one at a time per branch
  case "$1" in axi:run|axi:respond|axi:answer|axi:retry|axi:handoff) return 0 ;; esac
  return 1
}

branch_busy() { # <route> <branch>: a gate-changing request for it is already running
  local d
  for d in "$RUN/req/$1".*; do
    [ -d "$d" ] && [ "$(cat "$d/branch" 2>/dev/null || true)" = "$2" ] && pid_alive "$(cat "$d/pid" 2>/dev/null || true)" && return 0
  done
  return 1
}

poll_route() { # <route>
  local route=$1 listing id project branch verb dir
  if ! listing=$(spool "$route" pending 2>/dev/null); then
    log "route $route unreachable; its requests stay queued"
    return 0
  fi
  while IFS=$'\t' read -r id project branch verb; do
    [ -n "$id" ] || continue
    [ "$(inflight_count)" -lt "$MAX_INFLIGHT" ] || { log "at the concurrency limit; $id stays queued"; break; }
    if serial_verb "$verb"; then branch_busy "$route" "$branch" && continue; fi
    spool "$route" claim "$id" "$RUNNER_ID" >/dev/null 2>&1 || continue
    dir="$RUN/req/$route.$id"
    mkdir -p "$dir"
    if serial_verb "$verb"; then printf '%s\n' "$branch" > "$dir/branch"; fi
    run_request "$route" "$id" "$dir" &
    echo "$!" > "$dir/pid"
  done <<EOF
$listing
EOF
}

tick() {
  local route
  mkdir -p "$RUN/req"
  for route in $(routes); do
    reconcile_route "$route"
    resend_results
    poll_route "$route"
  done
  date +%s > "$RUN/last-poll"
}

acquire_serve_lock() {
  mkdir -p "$RUN"
  if ! mkdir "$RUN/serve.lock" 2>/dev/null; then
    pid_alive "$(cat "$RUN/serve.lock/pid" 2>/dev/null || true)" && die "another gate runner is already serving this home" 75
    rm -rf -- "$RUN/serve.lock"
    mkdir "$RUN/serve.lock" || die "cannot take the serve lock" 75
  fi
  printf '%s\n' "$$" > "$RUN/serve.lock/pid"
  trap 'rm -rf -- "$RUN/serve.lock"' EXIT
}

cmd_status() {
  local last=none
  [ -f "$RUN/last-poll" ] && last=$(cat "$RUN/last-poll")
  printf 'runner=%s\nlast-poll=%s\ninflight=%s\nroutes=%s\n' "$RUNNER_ID" "$last" "$(inflight_count 2>/dev/null || echo 0)" "$(routes | tr '\n' ' ')"
}

cmd_install() {
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist" body
  body=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$SCRIPT_DIR/fm-gate-runner.sh</string><string>serve</string></array>
<key>EnvironmentVariables</key><dict><key>FM_HOME</key><string>$FM_HOME</string><key>PATH</key><string>$PATH</string><key>HOME</key><string>$HOME</string></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>StandardOutPath</key><string>$HOME/Library/Logs/$LABEL.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/$LABEL.log</string>
</dict></plist>
EOF
)
  if [ "${1:-}" = --print ]; then printf '%s\n' "$body"; return 0; fi
  [ "$(uname)" = Darwin ] || die "the LaunchAgent is macOS only; run 'fm-gate-runner.sh serve' under your service manager" 64
  mkdir -p "$(dirname "$plist")" "$HOME/Library/Logs"
  printf '%s\n' "$body" > "$plist"
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  log "installed and loaded $plist"
}

[ "$#" -ge 1 ] || usage
case "$1" in
  serve)
    acquire_serve_lock
    while :; do tick || log "poll failed"; sleep "$INTERVAL"; done ;;
  once)
    tick
    wait ;;
  status) cmd_status ;;
  install) shift; cmd_install "$@" ;;
  *) usage ;;
esac
