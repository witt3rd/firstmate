#!/usr/bin/env bash
# Contract tests for bin/fm-install-shellcheck.sh and bin/fm-install-actionlint.sh,
# the pinned CI lint-tool installers. Everything external is a stub on PATH
# (uname, curl, sleep, tar, sha256sum), so nothing is downloaded or installed
# outside the temp root. Published digests below are compared with what the
# installers verify, not read from script source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHELLCHECK="$ROOT/bin/fm-install-shellcheck.sh"
ACTIONLINT="$ROOT/bin/fm-install-actionlint.sh"
SC_VERSION=$("$ROOT/bin/fm-lint.sh" --required-version)
AL_VERSION=$("$ROOT/bin/fm-lint-workflows.sh" --required-version)
SC_SHA_LINUX_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
AL_SHA_LINUX_X86_64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
SC_SHA_LINUX_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
SC_SHA_DARWIN_X86_64=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
SC_SHA_DARWIN_ARM64=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
AL_SHA_LINUX_AARCH64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
AL_SHA_DARWIN_X86_64=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
AL_SHA_DARWIN_ARM64=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f

# mk_world <name>: fakebin with uname, sha256sum, sleep, tar, and a curl that
# logs its URL, fails its first CURL_FAIL_FIRST calls, and writes a placeholder.
mk_world() {
  local w fb
  w=$(fm_test_tmproot "fm-install-lint-$1")
  fb="$w/bin"
  mkdir -p "$fb" "$w/dest" "$w/tmp"
  cat > "$fb/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  cat > "$fb/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$1"
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
SH
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
out=; url=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac
done
printf '%s\n' "$url" >> "$CURL_URL_LOG"
n=$(wc -l < "$CURL_URL_LOG")
[ "$n" -gt "${CURL_FAIL_FIRST:-0}" ] || exit 22
: > "$out"
SH
  cat > "$fb/tar" <<'SH'
#!/usr/bin/env bash
flag=$1
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then
    [ -z "${TAR_EMPTY:-}" ] || exit 0
    case "$flag" in
      -xzf) bin="$2/actionlint" ;;
      -xJf) mkdir -p "$2/shellcheck-v${SC_FAKE_VERSION}"; bin="$2/shellcheck-v${SC_FAKE_VERSION}/shellcheck" ;;
      *) exit 2 ;;
    esac
    printf '#!/usr/bin/env bash\necho fake-tool-version\n' > "$bin"
    chmod +x "$bin"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fb"/*
  : > "$w/urls"
  : > "$w/sleeps"
  printf '%s\n' "$w"
}

run_inst() {
  # run_inst <world> <script> [env...]: runs installer, sets OUT and RC.
  local w=$1 script=$2
  shift 2
  OUT=$(env "$@" CURL_URL_LOG="$w/urls" SLEEP_LOG="$w/sleeps" SC_FAKE_VERSION="$SC_VERSION" \
    RUNNER_TEMP="$w/tmp" PATH="$w/bin:$PATH" bash "$script" "$w/dest" 2>&1)
  RC=$?
}

test_installs_pinned_builds() {
  local w
  w=$(mk_world sc)
  run_inst "$w" "$SHELLCHECK" SHA256_STUB_HASH=$SC_SHA_LINUX_X86_64
  [ "$RC" -eq 0 ] || fail "shellcheck install failed: $OUT"
  [ -x "$w/dest/shellcheck" ] || fail "shellcheck binary not installed"
  assert_contains "$(cat "$w/urls")" \
    "https://github.com/koalaman/shellcheck/releases/download/v$SC_VERSION/shellcheck-v$SC_VERSION.linux.x86_64.tar.xz" \
    "shellcheck download URL is not the pinned official asset"
  w=$(mk_world al)
  run_inst "$w" "$ACTIONLINT" SHA256_STUB_HASH=$AL_SHA_LINUX_X86_64
  [ "$RC" -eq 0 ] || fail "actionlint install failed: $OUT"
  [ -x "$w/dest/actionlint" ] || fail "actionlint binary not installed"
  assert_contains "$(cat "$w/urls")" \
    "https://github.com/rhysd/actionlint/releases/download/v$AL_VERSION/actionlint_${AL_VERSION}_linux_amd64.tar.gz" \
    "actionlint download URL is not the pinned official asset"
  pass "lint-tool installers install the pinned verified builds"
}

test_selects_asset_per_platform() {
  local w s m sc al scsha alsha other_sc other_al
  while read -r s m sc al scsha alsha; do
    w=$(mk_world plat)
    run_inst "$w" "$SHELLCHECK" SHA256_STUB_HASH=$scsha FM_TEST_UNAME_S="$s" FM_TEST_UNAME_M="$m"
    [ "$RC" -eq 0 ] || fail "shellcheck pinned digest rejected for $s-$m: $OUT"
    assert_contains "$(cat "$w/urls")" "shellcheck-v$SC_VERSION.$sc.tar.xz" "wrong shellcheck asset for $s-$m"
    other_sc=$SC_SHA_LINUX_X86_64
    [ "$scsha" != "$other_sc" ] || other_sc=$SC_SHA_LINUX_AARCH64
    w=$(mk_world plat)
    run_inst "$w" "$SHELLCHECK" SHA256_STUB_HASH=$other_sc FM_TEST_UNAME_S="$s" FM_TEST_UNAME_M="$m"
    [ "$RC" -ne 0 ] || fail "shellcheck accepted another platform's digest for $s-$m"
    w=$(mk_world plat)
    run_inst "$w" "$ACTIONLINT" SHA256_STUB_HASH=$alsha FM_TEST_UNAME_S="$s" FM_TEST_UNAME_M="$m"
    [ "$RC" -eq 0 ] || fail "actionlint pinned digest rejected for $s-$m: $OUT"
    assert_contains "$(cat "$w/urls")" "actionlint_${AL_VERSION}_$al.tar.gz" "wrong actionlint asset for $s-$m"
    other_al=$AL_SHA_LINUX_X86_64
    [ "$alsha" != "$other_al" ] || other_al=$AL_SHA_LINUX_AARCH64
    w=$(mk_world plat)
    run_inst "$w" "$ACTIONLINT" SHA256_STUB_HASH=$other_al FM_TEST_UNAME_S="$s" FM_TEST_UNAME_M="$m"
    [ "$RC" -ne 0 ] || fail "actionlint accepted another platform's digest for $s-$m"
  done <<EOP
Linux x86_64 linux.x86_64 linux_amd64 $SC_SHA_LINUX_X86_64 $AL_SHA_LINUX_X86_64
Linux aarch64 linux.aarch64 linux_arm64 $SC_SHA_LINUX_AARCH64 $AL_SHA_LINUX_AARCH64
Linux arm64 linux.aarch64 linux_arm64 $SC_SHA_LINUX_AARCH64 $AL_SHA_LINUX_AARCH64
Darwin x86_64 darwin.x86_64 darwin_amd64 $SC_SHA_DARWIN_X86_64 $AL_SHA_DARWIN_X86_64
Darwin arm64 darwin.aarch64 darwin_arm64 $SC_SHA_DARWIN_ARM64 $AL_SHA_DARWIN_ARM64
EOP
  pass "lint-tool installers select the right asset and digest per platform"
}

test_refuses_unsupported_platform_without_download() {
  local w script
  for script in "$SHELLCHECK" "$ACTIONLINT"; do
    w=$(mk_world bad)
    run_inst "$w" "$script" SHA256_STUB_HASH=0 FM_TEST_UNAME_S=FreeBSD
    [ "$RC" -ne 0 ] || fail "unsupported platform must fail for $script"
    assert_contains "$OUT" "unsupported platform" "missing platform diagnostic"
    [ ! -s "$w/urls" ] || fail "unsupported platform must not download"
  done
  pass "lint-tool installers refuse unsupported platforms before downloading"
}

test_refuses_checksum_mismatch() {
  local w script tool
  for tool in shellcheck actionlint; do
    script=$ROOT/bin/fm-install-$tool.sh
    w=$(mk_world sum)
    run_inst "$w" "$script" SHA256_STUB_HASH=deadbeef
    [ "$RC" -ne 0 ] || fail "$tool checksum mismatch must fail"
    assert_contains "$OUT" "checksum mismatch" "missing checksum diagnostic"
    [ ! -e "$w/dest/$tool" ] || fail "mismatched $tool archive must not be installed"
  done
  pass "lint-tool installers refuse a checksum mismatch"
}

test_download_retries_then_fails() {
  local w
  w=$(mk_world retry)
  run_inst "$w" "$SHELLCHECK" SHA256_STUB_HASH=$SC_SHA_LINUX_X86_64 CURL_FAIL_FIRST=2
  [ "$RC" -eq 0 ] || fail "transient download failures must be retried: $OUT"
  assert_equals "3" "$(wc -l < "$w/urls" | tr -d ' ')" "expected two failures then one success"
  assert_equals "1 2 " "$(tr '\n' ' ' < "$w/sleeps")" "backoff must double between attempts"
  w=$(mk_world dl)
  run_inst "$w" "$ACTIONLINT" SHA256_STUB_HASH=$AL_SHA_LINUX_X86_64 CURL_FAIL_FIRST=99
  [ "$RC" -ne 0 ] || fail "persistent download failure must fail"
  assert_contains "$OUT" "download failed after 6 attempts" "missing download diagnostic"
  assert_equals "6" "$(wc -l < "$w/urls" | tr -d ' ')" "expected exactly six download attempts"
  [ ! -e "$w/dest/actionlint" ] || fail "failed download must not install"
  pass "lint-tool installers retry transient downloads and stop after six attempts"
}

test_requires_destination() {
  local out script
  for script in "$SHELLCHECK" "$ACTIONLINT"; do
    out=$(bash "$script" 2>&1) && fail "missing destination must fail for $script"
    assert_contains "$out" "usage:" "missing usage text"
  done
  pass "lint-tool installers require a destination"
}

test_installs_pinned_builds
test_selects_asset_per_platform
test_refuses_unsupported_platform_without_download
test_refuses_checksum_mismatch
test_download_retries_then_fails
test_requires_destination
