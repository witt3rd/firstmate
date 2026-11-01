#!/usr/bin/env bash
# tests/fm-backend-tmux-socket.test.sh - the tmux adapter's pinned-server mode.
#
# FM_TMUX_SOCKET addresses every tmux call at one server and FM_TMUX_SESSION pins
# the container session; the remote tmux route sets both so a remote second
# mate's endpoint is the unit-owned server's and nothing else's. Drives the real
# adapter against real tmux servers on private sockets
# (tests/remote-tmux-fixture.sh), and pins that unset, nothing changes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-tmux-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-tmux-fixture.sh"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fmts.XXXXXX") || fail "cannot create the fixture directory"
OTHER_SOCKET="$FIXTURE/other.sock"
cleanup() {
  remote_tmux_stop
  env -u TMUX tmux -S "$OTHER_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE"
  fm_test_cleanup || true
}
trap cleanup EXIT
remote_tmux_fixture_init "$FIXTURE"

pinned() { env -u TMUX tmux -S "$RT_SOCKET" "$@"; }
other() { env -u TMUX tmux -S "$OTHER_SOCKET" "$@"; }

# in_adapter <script>: runs <script> in a fresh bash that sourced the real adapter
# with the pinned environment of the case.
in_adapter() {
  env -u TMUX FM_TMUX_SOCKET="${CASE_SOCKET-}" FM_TMUX_SESSION="${CASE_SESSION-}" \
    bash -c ". '$ROOT/bin/fm-backend.sh'; fm_backend_source tmux || exit 99; $1"
}

# wait_state <target> <state> <msg>: the pane's foreground settles a moment after
# tmux creates the window, so poll the adapter's own verdict.
wait_state() {
  local i=0 got=
  while [ "$i" -lt 60 ]; do
    got=$(in_adapter "fm_backend_tmux_agent_state $1")
    [ "$got" != "$2" ] || return 0
    sleep 0.05
    i=$((i + 1))
  done
  fail "$3 (expected $2, got $got)"
}

fresh() {
  remote_tmux_stop
  other kill-server 2>/dev/null || true
  rm -rf "$RT_HOME"
  mkdir -p "$(dirname "$RT_SOCKET")"
  CASE_SOCKET=$RT_SOCKET
  CASE_SESSION=$RT_SESSION
}

test_calls_address_the_pinned_server_only() {
  fresh
  remote_tmux_start_outside
  other new-session -d -s decoy
  pinned new-window -d -t "$RT_SESSION:" -n fm-mate
  assert_equals "$(printf 'fm-mate\n')" "$(in_adapter "fm_backend_tmux_window_inventory $RT_SESSION" | grep -x fm-mate)" \
    "the pinned server's window was not inventoried"
  assert_equals missing "$(in_adapter "fm_backend_tmux_agent_state decoy:fm-mate")" \
    "a window on the decoy server was visible through the pinned server"
  wait_state "$RT_SESSION:fm-mate" dead "an idle shell window on the pinned server was not dead"
  # Unpinned, the same call reaches the (here empty) default server and sees nothing.
  assert_equals "" "$(CASE_SOCKET='' in_adapter "export TMUX_TMPDIR='$FIXTURE/none'; fm_backend_tmux_window_inventory $RT_SESSION 2>/dev/null")" \
    "an unpinned call reached the pinned server"
  in_adapter "fm_backend_tmux_create_task $RT_SESSION fm-new $FIXTURE" >/dev/null || fail "the window could not be created on the pinned server"
  assert_contains "$(pinned list-windows -t "$RT_SESSION" -F '#{window_name}')" fm-new "the new window is not on the pinned server"
  assert_not_contains "$(other list-sessions -F '#{session_name}:#{session_windows}')" "$RT_SESSION" "the new window leaked to another server"
  pass "every adapter call addresses the pinned server and no other"
}

test_a_pinned_container_never_starts_a_server() {
  fresh
  local out rc
  set +e
  out=$(in_adapter 'fm_backend_tmux_container_ensure' 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "a missing pinned server was accepted as a container"
  assert_contains "$out" "is not served on $RT_SOCKET" "the refusal did not say why"
  assert_absent "$RT_SOCKET" "a client started a server outside the unit"
  remote_tmux_start_outside
  assert_equals "$RT_SESSION" "$(in_adapter 'fm_backend_tmux_container_ensure')" "an existing pinned session was not reused"
  CASE_SESSION=other-session
  set +e
  out=$(in_adapter 'fm_backend_tmux_container_ensure' 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "a missing pinned session was created"
  assert_equals "$RT_SESSION" "$(pinned list-sessions -F '#{session_name}')" "a session was created on the pinned server"
  pass "a pinned container reuses its session and never starts a server or a session"
}

test_unset_is_unchanged() {
  fresh
  mkdir -p "$FIXTURE/bin"
  cat > "$FIXTURE/bin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FIXTURE/tmux.log"
exit 1
SH
  chmod +x "$FIXTURE/bin/tmux"
  : > "$FIXTURE/tmux.log"
  CASE_SOCKET='' CASE_SESSION='' PATH="$FIXTURE/bin:$PATH" in_adapter 'fm_backend_tmux_window_inventory s; fm_backend_tmux_container_ensure' >/dev/null 2>&1 || true
  assert_not_contains "$(cat "$FIXTURE/tmux.log")" ' -S ' "an unpinned call named a socket"
  assert_not_contains "$(cat "$FIXTURE/tmux.log")" '-S ' "an unpinned call named a socket"
  assert_contains "$(cat "$FIXTURE/tmux.log")" 'has-session -t firstmate' "the default container changed"
  pass "with nothing set the adapter calls tmux exactly as before"
}

test_a_test_stub_is_not_shadowed() {
  local out
  out=$(env -u TMUX FM_TMUX_SOCKET=/nonexistent bash -c "tmux() { printf 'stub:%s' \"\$*\"; }; . '$ROOT/bin/fm-tmux-lib.sh'; tmux hello")
  assert_equals 'stub:hello' "$out" "an existing tmux function was replaced"
  pass "a caller's own tmux function wins over the library's"
}

mk_meta() { # <file> <socket-or-empty>
  {
    printf 'window=%s:fm-mate\nendpoint_task_id=mate\n' "$RT_SESSION"
    [ -z "$2" ] || printf 'tmux_socket=%s\n' "$2"
  } > "$1"
}

test_absence_is_proven_only_on_the_recorded_server() {
  fresh
  remote_tmux_start_outside
  mk_meta "$FIXTURE/with.meta" "$RT_SOCKET"
  mk_meta "$FIXTURE/without.meta" ''
  local t="$RT_SESSION:fm-mate"
  verdict() { in_adapter ". '$ROOT/bin/fm-control-lib.sh'; fm_control_endpoint_absence_verdict tmux '$t' '$1'" | tr '\t' '|'; }
  assert_equals 'gone|' "$(verdict "$FIXTURE/with.meta")" "a window absent from the recorded server was not proven gone"
  assert_contains "$(verdict "$FIXTURE/without.meta")" 'unproven|tmux absence cannot be proven' \
    "a record that names no server was trusted"
  pinned new-window -d -t "$RT_SESSION:" -n fm-mate
  wait_state "$t" dead "a shell-only window was not dead"
  assert_equals 'dead|' "$(verdict "$FIXTURE/with.meta")" "a shell-only window was not dead"
  # A live agent: a process whose kernel name is a verified harness.
  cp "$(command -v sleep)" "$FIXTURE/claude"
  pinned respawn-window -k -t "$t" "$FIXTURE/claude 60"
  wait_state "$t" alive "a live agent window was not alive"
  assert_equals 'alive|' "$(verdict "$FIXTURE/with.meta")" "a live agent window was not alive"
  # The same record read through a different server proves nothing.
  mk_meta "$FIXTURE/elsewhere.meta" "$OTHER_SOCKET"
  assert_contains "$(verdict "$FIXTURE/elsewhere.meta")" 'unproven|' "a record naming another server was trusted"
  remote_tmux_stop
  local i=0
  while pinned list-sessions >/dev/null 2>&1 && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  assert_equals 'gone|' "$(verdict "$FIXTURE/with.meta")" "a dead recorded server did not prove its windows gone"
  pass "absence is proven only against the server the record names"
}

fm_test_run \
  test_calls_address_the_pinned_server_only \
  test_a_pinned_container_never_starts_a_server \
  test_unset_is_unchanged \
  test_a_test_stub_is_not_shadowed \
  test_absence_is_proven_only_on_the_recorded_server
