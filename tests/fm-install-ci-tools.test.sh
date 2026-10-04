#!/usr/bin/env bash
# Contract tests for bin/fm-install-treehouse.sh and bin/fm-install-herdr.sh,
# the pinned CI installers for the real-Herdr lane. Everything external is a
# stub on PATH (uname, curl, tar, sha256sum), so nothing is downloaded or
# installed outside the temp root. Published digests below are compared with
# what the installers verify, not read from script source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TREEHOUSE="$ROOT/bin/fm-install-treehouse.sh"
HERDR="$ROOT/bin/fm-install-herdr.sh"
TREEHOUSE_SHA_LINUX_X86_64=1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2
HERDR_SHA_LINUX_X86_64=bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059

# mk_world <name>: fakebin with uname, sha256sum stub, and curl logging its URL
# and writing a placeholder (or the herdr fake binary) at -o.
mk_world() {
  local w fb
  w=$(fm_test_tmproot "fm-install-$1")
  fb="$w/bin"
  mkdir -p "$fb" "$w/dest"
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
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
out=; url=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac
done
printf '%s\n' "$url" >> "$CURL_URL_LOG"
[ -z "${CURL_FAIL:-}" ] || exit 22
if [ -n "${FAKE_BIN_SRC:-}" ]; then cp "$FAKE_BIN_SRC" "$out"; else : > "$out"; fi
SH
  cat > "$fb/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then
    [ -z "${TAR_EMPTY:-}" ] || exit 0
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "${TREEHOUSE_FAKE_VERSION:-v2.0.1}" > "$2/treehouse"
    chmod +x "$2/treehouse"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fb"/*
  : > "$w/urls"
  printf '%s\n' "$w"
}

fake_herdr() {
  # fake_herdr <path> <version> <protocol>
  cat > "$1" <<SH
#!/usr/bin/env bash
case "\$1" in
  --version) echo "herdr $2" ;;
  status) printf '{"client":{"protocol":$3}}\n' ;;
esac
SH
  chmod +x "$1"
}

run_inst() {
  # run_inst <world> <script> [env...]: runs installer, sets OUT and RC.
  local w=$1 script=$2
  shift 2
  OUT=$(env "$@" CURL_URL_LOG="$w/urls" PATH="$w/bin:$PATH" bash "$script" "$w/dest" 2>&1)
  RC=$?
}

test_treehouse_installs_pinned_build() {
  local w; w=$(mk_world th)
  run_inst "$w" "$TREEHOUSE" SHA256_STUB_HASH=$TREEHOUSE_SHA_LINUX_X86_64
  [ "$RC" -eq 0 ] || fail "treehouse install failed: $OUT"
  [ -x "$w/dest/treehouse" ] || fail "treehouse binary not installed"
  assert_contains "$(cat "$w/urls")" \
    "https://github.com/kunchenguid/treehouse/releases/download/v2.0.1/treehouse-v2.0.1-linux-amd64.tar.gz" \
    "treehouse download URL is not the pinned official asset"
  pass "treehouse installer installs the pinned verified build"
}

test_treehouse_selects_asset_per_platform() {
  local w s m want
  while read -r s m want; do
    w=$(mk_world th-plat)
    # Digest differs per platform, so a mismatch is expected; the URL is the check.
    run_inst "$w" "$TREEHOUSE" SHA256_STUB_HASH=0 FM_TEST_UNAME_S="$s" FM_TEST_UNAME_M="$m"
    assert_contains "$(cat "$w/urls")" "treehouse-v2.0.1-$want.tar.gz" "wrong asset for $s-$m"
  done <<'EOP'
Linux aarch64 linux-arm64
Darwin arm64 darwin-arm64
Darwin x86_64 darwin-amd64
EOP
  pass "treehouse installer selects the right asset per platform"
}

test_treehouse_refuses_unsupported_platform_without_download() {
  local w; w=$(mk_world th-bad)
  run_inst "$w" "$TREEHOUSE" SHA256_STUB_HASH=0 FM_TEST_UNAME_S=FreeBSD
  [ "$RC" -ne 0 ] || fail "unsupported platform must fail"
  assert_contains "$OUT" "unsupported platform" "missing platform diagnostic"
  [ ! -s "$w/urls" ] || fail "unsupported platform must not download"
  pass "treehouse installer refuses unsupported platforms before downloading"
}

test_treehouse_refuses_checksum_mismatch() {
  local w; w=$(mk_world th-sum)
  run_inst "$w" "$TREEHOUSE" SHA256_STUB_HASH=deadbeef
  [ "$RC" -ne 0 ] || fail "checksum mismatch must fail"
  assert_contains "$OUT" "checksum mismatch" "missing checksum diagnostic"
  [ ! -e "$w/dest/treehouse" ] || fail "mismatched archive must not be installed"
  pass "treehouse installer refuses a checksum mismatch"
}

test_treehouse_refuses_download_failure_and_wrong_version() {
  local w
  w=$(mk_world th-dl)
  run_inst "$w" "$TREEHOUSE" SHA256_STUB_HASH=$TREEHOUSE_SHA_LINUX_X86_64 CURL_FAIL=1
  [ "$RC" -ne 0 ] || fail "download failure must fail"
  assert_contains "$OUT" "download failed" "missing download diagnostic"
  w=$(mk_world th-ver)
  run_inst "$w" "$TREEHOUSE" SHA256_STUB_HASH=$TREEHOUSE_SHA_LINUX_X86_64 TREEHOUSE_FAKE_VERSION=v9.9.9
  [ "$RC" -ne 0 ] || fail "wrong version must fail"
  assert_contains "$OUT" "expected exact pin" "missing version diagnostic"
  w=$(mk_world th-empty)
  run_inst "$w" "$TREEHOUSE" SHA256_STUB_HASH=$TREEHOUSE_SHA_LINUX_X86_64 TAR_EMPTY=1
  [ "$RC" -ne 0 ] || fail "archive without a binary must fail"
  assert_contains "$OUT" "did not contain a treehouse binary" "missing empty-archive diagnostic"
  pass "treehouse installer refuses download failure, wrong version, and empty archive"
}

test_treehouse_requires_destination() {
  local out
  out=$(bash "$TREEHOUSE" 2>&1) && fail "missing destination must fail"
  assert_contains "$out" "usage:" "missing usage text"
  pass "treehouse installer requires a destination"
}

test_herdr_installs_pinned_build() {
  local w; w=$(mk_world hd)
  fake_herdr "$w/src" 0.7.4 16
  run_inst "$w" "$HERDR" SHA256_STUB_HASH=$HERDR_SHA_LINUX_X86_64 FAKE_BIN_SRC="$w/src"
  [ "$RC" -eq 0 ] || fail "herdr install failed: $OUT"
  [ -x "$w/dest/herdr" ] || fail "herdr binary not installed"
  assert_contains "$(cat "$w/urls")" \
    "https://github.com/ogulcancelik/herdr/releases/download/v0.7.4/herdr-linux-x86_64" \
    "herdr download URL is not the pinned official asset"
  assert_contains "$OUT" "protocol 16" "success output omitted the protocol"
  pass "herdr installer installs the pinned verified build"
}

test_herdr_refuses_bad_inputs() {
  local w
  w=$(mk_world hd-plat)
  run_inst "$w" "$HERDR" SHA256_STUB_HASH=0 FM_TEST_UNAME_S=Plan9
  [ "$RC" -ne 0 ] || fail "unsupported platform must fail"
  [ ! -s "$w/urls" ] || fail "unsupported platform must not download"
  w=$(mk_world hd-sum)
  fake_herdr "$w/src" 0.7.4 16
  run_inst "$w" "$HERDR" SHA256_STUB_HASH=deadbeef FAKE_BIN_SRC="$w/src"
  [ "$RC" -ne 0 ] || fail "checksum mismatch must fail"
  assert_contains "$OUT" "checksum mismatch" "missing checksum diagnostic"
  w=$(mk_world hd-dl)
  run_inst "$w" "$HERDR" SHA256_STUB_HASH=$HERDR_SHA_LINUX_X86_64 CURL_FAIL=1
  assert_contains "$OUT" "download failed" "missing download diagnostic"
  w=$(mk_world hd-ver)
  fake_herdr "$w/src" 0.7.3 16
  run_inst "$w" "$HERDR" SHA256_STUB_HASH=$HERDR_SHA_LINUX_X86_64 FAKE_BIN_SRC="$w/src"
  [ "$RC" -ne 0 ] || fail "wrong version must fail"
  assert_contains "$OUT" "expected exact pin" "missing version diagnostic"
  w=$(mk_world hd-proto)
  fake_herdr "$w/src" 0.7.4 15
  run_inst "$w" "$HERDR" SHA256_STUB_HASH=$HERDR_SHA_LINUX_X86_64 FAKE_BIN_SRC="$w/src"
  [ "$RC" -ne 0 ] || fail "low protocol must fail"
  assert_contains "$OUT" "below the required floor" "missing protocol diagnostic"
  pass "herdr installer refuses bad platform, checksum, download, version, and protocol"
}

test_treehouse_installs_pinned_build
test_treehouse_selects_asset_per_platform
test_treehouse_refuses_unsupported_platform_without_download
test_treehouse_refuses_checksum_mismatch
test_treehouse_refuses_download_failure_and_wrong_version
test_treehouse_requires_destination
test_herdr_installs_pinned_build
test_herdr_refuses_bad_inputs
