#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031  # subshell-scoped env and literal command text are deliberate
# Behavior tests for bin/fm-run and bin/fm-created-check (docs/fm-run.md).
#
# Real behavior, no mocks of our own components: every case launches the real
# bin/fm-run, which runs the real shims against the real docker daemon, and the
# oracle is an independent query (docker inspect, docker ps, test -e) that never
# goes through fm-run's own ledger or lists. Docker objects are throwaway, named
# with a per-test task id unique to this process, built from an image that needs
# no pull (FROM scratch), and an EXIT trap removes anything a failed assertion
# left behind through fm-run's own recovery (exact names from its own ledgers,
# never a filter or a prune). Docker-less hosts still run the temp-dir cases.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fmrun-test)
FM_RUN="$ROOT/bin/fm-run"
FM_CHECK="$ROOT/bin/fm-created-check"
CHECK="$ROOT/bin/fm-destructive-pretool-check.sh"
export FM_HEAVY_HOSTNAME=${FM_HEAVY_HOSTNAME:-testhost}
export FM_RUN_ROOT="$TMP_ROOT/run-root"
export FM_RUN_TMPBASE="$TMP_ROOT/scratch-base"
mkdir -p "$FM_RUN_ROOT" "$FM_RUN_TMPBASE"

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && timeout 20 docker info >/dev/null 2>&1; then HAVE_DOCKER=1; fi

# eq <actual> <expected> <message>: reads in the order the cases are written.
eq() { assert_equals "$2" "$1" "$3"; }

SEQ=0
TASKS=()
TASK_ID=''
new_task() {  # sets TASK_ID: unique to this process and case (never call it in a subshell)
  SEQ=$((SEQ + 1))
  TASK_ID="fmrt$$x$SEQ"
  TASKS+=("$TASK_ID")
}

# Anything a failed case left behind is removed by fm-run's own recovery of the
# task's ledger: exact names the creator recorded, nothing else.
cleanup_leftovers() {
  local id
  for id in ${TASKS[@]+"${TASKS[@]}"}; do
    timeout 120 "$FM_RUN" "$id" -- true >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_leftovers EXIT

# A one-file image Dockerfile: builds without pulling, enough to `docker create`.
make_context() {  # <dir>
  mkdir -p "$1"
  printf 'hello\n' >"$1/f"
  printf 'FROM scratch\nCOPY f /f\n' >"$1/Dockerfile"
}

wait_for_file() {  # <file>
  local i
  for i in $(seq 1 300); do
    [ -e "$1" ] && return 0
    sleep 0.2
  done
  return 1
}

docker_has() {  # <kind> <name> -> independent oracle, never fm-run's ledger
  docker "$1" inspect --format x -- "$2" >/dev/null 2>&1
}

# --- cases ---------------------------------------------------------------------------

test_normal_run_prints_three_lists_and_leaves_nothing() {
  local task out rc dir_made
  new_task; task=$TASK_ID
  dir_made="$TMP_ROOT/dir-made-$task"
  out=$(timeout 120 "$FM_RUN" "$task" -- bash -c 'd=$(mktemp -d); echo "$d" >"'"$dir_made"'"; echo output-of-the-command' 2>&1)
  rc=$?
  eq "$rc" 0 "a clean run exits 0"
  assert_contains "$out" "output-of-the-command" "the command's own output passes through"
  assert_contains "$out" "CREATED (2):" "CREATED list prints with its count (the scratch root and the mktemp dir)"
  assert_contains "$out" "REMOVED (2):" "REMOVED list prints with its count"
  assert_contains "$out" "REMAINING (0):" "REMAINING list prints, empty"
  [ ! -e "$(cat "$dir_made")" ] || fail "the mktemp dir the command made is still on disk"
  assert_contains "$out" "$(cat "$dir_made")" "the exact recorded path is named in the lists"
  pass "a normal run prints CREATED / REMOVED / REMAINING and leaves no temp dir"
}

test_command_exit_status_passes_through() {
  local task rc
  new_task; task=$TASK_ID
  timeout 60 "$FM_RUN" "$task" -- bash -c 'exit 7' >/dev/null 2>&1
  rc=$?
  eq "$rc" 7 "fm-run exits with the command's own status when nothing remains"
  pass "the command's exit status passes through"
}

test_term_killed_run_leaves_nothing() {
  [ "$HAVE_DOCKER" -eq 1 ] || { pass "TERM-killed run (skip: no docker daemon)"; return; }
  local task ctx out pid ready scratch_dir
  new_task; task=$TASK_ID
  ctx="$TMP_ROOT/ctx-$task"
  make_context "$ctx"
  ready="$TMP_ROOT/ready-$task"
  out="$TMP_ROOT/out-$task"
  "$FM_RUN" "$task" -- bash -c '
    docker build -q -t "$FM_TASK_LABEL-img:1" "'"$ctx"'" >/dev/null || exit 1
    docker create --name "$FM_TASK_LABEL-c1" "$FM_TASK_LABEL-img:1" /f >/dev/null || exit 1
    docker volume create "$FM_TASK_LABEL-vol" >/dev/null || exit 1
    docker network create "$FM_TASK_LABEL-net" >/dev/null || exit 1
    mktemp -d >"'"$ready.dir"'" || exit 1
    : >"'"$ready"'"
    sleep 30' >"$out" 2>&1 &
  pid=$!
  wait_for_file "$ready" || { kill -TERM "$pid" 2>/dev/null; sleep 2; fail "the launched command never reached its sleep: $(cat "$out")"; }
  docker_has container "$task-c1" || fail "precondition: the container was never created"
  scratch_dir=$(cat "$ready.dir")
  kill -TERM "$pid"
  wait "$pid"
  eq "$?" 143 "a TERM-killed run exits 128+15"
  docker_has container "$task-c1" && fail "the container survived a TERM-killed run"
  docker_has volume "$task-vol" && fail "the volume survived a TERM-killed run"
  docker_has network "$task-net" && fail "the network survived a TERM-killed run"
  docker_has image "$task-img:1" && fail "the image tag survived a TERM-killed run"
  [ ! -e "$scratch_dir" ] || fail "the temp dir survived a TERM-killed run"
  assert_contains "$(cat "$out")" "REMAINING (0):" "the lists printed after the kill and nothing remains"
  pass "a TERM-killed run removes its container, volume, network, image, and temp dir"
}

test_hard_killed_run_is_cleaned_by_the_next_run_of_the_same_task() {
  [ "$HAVE_DOCKER" -eq 1 ] || { pass "hard-killed run (skip: no docker daemon)"; return; }
  local task other ctx out pid ready scratch_dir recovered other_vol
  new_task; task=$TASK_ID
  new_task; other=$TASK_ID
  ctx="$TMP_ROOT/ctx-$task"
  make_context "$ctx"
  ready="$TMP_ROOT/ready-$task"
  out="$TMP_ROOT/out-$task"
  # A second task's object must be untouched by the recovery of the first.
  other_vol="$other-bystander"
  docker volume create --label "fm.task=$other" "$other_vol" >/dev/null || fail "could not create the bystander volume"
  "$FM_RUN" "$task" -- bash -c '
    docker build -q -t "$FM_TASK_LABEL-img:1" "'"$ctx"'" >/dev/null || exit 1
    docker create --name "$FM_TASK_LABEL-c1" "$FM_TASK_LABEL-img:1" /f >/dev/null || exit 1
    docker volume create "$FM_TASK_LABEL-vol" >/dev/null || exit 1
    mktemp -d >"'"$ready.dir"'" || exit 1
    : >"'"$ready"'"
    sleep 20' >"$out" 2>&1 &
  pid=$!
  wait_for_file "$ready" || { kill -KILL "$pid" 2>/dev/null; fail "the launched command never reached its sleep: $(cat "$out")"; }
  scratch_dir=$(cat "$ready.dir")
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null
  docker_has container "$task-c1" || fail "precondition: the hard kill must leave the container behind"
  [ -e "$scratch_dir" ] || fail "precondition: the hard kill must leave the temp dir behind"
  # The closing check reads the ledger and names the exact leftovers without touching them.
  local check_out
  check_out=$("$FM_CHECK" "$task" 2>&1)
  eq "$?" 1 "the closing check fails while objects remain"
  assert_contains "$check_out" "container $task-c1" "the check names the exact container"
  assert_contains "$check_out" "volume $task-vol" "the check names the exact volume"
  assert_contains "$check_out" "$scratch_dir" "the check names the exact temp dir"
  assert_contains "$check_out" "fm-run $task -- true" "the check prints the one command that removes them"
  docker_has container "$task-c1" || fail "the read-only check removed something"
  # The next run of the same task id cleans first, by the prior ledger's exact names.
  recovered=$(timeout 180 "$FM_RUN" "$task" -- bash -c 'echo second-run-body' 2>&1)
  eq "$?" 0 "the next run succeeds once the prior leftovers are removed"
  assert_contains "$recovered" "recovered prior run" "the next run reports the recovery"
  assert_contains "$recovered" "container $task-c1" "the recovery names the exact container it removed"
  assert_contains "$recovered" "second-run-body" "the next run still runs its own command"
  docker_has container "$task-c1" && fail "the container survived recovery"
  docker_has volume "$task-vol" && fail "the volume survived recovery"
  docker_has image "$task-img:1" && fail "the image survived recovery"
  [ ! -e "$scratch_dir" ] || fail "the temp dir survived recovery"
  docker_has volume "$other_vol" || fail "recovery removed another task's volume"
  docker volume rm "$other_vol" >/dev/null 2>&1 || true
  assert_contains "$("$FM_CHECK" "$task" 2>&1)" "CLEAN" "the closing check reports CLEAN after recovery"
  pass "a hard-killed run is cleaned by the next run of the same task id, and only by its own ledger"
}

test_unlabelled_docker_object_cannot_be_created_through_the_shim() {
  [ "$HAVE_DOCKER" -eq 1 ] || { pass "labelled creates (skip: no docker daemon)"; return; }
  local task ctx out label_c label_v label_n label_i
  new_task; task=$TASK_ID
  ctx="$TMP_ROOT/ctx-$task"
  make_context "$ctx"
  out="$TMP_ROOT/out-$task"
  timeout 180 "$FM_RUN" "$task" -- bash -c '
    docker build -q -t "$FM_TASK_LABEL-img:1" "'"$ctx"'" >/dev/null || exit 1
    docker create --name "$FM_TASK_LABEL-c1" "$FM_TASK_LABEL-img:1" /f >/dev/null || exit 1
    docker volume create "$FM_TASK_LABEL-vol" >/dev/null || exit 1
    docker network create "$FM_TASK_LABEL-net" >/dev/null || exit 1
    for kind in container volume network image; do
      case $kind in container) n=c1 ;; volume) n=vol ;; network) n=net ;; image) n=img:1 ;; esac
      case $kind in
        container|image) f="{{index .Config.Labels \"fm.task\"}}" ;;
        *) f="{{index .Labels \"fm.task\"}}" ;;
      esac
      printf "%s=%s\n" "$kind" "$(docker $kind inspect --format "$f" "$FM_TASK_LABEL-$n")"
    done >"'"$out.labels"'"
    # a caller cannot relabel, and an unnamed create is named from the label
    docker create --label fm.task=someone-else "$FM_TASK_LABEL-img:1" /f; echo "relabel-rc=$?" >>"'"$out.labels"'"
    docker volume create --label fm.task=someone-else x; echo "relabel-volume-rc=$?" >>"'"$out.labels"'"
    docker create --name "$FM_TASK_LABEL-c2" -v "$FM_TASK_LABEL-implicit:/d" "$FM_TASK_LABEL-img:1" /f >/dev/null &&
      echo "implicit=$(docker volume inspect --format "{{index .Labels \"fm.task\"}}" "$FM_TASK_LABEL-implicit")" >>"'"$out.labels"'"
    id=$(docker create "$FM_TASK_LABEL-img:1" /f) && docker ps -a --filter "id=$id" --format "unnamed={{.Names}}" >>"'"$out.labels"'"
    ' >"$out" 2>&1
  label_c=$(sed -n 's/^container=//p' "$out.labels")
  label_v=$(sed -n 's/^volume=//p' "$out.labels")
  label_n=$(sed -n 's/^network=//p' "$out.labels")
  label_i=$(sed -n 's/^image=//p' "$out.labels")
  eq "$label_c" "$task" "the container carries the task label"
  eq "$label_v" "$task" "the volume carries the task label"
  eq "$label_n" "$task" "the network carries the task label"
  eq "$label_i" "$task" "the image carries the task label"
  assert_contains "$(cat "$out.labels")" "relabel-rc=126" "a caller-supplied fm.task label on a container is refused"
  assert_contains "$(cat "$out.labels")" "relabel-volume-rc=126" "a caller-supplied fm.task label on a volume is refused"
  assert_contains "$(cat "$out.labels")" "implicit=$task" "a volume a create makes implicitly (-v name:/path) is labelled too"
  assert_contains "$(cat "$out.labels")" "unnamed=$task-" "an unnamed create is named from the task label"
  docker_has volume x && fail "the refused relabelled volume was created anyway"
  assert_contains "$(cat "$out")" "REMAINING (0):" "everything created, including the unnamed container, was removed"
  # Outside any fm-run launch the shim refuses every create rather than let it through unlabelled.
  local bare bare_rc
  bare=$(env -u FM_RUN_LEDGER -u FM_TASK_LABEL -u FM_RUN_ID bash "$ROOT/bin/fm-run-shim.sh" docker volume create "$task-bare" 2>&1)
  bare_rc=$?
  eq "$bare_rc" 126 "the shim refuses a create outside an fm-run launch: $bare"
  docker_has volume "$task-bare" && fail "the shim created an unrecorded volume outside fm-run"
  pass "every create through the shim is labelled and recorded; relabelling and unrecorded creates are refused"
}

test_guard_allows_fm_run_removals_and_still_refuses_everything_else() {
  local task home parent wt run_dir
  new_task; task=$TASK_ID
  home="$TMP_ROOT/guard-home"
  parent="$TMP_ROOT/guard-parent"
  wt="$home/.treehouse/pool-x/3/proj"
  mkdir -p "$wt" "$parent/state"
  # The task's own ledger (the format bin/fm-run writes; the cases above prove fm-run writes it).
  run_dir="$FM_RUN_ROOT/$task/r1-1"
  mkdir -p "$run_dir"
  printf 'container\tpg-builder-test\tfm.task=%s\nvolume\tbuilder-data\tfm.task=%s\nproject\tbuilder-stack\t-\n' "$task" "$task" >"$run_dir/ledger"
  guard() {  # <command> -> allow | deny:<code>
    local text rc
    text=$(cd "$wt" && HOME="$home" FM_HOME="$parent" FM_RUN_ROOT="$FM_RUN_ROOT" "$CHECK" --state "$parent/state" --task "$task" --worktree "$wt" --command "$1" 2>&1 </dev/null)
    rc=$?
    case "$rc" in
      0) printf 'allow' ;;
      2) printf 'deny:%s' "$(printf '%s' "$text" | sed -n 's/.*\[\([a-z-]*\)\].*/\1/p' | head -n 1)" ;;
      *) printf 'rc=%s' "$rc" ;;
    esac
  }
  eq "$(guard "docker rm -f pg-builder-test")" allow "an exact name from this task's own fm-run ledger is removable"
  eq "$(guard "docker volume rm builder-data")" allow "a ledger volume is removable by exact name"
  eq "$(guard "docker compose -p builder-stack down")" allow "a ledger compose project is removable by exact name"
  eq "$(guard "docker rm -f $task-web")" allow "the existing task-label rule is unchanged"
  eq "$(guard "fm-run $task -- docker rm -f pg-builder-test")" allow "the wrapped command is judged as if run directly"
  # Everything else is still refused.
  eq "$(guard "docker rm -f somebody-elses-db")" deny:docker-rm-unowned "a name in nobody's ledger is refused"
  eq "$(guard "docker rm -f pg-builder-test somebody-elses-db")" deny:docker-rm-unowned "one foreign name among owned ones is refused"
  eq "$(guard 'docker ps -aq --filter name=pg-builder | xargs docker rm -f')" deny:docker-bulk-rm "a name pattern through xargs is refused"
  eq "$(guard 'docker rm -f $(docker ps -aq --filter label=fm.task)')" deny:docker-bulk-rm "a label filter in a command substitution is refused"
  eq "$(guard 'docker volume rm --filter label=fm.task=x')" deny:docker-bulk-rm "a label filter on the removal itself is refused"
  eq "$(guard 'docker rm -f pg-builder-*')" deny:docker-bulk-rm "a glob is refused even over a ledger prefix"
  eq "$(guard 'docker system prune -af')" deny:docker-prune "a prune is refused"
  eq "$(guard "fm-run $task -- docker volume prune -f")" deny:docker-prune "a prune hidden behind fm-run is refused"
  eq "$(guard "fm-run $task -- docker volume ls -q | xargs docker volume rm")" deny:docker-bulk-rm "an xargs removal hidden behind fm-run is refused"
  # Another task's ledger grants this task nothing.
  local other
  new_task; other=$TASK_ID
  mkdir -p "$FM_RUN_ROOT/$other/r1-1"
  printf 'container\tother-task-db\tfm.task=%s\n' "$other" >"$FM_RUN_ROOT/$other/r1-1/ledger"
  eq "$(guard "docker rm -f other-task-db")" deny:docker-rm-unowned "another task's ledger grants nothing"
  pass "the guard allows exact names from the task's own ledger and still refuses patterns, filters, xargs, prunes, and foreign names"
}

test_path_outside_the_scratch_root_is_refused() {
  local task run_dir scratch victim out rc outside_link
  new_task; task=$TASK_ID
  run_dir="$FM_RUN_ROOT/$task/r1-1"
  scratch="$FM_RUN_TMPBASE/fm-run-$task-r1-1"
  victim="$TMP_ROOT/victim-$task"
  outside_link="$scratch/escape"
  mkdir -p "$run_dir" "$scratch" "$victim/keep"
  : >"$victim/keep/file"
  ln -s "$victim" "$outside_link"
  mkdir -p "$scratch/inside"
  # A ledger that names: an unrelated dir, a dot-dot escape, a symlink-parent escape, and one legitimate path.
  printf 'dir\t%s\t-\ndir\t%s\t-\ndir\t%s\t-\ndir\t%s\t-\n' \
    "$victim" "$scratch/../victim-$task" "$outside_link/keep" "$scratch/inside" >"$run_dir/ledger"
  mkdir -p "$FM_RUN_TMPBASE/victim-$task"
  out=$(timeout 60 "$FM_RUN" "$task" -- bash -c 'echo body' 2>&1)
  rc=$?
  eq "$rc" 3 "a run whose settle leaves REMAINING exits nonzero even though its command succeeded"
  [ -e "$victim/keep/file" ] || fail "a path outside the scratch root was removed"
  [ -d "$victim" ] || fail "an unrelated directory named in a ledger was removed"
  [ -d "$FM_RUN_TMPBASE/victim-$task" ] || fail "a dot-dot path out of the scratch root was followed and removed"
  [ ! -e "$scratch/inside" ] || fail "the legitimate path inside the scratch root was not removed"
  assert_contains "$out" "REMAINING (3):" "the three refused paths are REMAINING"
  assert_contains "$out" "outside this run's scratch root" "the refusal names its reason"
  assert_contains "$out" "$victim" "the refused path is named exactly"
  pass "a path outside the run's own scratch root is refused, by name, dot-dot, and symlink parent"
}

test_created_check_reports_clean_remaining_and_no_ledger() {
  local task out
  new_task; task=$TASK_ID
  out=$("$FM_CHECK" "$task" 2>&1)
  eq "$?" 2 "no ledger is flagged, not passed"
  assert_contains "$out" "NO-LEDGER" "the check says nothing was launched through fm-run"
  assert_contains "$out" "not covered" "and that direct creation outside fm-run is not covered"
  timeout 60 "$FM_RUN" "$task" -- bash -c 'mktemp -d >/dev/null' >/dev/null 2>&1
  out=$("$FM_CHECK" "$task" 2>&1)
  eq "$?" 0 "a settled ledger is CLEAN"
  assert_contains "$out" "CLEAN" "CLEAN prints"
  # A recorded path that still exists is reported with the one command per host.
  local run_dir="$FM_RUN_ROOT/$task/r1-1" scratch="$FM_RUN_TMPBASE/fm-run-$task-r1-1"
  mkdir -p "$run_dir" "$scratch/left"
  printf 'dir\t%s\t-\n' "$scratch/left" >"$run_dir/ledger"
  out=$("$FM_CHECK" "$task" 2>&1)
  eq "$?" 1 "a remaining path fails the check"
  assert_contains "$out" "$scratch/left" "the exact remaining path is named"
  assert_contains "$out" "$(uname -n)" "the host is named"
  assert_contains "$out" "bin/fm-run $task -- true" "the one command is printed"
  [ -d "$scratch/left" ] || fail "the closing check is read-only but removed a path"
  pass "the closing check prints CLEAN, the exact remaining names with the one command, or flags a missing ledger"
}

test_mktemp_shim_records_common_forms() {
  local task out
  new_task; task=$TASK_ID
  out=$(timeout 60 "$FM_RUN" "$task" -- bash -c '
    mktemp -d >/dev/null; mktemp >/dev/null; mktemp -d /tmp/fmrt.XXXXXX >/dev/null; mktemp -d -t fmrt2.XXXXXX >/dev/null
    mktemp -u >/dev/null
    echo "tmpdir=$TMPDIR"' 2>&1)
  eq "$?" 0 "the mktemp forms run clean"
  assert_contains "$out" "CREATED (5):" "four mktemp paths and the scratch root are recorded (a dry-run -u is not)"
  assert_contains "$out" "REMAINING (0):" "all are removed"
  assert_contains "$out" "tmpdir=$FM_RUN_TMPBASE/fm-run-$task-" "TMPDIR points at the run's scratch root"
  pass "the mktemp shim records every temp path it makes, including /tmp templates relocated into the scratch root"
}

test_scratch_defaults_to_short_disk_path_and_refuses_a_full_disk() {
  local task out rc home="$TMP_ROOT/home"
  mkdir -p "$home"
  new_task; task=$TASK_ID
  out=$(HOME="$home" env -u FM_RUN_TMPBASE timeout 60 "$FM_RUN" "$task" -- bash -c 'echo "tmpdir=$TMPDIR"' 2>&1)
  eq "$?" 0 "a default-base run succeeds"
  assert_contains "$out" "tmpdir=$home/.t/fm-run-$task-" "the default scratch base is ~/.t"
  eq "$(stat -c %a "$home/.t")" 700 "the default base is mode 700"
  new_task; task=$TASK_ID
  out=$(FM_RUN_MAX_USED_PCT=0 timeout 60 "$FM_RUN" "$task" -- true 2>&1); rc=$?
  eq "$rc" 75 "a nearly full scratch filesystem refuses the run with exit 75"
  assert_contains "$out" "fm-run: refusing to start" "one plain line names the refusal"
  pass "scratch defaults to ~/.t and a run refuses to start when that disk is over the limit"
}

test_compose_project_objects_are_recorded_and_removed() {
  [ "$HAVE_DOCKER" -eq 1 ] || { pass "compose (skip: no docker daemon)"; return; }
  docker compose version >/dev/null 2>&1 || { pass "compose (skip: no docker compose)"; return; }
  local task ctx out
  new_task; task=$TASK_ID
  ctx="$TMP_ROOT/ctx-$task"
  make_context "$ctx"
  printf 'services:\n  web:\n    build: .\n    command: ["/f"]\n    volumes: ["data:/d"]\nvolumes:\n  data: {}\n' >"$ctx/compose.yaml"
  out=$(cd "$ctx" && timeout 240 "$FM_RUN" "$task" -- bash -c 'docker compose up --no-start >/dev/null 2>&1; docker compose ps -a --format "{{.Name}}"' 2>&1)
  eq "$?" 0 "the compose run exits clean"
  assert_contains "$out" "container $task-" "the compose container is recorded under the task's prefix"
  assert_contains "$out" "network $task-" "the compose network is recorded"
  assert_contains "$out" "volume $task-" "the compose volume is recorded"
  assert_contains "$out" "REMAINING (0):" "the compose objects are removed"
  [ -z "$(docker ps -aq --filter "name=$task-")" ] || fail "a compose container survived"
  [ -z "$(docker volume ls -q --filter "name=$task-")" ] || fail "a compose volume survived"
  [ -z "$(docker network ls -q --filter "name=$task-")" ] || fail "a compose network survived"
  pass "a compose project's containers, network, volume, and built image are recorded and removed"
}

test_listed_host_is_refused_and_override_only_adds() {
  local out rc home="$TMP_ROOT/heavy-home"
  mkdir -p "$home/config"
  out=$(FM_HEAVY_HOSTNAME=roger "$FM_RUN" heavyguard -- true 2>&1); rc=$?
  eq "$rc" 75 "a listed host exits 75"
  eq "$out" "roger is the captain's desktop: heavy work runs on x, chef, et or mcfeely" "the refusal is the single named line"
  out=$(FM_HEAVY_HOSTNAME=x "$FM_RUN" heavyguard -- true 2>&1); rc=$?
  eq "$rc" 0 "an unlisted host runs"
  printf '# add\nnewbox  # c\n' >"$home/config/no-heavy-hosts"
  out=$(FM_HOME="$home" FM_HEAVY_HOSTNAME=newbox "$FM_RUN" heavyguard -- true 2>&1); rc=$?
  eq "$rc" 75 "a host added by the home override is refused"
  : >"$home/config/no-heavy-hosts"
  out=$(FM_HOME="$home" FM_HEAVY_HOSTNAME=prince "$FM_RUN" heavyguard -- true 2>&1); rc=$?
  eq "$rc" 75 "an empty override cannot remove a tracked default host"
  out=$(FM_HEAVY_HOSTNAME=king "$ROOT/bin/fm-test-run.sh" --all 2>&1); rc=$?
  eq "$rc" 75 "the test runner shares the guard"
  pass "no-heavy-hosts refuses listed hosts; overrides only add"
}

test_scripts_are_lint_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-run-lib.sh" "$ROOT/bin/fm-run-shim.sh" "$FM_RUN" "$FM_CHECK" 2>&1) || fail "fm-run scripts are not lint-clean: $out"
  pass "the fm-run scripts are lint-clean"
}

fm_test_run \
  test_normal_run_prints_three_lists_and_leaves_nothing \
  test_command_exit_status_passes_through \
  test_term_killed_run_leaves_nothing \
  test_hard_killed_run_is_cleaned_by_the_next_run_of_the_same_task \
  test_unlabelled_docker_object_cannot_be_created_through_the_shim \
  test_guard_allows_fm_run_removals_and_still_refuses_everything_else \
  test_path_outside_the_scratch_root_is_refused \
  test_created_check_reports_clean_remaining_and_no_ledger \
  test_mktemp_shim_records_common_forms \
  test_scratch_defaults_to_short_disk_path_and_refuses_a_full_disk \
  test_compose_project_objects_are_recorded_and_removed \
  test_listed_host_is_refused_and_override_only_adds \
  test_scripts_are_lint_clean
