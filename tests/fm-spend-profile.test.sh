#!/usr/bin/env bash
# Behavior tests for spend profiles (spend_profiles and project_profiles in
# config/crew-dispatch.json; bin/fm-spend-profile-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane. The
# fake pi answers `pi auth check` from the selected store's signed-in file and
# records the store and arguments a launched worker receives, so a test can
# prove which key store a project's worker would spend. No case touches a
# network or a real key; a store is a directory name.
#
# Relaunch and bootstrap coverage lives in tests/fm-control-relaunch.test.sh and
# tests/fm-bootstrap.test.sh; the resolver's per-profile request in
# tests/fm-dispatch-resolve.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spend-profile)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY

CHEAP=openrouter/deepseek/deepseek-v4.1-flash
OPUS=openrouter/anthropic/claude-opus-5.5
SONNET=openrouter/anthropic/claude-sonnet-5.5

# make_pi_fake <fakebin> <case-dir>
# `pi auth check` is ready when the selected store lists the provider in its
# signed-in file; a worker launch records the store and arguments it received.
make_pi_fake() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" >> '$dir/pi-checks'
    if grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"api_key"}\n' "\$provider"
      exit 0
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"
    exit 1
    ;;
esac
{
  printf 'PI_CODING_AGENT_DIR=%s\n' "\${PI_CODING_AGENT_DIR-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
SH
  chmod +x "$fakebin/pi"
}

# write_dispatch <config-dir> <work-root> <personal-root>
# A day-one-shaped file: work spends the full model range, personal only the
# cheap model; both are mapped by project name.
write_dispatch() {
  local config=$1 work=$2 personal=$3
  cat > "$config/crew-dispatch.json" <<JSON
{
  "spend_profiles": {
    "work": {
      "doppler": "fleet/dev_work",
      "pi_account": { "root": "$work", "providers": ["openrouter"] },
      "rules": [
        { "when": "Hard or ambiguous work.", "use": { "harness": "pi", "model": "$OPUS", "effort": "high" } },
        { "when": "A trivial mechanical edit.", "use": { "harness": "pi", "model": "$CHEAP", "effort": "low" } }
      ],
      "default": { "harness": "pi", "model": "$SONNET", "effort": "medium" }
    },
    "personal": {
      "doppler": "fleet/dev_personal",
      "pi_account": { "root": "$personal", "providers": ["openrouter"] },
      "rules": [
        { "when": "Hard or ambiguous work.", "use": { "harness": "pi", "model": "$CHEAP", "effort": "high" } }
      ],
      "default": { "harness": "pi", "model": "$CHEAP", "effort": "medium" }
    }
  },
  "project_profiles": { "spire": "work", "cappz-core": "personal" },
  "rules": [],
  "default": { "harness": "pi", "model": "$SONNET" }
}
JSON
}

# new_case <name> <project-dir-name> -> sets CASE HOME_DIR PROJ WT FAKEBIN
# The project is the clone directory name, which is its spend profile identity.
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/$2"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_pi_fake "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home" "$CASE/pi-work" "$CASE/pi-personal"
  printf 'openrouter\n' > "$CASE/pi-work/signed-in"
  printf 'openrouter\n' > "$CASE/pi-personal/signed-in"
  : > "$CASE/launch.log"
}

# spawn_ship <id> [fm-spawn args...]
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_legacy_file_keeps_the_launch_and_record_unchanged() {
  local out rc legacy_launch legacy_keys
  new_case legacy spire
  cat > "$HOME_DIR/config/crew-dispatch.json" <<JSON
{ "rules": [], "default": { "harness": "pi", "model": "$SONNET" } }
JSON
  out=$(spawn_ship legacy-1 --harness pi --model "$SONNET"); rc=$?
  expect_code 0 "$rc" "a legacy dispatch file should launch exactly as before: $out"
  assert_not_contains "$out" "profile=" "a legacy spawn must not report a profile"
  assert_no_grep "profile=" "$HOME_DIR/state/legacy-1.meta" "a legacy record must carry no profile"
  assert_no_grep "captain_override=" "$HOME_DIR/state/legacy-1.meta" "a legacy record must carry no override"
  assert_no_grep "account=" "$HOME_DIR/state/legacy-1.meta" "a legacy record must carry no account"
  legacy_launch=$(sed 's/legacy-[12]/ID/g' "$CASE/launch.log")
  legacy_keys=$(cut -d= -f1 "$HOME_DIR/state/legacy-1.meta" | sort | tr '\n' ' ')

  # The same spawn with no dispatch file at all is the baseline: the legacy
  # file must change nothing but the harness requirement it already imposed.
  rm "$HOME_DIR/config/crew-dispatch.json"
  out=$(spawn_ship legacy-2 --harness pi --model "$SONNET"); rc=$?
  expect_code 0 "$rc" "the baseline spawn should succeed: $out"
  [ "$(sed 's/legacy-[12]/ID/g' "$CASE/launch.log")" = "$legacy_launch" ] || fail "a legacy dispatch file changed the launch command"
  [ "$(cut -d= -f1 "$HOME_DIR/state/legacy-2.meta" | sort | tr '\n' ' ')" = "$legacy_keys" ] \
    || fail "a legacy dispatch file changed the task record keys"
  assert_not_contains "$legacy_launch" "PI_CODING_AGENT_DIR" "a legacy launch must not select a store"
  pass "a dispatch file without spend_profiles launches and records exactly as before"
}

test_profile_selects_the_store_and_rules_by_project() {
  local out rc
  new_case select cappz-core
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  out=$(spawn_ship sp-cappz --harness pi --model "$CHEAP"); rc=$?
  expect_code 0 "$rc" "a CAPPZ task on a cheap model should launch: $out"
  assert_contains "$out" "profile=personal" "the spawn should report the personal profile"
  assert_contains "$out" "account=$CASE/pi-personal account_provider=openrouter" "the spawn should report the personal store"
  assert_grep "profile=personal" "$HOME_DIR/state/sp-cappz.meta" "the task record should carry the profile"
  assert_grep "account=$CASE/pi-personal" "$HOME_DIR/state/sp-cappz.meta" "the task record should carry the personal store"
  assert_no_grep "captain_override=" "$HOME_DIR/state/sp-cappz.meta" "no override was given"
  [ "$(cat "$CASE/pi-checks")" = "$CASE/pi-personal openrouter" ] \
    || fail "the sign-in check should ask only the personal store: $(cat "$CASE/pi-checks")"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-personal" "$CASE/pi-worker" "the CAPPZ worker should run on the personal store"

  new_case select-spire spire
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  out=$(spawn_ship sp-spire --harness pi --model "$OPUS"); rc=$?
  expect_code 0 "$rc" "a work task on Opus should launch: $out"
  assert_contains "$out" "profile=work" "the spawn should report the work profile"
  assert_grep "profile=work" "$HOME_DIR/state/sp-spire.meta" "the task record should carry the work profile"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the work worker should run on the work store"
  pass "a CAPPZ project resolves to the personal store and a Spire project to the work store"
}

test_a_model_outside_the_profile_is_refused() {
  local out rc
  new_case opus cappz-core
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  out=$(spawn_ship sp-opus --harness pi --model "$OPUS"); rc=$?
  expect_code 1 "$rc" "Opus under the personal profile must refuse"
  assert_refused_before_launch sp-opus "$out" "spend profile 'personal' does not allow harness 'pi' with model '$OPUS'"
  out=$(spawn_ship sp-sonnet --harness pi --model "$SONNET"); rc=$?
  expect_code 1 "$rc" "Sonnet under the personal profile must refuse"
  assert_refused_before_launch sp-sonnet "$out" "does not allow"
  pass "a CAPPZ task asking for Opus or Sonnet on the personal profile is refused before launch"
}

test_a_cappz_task_on_the_work_key_is_refused() {
  local out rc
  new_case workkey cappz-core
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  printf '%s\nopenrouter\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship sp-workkey --harness pi --model "$CHEAP"); rc=$?
  expect_code 1 "$rc" "a CAPPZ task with a work-key pin must refuse"
  assert_refused_before_launch sp-workkey "$out" "config/pi-account pins Pi workers to $CASE/pi-work"
  assert_contains "$out" "spend profile 'personal' for project 'cappz-core' declares $CASE/pi-personal" \
    "the refusal should name the profile's own store"

  printf '%s\nopenrouter\n' "$CASE/pi-personal" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship sp-agree --harness pi --model "$CHEAP"); rc=$?
  expect_code 0 "$rc" "a pin that repeats the profile's store should launch: $out"
  assert_contains "$out" "account=$CASE/pi-personal" "the agreeing pin should select the personal store"

  new_case workkey-spire spire
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  printf '%s\nopenrouter\n' "$CASE/pi-personal" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship sp-inverse --harness pi --model "$OPUS"); rc=$?
  expect_code 1 "$rc" "a work task with a personal-key pin must refuse"
  assert_refused_before_launch sp-inverse "$out" "spend profile 'work' for project 'spire'"
  pass "a pi-account that disagrees with the project's profile is refused in both directions"
}

test_an_unmapped_project_is_refused() {
  local out rc
  new_case unmapped brand-new-app
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  out=$(spawn_ship sp-unmapped --harness pi --model "$CHEAP"); rc=$?
  expect_code 1 "$rc" "an unmapped project must refuse"
  assert_refused_before_launch sp-unmapped "$out" "project 'brand-new-app' is not in project_profiles"
  assert_absent "$CASE/pi-checks" "an unmapped project must refuse before any sign-in check"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" sp-unmapped-scout "$PROJ" --scout --harness pi --model "$CHEAP"); rc=$?
  expect_code 1 "$rc" "an unmapped project must refuse a scout too"
  assert_contains "$out" "is not in project_profiles" "the scout refusal should say why"
  pass "a project that is not in the profile map refuses to launch, ship or scout, until it is mapped"
}

test_a_captain_override_is_explicit_and_recorded() {
  local out rc
  new_case override cappz-core
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  out=$(spawn_ship sp-ov-bare --harness pi --model "$OPUS" --profile work); rc=$?
  expect_code 1 "$rc" "--profile alone must refuse"
  assert_refused_before_launch sp-ov-bare "$out" "--profile and --captain-override go together"
  out=$(spawn_ship sp-ov-words --harness pi --model "$OPUS" --captain-override "yes"); rc=$?
  expect_code 1 "$rc" "--captain-override alone must refuse"
  assert_refused_before_launch sp-ov-words "$out" "--profile and --captain-override go together"
  out=$(spawn_ship sp-ov-none --harness pi --model "$OPUS" --profile nope --captain-override "use it"); rc=$?
  expect_code 1 "$rc" "an undeclared profile must refuse"
  assert_refused_before_launch sp-ov-none "$out" "spend profile 'nope' is not declared"

  out=$(spawn_ship sp-ov --harness pi --model "$OPUS" --profile work --captain-override "Opus for this CAPPZ task, my call"); rc=$?
  expect_code 0 "$rc" "an explicit override should launch: $out"
  assert_contains "$out" "profile=work" "the override profile should be reported"
  assert_grep "profile=work" "$HOME_DIR/state/sp-ov.meta" "the record should carry the override profile"
  assert_grep "captain_override=Opus for this CAPPZ task, my call" "$HOME_DIR/state/sp-ov.meta" "the record should carry the captain's words"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the override should use the chosen profile's store"

  new_case override-unmapped brand-new-app
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  out=$(spawn_ship sp-ov-unmapped --harness pi --model "$CHEAP" --profile personal --captain-override "personal, mine"); rc=$?
  expect_code 0 "$rc" "an override should name the profile of an unmapped project: $out"
  pass "a profile other than the project's own needs the captain's words, and the record keeps them"
}

test_a_harness_without_an_account_pin_is_refused() {
  local out rc
  new_case harness cappz-core
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  out=$(spawn_ship sp-codex --harness codex --model gpt-5.5 --profile personal --captain-override "try codex"); rc=$?
  expect_code 1 "$rc" "a codex task under a keyed profile must refuse"
  assert_refused_before_launch sp-codex "$out" "has no per-launch account pin in this version"
  out=$(spawn_ship sp-raw --harness "pi --model $CHEAP" --model "$CHEAP"); rc=$?
  expect_code 1 "$rc" "a raw Pi command under a keyed profile must refuse"
  assert_refused_before_launch sp-raw "$out" "a raw Pi launch command runs verbatim"
  pass "a harness that cannot pin the profile's account, and a raw Pi command, are refused"
}

test_malformed_spend_profiles_refuse_before_launch() {
  local out rc n=0 body
  new_case malformed cappz-core
  # Each edit breaks one rule of the schema; every one must refuse the spawn.
  for body in \
    '.spend_profiles.personal.pi_account.root = "relative/store"' \
    '.spend_profiles.personal.pi_account.providers = []' \
    'del(.spend_profiles.personal.default)' \
    '.spend_profiles.personal.pi_account.root = .spend_profiles.work.pi_account.root' \
    '.project_profiles.spire = "ghost"' \
    '.default_profile = "work"' \
    '.spend_profiles.work.rules[0].use.harness = "claude"' \
    '.spend_profiles.work.default.model = "anthropic/claude-sonnet-5.5"' \
    'del(.project_profiles)'; do
    n=$((n + 1))
    write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
    jq "$body" "$HOME_DIR/config/crew-dispatch.json" > "$CASE/edited.json" && mv "$CASE/edited.json" "$HOME_DIR/config/crew-dispatch.json"
    out=$(spawn_ship "sp-bad-$n" --harness pi --model "$CHEAP"); rc=$?
    expect_code 1 "$rc" "malformed spend profiles #$n ($body) must refuse"
    assert_refused_before_launch "sp-bad-$n" "$out" "config/crew-dispatch.json spend_profiles invalid"
  done
  printf '{ "spend_profiles": { ' > "$HOME_DIR/config/crew-dispatch.json"
  out=$(spawn_ship sp-bad-json --harness pi --model "$CHEAP"); rc=$?
  expect_code 1 "$rc" "an unreadable file that names spend_profiles must refuse"
  assert_refused_before_launch sp-bad-json "$out" "spend profile guards cannot be evaluated"
  printf '{ not json' > "$HOME_DIR/config/crew-dispatch.json"
  out=$(spawn_ship sp-legacy-json --harness pi --model "$CHEAP"); rc=$?
  expect_code 0 "$rc" "a legacy file that is not JSON keeps launching as before (bootstrap reports it): $out"
  pass "malformed spend profiles, a shared store, and an unreadable spend-profile file refuse before launch"
}

test_a_secondmate_spawn_is_exempt() {
  local out rc sm id=sp-sm
  new_case secondmate cappz-core
  write_dispatch "$HOME_DIR/config" "$CASE/pi-work" "$CASE/pi-personal"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate --harness pi --model "$SONNET"); rc=$?
  expect_code 0 "$rc" "a secondmate spawn resolves no project profile in this version: $out"
  assert_not_contains "$out" "profile=" "a secondmate spawn must report no profile"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id-2" "$sm" --secondmate --profile work --captain-override "x"); rc=$?
  expect_code 1 "$rc" "--profile must refuse on a secondmate"
  assert_contains "$out" "--profile applies only to ship and scout spawns" "the secondmate refusal should say why"
  pass "a secondmate spawn is exempt from project profiles and refuses --profile"
}

test_the_day_one_example_reproduces_todays_routing() {
  local cfg="$TMP_ROOT/day-one/config" project sel out
  mkdir -p "$cfg" "$TMP_ROOT/day-one/home"
  cp "$ROOT/docs/examples/crew-dispatch.spend-profiles.json" "$cfg/crew-dispatch.json"
  (
    export HOME="$TMP_ROOT/day-one/home"
    # shellcheck source=bin/fm-spend-profile-lib.sh
    . "$ROOT/bin/fm-spend-profile-lib.sh"
    fm_spend_profile_validate "$cfg" || exit 1
    for project in fleet-ops auteur spire-project spire-venue agent-binding-host agent-binding-catalog quota-axi \
      continuum Qwen3.8-Flash-Next-Single-DGX-Spark rung firstmate; do
      sel=$(fm_spend_profile_select "$cfg" "$project" "" "" "" "" pi "$OPUS" "") || exit 2
      [ "${sel%%$'\t'*}" = work ] || exit 3
      fm_spend_profile_select "$cfg" "$project" "" "" "" "" pi "$SONNET" "" >/dev/null || exit 4
      fm_spend_profile_select "$cfg" "$project" "" "" "" "" pi openrouter/z-ai/glm-5.3-flashx "" >/dev/null || exit 5
    done
    for project in cappz-core cappz-dt animus graph-ledger-notary quanty-helper-pal mltradingsignal; do
      sel=$(fm_spend_profile_select "$cfg" "$project" "" "" "" "" pi "$CHEAP" "") || exit 6
      [ "${sel%%$'\t'*}" = personal ] || exit 7
      fm_spend_profile_select "$cfg" "$project" "" "" "" "" pi "$OPUS" "" >/dev/null 2>&1 && exit 8
      fm_spend_profile_select "$cfg" "$project" "" "" "" "" pi "$SONNET" "" >/dev/null 2>&1 && exit 9
    done
    fm_spend_profile_select "$cfg" not-registered "" "" "" "" pi "$CHEAP" "" >/dev/null 2>&1 && exit 10
    exit 0
  ); out=$?
  expect_code 0 "$out" "the day-one example must map every registered project plus firstmate and keep the personal profile cheap (stage $out)"
  pass "the day-one example maps work, personal, and unmapped projects as today's routing requires"
}

test_legacy_file_keeps_the_launch_and_record_unchanged
test_profile_selects_the_store_and_rules_by_project
test_a_model_outside_the_profile_is_refused
test_a_cappz_task_on_the_work_key_is_refused
test_an_unmapped_project_is_refused
test_a_captain_override_is_explicit_and_recorded
test_a_harness_without_an_account_pin_is_refused
test_malformed_spend_profiles_refuse_before_launch
test_a_secondmate_spawn_is_exempt
test_the_day_one_example_reproduces_todays_routing

echo "# all fm-spend-profile tests passed"
