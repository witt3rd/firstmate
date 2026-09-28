#!/usr/bin/env bash
# fm-caretaker-sweep.sh - the schedule and read-only snapshot behind a caretaker
# charter's declared health sweep.
#
# Usage:
#   fm-caretaker-sweep.sh due
#   fm-caretaker-sweep.sh status
#   fm-caretaker-sweep.sh start
#   fm-caretaker-sweep.sh complete
#   fm-caretaker-sweep.sh snapshot
#   fm-caretaker-sweep.sh arm [--if-declared]
#   fm-caretaker-sweep.sh disarm
#   fm-caretaker-sweep.sh --help
#
# A caretaker charter scaffolded with `bin/fm-brief.sh <id> --secondmate
# --caretaker --sweep-every <cadence> ...` declares a sweep cadence in the home's
# data/charter.md; bin/fm-caretaker-lib.sh owns that line and its grammar. The
# declared sweep is the only work a secondmate starts without routing, and this
# script owns the schedule that authorizes it. The procedure an agent follows
# on the resulting notification is owned by .agents/skills/caretaker-sweep.
#
# RECORD. data/caretaker-sweep.record is the durable schedule record, rewritten
# atomically by start and complete:
#   schema=fm-caretaker-sweep.v1
#   started_at=<epoch>     the latest sweep start
#   completed_at=<epoch>   the latest recorded completion
# It lives on disk beside the charter, so a restart neither repeats a sweep that
# already completed within the cadence nor skips one that came due while the
# home was down: the next check simply reads it.
#
# due      The watcher check body. It reads only the charter and the record,
#          never the network or a project, and always exits 0. It prints
#          nothing when the charter declares no sweep, and exactly one line
#          when a sweep is due: none has completed yet, or the cadence has
#          elapsed since the last completion; or a started sweep recorded no
#          completion within the in-progress bound (the cadence, capped at
#          FM_CARETAKER_SWEEP_STALL_SECS, default 86400), so an abandoned sweep
#          comes due again instead of silencing the schedule; or the declaration
#          is malformed. A sweep in progress inside that bound stays silent, so
#          the watcher's check interval never re-rings a sweep already started.
#          FM_CARETAKER_SWEEP_NOW (epoch seconds) pins the clock for tests.
# status   Print the cadence, the record, and the current verdict.
# start    Record started_at=now. Refuses when the charter declares no valid
#          sweep, because that declaration is the sweep's only authority.
# complete Record completed_at=now. Refuses unless a started sweep is pending.
# snapshot Print a read-only Markdown fact sheet to stdout: for each clone under
#          the home's projects/, its checkout, local changes, stashes, linked
#          worktrees, local branches missing from origin, and its default branch
#          against origin's current head read with one bounded `git ls-remote`
#          (FM_CARETAKER_SWEEP_REMOTE_SECS, default 15) rather than a fetch;
#          then each recurrence-ledger row from data/learnings.md with its
#          dated-occurrence count, marking a class with two or more as
#          recurring. It never fetches, never refreshes an index, and writes
#          nothing: every git read runs with optional locks and fsmonitor off.
# arm      Write state/caretaker-sweep.check.sh, a shim that execs `due` for
#          this home, and bind it with bin/fm-check-register.sh, so the home's
#          own watcher runs it every check interval (FM_CHECK_INTERVAL) and
#          turns its one line into a `check:` wake; a registered check also
#          keeps an otherwise idle home's watcher alive. Plain arm refuses a
#          home without the .fm-secondmate-home marker or a declared sweep.
#          `arm --if-declared`, run by bin/fm-bootstrap.sh at every locked
#          session start, arms when both hold and otherwise disarms a stale
#          shim, so a charter edit takes effect at the next session start. A
#          failed arm never leaves a shim without its trust binding.
# disarm   Remove the shim and its trust binding; the record is kept.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CHARTER="$DATA/charter.md"
RECORD="$DATA/caretaker-sweep.record"
RECORD_SCHEMA=fm-caretaker-sweep.v1
CHECK_ID=caretaker-sweep
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
PROJECTS_REAL=
REPO=

# shellcheck source=bin/fm-caretaker-lib.sh
. "$SCRIPT_DIR/fm-caretaker-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'fm-caretaker-sweep: %s\n' "$1" >&2; exit 1; }

now_epoch() {
  case "${FM_CARETAKER_SWEEP_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_CARETAKER_SWEEP_NOW" ;;
  esac
}

epoch_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null \
    || printf '%s\n' "$1"
}

stall_bound() {  # <cadence-secs>
  local cap=${FM_CARETAKER_SWEEP_STALL_SECS:-86400}
  case "$cap" in ''|*[!0-9]*|0) cap=86400 ;; esac
  if [ "$1" -lt "$cap" ]; then printf '%s\n' "$1"; else printf '%s\n' "$cap"; fi
}

# Record fields, 0 when absent or unusable.
STARTED_AT=0
COMPLETED_AT=0
record_read() {
  local key value schema=
  STARTED_AT=0
  COMPLETED_AT=0
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      schema) schema=$value ;;
      started_at) case "$value" in ''|*[!0-9]*) ;; *) STARTED_AT=$value ;; esac ;;
      completed_at) case "$value" in ''|*[!0-9]*) ;; *) COMPLETED_AT=$value ;; esac ;;
    esac
  done < "$RECORD"
  if [ "$schema" != "$RECORD_SCHEMA" ]; then
    STARTED_AT=0
    COMPLETED_AT=0
  fi
}

record_write() {  # <started> <completed>
  local tmp
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || die "data directory is unavailable: $DATA"
  if [ -L "$RECORD" ] || { [ -e "$RECORD" ] && [ ! -f "$RECORD" ]; }; then
    die "sweep record is not a regular file: $RECORD"
  fi
  tmp=$(umask 077; mktemp "$DATA/.caretaker-sweep.XXXXXX") || die "cannot stage the sweep record"
  if ! printf 'schema=%s\nstarted_at=%s\ncompleted_at=%s\n' "$RECORD_SCHEMA" "$1" "$2" > "$tmp" \
    || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    die "cannot write the sweep record: $RECORD"
  fi
}

# The schedule verdict for the current charter and record. Sets VERDICT to
# none, malformed, due, stalled, pending, or waiting, and VERDICT_LINE to the
# one line `due` prints for the three actionable verdicts.
VERDICT=
VERDICT_LINE=
verdict_compute() {
  local rc=0 now bound
  VERDICT=none
  VERDICT_LINE=
  fm_caretaker_charter_cadence "$CHARTER" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *)
      VERDICT=malformed
      VERDICT_LINE="caretaker health sweep declaration in data/charter.md is unusable: $FM_CARETAKER_CADENCE_ERROR; correct it or remove the declaration"
      return 0
      ;;
  esac
  record_read
  now=$(now_epoch)
  if [ "$STARTED_AT" -gt "$COMPLETED_AT" ]; then
    bound=$(stall_bound "$FM_CARETAKER_CADENCE_SECS")
    if [ $((now - STARTED_AT)) -lt "$bound" ]; then
      VERDICT=pending
      return 0
    fi
    VERDICT=stalled
    VERDICT_LINE="caretaker health sweep due again (every $FM_CARETAKER_CADENCE; the sweep started $(epoch_iso "$STARTED_AT") never recorded completion); load the caretaker-sweep skill"
    return 0
  fi
  if [ "$COMPLETED_AT" -eq 0 ]; then
    VERDICT=due
    VERDICT_LINE="caretaker health sweep due (every $FM_CARETAKER_CADENCE; no sweep completed yet); load the caretaker-sweep skill"
  elif [ $((now - COMPLETED_AT)) -ge "$FM_CARETAKER_CADENCE_SECS" ]; then
    VERDICT=due
    VERDICT_LINE="caretaker health sweep due (every $FM_CARETAKER_CADENCE; last completed $(epoch_iso "$COMPLETED_AT")); load the caretaker-sweep skill"
  else
    VERDICT=waiting
  fi
}

action_due() {
  verdict_compute
  [ -z "$VERDICT_LINE" ] || printf '%s\n' "$VERDICT_LINE"
  return 0
}

action_status() {
  local next=
  verdict_compute
  record_read
  if [ "$VERDICT" = none ]; then
    printf 'cadence: none declared\n'
  elif [ "$VERDICT" = malformed ]; then
    printf 'cadence: unusable (%s)\n' "$FM_CARETAKER_CADENCE_ERROR"
  else
    printf 'cadence: every %s\n' "$FM_CARETAKER_CADENCE"
    [ "$COMPLETED_AT" -eq 0 ] || next=$(epoch_iso $((COMPLETED_AT + FM_CARETAKER_CADENCE_SECS)))
  fi
  if [ "$STARTED_AT" -eq 0 ]; then printf 'last started: never\n'; else printf 'last started: %s\n' "$(epoch_iso "$STARTED_AT")"; fi
  if [ "$COMPLETED_AT" -eq 0 ]; then printf 'last completed: never\n'; else printf 'last completed: %s\n' "$(epoch_iso "$COMPLETED_AT")"; fi
  [ -z "$next" ] || printf 'next due: %s\n' "$next"
  printf 'verdict: %s\n' "$VERDICT"
  if fm_custom_check_registered "$STATE" "$CHECK_ID" 2>/dev/null; then
    printf 'check: armed\n'
  else
    printf 'check: not armed\n'
  fi
}

action_start() {
  local rc=0 now
  fm_caretaker_charter_cadence "$CHARTER" || rc=$?
  case "$rc" in
    0) ;;
    1) die "data/charter.md declares no scheduled health sweep; a sweep runs only under a caretaker charter's declared cadence" ;;
    *) die "data/charter.md sweep declaration is unusable: $FM_CARETAKER_CADENCE_ERROR" ;;
  esac
  record_read
  now=$(now_epoch)
  record_write "$now" "$COMPLETED_AT"
  printf 'started: %s\n' "$(epoch_iso "$now")"
}

action_complete() {
  local now
  record_read
  [ "$STARTED_AT" -gt "$COMPLETED_AT" ] || die "no started sweep is pending; run start when a sweep begins"
  now=$(now_epoch)
  record_write "$STARTED_AT" "$now"
  printf 'completed: %s\n' "$(epoch_iso "$now")"
}

# --- read-only snapshot ------------------------------------------------------

# Every git read: no optional index refresh, no fsmonitor daemon, no prompt,
# and no discovery above projects/, so a directory that is not its own clone
# is never read as the enclosing Firstmate checkout.
rgit() {
  GIT_CEILING_DIRECTORIES="$PROJECTS_REAL" GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 \
    git -c core.fsmonitor=false -C "$REPO" "$@"
}

short() { printf '%.12s' "$1"; }

# Up to <max> names from stdin joined with ", ", plus a remainder count.
join_names() {  # <max>
  awk -v max="$1" '
    NF { n++; if (n <= max) out = out (out == "" ? "" : ", ") $0 }
    END {
      if (n == 0) { print "none"; exit }
      if (n > max) out = out " and " (n - max) " more"
      print out
    }
  '
}

snapshot_project() {  # <name>
  local name=$1 remote_secs remote_out remote_rc=0 default remote_head local_head
  local branch porcelain tracked untracked stashes worktrees counts ahead behind
  local names remote_names reference drift
  REPO="$PROJECTS_REAL/$name"
  printf '\n### %s\n' "$name"
  if [ "$(rgit rev-parse --show-toplevel 2>/dev/null || true)" != "$(cd "$REPO" && pwd -P)" ]; then
    printf -- '- not a git clone\n'
    return 0
  fi
  remote_secs=${FM_CARETAKER_SWEEP_REMOTE_SECS:-15}
  case "$remote_secs" in ''|*[!0-9]*|0) remote_secs=15 ;; esac
  remote_out=$(fm_run_timed "$remote_secs" env GIT_CEILING_DIRECTORIES="$PROJECTS_REAL" \
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 \
    git -c core.fsmonitor=false -C "$REPO" ls-remote --symref origin HEAD 'refs/heads/*' \
    </dev/null 2>/dev/null) || remote_rc=$?

  branch=$(rgit symbolic-ref -q --short HEAD 2>/dev/null || true)
  if [ -n "$branch" ]; then
    printf -- '- checkout: branch %s\n' "$branch"
  else
    printf -- '- checkout: detached at %s\n' "$(short "$(rgit rev-parse -q --verify HEAD 2>/dev/null || true)")"
  fi

  porcelain=$(rgit status --porcelain=v1 --untracked-files=normal 2>/dev/null || true)
  untracked=$(printf '%s\n' "$porcelain" | grep -c '^??' || true)
  tracked=$(printf '%s\n' "$porcelain" | grep -c '^[^?]' || true)
  if [ "$tracked" -eq 0 ] && [ "$untracked" -eq 0 ]; then
    printf -- '- local changes: none\n'
  else
    printf -- '- local changes: %s tracked, %s untracked\n' "$tracked" "$untracked"
  fi
  stashes=$(rgit stash list 2>/dev/null | grep -c '' || true)
  printf -- '- stashes: %s\n' "$stashes"
  worktrees=$(rgit worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)
  [ "$worktrees" -gt 0 ] || worktrees=1
  printf -- '- linked worktrees: %s\n' "$((worktrees - 1))"

  if [ "$remote_rc" -eq 0 ]; then
    default=$(printf '%s\n' "$remote_out" | awk -F '\t' '$1 ~ /^ref: refs\/heads\// && $2 == "HEAD" { sub(/^ref: refs\/heads\//, "", $1); print $1; exit }')
    remote_names=$(printf '%s\n' "$remote_out" | awk -F '\t' '$2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2 }')
    reference="origin now"
  else
    default=
    remote_names=$(rgit for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null \
      | sed -n 's#^refs/remotes/origin/##p' | grep -vx HEAD || true)
    reference="origin as last fetched (origin unreachable)"
  fi
  [ -n "$default" ] || default=$(rgit symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  [ -n "$default" ] || default=main

  names=$(rgit for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
    | awk 'NR == FNR { if (NF) remote[$0] = 1; next } NF && !($0 in remote)' <(printf '%s\n' "$remote_names") - \
    | join_names 20)
  printf -- '- local branches not on %s: %s\n' "$reference" "$names"

  local_head=$(rgit rev-parse -q --verify "refs/heads/$default^{commit}" 2>/dev/null || true)
  if [ "$remote_rc" -eq 0 ]; then
    remote_head=$(printf '%s\n' "$remote_out" | awk -F '\t' -v ref="refs/heads/$default" '$2 == ref { print $1; exit }')
  else
    remote_head=$(rgit rev-parse -q --verify "refs/remotes/origin/$default^{commit}" 2>/dev/null || true)
  fi
  if [ -z "$local_head" ]; then
    drift="no local $default branch"
  elif [ -z "$remote_head" ]; then
    drift="no $default head on $reference"
  elif [ "$local_head" = "$remote_head" ]; then
    drift="current with $reference at $(short "$remote_head")"
  elif ! rgit cat-file -e "$remote_head^{commit}" 2>/dev/null; then
    drift="behind $reference: its head $(short "$remote_head") is not fetched here"
  else
    counts=$(rgit rev-list --left-right --count "$local_head...$remote_head" 2>/dev/null || true)
    ahead=${counts%%[[:space:]]*}
    behind=${counts##*[[:space:]]}
    drift="ahead ${ahead:-?}, behind ${behind:-?} against $reference (local $(short "$local_head"), origin $(short "$remote_head"))"
  fi
  printf -- '- default branch %s: %s\n' "$default" "$drift"
}

snapshot_ledger() {
  local learnings="$DATA/learnings.md"
  printf '\n## Recurrence ledger\n'
  if [ -f "$learnings" ] && ! grep -Fxq -- "$FM_CARETAKER_LEDGER_HEADING" "$learnings" \
    && fm_caretaker_ledger_present "$learnings"; then
    # shellcheck disable=SC2016 # The backticks are literal Markdown code quotes.
    printf 'A hand-written recurrence ledger exists in data/learnings.md outside the canonical `%s` section, so its rows are not counted here. Review it directly and migrate it to the canonical heading and row format.\n' "$FM_CARETAKER_LEDGER_HEADING"
    return 0
  fi
  if [ ! -f "$learnings" ] || ! grep -Fxq -- "$FM_CARETAKER_LEDGER_HEADING" "$learnings"; then
    # shellcheck disable=SC2016 # The backticks are literal Markdown code quotes.
    printf 'No `%s` section in data/learnings.md.\n' "$FM_CARETAKER_LEDGER_HEADING"
    return 0
  fi
  awk -v heading="$FM_CARETAKER_LEDGER_HEADING" '
    $0 == heading { in_section = 1; next }
    in_section && /^#/ { exit }
    in_section && /^- / {
      n = split($0, field, / \| /)
      if (n < 3) next
      class = field[1]; sub(/^- /, "", class)
      status = field[3]
      for (i = 4; i <= n; i++) status = status " | " field[i]
      gsub(/[[:space:]]*<!--[^>]*-->[[:space:]]*/, "", status)
      occurrences = field[2]
      count = gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/, "", occurrences)
      rows++
      printf "- %s: %d dated occurrence%s; remedy: %s%s\n", class, count, (count == 1 ? "" : "s"), status, (count >= 2 ? " - recurring" : "")
    }
    END { if (rows == 0) print "No classes recorded yet." }
  ' "$learnings"
}

action_snapshot() {
  local project found=0
  printf '# Caretaker health sweep snapshot\n'
  printf 'Taken %s; read-only: nothing was fetched or changed.\n' "$(epoch_iso "$(now_epoch)")"
  printf '\n## Projects\n'
  if [ -d "$PROJECTS" ] && PROJECTS_REAL=$(cd "$PROJECTS" && pwd -P); then
    for project in "$PROJECTS_REAL"/*; do
      [ -d "$project" ] || continue
      found=1
      snapshot_project "${project##*/}"
    done
  fi
  [ "$found" -eq 1 ] || printf 'No project clones under projects/.\n'
  snapshot_ledger
}

# --- arm / disarm --------------------------------------------------------------

shim_content() {  # <home> <data>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-caretaker-sweep.sh - scheduled caretaker health sweep check.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$2")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-caretaker-sweep.sh") due"
}

resolve_dir() {  # <dir>
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) CDPATH='' cd -- "$1" 2>/dev/null && pwd -P ;;
  esac
}

action_disarm() {
  if [ -e "$CHECK_SHIM" ] || [ -L "$CHECK_SHIM" ] || [ -e "$CHECK_TRUST" ] || [ -L "$CHECK_TRUST" ]; then
    FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null \
      || die "could not remove state/$CHECK_ID.check.sh"
  fi
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

action_arm() {
  local if_declared=${1:-} rc=0 home data want device tmp
  if [ ! -f "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    if [ "$if_declared" = --if-declared ]; then action_disarm >/dev/null; return 0; fi
    die "this home is not a seeded secondmate home; only a caretaker second mate runs a scheduled sweep"
  fi
  fm_caretaker_charter_cadence "$CHARTER" || rc=$?
  if [ "$rc" -eq 1 ]; then
    if [ "$if_declared" = --if-declared ]; then action_disarm >/dev/null; return 0; fi
    die "data/charter.md declares no scheduled health sweep"
  fi
  # A malformed declaration is still armed, so the check itself reports it.
  home=$(resolve_dir "$FM_HOME") || die "cannot resolve FM_HOME $FM_HOME"
  data=$(resolve_dir "$DATA") || die "cannot resolve the data directory $DATA"
  mkdir -p "$STATE" || die "cannot create the state directory $STATE"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable: $STATE"
  want=$(shim_content "$home" "$data")
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] \
    && fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  device=$(fm_pr_file_device "$STATE") || die "state directory is unavailable: $STATE"
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || die "refusing an unsafe check path: $CHECK_SHIM"
  tmp=$(umask 077; mktemp "$STATE/.fm-caretaker-sweep.XXXXXX") || die "cannot stage the check shim"
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    die "could not write $CHECK_SHIM"
  fi
  # A shim without its trust binding is rejected on every watcher cycle, so a
  # failed registration removes the shim rather than leave it unbound.
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    die "could not register $CHECK_SHIM"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-}" in
  due) action_due ;;
  status) action_status ;;
  start) action_start ;;
  complete) action_complete ;;
  snapshot) action_snapshot ;;
  arm)
    case "${2:-}" in
      ''|--if-declared) action_arm "${2:-}" ;;
      *) printf 'fm-caretaker-sweep: unknown arm option: %s\n' "$2" >&2; exit 2 ;;
    esac
    ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
