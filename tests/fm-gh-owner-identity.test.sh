#!/usr/bin/env bash
# Tests for bin/fm-gh-owner-identity.sh: the gh stand-in that runs each call as
# the identity owning the repository it targets. A stub gh records the GH_TOKEN
# and arguments it was run with, so every case asserts what the real gh would
# have seen.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM_SRC="$ROOT/bin/fm-gh-owner-identity.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-owner-identity-tests)
BASE_PATH=$PATH

# A case dir with the shim symlinked as gh ahead of a stub real gh. The stub logs
# one line per run ("token=<GH_TOKEN or -> args=<argv>"), answers
# `auth token -u <login>` from the case's tokens file, and never prints a token
# for any other call. Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/shimbin" "$case_dir/realbin" "$case_dir/config"
  ln -s "$SHIM_SRC" "$case_dir/shimbin/gh"
  cat > "$case_dir/realbin/gh" <<'SH'
#!/usr/bin/env bash
printf 'token=%s args=%s\n' "${GH_TOKEN:--}" "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = token ] && [ "${3:-}" = -u ]; then
  token=$(sed -n "s/^$4 //p" "$FM_TEST_GH_TOKENS" | head -1)
  [ -n "$token" ] || exit 1
  printf '%s\n' "$token"
  exit 0
fi
printf 'stub gh ran\n'
SH
  chmod +x "$case_dir/realbin/gh"
  : > "$case_dir/gh.log"
  printf '%s\n' 'witt3rd tok-witt3rd-secret' 'ghostless-other tok-other' > "$case_dir/tokens"
  printf '%s\n' '# identities' 'witt3rd witt3rd' '' 'Mixed-Case witt3rd' > "$case_dir/config/gh-identities"
  printf '%s\n' "$case_dir"
}

# Run the shim as gh from <dir>. Args: case_dir cwd gh-args...
run_gh() {
  local case_dir=$1 cwd=$2
  shift 2
  ( cd "$cwd" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REPO \
      FM_GH_IDENTITIES="$case_dir/config/gh-identities" \
      FM_TEST_GH_LOG="$case_dir/gh.log" \
      FM_TEST_GH_TOKENS="$case_dir/tokens" \
      PATH="$case_dir/shimbin:$case_dir/realbin:$BASE_PATH" \
      gh "$@" )
}

last_run() { grep -v ' args=auth token ' "$1/gh.log" | tail -1; }

test_personal_repo_runs_as_its_owner_identity() {
  local case_dir out
  case_dir=$(make_case personal)
  out=$(run_gh "$case_dir" "$case_dir" pr create -R witt3rd/firstmate --base main 2>&1) \
    || fail "personal: the call should succeed: $out"
  [ "$(last_run "$case_dir")" = 'token=tok-witt3rd-secret args=pr create -R witt3rd/firstmate --base main' ] \
    || fail "personal: the real gh did not get the owner's token: $(last_run "$case_dir")"
  case "$out" in *tok-witt3rd-secret*) fail "personal: the token leaked into the call's output" ;; esac
  assert_no_grep 'args=.*tok-witt3rd-secret' "$case_dir/gh.log" "personal: the token reached a command line"
  pass "fm-gh-owner-identity runs a personal repository's call as the owning login"
}

test_enterprise_repo_keeps_its_own_identity() {
  local case_dir
  case_dir=$(make_case enterprise)
  run_gh "$case_dir" "$case_dir" pr create --repo janus-infra/spire-venue >/dev/null 2>&1 \
    || fail "enterprise: the call should pass through"
  [ "$(last_run "$case_dir")" = 'token=- args=pr create --repo janus-infra/spire-venue' ] \
    || fail "enterprise: an unmapped owner was given a token: $(last_run "$case_dir")"
  assert_no_grep 'args=auth token' "$case_dir/gh.log" "enterprise: a token was read for an unmapped owner"
  pass "fm-gh-owner-identity leaves an unmapped owner on the ambient account"
}

test_missing_identity_refuses_plainly() {
  local case_dir out rc
  case_dir=$(make_case missing)
  printf '%s\n' 'witt3rd ghost' > "$case_dir/config/gh-identities"
  set +e
  out=$(run_gh "$case_dir" "$case_dir" pr create -R witt3rd/firstmate 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing: a mapped login with no token must refuse"
  case "$out" in *"witt3rd"*"ghost"*"no token"*) ;; *) fail "missing: the refusal did not name the owner and login: $out" ;; esac
  assert_no_grep 'args=pr create' "$case_dir/gh.log" "missing: the call ran as another account"
  pass "fm-gh-owner-identity refuses plainly when the owning login has no token"
}

test_malformed_map_refuses() {
  local case_dir out rc
  case_dir=$(make_case malformed)
  printf '%s\n' 'witt3rd' > "$case_dir/config/gh-identities"
  set +e
  out=$(run_gh "$case_dir" "$case_dir" pr create -R witt3rd/firstmate 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed: a malformed map line must refuse"
  case "$out" in *"line 1"*) ;; *) fail "malformed: the refusal did not name the line: $out" ;; esac
  assert_no_grep 'args=pr create' "$case_dir/gh.log" "malformed: the call ran anyway"
  pass "fm-gh-owner-identity refuses a malformed identity map instead of guessing"
}

test_absent_map_and_explicit_token_pass_through() {
  local case_dir
  case_dir=$(make_case passthrough)
  rm -f "$case_dir/config/gh-identities"
  run_gh "$case_dir" "$case_dir" pr create -R witt3rd/firstmate >/dev/null 2>&1 || fail "absent-map: should pass through"
  [ "$(last_run "$case_dir")" = 'token=- args=pr create -R witt3rd/firstmate' ] \
    || fail "absent-map: a token was injected without a map: $(last_run "$case_dir")"
  printf '%s\n' 'witt3rd witt3rd' > "$case_dir/config/gh-identities"
  : > "$case_dir/gh.log"
  ( cd "$case_dir" && env FM_GH_IDENTITIES="$case_dir/config/gh-identities" \
      FM_TEST_GH_LOG="$case_dir/gh.log" FM_TEST_GH_TOKENS="$case_dir/tokens" GH_TOKEN=explicit \
      PATH="$case_dir/shimbin:$case_dir/realbin:$BASE_PATH" gh pr create -R witt3rd/firstmate >/dev/null 2>&1 ) \
    || fail "explicit-token: should pass through"
  [ "$(last_run "$case_dir")" = 'token=explicit args=pr create -R witt3rd/firstmate' ] \
    || fail "explicit-token: an explicit GH_TOKEN was replaced: $(last_run "$case_dir")"
  pass "fm-gh-owner-identity is a pass-through without a map and never overrides an explicit token"
}

test_auth_and_config_calls_are_never_touched() {
  local case_dir
  case_dir=$(make_case auth)
  run_gh "$case_dir" "$case_dir" auth status -R witt3rd/firstmate >/dev/null 2>&1 || true
  run_gh "$case_dir" "$case_dir" config get editor >/dev/null 2>&1 || true
  assert_no_grep 'token=tok' "$case_dir/gh.log" "auth: a gh auth or config call was given a token"
  assert_no_grep 'args=auth token' "$case_dir/gh.log" "auth: the shim read a token for an auth call"
  pass "fm-gh-owner-identity never touches gh auth or gh config calls"
}

test_owner_is_read_from_every_target_form() {
  local case_dir repo
  case_dir=$(make_case forms)
  repo="$case_dir/repo"
  git init -q "$repo"
  git -C "$repo" remote add origin git@github.com:witt3rd/firstmate.git
  run_gh "$case_dir" "$repo" pr create >/dev/null 2>&1 || fail "forms: origin remote call failed"
  [ "$(last_run "$case_dir")" = 'token=tok-witt3rd-secret args=pr create' ] || fail "forms: the origin remote owner was not used"
  run_gh "$case_dir" "$case_dir" pr view https://github.com/witt3rd/firstmate/pull/31 >/dev/null 2>&1
  [ "$(last_run "$case_dir" | cut -d' ' -f1)" = 'token=tok-witt3rd-secret' ] || fail "forms: a URL argument owner was not used"
  run_gh "$case_dir" "$case_dir" api repos/witt3rd/firstmate/commits >/dev/null 2>&1
  [ "$(last_run "$case_dir" | cut -d' ' -f1)" = 'token=tok-witt3rd-secret' ] || fail "forms: an api path owner was not used"
  run_gh "$case_dir" "$case_dir" pr view -Rwitt3rd/firstmate 31 >/dev/null 2>&1
  [ "$(last_run "$case_dir" | cut -d' ' -f1)" = 'token=tok-witt3rd-secret' ] || fail "forms: a bundled -R owner was not used"
  ( cd "$case_dir" && env -u GH_TOKEN GH_REPO=witt3rd/firstmate FM_GH_IDENTITIES="$case_dir/config/gh-identities" \
      FM_TEST_GH_LOG="$case_dir/gh.log" FM_TEST_GH_TOKENS="$case_dir/tokens" \
      PATH="$case_dir/shimbin:$case_dir/realbin:$BASE_PATH" gh pr list >/dev/null 2>&1 )
  [ "$(last_run "$case_dir" | cut -d' ' -f1)" = 'token=tok-witt3rd-secret' ] || fail "forms: GH_REPO owner was not used"
  run_gh "$case_dir" "$case_dir" pr create -R mixed-case/firstmate >/dev/null 2>&1
  [ "$(last_run "$case_dir" | cut -d' ' -f1)" = 'token=tok-witt3rd-secret' ] || fail "forms: the owner match is not case-insensitive"
  run_gh "$case_dir" "$case_dir" pr create -R ghe.example.com/witt3rd/firstmate >/dev/null 2>&1
  [ "$(last_run "$case_dir" | cut -d' ' -f1)" = 'token=-' ] || fail "forms: a non-github.com host was given a token"
  pass "fm-gh-owner-identity reads the owner from -R, GH_REPO, a URL, an api path, and the origin remote"
}

test_personal_repo_runs_as_its_owner_identity
test_enterprise_repo_keeps_its_own_identity
test_missing_identity_refuses_plainly
test_malformed_map_refuses
test_absent_map_and_explicit_token_pass_through
test_auth_and_config_calls_are_never_touched
test_owner_is_read_from_every_target_form
