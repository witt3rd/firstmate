#!/usr/bin/env bash
# Who owns the fm-remote-tmux server socket, and is that process the systemd
# unit's own?
#
# Source this file; it defines names and functions only. It is the single owner
# of the remote tmux route's fixed names and of the server-ownership
# classification shared by bin/fm-remote-tmux-guard.sh (the unit's exec target)
# and bin/fm-remote-doctor.sh (the readiness check for that route).
#
# Why ownership matters: the tmux route exists so a remote second mate's
# endpoint survives every SSH disconnection. A server started from a login
# session, an SSH command, or a client's autostart lives in that session's
# scope and dies with it, and a server born with NoNewPrivs=1 breaks sudo in
# every pane. Only a server that is the process tree of the system unit
# fm-remote-tmux.service is neither. The classification reads the server's
# kernel cgroup, not any tmux output, so it cannot be spoofed by a session name.
#
# Fixed names (override only in tests):
#   FM_REMOTE_TMUX_SESSION  the session every remote second mate lives in
#   FM_REMOTE_TMUX_UNIT     the system unit that owns the server
#   fm_remote_tmux_socket_path
#     Prints the absolute socket path, ${HOME}/.firstmate/remote-tmux/
#     <session>.sock. An explicit path (tmux -S), rather than tmux -L, because
#     the default socket directory depends on TMUX_TMPDIR and XDG_RUNTIME_DIR,
#     which a system unit and an SSH job worker do not share.
#
# Functions:
#   fm_remote_tmux_server_pid <tmux-bin> <socket>
#     Prints the pid of the tmux server listening on <socket>. Returns 1 when
#     tmux answers definitively that no server is there, and 2 when the answer
#     cannot be read (tmux unusable, a transient error): the caller decides what
#     an unprovable owner means.
#   fm_remote_tmux_pid_unit <pid>
#     Prints the system unit whose cgroup holds <pid> (the unit name only, for
#     example fm-remote-tmux.service), or nothing when <pid> is not in a system
#     unit. Returns 1 when its cgroup cannot be read. FM_REMOTE_TMUX_PROC_ROOT
#     (default /proc) relocates the read for tests.
#   fm_remote_tmux_owner <tmux-bin> <socket> <unit>
#     Prints exactly one line, "<class>" or "<class> <pid>":
#       absent    no server listens on the socket
#       unit      the server is a process of <unit> (the verified state)
#       foreign   a server runs outside <unit>; it is unverified and must be
#                 left untouched
#       unproven  a server may run but its owner cannot be read

FM_REMOTE_TMUX_SESSION=${FM_REMOTE_TMUX_SESSION:-fm-remote-tmux}
FM_REMOTE_TMUX_UNIT=${FM_REMOTE_TMUX_UNIT:-fm-remote-tmux.service}

fm_remote_tmux_socket_path() {
  [ -n "${HOME:-}" ] || return 1
  printf '%s/.firstmate/remote-tmux/%s.sock\n' "$HOME" "$FM_REMOTE_TMUX_SESSION"
}

fm_remote_tmux_server_pid() { # <tmux-bin> <socket>
  local tmux_bin=$1 socket=$2 out rc pid
  [ -n "$tmux_bin" ] && [ -x "$tmux_bin" ] && [ -n "$socket" ] || return 2
  if out=$(LC_ALL=C "$tmux_bin" -S "$socket" list-sessions -F '#{pid}' 2>&1); then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      'no server running on '*|'error connecting to '*'(No such file or directory)'*|'error connecting to '*'(Connection refused)'*)
        return 1
        ;;
    esac
    return 2
  fi
  pid=$(printf '%s\n' "$out" | head -1)
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  printf '%s\n' "$pid"
}

fm_remote_tmux_pid_unit() { # <pid>
  local pid=$1 file path line rest
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  file="${FM_REMOTE_TMUX_PROC_ROOT:-/proc}/$pid/cgroup"
  [ -r "$file" ] || return 1
  path=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      0::*) path=${line#0::}; break ;;
      *:name=systemd:*) rest=${line#*:name=systemd:}; path=$rest ;;
    esac
  done < "$file"
  case "$path" in
    /system.slice/*.service|/system.slice/*.service/*)
      rest=${path#/system.slice/}
      printf '%s\n' "${rest%%/*}"
      ;;
  esac
  return 0
}

fm_remote_tmux_owner() { # <tmux-bin> <socket> <unit>
  local tmux_bin=$1 socket=$2 unit=$3 pid rc owner
  if pid=$(fm_remote_tmux_server_pid "$tmux_bin" "$socket"); then rc=0; else rc=$?; fi
  case "$rc" in
    0) ;;
    1) printf 'absent\n'; return 0 ;;
    *) printf 'unproven\n'; return 0 ;;
  esac
  owner=$(fm_remote_tmux_pid_unit "$pid") || { printf 'unproven %s\n' "$pid"; return 0; }
  if [ -n "$owner" ] && [ "$owner" = "$unit" ]; then
    printf 'unit %s\n' "$pid"
  else
    printf 'foreign %s\n' "$pid"
  fi
}
