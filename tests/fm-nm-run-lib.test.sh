#!/usr/bin/env bash
# Contract coverage for bin/fm-nm-run-lib.sh's pure attribution primitives:
# text helpers, TOON readers, head matching, run liveness classes, ledger
# attribution, and overview run selection. Nothing here needs a no-mistakes
# daemon; the capped-overview sqlite fallback is out of scope.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-run-lib)

# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

GIT() { git -C "$REPO" "$@"; }

make_repo() {
  REPO="$TMP_ROOT/repo"
  mkdir -p "$REPO"
  git init -q "$REPO"
  GIT config user.email t@example.invalid
  GIT config user.name t
  GIT commit -q --allow-empty -m one
  C1=$(GIT rev-parse HEAD)
  GIT commit -q --allow-empty -m two
  C2=$(GIT rev-parse HEAD)
  GIT commit -q --allow-empty -m three
  C3=$(GIT rev-parse HEAD)
  GIT checkout -q "$C1"
  GIT commit -q --allow-empty -m side
  CSIDE=$(GIT rev-parse HEAD)
  GIT checkout -q "$C2"
}

test_text_helpers() {
  assert_equals "a b" "$(fm_nm_trim $'  \t a b \n ')" "trim strips outer whitespace only"
  assert_equals "" "$(fm_nm_trim '   ')" "trim of blanks is empty"
  assert_equals "x y" "$(fm_nm_strip_quotes ' "x y" ')" "strip_quotes unwraps a quoted scalar"
  assert_equals '"x' "$(fm_nm_strip_quotes '"x')" "strip_quotes leaves an unbalanced quote"
  local toon=$'run:\n  status: running\n  head: "abc1234"\nother:\n  status: nope'
  assert_equals running "$(fm_nm_field "$toon" status)" "field reads the first match"
  assert_equals '"abc1234"' "$(fm_nm_field "$toon" head)" "field keeps quotes for the caller"
  assert_equals "" "$(fm_nm_field "$toon" missing)" "absent field is empty"
  pass "trim, strip_quotes, and field behave on edge input"
}

test_commit_identity() {
  assert_equals "$C2" "$(fm_nm_resolve_commit "$REPO" "${C2:0:8}")" "short sha resolves to full"
  assert_equals "" "$(fm_nm_resolve_commit "$REPO" deadbeefdeadbeef)" "unknown object resolves to empty"
  fm_nm_head_matches_worktree "$REPO" "$C2" || fail "equal commit must match"
  fm_nm_head_matches_worktree "$REPO" "${C2:0:7}" || fail "equal short sha must match"
  fm_nm_head_matches_worktree "$REPO" "$C3" || fail "run head descended from worktree HEAD must match"
  fm_nm_head_matches_worktree "$REPO" "$C1" && fail "run head behind worktree HEAD must not match"
  fm_nm_head_matches_worktree "$REPO" "$CSIDE" && fail "diverged run head must not match"
  fm_nm_head_matches_worktree "$REPO" "" && fail "empty head must not match"
  fm_nm_head_matches_worktree "$REPO" deadbeefdeadbeef && fail "unknown head must not match"
  fm_nm_head_matches_worktree "$TMP_ROOT/not-a-repo" "$C2" && fail "non-repo must not match"
  pass "resolve_commit and head_matches_worktree apply the equal/ancestor rule"
}

test_status_class() {
  assert_equals terminal "$(fm_nm_run_status_class completed)" "completed"
  assert_equals terminal "$(fm_nm_run_status_class failed)" "failed"
  assert_equals terminal "$(fm_nm_run_status_class cancelled)" "cancelled"
  assert_equals live "$(fm_nm_run_status_class running)" "running"
  assert_equals live "$(fm_nm_run_status_class pending)" "pending"
  assert_equals unknown "$(fm_nm_run_status_class fixing)" "fixing is not a ledger word"
  assert_equals unknown "$(fm_nm_run_status_class '')" "empty"
  pass "run_status_class partitions ledger status words"
}

test_branch_sync_readers() {
  local toon
  toon=$'run:\n  status: running\nbranch_sync:\n  state: pipeline_owned\n  local:\n    head: aaa\n  pipeline:\n    head: bbb\n    current_head: "ccc"\n  next_action:\n    code: continue_active_run\ngate:\n  state: awaiting_approval'
  assert_equals pipeline_owned "$(fm_nm_branch_sync_state "$toon")" "direct child state"
  assert_equals ccc "$(fm_nm_branch_sync_nested "$toon" pipeline current_head)" "nested quoted key"
  assert_equals bbb "$(fm_nm_branch_sync_nested "$toon" pipeline head)" "pipeline head not local head"
  assert_equals aaa "$(fm_nm_branch_sync_nested "$toon" local head)" "local head"
  assert_equals continue_active_run "$(fm_nm_branch_sync_nested "$toon" next_action code)" "next_action code"
  assert_equals "" "$(fm_nm_branch_sync_nested "$toon" pipeline code)" "key from a sibling block is not read"
  assert_equals "" "$(fm_nm_branch_sync_nested "$toon" nothere head)" "absent block"
  assert_equals "" "$(fm_nm_branch_sync_state $'run:\n  status: running')" "no block means empty state"
  assert_equals "" "$(fm_nm_branch_sync_state $'gate:\n  state: awaiting_approval')" "gate state is not branch_sync state"
  pass "branch_sync readers are block-scoped"
}

test_liveness_predicates() {
  local running done_out failed_out cancelled_out outcome_out parked owned fixing
  running=$'run:\n  status: running'
  fixing=$'run:\n  status: fixing'
  done_out=$'run:\n  status: completed'
  failed_out=$'run:\n  status: "failed"'
  cancelled_out=$'run:\n  status: cancelled'
  outcome_out=$'run:\n  status: running\noutcome: checks-passed'
  parked=$'run:\n  status: running\n  awaiting_agent: parked 0s'
  owned=$'run:\n  status: running\nbranch_sync:\n  state: pipeline_owned'

  fm_nm_run_is_active "$running" || fail "running is active"
  fm_nm_run_is_active "$done_out" && fail "completed is not active"
  fm_nm_run_is_active "$failed_out" && fail "quoted failed is not active"
  fm_nm_run_is_active "$cancelled_out" && fail "cancelled is not active"
  fm_nm_run_is_active "$outcome_out" && fail "an outcome ends activity"

  fm_nm_run_is_parked "$parked" || fail "awaiting_agent parks"
  fm_nm_run_is_parked $'gate:\n  step: lint\n  status: awaiting_approval' || fail "gate block parks"
  fm_nm_run_is_parked $'steps[1]{step,status}:\n  lint,awaiting_approval,1' || fail "gate row parks"
  fm_nm_run_is_parked $'x:\n  state: fix_review' || fail "fix_review parks"
  fm_nm_run_is_parked "$running" && fail "plain running is not parked"

  fm_nm_run_is_executing "$running" || fail "running executes"
  fm_nm_run_is_executing "$fixing" || fail "fixing executes"
  fm_nm_run_is_executing $'run:\n  status: ci' || fail "ci executes"
  fm_nm_run_is_executing "$parked" && fail "parked is not executing"
  fm_nm_run_is_executing "$done_out" && fail "completed is not executing"
  fm_nm_run_is_executing $'run:\n  status: weird' && fail "unknown status is not executing"

  fm_nm_run_is_pipeline_owned_active "$owned" || fail "owned active run binds"
  fm_nm_run_is_pipeline_owned_active "$running" && fail "no branch_sync, no custody"
  fm_nm_run_is_pipeline_owned_active $'run:\n  status: completed\nbranch_sync:\n  state: pipeline_owned' \
    && fail "terminal run never binds by custody"
  pass "active, parked, executing, and pipeline-owned predicates"
}

overview() {  # <count-line> <rows...>
  local count=$1 n
  shift
  n=$#
  printf 'count: %s\nruns[%d]{id,branch,status,head,pr}:\n' "$count" "$n"
  local row
  for row in "$@"; do printf '  %s\n' "$row"; done
}

test_select_run() {
  local out
  out=$(fm_nm_select_run b "$(overview '2 of 2 total' 'r2,b,completed,abcdef1,""' 'r1,b,failed,abcdef2,""')" "$REPO")
  assert_equals "selected|r2|completed|r2, r1" "$out" "newest same-branch row selected"
  out=$(fm_nm_select_run b "$(overview '2 of 2 total' 'r2,other,running,abcdef1,""' 'r1,b,failed,abcdef2,""')" "$REPO")
  assert_equals "selected|r1|failed|r1" "$out" "other branches are ignored"
  out=$(fm_nm_select_run b "$(overview '1 of 1 total' 'r1,other,running,abcdef1,""')" "$REPO")
  assert_equals absent "$out" "no same-branch row is absent"
  out=$(fm_nm_select_run b "$(overview '2 of 2 total' 'r2,b,running,abcdef1,""' 'r1,b,pending,abcdef2,""')" "$REPO")
  assert_equals "unknown|competing live runs; run ids: r2, r1" "$out" "two live rows are ambiguous"
  out=$(fm_nm_select_run b "$(overview '2 of 2 total' 'r2,b,failed,abcdef1,""' 'r1,b,running,abcdef2,""')" "$REPO")
  assert_equals "selected|r2|failed|r2, r1" "$out" "older live row does not hide a newer failure"
  out=$(fm_nm_select_run b "$(overview '1 of 1 total' 'r1,b,exploded,abcdef1,""')" "$REPO")
  assert_equals "unknown|unrecognized run status; run ids: r1" "$out" "unknown status word"
  out=$(fm_nm_select_run b "$(overview '1 of 1 total' 'r1,b,failed,zz,""')" "$REPO")
  assert_equals "unknown|unreadable runs table; run ids: r1" "$out" "bad head is unreadable"
  out=$(fm_nm_select_run b "$(overview '3 of 3 total' 'r1,b,failed,abcdef1,""')" "$REPO")
  assert_equals "unknown|unreadable runs table; run ids: r1" "$out" "row count mismatch is unreadable"
  out=$(fm_nm_select_run b "$(overview '1 of 1 total' 'r1,b,failed,abcdef1')" "$REPO")
  assert_equals "unknown|unreadable runs table; run ids: r1" "$out" "short row is unreadable"
  out=$(fm_nm_select_run b "$(overview '2 of 2 total' 'r1,b,failed,abcdef1,""' 'r1,b,failed,abcdef2,""')" "$REPO")
  assert_equals "unknown|unreadable runs table; run ids: r1" "$out" "duplicate run id is unreadable"
  out=$(fm_nm_select_run b $'status: ok' "$REPO")
  assert_equals unavailable "$out" "no runs table is unavailable"
  pass "select_run chooses the newest same-branch row and refuses ambiguity"
}

test_runs_status_for_worktree() {
  local s2 s3 sx out
  s2=${C2:0:8}
  s3=${C3:0:8}
  sx=${CSIDE:0:8}
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2026-01-02 10:00")
  assert_equals completed "$out" "matching newest row's status"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "failed b $s3 2026-01-02 10:00 https://example.invalid/pr/1")
  assert_equals failed "$out" "descendant head with PR url matches"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $sx 2026-01-02 10:00")
  assert_equals "" "$out" "diverged head is not this worktree's"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "failed other $s2 2026-01-02 10:00
completed b $s2 2026-01-01 10:00")
  assert_equals completed "$out" "other branch rows are skipped"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $sx 2026-01-02 10:00
completed b $s2 2026-01-01 10:00")
  assert_equals "" "$out" "older matching row never answers for a newer foreign one"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2026-01-02 10:00" "${C2:0:7}")
  assert_equals completed "$out" "expected head agreeing with newest row"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2026-01-02 10:00" "$sx")
  assert_equals "" "$out" "expected head contradicting newest row"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2026-01-02 10:00" "zz")
  assert_equals "" "$out" "malformed expected head"

  # Active row whose commit this copy lacks, anchored by an older row at HEAD.
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "running b deadbee 2026-01-02 11:00
failed b $s2 2026-01-02 10:00")
  assert_equals running "$out" "pipeline-owned continuation anchored at HEAD"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "running b deadbee 2026-01-02 11:00
failed b ${C1:0:8} 2026-01-02 10:00")
  assert_equals "" "$out" "an ancestor anchor is not enough"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "running b deadbee 2026-01-02 11:00")
  assert_equals "" "$out" "no anchor row"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "failed b deadbee 2026-01-02 11:00
failed b $s2 2026-01-02 10:00")
  assert_equals "" "$out" "a terminal unresolvable row is not continued"

  # Malformed rows stop the scan rather than guessing.
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2026-02-30 10:00")
  assert_equals "" "$out" "impossible date"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2026-01-02 25:00")
  assert_equals "" "$out" "impossible time"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2026-01-02 10:00 ftp://x")
  assert_equals "" "$out" "non-https pr field"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2026-01-02 10:00 https://x extra")
  assert_equals "" "$out" "trailing extra field"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "COMPLETED b $s2 2026-01-02 10:00")
  assert_equals "" "$out" "uppercase status word"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b zz 2026-01-02 10:00")
  assert_equals "" "$out" "non-hex sha"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "")
  assert_equals "" "$out" "empty ledger"
  out=$(fm_nm_runs_status_for_worktree "$TMP_ROOT/not-a-repo" b "completed b $s2 2026-01-02 10:00")
  assert_equals "" "$out" "non-repo worktree"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2024-02-29 10:00")
  assert_equals completed "$out" "leap day is valid"
  out=$(fm_nm_runs_status_for_worktree "$REPO" b "completed b $s2 2025-02-29 10:00")
  assert_equals "" "$out" "non-leap Feb 29 is invalid"
  pass "runs_status_for_worktree attributes only provable newest rows"
}

make_repo
test_text_helpers
test_commit_identity
test_status_class
test_branch_sync_readers
test_liveness_predicates
test_select_run
test_runs_status_for_worktree

echo '# all fm-nm-run-lib tests passed'
