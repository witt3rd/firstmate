#!/usr/bin/env bash
# Regression test for how bin/fm-spawn.sh acquires and proves a task worktree.
#
# A worker's worktree is leased non-interactively (`treehouse get --lease
# --lease-holder <task-id>`), the pane is told to `cd` into it, and the launch
# boundary then reads the pane's FOREGROUND process cwd and refuses to start a
# worker anywhere else. This suite drives the real spawn against a stub
# `treehouse` (tests/lib.sh fm_fake_treehouse) and a fake tmux, with no live
# pool, and covers:
#   - acquisition passes --lease and the task id, never the interactive form;
#   - a pool that reports exhaustion refuses at once with Treehouse's message,
#     takes no lease and closes the endpoint it just created;
#   - a leased path that is the repository primary is refused and returned;
#   - the launch-boundary read tolerates a transient stale cwd, but a pane that
#     never reaches the worktree refuses and returns the lease;
#   - a spawn that succeeds keeps its lease (teardown owns the release).
# The pane cwd read itself (herdr's foreground_cwd, never the frozen plain cwd)
# is pinned in tests/fm-backend-herdr.test.sh, and teardown's release of the
# lease in tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree. Every
# call is recorded to FM_FAKE_TMUX_LOG so a case can assert what the spawn did
# to the endpoint.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the path the stub treehouse leases), and a separate real
# git repo standing in for a stale cwd (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where a stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  fm_test_spawn_brief "$home" "$id" "Exercise worktree acquisition for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  TMUX_LOG="$CASE_DIR/tmux.log"
  : > "$TREEHOUSE_LOG"
  : > "$TMUX_LOG"
}

# LEASE_PATH overrides the path the stub leases (default: the case's worktree);
# GET_FAIL makes the stub pool report exhaustion.
run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    FM_FAKE_TREEHOUSE_PATH="${LEASE_PATH:-$WT_DIR}" \
    FM_FAKE_TREEHOUSE_GET_FAIL="${GET_FAIL:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# Acquisition takes the durable lease under the task's own id and never the
# interactive form, so Treehouse can attribute the slot after the worker exits.
test_acquisition_leases_under_the_task_id() {
  local rec id out status
  id=lease-acquire-z1
  rec=$(make_settle_case lease-acquire "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed with a leased worktree"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "meta did not record the leased worktree"
  assert_grep "get --lease --lease-holder $id" "$TREEHOUSE_LOG" \
    "acquisition did not pass --lease with the task id as lease holder"
  [ "$(grep -c '^get' "$TREEHOUSE_LOG")" -eq 1 ] || fail "spawn acquired more than one worktree"$'\n'"$(cat "$TREEHOUSE_LOG")"
  assert_no_grep "return" "$TREEHOUSE_LOG" "a successful spawn must keep its lease for teardown to release"
  assert_no_grep "treehouse get" "$TMUX_LOG" "spawn typed the interactive treehouse get into the pane"
  pass "worktree acquisition passes --lease --lease-holder <task-id> and keeps the lease on success"
}

# A pool with no free tree answers at once with its own message. The spawn must
# refuse immediately with that message, take no lease, publish nothing, and
# close the endpoint it created instead of leaving the window to die.
test_exhausted_pool_refuses_immediately_and_closes_the_endpoint() {
  local rec id out status start elapsed
  id=lease-exhausted-z2
  rec=$(make_settle_case lease-exhausted "$id" 0)
  read_settle_record "$rec"
  GET_FAIL=1

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$(( $(date +%s) - start ))
  GET_FAIL=
  [ "$status" -ne 0 ] || fail "spawn succeeded against an exhausted pool"$'\n'"$out"
  [ "$elapsed" -lt 30 ] || fail "exhausted pool took ${elapsed}s to refuse; it must not wait out a discovery timeout"
  assert_contains "$out" "max_trees = 8" "refusal did not carry Treehouse's own exhaustion message"
  assert_contains "$out" "docs/treehouse-pool.md" "refusal did not point at the pool sizing doc"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_no_grep "return" "$TREEHOUSE_LOG" "no lease was taken, so none may be returned"
  assert_grep "kill-window" "$TMUX_LOG" "the endpoint created for the refused spawn was not closed"
  pass "an exhausted pool refuses immediately with its own message and closes the new window"
}

# The leased path is screened by the isolation predicate: the repository's
# primary checkout is never a valid worker location. The refusal must name it
# and the lease just taken must go back to the pool.
test_primary_checkout_lease_is_refused_and_returned() {
  local rec id out status primary
  id=lease-primary-z3
  rec=$(make_settle_case lease-primary "$id" 0)
  read_settle_record "$rec"
  primary=$(git -C "$PROJ_DIR" rev-parse --path-format=absolute --git-common-dir)
  primary=$(dirname "$primary")
  LEASE_PATH=$primary

  out=$(run_settle_spawn "$id")
  status=$?
  LEASE_PATH=
  [ "$status" -ne 0 ] || fail "spawn accepted a leased path that is not an isolated worktree"$'\n'"$out"
  assert_contains "$out" "did not yield an isolated worktree" "refusal did not explain the isolation failure"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_grep "return --force --if-lease-holder $id $primary" "$TREEHOUSE_LOG" \
    "a refused spawn did not return its lease"
  pass "a leased path that is not isolated is refused and its lease returned"
}

# The launch boundary reads the pane's foreground cwd after the explicit cd. A
# transient stale read must neither fail the spawn nor be recorded, because the
# read is retried until it agrees with the recorded worktree.
test_transient_stale_cwd_at_the_launch_boundary_is_retried() {
  local rec id out status
  id=lease-stale-z4
  rec=$(make_settle_case lease-stale "$id" 2)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane reaches the worktree"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "meta did not record the leased worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  [ "$(cat "$COUNTFILE")" -ge 3 ] || fail "launch-boundary check did not retry past the stale reads"
  pass "a transient stale cwd read at the launch boundary is retried, not recorded"
}

# A pane that never reaches the leased worktree must refuse before any worker
# starts, and the lease taken for it must be returned rather than stranded.
test_pane_that_never_reaches_the_worktree_refuses_and_returns_the_lease() {
  local rec id out status
  id=lease-never-z5
  rec=$(make_settle_case lease-never "$id" 100000)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker from a pane outside its worktree"$'\n'"$out"
  assert_contains "$out" "not its recorded worktree" "refusal did not say the worker started outside its worktree"
  assert_contains "$out" "$STALE_DIR" "refusal did not name the path the pane kept reporting"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_grep "return --force --if-lease-holder $id $WT_DIR" "$TREEHOUSE_LOG" \
    "a failed spawn did not return its lease"
  pass "a pane outside the worktree refuses at the launch boundary and the lease is returned"
}

test_acquisition_leases_under_the_task_id
test_exhausted_pool_refuses_immediately_and_closes_the_endpoint
test_primary_checkout_lease_is_refused_and_returned
test_transient_stale_cwd_at_the_launch_boundary_is_retried
test_pane_that_never_reaches_the_worktree_refuses_and_returns_the_lease

echo "# all fm-spawn-worktree-settle tests passed"
