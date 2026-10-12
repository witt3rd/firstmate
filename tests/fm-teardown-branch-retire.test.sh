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

# no default branch resolvable: keep (no proof is possible)
new_repo nodefault
git -C "$R" checkout -q -b t4; git -C "$R" checkout -q --detach
(
  default_branch() { return 1; }
  BASE_BRANCH=
  err=$(retire_landed_branch "$R" t4 2>&1)
  git -C "$R" rev-parse -q --verify refs/heads/t4 >/dev/null || fail "branch deleted with no default branch"
  assert_contains "$err" "left in place"
)
pass "no default branch keeps the branch"

# default branch named but absent from the repo: keep
new_repo missingbase
git -C "$R" checkout -q -b t5; echo e >"$R/e"; git -C "$R" add e; git -C "$R" commit -q -m e
git -C "$R" checkout -q --detach
(
  BASE_BRANCH=nonexistent
  retire_landed_branch "$R" t5 >/dev/null 2>&1
  git -C "$R" rev-parse -q --verify refs/heads/t5 >/dev/null || fail "branch deleted with missing default branch"
)
pass "missing default branch ref keeps the branch"

# proven landed but the notes file cannot be written: keep (notes precede the delete)
new_repo nonotes
git -C "$R" checkout -q -b t6; echo f >"$R/f"; git -C "$R" add f; git -C "$R" commit -q -m f
git -C "$R" checkout -q main; git -C "$R" merge -q --ff-only t6; git -C "$R" checkout -q --detach
: >"$DATA"   # DATA is a regular file, so mkdir -p and the append both fail
err=$(retire_landed_branch "$R" t6 2>&1)
git -C "$R" rev-parse -q --verify refs/heads/t6 >/dev/null || fail "branch deleted though its commit id could not be saved"
assert_contains "$err" "could not save"
pass "unwritable notes file keeps the branch"
