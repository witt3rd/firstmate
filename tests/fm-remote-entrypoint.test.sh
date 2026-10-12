#!/usr/bin/env bash
# fm-remote-entrypoint.sh installs as a PATH symlink under ~/.local/bin
# (docs/remote-secondmates.md). SCRIPT_DIR must resolve to the real bin/
# directory so it can source its sibling fm-remote-job-lib.sh, not to the
# symlink's own directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-entrypoint)
REAL_BIN="$TMP_ROOT/real-root/bin"
LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$REAL_BIN" "$LOCAL_BIN"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" "$REAL_BIN/"
chmod +x "$REAL_BIN/fm-remote-entrypoint.sh"
ln -s "$REAL_BIN/fm-remote-entrypoint.sh" "$LOCAL_BIN/fm-remote-entrypoint.sh"

run_entrypoint() { # <path> <stdout-file> <stderr-file>
  local path=$1 out=$2 err=$3 code
  "$path" >"$out" 2>"$err"
  code=$?
  printf '%s' "$code"
}

test_symlink_invocation_resolves_sibling_lib() {
  local out err code
  out="$TMP_ROOT/symlink.stdout"
  err="$TMP_ROOT/symlink.stderr"
  code=$(run_entrypoint "$LOCAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  # A wrong SCRIPT_DIR fails while sourcing the sibling lib, before argv is
  # even checked, with a "No such file or directory" source error and exit 1.
  # Reaching the die() for missing protocol args proves the sibling lib
  # sourced from the real bin/, not from the symlink's own directory.
  assert_no_grep 'No such file or directory' "$err" \
    "invoking fm-remote-entrypoint.sh through a symlink failed to source its sibling lib"
  expect_code 64 "$code" "symlink invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "symlink invocation did not reach argument validation past sibling-lib sourcing"
  pass "fm-remote-entrypoint.sh invoked via a PATH symlink resolves SCRIPT_DIR to the real bin/ directory"
}

test_direct_invocation_still_works() {
  # Control: the same real script invoked directly (no symlink) must behave
  # identically, so the symlink coverage above is proven by contrast.
  local out err code
  out="$TMP_ROOT/direct.stdout"
  err="$TMP_ROOT/direct.stderr"
  code=$(run_entrypoint "$REAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  expect_code 64 "$code" "direct invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "direct invocation did not reach argument validation"
  pass "fm-remote-entrypoint.sh invoked directly still resolves SCRIPT_DIR correctly"
}

test_symlink_invocation_resolves_sibling_lib
test_direct_invocation_still_works

GOOD_B64=$(printf '%s' "$TMP_ROOT/real-root" | base64 | tr -d '\n')

test_corrupt_decode_prints_diagnostic() {
  local out err code
  out="$TMP_ROOT/corrupt.stdout"
  err="$TMP_ROOT/corrupt.stderr"
  "$REAL_BIN/fm-remote-entrypoint.sh" 1 '!!notbase64!!' "$GOOD_B64" "$GOOD_B64" >"$out" 2>"$err"
  code=$?
  expect_code 64 "$code" "corrupt decode exit code"
  assert_grep 'error: invalid base64 for remote root' "$err" "original message changed"
  assert_grep 'diagnostic: remote root decode failed: encoded length=13 bytes, empty=no, only base64 characters=no, decoder stderr=base64: invalid input' "$err" \
    "diagnostic lacks length or decoder stderr"
  assert_grep 'writable=yes' "$err" "diagnostic lacks staging dir"
  pass "corrupt decode appends a diagnostic line with length and decoder stderr"
}

test_unwritable_staging_names_it() {
  local err code stubs="$TMP_ROOT/stubs"
  err="$TMP_ROOT/unwritable.stderr"
  mkdir -p "$stubs"
  cat > "$stubs/mktemp" <<'S'
#!/usr/bin/env bash
d=$(/usr/bin/mktemp "$@") || exit 1
chmod 555 "$d"
printf '%s\n' "$d"
S
  chmod +x "$stubs/mktemp"
  PATH="$stubs:$PATH" "$REAL_BIN/fm-remote-entrypoint.sh" 1 "$GOOD_B64" "$GOOD_B64" "$GOOD_B64" >/dev/null 2>"$err"
  code=$?
  expect_code 64 "$code" "unwritable staging exit code"
  assert_grep 'staging dir=' "$err" "diagnostic lacks staging dir"
  assert_grep 'writable=no' "$err" \
    "diagnostic did not name the unwritable staging dir"
  pass "unwritable staging directory is named in the diagnostic"
}

test_good_decode_prints_no_diagnostic() {
  local err
  err="$TMP_ROOT/good.stderr"
  "$REAL_BIN/fm-remote-entrypoint.sh" 1 "$GOOD_B64" "$GOOD_B64" "$GOOD_B64" >/dev/null 2>"$err"
  assert_no_grep 'diagnostic:' "$err" "good decode printed a diagnostic"
  assert_no_grep 'invalid base64' "$err" "good decode failed to decode"
  pass "good decode prints no diagnostic"
}

test_corrupt_decode_prints_diagnostic
test_unwritable_staging_names_it
test_good_decode_prints_no_diagnostic
