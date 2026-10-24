#!/usr/bin/env bash
# fm-auto-teardown.sh - tear down this home's finished tasks once they are
# done AND landed, so the creator removes what it made without a janitor.
#
# Usage: fm-auto-teardown.sh [--detach]
#
# For every ship or scout record in this home's state/ whose current state
# (bin/fm-crew-state.sh) reads `done`, this runs `bin/fm-teardown.sh <id>`
# WITHOUT --force. Teardown owns the landed-work test and every refusal, so a
# task whose work has not landed (an unmerged PR, a dirty copy, a scout with no
# report or an open captain question) is left exactly as it was and is retried
# no sooner than FM_AUTO_TEARDOWN_RETRY_SECS (default 600) later. A secondmate is
# never touched, and this script never passes --force or discards anything.
#
# --detach starts the same sweep in its own session and returns at once, with
# its output appended to state/.auto-teardown.log; that is how the wake path
# (bin/fm-wake-drain.sh) calls it, so a drain never waits on a teardown.
# One sweep runs at a time per home (state/.auto-teardown.lock); a second call
# while one is live exits 0 silently, and a --detach request within
# FM_AUTO_TEARDOWN_MIN_INTERVAL seconds of the previous one is skipped. FM_AUTO_TEARDOWN=0 turns the sweep off.
# bin/fm-spawn.sh also runs one sweep (foreground) as the single reclaim of a
# home's own leftovers before it refuses a spawn over a ceiling.
#
# Output: one `auto-teardown: <id> <result>` line per attempted task, where
# result is `done`, or `kept (<first refusal line>)` when teardown refused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

[ "${FM_AUTO_TEARDOWN:-1}" != 0 ] || exit 0
[ -d "$STATE" ] || exit 0

LOCK="$STATE/.auto-teardown.lock"
LOG="$STATE/.auto-teardown.log"
RETRY_SECS=${FM_AUTO_TEARDOWN_RETRY_SECS:-600}
case "$RETRY_SECS" in ''|*[!0-9]*) RETRY_SECS=600 ;; esac

if [ "${1:-}" = --detach ]; then
  # Every wake drain calls this, so a detached request is rate limited: a sweep
  # that began within FM_AUTO_TEARDOWN_MIN_INTERVAL seconds (default 120) is
  # enough, and the retry backoff below still paces each refused task.
  interval=${FM_AUTO_TEARDOWN_MIN_INTERVAL:-120}
  case "$interval" in ''|*[!0-9]*) interval=120 ;; esac
  stamp="$STATE/.auto-teardown.stamp"
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || true)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( $(date +%s) - last )) -ge "$interval" ] || exit 0
  fi
  date +%s > "$stamp" 2>/dev/null || true
  # The sweep runs in its own session so it outlives the caller and never
  # holds the caller's pipes open.
  if command -v setsid >/dev/null 2>&1; then
    ( setsid "$0" </dev/null >>"$LOG" 2>&1 & )
  else
    ( "$0" </dev/null >>"$LOG" 2>&1 & )
  fi
  exit 0
fi

# Single flight. A lock whose pid is gone is stale and is taken over.
if ! mkdir "$LOCK" 2>/dev/null; then
  holder=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCK" 2>/dev/null || exit 0
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

now=$(date +%s)
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  fm_task_id_path_safe "$id" || continue
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in
    ''|ship|scout) ;;
    *) continue ;;
  esac
  retry="$STATE/.auto-teardown-retry.$id"
  if [ -f "$retry" ]; then
    last=$(cat "$retry" 2>/dev/null || true)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge "$RETRY_SECS" ] || continue
  fi
  verdict=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -1) || verdict=
  case "$verdict" in
    "state: done"*) ;;
    *) continue ;;
  esac
  if out=$("$SCRIPT_DIR/fm-teardown.sh" "$id" 2>&1 </dev/null); then
    rm -f "$retry"
    printf 'auto-teardown: %s done\n' "$id"
  else
    printf '%s\n' "$now" > "$retry"
    first=$(printf '%s\n' "$out" | grep -m1 -E 'REFUSED|error|refus|unlanded|not landed' || printf '%s\n' "$out" | tail -1)
    printf 'auto-teardown: %s kept (%s)\n' "$id" "$first"
  fi
done
exit 0
