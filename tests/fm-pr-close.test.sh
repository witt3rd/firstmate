#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-close.sh: closing a PR deletes its head branch
# when the branch is still at the PR head (kept recoverable by refs/pull/<n>/head),
# keeps a branch that moved or an evidence-prefixed one, and never deletes after
# a close that did not take. gh-axi is a stub; origin is a real bare repository.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CLOSE="$ROOT/bin/fm-pr-close.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-close)
fm_git_identity fmtest fmtest@example.invalid

# make_world <name> <branch> [initial-pr-state]: a clone whose origin holds
# <branch> and refs/pull/7/head at the same commit; a gh-axi stub whose PR state
# lives in $w/pr-state ("close" flips open to closed unless GH_CLOSE_FAILS=1).
make_world() {
  local name=$1 branch=$2 w="$TMP_ROOT/$1"
  mkdir -p "$w/fakebin"
  git init -q -b main "$w/work"
  git -C "$w/work" commit -q --allow-empty -m base
  git init -q --bare "$w/origin.git"
  git -C "$w/work" remote add origin "$w/origin.git"
  git -C "$w/work" push -q origin main
  git -C "$w/work" checkout -q -b "$branch"
  git -C "$w/work" commit -q --allow-empty -m work
  git -C "$w/work" push -q origin "$branch"
  git -C "$w/origin.git" update-ref refs/pull/7/head "$(git -C "$w/work" rev-parse HEAD)"
  printf '%s\n' "${3:-open}" > "$w/pr-state"
  cat > "$w/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")/..
case "$1 $2" in
  "pr view") printf 'pull_request:\n  number: 7\n  state: %s\n' "$(cat "$dir/pr-state")" ;;
  "pr close") [ "${GH_CLOSE_FAILS:-0}" = 1 ] && exit 1; echo closed > "$dir/pr-state" ;;
esac
SH
  chmod +x "$w/fakebin/gh-axi"
  printf '%s\n' "$w"
}

run_close() {  # <world> [args...]
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" "$CLOSE" 7 --repo-dir "$w/work" --repo o/r "$@" 2>&1
}
remote_has() { git -C "$1/work" ls-remote --exit-code --heads origin "refs/heads/$2" >/dev/null 2>&1; }

test_close_deletes_the_head_branch() {
  local w out
  w=$(make_world del fm/task)
  out=$(run_close "$w"); assert_equals 0 "$?" "close succeeds"$'\n'"$out"
  assert_equals closed "$(cat "$w/pr-state")" "the PR is closed"
  remote_has "$w" fm/task && fail "head branch must be deleted with the PR"
  git -C "$w/work" ls-remote origin refs/pull/7/head | grep -q . || fail "the PR head ref is what keeps the work recoverable"
  assert_contains "$out" "retired remote branch fm/task" "deletion reported"
  pass "closing a PR deletes its head branch, the work staying on refs/pull/<n>/head"
}

test_already_merged_pr_still_cleans_up() {
  local w
  w=$(make_world merged fm/task merged)
  run_close "$w" >/dev/null || fail "an already merged PR is a success"
  remote_has "$w" fm/task && fail "a merged PR's leftover branch must go"
  pass "a merged PR's leftover head branch is removed"
}

test_moved_branch_and_evidence_branch_are_kept() {
  local w out
  w=$(make_world moved fm/task)
  git -C "$w/work" commit -q --allow-empty -m more
  git -C "$w/work" push -q origin fm/task
  out=$(run_close "$w" --branch fm/task)
  remote_has "$w" fm/task || fail "a branch past the PR head must stay"
  assert_contains "$out" "kept remote branch fm/task" "the keep is reported"
  w=$(make_world evid evidence/shots-1)
  run_close "$w" --branch evidence/shots-1 >/dev/null
  remote_has "$w" evidence/shots-1 || fail "an evidence branch is never deleted"
  pass "a branch that moved past the PR head, and evidence branches, are kept"
}

test_failed_close_changes_nothing() {
  local w rc
  w=$(make_world fail fm/task)
  GH_CLOSE_FAILS=1 run_close "$w" >/dev/null; rc=$?
  assert_equals 1 "$rc" "a close that did not take fails"
  remote_has "$w" fm/task || fail "the branch stays when the PR could not be closed"
  pass "a PR that could not be closed keeps its branch"
}

test_close_deletes_the_head_branch
test_already_merged_pr_still_cleans_up
test_moved_branch_and_evidence_branch_are_kept
test_failed_close_changes_nothing
