#!/usr/bin/env bash
# Read or set a remote second-mate route's backend in data/secondmates.md.
#
# Usage:
#   fm-remote-route-backend.sh <id>                 print herdr or tmux
#   fm-remote-route-backend.sh <id> herdr|tmux      set it
#
# The route's backend is the optional `backend: tmux;` field right after home:
# in its registry record (bin/fm-secondmate-registry-lib.sh owns the grammar);
# herdr is written as no field at all, so setting herdr restores the record
# byte for byte. Setting it rewrites only that one field of that one record,
# atomically, under the registry lock, validates the whole registry afterwards,
# and puts the previous registry back when validation refuses. It changes no
# endpoint: moving a live mate between backends is
# bin/fm-remote-secondmate-control.sh migrate plus a relaunch
# (docs/remote-secondmates.md "Move a route between backends"). Only a remote
# route has a backend; a local record is refused.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
ID=$1
WANT=${2:-}
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$WANT" in ''|herdr|tmux) ;; *) usage ;; esac
[ -f "$REG" ] && [ ! -L "$REG" ] || die "no safe secondmate registry at $REG"

if [ -z "$WANT" ]; then
  secondmate_registry_line_for_id "$REG" "$ID" || die "no valid registry record for $ID"
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || die "$ID is a local secondmate and has no remote backend"
  printf '%s\n' "$SECONDMATE_REGISTRY_BACKEND"
  exit 0
fi

mkdir -p "$STATE"
LOCK=$(secondmate_registry_lock_path "$STATE")
fm_lock_acquire_wait "$LOCK" || die "cannot lock the secondmate registry"
TMP=$(mktemp "${TMPDIR:-/tmp}/fm-route-backend.XXXXXX") || { fm_lock_release "$LOCK"; die "cannot stage the registry"; }
BEFORE=$(mktemp "${TMPDIR:-/tmp}/fm-route-backend-before.XXXXXX") || { rm -f "$TMP"; fm_lock_release "$LOCK"; die "cannot stage the registry"; }
cleanup() { rm -f -- "$TMP" "$BEFORE"; fm_lock_release "$LOCK"; }
trap cleanup EXIT

secondmate_registry_line_for_id "$REG" "$ID" || die "no valid registry record for $ID"
[ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || die "$ID is a local secondmate and has no remote backend"
LINE=$SECONDMATE_REGISTRY_LINE
OLD=$SECONDMATE_REGISTRY_BACKEND
if [ "$OLD" = "$WANT" ]; then
  printf 'already: %s is on %s\n' "$ID" "$WANT"
  exit 0
fi
NEEDLE="(host: $SECONDMATE_REGISTRY_HOST; root: $SECONDMATE_REGISTRY_ROOT; home: $SECONDMATE_REGISTRY_HOME; "
case "$LINE" in *"$NEEDLE"*) ;; *) die "the record for $ID is not in the canonical field spacing; edit it by hand" ;; esac
PREFIX=${LINE%"$NEEDLE"*}
SUFFIX=${LINE##*"$NEEDLE"}
case "$SUFFIX" in backend:*) SUFFIX=${SUFFIX#*; } ;; esac
FIELD=
[ "$WANT" = herdr ] || FIELD="backend: $WANT; "
NEW="$PREFIX$NEEDLE$FIELD$SUFFIX"

cp "$REG" "$BEFORE"
while IFS= read -r row || [ -n "$row" ]; do
  if [ "$row" = "$LINE" ]; then printf '%s\n' "$NEW"; else printf '%s\n' "$row"; fi
done < "$REG" > "$TMP"
mv -f -- "$TMP" "$REG"
if ! secondmate_registry_validate_bindings "$REG" secondmate_registry_path_key "$ID" "$SECONDMATE_REGISTRY_HOME"; then
  ERR=$SECONDMATE_REGISTRY_ERROR
  cp "$BEFORE" "$REG"
  die "the registry did not validate with that backend ($ERR); it was restored"
fi
printf 'set: %s backend %s -> %s\n' "$ID" "$OLD" "$WANT"
