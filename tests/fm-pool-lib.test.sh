#!/usr/bin/env bash
# Behavior tests for bin/fm-pool-lib.sh, the pool slot rules fm-spawn applies:
#   - the claim file is the only truth: claiming a slot demotes every other
#     record naming it to a #stale-worktree-record comment;
#   - a slot whose claimant still has a record is leased in place before a get
#     so it is never offered, and a claim naming a task with no record is not;
#   - empty numbered directories are removed and never counted as slots.
# The pool is a real directory tree of real worktrees; treehouse is a stub that
# records the `lease` calls.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-pool-lib.sh
. "$ROOT/bin/fm-pool-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pool-lib)

# make_pool <name>: a project, a pool root with pool "p-1" holding numbered
# slots 1 and 2 (real worktrees), empty numbered dirs 3 and 4, and a stub
# treehouse on PATH logging to $TMP_ROOT/<name>/lease.log.
make_pool() {
  local name=$1 w="$TMP_ROOT/$1" i
  mkdir -p "$w/root/p-1" "$w/fakebin" "$w/state"
  fm_git_init_commit "$w/project"
  : > "$w/root/p-1/treehouse-state.json"
  for i in 1 2; do
    mkdir -p "$w/root/p-1/$i"
    git -C "$w/project" worktree add --quiet --detach "$w/root/p-1/$i/project"
  done
  mkdir -p "$w/root/p-1/3" "$w/root/p-1/4"
  cat > "$w/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
SH
  chmod +x "$w/fakebin/treehouse"
  : > "$w/lease.log"
  printf '%s\n' "$w"
}

claim() {  # <world> <slot-number> <task>
  printf 'task=%s\nhome=/h\n' "$3" > "$1/root/p-1/$2/.fm-slot-owner"
}

test_demote_names_only_the_claim_as_truth() {
  local w slot
  w=$(make_pool demote)
  slot="$w/root/p-1/1/project"
  fm_write_meta "$w/state/old.meta" "kind=ship" "worktree=$slot" "branch=fm/old"
  fm_write_meta "$w/state/new.meta" "kind=ship" "worktree=$slot"
  fm_write_meta "$w/state/other.meta" "kind=ship" "worktree=$w/root/p-1/2/project"
  out=$(fm_pool_demote_records "$slot" new "$w/state")
  assert_equals "demoted old" "$out" "only the older record is demoted"
  [ "$(fm_meta_get "$w/state/old.meta" worktree)" = "" ] || fail "old record must lose its worktree= line"
  assert_contains "$(cat "$w/state/old.meta")" "#stale-worktree-record(superseded-by=new) $slot" "path kept as evidence"
  assert_contains "$(cat "$w/state/old.meta")" "branch=fm/old" "other fields untouched"
  assert_equals "$slot" "$(fm_meta_get "$w/state/new.meta" worktree)" "claimant record untouched"
  assert_equals "$w/root/p-1/2/project" "$(fm_meta_get "$w/state/other.meta" worktree)" "other slot's record untouched"
  pass "a claim demotes every other record naming the slot"
}

test_protect_leases_only_claims_with_a_record() {
  local w
  w=$(make_pool protect)
  claim "$w" 1 live-task
  claim "$w" 2 gone-task
  fm_write_meta "$w/state/live-task.meta" "kind=ship"
  out=$(PATH="$w/fakebin:$PATH" FM_FAKE_TREEHOUSE_LOG="$w/lease.log" TREEHOUSE_ROOT="$w/root" \
    fm_pool_protect_claimed "$w/project" "$w/state")
  assert_equals 1 "$out" "one slot protected"
  assert_equals "lease 1 --lease-holder live-task" "$(cat "$w/lease.log")" "claimant's slot leased in place, stale claim not"
  pass "slots held by a task still on the books are leased, stale claims are not"
}

test_empty_numbered_dirs_do_not_count_and_are_removed() {
  local w
  w=$(make_pool empty)
  assert_equals 2 "$(TREEHOUSE_ROOT="$w/root" fm_pool_populated_count "$w/project")" "only populated slots count"
  assert_equals 2 "$(TREEHOUSE_ROOT="$w/root" fm_pool_prune_empty "$w/project")" "both empty dirs removed"
  [ ! -d "$w/root/p-1/3" ] && [ ! -d "$w/root/p-1/4" ] || fail "empty dirs gone"
  [ -d "$w/root/p-1/1/project" ] && [ -d "$w/root/p-1/2/project" ] || fail "populated slots untouched"
  pass "empty numbered dirs are removed and never counted"
}

test_other_projects_pools_are_left_alone() {
  local w
  w=$(make_pool foreign)
  fm_git_init_commit "$w/other"
  assert_equals "" "$(TREEHOUSE_ROOT="$w/root" fm_pool_dirs "$w/other")" "another repo's pool is not ours"
  pass "pools of other repositories are never touched"
}

test_demote_names_only_the_claim_as_truth
test_protect_leases_only_claims_with_a_record
test_empty_numbered_dirs_do_not_count_and_are_removed
test_other_projects_pools_are_left_alone
