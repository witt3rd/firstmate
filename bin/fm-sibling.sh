#!/usr/bin/env bash
# fm-sibling.sh - FORK-ONLY EXPERIMENT: send a note to a sibling worker.
# Usage: fm-sibling.sh <sibling-task-id> <message...>
#
# A worker (crewmate or scout) may note a sibling crewmate under the SAME
# firstmate home, and a secondmate may note a sibling secondmate under the SAME
# main firstmate, so stacked or dependent work need not bottleneck on the
# parent. docs/sibling-notes.md owns the contract; this header only pins the
# mechanics:
#   1. REFUSES unless config/sibling-notes (first word "on") is present in the
#      caller's own home. Default off; inherited into secondmate homes through
#      FM_INHERITABLE_CONFIG (bin/fm-config-inherit-lib.sh).
#   2. RESOLVES the caller from its own launch identity, never from a path it
#      supplies: a crewmate is FM_TASK_ID in FM_HOME's state/<id>.meta (kind
#      ship or scout), its parent is that home; a secondmate is the home's
#      .fm-secondmate-home marker plus .fm-secondmate-parent binding, proved
#      against the parent's data/secondmates.md registry. The target must be a
#      registered direct report of THAT SAME parent and of the same kind
#      (crewmate to crewmate in this home's state/meta; secondmate to secondmate
#      in the parent's registry and state/meta). Self, the parent, another
#      parent's workers, another kind, and remote secondmates are refused.
#   3. WRITES the note into the target's existing steering inbox with the
#      existing inbox library and rings the existing doorbell. The record is
#      marked [FM-SIBLING-NOTE from=<sender> ...] and states it carries no
#      authority; the receiver acknowledges it like any inbox message.
#   4. COPIES the parent: a `note:` line (sibling-note from <sender> to
#      <target>: <text or pointer>) is appended to the SENDER's own status file,
#      which the parent's watcher already surfaces as unread status. The copy
#      is written before delivery, so a parent is never the last to know.
#   5. RATE-LIMITS per sender and per sibling pair and refuses ping-pong loops,
#      from one ledger (state/.sibling-notes.ledger in the parent's state dir,
#      so both directions of a pair are seen); the limits live in the single
#      FM_SIBLING_LIMITS constant in bin/fm-sibling-lib.sh.
# Exit: 0 delivered; 1 refused or failed (nothing or only a correction line was
# recorded); 2 usage. Not a general chat mode: one command, one note.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage: fm-sibling.sh <sibling-task-id> <message...>
Fork-only experiment (docs/sibling-notes.md): note a sibling under your own parent.
USAGE
  exit 2
}

case "${1:-}" in
  -h|--help) usage ;;
esac
[ "$#" -ge 2 ] || usage

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# A no-mistakes gate agent must never message fleet workers.
fm_refuse_if_gate_agent

# shellcheck source=bin/fm-sibling-lib.sh
. "$SCRIPT_DIR/fm-sibling-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() {
  echo "fm-sibling: $*" >&2
  exit 1
}

id_ok() {  # <id>
  case "$1" in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

TARGET=$1
shift
TEXT=$*

[ -n "${FM_HOME:-}" ] || die "FM_HOME is not set; sibling notes resolve the parent from the caller's own home"
[ -d "$FM_HOME" ] || die "FM_HOME '$FM_HOME' is not a directory"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || die "state dir '$STATE' is missing"

fm_sibling_notes_enabled "$CONFIG" ||
  die "sibling notes are off (fork-only experiment); this home has no config/sibling-notes set to on"

[ -n "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] || die "the note is empty"
[ "${#TEXT}" -le "$FM_SIBLING_TEXT_MAX" ] ||
  die "the note is ${#TEXT} characters (limit $FM_SIBLING_TEXT_MAX); notes are short coordination hints, so send a pointer, not a document"
id_ok "$TARGET" || die "'$TARGET' is not a valid sibling task id"

# --- sender identity and parent binding (never a caller-supplied path) -------
SENDER=
ROLE=
PARENT_STATE=
STATUS_FILE=
if [ -n "${FM_TASK_ID:-}" ]; then
  ROLE=crew
  SENDER=$FM_TASK_ID
  id_ok "$SENDER" || die "FM_TASK_ID is not a valid task id"
  SENDER_META="$STATE/$SENDER.meta"
  [ -f "$SENDER_META" ] || die "no task record for $SENDER in this home; only a registered worker can send a sibling note"
  case "$(fm_meta_get "$SENDER_META" kind)" in
    ship|scout) ;;
    *) die "$SENDER is not a crewmate or scout in this home" ;;
  esac
  [ -z "$(fm_meta_get "$SENDER_META" remote_host)" ] || die "remote workers are not supported by sibling notes yet"
  PARENT_STATE=$STATE
  STATUS_FILE="$STATE/$SENDER.status"
else
  ROLE=mate
  SENDER=$(fm_parent_channel_home_id "$FM_HOME") ||
    die "this is neither a registered worker nor a secondmate home; there is no sibling relationship to use"
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || die "cannot read the parent binding of this secondmate home"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] ||
    die "a secondmate with a remote parent route cannot send sibling notes yet (fork-only experiment: local routes only)"
  rc=0
  STATUS_FILE=$(fm_parent_channel_destination "$FM_HOME" "$STATE") || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$STATUS_FILE" ] || die "cannot resolve the parent binding of this secondmate home"
  PARENT_HOME=$FM_SECONDMATE_PARENT_HOME
  PARENT_STATE="$PARENT_HOME/state"
  REGISTRY="$PARENT_HOME/data/secondmates.md"
  secondmate_registry_line_for_id "$REGISTRY" "$SENDER" ||
    die "$SENDER is not registered in its parent's secondmate registry"
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || die "remote secondmates are not supported by sibling notes yet"
  [ "$(cd "$SECONDMATE_REGISTRY_HOME" 2>/dev/null && pwd -P)" = "$(cd "$FM_HOME" && pwd -P)" ] ||
    die "the registry's home for $SENDER is not this home; refusing to act as that secondmate"
fi

[ "$TARGET" != "$SENDER" ] || die "refusing to note yourself"

# --- the target must be a registered direct report of the SAME parent --------
TARGET_META="$PARENT_STATE/$TARGET.meta"
if [ "$ROLE" = crew ]; then
  [ -f "$TARGET_META" ] || die "$TARGET is not a registered worker under your parent; sibling notes stay within one parent's scope"
  case "$(fm_meta_get "$TARGET_META" kind)" in
    ship|scout) ;;
    *) die "$TARGET is not a sibling crewmate or scout under your parent" ;;
  esac
else
  secondmate_registry_line_for_id "$REGISTRY" "$TARGET" ||
    die "$TARGET is not a secondmate registered under your parent; sibling notes stay within one parent's scope"
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || die "remote secondmates are not supported by sibling notes yet"
  [ -f "$TARGET_META" ] && [ "$(fm_meta_get "$TARGET_META" kind)" = secondmate ] ||
    die "$TARGET has no live secondmate record under your parent"
fi
[ -z "$(fm_meta_get "$TARGET_META" remote_host)" ] || die "$TARGET is remote; sibling notes do not support remote workers yet"
T=$(fm_backend_target_of_meta "$TARGET_META")
[ -n "$T" ] || die "no endpoint is recorded for $TARGET"
TARGET_BACKEND=$(fm_backend_of_meta "$TARGET_META")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$TARGET" "$PARENT_STATE")

# --- limits, parent copy, durable delivery (serialized on the ledger) --------
LEDGER="$PARENT_STATE/.sibling-notes.ledger"
LEDGER_LOCK="$PARENT_STATE/.sibling-notes.lock"
fm_task_inbox_lock_acquire "$LEDGER_LOCK" || die "could not lock the sibling-note ledger; try again"
release_ledger() { fm_lock_release "$LEDGER_LOCK" || true; }
trap release_ledger EXIT

NOW=$(date +%s)
LEDGER_TEXT=
[ ! -f "$LEDGER" ] || LEDGER_TEXT=$(cat "$LEDGER")
if ! REASON=$(printf '%s' "$LEDGER_TEXT" | fm_sibling_ledger_check "$NOW" "$SENDER" "$TARGET"); then
  die "${REASON:-refused by the sibling-note limits}"
fi

append_status() {  # <status-line>
  fm_parent_channel_append_once "$STATUS_FILE" "$(status_stamp_line "$1")" || return 1
  [ ! -e "$CONFIG/fleet-ledger" ] ||
    "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$STATUS_FILE" >/dev/null 2>&1 || true
}

EXCERPT=$(fm_parent_channel_clean_note "$TEXT")
if [ "${#EXCERPT}" -gt "$FM_SIBLING_STATUS_TEXT_MAX" ]; then
  EXCERPT="${EXCERPT:0:$FM_SIBLING_STATUS_TEXT_MAX}... [full text in $PARENT_STATE/$TARGET.inbox]"
fi
append_status "note: sibling-note from $SENDER to $TARGET: $EXCERPT" ||
  die "could not copy the parent on $STATUS_FILE; the note was not sent"

BODY=$(fm_sibling_record_text "$SENDER" "$TARGET" "$SCRIPT_DIR/fm-sibling.sh" "$TEXT")
META_LOCK=$(fm_meta_lock_path "$TARGET_META") || die "cannot lock the record of $TARGET"
failed() {  # <reason>
  append_status "note: sibling-note from $SENDER to $TARGET was NOT delivered: $1" || true
  die "note not delivered to $TARGET: $1"
}
fm_task_inbox_lock_acquire "$META_LOCK" || failed "its task record could not be locked"
if [ "$(fm_backend_target_of_meta "$TARGET_META")" != "$T" ] ||
  [ "$(fm_backend_of_meta "$TARGET_META")" != "$TARGET_BACKEND" ]; then
  fm_lock_release "$META_LOCK"
  failed "it retired or changed endpoint"
fi
write_rc=0
RECORD=$(fm_task_inbox_write "$PARENT_STATE" "$TARGET" "$BODY") || write_rc=$?
fm_lock_release "$META_LOCK"
[ "$write_rc" -eq 0 ] || failed "its inbox record could not be written"

printf '%s' "$LEDGER_TEXT" | fm_sibling_ledger_append "$NOW" "$SENDER" "$TARGET" > "$LEDGER.tmp.$$" &&
  mv "$LEDGER.tmp.$$" "$LEDGER" ||
  echo "fm-sibling: warning: the note was delivered but the rate ledger could not be updated" >&2
release_ledger
trap - EXIT

ring_rc=0
fm_task_inbox_ring "$TARGET_BACKEND" "$T" "$RECORD" "$EXPECTED_LABEL" || ring_rc=$?
case "$ring_rc" in
  1) echo "fm-sibling: doorbell skipped (composer holds pending text); the note is durably recorded at $RECORD and the watcher will re-ring" >&2 ;;
  2) echo "fm-sibling: doorbell did not reach $T; the note is durably recorded at $RECORD and the watcher will re-ring" >&2 ;;
  3) echo "fm-sibling: $TARGET's agent has exited; the note is durably recorded at $RECORD for recovery" >&2 ;;
esac
echo "fm-sibling: note delivered to $TARGET (parent copied on $SENDER's status file)"
