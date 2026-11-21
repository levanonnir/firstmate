#!/usr/bin/env bash
# Durable gate-request queue for a home whose no-mistakes validation runs on its primary.
#
# Usage (worker, inside its own task worktree):
#   fm-gate-spool.sh nm [--project <name>] -- <no-mistakes args...>
# Usage (the primary's gate runner, through fm-on.sh; FM_HOME is the remote home):
#   fm-gate-spool.sh pending
#   fm-gate-spool.sh claimed <runner>
#   fm-gate-spool.sh show <id>
#   fm-gate-spool.sh claim <id> <runner>
#   fm-gate-spool.sh release <id> <runner>
#   fm-gate-spool.sh finish <id> <runner>      (stdin: rc=<n>, out=<base64>, err=<base64> lines)
#   fm-gate-spool.sh check <no-mistakes args...>   (validate a relayed request; no spool access)
#
# docs/remote-secondmates.md ("Gate on the primary") owns the design. The queue
# lives in $FM_HOME/state/gate-spool as one directory per request that moves by
# atomic rename: queued -> claimed -> done -> delivered. Nothing here runs
# no-mistakes: a request that cannot be served stays queued until the primary's
# runner (bin/fm-gate-runner.sh) is back, and there is no local fallback.
#
# `nm` is the worker's stand-in for the no-mistakes CLI. It accepts only the
# `axi` drive verbs plus `runs` and `status`, refuses --yes/-y fleet-wide, turns
# every --intent form into one stdin payload, queues the request for the current
# branch and HEAD, and blocks until the runner has finished it, then prints the
# runner's stdout, stderr, and exit status unchanged. An identical request that is
# still queued, claimed, or finished but undelivered is reattached rather than
# duplicated, so a killed or re-run wait never answers a gate twice. After every
# delivery it fast-forwards the worker's branch to the pipeline-pushed origin
# head when that is safe.
set -eu

FM_HOME="${FM_HOME:?FM_HOME is required}"
SPOOL="${FM_GATE_SPOOL_OVERRIDE:-$FM_HOME/state/gate-spool}"
POLL="${FM_GATE_POLL:-2}"
MAX_PAYLOAD=262144
DELIVERED_KEEP_DAYS=7

die() { printf 'fm-gate: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

umask 077
ensure_spool() { mkdir -p "$SPOOL/queued" "$SPOOL/claimed" "$SPOOL/done" "$SPOOL/delivered"; }

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}
b64() { base64 | tr -d '\n'; }
unb64() { base64 --decode 2>/dev/null || base64 -D; }

valid_id() { case "$1" in ''|*[!0-9-]*|-*) return 1 ;; esac; return 0; }
valid_name() { case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
valid_runner() { case "$1" in ''|-*|*[!A-Za-z0-9._@-]*) return 1 ;; esac; return 0; }

meta_get() { # <request-dir> <key>
  sed -n "s/^$2=//p" "$1/meta" | head -n 1
}

find_request() { # <id> -> prints the request directory
  local state
  for state in queued claimed "done" delivered; do
    [ -d "$SPOOL/$state/$1" ] && { printf '%s\n' "$SPOOL/$state/$1"; return 0; }
  done
  return 1
}

# ---- worker side -----------------------------------------------------------

refuse_verb() { die "refused: $* is not a gate verb; the primary runs the gate and only axi drive verbs, runs, and status are relayed" 64; }

check_nm_args() {
  local arg
  [ "$#" -ge 1 ] || refuse_verb "(no command)"
  for arg in "$@"; do
    case "$arg" in
      -y|--yes|--yes=*) die "refused: --yes is banned fleet-wide because it would answer ask-user findings with no escalation" 64 ;;
    esac
  done
  case "$1" in
    axi)
      case "${2:-}" in
        ''|-*|run|respond|answer|status|abort|retry|rounds|logs|handoff) ;;
        *) refuse_verb "axi $2" ;;
      esac ;;
    runs|status) ;;
    *) refuse_verb "$1" ;;
  esac
}

# Fold --intent TEXT, --intent=TEXT, --intent-file PATH, and --intent - into one
# stdin payload so the primary never needs a path on this host.
normalize_intent() { # <payload-file> <args...> -> NORM_ARGS array
  local payload=$1 seen=0 value
  shift
  NORM_ARGS=()
  : > "$payload"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --intent|--intent-file)
        [ "$#" -ge 2 ] || die "$1 needs a value" 64
        [ "$seen" -eq 0 ] || die "give the intent once" 64
        seen=1
        if [ "$1" = --intent-file ]; then
          [ -f "$2" ] || die "intent file is not readable: $2" 64
          head -c "$((MAX_PAYLOAD + 1))" "$2" > "$payload"
        elif [ "$2" = - ]; then
          head -c "$((MAX_PAYLOAD + 1))" > "$payload"
        else
          printf '%s' "$2" > "$payload"
        fi
        NORM_ARGS+=(--intent -)
        shift 2 ;;
      --intent=*|--intent-file=*)
        [ "$seen" -eq 0 ] || die "give the intent once" 64
        seen=1
        value=${1#*=}
        if [ "${1%%=*}" = --intent-file ]; then
          [ -f "$value" ] || die "intent file is not readable: $value" 64
          head -c "$((MAX_PAYLOAD + 1))" "$value" > "$payload"
        elif [ "$value" = - ]; then
          head -c "$((MAX_PAYLOAD + 1))" > "$payload"
        else
          printf '%s' "$value" > "$payload"
        fi
        NORM_ARGS+=(--intent -)
        shift ;;
      *) NORM_ARGS+=("$1"); shift ;;
    esac
  done
  [ "$(wc -c < "$payload" | tr -d ' ')" -le "$MAX_PAYLOAD" ] || die "intent exceeds the $MAX_PAYLOAD-byte bound" 64
}

find_open_by_key() { # <key>
  local state dir
  for state in queued claimed "done"; do
    for dir in "$SPOOL/$state"/*; do
      [ -d "$dir" ] && [ -f "$dir/key" ] || continue
      if [ "$(cat "$dir/key")" = "$1" ]; then basename "$dir"; return 0; fi
    done
  done
  return 1
}

# Fast-forward the worker's branch to the head the primary's pipeline pushed.
sync_branch() { # <branch>
  local branch=$1 fetched
  git fetch --quiet origin "refs/heads/$branch" 2>/dev/null || return 0
  fetched=$(git rev-parse FETCH_HEAD 2>/dev/null) || return 0
  [ "$fetched" != "$(git rev-parse HEAD)" ] || return 0
  if git merge-base --is-ancestor HEAD "$fetched" 2>/dev/null; then
    if git diff --quiet && git diff --cached --quiet; then
      git merge --ff-only --quiet "$fetched" >/dev/null 2>&1 \
        && printf 'fm-gate: branch %s fast-forwarded to the pipeline head %s\n' "$branch" "$fetched" >&2
    else
      printf 'fm-gate: pipeline pushed %s but this copy has uncommitted changes; commit or discard them and sync\n' "$fetched" >&2
    fi
  elif ! git merge-base --is-ancestor "$fetched" HEAD 2>/dev/null; then
    printf 'fm-gate: this branch and origin diverged (origin %s); reconcile before continuing\n' "$fetched" >&2
  fi
}

cmd_nm() {
  local project=${FM_GATE_PROJECT:-} top branch sha id key tmp payload rc dir
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) [ "$#" -ge 2 ] || die "--project needs a value" 64; project=$2; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  valid_name "$project" || die "name the project with --project <name> or FM_GATE_PROJECT" 64
  check_nm_args "$@"
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die "run this from inside your task worktree" 64
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || die "HEAD is detached; check out your task branch" 64
  sha=$(git rev-parse HEAD)
  tmp="$SPOOL/.tmp-$$"
  rm -rf -- "$tmp"; mkdir -p "$tmp"
  payload="$tmp/stdin"
  normalize_intent "$payload" "$@"
  key=$({ printf '%s\0%s\0%s\0' "$project" "$branch" "$sha"; printf '%s\0' "${NORM_ARGS[@]}"; cat "$payload"; } | sha256)
  if id=$(find_open_by_key "$key"); then
    rm -rf -- "$tmp"
    printf 'fm-gate: reattached to request %s (waiting for the primary'"'"'s gate runner; no local fallback)\n' "$id" >&2
  else
    find "$SPOOL/delivered" -mindepth 1 -maxdepth 1 -mtime "+$DELIVERED_KEEP_DAYS" -exec rm -rf -- {} + 2>/dev/null || true
    id="$(date +%s)-$$-$RANDOM"
    printf '%s\n' "$key" > "$tmp/key"
    printf '%s\0' "${NORM_ARGS[@]}" > "$tmp/argv"
    {
      printf 'project=%s\n' "$project"
      printf 'branch=%s\n' "$branch"
      printf 'sha=%s\n' "$sha"
      printf 'repo=%s\n' "$(cd "$top" && pwd -P)"
      printf 'created=%s\n' "$(date +%s)"
    } > "$tmp/meta"
    mv "$tmp" "$SPOOL/queued/$id"
    printf 'fm-gate: queued request %s for the primary'"'"'s gate runner (waiting; no local fallback)\n' "$id" >&2
  fi
  while :; do
    # A second waiter reattached to the same request reads it from delivered/.
    for dir in "$SPOOL/done/$id" "$SPOOL/delivered/$id"; do
      [ -f "$dir/rc" ] || continue
      rc=$(cat "$dir/rc")
      cat "$dir/out"
      cat "$dir/err" >&2
      [ "$dir" = "$SPOOL/delivered/$id" ] || mv "$dir" "$SPOOL/delivered/$id" 2>/dev/null || true
      sync_branch "$branch"
      exit "$rc"
    done
    sleep "$POLL"
  done
}

# The primary re-validates every relayed request with this, so the verb allowlist
# and the --yes ban have one owner. A relayed request never carries a path from
# the worker's host, so --intent-file is refused here.
cmd_check() {
  local arg
  check_nm_args "$@"
  for arg in "$@"; do
    case "$arg" in --intent-file|--intent-file=*) die "refused: --intent-file is folded into stdin by the worker side" 64 ;; esac
  done
}

# ---- primary's runner side ---------------------------------------------------

cmd_pending() {
  local dir
  for dir in "$SPOOL/queued"/*; do
    [ -d "$dir" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$dir")" "$(meta_get "$dir" project)" "$(meta_get "$dir" branch)"
  done | sort
}

cmd_claimed() { # <runner>
  local dir
  valid_runner "$1" || die "unsafe runner id" 64
  for dir in "$SPOOL/claimed"/*; do
    [ -d "$dir" ] || continue
    [ "$(cat "$dir/claim" 2>/dev/null || true)" = "$1" ] && basename "$dir"
  done | sort
  return 0
}

cmd_show() { # <id>
  local dir
  valid_id "$1" || die "unsafe request id" 64
  dir=$(find_request "$1") || die "no such request: $1" 66
  cat "$dir/meta"
  printf 'argv_b64=%s\n' "$(b64 < "$dir/argv")"
  printf 'stdin_b64=%s\n' "$(b64 < "$dir/stdin")"
}

cmd_claim() { # <id> <runner>
  valid_id "$1" || die "unsafe request id" 64
  valid_runner "$2" || die "unsafe runner id" 64
  [ -d "$SPOOL/queued/$1" ] || exit 3
  printf '%s\n' "$2" > "$SPOOL/queued/$1/claim"
  mv "$SPOOL/queued/$1" "$SPOOL/claimed/$1" 2>/dev/null || exit 3
}

cmd_release() { # <id> <runner>
  valid_id "$1" || die "unsafe request id" 64
  valid_runner "$2" || die "unsafe runner id" 64
  [ "$(cat "$SPOOL/claimed/$1/claim" 2>/dev/null || true)" = "$2" ] || exit 3
  rm -f "$SPOOL/claimed/$1/claim"
  mv "$SPOOL/claimed/$1" "$SPOOL/queued/$1" 2>/dev/null || exit 3
}

cmd_finish() { # <id> <runner>; frames on stdin
  local dir rc out err line
  valid_id "$1" || die "unsafe request id" 64
  valid_runner "$2" || die "unsafe runner id" 64
  [ ! -d "$SPOOL/done/$1" ] && [ ! -d "$SPOOL/delivered/$1" ] || exit 0
  dir="$SPOOL/claimed/$1"
  [ "$(cat "$dir/claim" 2>/dev/null || true)" = "$2" ] || die "request $1 is not claimed by $2" 3
  rc='' out='' err=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      rc=*) rc=${line#rc=} ;;
      out=*) out=${line#out=} ;;
      err=*) err=${line#err=} ;;
    esac
  done
  case "$rc" in ''|*[!0-9]*) die "finish needs rc=<number>" 64 ;; esac
  printf '%s' "$out" | unb64 > "$dir/out"
  printf '%s' "$err" | unb64 > "$dir/err"
  printf '%s\n' "$rc" > "$dir/rc"
  mv "$dir" "$SPOOL/done/$1"
}

[ "$#" -ge 1 ] || usage
verb=$1
shift
[ "$verb" = check ] || ensure_spool
case "$verb" in
  nm) cmd_nm "$@" ;;
  check) cmd_check "$@" ;;
  pending) cmd_pending ;;
  claimed) [ "$#" -eq 1 ] || usage; cmd_claimed "$1" ;;
  show) [ "$#" -eq 1 ] || usage; cmd_show "$1" ;;
  claim) [ "$#" -eq 2 ] || usage; cmd_claim "$1" "$2" ;;
  release) [ "$#" -eq 2 ] || usage; cmd_release "$1" "$2" ;;
  finish) [ "$#" -eq 2 ] || usage; cmd_finish "$1" "$2" ;;
  *) usage ;;
esac
