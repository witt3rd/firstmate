#!/usr/bin/env bash
# Behavior tests for bin/fm-retire-stale-record.sh: the guarded retirement of a
# finished task's stale record when bin/fm-teardown.sh cannot clean it up (its
# worktree slot now belongs to a later task, or the worktree is gone).
#
# Every case runs the real script in a throwaway home with a real backlog and the
# real tasks-axi, a throwaway git project and pool slots, and a stub tmux/gh. It
# asserts the RECORD STATE and that nothing a retirement must never touch (a
# slot, its claim, another task's files, the report) changed.
#
#   retires a scout whose slot a later live task now owns: record, alert and
#     marker files gone, backlog item closed, the slot, its claim and the later
#     task's own files untouched
#   retires a ship whose worktree is gone and whose PR is merged
#   dry run (the default) changes nothing, byte for byte
#   second run is a no-op
#   refuses: missing or empty report, unmerged PR, commits not on a remote in a
#     named slot, a live task, an intact exclusively-owned slot, an open keyed
#     decision, a secondmate
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

RETIRE="$ROOT/bin/fm-retire-stale-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-retire-stale-record)

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the backlog close is inert without it)\n'
  exit 0
}
unset TASKS_AXI_BACKEND || :

# A home with a real backlog, a project clone with an origin, and a pool laid out
# the way Treehouse lays slots out (<pool>/<slot>/<repo>, claim beside the repo).
make_case() {  # <name> <task-id...>
  local name=$1 case_dir home fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects" "$case_dir/pool"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  for id in "$@"; do
    tasks-axi add "$id" "item for $id" --kind ship --file "$home/data/backlog.md" >/dev/null
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  done
  # tmux: a window is "alive" when listed in $FM_FAKE_TMUX_ALIVE (agent
  # foreground), "dead" when in $FM_FAKE_TMUX_DEAD (shell only), else missing.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
alive=${FM_FAKE_TMUX_ALIVE:-}
dead=${FM_FAKE_TMUX_DEAD:-}
target=
for a in "$@"; do target=$a; done
case "${1:-}" in
  list-windows)
    printf '%s\n' $alive $dead
    [ -n "$alive$dead" ] || { echo "no server running on /tmp/fake" >&2; exit 1; }
    exit 0 ;;
  display-message)
    for w in $alive; do case " $* " in *"fm-$w"*|*":$w"*) printf 'pi\n'; exit 0 ;; esac; done
    printf 'bash\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes gh-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# `gh pr view <pr-or-branch> --json state,url -q ...`: FM_FAKE_PR_STATE decides.
if [ "${1:-} ${2:-}" = "pr view" ]; then
  [ -n "${FM_FAKE_PR_STATE:-}" ] || { echo "no pull request found" >&2; exit 1; }
  printf '%s\t%s\n' "$FM_FAKE_PR_STATE" "https://github.com/example/repo/pull/7"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/gh"
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' "$case_dir"
}

home_of() { printf '%s/home\n' "$1"; }

# A pool slot checked out as a worktree of the project, with an owner claim.
make_slot() {  # <case-dir> <slot-name> <branch> [claimant]
  local case_dir=$1 slot=$2 branch=$3 claimant=${4:-}
  mkdir -p "$case_dir/pool/$slot"
  : > "$case_dir/pool/treehouse-state.json"
  git -C "$case_dir/project" worktree add --quiet -b "$branch" "$case_dir/pool/$slot/repo"
  if [ -n "$claimant" ]; then
    printf 'task=%s\nhome=%s\n' "$claimant" "$(home_of "$case_dir")" > "$case_dir/pool/$slot/.fm-slot-owner"
  fi
  printf '%s\n' "$case_dir/pool/$slot/repo"
}

# Write a task record plus the volatile files a finished task leaves behind.
write_task() {  # <case-dir> <id> <kind> <worktree> [extra meta...]
  local case_dir=$1 id=$2 kind=$3 wt=$4 state
  shift 4
  state="$(home_of "$case_dir")/state"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$case_dir/project" "kind=$kind" "mode=no-mistakes" \
    "branch=fm/$id" "spawn_gen=s1.$id.1" "$@"
  # A scout's captain-call inventory is complete (bin/fm-captain-hold.sh verify).
  [ "$kind" != scout ] || printf 'decisions_reviewed=1\n' >> "$state/$id.meta"
  printf 'done [at=1]: finished\n' > "$state/$id.status"
  : > "$state/$id.turn-ended"
  mkdir -p "$state/$id.inbox"
  : > "$state/$id.inbox/001.msg"
  : > "$state/.count-firstmate_fm-$id"
  : > "$state/.hash-firstmate_fm-$id"
  : > "$state/.stale-since-firstmate_fm-$id"
  : > "$state/.wedge-escalations-firstmate_fm-$id"
}

# A real report: a Markdown heading and a standalone body well over the floor.
real_report() {  # <id>
  printf '# Report for %s\n\n' "$1"
  printf 'What was done, what was found, the evidence and the recommendation. %.0s' 1 2 3 4
  printf '\n'
}

write_report() {  # <case-dir> <id> [content]
  mkdir -p "$(home_of "$1")/data/$2"
  if [ "$#" -ge 3 ]; then
    printf '%s' "$3" > "$(home_of "$1")/data/$2/report.md"
  else
    real_report "$2" > "$(home_of "$1")/data/$2/report.md"
  fi
}

# Everything under the case dir except the throwaway tool shims, as one
# comparable digest: path, mode and content hash of every entry.
snapshot() {  # <case-dir>
  (cd "$1" && find . -path ./fakebin -prune -o -path '*/.git' -prune -o -path '*/.git/*' -prune \
    -o -print | LC_ALL=C sort | while IFS= read -r f; do
      if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum < "$f")"; else printf '%s\n' "$f"; fi
    done)
}

run_retire() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  PATH="$case_dir/fakebin:$PATH" FM_HOME="$(home_of "$case_dir")" \
    FM_FAKE_TMUX_ALIVE="${ALIVE:-}" FM_FAKE_TMUX_DEAD="${DEAD:-}" \
    FM_FAKE_PR_STATE="${PR_STATE:-}" \
    bash "$RETIRE" "$@" 2>&1
}

row_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$(home_of "$1")/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# --- the case this script exists for ----------------------------------------

test_retires_scout_whose_slot_a_later_live_task_owns() {
  local c wt before_slot out rc state leftover
  c=$(make_case shared scout1 later1)
  state="$(home_of "$c")/state"
  wt=$(make_slot "$c" slot1 fm/later1 later1)
  write_task "$c" scout1 scout "$wt"
  write_task "$c" later1 ship "$wt"
  write_report "$c" scout1
  before_slot=$(snapshot "$c/pool")
  ALIVE=fm-later1
  DEAD=
  out=$(ALIVE=fm-later1 run_retire "$c" scout1 --confirm) && rc=0 || rc=$?
  expect_code 0 "$rc" "retire a scout on a reassigned slot"$'\n'"$out"
  assert_contains "$out" "retire scout1 complete" "reports completion"
  assert_absent "$state/scout1.meta" "scout record is removed"
  assert_absent "$state/scout1.status" "scout status is removed"
  assert_absent "$state/scout1.inbox" "scout inbox is removed"
  assert_absent "$state/scout1.turn-ended" "scout turn marker is removed"
  assert_absent "$state/.count-firstmate_fm-scout1" "scout idle counter is removed"
  assert_absent "$state/.hash-firstmate_fm-scout1" "scout pane hash is removed"
  assert_absent "$state/.stale-since-firstmate_fm-scout1" "scout stale marker is removed"
  assert_absent "$state/.wedge-escalations-firstmate_fm-scout1" "scout wedge counter is removed"
  assert_absent "$state/scout1.backlog-close" "no pending-close record is left"
  leftover=$(find "$state" -name '*scout1*' -print)
  assert_equals "" "$leftover" "no file named for the retired task remains"
  assert_equals "$before_slot" "$(snapshot "$c/pool")" "the slot and its claim are untouched"
  assert_present "$wt/README.md" "the slot's checkout is intact"
  assert_present "$state/later1.meta" "the later task's record is untouched"
  assert_present "$state/later1.status" "the later task's status is untouched"
  assert_present "$state/later1.inbox/001.msg" "the later task's inbox is untouched"
  assert_present "$state/.count-firstmate_fm-later1" "the later task's markers are untouched"
  assert_present "$(home_of "$c")/data/scout1/report.md" "the report stays"
  assert_equals "done" "$(row_state "$c" scout1)" "the backlog item is closed"
  assert_equals "in_flight" "$(row_state "$c" later1)" "the later task's item is untouched"
  pass "retires a scout whose slot a later live task owns"
}

test_retires_ship_with_gone_worktree_and_merged_pr() {
  local c out rc
  c=$(make_case ship ship1)
  write_task "$c" ship1 ship "$c/pool/gone/repo" "pr=https://github.com/example/repo/pull/7"
  out=$(PR_STATE=MERGED run_retire "$c" ship1 --confirm) && rc=0 || rc=$?
  expect_code 0 "$rc" "retire a ship with a merged PR"$'\n'"$out"
  assert_absent "$(home_of "$c")/state/ship1.meta" "ship record is removed"
  assert_equals "done" "$(row_state "$c" ship1)" "the ship's backlog item is closed"
  tasks-axi show ship1 --file "$(home_of "$c")/data/backlog.md" 2>/dev/null | grep -q 'pull/7' \
    || fail "the closed item links the merged PR"
  pass "retires a ship whose worktree is gone and whose PR is merged"
}

test_dry_run_changes_nothing() {
  local c wt before after out rc
  c=$(make_case dry scout1 later1)
  wt=$(make_slot "$c" slot1 fm/later1 later1)
  write_task "$c" scout1 scout "$wt"
  write_task "$c" later1 ship "$wt"
  write_report "$c" scout1
  before=$(snapshot "$c")
  out=$(ALIVE=fm-later1 run_retire "$c" scout1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a dry run that would retire exits 0"$'\n'"$out"
  assert_contains "$out" "would remove: $(home_of "$c")/state/scout1.meta" "the dry run names the record"
  assert_contains "$out" "dry run: nothing was changed" "the dry run says it changed nothing"
  after=$(snapshot "$c")
  assert_equals "$before" "$after" "a dry run leaves every file as it was"
  assert_equals "in_flight" "$(row_state "$c" scout1)" "a dry run leaves the backlog item open"
  pass "dry run changes nothing"
}

test_second_run_is_a_no_op() {
  local c wt before out rc
  c=$(make_case twice scout1 later1)
  wt=$(make_slot "$c" slot1 fm/later1 later1)
  write_task "$c" scout1 scout "$wt"
  write_task "$c" later1 ship "$wt"
  write_report "$c" scout1
  ALIVE=fm-later1 run_retire "$c" scout1 --confirm >/dev/null || fail "first retire"
  before=$(snapshot "$c")
  out=$(ALIVE=fm-later1 run_retire "$c" scout1 --confirm) && rc=0 || rc=$?
  expect_code 0 "$rc" "the second run succeeds"$'\n'"$out"
  assert_contains "$out" "nothing to retire" "the second run says there is nothing to do"
  assert_equals "$before" "$(snapshot "$c")" "the second run changes nothing"
  out=$(run_retire "$c" scout1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a dry run after retirement succeeds"
  pass "second run is a no-op"
}

# --- refusals ---------------------------------------------------------------

refuses() {  # <label> <expected-reason> <case-dir> <id> [env...]
  local label=$1 reason=$2 c=$3 id=$4 before out rc
  before=$(snapshot "$c")
  out=$(run_retire "$c" "$id" --confirm) && rc=0 || rc=$?
  expect_code 1 "$rc" "$label refuses"$'\n'"$out"
  assert_contains "$out" "REFUSED" "$label names a refusal"
  assert_contains "$out" "$reason" "$label gives the exact reason"
  assert_equals "$before" "$(snapshot "$c")" "$label changes nothing"
  assert_equals "in_flight" "$(row_state "$c" "$id")" "$label leaves the backlog item open"
  pass "refuses: $label"
}

test_refuses_missing_and_empty_report() {
  local c wt
  c=$(make_case noreport scout1 later1)
  wt=$(make_slot "$c" slot1 fm/later1 later1)
  write_task "$c" scout1 scout "$wt"
  write_task "$c" later1 ship "$wt"
  refuses "a scout with no report" "has no report" "$c" scout1
  write_report "$c" scout1 ""
  refuses "a scout with an empty report" "is not a real report" "$c" scout1
  write_report "$c" scout1 "x"
  refuses "a scout with a one-byte report" "is not a real report" "$c" scout1
  write_report "$c" scout1 "# Report"$'\n'"short"
  refuses "a scout with a heading but a stub body" "is not a real report" "$c" scout1
  write_report "$c" scout1 "$(printf 'no heading on the first line, just prose. %.0s' 1 2 3 4 5 6 7 8)"
  refuses "a scout with a long report that has no heading" "is not a real report" "$c" scout1
  write_report "$c" scout1
  ALIVE=fm-later1 run_retire "$c" scout1 >/dev/null || fail "a real report passes the gate"
  pass "a real report is accepted, a stub is not"
}

test_refuses_unpushed_commits_in_a_named_slot() {
  local c wt
  c=$(make_case unpushed scout1)
  wt=$(make_slot "$c" slot1 fm/scout1)
  printf 'x\n' > "$wt/new.txt"
  git -C "$wt" add new.txt
  git -C "$wt" -c user.name=t -c user.email=t@t commit -qm "unpushed work"
  write_task "$c" scout1 scout "$wt"
  write_report "$c" scout1
  refuses "a slot holding unpushed commits" "holds commits not on any remote" "$c" scout1
}

test_refuses_unpushed_commits_on_the_records_own_branch_in_a_shared_slot() {
  local c wt
  c=$(make_case sharedunpushed scout1 later1)
  wt=$(make_slot "$c" slot1 fm/scout1 later1)
  printf 'x\n' > "$wt/new.txt"
  git -C "$wt" add new.txt
  git -C "$wt" -c user.name=t -c user.email=t@t commit -qm "unpushed work"
  write_task "$c" scout1 scout "$wt"
  write_task "$c" later1 ship "$wt"
  write_report "$c" scout1
  refuses "a shared slot on this record's own branch with unpushed commits" \
    "holds commits not on any remote" "$c" scout1
}

test_refuses_a_live_task() {
  local c wt
  c=$(make_case live scout1)
  wt=$(make_slot "$c" slot1 fm/scout1 scout1)
  write_task "$c" scout1 scout "$wt"
  write_report "$c" scout1
  ALIVE=fm-scout1
  refuses "a live task" "is live" "$c" scout1
  ALIVE=
}

test_refuses_an_intact_exclusive_slot() {
  local c wt
  c=$(make_case intact scout1)
  wt=$(make_slot "$c" slot1 fm/scout1 scout1)
  write_task "$c" scout1 scout "$wt"
  write_report "$c" scout1
  refuses "an intact exclusively-owned slot" "use bin/fm-teardown.sh scout1" "$c" scout1
}

test_refuses_unlanded_ship() {
  local c
  c=$(make_case unlanded ship1)
  write_task "$c" ship1 ship "$c/pool/gone/repo" "pr=https://github.com/example/repo/pull/7"
  PR_STATE=OPEN
  refuses "a ship whose PR is not merged" "is OPEN, not merged" "$c" ship1
  PR_STATE=
  refuses "a ship whose PR cannot be read" "cannot read the pull request" "$c" ship1
}

test_refuses_an_open_keyed_decision() {
  local c
  c=$(make_case keyed ship1)
  write_task "$c" ship1 ship "$c/pool/gone/repo" "pr=https://github.com/example/repo/pull/7"
  printf 'needs-decision [at=1] [key=k1]: pick one\n' >> "$(home_of "$c")/state/ship1.status"
  PR_STATE=MERGED
  refuses "an open keyed decision" "open keyed decision (k1)" "$c" ship1
  PR_STATE=
}

test_never_chmods_through_a_planted_hooks_symlink() {
  local c outside state mode
  c=$(make_case hooklink scout1)
  state="$(home_of "$c")/state"
  write_task "$c" scout1 scout "$c/pool/gone/repo"
  write_report "$c" scout1
  outside="$c/outside-hooks"
  mkdir -p "$outside"
  chmod 500 "$outside"
  ln -s "$outside" "$state/scout1.git-hooks"
  run_retire "$c" scout1 --confirm >/dev/null || fail "retire with a planted hooks symlink"
  mode=$(stat -c %a "$outside" 2>/dev/null || stat -f %Lp "$outside")
  chmod 700 "$outside"
  assert_equals "500" "$mode" "the link's target keeps its mode"
  assert_absent "$state/scout1.git-hooks" "the planted link itself is removed"
  assert_present "$outside" "the link's target survives"
  # A real read-only hooks directory is still cleared.
  c=$(make_case hookdir scout1)
  state="$(home_of "$c")/state"
  write_task "$c" scout1 scout "$c/pool/gone/repo"
  write_report "$c" scout1
  mkdir -p "$state/scout1.git-hooks"
  : > "$state/scout1.git-hooks/commit-msg"
  chmod 500 "$state/scout1.git-hooks"
  run_retire "$c" scout1 --confirm >/dev/null || fail "retire with a read-only hooks directory"
  assert_absent "$state/scout1.git-hooks" "a real read-only hooks directory is removed"
  pass "never chmods through a planted hooks symlink"
}

test_refuses_a_shared_endpoint_and_keeps_the_other_tasks_wake_rows() {
  local c state
  c=$(make_case sharedendpoint scout1 later1)
  state="$(home_of "$c")/state"
  write_task "$c" scout1 scout "$c/pool/gone/repo" "window=firstmate:fm-shared"
  write_task "$c" later1 ship "$c/pool/gone2/repo" "window=firstmate:fm-shared"
  write_report "$c" scout1
  printf '1\t1\tstale\tfirstmate:fm-shared\tx\n' > "$state/.wake-queue"
  refuses "an endpoint another task's record also names" "is also named by task later1" "$c" scout1
  assert_grep "firstmate:fm-shared" "$state/.wake-queue" "the other task's wake row is kept"
}

test_refuses_a_secondmate() {
  local c
  c=$(make_case mate mate1)
  write_task "$c" mate1 secondmate "$c/pool/gone/repo"
  refuses "a secondmate" "is a secondmate" "$c" mate1
}

test_rejects_bad_requests() {
  local c out rc
  c=$(make_case bad)
  out=$(run_retire "$c" '../etc' --confirm) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unsafe task id is a bad request"
  out=$(run_retire "$c" a b) && rc=0 || rc=$?
  expect_code 2 "$rc" "two task ids are a bad request"
  out=$(run_retire "$c" a --force) && rc=0 || rc=$?
  expect_code 2 "$rc" "there is no --force"
  assert_contains "$out" "unknown option" "--force is rejected by name"
  pass "rejects bad requests"
}

test_retires_scout_whose_slot_a_later_live_task_owns
test_retires_ship_with_gone_worktree_and_merged_pr
test_dry_run_changes_nothing
test_second_run_is_a_no_op
test_refuses_missing_and_empty_report
test_refuses_unpushed_commits_in_a_named_slot
test_refuses_unpushed_commits_on_the_records_own_branch_in_a_shared_slot
test_refuses_a_live_task
test_refuses_an_intact_exclusive_slot
test_refuses_unlanded_ship
test_refuses_an_open_keyed_decision
test_refuses_a_secondmate
test_never_chmods_through_a_planted_hooks_symlink
test_refuses_a_shared_endpoint_and_keeps_the_other_tasks_wake_rows
test_rejects_bad_requests
