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
#     takes no lease and never creates an endpoint at all (so nothing has to be
#     closed afterwards); any other lease failure refuses the same way;
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
window_file="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}.window"
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
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0 ;;
  kill-window) : > "$window_file"; exit 0 ;;
  has-session|new-session) exit 0 ;;
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

# LEASE_PATH overrides the path the stub leases (default: the case's worktree).
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
    "${SPAWN_BIN:-$SPAWN}" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
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
  assert_grep "new-window" "$TMUX_LOG" "a healthy pool must take the normal path and create the window"
  pass "worktree acquisition passes --lease --lease-holder <task-id> and keeps the lease on success"
}

# A pool with no free tree answers at once with its own message. The spawn must
# refuse immediately with that message, take no lease, publish nothing, and
# create no endpoint, so there is no pane to wait on and no teardown to run.
test_exhausted_pool_refuses_immediately_before_any_endpoint_exists() {
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
  assert_contains "$out" "all 8 worktrees are in use or dirty (max_trees = 8)" "refusal did not carry Treehouse's own exhaustion message"
  assert_contains "$out" "docs/treehouse-pool.md" "refusal did not point at the pool sizing doc"
  assert_contains "$out" "no worker endpoint was created" "refusal did not say that nothing was launched"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_no_grep "return" "$TREEHOUSE_LOG" "no lease was taken, so none may be returned"
  assert_no_grep "new-window" "$TMUX_LOG" "an exhausted pool must refuse before a window is created"
  assert_no_grep "kill-window" "$TMUX_LOG" "no endpoint existed, so none may be closed"
  assert_no_grep "send-keys" "$TMUX_LOG" "nothing may be typed into any pane for a refused spawn"
  pass "an exhausted pool refuses immediately with its own message before any window exists"
}

# Any other failure to lease is refused at the same point, still carrying the
# tool's message, so the operator never has to guess why no tree came back.
test_other_lease_failure_refuses_with_the_tools_message() {
  local rec id out status
  id=lease-other-z6
  rec=$(make_settle_case lease-other "$id" 0)
  read_settle_record "$rec"
  GET_FAIL="cannot resolve a treehouse pool from here"

  out=$(run_settle_spawn "$id")
  status=$?
  GET_FAIL=
  [ "$status" -ne 0 ] || fail "spawn succeeded although treehouse could not lease"$'\n'"$out"
  assert_contains "$out" "cannot resolve a treehouse pool from here" "refusal did not carry treehouse's message"
  assert_contains "$out" "no worker endpoint was created" "refusal did not say that nothing was launched"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_no_grep "new-window" "$TMUX_LOG" "a refused lease must not create a window"
  pass "a non-exhaustion lease failure also refuses before any window exists, with the tool's message"
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

test_unborn_head_project_is_refused_at_once() {
  local rec id out status started elapsed
  id=settle-unborn-head-z5
  rec=$(make_settle_case settle-unborn "$id" 0)
  read_settle_record "$rec"
  PROJ_DIR="$TMP_ROOT/settle-unborn/unborn-project"
  git init -q "$PROJ_DIR"

  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "spawn into a project with no commit should be refused"
  assert_contains "$out" "unborn HEAD" "the refusal did not name the unborn HEAD cause"
  assert_contains "$out" "make one commit" "the refusal did not name the remedy"
  [ "$elapsed" -lt 30 ] || fail "refusal took ${elapsed}s instead of failing before the treehouse wait"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ -z "$(git -C "$PROJ_DIR" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the project"
  pass "a project with an unborn HEAD is refused at once with its cause named"
}

# make_pool_case <name> <id>: a settle case whose leased worktree sits in a
# real Treehouse pool layout (<root>/<pool>/<slot>/<repo> beside a
# treehouse-state.json), with slot 1 the one the stub leases, slot 2 an empty
# numbered directory and slot 3 a populated slot claimed by task "live".
make_pool_case() {
  local name=$1 id=$2 rec pool
  rec=$(make_settle_case "$name" "$id" 0)
  read_settle_record "$rec"
  pool="$CASE_DIR/poolroot/pool"
  mkdir -p "$pool/1" "$pool/2" "$pool/3"
  : > "$pool/treehouse-state.json"
  git -C "$PROJ_DIR" worktree add --quiet --detach "$pool/1/proj"
  git -C "$PROJ_DIR" worktree add --quiet --detach "$pool/3/proj"
  printf 'task=live\nhome=%s\n' "$HOME_DIR" > "$pool/3/.fm-slot-owner"
  fm_write_meta "$HOME_DIR/state/live.meta" "kind=ship" "worktree=$pool/3/proj"
  fm_write_meta "$HOME_DIR/state/stale-holder.meta" "kind=ship" "worktree=$pool/1/proj" "branch=fm/stale"
  WT_DIR="$pool/1/proj"
  POOL_DIR=$pool
  export TREEHOUSE_ROOT="$CASE_DIR/poolroot"
}

# Pool rule: the claim is the only truth. The spawn claims its slot and demotes
# the older record that still names it, protects the slot of a task still on the
# books by leasing it in place, and drops empty numbered directories first.
test_pool_rule_claim_demote_protect_and_prune() {
  local tid out status
  tid='pool-slot-z7'
  make_pool_case pool-slot "$tid"

  out=$(run_settle_spawn "$tid")
  status=$?
  unset TREEHOUSE_ROOT
  expect_code 0 "$status" "spawn into a pool slot should succeed"$'\n'"$out"
  assert_grep "task=$tid" "$POOL_DIR/1/.fm-slot-owner" "the spawn must claim its slot"
  assert_no_grep "worktree=$POOL_DIR/1/proj" "$HOME_DIR/state/stale-holder.meta" "the older record naming the slot must be demoted"
  assert_grep "#stale-worktree-record(superseded-by=$tid) $POOL_DIR/1/proj" "$HOME_DIR/state/stale-holder.meta" "the demoted record keeps the path as a comment"
  assert_grep "branch=fm/stale" "$HOME_DIR/state/stale-holder.meta" "demotion changes nothing but the worktree line"
  assert_grep "worktree=$POOL_DIR/3/proj" "$HOME_DIR/state/live.meta" "another slot's record is untouched"
  assert_grep "lease 3 --lease-holder live" "$TREEHOUSE_LOG" "the slot of a task still on the books is leased in place before the get"
  [ ! -d "$POOL_DIR/2" ] || fail "an empty numbered directory must be removed before the get"
  pass "a spawn claims its slot, demotes older records, protects live slots and drops empty dirs"
}

# Spawn gate: a host at a declared ceiling refuses a fresh worker before any
# endpoint, lease or record exists, after exactly one reclaim of the home's own
# done-and-landed leftovers (bin/fm-auto-teardown.sh); a reclaim that brings the
# host under its ceiling lets the spawn through.
# make_gate_case <name> <id> <containers>: a settle case with a docker stub that
# reports the number in $CASE_DIR/containers and a ceiling of 3.
make_gate_case() {
  local name=$1 id=$2 rec
  rec=$(make_settle_case "$name" "$id" 0)
  read_settle_record "$rec"
  printf '%s\n' "$3" > "$CASE_DIR/containers"
  cat > "$FAKEBIN_DIR/docker" <<SH
#!/usr/bin/env bash
[ "\$*" = "ps -aq" ] && seq 1 "\$(cat "$CASE_DIR/containers")"
exit 0
SH
  chmod +x "$FAKEBIN_DIR/docker"
  printf 'CONTAINERS=3\n' > "$CASE_DIR/ceilings.env"
  export FM_CEILINGS_FILE="$CASE_DIR/ceilings.env"
}

test_spawn_over_ceiling_refuses_before_anything_exists() {
  local id out status
  id=gate-refuse-z1
  make_gate_case gate-refuse "$id" 5

  out=$(run_settle_spawn "$id")
  status=$?
  unset FM_CEILINGS_FILE
  expect_code 1 "$status" "a host over its ceiling must refuse the spawn"
  assert_contains "$out" "over: CONTAINERS 5 >= 3" "the refusal must name the breach"
  assert_contains "$out" "one reclaim of this home's own leftovers ran first" "the single reclaim must be reported"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_no_grep "get" "$TREEHOUSE_LOG" "no lease may be taken for a refused spawn"
  assert_no_grep "new-window" "$TMUX_LOG" "no endpoint may be created for a refused spawn"
  pass "a spawn over a ceiling refuses before any lease, endpoint or record exists"
}

test_reclaim_of_own_leftovers_lets_the_spawn_through() {
  local id out status bin
  id=gate-reclaim-z2
  make_gate_case gate-reclaim "$id" 5
  # A copied bin/ whose crew-state reads the one finished task as done and whose
  # teardown frees two containers, so the single reclaim brings the host under.
  bin="$CASE_DIR/bin"
  cp -R "$ROOT/bin" "$bin"
  printf '#!/usr/bin/env bash\necho "state: done"\n' > "$bin/fm-crew-state.sh"
  cat > "$bin/fm-teardown.sh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$CASE_DIR/teardown.calls"
echo 2 > "$CASE_DIR/containers"
rm -f "$HOME_DIR/state/\$1.meta"
SH
  chmod +x "$bin/fm-crew-state.sh" "$bin/fm-teardown.sh"
  # A code root outside the repository has no history, which the role lib
  # refuses; give it an unrelated one so the fixture project is not "firstmate".
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m code-root
  fm_write_meta "$HOME_DIR/state/finished-old.meta" "kind=ship" "worktree=/nonexistent/finished-old"

  out=$(SPAWN_BIN="$bin/fm-spawn.sh" FM_AUTO_TEARDOWN=1 run_settle_spawn "$id")
  status=$?
  unset FM_CEILINGS_FILE
  expect_code 0 "$status" "a reclaim that clears the ceiling must let the spawn through"$'\n'"$out"
  [ "$(cat "$CASE_DIR/teardown.calls")" = finished-old ] || fail "exactly the finished task is reclaimed, never forced"
  assert_grep "new-window" "$TMUX_LOG" "the spawn proceeds to create its endpoint"
  pass "one reclaim of the home's own finished tasks lets a spawn through"
}

test_acquisition_leases_under_the_task_id
test_spawn_over_ceiling_refuses_before_anything_exists
test_reclaim_of_own_leftovers_lets_the_spawn_through
test_pool_rule_claim_demote_protect_and_prune
test_exhausted_pool_refuses_immediately_before_any_endpoint_exists
test_other_lease_failure_refuses_with_the_tools_message
test_primary_checkout_lease_is_refused_and_returned
test_transient_stale_cwd_at_the_launch_boundary_is_retried
test_pane_that_never_reaches_the_worktree_refuses_and_returns_the_lease
test_unborn_head_project_is_refused_at_once

echo "# all fm-spawn-worktree-settle tests passed"
