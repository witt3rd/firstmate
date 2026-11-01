#!/usr/bin/env bash
# tests/fm-remote-secondmate-tmux.test.sh - the remote tmux route's host-local
# control plane and its route setting (docs/remote-secondmates.md).
#
# Runs the real bin/fm-remote-secondmate-control.sh on a host fixture (a real
# provisioned secondmate home, a real tmux server on a private socket standing in
# for the fm-remote-tmux.service server, and a stand-in harness binary) and pins
# what the route promises: launch, state, send, capture, replacement of a dead
# agent, identity-safe retirement, and refusal of every endpoint it cannot verify
# (a server outside the unit, an endpoint recorded on the other backend, a legacy
# tmux record). The route setting itself - the registry field, the doctor flag the
# readiness gate passes, the seed option - is pinned against the real libraries.
# The only fake is the per-pid cgroup file under a fake proc root, because a test
# cannot start a system unit. tests/fm-remote-secondmate-lifecycle-e2e.test.sh owns
# the herdr route end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-tmux-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-tmux-fixture.sh"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fmrs.XXXXXX") || fail "cannot create the fixture directory"
FIXTURE=$(cd "$FIXTURE" && pwd -P)
cleanup() {
  remote_tmux_stop
  fm_test_remove_tree "$FIXTURE"
  fm_test_cleanup || true
}
trap cleanup EXIT

REMOTE_ROOT="$FIXTURE/root"
REMOTE_HOME="$FIXTURE/rhome"
FAKEBIN="$FIXTURE/fakebin"
mkdir -p "$REMOTE_ROOT" "$FAKEBIN"
remote_tmux_fixture_init "$FIXTURE"
TMUX_REAL=$(command -v tmux)
# The server and its windows see the stand-in harness first.
RT_SERVER_PATH="$FAKEBIN:/usr/bin:/bin"

# The host's tracked Firstmate code root is a real git repository, as on a second
# machine, so the host-local spawn and teardown run their ordinary paths.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

# A stand-in harness: its kernel process name is codex (a #! script run directly
# takes its own file name), it shows a prompt, and it blocks reading its pane
# until it is told /quit, which is codex's exit command.
cat > "$FAKEBIN/codex" <<'SH'
#!/bin/bash
printf '\xe2\x80\xba '
while read -r line; do [ "$line" != /quit ] || exit 0; done
SH
chmod +x "$FAKEBIN/codex"

provision_home() {
  printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
    "$(printf ios | base64 | tr -d '\n')" "$(printf 'Charter text.\n' | base64 | tr -d '\n')" > "$FIXTURE/manifest"
  FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" \
    < "$FIXTURE/manifest" >/dev/null 2>&1 || fail "the fixture home could not be provisioned"
}

META="$REMOTE_HOME/state/parent-route/ios.meta"
T() { env -u TMUX "$TMUX_REAL" -S "$RT_SOCKET" "$@"; }
ctl() { # <control args...>; merged output in CTL_OUT, status in CTL_RC
  set +e
  CTL_OUT=$(env -i HOME="$RT_HOME" PATH="$FAKEBIN:/usr/bin:/bin" TMUX_TMPDIR="$FIXTURE/default-tmux" \
    FM_REMOTE_TMUX_PROC_ROOT="$RT_PROC" FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    bash "$REMOTE_ROOT/bin/fm-remote-secondmate-control.sh" "$@" 2>&1)
  CTL_RC=$?
  set -e
}
ctl_out() { ctl "$@"; printf '%s' "$CTL_OUT"; }
# The task windows only: the server's first window is named for the shell that ran it.
windows() { T list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' | sort; }
wait_state() { # <state> <msg>
  local i=0 got=
  while [ "$i" -lt 100 ]; do
    ctl state ios
    got=$CTL_OUT
    [ "$got" != "$1" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "$2 (expected $1, got $got)"
}
in_unit() { remote_tmux_set_cgroup "$RT_SERVER_PID" "0::/system.slice/$RT_UNIT"; }
outside_unit() { remote_tmux_set_cgroup "$RT_SERVER_PID" '0::/user.slice/user-1000.slice/session-2.scope'; }

fresh_host() {
  remote_tmux_stop
  fm_test_remove_tree "$REMOTE_HOME"
  rm -rf "$RT_HOME" "$RT_PROC" "$FIXTURE/default-tmux"
  remote_tmux_fixture_init "$FIXTURE"
  provision_home
}
start_unit_server() {
  remote_tmux_start_outside
  in_unit
}

test_launch_pins_the_unit_server() {
  fresh_host
  start_unit_server
  ctl launch ios codex - - tmux
  expect_code 0 "$CTL_RC" "a tmux launch failed: $CTL_OUT"
  assert_contains "$CTL_OUT" 'backend=tmux' "the route block did not report the tmux backend"
  assert_contains "$CTL_OUT" 'target=fm-remote-tmux:fm-ios' "the route block did not name the endpoint"
  assert_contains "$CTL_OUT" 'tmux_session=fm-remote-tmux' "the route block did not name the session"
  assert_contains "$CTL_OUT" "tmux_socket=$RT_SOCKET" "the route block did not name the server"
  assert_not_contains "$CTL_OUT" 'herdr' "a tmux route block mentioned herdr"
  assert_grep "tmux_socket=$RT_SOCKET" "$META" "the endpoint record does not carry the server identity"
  assert_grep 'window=fm-remote-tmux:fm-ios' "$META" "the endpoint record does not name its window"
  assert_equals fm-remote-tmux:fm-ios "$(windows)" "the window was not created on the unit's server"
  # Nothing reached the account's own default tmux server.
  assert_equals "" "$(env -u TMUX TMUX_TMPDIR="$FIXTURE/default-tmux" "$TMUX_REAL" list-sessions 2>/dev/null)" \
    "a launch started or used the account's default tmux server"
  wait_state alive "the launched agent was not alive"
  pass "a tmux launch records a window on the unit's server and touches no other server"
}

test_state_send_and_capture_read_the_endpoint() {
  fresh_host
  start_unit_server
  ctl launch ios codex - - tmux
  expect_code 0 "$CTL_RC" "launch failed: $CTL_OUT"
  wait_state alive "the agent was not alive"
  ctl launch ios codex - - tmux
  expect_code 0 "$CTL_RC" "an idempotent relaunch failed: $CTL_OUT"
  assert_equals fm-remote-tmux:fm-ios "$(windows)" "a launch over a live agent created a second window"
  ctl send ios 'report the build result'
  expect_code 0 "$CTL_RC" "a remote steer failed: $CTL_OUT"
  assert_equals 1 "$(find "$REMOTE_HOME/state/parent-route/ios.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" \
    "the steer was not recorded durably"
  assert_grep 'report the build result' "$REMOTE_HOME"/state/parent-route/ios.inbox/*.msg "the steer record lost its payload"
  ctl capture ios 20
  assert_contains "$CTL_OUT" 'Firstmate instruction waiting' "the doorbell was not rung into the agent's window"
  assert_not_contains "$CTL_OUT" 'report the build result' "the steer payload was typed into the pane"
  ctl route ios
  assert_contains "$CTL_OUT" 'harness=codex' "route did not read the recorded harness"
  pass "state, send, and capture read the recorded endpoint on the unit's server"
}

test_a_dead_agent_is_replaced_in_place() {
  fresh_host
  start_unit_server
  ctl launch ios codex - - tmux
  wait_state alive "the agent was not alive"
  T send-keys -t fm-remote-tmux:fm-ios C-d
  wait_state dead "an exited agent was not dead"
  ctl launch ios codex - - tmux
  expect_code 0 "$CTL_RC" "a launch over a dead endpoint failed: $CTL_OUT"
  assert_equals fm-remote-tmux:fm-ios "$(windows)" "the dead window was not replaced by exactly one window"
  wait_state alive "the replacement agent was not alive"
  T kill-window -t fm-remote-tmux:fm-ios
  ctl state ios
  assert_equals missing "$CTL_OUT" "a closed window was not missing"
  T kill-server
  local i=0
  while T list-sessions >/dev/null 2>&1 && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  ctl state ios
  assert_equals missing "$CTL_OUT" "a stopped server did not read missing, which is what lets the parent relaunch"
  ctl launch ios codex - - tmux
  expect_code 1 "$CTL_RC" "a launch with no server succeeded"
  assert_contains "$CTL_OUT" 'launch failed' "the launch refusal was not reported"
  assert_equals "" "$(T list-sessions 2>/dev/null)" "a launch started a server outside the unit"
  pass "a dead agent is replaced in place and a stopped server reads missing without a stray server being born"
}

test_a_server_outside_the_unit_is_unverified() {
  fresh_host
  start_unit_server
  ctl launch ios codex - - tmux
  wait_state alive "the agent was not alive"
  outside_unit
  local before
  before=$(windows)
  ctl state ios
  assert_contains "$CTL_OUT" unverified "a server outside the unit was trusted"
  assert_contains "$CTL_OUT" 'is not a process of fm-remote-tmux.service' "the refusal did not say why"
  for verb in "send ios hello" "capture ios 5" "observe ios" "key ios Enter" "route ios" "retire ios --force"; do
    # shellcheck disable=SC2086
    ctl $verb
    [ "$CTL_RC" -ne 0 ] || fail "'$verb' touched an endpoint on a server outside the unit"
  done
  ctl launch ios codex - - tmux
  [ "$CTL_RC" -ne 0 ] || fail "a launch used a server outside the unit"
  assert_equals "$before" "$(windows)" "a refused verb changed the foreign server"
  assert_present "$REMOTE_HOME" "a refused retirement removed the remote home"
  remote_tmux_set_cgroup "$RT_SERVER_PID" ''
  ctl state ios
  assert_contains "$CTL_OUT" unverified "a server with an unreadable owner was trusted"
  in_unit
  wait_state alive "the endpoint did not recover once the server proved to be the unit's"
  pass "every verb refuses a server outside the unit and leaves it exactly as it was"
}

test_endpoints_recorded_elsewhere_are_unverified() {
  fresh_host
  start_unit_server
  ctl launch ios codex - - tmux
  wait_state alive "the agent was not alive"
  cp "$META" "$FIXTURE/meta.good"
  # An endpoint recorded on the other backend.
  { grep -v '^tmux_socket=' "$FIXTURE/meta.good"; printf 'backend=herdr\nherdr_session=fm-remote\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:t1:p1\n'; } \
    | sed 's|^window=.*|window=fm-remote:w1:t1:p1|' > "$META"
  cp "$META" "$FIXTURE/meta.herdr"
  ctl launch ios codex - - tmux
  expect_code 1 "$CTL_RC" "a tmux launch accepted a herdr-recorded endpoint"
  assert_contains "$CTL_OUT" "recorded on backend 'herdr', expected 'tmux'" "the refusal did not name the recorded backend"
  cmp -s "$FIXTURE/meta.herdr" "$META" || fail "the refusal rewrote the endpoint record"
  assert_equals fm-remote-tmux:fm-ios "$(windows)" "the refusal touched the tmux server"
  # A legacy tmux record that names no pinned server, and one naming another.
  grep -v '^tmux_socket=' "$FIXTURE/meta.good" > "$META"
  ctl state ios
  assert_contains "$CTL_OUT" unverified "a tmux record with no pinned server was trusted"
  ctl launch ios codex - - herdr
  expect_code 1 "$CTL_RC" "a herdr launch accepted a tmux-recorded endpoint"
  assert_contains "$CTL_OUT" "recorded on backend 'tmux', expected 'herdr'" "the herdr refusal did not name the recorded backend"
  { grep -v '^tmux_socket=' "$FIXTURE/meta.good"; printf 'tmux_socket=/elsewhere/fm-remote-tmux.sock\n'; } > "$META"
  ctl state ios
  assert_contains "$CTL_OUT" unverified "a record naming another server was trusted"
  cp "$FIXTURE/meta.good" "$META"
  wait_state alive "the restored record did not read alive"
  pass "an endpoint recorded on the other backend or another server is unverified and left untouched"
}

test_retire_closes_only_this_window() {
  fresh_host
  start_unit_server
  ctl launch ios codex - - tmux
  wait_state alive "the agent was not alive"
  T new-window -d -t fm-remote-tmux: -n fm-sibling
  ctl retire ios --force
  expect_code 0 "$CTL_RC" "a forced retirement failed: $CTL_OUT"
  assert_equals fm-remote-tmux:fm-sibling "$(windows)" "retirement closed more or less than its own window"
  assert_absent "$REMOTE_HOME" "retirement left the remote home behind"
  [ -n "$(T list-sessions 2>/dev/null)" ] || fail "retirement stopped the shared server"
  pass "retirement closes only the retiring mate's window and never the shared server or a sibling"
}

test_an_existing_server_is_required_and_never_created() {
  fresh_host
  ctl launch ios codex - - tmux
  expect_code 1 "$CTL_RC" "a launch with no server succeeded"
  assert_equals "" "$(T list-sessions 2>/dev/null)" "a launch started a server outside the unit"
  assert_absent "$META" "a refused launch left an endpoint record"
  remote_tmux_start_outside
  outside_unit
  ctl launch ios codex - - tmux
  expect_code 1 "$CTL_RC" "a launch used a foreign server"
  assert_contains "$CTL_OUT" 'is not a process of fm-remote-tmux.service' "the foreign-server refusal did not say why"
  assert_equals "" "$(windows)" "a refused launch created a window"
  pass "a launch needs the unit's own server and never creates one"
}

test_migrate_moves_the_endpoint_record_off_the_backend() {
  fresh_host
  ctl migrate ios herdr
  assert_equals "nothing-to-migrate: ios has no endpoint record" "$CTL_OUT" "a route with no endpoint was not a no-op"
  start_unit_server
  ctl launch ios codex - - tmux
  expect_code 0 "$CTL_RC" "launch failed: $CTL_OUT"
  wait_state alive "the agent was not alive"
  ctl migrate ios tmux
  assert_equals "already: ios is recorded on tmux" "$CTL_OUT" "migrating to the recorded backend was not a no-op"
  ctl migrate ios herdr
  expect_code 1 "$CTL_RC" "a live agent was migrated away"
  assert_contains "$CTL_OUT" 'still has a live agent on tmux' "the refusal did not say why"
  assert_present "$META" "a refused migration archived the record"
  # A server outside the unit is unverified: nothing is stopped, closed, or archived.
  outside_unit
  ctl migrate ios herdr --stop
  expect_code 1 "$CTL_RC" "an endpoint on a foreign server was migrated"
  assert_present "$META" "a refused migration archived the record"
  assert_equals fm-remote-tmux:fm-ios "$(windows)" "a refused migration closed the window"
  in_unit
  T new-window -d -t fm-remote-tmux: -n fm-sibling
  ctl migrate ios herdr --stop
  expect_code 0 "$CTL_RC" "a stopped-agent migration failed: $CTL_OUT"
  assert_contains "$CTL_OUT" 'migrated: ios from tmux to herdr (archived ' "the migration did not report what it did"
  assert_absent "$META" "the migrated endpoint record is still live"
  assert_equals 1 "$(find "$REMOTE_HOME/state/parent-route" -maxdepth 1 -name 'ios.meta.migrated-from-tmux-*' | wc -l | tr -d ' ')" \
    "the endpoint record was not archived exactly once"
  assert_equals fm-remote-tmux:fm-sibling "$(windows)" "the migration closed more or less than the mate's own window"
  assert_present "$REMOTE_HOME/AGENTS.md" "the migration touched the mate's home"
  ctl state ios
  assert_equals missing "$CTL_OUT" "a migrated route still read as having an endpoint"
  # The way back is the same verb: launch on tmux again, now a fresh record.
  ctl launch ios codex - - tmux
  expect_code 0 "$CTL_RC" "relaunching on tmux after a migration failed: $CTL_OUT"
  wait_state alive "the relaunched agent was not alive"
  pass "migrate stops and closes only the mate's own endpoint, archives its record, and leaves the home alone"
}

fm_test_run \
  test_launch_pins_the_unit_server \
  test_state_send_and_capture_read_the_endpoint \
  test_a_dead_agent_is_replaced_in_place \
  test_a_server_outside_the_unit_is_unverified \
  test_endpoints_recorded_elsewhere_are_unverified \
  test_retire_closes_only_this_window \
  test_an_existing_server_is_required_and_never_created \
  test_migrate_moves_the_endpoint_record_off_the_backend
