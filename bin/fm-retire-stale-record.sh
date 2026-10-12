#!/usr/bin/env bash
# Retire the stale RECORD of a finished task whose cleanup bin/fm-teardown.sh
# cannot complete: the recorded worktree slot was handed to a later task, the
# worktree is gone, or its identity is missing. Such a record otherwise stays
# forever and keeps raising idle alerts for an endpoint nobody owns.
#
# Usage: fm-retire-stale-record.sh <task-id> [--confirm]
#   Without --confirm this is a DRY RUN: it proves the record is stale, prints
#   what it would remove and why, and changes nothing. With --confirm it
#   re-proves everything under the task's locks and then removes the record.
#   Exit 0 on a dry run that would retire, a completed retirement, and a task
#   that has no record (idempotent no-op); exit 1 on any refusal, with the exact
#   reason; exit 2 on a bad request. A wrong FM_HOME (no state folder) is
#   refused with exit 1 before anything is created, dry run included.
#
# Why a sibling of fm-teardown.sh rather than a flag on it: teardown is a
# 3,900-line script whose every path kills processes, returns worktrees and
# closes endpoints. A retirement is the opposite promise - it must be unable to
# do any of that - and a separate script makes "never touches a worktree, a
# slot, an endpoint or another task" true by construction instead of by a flag
# test on each of those steps. It reuses the libraries teardown uses for every
# record it removes (backlog transition, PR-check artifacts, presentation and
# busy retirement, wake-queue pruning), so both retire the same records.
#
# PROOFS (every one must pass; any failure or ambiguity refuses and names why):
#   - the record is a plain ship or scout task (never a secondmate), the
#     supervision-lease and gate-agent guards pass, and the task is not live:
#     its recorded endpoint is proved dead or missing (alive, ambiguous,
#     unreadable and unverified are all refused). An endpoint another task's
#     record also names is refused too: its wake rows and per-window markers
#     cannot be told apart from this task's, so retire or reconcile the other
#     record first.
#   - landed work. A scout: data/<id>/report.md is a regular file of at least
#     200 bytes whose first line is a Markdown heading (every scout brief asks
#     for a standalone report, so a one-line note or a headerless stub is not
#     one) and bin/fm-captain-hold.sh verify passes. A ship: its PR is merged on the
#     forge, or - for a local-only ship - its branch is in the local default
#     branch. Teardown's own landed-work test inspects the worktree, which is
#     exactly what is gone or shared here, so this is the forge/clone-side
#     equivalent of it.
#   - slots. For every slot the record names (worktree=, home=): a path that is
#     absent or unrecorded has nothing to inspect; a slot whose owner claim names
#     another task, or that another task record also names, belongs to that
#     task and is left alone (the case this script exists for: its commits are
#     the later task's, not this record's, unless it sits on this record's own
#     branch). A slot that is exclusively this record's must hold no commit that
#     is not on a remote - and, being intact, is refused anyway: it is
#     teardown's to return, not this script's.
#   - nothing is owed: no open keyed decision in the status log, the backlog
#     item is not held for the captain, and no public reply is owed.
#
# EFFECT. Removes ONLY state/<id>.* and the matching dot-files for this task:
# status, busy and turn markers, steering inbox, alert and presentation
# markers, PR-check artifacts, wake-queue rows, and the watcher's per-window
# idle/stale markers (.hash-/.count-/.stale-/.stale-since-/.wedge-escalations-/
# .paused-*/.writing-*/.waiting-* for the recorded endpoint, which no other
# record may name). The record itself goes last, together with the
# backlog item's close, through the same pending-close record and atomic
# transition teardown uses (the item is closed with the report or PR link; a
# home with no automatic backlog just loses the record). NEVER touched: any
# worktree or pool slot or its claim, any endpoint or process, data/<id>/ (the
# report and brief stay), a herdr presentation journal (the session-start sweep
# owns it), harness turn-end auth files outside state/, or another task's files.
# --force does not exist: nothing here discards work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  awk '/^# PROOFS/ { exit } NR > 1 && /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# Help is answered before anything is sourced, and a wrong home is refused
# before it: sourced libraries create the state folder, and nothing here (dry
# run and help included) may create a folder, file or lock.
for _arg in "$@"; do
  case "$_arg" in
    -h|--help) usage; exit 0 ;;
  esac
done
unset _arg
if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "error: retire refused: no state folder at $STATE (check FM_HOME); nothing was changed" >&2
  exit 1
fi

for _src in \
  fm-tasks-axi-lib.sh fm-backlog-transition-lib.sh fm-backend.sh fm-lock-lib.sh \
  fm-classify-lib.sh fm-pr-lib.sh fm-public-followup-lib.sh \
  fm-secondmate-registry-lib.sh fm-secondmate-parent-lib.sh fm-wake-lib.sh \
  fm-lease-lib.sh fm-gate-refuse-lib.sh
do
  if [ ! -f "$SCRIPT_DIR/$_src" ] || [ ! -r "$SCRIPT_DIR/$_src" ]; then
    echo "error: retire refused: required source $_src is missing or unreadable; nothing was changed" >&2
    exit 1
  fi
done
unset _src
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

ID=
CONFIRM=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --confirm) CONFIRM=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $1 (usage: fm-retire-stale-record.sh <task-id> [--confirm])" >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo "error: exactly one task id is required" >&2; exit 2; }
      ID=$1
      ;;
  esac
  shift
done
if [ -z "$ID" ] || ! fm_task_id_path_safe "$ID"; then
  echo "error: invalid retire request (usage: fm-retire-stale-record.sh <task-id> [--confirm])" >&2
  exit 2
fi

META="$STATE/$ID.meta"
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
release_locks() {
  local status=$?
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  fm_lease_guard_release || true
  return "$status"
}
trap release_locks EXIT

refuse() {  # <reason...>
  echo "REFUSED: $*; nothing was changed." >&2
  exit 1
}

# Facts the proofs establish and the plan reads.
MIN_REPORT_BYTES=200
KIND=ship
MODE=
BACKEND=tmux
TARGET=
PROJ=
BRANCH=
PR_URL=
BACKLOG_APPLIES=0
BACKLOG_SKIP_REASON=
SPAWN_GEN=
DONE_ARGS=()
NOTES=()
WINDOW_KEY=

note() { NOTES+=("$*"); }

canonical_dir() { CDPATH='' cd -- "$1" 2>/dev/null && pwd -P; }

# Another task record (in any local Firstmate home) that names <slot> as its
# worktree= or home=; prints that task id and returns 0, or returns 1.
other_record_for_slot() {  # <canonical-slot>
  local slot=$1 dir other field p
  for dir in "${LOCAL_STATES[@]}"; do
    for other in "$dir"/*.meta; do
      [ -f "$other" ] && [ ! -L "$other" ] || continue
      [ "$other" -ef "$META" ] && continue
      for field in worktree home; do
        p=$(fm_meta_get "$other" "$field")
        [ -n "$p" ] || continue
        p=$(canonical_dir "$p") || continue
        if [ "$p" = "$slot" ]; then
          basename "$other" .meta
          return 0
        fi
      done
    done
  done
  return 1
}

# Another record of THIS home that names the same endpoint.
other_record_for_target() {  # <target>
  local target=$1 other
  [ -n "$target" ] || return 1
  for other in "$STATE"/*.meta; do
    [ -f "$other" ] && [ ! -L "$other" ] || continue
    [ "$other" -ef "$META" ] && continue
    if [ "$(fm_backend_target_of_meta "$other")" = "$target" ]; then
      basename "$other" .meta
      return 0
    fi
  done
  return 1
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

prove_not_live() {
  local state shared
  [ -n "$TARGET" ] || { note "no endpoint recorded: nothing to probe"; return 0; }
  if shared=$(other_record_for_target "$TARGET"); then
    refuse "endpoint $TARGET is also named by task $shared, so this task's wake rows and per-window markers cannot be told apart from that task's; retire or reconcile $shared's record first"
  fi
  state=$(fm_backend_agent_state "$BACKEND" "$TARGET")
  case "$state" in
    alive) refuse "task $ID is live: its recorded endpoint $TARGET still runs an agent (finish or exit it first, then use bin/fm-teardown.sh)" ;;
    dead|missing) note "endpoint $TARGET is $state" ;;
    *)
      # A backend with no recovery classifier can still prove the endpoint gone.
      if ! fm_backend_target_exists "$BACKEND" "$TARGET" >/dev/null 2>&1 \
         && [ "$state" = unverified ]; then
        note "endpoint $TARGET no longer exists"
      else
        refuse "cannot prove task $ID is not live: its endpoint $TARGET reads $state"
      fi
      ;;
  esac
}

prove_slots() {
  local field path slot other unpushed head
  for field in worktree home; do
    path=$(fm_meta_get "$META" "$field")
    if [ -z "$path" ]; then
      note "$field is not recorded (identity missing): nothing to inspect"
      continue
    fi
    if [ ! -d "$path" ]; then
      note "$field $path is gone: nothing to inspect"
      continue
    fi
    slot=$(canonical_dir "$path") || refuse "cannot resolve recorded $field $path"
    fm_treehouse_slot_owner_state "$slot" "$ID"
    other=
    case "$FM_TREEHOUSE_SLOT_OWNER" in
      other) other=$FM_TREEHOUSE_SLOT_OWNER_ID ;;
      unsafe) refuse "the slot-owner claim beside $slot cannot be read, so the slot cannot be proved reassigned (repair the claim, never remove it)" ;;
    esac
    [ -n "$other" ] || other=$(other_record_for_slot "$slot") || other=
    if [ -n "$other" ]; then
      note "$field $slot belongs to task $other: left untouched"
      # Commits on the later task's own branch are its work. Only this
      # record's own branch there would be this record's work.
      head=$(git -C "$slot" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      [ -n "$BRANCH" ] && [ "$head" = "$BRANCH" ] || continue
    fi
    if ! git -C "$slot" rev-parse --git-dir >/dev/null 2>&1; then
      refuse "recorded $field $slot exists but is not an inspectable git worktree, so unpushed commits cannot be ruled out"
    fi
    unpushed=$(git -C "$slot" log --oneline HEAD --not --remotes -- 2>/dev/null) \
      || refuse "cannot inspect $field $slot for commits not on a remote"
    if [ -n "$unpushed" ]; then
      refuse "$field $slot holds commits not on any remote ($(printf '%s\n' "$unpushed" | head -1)); push or land them first"
    fi
    [ -z "$other" ] || continue
    refuse "$field $slot is intact and exclusively task $ID's; this record is not stale - use bin/fm-teardown.sh $ID"
  done
}

prove_landed() {
  local report view state url name
  case "$KIND" in
    scout)
      report="$DATA/$ID/report.md"
      if [ ! -f "$report" ] || [ -L "$report" ]; then
        refuse "scout task $ID has no report at $report"
      fi
      if [ "$(wc -c < "$report" | tr -d ' ')" -lt "$MIN_REPORT_BYTES" ] \
         || ! head -n 1 "$report" | grep -Eq '^#{1,6} +[^ ]'; then
        refuse "scout task $ID's report at $report is not a real report (it needs a Markdown heading on its first line and at least $MIN_REPORT_BYTES bytes)"
      fi
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" >/dev/null 2>&1 \
        || refuse "scout task $ID has not passed the captain-call completion gate (bin/fm-captain-hold.sh verify $ID)"
      note "report $report is a real report"
      ;;
    *)
      [ -d "$PROJ" ] || refuse "ship task $ID's project $PROJ is not available to prove landing"
      if [ "$MODE" = local-only ]; then
        [ -n "$BRANCH" ] || refuse "local-only ship task $ID records no branch to prove landed"
        name=$(default_branch) || refuse "cannot determine the default branch of $PROJ"
        git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" >/dev/null 2>&1 \
          || refuse "local-only branch $BRANCH is not in $PROJ, so its landing cannot be proved"
        if git -C "$PROJ" merge-base --is-ancestor "refs/heads/$BRANCH" "refs/heads/$name" 2>/dev/null; then
          note "branch $BRANCH is merged into local $name"
        elif view=$(git -C "$PROJ" cherry "refs/heads/$name" "refs/heads/$BRANCH" 2>/dev/null) \
            && ! printf '%s\n' "$view" | grep -q '^+'; then
          note "every commit of $BRANCH is in local $name"
        else
          refuse "local-only branch $BRANCH is not landed in $name"
        fi
        return 0
      fi
      if [ -n "$PR_URL" ]; then
        name=$PR_URL
      elif [ -n "$BRANCH" ]; then
        name=$BRANCH
      else
        refuse "ship task $ID records neither a PR nor a branch, so its landing cannot be proved"
      fi
      view=$(cd "$PROJ" && gh pr view "$name" --json state,url -q '.state + "\t" + .url' 2>/dev/null) \
        || refuse "cannot read the pull request for ship task $ID ($name) from the forge, so its landing cannot be proved"
      state=${view%%$'\t'*}
      url=${view#*$'\t'}
      case "$state" in
        MERGED|merged) ;;
        *) refuse "pull request $url for ship task $ID is $state, not merged" ;;
      esac
      [ -n "$PR_URL" ] || PR_URL=$url
      note "pull request $PR_URL is merged"
      ;;
  esac
}

prove_nothing_owed() {
  local keys key verb _text status=0
  keys=
  while IFS=$'\t' read -r key verb _text; do
    [ "$verb" = needs-decision ] || continue
    keys="${keys:+$keys, }$key"
  done <<EOF
$(status_open_decisions "$STATE/$ID.status")
EOF
  [ -z "$keys" ] || refuse "task $ID still has an open keyed decision ($keys) in its status log"
  if [ "$BACKLOG_APPLIES" = 1 ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" >/dev/null 2>&1 || status=$?
    case "$status" in
      0) refuse "task $ID's backlog item is held for the captain; answer it with bin/fm-captain-hold.sh answer first" ;;
      1) ;;
      *) refuse "whether task $ID's backlog item is held for the captain could not be read" ;;
    esac
  fi
  if fm_pf_relay_active "$FM_HOME"; then
    if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
      refuse "this is a secondmate home with the relay active; a public reply owed for $ID cannot be ruled out from here"
    fi
    if fm_pf_has_registrations "$STATE" \
       && ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
         "$SCRIPT_DIR/fm-public-followup.sh" guard-work main "$ID" >/dev/null 2>&1; then
      refuse "task $ID still owes a public reply through the relay"
    fi
  fi
}

# Everything below only READS: the proofs, run before any lock in a dry run and
# again under the locks before a retirement.
prove_stale() {
  NOTES=()
  fm_backlog_record_present "$META" "task record" "$STATE" \
    || refuse "$FM_BACKLOG_TRANSITION_ERROR"
  KIND=$(fm_meta_get "$META" kind)
  [ -n "$KIND" ] || KIND=ship
  case "$KIND" in
    ship|scout) ;;
    secondmate) refuse "task $ID is a secondmate; retire it with bin/fm-teardown.sh" ;;
    *) refuse "task $ID has unrecognised kind $KIND" ;;
  esac
  MODE=$(fm_meta_get "$META" mode)
  BACKEND=$(fm_backend_of_meta "$META")
  TARGET=$(fm_backend_target_of_meta "$META" || true)
  PROJ=$(fm_meta_get "$META" project)
  BRANCH=$(fm_meta_get "$META" branch)
  PR_URL=$(fm_meta_get "$META" pr)
  if ! fm_local_firstmate_state_dirs "$STATE"; then
    refuse "$FM_LOCAL_FIRSTMATE_ERROR, so no other task can be proved not to own this task's slot"
  fi
  LOCAL_STATES=("${FM_LOCAL_FIRSTMATE_STATES[@]}")

  BACKLOG_APPLIES=0
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
    BACKLOG_APPLIES=1
  else
    [ "$?" -ne 2 ] || refuse "the backlog data directory is inaccessible ($FM_BACKLOG_TRANSITION_ERROR)"
    BACKLOG_SKIP_REASON=$FM_BACKLOG_TRANSITION_SKIP
  fi
  if [ "$BACKLOG_APPLIES" = 1 ]; then
    fm_backlog_meta_spawn_gen "$META" "$STATE" \
      || refuse "task $ID's record has no unambiguous spawn_gen ($FM_BACKLOG_TRANSITION_ERROR); use bin/fm-teardown.sh with --legacy-record"
    SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN
  fi

  prove_not_live
  prove_landed
  prove_slots
  prove_nothing_owed

  DONE_ARGS=()
  if [ "$KIND" = scout ]; then
    DONE_ARGS=(--report "$(fm_backlog_data_relative "$DATA")/$ID/report.md")
  elif [ "$MODE" = local-only ]; then
    DONE_ARGS=(--note "local main")
  elif [ -n "$PR_URL" ]; then
    DONE_ARGS=(--pr "$PR_URL")
  fi
}

# The watcher's per-window marker key (bin/fm-watch.sh window_key owns it):
# ':', '/' and '.' become '_'.
window_key() {
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

# Candidate record paths for this task, one per line. Every name is derived from
# the task id or from this record's own endpoint, so no other task's file can be
# named; each is only ever removed if it exists.
candidate_paths() {
  local suffix k
  for suffix in status turn-ended progress busy-gen busy-state inbox git-hooks \
    pi-ext.ts omp-ext.ts grok-turnend-token kimi-turnend-token muse-session \
    muse-session-current cursor-session control-relaunch control-relaunch.meta-prior \
    control-relaunch.brief-prior control-relaunch.note reconcile-nudged \
    gemini-settings.json devin-config.json check.sh pr-poll pr-poll-registration \
    pr-poll-retirement merge-authority check-trust pr-poll-merge-notified; do
    printf '%s/%s.%s\n' "$STATE" "$ID" "$suffix"
  done
  printf '%s\n' \
    "$STATE/.$ID.branch-outcome-index" "$STATE/.$ID.home-appends" \
    "$STATE/.$ID.home-appends.lock" "$STATE/.$ID.open-decisions-cursor" \
    "$(fm_wake_signal_seen_path "$STATE" "$STATE/$ID.status")" \
    "$(fm_wake_signal_seen_path "$STATE" "$STATE/$ID.turn-ended")" \
    "$(status_signal_seen_marker_path "$STATE" "$ID")" \
    "$(status_heartbeat_seen_marker_path "$STATE" "$ID")" \
    "$(status_daemon_seen_marker_path "$STATE" "$ID")"
  if [ -n "$WINDOW_KEY" ]; then
    for k in hash count stale stale-since wedge-escalations paused paused-rechecked \
      paused-resurfaced writing-since writing-resurfaced waiting-resurfaced; do
      printf '%s/.%s-%s\n' "$STATE" "$k" "$WINDOW_KEY"
    done
  fi
}

# prove_not_live already refused an endpoint another record names, so the
# per-window markers of the recorded endpoint are this task's alone.
resolve_window_key() {
  local window
  WINDOW_KEY=
  window=$(fm_meta_get "$META" window)
  [ -n "$window" ] || return 0
  WINDOW_KEY=$(window_key "$window")
}

report_plan() {
  local path n=0 note
  printf 'task %s (%s) is a stale record that can be retired:\n' "$ID" "$KIND"
  for note in "${NOTES[@]+"${NOTES[@]}"}"; do
    printf '  proof: %s\n' "$note"
  done
  while IFS= read -r path; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf '  would remove: %s\n' "$path"
      n=$((n + 1))
    fi
  done <<EOF
$(candidate_paths)
EOF
  printf '  would remove: %s (the record, last)\n' "$META"
  if [ "$BACKLOG_APPLIES" = 1 ]; then
    printf '  would close backlog item %s (%s)\n' "$ID" "${DONE_ARGS[*]-no completion link}"
  else
    printf '  backlog: %s; the item is not touched\n' "$BACKLOG_SKIP_REASON"
  fi
  printf '  never touched: any worktree or slot, endpoint, data/%s/, another task\n' "$ID"
}

# --- run ----------------------------------------------------------------------

fm_refuse_if_gate_agent

fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: retire refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}

if [ ! -e "$META" ] && [ ! -L "$META" ]; then
  echo "retire $ID: no task record at $META; nothing to retire"
  exit 0
fi

if [ "$CONFIRM" = 0 ]; then
  prove_stale
  resolve_window_key
  report_plan
  echo "dry run: nothing was changed; re-run with --confirm to retire the record"
  exit 0
fi

fm_lease_guard "$ID" "stale-record retirement (fm-retire-stale-record)"
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
FM_LOCK_LOG_PREFIX=retire
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
# A concurrent teardown may have finished while this waited for the lock.
if [ ! -e "$META" ] && [ ! -L "$META" ]; then
  echo "retire $ID: no task record at $META; nothing to retire"
  exit 0
fi
prove_stale
resolve_window_key

BUSY_GEN=$(fm_meta_get "$META" busy_gen)
[ -n "$BUSY_GEN" ] || BUSY_GEN=$(cat "$STATE/$ID.busy-gen" 2>/dev/null || true)
fm_pr_task_artifacts_validate "$STATE" "$ID" || exit 1

BACKLOG_CLOSED=0
if [ "$BACKLOG_APPLIES" = 1 ]; then
  fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$SPAWN_GEN" \
    "${DONE_ARGS[@]+"${DONE_ARGS[@]}"}" || {
    echo "error: the pending backlog close for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); retaining every durable task record" >&2
    exit 1
  }
  BACKLOG_CLOSED=1
fi

fm_pr_task_artifacts_remove "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || exit 1
if [ -n "$BUSY_GEN" ]; then
  "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --gen "$BUSY_GEN" || exit 1
elif [ -f "$STATE/$ID.busy-gen" ]; then
  "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --current-gen || exit 1
fi
status_retire_presentation_task "$STATE" "$ID" || exit 1
fm_wake_queue_prune_task "$STATE" "$ID" "$TARGET" 2>/dev/null || true
if [ -n "$WINDOW_KEY" ]; then
  fm_backend_clear_transition "$BACKEND" "$STATE" "$TARGET" || true
fi
# The spawn-owned hooks directory is left read-only by its installer; never
# chmod through a link planted in its place (rm below drops a link itself).
if [ -d "$STATE/$ID.git-hooks" ] && [ ! -L "$STATE/$ID.git-hooks" ]; then
  chmod u+w "$STATE/$ID.git-hooks" 2>/dev/null || true
fi
while IFS= read -r path; do
  [ -e "$path" ] || [ -L "$path" ] || continue
  rm -rf -- "$path"
done <<EOF
$(candidate_paths)
EOF

if [ "$BACKLOG_CLOSED" = 1 ]; then
  MARKER=$(fm_backlog_close_marker_path "$STATE" "$ID") || exit 1
  if ! fm_backlog_atomic_transition close "$META" "$MARKER" "$DATA" "$ID" "$STATE" \
      "${DONE_ARGS[@]+"${DONE_ARGS[@]}"}"; then
    echo "error: $ID's stale records are removed, but its backlog item could not be closed atomically ($FM_BACKLOG_TRANSITION_ERROR); the pending close is recorded and the next session start retries it" >&2
    exit 1
  fi
elif ! fm_backlog_atomic_transition remove "$META" "task record" "$STATE"; then
  echo "error: $ID's stale records are removed, but its task record could not be removed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
echo "retire $ID complete: stale record removed; no worktree, slot or endpoint was touched"
if [ "$BACKLOG_CLOSED" = 1 ]; then
  echo "Backlog: $ID is closed. Run bin/fm-tasks-axi.sh ready for dependency-cleared candidates."
else
  echo "Backlog: not changed ($BACKLOG_SKIP_REASON); update it by hand if $ID still shows in flight."
fi
