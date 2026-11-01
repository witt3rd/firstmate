#!/usr/bin/env bash
# tests/fm-remote-tmux-guard.test.sh - the fm-remote-tmux unit's guard.
#
# Drives the real bin/fm-remote-tmux-guard.sh and the owner library it sources
# against real tmux servers on a private socket (tests/remote-tmux-fixture.sh).
# The only fake is the per-pid cgroup file under a fake proc root, because a test
# cannot start a systemd system unit. It pins the decision table: no server ->
# become the server; a server of the unit, outside the unit, or of unreadable
# ownership -> exit 3 and leave that server exactly as it was. The verdict comes
# from a kernel fact (the cgroup), not vendor output, so no live harness guard
# applies.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-tmux-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-tmux-fixture.sh"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

GUARD="$ROOT/bin/fm-remote-tmux-guard.sh"
TMUX_BIN=$(command -v tmux)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fmrt.XXXXXX") || fail "cannot create the fixture directory"
GUARD_PIDS=()
cleanup() {
  remote_tmux_stop
  if [ "${#GUARD_PIDS[@]}" -gt 0 ]; then kill "${GUARD_PIDS[@]}" 2>/dev/null || true; fi
  rm -rf "$FIXTURE"
  fm_test_cleanup || true
}
trap cleanup EXIT
remote_tmux_fixture_init "$FIXTURE"

tmux_rt() { env -u TMUX "$TMUX_BIN" -S "$RT_SOCKET" "$@"; }
wait_for_server() { # sets RT_SERVER_PID
  local i=0
  while [ "$i" -lt 100 ]; do
    RT_SERVER_PID=$(tmux_rt list-sessions -F '#{pid}' 2>/dev/null | head -1)
    [ -z "$RT_SERVER_PID" ] || return 0
    sleep 0.05
    i=$((i + 1))
  done
  fail "no tmux server answered on $RT_SOCKET"
}
reset_host() {
  remote_tmux_stop
  rm -rf "$RT_HOME" "$RT_PROC"
  remote_tmux_fixture_init "$FIXTURE"
}
guard() { # <args...>; sets GUARD_OUT and GUARD_RC
  set +e
  GUARD_OUT=$(env -i PATH="$PATH" HOME="$RT_HOME" FM_REMOTE_TMUX_PROC_ROOT="$RT_PROC" \
    "$GUARD" "$@" 2>&1)
  GUARD_RC=$?
  set -e
}
std_guard() { guard "$TMUX_BIN" "$RT_SOCKET" "$RT_SESSION" "$RT_UNIT"; }

test_no_server_becomes_the_server() {
  reset_host
  env -i PATH="$PATH" HOME="$RT_HOME" FM_REMOTE_TMUX_PROC_ROOT="$RT_PROC" \
    "$GUARD" "$TMUX_BIN" "$RT_SOCKET" "$RT_SESSION" "$RT_UNIT" >"$FIXTURE/guard.out" 2>&1 &
  local guard_pid=$!
  GUARD_PIDS+=("$guard_pid")
  wait_for_server
  [ "$RT_SERVER_PID" = "$guard_pid" ] \
    || fail "the guard did not exec the server in place (guard pid $guard_pid, server pid $RT_SERVER_PID)"
  assert_equals "$RT_SESSION" "$(tmux_rt list-sessions -F '#{session_name}' | head -1)" \
    "the guard's server has the wrong session"
  assert_equals off "$(tmux_rt show-options -gv exit-empty)" \
    "the foreground server would exit when its last window closes"
  assert_contains "$(cat "$FIXTURE/guard.out")" "starting the tmux server for session $RT_SESSION" \
    "the guard did not log the start"
  # The server is the unit's own process once its cgroup says so.
  remote_tmux_set_cgroup "$guard_pid" "0::/system.slice/$RT_UNIT"
  # shellcheck source=bin/fm-remote-tmux-owner-lib.sh
  . "$ROOT/bin/fm-remote-tmux-owner-lib.sh"
  assert_equals "unit $guard_pid" "$(FM_REMOTE_TMUX_PROC_ROOT=$RT_PROC fm_remote_tmux_owner "$TMUX_BIN" "$RT_SOCKET" "$RT_UNIT")" \
    "a server in the unit's cgroup was not classified as the unit's"
  remote_tmux_stop
  pass "an empty socket is served by the guard's own foreground server"
}

assert_untouched() { # <pid> <exit-3-label>
  expect_code 3 "$GUARD_RC" "$2"
  [ "$(tmux_rt list-sessions -F '#{pid}' | head -1)" = "$1" ] || fail "the refused guard disturbed the existing server"
  assert_equals 1 "$(tmux_rt list-sessions | wc -l | tr -d ' ')" "the refused guard changed the server's sessions"
}

test_foreign_server_is_left_untouched() {
  reset_host
  remote_tmux_start_outside
  tmux_rt new-window -d -t "$RT_SESSION:" -n fm-existing-mate
  remote_tmux_set_cgroup "$RT_SERVER_PID" '0::/user.slice/user-1000.slice/session-3.scope'
  std_guard
  assert_untouched "$RT_SERVER_PID" "a server outside the unit was not refused with exit 3"
  assert_contains "$GUARD_OUT" "outside $RT_UNIT; it is unverified and left untouched" "the refusal did not name the foreign server"
  assert_contains "$(tmux_rt list-windows -F '#{window_name}')" fm-existing-mate "the foreign server lost a window"
  # A user unit of the same name is still not the system unit.
  remote_tmux_set_cgroup "$RT_SERVER_PID" "0::/user.slice/user-1000.slice/user@1000.service/app.slice/$RT_UNIT"
  std_guard
  assert_untouched "$RT_SERVER_PID" "a same-named user unit was trusted as the system unit"
  assert_contains "$GUARD_OUT" 'unverified and left untouched' "the user-unit refusal did not report the foreign server"
  pass "a server outside the system unit is unverified and left untouched"
}

test_server_of_this_unit_is_not_started_twice() {
  reset_host
  remote_tmux_start_outside
  remote_tmux_set_cgroup "$RT_SERVER_PID" "0::/system.slice/$RT_UNIT"
  std_guard
  assert_untouched "$RT_SERVER_PID" "a second guard in the same unit did not exit 3"
  assert_contains "$GUARD_OUT" 'nothing to start' "the guard did not report the unit's existing server"
  remote_tmux_set_cgroup "$RT_SERVER_PID" "0::/system.slice/$RT_UNIT/helper"
  std_guard
  assert_untouched "$RT_SERVER_PID" "a server in a sub-cgroup of the unit was not recognized"
  assert_contains "$GUARD_OUT" 'nothing to start' "the sub-cgroup server was not classified as the unit's"
  pass "a server already in the unit's cgroup is recognized and not started twice"
}

test_unprovable_owner_is_left_untouched() {
  reset_host
  remote_tmux_start_outside
  std_guard
  assert_untouched "$RT_SERVER_PID" "a server with no readable cgroup was not refused"
  assert_contains "$GUARD_OUT" 'cannot be proven' "the guard did not report the unprovable owner"
  pass "a server whose cgroup cannot be read is left untouched"
}

test_stale_socket_counts_as_absent() {
  reset_host
  remote_tmux_start_outside
  remote_tmux_stop
  # Wait for the server to die. A killed server leaves its socket file behind on
  # some tmux builds and removes it on others; this case needs the dead file.
  local i=0
  while tmux_rt list-sessions >/dev/null 2>&1 && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  if [ ! -S "$RT_SOCKET" ]; then
    command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (it binds the stale socket)"; exit 0; }
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$RT_SOCKET" \
      || fail "the fixture could not leave a stale socket"
  fi
  [ -S "$RT_SOCKET" ] || fail "the fixture did not leave a stale socket"
  env -i PATH="$PATH" HOME="$RT_HOME" FM_REMOTE_TMUX_PROC_ROOT="$RT_PROC" \
    "$GUARD" "$TMUX_BIN" "$RT_SOCKET" "$RT_SESSION" "$RT_UNIT" >"$FIXTURE/guard.out" 2>&1 &
  GUARD_PIDS+=("$!")
  wait_for_server
  assert_equals "$RT_SESSION" "$(tmux_rt list-sessions -F '#{session_name}' | head -1)" \
    "the guard did not replace a stale socket with its own server"
  remote_tmux_stop
  pass "a stale socket file is replaced, not mistaken for an owner"
}

test_owner_library_classes() {
  reset_host
  # shellcheck source=bin/fm-remote-tmux-owner-lib.sh
  . "$ROOT/bin/fm-remote-tmux-owner-lib.sh"
  export FM_REMOTE_TMUX_PROC_ROOT=$RT_PROC
  assert_equals absent "$(fm_remote_tmux_owner "$TMUX_BIN" "$RT_SOCKET" "$RT_UNIT")" "an empty socket was not absent"
  assert_equals unproven "$(fm_remote_tmux_owner "$FIXTURE/no-such-tmux" "$RT_SOCKET" "$RT_UNIT")" \
    "an unusable tmux was not unproven"
  remote_tmux_start_outside
  printf '4:cpu:/\n1:name=systemd:/system.slice/%s\n' "$RT_UNIT" > "$FIXTURE/v1"
  mkdir -p "$RT_PROC/$RT_SERVER_PID"
  cp "$FIXTURE/v1" "$RT_PROC/$RT_SERVER_PID/cgroup"
  assert_equals "$RT_UNIT" "$(fm_remote_tmux_pid_unit "$RT_SERVER_PID")" "a cgroup v1 name=systemd line was not read"
  assert_equals "unit $RT_SERVER_PID" "$(fm_remote_tmux_owner "$TMUX_BIN" "$RT_SOCKET" "$RT_UNIT")" "a v1 cgroup unit was not classified"
  assert_equals "foreign $RT_SERVER_PID" "$(fm_remote_tmux_owner "$TMUX_BIN" "$RT_SOCKET" other.service)" \
    "a server of another unit was not foreign"
  unset FM_REMOTE_TMUX_PROC_ROOT
  assert_equals "$HOME/.firstmate/remote-tmux/fm-remote-tmux.sock" "$(fm_remote_tmux_socket_path)" "the socket path is not under the account home"
  remote_tmux_stop
  pass "the owner library classifies absent, unproven, unit, and foreign servers"
}

test_bad_arguments_start_nothing() {
  reset_host
  guard "$TMUX_BIN" "$RT_SOCKET" "$RT_SESSION"
  expect_code 2 "$GUARD_RC" "a missing unit argument was not a usage error"
  guard "$FIXTURE/no-such-tmux" "$RT_SOCKET" "$RT_SESSION" "$RT_UNIT"
  expect_code 1 "$GUARD_RC" "a non-executable tmux was not refused"
  guard "$TMUX_BIN" relative.sock "$RT_SESSION" "$RT_UNIT"
  expect_code 2 "$GUARD_RC" "a relative socket path was not refused"
  guard "$TMUX_BIN" "$RT_SOCKET" 'bad session' "$RT_UNIT"
  expect_code 2 "$GUARD_RC" "an invalid session name was not refused"
  guard "$TMUX_BIN" "$RT_SOCKET" "$RT_SESSION" not-a-unit
  expect_code 2 "$GUARD_RC" "a non-.service unit was not refused"
  assert_absent "$RT_SOCKET" "a refused invocation still started a server"
  pass "argument errors are refused before any server starts"
}

fm_test_run \
  test_no_server_becomes_the_server \
  test_foreign_server_is_left_untouched \
  test_server_of_this_unit_is_not_started_twice \
  test_unprovable_owner_is_left_untouched \
  test_stale_socket_counts_as_absent \
  test_owner_library_classes \
  test_bad_arguments_start_nothing
