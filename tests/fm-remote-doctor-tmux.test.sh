#!/usr/bin/env bash
# tests/fm-remote-doctor-tmux.test.sh - the remote second-mate readiness gate
# for a route whose backend is tmux (docs/remote-secondmates.md).
#
# Drives the real bin/fm-remote-doctor.sh --backend tmux against a controlled
# Linux account fixture: a private HOME, real tmux servers on a private socket
# (tests/remote-tmux-fixture.sh), and fake loginctl, systemctl, sudo, getent, and
# id. The fake systemctl starts the unit by running the ExecStart line the doctor
# actually wrote, so the rendered unit, the real guard, and the real owner
# classification are all exercised; only the cgroup file the kernel would write
# for a started unit is faked. Herdr is absent from every host here, which is the
# point: nothing in the tmux route may need it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-tmux-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-tmux-fixture.sh"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMUX_REAL=$(command -v tmux)
ROOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fmrd.XXXXXX") || fail "cannot create the fixture directory"
ROOT_DIR=$(cd "$ROOT_DIR" && pwd -P)
CASE_N=0
cleanup() {
  remote_tmux_stop
  rm -rf "$ROOT_DIR"
  fm_test_cleanup || true
}
trap cleanup EXIT

TOOLS="$ROOT_DIR/tools"
mkdir -p "$TOOLS"
for tool in git jq cat sed head tr cut mktemp rm mv mkdir install sleep env sh bash dirname basename uname grep awk ps; do
  real=$(command -v "$tool") || fail "test host lacks $tool"
  ln -sf "$real" "$TOOLS/$tool"
done
BASE_PATH="$TOOLS"

# new_case [tmux-version]: one isolated account fixture, exposed as CASE_*.
new_case() {
  CASE_N=$((CASE_N + 1))
  remote_tmux_stop
  CASE_DIR="$ROOT_DIR/c$CASE_N"
  CASE_BIN="$CASE_DIR/bin"
  CASE_STATE="$CASE_DIR/state"
  CASE_UNITS="$CASE_DIR/units"
  CASE_ID_UID=1000
  CASE_PLATFORM=linux
  mkdir -p "$CASE_BIN" "$CASE_STATE" "$CASE_UNITS"
  remote_tmux_fixture_init "$CASE_DIR"
  CASE_HOME=$RT_HOME
  printf '%s\n' "${1:-tmux 3.8}" > "$CASE_STATE/tmux-version"
  printf 'no\n' > "$CASE_STATE/linger"
  : > "$CASE_STATE/calls.log"

  cat > "$CASE_BIN/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -V ]; then cat "$CASE_STATE/tmux-version"; exit 0; fi
exec "$TMUX_REAL" "\$@"
SH
  cat > "$CASE_BIN/id" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -un) printf 'fmtest\n' ;;
  -u) printf '%s\n' "$FM_FAKE_UID" ;;
  *) printf 'uid=%s(fmtest)\n' "$FM_FAKE_UID" ;;
esac
SH
  cat > "$CASE_BIN/getent" <<'SH'
#!/usr/bin/env bash
printf 'fmtest:x:%s:%s::%s:/bin/sh\n' "$FM_FAKE_UID" "$FM_FAKE_UID" "$HOME"
SH
  cat > "$CASE_BIN/loginctl" <<'SH'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >> "$FM_FAKE_STATE/calls.log"
case "${1:-}" in
  show-user) cat "$FM_FAKE_STATE/linger" ;;
  enable-linger)
    [ ! -f "$FM_FAKE_STATE/linger-refused" ] || exit 1
    printf 'yes\n' > "$FM_FAKE_STATE/linger"
    ;;
esac
exit 0
SH
  cat > "$CASE_BIN/sudo" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -n ] || exit 2
shift
printf 'sudo %s\n' "$*" >> "$FM_FAKE_STATE/calls.log"
[ ! -f "$FM_FAKE_STATE/no-sudo" ] || exit 1
[ "${1:-}" != true ] || exit 0
exec "$@"
SH
  cat > "$CASE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$FM_FAKE_STATE/calls.log"
case "${1:-}" in
  is-active) [ -f "$FM_FAKE_STATE/unit-active" ] ;;
  daemon-reload) exit 0 ;;
  enable)
    unit_file="$FM_FAKE_UNIT_DIR/fm-remote-tmux.service"
    exec_line=$(sed -n 's/^ExecStart=//p' "$unit_file")
    [ -n "$exec_line" ] || exit 1
    : > "$FM_FAKE_STATE/unit-active"
    (
      env -i PATH="$FM_FAKE_SYSPATH" HOME="$FM_FAKE_HOME" FM_REMOTE_TMUX_PROC_ROOT="$FM_FAKE_PROC" \
        sh -c "exec $exec_line" >> "$FM_FAKE_STATE/unit.log" 2>&1 &
      pid=$!
      mkdir -p "$FM_FAKE_PROC/$pid"
      printf '0::/system.slice/fm-remote-tmux.service\n' > "$FM_FAKE_PROC/$pid/cgroup"
      printf '%s\n' "$pid" > "$FM_FAKE_STATE/unit.pid"
    )
    ;;
  *) exit 0 ;;
esac
SH
  cat > "$CASE_BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '0.2.6\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_BIN/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_BIN/claude"
  chmod +x "$CASE_BIN"/*
}

# doctor [args...]: runs the real doctor against the current fixture; merged
# output in DOCTOR_OUT, status in DOCTOR_RC.
doctor() {
  set +e
  DOCTOR_OUT=$(
    env -i HOME="$CASE_HOME" FM_HOME="$CASE_DIR/project-home" \
      PATH="$CASE_BIN:$BASE_PATH:/usr/bin:/bin" \
      FM_FAKE_STATE="$CASE_STATE" FM_FAKE_UID="$CASE_ID_UID" FM_FAKE_UNIT_DIR="$CASE_UNITS" \
      FM_FAKE_HOME="$CASE_HOME" FM_FAKE_PROC="$RT_PROC" FM_FAKE_SYSPATH="$CASE_BIN:$BASE_PATH:/usr/bin:/bin" \
      FM_REMOTE_TMUX_UNIT_DIR="$CASE_UNITS" FM_REMOTE_TMUX_PROC_ROOT="$RT_PROC" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE="$CASE_PLATFORM" FM_REMOTE_JOB_ACTIVE=1 \
      "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1
  )
  DOCTOR_RC=$?
  set -e
}

calls() { cat "$CASE_STATE/calls.log"; }
# Everything the doctor did to the host, without its read-only probes.
mutating_calls() { grep -v '^loginctl show-user\|^systemctl is-active\|^sudo true$' "$CASE_STATE/calls.log" || true; }
unit_file() { printf '%s/fm-remote-tmux.service' "$CASE_UNITS"; }
server_pid() { env -u TMUX "$TMUX_REAL" -S "$RT_SOCKET" list-sessions -F '#{pid}' 2>/dev/null | head -1; }

# A host whose unit is installed, active, and serving: what a repaired host is.
make_ready_host() {
  doctor --backend tmux --fix
  expect_code 0 "$DOCTOR_RC" "the fixture host could not be made ready: $DOCTOR_OUT"
}

test_a_host_without_herdr_is_ready_on_tmux() {
  new_case
  make_ready_host
  doctor --backend tmux
  expect_code 0 "$DOCTOR_RC" "a repaired tmux host was not reported ready"
  assert_contains "$DOCTOR_OUT" 'check tmux=ok:' "tmux was not detected"
  assert_contains "$DOCTOR_OUT" 'check linger=ok:' "lingering was not detected"
  assert_contains "$DOCTOR_OUT" 'check tmux-unit=ok:' "the installed unit was not recognized"
  assert_contains "$DOCTOR_OUT" 'check tmux-unit-active=ok:' "the active unit was not recognized"
  assert_contains "$DOCTOR_OUT" "check tmux-server=ok: session fm-remote-tmux is served by pid $(server_pid) inside fm-remote-tmux.service" \
    "the unit's own server was not recognized"
  assert_contains "$DOCTOR_OUT" 'required tmux=' "tmux is not in the tool contract"
  assert_not_contains "$DOCTOR_OUT" 'herdr' "the tmux route mentioned herdr on a host without it"
  assert_not_contains "$DOCTOR_OUT" 'gui-session' "the tmux route inspected a login session"
  pass "a host with no herdr is ready on the tmux route"
}

test_fix_installs_the_unit_and_starts_the_server() {
  new_case
  doctor --backend tmux
  expect_code 1 "$DOCTOR_RC" "an empty host was reported ready"
  assert_contains "$DOCTOR_OUT" 'check linger=fixable:' "off lingering was not fixable"
  assert_contains "$DOCTOR_OUT" 'check tmux-unit=fixable:' "a missing unit was not fixable"
  assert_contains "$DOCTOR_OUT" 'check tmux-unit-active=fixable:' "an inactive unit was not fixable"
  assert_contains "$DOCTOR_OUT" 'check tmux-server=fixable:' "a missing server was not fixable"
  assert_absent "$(unit_file)" "a read-only run installed the unit"
  assert_equals '' "$(mutating_calls)" "a read-only run changed the host"
  doctor --backend tmux --fix
  expect_code 0 "$DOCTOR_RC" "--fix left a repairable host unready: $DOCTOR_OUT"
  assert_contains "$DOCTOR_OUT" 'fix linger=applied:' "--fix did not enable lingering"
  assert_contains "$DOCTOR_OUT" 'fix tmux-unit=applied:' "--fix did not install the unit"
  assert_contains "$DOCTOR_OUT" 'fix tmux-unit-active=applied:' "--fix did not start the unit"
  assert_equals 'yes' "$(cat "$CASE_STATE/linger")" "lingering was not turned on"
  # The unit is a system unit for this account, run through its login shell.
  assert_equals '# Firstmate-owned: fm-remote-tmux.service v1' "$(head -1 "$(unit_file)")" "the unit carries no ownership marker"
  assert_grep 'User=fmtest' "$(unit_file)" "the unit does not run as the account"
  assert_grep 'WantedBy=multi-user.target' "$(unit_file)" "the unit is not a boot-time system unit"
  assert_grep 'RestartPreventExitStatus=3' "$(unit_file)" "the unit would loop on a guard refusal"
  assert_grep "ExecStart=/bin/sh -l -c 'exec $ROOT/bin/fm-remote-tmux-guard.sh $CASE_BIN/tmux $RT_SOCKET fm-remote-tmux fm-remote-tmux.service'" \
    "$(unit_file)" "the unit does not exec the guard through the account's login shell"
  assert_contains "$(calls)" 'sudo install -D -m 0644' "the unit was not installed through sudo -n"
  assert_contains "$(calls)" 'systemctl daemon-reload' "systemd was not reloaded"
  assert_contains "$(calls)" 'systemctl enable --now fm-remote-tmux.service' "the unit was not enabled and started"
  assert_equals "$(cat "$CASE_STATE/unit.pid")" "$(server_pid)" "the server is not the unit's own process"
  : > "$CASE_STATE/calls.log"
  doctor --backend tmux --fix
  expect_code 0 "$DOCTOR_RC" "a second --fix on a ready host reported a gap"
  assert_not_contains "$DOCTOR_OUT" 'fix ' "a second --fix changed something"
  assert_equals '' "$(mutating_calls)" "a second --fix touched the host"
  pass "--fix installs the system unit, enables lingering, and starts the unit's own server, once"
}

test_print_tmux_unit_matches_the_installed_unit() {
  new_case
  make_ready_host
  doctor --backend tmux --print-tmux-unit
  expect_code 0 "$DOCTOR_RC" "--print-tmux-unit failed"
  assert_equals "$(cat "$(unit_file)")" "$DOCTOR_OUT" "the printed unit is not the installed one"
  doctor --print-tmux-unit
  expect_code 2 "$DOCTOR_RC" "--print-tmux-unit without the tmux backend was not a usage error"
  pass "an account that cannot elevate can install exactly the unit --fix would"
}

test_an_account_that_cannot_elevate_gets_a_human_gap() {
  new_case
  : > "$CASE_STATE/no-sudo"
  doctor --backend tmux --fix
  expect_code 1 "$DOCTOR_RC" "an account without sudo was reported ready"
  assert_contains "$DOCTOR_OUT" 'check tmux-unit=human:' "a unit that cannot be installed was not a human gap"
  assert_contains "$DOCTOR_OUT" '--print-tmux-unit' "the human gap did not say how to install the unit"
  assert_absent "$(unit_file)" "the doctor wrote a unit without privileges"
  assert_not_contains "$(calls)" 'systemctl enable' "the doctor started a unit it could not install"
  pass "an account that cannot elevate is told the exact steps instead of failing silently"
}

test_a_foreign_server_is_left_untouched() {
  new_case
  remote_tmux_start_outside
  env -u TMUX "$TMUX_REAL" -S "$RT_SOCKET" new-window -d -t fm-remote-tmux: -n fm-live-mate
  remote_tmux_set_cgroup "$RT_SERVER_PID" '0::/user.slice/user-1000.slice/session-4.scope'
  doctor --backend tmux --fix
  expect_code 1 "$DOCTOR_RC" "a host with a foreign server on the socket was reported ready"
  assert_contains "$DOCTOR_OUT" 'check tmux-server=human:' "a foreign server was not a human gap"
  assert_contains "$DOCTOR_OUT" "pid $RT_SERVER_PID) is not a process of fm-remote-tmux.service" "the gap did not name the foreign server"
  assert_contains "$DOCTOR_OUT" 'fix tmux-unit-active=failed:' "--fix did not report refusing to start over the foreign server"
  assert_not_contains "$(calls)" 'systemctl enable' "--fix started the unit over a foreign server"
  assert_equals "$RT_SERVER_PID" "$(server_pid)" "the foreign server was replaced"
  assert_contains "$(env -u TMUX "$TMUX_REAL" -S "$RT_SOCKET" list-windows -F '#{window_name}')" fm-live-mate \
    "the foreign server lost a live window"
  pass "a server outside the unit is unverified and left untouched, even under --fix"
}

test_a_stale_unit_is_rewritten_without_a_restart() {
  new_case
  make_ready_host
  local before
  before=$(server_pid)
  printf '%s\n# drift\n' "$(head -1 "$(unit_file)")" > "$(unit_file)"
  doctor --backend tmux
  expect_code 1 "$DOCTOR_RC" "a drifted unit was reported ready"
  assert_contains "$DOCTOR_OUT" 'check tmux-unit=fixable:' "a drifted unit was not fixable"
  : > "$CASE_STATE/calls.log"
  doctor --backend tmux --fix
  expect_code 0 "$DOCTOR_RC" "--fix did not repair a drifted unit: $DOCTOR_OUT"
  assert_contains "$DOCTOR_OUT" 'fix tmux-unit=applied:' "--fix did not rewrite the unit"
  assert_not_contains "$DOCTOR_OUT" 'tmux-unit-active=applied' "--fix restarted a running unit"
  assert_not_contains "$(calls)" 'systemctl enable' "--fix touched the running unit"
  assert_not_contains "$(calls)" 'restart' "--fix restarted the server"
  assert_equals "$before" "$(server_pid)" "the running server was replaced by a unit rewrite"
  pass "a drifted unit is rewritten and reloaded but a running server is never restarted"
}

test_a_unit_file_firstmate_did_not_write_is_never_overwritten() {
  new_case
  printf '[Service]\nExecStart=/bin/true\n' > "$(unit_file)"
  doctor --backend tmux --fix
  expect_code 1 "$DOCTOR_RC" "a foreign unit file was reported ready"
  assert_contains "$DOCTOR_OUT" 'check tmux-unit=human:' "a foreign unit file was not a human gap"
  assert_equals $'[Service]\nExecStart=/bin/true' "$(cat "$(unit_file)")" "a unit file Firstmate did not write was overwritten"
  assert_not_contains "$(calls)" 'sudo install' "a unit file Firstmate did not write was replaced"
  pass "a unit file Firstmate did not write is reported, never overwritten"
}

test_tmux_version_floor() {
  local v
  for v in 'tmux 3.3' 'tmux 3.3a' 'tmux 3.10' 'tmux 4.0' 'tmux next-3.5'; do
    new_case "$v"
    doctor --backend tmux
    assert_contains "$DOCTOR_OUT" 'check tmux=ok:' "'$v' was refused"
  done
  for v in 'tmux 3.2a' 'tmux 2.9' 'tmux 1.8'; do
    new_case "$v"
    doctor --backend tmux
    assert_contains "$DOCTOR_OUT" 'check tmux=human:' "'$v' was accepted"
    assert_contains "$DOCTOR_OUT" 'older than the required 3.3' "'$v' was not reported as too old"
  done
  new_case 'tmux master'
  doctor --backend tmux
  assert_contains "$DOCTOR_OUT" 'check tmux=human:' "an unreadable version was accepted"
  assert_contains "$DOCTOR_OUT" 'cannot be read' "an unreadable version was not reported as such"
  pass "tmux 3.3 or newer is required, in numeric order"
}

test_the_tmux_route_is_linux_only_and_non_root() {
  new_case
  CASE_PLATFORM=darwin
  doctor --backend tmux
  expect_code 1 "$DOCTOR_RC" "a macOS host was reported ready for the tmux route"
  assert_contains "$DOCTOR_OUT" 'check tmux-platform=human:' "the Linux-only limit was not a human gap"
  new_case
  CASE_ID_UID=0
  doctor --backend tmux
  assert_contains "$DOCTOR_OUT" 'check tmux-unit=human:' "a root account was accepted for the unit"
  assert_contains "$DOCTOR_OUT" 'non-root account' "the root refusal did not say why"
  pass "the tmux route refuses macOS and a root account"
}

test_the_herdr_route_is_unchanged() {
  new_case
  doctor
  expect_code 1 "$DOCTOR_RC" "a host with no herdr was reported ready on the default route"
  assert_contains "$DOCTOR_OUT" 'check herdr=human:' "the default route stopped requiring herdr"
  assert_contains "$DOCTOR_OUT" 'required herdr=MISSING' "herdr left the default tool contract"
  assert_not_contains "$DOCTOR_OUT" 'check tmux-' "the default route started checking the tmux unit"
  doctor --backend herdr
  assert_contains "$DOCTOR_OUT" 'check herdr=human:' "--backend herdr is not the default route"
  doctor --backend zellij
  expect_code 2 "$DOCTOR_RC" "an unknown backend was accepted"
  pass "an unflagged doctor is the herdr route, byte for byte"
}

test_worker_tool_probe_follows_the_backend() {
  new_case
  doctor --backend tmux --worker-tool-probe
  expect_code 0 "$DOCTOR_RC" "the tmux tool probe failed on a host with every tool: $DOCTOR_OUT"
  assert_equals 6 "$(printf '%s\n' "$DOCTOR_OUT" | grep -c '^required ')" "the probe did not report exactly six facts"
  assert_contains "$DOCTOR_OUT" 'required tmux=' "the probe did not report tmux"
  assert_not_contains "$DOCTOR_OUT" 'required herdr=' "the tmux probe asked for herdr"
  doctor --fix --worker-tool-probe
  expect_code 2 "$DOCTOR_RC" "--fix with the worker probe was accepted"
  pass "the worker tool probe carries the route's backend"
}

fm_test_run \
  test_a_host_without_herdr_is_ready_on_tmux \
  test_fix_installs_the_unit_and_starts_the_server \
  test_print_tmux_unit_matches_the_installed_unit \
  test_an_account_that_cannot_elevate_gets_a_human_gap \
  test_a_foreign_server_is_left_untouched \
  test_a_stale_unit_is_rewritten_without_a_restart \
  test_a_unit_file_firstmate_did_not_write_is_never_overwritten \
  test_tmux_version_floor \
  test_the_tmux_route_is_linux_only_and_non_root \
  test_the_herdr_route_is_unchanged \
  test_worker_tool_probe_follows_the_backend
