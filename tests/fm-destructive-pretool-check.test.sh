#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031  # subshell-scoped env is deliberate
# Behavior tests for the destructive-command guard (docs/destructive-guard.md).
#
# bin/fm-destructive-command-policy.mjs is the single owner of the allow/deny
# decision; bin/fm-destructive-pretool-check.sh is the stable transport that
# supplies identity, honors the captain-or-main override, logs, tells the
# parent, and renders every harness entry form. This suite proves the decision
# matrix (led by the exact xwvol incident command shapes) through all five entry
# forms, the override and its self-grant refusal, the durable log and the
# supervisor note, the primary adapter's stand-down in worker panes, the
# fail-open transport, and the per-task adapters fm-spawn installs for Pi and
# Claude workers plus the tracked Pi primary extension. No harness is spawned
# and no docker, rm, or device command ever runs: every case is classification
# only.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_git_identity fmtest fmtest@example.invalid
# The prefix deliberately avoids "fm-": /tmp/fm-* is the one tree the find
# rule opens, so a fixture home there would mask the denials under test.
TMP_ROOT=$(fm_test_tmproot dguard-test)
CHECK="$ROOT/bin/fm-destructive-pretool-check.sh"
POLICY="$ROOT/bin/fm-destructive-command-policy.mjs"

FIX_HOME="$TMP_ROOT/home"
FIX_PARENT="$TMP_ROOT/parent-home"
FIX_WT="$FIX_HOME/.treehouse/pool-x/3/proj"
FIX_TASK=dg-task-1
mkdir -p "$FIX_WT/build" "$FIX_PARENT/state" "$FIX_HOME/src/other"

# Run the transport the way a per-task worker adapter does: from the worker's
# own worktree, with the fixture HOME, and with no inherited override.
run_check() {  # <stdin-or-empty> <args...>
  local input=$1
  shift
  (
    cd "$FIX_WT" || exit 99
    unset FM_DESTRUCTIVE_OK FM_TASK_ID
    if [ -n "$input" ]; then
      printf '%s' "$input" | HOME="$FIX_HOME" FM_HOME="$FIX_PARENT" "$CHECK" "$@"
    else
      HOME="$FIX_HOME" FM_HOME="$FIX_PARENT" "$CHECK" "$@" </dev/null
    fi
  )
}

WORKER_ARGS=(--state "$FIX_PARENT/state" --task "$FIX_TASK" --worktree "$FIX_WT")

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

# The xwvol incident shapes: a filtered listing fed into a volume removal.
matrix_case X01 deny 'docker volume ls -q -f name=xwvol- -f name=ws- | xargs docker volume rm'
matrix_case X02 deny 'docker volume ls -q --filter name=xwvol | xargs -r docker volume rm -f'
matrix_case X03 deny 'docker volume rm $(docker volume ls -q -f name=xwvol-)'
matrix_case X04 deny 'docker volume rm `docker volume ls -q -f name=xwvol-`'
matrix_case X05 deny "ssh x 'docker volume ls -q -f name=xwvol | xargs docker volume rm'"
matrix_case X06 deny 'for v in $(docker volume ls -q -f name=xwvol); do docker volume rm "$v"; done'
matrix_case X07 deny 'docker volume ls -q | grep xwvol | xargs -n1 docker volume rm'
matrix_case X08 deny 'docker volume rm xwvol-ws-123'
matrix_case X09 deny 'docker volume ls -q -f name=xwvol | while read -r v; do docker volume rm "$v"; done'
# Docker and podman bulk forms.
matrix_case D01 deny 'docker volume prune -f'
matrix_case D02 deny 'docker system prune -af --volumes'
matrix_case D03 deny 'docker container prune'
matrix_case D04 deny 'docker image prune -a'
matrix_case D05 deny 'docker network prune -f'
matrix_case D06 deny 'docker rm -f $(docker ps -aq)'
matrix_case D07 deny 'docker rmi xwvol-*'
matrix_case D08 deny 'sudo docker volume rm $VOL'
matrix_case D09 deny 'podman volume prune'
matrix_case D10 deny 'docker rm -f other-stack-web'
matrix_case D11 deny 'docker -H ssh://x volume prune -f'
matrix_case D12 deny "bash -c 'docker volume prune -f'"
matrix_case D13 deny "eval 'docker system prune -f'"
matrix_case D14 deny 'case x in a) docker volume prune -f;; esac'
# Recursive rm over a glob or root under the home directory or /mnt.
matrix_case R01 deny 'rm -rf ~/.treehouse/*'
matrix_case R02 deny 'rm -rf ~/.local/state/*'
matrix_case R03 deny 'rm -rf /mnt/nasty/*'
matrix_case R04 deny 'rm -rf ~/Documents/old-*'
matrix_case R05 deny 'rm -rf ~/backups/*'
matrix_case R06 deny 'rm -rf "$HOME"/*'
matrix_case R07 deny 'rm -rf ~'
matrix_case R08 deny 'cd ~ && rm -rf *'
matrix_case R09 deny 'rm -rf ~/.treehouse/firstmate-d3fceb'
matrix_case R10 deny 'find ~ -name cache | xargs rm -rf'
# git clean outside the pane's own worktree.
matrix_case G01 deny 'git -C ~/src/other clean -fdx'
matrix_case G02 deny 'cd ~/src/other && git clean -fdx'
# find -delete or -exec rm outside /tmp/fm-*.
matrix_case F01 deny "find . -name '*.pyc' -delete"
matrix_case F02 deny 'find ~ -name x -exec rm -rf {} +'
# Block devices, btrfs subvolumes, and managed systemd units.
matrix_case V01 deny 'dd if=/dev/zero of=/dev/sda bs=1M'
matrix_case V02 deny 'mkfs.ext4 /dev/sdb1'
matrix_case V03 deny 'wipefs -a /dev/sdb'
matrix_case V04 deny 'parted /dev/sda mklabel gpt'
matrix_case V05 deny 'btrfs subvolume delete /mnt/snap'
matrix_case V06 deny 'sudo btrfs sub del /x'
matrix_case V07 deny 'systemctl --user disable animus'
matrix_case V08 deny 'systemctl mask foo.service'
# A self-granted override inside the command grants nothing.
matrix_case O01 deny 'FM_DESTRUCTIVE_OK=T-1 docker volume prune -f'
matrix_case O02 deny 'export FM_DESTRUCTIVE_OK=T-1; docker volume prune -f'
matrix_case O03 deny 'env FM_DESTRUCTIVE_OK=T-1 docker volume prune -f'

# ALLOW: read-only, explicitly named own resources, own worktree, or data.
matrix_case A01 allow 'docker volume ls -q -f name=xwvol'
matrix_case A02 allow 'docker ps -a'
matrix_case A03 allow "docker volume rm $FIX_TASK-db"
matrix_case A04 allow "docker rm -f $FIX_TASK-web"
matrix_case A05 allow 'docker builder prune -f'
matrix_case A06 allow 'echo "docker volume prune -f"'
matrix_case A07 allow 'rm -rf build/*'
matrix_case A08 allow 'rm -rf ./node_modules'
matrix_case A09 allow 'rm -rf /tmp/fm-dg/*'
matrix_case A10 allow 'rm -f notes.txt'
matrix_case A11 allow 'git clean -fdx'
matrix_case A12 allow 'git clean -n -dx'
matrix_case A13 allow 'git status'
matrix_case A14 allow 'find /tmp/fm-abc -type f -delete'
matrix_case A15 allow 'find . -name x -print'
matrix_case A16 allow 'dd if=x of=/dev/null'
matrix_case A17 allow 'parted -l'
matrix_case A18 allow 'systemctl --user status animus'
matrix_case A19 allow 'mkfs.ext4 ./disk.img'
matrix_case A20 allow 'ls -la'
matrix_case A21 allow 'rm -rf "$tmpdir"'
matrix_case A22 allow "grep -rn 'docker volume prune' docs"
matrix_case A23 allow 'docker compose down'
matrix_case A24 allow "printf '%s\\n' 'rm -rf ~/*'"
matrix_case A25 allow $'cat <<\'EOF\'\nrm -rf ~/.treehouse/*\nEOF'
matrix_case A26 allow "rm -rf $FIX_WT/build/*"

MATRIX_TMP="$TMP_ROOT/matrix"
mkdir -p "$MATRIX_TMP"

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"
  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      run_check "$payload" "${WORKER_ARGS[@]}" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      run_check "$payload" --claude "${WORKER_ARGS[@]}" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      run_check "$payload" "${WORKER_ARGS[@]}" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      run_check "" --command "$cmd" "${WORKER_ARGS[@]}" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *) fail "unknown matrix entry form: $entry" ;;
  esac
  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow '$cmd', got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi
  [ "$rc" -eq 2 ] || fail "$id via $entry must deny '$cmd', got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("^\\[[a-z-]+\\] destructive-command guard: "))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "acceptance matrix: ${#MATRIX_IDS[@]} cases, including every xwvol incident shape, across five harness entry forms"
}

# The policy CLI names the incident shapes with the stable reason codes the
# contract documents, so an adapter or log reader can rely on them.
test_policy_reason_codes() {
  local out
  out=$(node "$POLICY" --command 'docker volume ls -q -f name=xwvol | xargs docker volume rm' --cwd "$FIX_WT" --home "$FIX_HOME")
  assert_equals "$(printf '%s' "$out" | cut -f1,2)" "deny	docker-bulk-rm" "the xwvol pipe shape must deny as docker-bulk-rm"
  out=$(node "$POLICY" --command 'docker volume prune -f' --cwd "$FIX_WT" --home "$FIX_HOME")
  assert_equals "$(printf '%s' "$out" | cut -f1,2)" "deny	docker-prune" "a prune must deny as docker-prune"
  out=$(node "$POLICY" --command "docker volume rm $FIX_TASK-db" --cwd "$FIX_WT" --home "$FIX_HOME")
  assert_equals "$(printf '%s' "$out" | cut -f1,2)" "deny	docker-rm-unowned" "without an own label even a named volume is unowned"
  out=$(node "$POLICY" --command "docker volume rm $FIX_TASK-db" --cwd "$FIX_WT" --home "$FIX_HOME" --own-label "$FIX_TASK")
  assert_equals "$out" "allow" "the named own-label volume must allow"
  out=$(node "$POLICY" --command 'git clean -fdx' --cwd "$FIX_WT" --home "$FIX_HOME")
  assert_equals "$(printf '%s' "$out" | cut -f1,2)" "deny	git-clean" "git clean with no worktree spawned for the caller must deny"
  pass "policy CLI: stable reason codes, own-label allow, and own-worktree gating"
}

# --- log, supervisor note, and override -------------------------------------

test_denial_is_logged_and_noted() {
  local home="$TMP_ROOT/log-home" log status line rc
  mkdir -p "$home/state"
  (
    cd "$FIX_WT" || exit 99
    unset FM_DESTRUCTIVE_OK FM_TASK_ID
    HOME="$FIX_HOME" "$CHECK" --command 'docker volume ls -q -f name=xwvol | xargs docker volume rm' \
      --state "$home/state" --task log-task --worktree "$FIX_WT" >/dev/null 2>&1
  )
  rc=$?
  expect_code 2 "$rc" "the xwvol shape must deny"
  log="$home/data/destructive-guard.log"
  assert_present "$log" "a denial must write the durable guard log"
  line=$(tail -n 1 "$log")
  printf '%s' "$line" | jq -e --arg wt "$FIX_WT" '
    .decision == "deny" and .code == "docker-bulk-rm" and .who == "task:log-task" and
    (.at | type == "number") and (.time | test("Z$")) and .cwd == $wt and
    (.command | contains("xargs docker volume rm")) and .ticket == ""' >/dev/null \
    || fail "the log line must record what, who, when, and where: $line"
  status="$home/state/log-task.status"
  assert_present "$status" "a worker denial must append to the worker's status stream"
  line=$(tail -n 1 "$status")
  case "$line" in
    "note [at="*"]: destructive-command guard denied [docker-bulk-rm]; the command did not run: docker volume ls"*) ;;
    *) fail "the status line must be a stamped note naming the code and command: $line" ;;
  esac
  (
    . "$ROOT/bin/fm-classify-lib.sh"
    status_line_is_unread_surface "$line"
  ) || fail "the note must reach the supervisor's unread-status surface"
  pass "a denial logs what/who/when/where and appends a stamped note the supervisor reads"
}

test_override_from_process_environment() {
  local home="$TMP_ROOT/override-home" log rc
  mkdir -p "$home/state"
  (
    cd "$FIX_WT" || exit 99
    unset FM_TASK_ID
    FM_DESTRUCTIVE_OK=CAPT-42 HOME="$FIX_HOME" "$CHECK" --command 'docker volume prune -f' \
      --state "$home/state" --task ov-task >/dev/null 2>&1
  )
  rc=$?
  expect_code 0 "$rc" "a valid ticket in the guard's own environment must allow"
  log="$home/data/destructive-guard.log"
  tail -n 1 "$log" | jq -e '.decision == "override" and .ticket == "CAPT-42" and .code == "docker-prune"' >/dev/null \
    || fail "an honored override must be logged with its ticket: $(tail -n 1 "$log")"
  assert_grep "override FM_DESTRUCTIVE_OK=CAPT-42 allowed [docker-prune]" "$home/state/ov-task.status" \
    "an honored override must also be noted for the supervisor"
  (
    cd "$FIX_WT" || exit 99
    FM_DESTRUCTIVE_OK='bad ticket;rm' HOME="$FIX_HOME" "$CHECK" --command 'docker volume prune -f' \
      --state "$home/state" --task ov-task >/dev/null 2>&1
  )
  rc=$?
  expect_code 2 "$rc" "a malformed ticket must grant nothing"
  (
    cd "$FIX_WT" || exit 99
    unset FM_DESTRUCTIVE_OK
    HOME="$FIX_HOME" "$CHECK" --command 'FM_DESTRUCTIVE_OK=CAPT-42 docker volume prune -f' \
      --state "$home/state" --task ov-task >/dev/null 2>&1
  )
  rc=$?
  expect_code 2 "$rc" "an assignment inside the command must grant nothing"
  pass "the override is honored only from the guard's own environment, logged, and never self-granted"
}

test_grant_validates_and_logs() {
  local home="$TMP_ROOT/grant-home" rc
  mkdir -p "$home/state"
  "$CHECK" --grant TKT-7 --state "$home/state" --task g-task
  expect_code 0 $? "a valid grant must succeed"
  tail -n 1 "$home/data/destructive-guard.log" | jq -e '.decision == "grant" and .ticket == "TKT-7" and .who == "task:g-task"' >/dev/null \
    || fail "a grant must be logged before the launch can use it"
  "$CHECK" --grant 'no spaces' --state "$home/state" --task g-task 2>/dev/null
  rc=$?
  expect_code 1 "$rc" "a malformed grant must refuse"
  pass "--grant validates the ticket shape and logs the grant"
}

# --- primary adapter scoping -------------------------------------------------

test_primary_stands_down_in_worker_panes() {
  local home="$TMP_ROOT/primary-home" rc
  mkdir -p "$home/state"
  (
    cd "$FIX_WT" || exit 99
    unset FM_DESTRUCTIVE_OK
    FM_TASK_ID=some-worker FM_HOME="$home" HOME="$FIX_HOME" "$CHECK" --primary --command 'docker volume prune -f' >/dev/null 2>&1
  )
  rc=$?
  expect_code 0 "$rc" "the tracked primary adapter must defer to the per-task adapter in a worker pane"
  assert_absent "$home/data/destructive-guard.log" "a stand-down must not log"
  (
    cd "$FIX_WT" || exit 99
    unset FM_DESTRUCTIVE_OK FM_TASK_ID
    FM_HOME="$home" HOME="$FIX_HOME" "$CHECK" --primary --command 'docker volume prune -f' >/dev/null 2>&1
  )
  rc=$?
  expect_code 2 "$rc" "the primary adapter must deny in a primary or mate pane"
  tail -n 1 "$home/data/destructive-guard.log" | jq -e '.who == "primary" and .decision == "deny"' >/dev/null \
    || fail "a primary denial must log to its own home"
  pass "the primary adapter stands down in worker panes and guards primary and mate panes"
}

test_secondmate_primary_reports_to_parent_channel() {
  local parent="$TMP_ROOT/sm-parent" mate="$TMP_ROOT/sm-mate" rc
  mkdir -p "$parent/state" "$mate/state"
  printf 'sm-dg\n' >"$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" >"$mate/.fm-secondmate-parent"
  (
    cd "$FIX_WT" || exit 99
    unset FM_DESTRUCTIVE_OK FM_TASK_ID
    FM_HOME="$mate" HOME="$FIX_HOME" "$CHECK" --primary --command 'docker system prune -af' >/dev/null 2>&1
  )
  rc=$?
  expect_code 2 "$rc" "a secondmate primary must be denied"
  assert_grep "destructive-command guard denied [docker-prune]" "$parent/state/sm-dg.status" \
    "a secondmate denial must reach its parent channel"
  pass "a secondmate's denial is reported on its parent channel"
}

# --- fail-open transport ----------------------------------------------------

test_fail_open_transport() {
  local out rc base
  out=$(run_check "" 2>&1)
  rc=$?
  expect_code 0 "$rc" "empty stdin must fail open"
  [ -z "$out" ] || fail "empty stdin must be silent: $out"
  out=$(run_check "not json" 2>&1)
  rc=$?
  expect_code 0 "$rc" "unparseable stdin must fail open"
  base=$(fm_test_base_path_sans "/usr/bin:/bin" node)
  out=$(cd "$FIX_WT" && HOME="$FIX_HOME" PATH="$base" "$CHECK" --command 'docker volume prune -f' 2>&1)
  rc=$?
  expect_code 0 "$rc" "a missing Node runtime must fail open"
  pass "malformed transport and a missing runtime fail open"
}

# --- per-task worker adapters installed by fm-spawn ---------------------------

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi claude opencode)
  # A fake omp that answers the catalog query and exits 0 for everything else.
  cat >"$fakebin/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  models) printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"}]}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/omp"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : >"$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# drive_tool_call <ext> <command>: load a Pi-family extension in a plain Node
# host and print the tool_call verdict for one bash command.
drive_tool_call() {
  EXT_PATH="$1" CMD="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
const pi = { on: (name, fn) => { handlers[name] = fn; }, events: { on() {} }, sendMessage() {}, sendUserMessage() {} };
mod.default(pi);
if (!handlers.tool_call) throw new Error("no tool_call handler registered");
const verdict = await handlers.tool_call({ type: "tool_call", toolName: "bash", input: { command: process.env.CMD } }, {});
process.stdout.write(JSON.stringify(verdict ?? {}));
EOF
}

test_pi_worker_adapter_denies_and_notes() {
  local rec id=dg-pi-1 out state ext
  rec=$(make_spawn_case pi-worker pi "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout)
  expect_code 0 $? "pi scout spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"
  out=$(cd "$WT_DIR" && unset FM_DESTRUCTIVE_OK && drive_tool_call "$ext" 'docker volume ls -q -f name=xwvol | xargs docker volume rm')
  printf '%s' "$out" | jq -e '.block == true and (.reason | contains("[docker-bulk-rm]"))' >/dev/null \
    || fail "the pi worker adapter must block the xwvol shape: $out"
  assert_grep "destructive-command guard denied [docker-bulk-rm]" "$state/$id.status" \
    "the pi worker denial must reach the task's status stream"
  assert_grep "\"who\":\"task:$id\"" "$HOME_DIR/data/destructive-guard.log" \
    "the pi worker denial must be logged in the parent home"
  out=$(cd "$WT_DIR" && drive_tool_call "$ext" "docker volume rm $id-db")
  printf '%s' "$out" | jq -e '.block != true' >/dev/null || fail "the pi worker adapter must allow its own named volume: $out"
  out=$(cd "$WT_DIR" && drive_tool_call "$ext" 'git clean -fdx')
  printf '%s' "$out" | jq -e '.block != true' >/dev/null || fail "git clean inside the spawned worktree must allow: $out"
  pass "fm-spawn's Pi worker adapter blocks the xwvol shape, notes the parent, and allows own resources"
}

test_omp_worker_adapter_denies() {
  local rec id=dg-omp-1 out state ext
  rec=$(make_spawn_case omp-worker omp "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --harness omp --model openai-codex/gpt-6-astra)
  expect_code 0 $? "omp scout spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"
  out=$(cd "$WT_DIR" && unset FM_DESTRUCTIVE_OK && drive_tool_call "$ext" 'rm -rf ~/.treehouse/*')
  printf '%s' "$out" | jq -e '.block == true and (.reason | contains("[rm-glob-protected]"))' >/dev/null \
    || fail "the omp worker adapter must block a treehouse sweep: $out"
  assert_grep "destructive-command guard denied [rm-glob-protected]" "$state/$id.status" \
    "the omp worker denial must reach the task's status stream"
  pass "fm-spawn's omp worker adapter blocks a destructive sweep and notes the parent"
}

test_opencode_worker_adapter_denies() {
  local rec id=dg-oc-1 out plugin
  rec=$(make_spawn_case opencode-worker opencode "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --harness opencode)
  expect_code 0 $? "opencode scout spawn should succeed: $out"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode spawn did not write the per-task plugin"
  out=$(cd "$WT_DIR" && unset FM_DESTRUCTIVE_OK && PLUGIN="$plugin" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmBusyState({});
const run = async (command) => {
  try {
    await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command } });
    return "allowed";
  } catch (error) {
    return `blocked:${error.message}`;
  }
};
process.stdout.write(`${await run("docker system prune -af")}\n${await run("ls -la")}\n`);
EOF
)
  case "$out" in
    "blocked:"*"[docker-prune]"*$'\n'allowed) ;;
    *) fail "the opencode worker plugin must block a prune and allow ls: $out" ;;
  esac
  assert_grep "destructive-command guard denied [docker-prune]" "$HOME_DIR/state/$id.status" \
    "the opencode worker denial must reach the task's status stream"
  pass "fm-spawn's OpenCode worker plugin blocks a prune by throwing and notes the parent"
}

# Every tracked primary adapter reaches the guard with --primary: it denies in
# a primary or mate pane and stands down in a worker pane. Each command string
# is read from its tracked config and executed, never matched as text.
run_adapter() {  # <dir> <task-id-or-empty> <cmd> <payload> [env...]
  local dir=$1 task=$2 command=$3 input=$4
  shift 4
  (
    cd "$dir" || exit 99
    unset FM_DESTRUCTIVE_OK FM_TASK_ID GROK_AGENT GROK_HOOK_EVENT
    [ -z "$task" ] || export FM_TASK_ID="$task"
    printf '%s' "$input" | env FM_HOME="$dir" HOME="$FIX_HOME" "$@" bash -c "$command"
  )
}

test_tracked_primary_adapters() {
  local dir="$TMP_ROOT/tracked-primary" cmd payload out rc
  mkdir -p "$dir/bin" "$dir/.codex" "$dir/state"
  : >"$dir/AGENTS.md"
  cp "$ROOT/.codex/hooks.json" "$dir/.codex/hooks.json"
  cp "$CHECK" "$POLICY" "$ROOT/bin/fm-arm-command-policy.mjs" "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/"
  payload=$(jq -cn '{tool_name:"Bash",tool_input:{command:"docker volume prune -f"}}')
  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("fm-destructive-pretool-check.sh"))' "$ROOT/.claude/settings.json")
  run_adapter "$dir" "" "$cmd" "$payload" CLAUDE_PROJECT_DIR="$dir" >/dev/null 2>&1
  expect_code 2 $? "the tracked Claude primary hook must deny"
  run_adapter "$dir" w1 "$cmd" "$payload" CLAUDE_PROJECT_DIR="$dir" >/dev/null 2>&1
  expect_code 0 $? "the tracked Claude primary hook must stand down in a worker pane"
  cmd=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(contains("fm-destructive-pretool-check.sh"))' "$ROOT/.codex/hooks.json")
  run_adapter "$dir" "" "$cmd" "$payload" >/dev/null 2>&1
  expect_code 2 $? "the tracked Codex primary hook must deny"
  cmd=$(jq -r '.hooks.PreToolUse[].hooks[].command' "$ROOT/.grok/hooks/fm-primary-destructive-check.json")
  out=$(run_adapter "$dir" "" "$cmd" "$(jq -cn '{toolName:"run_terminal_command",toolInput:{command:"docker volume prune -f"}}')" GROK_WORKSPACE_ROOT="$dir" 2>/dev/null)
  rc=$?
  expect_code 2 "$rc" "the tracked Grok primary hook must deny"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null || fail "the Grok hook must print its deny object: $out"
  cmd=$(jq -r '.hooks.preToolUse[] | .command | select(contains("fm-destructive-pretool-check.sh"))' "$ROOT/.cursor/hooks.json")
  out=$(run_adapter "$dir" "" "$cmd" "$(jq -cn '{cursor_version:"1.0",tool_name:"Shell",tool_input:{command:"docker volume prune -f"}}')" CURSOR_PROJECT_DIR="$dir" 2>/dev/null)
  printf '%s' "$out" | jq -e '.permission == "deny" and (.user_message | contains("[docker-prune]"))' >/dev/null \
    || fail "the tracked Cursor primary hook must return Cursor's deny object: $out"
  out=$(cd "$dir" && unset FM_DESTRUCTIVE_OK FM_TASK_ID && export FM_HOME="$dir" HOME="$FIX_HOME" &&
    PLUGIN="$ROOT/.opencode/plugins/fm-primary-destructive-check.js" ROOTDIR="$dir" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimaryDestructiveCheck({ worktree: process.env.ROOTDIR });
try {
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "docker volume prune -f" } });
  process.stdout.write("allowed");
} catch (error) {
  process.stdout.write(`blocked:${error.message}`);
}
EOF
)
  case "$out" in
    "blocked:"*"[docker-prune]"*) ;;
    *) fail "the tracked OpenCode primary plugin must block a prune: $out" ;;
  esac
  pass "tracked Claude, Codex, Grok, Cursor, and OpenCode primary adapters deny through the guard; Claude stands down in worker panes"
}

test_claude_worker_adapter_denies() {
  local rec id=dg-cl-1 out state settings cmd payload rc
  rec=$(make_spawn_case claude-worker claude "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout)
  expect_code 0 $? "claude scout spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$settings")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "the claude worker settings carry no Bash PreToolUse hook"
  payload=$(jq -cn '{tool_name:"Bash",tool_input:{command:"docker system prune -af --volumes"}}')
  out=$(cd "$WT_DIR" && printf '%s' "$payload" | env -u FM_DESTRUCTIVE_OK sh -c "$cmd" 2>"$CASE_DIR/claude.err")
  rc=$?
  expect_code 2 "$rc" "the claude worker hook must deny a prune"
  [ -z "$out" ] || fail "the claude worker hook must keep stdout empty on deny: $out"
  jq -e '.systemMessage | contains("[docker-prune]")' "$CASE_DIR/claude.err" >/dev/null \
    || fail "the claude worker hook must explain the denial on stderr: $(cat "$CASE_DIR/claude.err")"
  assert_grep "destructive-command guard denied [docker-prune]" "$state/$id.status" \
    "the claude worker denial must reach the task's status stream"
  pass "fm-spawn's Claude worker settings carry a Bash PreToolUse guard that denies and notes"
}

test_spawn_destructive_ok_grant() {
  local rec id=dg-grant-1 out rc
  rec=$(make_spawn_case grant pi "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --destructive-ok 'bad ticket')
  rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed --destructive-ok ticket must refuse the spawn"
  assert_contains "$out" "--destructive-ok needs a well-formed ticket" "the refusal must name the ticket problem"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --destructive-ok CAPT-9)
  expect_code 0 $? "a valid --destructive-ok spawn should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "export FM_DESTRUCTIVE_OK='CAPT-9';" "the grant must ride the launch environment"
  tail -n 1 "$HOME_DIR/data/destructive-guard.log" | jq -e --arg id "$id" '.decision == "grant" and .ticket == "CAPT-9" and .who == ("task:" + $id)' >/dev/null \
    || fail "the spawn must log the grant"
  pass "fm-spawn --destructive-ok refuses a malformed ticket and logs a valid per-launch grant"
}

# --- tracked Pi primary extension -------------------------------------------

test_pi_primary_extension_guards_mate_panes() {
  local project="$TMP_ROOT/pi-primary" out
  mkdir -p "$project/.pi/extensions/lib" "$project/bin" "$project/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$project/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$project/.pi/extensions/lib/"
  cp "$CHECK" "$POLICY" "$ROOT/bin/fm-arm-command-policy.mjs" "$ROOT/bin/fm-hook-host-lib.sh" "$project/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$project/bin/fm-cd-pretool-check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$project/bin/fm-arm-pretool-check.sh"
  chmod +x "$project/bin/"*.sh
  out=$(cd "$FIX_WT" && unset FM_DESTRUCTIVE_OK FM_TASK_ID && export FM_HOME="$project" HOME="$FIX_HOME" &&
    drive_tool_call "$project/.pi/extensions/fm-primary-turnend-guard.ts" 'docker volume prune -f')
  printf '%s' "$out" | jq -e '.block == true and (.reason | contains("[docker-prune]"))' >/dev/null \
    || fail "the Pi primary extension must block a prune in a primary or mate pane: $out"
  out=$(cd "$FIX_WT" && unset FM_DESTRUCTIVE_OK && export FM_TASK_ID=w1 FM_HOME="$project" HOME="$FIX_HOME" &&
    drive_tool_call "$project/.pi/extensions/fm-primary-turnend-guard.ts" 'docker volume prune -f')
  printf '%s' "$out" | jq -e '.block != true' >/dev/null \
    || fail "the Pi primary extension must stand down where a per-task adapter owns the pane: $out"
  pass "the tracked Pi primary extension guards primary and mate panes and defers in worker panes"
}

test_scripts_are_lint_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$CHECK" 2>&1) || fail "bin/fm-destructive-pretool-check.sh is not lint-clean: $out"
  node --check "$POLICY" || fail "the policy owner does not parse"
  pass "the transport is lint-clean and the policy parses"
}

test_full_acceptance_matrix
test_policy_reason_codes
test_denial_is_logged_and_noted
test_override_from_process_environment
test_grant_validates_and_logs
test_primary_stands_down_in_worker_panes
test_secondmate_primary_reports_to_parent_channel
test_fail_open_transport
test_pi_worker_adapter_denies_and_notes
test_omp_worker_adapter_denies
test_claude_worker_adapter_denies
test_opencode_worker_adapter_denies
test_tracked_primary_adapters
test_spawn_destructive_ok_grant
test_pi_primary_extension_guards_mate_panes
test_scripts_are_lint_clean
