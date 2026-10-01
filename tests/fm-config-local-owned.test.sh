#!/usr/bin/env bash
# Behavior tests for the per-home inheritance opt-out: an inheritable config item
# the DESTINATION home lists in its config/local-owned marker is skipped entirely
# by every inheritance path (library push, spawn/relaunch, fm-config-push.sh, and
# the remote receiver), while every unlisted item keeps inheriting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-config-local-owned)

fm_git_identity fmtest fmtest@example.invalid

new_home_pair() {
  local name=$1 base
  base="$TMP_ROOT/$name"
  mkdir -p "$base/primary/config" "$base/primary/data" "$base/second/config" "$base/second/data"
  printf '%s\n' "$base"
}

test_library_push_skips_local_owned_and_inherits_the_rest() {
  local base primary second report
  base=$(new_home_pair library)
  primary="$base/primary"
  second="$base/second"
  report="$base/report"
  printf '%s\n' '{"primary":true}' > "$primary/config/crew-dispatch.json"
  printf '%s\n' 'codex' > "$primary/config/crew-harness"
  printf '%s\n' '{"local":true}' > "$second/config/crew-dispatch.json"
  # Inert lines (comment, blank, traversal, unknown item) around the one real entry.
  printf '%s\n' '# my own dispatch' '' '../data/captain.md' 'not-an-item' 'crew-dispatch.json' > "$second/config/local-owned"
  cp "$second/config/local-owned" "$base/marker.before"

  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary/config" "$second/config" 2>/dev/null \
    || fail "propagation should succeed with a local-owned item"

  assert_equals '{"local":true}' "$(cat "$second/config/crew-dispatch.json")" \
    "local-owned crew-dispatch.json must survive a push"
  assert_equals codex "$(cat "$second/config/crew-harness")" "an unlisted item must still inherit"
  cmp -s "$base/marker.before" "$second/config/local-owned" || fail "the marker must never be rewritten"
  assert_grep "$(printf 'crew-dispatch.json\tskipped\tlocal-owned')" "$report" \
    "the skip must be reported as skipped: local-owned"
  assert_grep "$(printf 'crew-harness\tpushed\t')" "$report" "the unlisted item must report pushed"

  # Absence is not mirrored for a local-owned item, but is for an unlisted one.
  rm -f "$primary/config/crew-dispatch.json" "$primary/config/crew-harness"
  propagate_inheritable_config "$primary/config" "$second/config" 2>/dev/null \
    || fail "absence propagation should succeed"
  assert_equals '{"local":true}' "$(cat "$second/config/crew-dispatch.json")" \
    "a local-owned item must not be deleted when the primary has no value"
  assert_absent "$second/config/crew-harness" "an unlisted item must still mirror primary absence"
  cmp -s "$base/marker.before" "$second/config/local-owned" || fail "absence mirroring must never delete the marker"

  # Dropping the line returns the item to primary-authoritative inheritance.
  printf '%s\n' '{"primary":true}' > "$primary/config/crew-dispatch.json"
  : > "$second/config/local-owned"
  propagate_inheritable_config "$primary/config" "$second/config" 2>/dev/null || fail "push after opt-out removal failed"
  assert_equals '{"primary":true}' "$(cat "$second/config/crew-dispatch.json")" \
    "an item removed from the marker must inherit again"
  pass "library push skips a local-owned item (present and absent primary), reports it, and inherits the rest"
}

test_symlinked_marker_is_ignored() {
  local base primary second
  base=$(new_home_pair symlink-marker)
  primary="$base/primary"
  second="$base/second"
  printf '%s\n' primary > "$primary/config/crew-dispatch.json"
  printf '%s\n' local > "$second/config/crew-dispatch.json"
  printf '%s\n' 'crew-dispatch.json' > "$base/elsewhere"
  ln -s "$base/elsewhere" "$second/config/local-owned"
  propagate_inheritable_config "$primary/config" "$second/config" 2>/dev/null || fail "push failed"
  assert_equals primary "$(cat "$second/config/crew-dispatch.json")" "a symlinked marker must not be honored"
  pass "a non-regular marker is ignored"
}

new_git_world() {
  local name=$1 w root home c1
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  printf '%s\n' '.fm-secondmate-home' 'data/' 'state/' 'config/' 'projects/' > "$root/.gitignore"
  printf '%s\n' "instructions" > "$root/AGENTS.md"
  mkdir -p "$root/bin"
  printf '%s\n' "echo spawn" > "$root/bin/fm-spawn.sh"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$w/sm" "$c1"
  printf '%s\n' sm > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data" "$w/sm/state" "$w/sm/config" "$w/sm/projects"
  printf '%s\n' "charter" > "$w/sm/data/charter.md"
  printf '%s|%s|%s|%s\n' "$w" "$root" "$home" "$w/sm"
}

seed_world_config() {
  local home=$1 sm=$2
  printf '%s\n' '{"primary":true}' > "$home/config/crew-dispatch.json"
  printf '%s\n' 'codex' > "$home/config/crew-harness"
  printf '%s\n' '{"local":true}' > "$sm/config/crew-dispatch.json"
  printf '%s\n' 'crew-dispatch.json' > "$sm/config/local-owned"
}

test_spawn_and_relaunch_keep_local_owned_file() {
  local rec w root home sm fakebin round
  rec=$(new_git_world spawn)
  IFS='|' read -r w root home sm <<REC
$rec
REC
  seed_world_config "$home" "$sm"
  fakebin="$w/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  # Two launches: the first spawn and a relaunch of the same home.
  for round in first relaunch; do
    PATH="$fakebin:$BASE_PATH" TMUX='' \
      FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" sm "$sm" codex --secondmate >/dev/null 2>&1 || true
    assert_equals '{"local":true}' "$(cat "$sm/config/crew-dispatch.json")" \
      "local-owned crew-dispatch.json must survive the $round launch"
    assert_equals codex "$(cat "$sm/config/crew-harness")" "unlisted crew-harness must inherit on the $round launch"
  done
  assert_equals 'crew-dispatch.json' "$(cat "$sm/config/local-owned")" "launch must leave the marker alone"
  pass "spawn and relaunch keep a local-owned crew-dispatch.json while inheriting other items"
}

test_config_push_keeps_local_owned_file() {
  local rec w root home sm out
  rec=$(new_git_world config-push)
  IFS='|' read -r w root home sm <<REC
$rec
REC
  seed_world_config "$home" "$sm"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-config-push.sh" 2>/dev/null)

  assert_contains "$out" "crew-dispatch.json: skipped - local-owned" "config-push should report the local-owned skip"
  assert_contains "$out" "crew-harness: pushed" "config-push should still push an unlisted item"
  assert_equals '{"local":true}' "$(cat "$sm/config/crew-dispatch.json")" \
    "config-push must not overwrite a local-owned file"
  assert_equals codex "$(cat "$sm/config/crew-harness")" "config-push must inherit the unlisted item"
  pass "fm-config-push skips a local-owned item and reports it"
}

remote_apply() {
  local home=$1 command=$2 rel=$3 payload=$4 generation=$5 bytes hash
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash remote payload"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
    "$command" "$rel" "$bytes" "$hash" "$generation" < "$payload" 2>&1
}

test_remote_receiver_skips_local_owned_item() {
  local base home payload empty out
  base="$TMP_ROOT/remote"
  home="$base/home"
  payload="$base/payload"
  empty="$base/empty"
  mkdir -p "$home/config" "$home/data"
  printf '%s\n' '{"primary":true}' > "$payload"
  : > "$empty"
  printf '%s\n' '{"local":true}' > "$home/config/crew-dispatch.json"
  printf '%s\n' 'crew-dispatch.json' > "$home/config/local-owned"

  out=$(remote_apply "$home" put config/crew-dispatch.json "$payload" 1) || fail "remote put failed: $out"
  assert_contains "$out" "skipped: config/crew-dispatch.json (local-owned)" "remote put should report the skip"
  assert_equals '{"local":true}' "$(cat "$home/config/crew-dispatch.json")" "remote put must not overwrite a local-owned file"
  assert_absent "$home/config/.fm-inherit-crew-dispatch.json.generation" "a skipped item must record no generation receipt"

  out=$(remote_apply "$home" absent config/crew-dispatch.json "$empty" 2) || fail "remote absent failed: $out"
  assert_contains "$out" "skipped: config/crew-dispatch.json (local-owned)" "remote absent should report the skip"
  assert_equals '{"local":true}' "$(cat "$home/config/crew-dispatch.json")" "remote absence must not delete a local-owned file"
  assert_absent "$home/config/.fm-inherit-crew-dispatch.json.generation" "a skipped absence must record no generation receipt"

  out=$(remote_apply "$home" put config/crew-harness "$payload" 3) || fail "remote put of unlisted item failed: $out"
  assert_contains "$out" "pushed: config/crew-harness" "an unlisted remote item must still inherit"

  if out=$(remote_apply "$home" absent config/local-owned "$empty" 4); then
    fail "the marker itself must not be an inheritable path"
  fi
  assert_contains "$out" "path is not inherited material" "the marker must be refused as inherited material"
  assert_equals 'crew-dispatch.json' "$(cat "$home/config/local-owned")" "the marker must survive every remote operation"
  pass "remote receiver skips local-owned items without receipts and never touches the marker"
}

test_library_push_skips_local_owned_and_inherits_the_rest
test_symlinked_marker_is_ignored
test_spawn_and_relaunch_keep_local_owned_file
test_config_push_keeps_local_owned_file
test_remote_receiver_skips_local_owned_item

echo "# all fm-config-local-owned tests passed"
