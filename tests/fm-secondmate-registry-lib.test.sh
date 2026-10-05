#!/usr/bin/env bash
# Contract coverage for bin/fm-secondmate-registry-lib.sh: record parsing for
# local and remote forms, single-record lookup, field selection, and the
# binding validation that refuses malformed, unsafe, duplicate, or overlapping
# registrations.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-registry-lib)

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

LOCAL_A='- alpha - Handles (tricky; prose) things (home: /srv/mates/alpha; scope: infra (all); misc; projects: p1,p2; added 2026-01-02)'
REMOTE_B='- beta - Remote mate (host: box-1; root: /opt/fm; home: /srv/mates/beta; scope: data work; projects: p3; added 2026-02-03)'

# A resolver that mirrors a real path-key function without touching the disk;
# /unresolvable stands in for a home whose parent cannot be resolved.
resolver() {
  case "$1" in
    /unresolvable) return 1 ;;
    /*) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

reg_file() {  # <name> <lines...>
  local f="$TMP_ROOT/$1.md"
  shift
  : > "$f"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
  printf '%s\n' "$f"
}

validate_err() {  # <reg> [id] [home]; prints error, returns validation status
  secondmate_registry_validate_bindings "$1" resolver "${2:-}" "${3:-}"
  local rc=$?
  printf '%s' "$SECONDMATE_REGISTRY_ERROR"
  return $rc
}

test_parse_local_and_remote() {
  secondmate_registry_parse_line "$LOCAL_A" || fail "local record must parse"
  assert_equals alpha "$SECONDMATE_REGISTRY_ID" "local id"
  assert_equals "Handles (tricky; prose) things" "$SECONDMATE_REGISTRY_SUMMARY" "summary keeps parens and semicolons"
  assert_equals /srv/mates/alpha "$SECONDMATE_REGISTRY_HOME" "local home"
  assert_equals "infra (all); misc" "$SECONDMATE_REGISTRY_SCOPE" "scope keeps parens and semicolons"
  assert_equals p1,p2 "$SECONDMATE_REGISTRY_PROJECTS" "projects"
  assert_equals 2026-01-02 "$SECONDMATE_REGISTRY_ADDED" "added date"
  assert_equals 0 "$SECONDMATE_REGISTRY_REMOTE" "local flag"
  assert_equals "" "$SECONDMATE_REGISTRY_HOST" "local has no host"

  secondmate_registry_parse_line "$REMOTE_B" || fail "remote record must parse"
  assert_equals beta "$SECONDMATE_REGISTRY_ID" "remote id"
  assert_equals box-1 "$SECONDMATE_REGISTRY_HOST" "remote host"
  assert_equals /opt/fm "$SECONDMATE_REGISTRY_ROOT" "remote root"
  assert_equals /srv/mates/beta "$SECONDMATE_REGISTRY_HOME" "remote home"
  assert_equals 1 "$SECONDMATE_REGISTRY_REMOTE" "remote flag"

  secondmate_registry_parse_line '- gamma - mentions (host: x; root: /r; home: /h; scope: s; projects: p; added 2026-01-01) inside (home: /real; scope: real scope; projects: p; added 2026-03-04)' \
    || fail "legacy local form with remote-looking prose must parse"
  assert_equals 0 "$SECONDMATE_REGISTRY_REMOTE" "local form wins over prose that names remote fields"
  assert_equals /real "$SECONDMATE_REGISTRY_HOME" "real home taken from the suffix"
  pass "parse_line handles local, remote, and prose containing punctuation"
}

test_parse_rejections() {
  local bad
  for bad in \
    'not a record' \
    '- alpha no separator (home: /h; scope: s; projects: p; added 2026-01-02)' \
    '- alpha - x (home: /h; scope: s; projects: p; added 2026-1-2)' \
    '- alpha - x (home: ; scope: s; projects: p; added 2026-01-02)' \
    '- alpha - x (home: /h; scope: ; projects: p; added 2026-01-02)' \
    '- alpha - x (host: ; root: /r; home: /h; scope: s; projects: p; added 2026-01-02)' \
    '- alpha - x (host: h; root: ; home: /h; scope: s; projects: p; added 2026-01-02)' \
    '- bad/id - x (home: /h; scope: s; projects: p; added 2026-01-02)' \
    '- alpha - x (home: /h; scope: s; projects: p; added 2026-01-02) trailing'; do
    secondmate_registry_parse_line "$bad" && fail "must reject: $bad"
  done
  secondmate_registry_parse_line "$LOCAL_A" || fail "parse before trailing-space check"
  secondmate_registry_parse_line "$LOCAL_A   " || fail "trailing whitespace is tolerated"
  pass "parse_line rejects malformed and incomplete records"
}

test_lookup_and_fields() {
  local reg
  reg=$(reg_file lookup '# header' "$LOCAL_A" '' "$REMOTE_B" '- alpha2 - other (home: /srv/mates/alpha2; scope: s; projects: p; added 2026-01-02)')
  secondmate_registry_line_for_id "$reg" alpha || fail "alpha lookup"
  assert_equals "$LOCAL_A" "$SECONDMATE_REGISTRY_LINE" "exact id, not alpha2"
  assert_equals /srv/mates/alpha "$SECONDMATE_REGISTRY_HOME" "lookup parses the record"
  secondmate_registry_line_for_id "$reg" nope && fail "unknown id"
  secondmate_registry_line_for_id "$reg" 'al pha' && fail "invalid id characters"
  secondmate_registry_line_for_id "$reg" '' && fail "empty id"
  secondmate_registry_line_for_id "$TMP_ROOT/absent.md" alpha && fail "missing registry"
  ln -s "$reg" "$TMP_ROOT/link.md"
  secondmate_registry_line_for_id "$TMP_ROOT/link.md" alpha && fail "symlinked registry"

  local dup
  dup=$(reg_file dup "$LOCAL_A" "$LOCAL_A")
  secondmate_registry_line_for_id "$dup" alpha && fail "duplicate id must refuse"
  local unparsable
  unparsable=$(reg_file unparsable '- alpha - broken entry')
  secondmate_registry_line_for_id "$unparsable" alpha && fail "unparsable single record must refuse"

  assert_equals /srv/mates/alpha "$(secondmate_registry_field "$reg" alpha home)" "home"
  assert_equals "infra (all); misc" "$(secondmate_registry_field "$reg" alpha scope)" "scope"
  assert_equals p1,p2 "$(secondmate_registry_field "$reg" alpha projects)" "projects"
  assert_equals 0 "$(secondmate_registry_field "$reg" alpha remote)" "remote 0"
  assert_equals 1 "$(secondmate_registry_field "$reg" beta remote)" "remote 1"
  assert_equals box-1 "$(secondmate_registry_field "$reg" beta host)" "host"
  assert_equals /opt/fm "$(secondmate_registry_field "$reg" beta root)" "root"
  secondmate_registry_field "$reg" alpha bogus && fail "unknown key"
  secondmate_registry_field "$reg" nope home && fail "unknown id field"
  pass "line_for_id and field select exactly one valid record"
}

test_lock_paths_and_path_key() {
  assert_equals /s/.secondmate-registry.lock "$(secondmate_registry_lock_path /s)" "registry lock"
  assert_equals /s/.remote-reply-lifecycle-c1.lock "$(secondmate_reply_lifecycle_lock_path /s c1)" "reply lock"
  mkdir -p "$TMP_ROOT/real/sub"
  ln -s "$TMP_ROOT/real" "$TMP_ROOT/alias"
  assert_equals "$TMP_ROOT/real/sub" "$(secondmate_registry_path_key "$TMP_ROOT/alias/sub")" "existing dir resolves symlinks"
  assert_equals "$TMP_ROOT/real/new" "$(secondmate_registry_path_key "$TMP_ROOT/alias/new")" "absent leaf keeps its name under a resolved parent"
  secondmate_registry_path_key relative/path && fail "relative path refused"
  secondmate_registry_path_key "$TMP_ROOT/missing-parent/x" 2>/dev/null && fail "unresolvable parent refused"
  pass "lock paths and path_key"
}

test_validate_accepts_and_matches() {
  local reg
  reg=$(reg_file ok "$LOCAL_A" "$REMOTE_B" 'free text is ignored')
  validate_err "$reg" >/dev/null || fail "valid registry must validate"
  validate_err "$reg" alpha >/dev/null || fail "alpha binding"
  assert_equals /srv/mates/alpha "$SECONDMATE_REGISTRY_MATCH_HOME" "match home"
  assert_equals local:/srv/mates/alpha "$SECONDMATE_REGISTRY_MATCH_HOME_KEY" "local key"
  assert_equals p1,p2 "$SECONDMATE_REGISTRY_MATCH_PROJECTS" "match projects"
  assert_equals 0 "$SECONDMATE_REGISTRY_MATCH_REMOTE" "match remote flag"
  validate_err "$reg" beta /srv/mates/beta >/dev/null || fail "remote binding with expected home"
  assert_equals ssh:box-1:/srv/mates/beta "$SECONDMATE_REGISTRY_MATCH_HOME_KEY" "remote key"
  assert_equals box-1 "$SECONDMATE_REGISTRY_MATCH_HOST" "match host"
  assert_equals /opt/fm "$SECONDMATE_REGISTRY_MATCH_ROOT" "match root"
  assert_equals 1 "$SECONDMATE_REGISTRY_MATCH_REMOTE" "remote match flag"
  validate_err "$reg" alpha /srv/mates/alpha >/dev/null || fail "expected home equal"
  local err
  err=$(validate_err "$reg" alpha /srv/mates/other) && fail "expected home mismatch must refuse"
  assert_contains "$err" "is registered at /srv/mates/alpha, not /srv/mates/other" "mismatch message"
  err=$(validate_err "$reg" ghost) && fail "unbound id must refuse"
  assert_contains "$err" "no registry binding for secondmate ghost" "unbound message"
  err=$(validate_err "$reg" 'bad id') && fail "invalid expected id must refuse"
  assert_contains "$err" "invalid secondmate id" "invalid id message"
  pass "validate_bindings accepts good registries and reports exact matches"
}

expect_invalid() {  # <label> <expected-error-fragment> <lines...>
  local label=$1 want=$2 reg err
  shift 2
  reg=$(reg_file "inv-${label// /-}" "$@")
  err=$(validate_err "$reg") && fail "$label: must refuse"
  assert_contains "$err" "$want" "$label: error message"
}

test_validate_refusals() {
  expect_invalid "malformed entry" "malformed secondmate registry entry" '- alpha - broken'
  expect_invalid "relative home" "unsafe non-absolute secondmate home for a" \
    '- a - x (home: rel/h; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "unresolvable local home" "unresolvable secondmate home" \
    '- a - x (home: /unresolvable; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "bad ssh alias" "unsafe SSH host alias" \
    '- b - x (host: -oProxy; root: /r; home: /h; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "alias with space chars" "unsafe SSH host alias" \
    '- b - x (host: a b; root: /r; home: /h; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "relative remote root" "non-absolute remote root" \
    '- b - x (host: h; root: r; home: /h; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "root traversal" "code root contains traversal" \
    '- b - x (host: h; root: /a/../b; home: /h; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "home dot component" "remote home contains traversal" \
    '- b - x (host: h; root: /r; home: /a/./b; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "empty component" "empty path component" \
    '- b - x (host: h; root: /r; home: /a//b; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "root equals home" "overlapping remote root and home" \
    '- b - x (host: h; root: /same; home: /same; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "home inside root" "inside its code root" \
    '- b - x (host: h; root: /r; home: /r/home; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "root inside home" "inside its home" \
    '- b - x (host: h; root: /h/code; home: /h; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "tab in route" "unsafe secondmate route" \
    "- c - x (home: /h	x; scope: s; projects: p; added 2026-01-01)"
  expect_invalid "duplicate home" "duplicate secondmate home assignment" \
    '- a - x (home: /h; scope: s; projects: p; added 2026-01-01)' \
    '- b - x (home: /h; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "duplicate id on different homes" "duplicate secondmate id assignment" \
    '- a - x (home: /h1; scope: s; projects: p; added 2026-01-01)' \
    '- a - y (home: /h2; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "nested homes" "overlapping secondmate home assignment" \
    '- a - x (home: /h; scope: s; projects: p; added 2026-01-01)' \
    '- b - x (home: /h/inner; scope: s; projects: p; added 2026-01-01)'
  expect_invalid "nested remote homes on one host" "overlapping secondmate home assignment" \
    "- a - x (host: h; root: /r; home: /m; scope: s; projects: p; added 2026-01-01)" \
    "- b - x (host: h; root: /r; home: /m/n; scope: s; projects: p; added 2026-01-01)"
  local reg
  reg=$(reg_file same-path-two-hosts \
    "- a - x (host: h1; root: /r; home: /m; scope: s; projects: p; added 2026-01-01)" \
    "- b - x (host: h2; root: /r; home: /m; scope: s; projects: p; added 2026-01-01)")
  validate_err "$reg" >/dev/null || fail "the same path on different hosts is not a collision"
  validate_err "$TMP_ROOT/absent.md" >/dev/null && fail "absent registry refuses"
  assert_contains "$SECONDMATE_REGISTRY_ERROR" "unavailable or unsafe" "absent registry message"
  ln -s "$reg" "$TMP_ROOT/vlink.md"
  validate_err "$TMP_ROOT/vlink.md" >/dev/null && fail "symlinked registry refuses"
  pass "validate_bindings refuses every unsafe or colliding registration"
}

test_parse_local_and_remote
test_parse_rejections
test_lookup_and_fields
test_lock_paths_and_path_key
test_validate_accepts_and_matches
test_validate_refusals

echo '# all fm-secondmate-registry-lib tests passed'
