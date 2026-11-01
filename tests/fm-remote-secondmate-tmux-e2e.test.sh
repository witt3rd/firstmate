#!/usr/bin/env bash
# tests/fm-remote-secondmate-tmux-e2e.test.sh - a remote second mate on the tmux
# route, from the parent's side.
#
# Seeds a route with --backend tmux, launches it with the real fm-spawn.sh,
# probes it the way the liveness sweep does, steers it with the real fm-send.sh,
# and retires it with the real fm-teardown.sh. The SSH boundary is a deterministic
# stand-in that runs the remote command directly on this machine with the empty
# environment the real entrypoint hands it (the entrypoint and job worker are
# pinned by tests/fm-remote-entrypoint.test.sh and tests/fm-remote-job.test.sh);
# the readiness doctor is answered by the stand-in, because
# tests/fm-remote-doctor-tmux.test.sh owns its verdicts. The remote host is a real
# provisioned home, a real tmux server on a private socket standing in for the
# fm-remote-tmux.service server, and a stand-in harness. tests/fm-remote-secondmate-tmux.test.sh
# owns the host-local control plane; this suite owns what the parent records and
# decides from it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-tmux-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-tmux-fixture.sh"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fmre.XXXXXX") || fail "cannot create the fixture directory"
FIXTURE=$(cd "$FIXTURE" && pwd -P)
PARENT="$FIXTURE/parent"
REMOTE_ROOT="$FIXTURE/root"
REMOTE_HOME="$FIXTURE/rhome"
FAKEBIN="$FIXTURE/fakebin"
CLAIMS="$FIXTURE/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$FAKEBIN" "$CLAIMS"
cleanup() {
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  remote_tmux_stop
  fm_test_remove_tree "$FIXTURE"
  fm_test_cleanup || true
}
trap cleanup EXIT
remote_tmux_fixture_init "$FIXTURE"
RT_SERVER_PATH="$FAKEBIN:/usr/bin:/bin"
TMUX_REAL=$(command -v tmux)
T() { env -u TMUX "$TMUX_REAL" -S "$RT_SOCKET" "$@"; }

(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

printf '#!/bin/bash\nprintf "\\xe2\\x80\\xba "\nwhile read -r line; do [ "$line" != /quit ] || exit 0; done\n' > "$FAKEBIN/codex"
chmod +x "$FAKEBIN/codex"
printf 'codex\n' > "$PARENT/config/secondmate-harness"

# The SSH stand-in: decodes fm-on's argv and runs the command on this machine as
# the entrypoint would, with an empty environment and the remote account's HOME.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = remote-tmux-host ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
root=$(printf '%s' "$4" | base64 -d); home=$(printf '%s' "$5" | base64 -d)
mapfile -d '' -t argv < <(printf '%s' "$6" | base64 -d)
cmd=${argv[0]}
printf '%s\n' "${argv[*]}" >> "$FM_FAKE_SSH_LOG"
if [ "$cmd" = fm-remote-doctor.sh ]; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec env -i HOME="$FM_FAKE_HOME" PATH="$root/bin:$FM_FAKE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
  FM_REMOTE_TMUX_PROC_ROOT="$FM_FAKE_PROC" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$root/bin/$cmd" "${argv[@]:1}"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_SSH_LOG="$FIXTURE/ssh.log" FM_FAKE_HOME="$RT_HOME" \
  FM_FAKE_PATH="$FAKEBIN:/usr/bin:/bin" FM_FAKE_PROC="$RT_PROC" \
  FM_SECONDMATE_CONVERGENCE_TIMEOUT=300 FM_REMOTE_INHERIT_PUSH_JOBS=1 \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 "$@"
}
windows() { T list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' | sort; }

test_seed_launch_probe_steer_and_retire() {
  : > "$FIXTURE/ssh.log"
  remote_tmux_start_outside
  remote_tmux_set_cgroup "$RT_SERVER_PID" "0::/system.slice/$RT_UNIT"

  FM_SECONDMATE_CHARTER='Tmux route charter.' FM_SECONDMATE_SCOPE='tmux route' \
    remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-tmux-host "$REMOTE_ROOT" "$REMOTE_HOME" \
    --backend tmux --no-projects > "$FIXTURE/seed.out" 2>&1 \
    || fail "seeding the tmux route failed: $(cat "$FIXTURE/seed.out")"
  assert_grep 'backend: tmux; scope: tmux route' "$PARENT/data/secondmates.md" "the route did not record its backend"
  assert_grep 'fm-remote-doctor.sh --backend tmux' "$FIXTURE/ssh.log" "the host was not gated on the tmux readiness"

  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate > "$FIXTURE/spawn.out" 2>&1 \
    || fail "launching the tmux route failed: $(cat "$FIXTURE/spawn.out")"
  assert_contains "$(cat "$FIXTURE/spawn.out")" 'backend=tmux' "the launch did not report the tmux backend"
  local meta="$PARENT/state/ios.meta"
  assert_grep 'remote_backend=tmux' "$meta" "the parent did not record the tmux backend"
  assert_grep 'remote_tmux_session=fm-remote-tmux' "$meta" "the parent did not record the tmux session"
  assert_grep 'remote_target=fm-remote-tmux:fm-ios' "$meta" "the parent did not record the endpoint"
  assert_no_grep 'remote_herdr_session' "$meta" "a tmux route recorded a herdr session"
  assert_equals fm-remote-tmux:fm-ios "$(windows)" "the mate is not in a window of the unit's server"
  assert_grep "tmux_socket=$RT_SOCKET" "$REMOTE_HOME/state/parent-route/ios.meta" "the host record does not name the server"

  # The liveness sweep reads the route's state, not the herdr one.
  # shellcheck source=bin/fm-secondmate-liveness-lib.sh
  . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
  local i=0 state=
  while [ "$i" -lt 100 ]; do
    state=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)
    [ "$state" != alive ] || break
    sleep 0.1
    i=$((i + 1))
  done
  assert_equals alive "$state" "the launched mate was not alive"
  (
    export FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_SSH_LOG="$FIXTURE/ssh.log" \
      FM_FAKE_HOME="$RT_HOME" FM_FAKE_PATH="$FAKEBIN:/usr/bin:/bin" FM_FAKE_PROC="$RT_PROC"
    STATE="$PARENT/state"
    fm_secondmate_liveness_probe "$meta" ios full
    [ "$FM_SM_LIVE_STATUS" = alive ] || { echo "probe verdict: $FM_SM_LIVE_STATUS ($FM_SM_LIVE_REASON)"; exit 1; }
  ) || fail "the liveness probe did not read a tmux route as alive"

  remote_env "$ROOT/bin/fm-send.sh" fm-ios 'report the build result' > "$FIXTURE/send.out" 2> "$FIXTURE/send.err" \
    || fail "a steer to the tmux mate failed: $(cat "$FIXTURE/send.err")"
  assert_equals 1 "$(find "$REMOTE_HOME/state/parent-route/ios.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" \
    "the steer was not recorded in the mate's host-local inbox"
  assert_contains "$(T capture-pane -p -t fm-remote-tmux:fm-ios)" 'Firstmate instruction waiting' "the doorbell did not reach the mate's window"

  remote_env "$ROOT/bin/fm-teardown.sh" ios --force > "$FIXTURE/teardown.out" 2>&1 \
    || fail "retiring the tmux mate failed: $(cat "$FIXTURE/teardown.out")"
  assert_equals "" "$(windows)" "retirement left the mate's window behind"
  [ -n "$(T list-sessions 2>/dev/null)" ] || fail "retirement stopped the shared server"
  assert_absent "$PARENT/state/ios.meta" "retirement left the parent's record"
  pass "a tmux route is seeded, launched, probed, steered, and retired through the parent's own commands"
}

fm_test_run test_seed_launch_probe_steer_and_retire
