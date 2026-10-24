#!/usr/bin/env bash
# Behavior tests for bin/fm-ceilings.sh: no declared ceilings never block; a
# value at or above its ceiling is reported and exits 1; an unmeasurable value
# is not a breach; empty numbered pool directories do not count as slots.
# df and docker are PATH stubs reporting fixed numbers.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CEIL="$ROOT/bin/fm-ceilings.sh"
TMP_ROOT=$(fm_test_tmproot fm-ceilings)

make_world() {  # <name> -> prints dir; df says 79% used and 7 GB /tmp
  local w="$TMP_ROOT/$1" fb
  mkdir -p "$w"
  fb=$(fm_fakebin "$w")
  cat > "$fb/df" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -Pm "*) printf 'Filesystem 1M-blocks Used Available Capacity Mounted\ntmpfs 32768 %s 100 20%% /tmp\n' "${FM_FAKE_TMP_MB:-7168}" ;;
  *) printf 'Filesystem 1K-blocks Used Available Capacity Mounted\n/dev/x 1000 790 210 %s%% /\n' "${FM_FAKE_DISK_PCT:-79}" ;;
esac
SH
  cat > "$fb/docker" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "ps -aq") seq 1 "${FM_FAKE_CONTAINERS:-10}" ;;
  "ps -q") seq 1 "${FM_FAKE_RUNNING:-2}" ;;
  "volume ls -q") seq 1 "${FM_FAKE_VOLUMES:-50}" ;;
  images*) seq 1 "${FM_FAKE_IMAGES:-30}" ;;
esac
SH
  chmod +x "$fb/df" "$fb/docker"
  printf '%s\n' "$w"
}

run() {  # <world> [args]  (env passes through)
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" FM_CEILINGS_FILE="$w/ceilings.env" "$CEIL" "$@" 2>&1
}

test_no_file_never_blocks() {
  local w out
  w=$(make_world nofile)
  out=$(run "$w" check); assert_equals 0 "$?" "no ceilings file never blocks"
  assert_equals "" "$out" "and prints nothing"
  pass "an absent ceilings file sets no ceiling"
}

test_within_ceilings_passes() {
  local w
  w=$(make_world within)
  printf 'DISK_PCT=80\nCONTAINERS=60\nVOLUMES=100\nIMAGE_TAGS=150\nTMP_GB=8\n' > "$w/ceilings.env"
  run "$w" check >/dev/null || fail "values below every ceiling must pass"
  pass "values below their ceilings pass"
}

test_breaches_are_named_at_or_above_ceiling() {
  local w out rc
  w=$(make_world over)
  printf '# host ceilings\nDISK_PCT=80\nCONTAINERS=10\nVOLUMES=100\nTMP_GB=8\nCONTAINERS_RUNNING=junk\n' > "$w/ceilings.env"
  out=$(FM_FAKE_DISK_PCT=83 run "$w" check); rc=$?
  assert_equals 1 "$rc" "a breach exits 1"
  assert_contains "$out" "over: DISK_PCT 83 >= 80" "disk over"
  assert_contains "$out" "over: CONTAINERS 10 >= 10" "a value AT its ceiling is over"
  assert_not_contains "$out" "VOLUMES" "volumes within ceiling are not named"
  assert_not_contains "$out" "TMP_GB" "tmp within ceiling not named"
  pass "each breach is named and a value at its ceiling is over"
}

test_unmeasurable_is_not_a_breach() {
  local w
  w=$(make_world nodocker)
  printf 'CONTAINERS=1\nVOLUMES=1\n' > "$w/ceilings.env"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$w/fakebin/docker"
  run "$w" check >/dev/null \
    || fail "a docker that cannot answer is unmeasurable, so its ceilings cannot be breached"
  pass "an unmeasurable value is never a breach"
}

test_pool_slots_ignore_empty_dirs() {
  local w pool out
  w=$(make_world pool)
  fm_git_init_commit "$w/project"
  pool="$w/root/pool"
  mkdir -p "$pool/1" "$pool/2" "$pool/3" "$pool/4"
  : > "$pool/treehouse-state.json"
  git -C "$w/project" worktree add --quiet --detach "$pool/1/project"
  git -C "$w/project" worktree add --quiet --detach "$pool/2/project"
  printf 'POOL_SLOTS=3\n' > "$w/ceilings.env"
  TREEHOUSE_ROOT="$w/root" run "$w" check --project "$w/project" >/dev/null \
    || fail "two populated slots plus two empty dirs is under a ceiling of 3"
  git -C "$w/project" worktree add --quiet --detach "$pool/3/project"
  out=$(TREEHOUSE_ROOT="$w/root" run "$w" check --project "$w/project")
  assert_contains "$out" "over: POOL_SLOTS 3 >= 3" "three populated slots reach the ceiling"
  pass "empty numbered pool directories do not count against the slot ceiling"
}

test_no_file_never_blocks
test_within_ceilings_passes
test_breaches_are_named_at_or_above_ceiling
test_unmeasurable_is_not_a_breach
test_pool_slots_ignore_empty_dirs
