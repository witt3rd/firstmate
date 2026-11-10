#!/usr/bin/env bash
# fm-teardown ends the task via fleet-task-stop on every backend (pane target only on tmux), before the window kill.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-taskstop)

make_case() {  # <name> <backend-meta-lines...> ; helper presence via WITH_HELPER
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" "$dir/worktree" "$dir/project"
  git init -q "$dir/project"
  : > "$dir/runtime.log"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse"
  if [ "${WITH_HELPER:-1}" = 1 ]; then
    cat > "$dir/fakebin/fleet-task-stop" <<'SH'
#!/usr/bin/env bash
printf 'fleet-task-stop' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit "${FAKE_STOP_RC:-0}"
SH
    chmod +x "$dir/fakebin/fleet-task-stop"
  fi
  printf '%s\n' "$dir"
}

run_case() {  # <dir> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" --force >"$dir/stdout" 2>"$dir/stderr"
}

test_tmux_calls_helper_before_kill() {
  local dir id=ts-a rc=0
  dir=$(make_case tmux)
  fm_write_meta "$dir/home/state/$id.meta" "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  run_case "$dir" "$id" || rc=$?
  [ "$rc" -eq 0 ] || fail "tmux teardown failed rc=$rc: $(cat "$dir/stderr")"
  grep -q "^fleet-task-stop <$id> <isolated:fm-$id>$" "$dir/runtime.log" \
    || fail "helper not called with id and target: $(cat "$dir/runtime.log")"
  local stop kill
  stop=$(grep -n '^fleet-task-stop' "$dir/runtime.log" | head -1 | cut -d: -f1)
  kill=$(grep -n '^tmux.*kill-window' "$dir/runtime.log" | head -1 | cut -d: -f1)
  [ -n "$kill" ] && [ "$stop" -lt "$kill" ] || fail "helper must precede kill-window: $(cat "$dir/runtime.log")"
  pass "fm-teardown tmux: fleet-task-stop runs with id and target before the window kill"
}

test_helper_failure_does_not_block() {
  local dir id=ts-b rc=0
  dir=$(make_case failing)
  fm_write_meta "$dir/home/state/$id.meta" "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  FAKE_STOP_RC=7 run_case "$dir" "$id" || rc=$?
  [ "$rc" -eq 0 ] || fail "helper failure blocked teardown rc=$rc"
  grep -q kill-window "$dir/runtime.log" || fail "window not killed after helper failure"
  pass "fm-teardown tmux: a failing fleet-task-stop never refuses teardown"
}

test_absent_helper_unchanged() {
  local dir id=ts-c rc=0
  dir=$(WITH_HELPER=0 make_case nohelper)
  fm_write_meta "$dir/home/state/$id.meta" "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  run_case "$dir" "$id" || rc=$?
  [ "$rc" -eq 0 ] || fail "teardown without helper failed rc=$rc: $(cat "$dir/stderr")"
  grep -q kill-window "$dir/runtime.log" || fail "window not killed without helper"
  pass "fm-teardown tmux: absent fleet-task-stop leaves behaviour unchanged"
}

test_non_tmux_backend_calls_helper_without_target() {
  local dir id=ts-d rc=0
  dir=$(make_case zellij)
  cat > "$dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/zellij"
  fm_write_meta "$dir/home/state/$id.meta" "window=lab:7" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  run_case "$dir" "$id" || rc=$?
  [ "$rc" -eq 0 ] || fail "zellij teardown failed rc=$rc: $(cat "$dir/stderr")"
  grep -q "^fleet-task-stop <$id>$" "$dir/runtime.log" || fail "helper not called with id only: $(cat "$dir/runtime.log")"
  pass "fm-teardown non-tmux: fleet-task-stop runs with the task id and no pane target"
}

test_tmux_calls_helper_before_kill
test_helper_failure_does_not_block
test_absent_helper_unchanged
test_non_tmux_backend_calls_helper_without_target
