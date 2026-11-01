#!/usr/bin/env bash
# systemd exec target for the Firstmate-owned fm-remote-tmux.service system
# unit: make the unit own the fm-remote-tmux server, or refuse and leave a
# server it does not own untouched.
#
# Usage:
#   fm-remote-tmux-guard.sh <tmux-path> <socket-path> <session> <unit>
#
# bin/fm-remote-doctor.sh renders the unit as `User=<account>`, runs this script
# through the account's login shell (`-l -c 'exec <this script> ...'`) so the
# server and every pane it spawns inherit the account's own environment, and
# installs it as a system unit (WantedBy=multi-user.target, Restart=always,
# RestartPreventExitStatus=3). `tmux -D` keeps the server in the foreground, so
# the final exec makes the server the unit's main process and systemd supervises
# its whole lifecycle.
#
# Decision, made once per start (bin/fm-remote-tmux-owner-lib.sh owns the
# classification, which reads the server's cgroup rather than tmux output):
#   absent     no server listens on the socket -> exec the foreground server,
#              which creates <session> from a one-line config file
#   unit       a server of this very unit already runs -> exit 3, nothing to start
#   foreign    a server runs outside <unit> (started from a login session, an
#              SSH command, or a client's autostart) -> exit 3
#   unproven   a server may run but its owner cannot be read -> exit 3
# Exit 3 is the unit's RestartPreventExitStatus, so a refused start rests
# instead of looping, and the doctor reports the refusal as a gap. The guard
# never stops, signals, or takes over a server it did not start: that server's
# windows may hold a live second mate, and replacing it is an operator decision.
# Every decision prints one line to stdout, which the journal records.
set -u

SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
# shellcheck source=bin/fm-remote-tmux-owner-lib.sh
. "$SCRIPT_DIR/fm-remote-tmux-owner-lib.sh"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ "$#" -eq 4 ] || usage
TMUX_BIN=$1
SOCKET=$2
SESSION=$3
UNIT=$4
log() { printf 'fm-remote-tmux-guard: %s\n' "$*"; }
[ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ] || { printf 'fm-remote-tmux-guard: tmux is not executable: %s\n' "$TMUX_BIN" >&2; exit 1; }
case "$SOCKET" in /*) ;; *) printf 'fm-remote-tmux-guard: the socket path must be absolute: %s\n' "$SOCKET" >&2; exit 2 ;; esac
case "$SESSION" in ''|*[!A-Za-z0-9._-]*) printf 'fm-remote-tmux-guard: invalid session name: %s\n' "$SESSION" >&2; exit 2 ;; esac
case "$UNIT" in ?*.service) ;; *) printf 'fm-remote-tmux-guard: the unit must be a .service name: %s\n' "$UNIT" >&2; exit 2 ;; esac

OWNER=$(fm_remote_tmux_owner "$TMUX_BIN" "$SOCKET" "$UNIT")
CLASS=${OWNER%% *}
PID=${OWNER#"$CLASS"}
PID=${PID# }
case "$CLASS" in
  absent) ;;
  unit)
    log "a server of $UNIT (pid $PID) already owns $SOCKET; nothing to start"
    exit 3
    ;;
  foreign)
    log "session $SESSION is served by pid $PID outside $UNIT; it is unverified and left untouched"
    exit 3
    ;;
  *)
    log "$SOCKET may be served, but its owner cannot be proven; leaving it untouched"
    exit 3
    ;;
esac

SOCKET_DIR=${SOCKET%/*}
CONFIG="$SOCKET_DIR/$SESSION.conf"
( umask 077 && mkdir -p -- "$SOCKET_DIR" ) || { log "cannot create $SOCKET_DIR"; exit 1; }
TMP_CONFIG="$CONFIG.tmp.$$"
{
  printf 'set -g history-limit 20000\n'
  printf 'new-session -d -s %s\n' "$SESSION"
} > "$TMP_CONFIG" || { rm -f -- "$TMP_CONFIG"; log "cannot write $CONFIG"; exit 1; }
mv -f -- "$TMP_CONFIG" "$CONFIG" || { rm -f -- "$TMP_CONFIG"; log "cannot publish $CONFIG"; exit 1; }
log "starting the tmux server for session $SESSION on $SOCKET inside $UNIT (pid $$)"
exec "$TMUX_BIN" -D -S "$SOCKET" -f "$CONFIG"
