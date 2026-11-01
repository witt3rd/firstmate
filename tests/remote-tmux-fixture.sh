#!/usr/bin/env bash
# tests/remote-tmux-fixture.sh - the stateful host-local tmux fixture the
# remote second-mate tmux-route suites install on their fake remote host.
#
# The tmux route (docs/remote-secondmates.md) keeps a remote second mate in a
# tmux server that a systemd system unit owns. A test cannot start a system
# unit, so this fixture keeps the two facts the route reads and fakes only the
# one it cannot make:
#   - the server is a REAL tmux server on a real private socket, so every
#     window, capture, and send the route performs is real tmux state;
#   - the unit's ownership is a per-pid cgroup file under a fake proc root
#     (FM_REMOTE_TMUX_PROC_ROOT), which is exactly where
#     bin/fm-remote-tmux-owner-lib.sh reads it from.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/remote-tmux-fixture.sh"
#   remote_tmux_fixture_init <fixture-dir>
#     Sets RT_HOME, RT_SOCKET, RT_PROC, RT_UNIT, RT_SESSION. <fixture-dir> must
#     be short: a unix socket path is limited to about 100 bytes.
#   remote_tmux_start_outside
#     Starts a server on RT_SOCKET the way an SSH command or a client autostart
#     would, outside any unit. Sets RT_SERVER_PID. The server, and so every
#     window it opens, runs under an empty environment with HOME=RT_HOME and
#     PATH=$RT_SERVER_PATH (default: the caller's PATH), so a test can put a
#     stand-in harness first and the account's own dotfiles never apply.
#   remote_tmux_set_cgroup <pid> <cgroup-line-content>
#     Writes <pid>'s fake /proc/<pid>/cgroup, for example
#     '0::/system.slice/fm-remote-tmux.service'.
#   remote_tmux_stop
#     Kills only the server on RT_SOCKET, addressed through that socket.

# shellcheck disable=SC2034 # the variables are the fixture's API for the sourcing test.
remote_tmux_fixture_init() { # <fixture-dir>
  RT_HOME=$1/home
  RT_PROC=$1/proc
  RT_UNIT=fm-remote-tmux.service
  RT_SESSION=fm-remote-tmux
  RT_SOCKET=$RT_HOME/.firstmate/remote-tmux/$RT_SESSION.sock
  mkdir -p "$RT_HOME" "$RT_PROC"
  RT_SERVER_PID=
}

# shellcheck disable=SC2034
remote_tmux_start_outside() {
  mkdir -p "$(dirname "$RT_SOCKET")"
  env -i HOME="$RT_HOME" PATH="${RT_SERVER_PATH:-$PATH}" TERM=xterm \
    "$(command -v tmux)" -S "$RT_SOCKET" -f /dev/null new-session -d -s "$RT_SESSION" || return 1
  # Windows run bash, not the runner's login shell, so an idle window reads as a shell.
  env -u TMUX tmux -S "$RT_SOCKET" set-option -g default-shell "$(command -v bash)"
  RT_SERVER_PID=$(env -u TMUX tmux -S "$RT_SOCKET" list-sessions -F '#{pid}' | head -1)
}

remote_tmux_set_cgroup() { # <pid> <content>
  mkdir -p "$RT_PROC/$1"
  printf '%s\n' "$2" > "$RT_PROC/$1/cgroup"
}

remote_tmux_stop() {
  [ -n "${RT_SOCKET:-}" ] || return 0
  env -u TMUX tmux -S "$RT_SOCKET" kill-server 2>/dev/null || true
}
