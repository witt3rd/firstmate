#!/usr/bin/env bash
# Behavior tests for bin/fm-auto-teardown.sh: a finished task is torn down once
# it is done, a refusal leaves it alone and backs off, a secondmate or a task
# that is still working is never touched, --force is never passed, and a
# second sweep while one is live does nothing.
# crew-state and teardown are stubs in a copied bin/, so the suite pins the
# sweep's own decisions; teardown's landed-work refusals have their own suites.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-auto-teardown)

# make_world <name>: a home with a copied bin/ whose crew-state reads
# state/<id>.verdict and whose teardown records its argv and refuses for ids
# listed in state/.refuse.
make_world() {
  local name=$1 w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data"
  cp -R "$ROOT/bin" "$w/bin"
  cat > "$w/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/state/$1.verdict" 2>/dev/null || echo "state: unknown"
SH
  cat > "$w/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/.teardown-calls"
if grep -qx "$1" "$FM_HOME/state/.refuse" 2>/dev/null; then
  echo "REFUSED: $1 has unlanded work" >&2
  exit 1
fi
rm -f "$FM_HOME/state/$1.meta"
SH
  chmod +x "$w/bin/fm-crew-state.sh" "$w/bin/fm-teardown.sh"
  printf '%s\n' "$w"
}

add_task() {  # <world> <id> <kind> <verdict>
  fm_write_meta "$1/home/state/$2.meta" "kind=$3" "worktree=/nonexistent/$2"
  printf '%s\n' "$4" > "$1/home/state/$2.verdict"
}

sweep() {  # <world> [args]
  local w=$1
  shift
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" FM_AUTO_TEARDOWN=1 \
    "$w/bin/fm-auto-teardown.sh" "$@" 2>&1
}

test_done_task_is_torn_down_without_force() {
  local w out
  w=$(make_world finished)
  add_task "$w" ship-a ship "state: done · source: run-step · passed"
  add_task "$w" scout-a scout "state: done · source: status-log · report"
  out=$(sweep "$w")
  assert_contains "$out" "auto-teardown: ship-a done" "ship torn down"
  assert_contains "$out" "auto-teardown: scout-a done" "scout torn down"
  [ ! -e "$w/home/state/ship-a.meta" ] || fail "ship record removed by teardown"
  assert_not_contains "$(cat "$w/home/state/.teardown-calls")" "--force" "never forces"
  pass "done tasks are torn down, never with --force"
}

test_unfinished_and_secondmate_untouched() {
  local w out
  w=$(make_world untouched)
  add_task "$w" busy ship "state: working · source: pane · busy"
  add_task "$w" parked ship "state: parked · source: run-step · gate"
  add_task "$w" mate secondmate "state: done · source: status-log · x"
  out=$(sweep "$w")
  [ -z "$out" ] || fail "nothing attempted, got: $out"
  [ ! -e "$w/home/state/.teardown-calls" ] || fail "teardown must not run"
  pass "working, parked and secondmate records are never torn down"
}

test_refusal_keeps_task_and_backs_off() {
  local w out
  w=$(make_world refuse)
  add_task "$w" held ship "state: done · source: run-step · passed"
  echo held > "$w/home/state/.refuse"
  out=$(sweep "$w")
  assert_contains "$out" "auto-teardown: held kept (REFUSED: held has unlanded work)" "refusal reported"
  [ -e "$w/home/state/held.meta" ] || fail "refused task record must stay"
  out=$(sweep "$w")
  [ -z "$out" ] || fail "retry within the backoff window must be skipped: $out"
  [ "$(wc -l < "$w/home/state/.teardown-calls")" -eq 1 ] || fail "teardown ran once only"
  : > "$w/home/state/.refuse"
  out=$(FM_AUTO_TEARDOWN_RETRY_SECS=0 sweep "$w")
  assert_contains "$out" "auto-teardown: held done" "retried once landed"
  [ ! -e "$w/home/state/.auto-teardown-retry.held" ] || fail "retry marker cleared on success"
  pass "refusal keeps the task, backs off, and a later sweep finishes it"
}

test_live_sweep_blocks_second() {
  local w out
  w=$(make_world lock)
  add_task "$w" t ship "state: done · source: run-step · passed"
  mkdir "$w/home/state/.auto-teardown.lock"
  sleep 30 &
  local holder=$!
  echo "$holder" > "$w/home/state/.auto-teardown.lock/pid"
  out=$(sweep "$w")
  kill "$holder" 2>/dev/null
  [ -z "$out" ] || fail "a live sweep must block a second: $out"
  # a stale lock (dead pid) is taken over
  echo 999999 > "$w/home/state/.auto-teardown.lock/pid"
  out=$(sweep "$w")
  assert_contains "$out" "auto-teardown: t done" "stale lock taken over"
  pass "single flight per home, stale lock recovered"
}

test_opt_out() {
  local w out
  w=$(make_world off)
  add_task "$w" t ship "state: done · source: run-step · passed"
  out=$(FM_AUTO_TEARDOWN=0 FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" "$w/bin/fm-auto-teardown.sh" 2>&1)
  [ -z "$out" ] && [ ! -e "$w/home/state/.teardown-calls" ] || fail "FM_AUTO_TEARDOWN=0 must disable the sweep"
  pass "FM_AUTO_TEARDOWN=0 disables the sweep"
}

test_detach_returns_and_logs() {
  local w i
  w=$(make_world detach)
  add_task "$w" t ship "state: done · source: run-step · passed"
  sweep "$w" --detach >/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q "auto-teardown: t done" "$w/home/state/.auto-teardown.log" 2>/dev/null && break
    sleep 0.5
  done
  grep -q "auto-teardown: t done" "$w/home/state/.auto-teardown.log" || fail "detached sweep logs its result"
  pass "--detach returns at once and the sweep logs its result"
}

test_done_task_is_torn_down_without_force
test_unfinished_and_secondmate_untouched
test_refusal_keeps_task_and_backs_off
test_live_sweep_blocks_second
test_opt_out
test_detach_returns_and_logs

test_detach_is_rate_limited() {
  local w
  w=$(make_world rate)
  add_task "$w" t1 ship "state: done · source: run-step · passed"
  sweep "$w" --detach >/dev/null
  sleep 2
  add_task "$w" t2 ship "state: done · source: run-step · passed"
  sweep "$w" --detach >/dev/null
  sleep 2
  grep -q "auto-teardown: t1 done" "$w/home/state/.auto-teardown.log" || fail "first detached sweep ran"
  ! grep -q "auto-teardown: t2" "$w/home/state/.auto-teardown.log" || fail "second request within the interval must be skipped"
  pass "--detach requests inside the interval are skipped"
}

# The wake path: a main drain starts one sweep; a branch drain never does.
test_wake_drain_starts_the_sweep() {
  local w i
  w=$(make_world drain)
  cat > "$w/bin/fm-auto-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/.sweep-calls"
SH
  chmod +x "$w/bin/fm-auto-teardown.sh"
  : > "$w/home/state/.wake-queue"
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" "$w/bin/fm-wake-drain.sh" >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$w/home/state/.sweep-calls" ] && break
    sleep 0.3
  done
  [ "$(cat "$w/home/state/.sweep-calls" 2>/dev/null)" = "--detach" ] || fail "main drain must start the detached sweep"
  pass "a main wake drain starts the detached sweep"
}

test_detach_is_rate_limited
test_wake_drain_starts_the_sweep
