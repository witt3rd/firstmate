#!/usr/bin/env bash
# Tests for retire_landed_branch in bin/fm-teardown.sh: a task branch is deleted only
# when proven landed on the default branch (merged or patch-equivalent); one proof line
# is logged, the tip commit id is saved in $DATA/retired-branches.md, and an unproven
# branch is left alone with a message.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FN=$(sed -n '/^retire_landed_branch() {/,/^}/p' "$ROOT/bin/fm-teardown.sh")
[ -n "$FN" ] || fail "retire_landed_branch not found"
default_branch() { echo main; }
eval "$FN"
# shellcheck source=bin/fm-branch-retire-lib.sh
. "$ROOT/bin/fm-branch-retire-lib.sh"
FN2=$(sed -n '/^retire_landed_branches() {/,/^}/p' "$ROOT/bin/fm-teardown.sh")
[ -n "$FN2" ] || fail "retire_landed_branches not found"
eval "$FN2"
PR_MERGED=0
pr_is_merged() { [ "$PR_MERGED" = 1 ]; }
# shellcheck disable=SC2034 # read by the eval-ed retire_landed_branch
BASE_BRANCH=main

new_repo() {
  R=$T/$1; DATA=$R-data; git init -q -b main "$R"
  git -C "$R" commit -q --allow-empty -m base
  echo a >"$R/a"; git -C "$R" add a; git -C "$R" commit -q -m a-base
}

# merged
new_repo merged
git -C "$R" checkout -q -b t1; echo b >"$R/b"; git -C "$R" add b; git -C "$R" commit -q -m b
tip=$(git -C "$R" rev-parse t1); git -C "$R" checkout -q main; git -C "$R" merge -q --ff-only t1
git -C "$R" checkout -q --detach
err=$(retire_landed_branch "$R" t1 2>&1)
if git -C "$R" rev-parse -q --verify refs/heads/t1 >/dev/null; then
  fail "merged branch kept"
else
  pass "merged branch deleted"
fi
assert_contains "$err" "merged: $tip" || true
assert_grep "$tip" "$DATA/retired-branches.md"

# patch-equivalent (cherry-picked onto main, different commit id)
new_repo equiv
git -C "$R" checkout -q -b t2; echo c >"$R/c"; git -C "$R" add c; git -C "$R" commit -q -m c
tip=$(git -C "$R" rev-parse t2); git -C "$R" checkout -q main; git -C "$R" commit -q --allow-empty -m other
git -C "$R" cherry-pick t2 >/dev/null; git -C "$R" checkout -q --detach
err=$(retire_landed_branch "$R" t2 2>&1)
if git -C "$R" rev-parse -q --verify refs/heads/t2 >/dev/null; then
  fail "equivalent branch kept"
else
  pass "equivalent branch deleted"
fi
assert_contains "$err" "patch-equivalent"
assert_grep "$tip" "$DATA/retired-branches.md"

# unlanded
new_repo unlanded
git -C "$R" checkout -q -b t3; echo d >"$R/d"; git -C "$R" add d; git -C "$R" commit -q -m d
git -C "$R" checkout -q --detach
err=$(retire_landed_branch "$R" t3 2>&1)
if git -C "$R" rev-parse -q --verify refs/heads/t3 >/dev/null; then
  pass "unlanded branch kept"
else
  fail "unlanded branch deleted"
fi
assert_contains "$err" "left in place"
assert_absent "$DATA/retired-branches.md"

# --- remote head branch: deleted with the local one only when proven landed ---

# new_remote_repo <name>: new_repo plus a bare origin that already holds main.
new_remote_repo() {
  new_repo "$1"
  git init -q --bare "$R-origin.git"
  git -C "$R" remote add origin "$R-origin.git"
  git -C "$R" push -q origin main
}
remote_has() { git -C "$R" ls-remote --exit-code --heads origin "refs/heads/$1" >/dev/null 2>&1; }

# merged work: local and remote branch both go, with a remote line in the log
new_remote_repo rmerged
git -C "$R" checkout -q -b fm/t1; echo b >"$R/b"; git -C "$R" add b; git -C "$R" commit -q -m b
git -C "$R" push -q origin fm/t1
tip=$(git -C "$R" rev-parse fm/t1); git -C "$R" checkout -q main; git -C "$R" merge -q --ff-only fm/t1
git -C "$R" push -q origin main; git -C "$R" checkout -q --detach
err=$(retire_landed_branches "$R" fm/t1 2>&1)
remote_has fm/t1 && fail "landed remote branch kept"
assert_contains "$err" "retired remote branch fm/t1 @ $tip" "remote retirement is logged"
assert_grep "remote:" "$DATA/retired-branches.md" "remote retirement is recorded"
pass "a landed task's remote head branch is deleted with the local one"

# a remote branch that moved since is never deleted
new_remote_repo radvanced
git -C "$R" checkout -q -b fm/t2; echo b >"$R/b"; git -C "$R" add b; git -C "$R" commit -q -m b
git -C "$R" push -q origin fm/t2
git -C "$R" checkout -q main; git -C "$R" merge -q --ff-only fm/t2; git -C "$R" push -q origin main
git -C "$R" checkout -q fm/t2; echo x >"$R/x"; git -C "$R" add x; git -C "$R" commit -q -m advanced
git -C "$R" push -q origin fm/t2; git -C "$R" reset -q --hard HEAD~1; git -C "$R" checkout -q --detach
err=$(retire_landed_branches "$R" fm/t2 2>&1)
remote_has fm/t2 || fail "a remote branch ahead of the proved tip must stay"
assert_contains "$err" "not at the proved tip" "the refusal is explained"
pass "a remote branch not at the proved tip is kept"

# squash flow: local branch is not an ancestor, but its merged PR contains it
new_remote_repo rsquash
git -C "$R" checkout -q -b fm/t3; echo s >"$R/s"; git -C "$R" add s; git -C "$R" commit -q -m s
git -C "$R" push -q origin fm/t3; git -C "$R" checkout -q --detach
PR_MERGED=1
err=$(retire_landed_branches "$R" fm/t3 2>&1)
PR_MERGED=0
remote_has fm/t3 && fail "a merged PR's head branch must go"
git -C "$R" rev-parse -q --verify refs/heads/fm/t3 >/dev/null || fail "local branch not proven here must stay"
pass "a merged PR's remote head branch goes even when the local branch cannot be proven an ancestor"

# unlanded work keeps both
new_remote_repo runlanded
git -C "$R" checkout -q -b fm/t4; echo u >"$R/u"; git -C "$R" add u; git -C "$R" commit -q -m u
git -C "$R" push -q origin fm/t4; git -C "$R" checkout -q --detach
retire_landed_branches "$R" fm/t4 >/dev/null 2>&1
remote_has fm/t4 || fail "unlanded remote branch deleted"
pass "an unlanded task's remote branch stays"

# evidence-prefixed branches are never touched, even when merged
new_remote_repo revidence
for pfx in evidence archive shots capture; do
  git -C "$R" checkout -q -b "$pfx/e1" main; echo "$pfx" >"$R/$pfx"; git -C "$R" add "$pfx"; git -C "$R" commit -q -m "$pfx"
  git -C "$R" push -q origin "$pfx/e1"
  git -C "$R" checkout -q main; git -C "$R" merge -q --ff-only "$pfx/e1"; git -C "$R" push -q origin main; git -C "$R" checkout -q --detach
  PR_MERGED=1
  retire_landed_branches "$R" "$pfx/e1" >/dev/null 2>&1
  PR_MERGED=0
  remote_has "$pfx/e1" || fail "$pfx/ remote branch deleted"
  git -C "$R" rev-parse -q --verify "refs/heads/$pfx/e1" >/dev/null || fail "$pfx/ local branch deleted"
done
pass "evidence, archive, shots and capture branches are never deleted"

# no origin (local-only delivery): only the local branch is retired
new_repo rlocal
git -C "$R" checkout -q -b fm/t5; echo l >"$R/l"; git -C "$R" add l; git -C "$R" commit -q -m l
git -C "$R" checkout -q main; git -C "$R" merge -q --ff-only fm/t5; git -C "$R" checkout -q --detach
retire_landed_branches "$R" fm/t5 >/dev/null 2>&1
git -C "$R" rev-parse -q --verify refs/heads/fm/t5 >/dev/null && fail "local branch of a local-only task must retire"
pass "a local-only task retires only its local branch"
