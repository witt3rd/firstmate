#!/usr/bin/env bash
# Behavior tests for the opt-in config/pi-approve-workers flag: an ordinary Pi
# worker launch receives the session-scoped --approve only when the home sets
# the flag and the selected Pi advertises --approve.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-approve)
unset LAVISH_AXI_HOST PI_CODING_AGENT_DIR

# new_case <name> <advertise-approve: yes|no> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  local opts='--help --tui-mode <mode>'
  [ "$2" != yes ] || opts="$opts --approve, -a"
  cat > "$FAKEBIN/pi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --help) printf '%s\n' 'Pi test' 'Options: $opts'; exit 0 ;;
esac
SH
  chmod +x "$FAKEBIN/pi"
  fm_test_spawn_home "$HOME_DIR" pi
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  : > "$CASE/launch.log"
}

spawn_ship() {
  local id=$1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off
}

test_default_worker_launch_has_no_approve() {
  local out rc
  new_case default yes
  out=$(spawn_ship approve-default); rc=$?
  expect_code 0 "$rc" "a default Pi spawn should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "--approve" "an unflagged worker must not be pre-approved"
  pass "an ordinary Pi worker without the flag never receives --approve"
}

test_flag_adds_approve_when_supported() {
  local out rc
  new_case flagged yes
  : > "$HOME_DIR/config/pi-approve-workers"
  out=$(spawn_ship approve-flagged); rc=$?
  expect_code 0 "$rc" "a flagged Pi spawn should succeed: $out"
  assert_contains "$(cat "$CASE/launch.log")" "--approve" "a flagged worker should receive --approve"
  pass "the flag adds --approve to an ordinary Pi worker"
}

test_flag_without_pi_support_is_a_no_op() {
  local out rc
  new_case unsupported no
  : > "$HOME_DIR/config/pi-approve-workers"
  out=$(spawn_ship approve-unsupported); rc=$?
  expect_code 0 "$rc" "a flagged spawn on an older Pi should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "--approve" "an older Pi must not receive an unknown flag"
  pass "the flag is ignored when the selected Pi does not advertise --approve"
}

test_default_worker_launch_has_no_approve
test_flag_adds_approve_when_supported
test_flag_without_pi_support_is_a_no_op

echo "# all fm-spawn-pi-approve-workers tests passed"
