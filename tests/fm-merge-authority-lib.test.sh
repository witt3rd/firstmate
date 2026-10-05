#!/usr/bin/env bash
# Contract coverage for bin/fm-merge-authority-lib.sh: resolve (attended vs
# away vs unreadable), persist/read round-trip, identity mismatches,
# malformed or unsafe records read as external, and guarded removal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-authority-lib)
URL=https://github.com/octo/repo/pull/42

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$ROOT/bin/fm-merge-authority-lib.sh"

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  chmod 700 "$dir/home/state"
  printf 'pr=%s\n' "$URL" > "$dir/home/state/t1.meta"
  printf '%s\n' "$dir"
}

persist() {  # <case> [authority]
  fm_merge_authority_persist "$1/home/state" t1 "$1/home/state/t1.meta" \
    github github.com octo/repo 42 "${2:-attended}"
}

read_auth() {  # <case> [number]
  fm_merge_authority_read "$1/home/state" t1 github github.com octo/repo "${2:-42}"
}

test_resolve() {
  local c rc
  c=$(make_case resolve)
  fm_merge_authority_resolve "$c/home" "$c/home/state" "$c/home/state/t1.meta" t1 \
    || fail "resolve without a record failed"
  assert_equals attended "$FM_MERGE_AUTHORITY" "no record is attended"
  fm_merge_authority_resolve "" "$c/home/state" m t1 && fail "empty home accepted"
  assert_equals invalid "$FM_MERGE_AUTHORITY_REASON" "missing argument reason"
  assert_equals "" "$FM_MERGE_AUTHORITY" "invalid resolve leaves no authority"

  FM_HOME="$c/home" FM_STATE_OVERRIDE="$c/home/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge t1 when green' >/dev/null \
    || fail "could not write away record"
  fm_merge_authority_resolve "$c/home" "$c/home/state" "$c/home/state/t1.meta" t1 \
    || fail "resolve with away record failed"
  assert_equals away "$FM_MERGE_AUTHORITY" "away record is away authority"
  assert_equals away "$FM_MERGE_AUTHORITY_REASON" "away reason"

  rm -f "$c/home/state/.afk-contract"
  FM_AFK_MODE=quiet FM_HOME="$c/home" FM_STATE_OVERRIDE="$c/home/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null \
    || fail "could not write quiet record"
  grep -q '^mode: quiet' "$c/home/state/.afk-contract" || fail "record is not quiet"
  fm_merge_authority_resolve "$c/home" "$c/home/state" "$c/home/state/t1.meta" t1 \
    || fail "resolve with quiet record failed"
  assert_equals attended "$FM_MERGE_AUTHORITY" "quiet record is attended"

  printf 'not-a-contract\n' > "$c/home/state/.afk-contract"
  fm_merge_authority_resolve "$c/home" "$c/home/state" "$c/home/state/t1.meta" t1
  rc=$?
  assert_equals 1 "$rc" "unreadable record refuses"
  assert_equals record-unreadable "$FM_MERGE_AUTHORITY_REASON" "unreadable reason"
  assert_equals "" "$FM_MERGE_AUTHORITY" "unreadable record resolves to nothing"
  pass "resolve: attended, away, quiet, invalid args, unreadable record"
}

test_persist_read_round_trip() {
  local c rec
  c=$(make_case roundtrip)
  rec="$c/home/state/t1.merge-authority"
  persist "$c" away || fail "persist failed"
  assert_equals "fm-merge-authority-v1
github
github.com
octo/repo
42
away" "$(cat "$rec")" "record body"
  assert_equals -rw------- "$(stat -c %A "$rec" 2>/dev/null || stat -f %Sp "$rec")" "record mode"
  read_auth "$c" || fail "read failed"
  assert_equals away "$FM_MERGE_AUTHORITY" "read returns persisted authority"
  [ -n "$FM_MERGE_AUTHORITY_RECORD_IDENTITY" ] || fail "no file identity"
  ls "$c/home/state"/.fm-merge-authority.* >/dev/null 2>&1 && fail "temp file left behind"
  persist "$c" attended || fail "re-persist failed"
  read_auth "$c" || fail "re-read failed"
  assert_equals attended "$FM_MERGE_AUTHORITY" "re-persist replaces the record"
  pass "persist/read round-trip is private, atomic, and replaceable"
}

test_persist_refusals() {
  local c
  c=$(make_case refusals)
  persist "$c" yolo && fail "retired value must not be written"
  persist "$c" bogus && fail "unknown authority accepted"
  fm_merge_authority_persist "$c/home/state" 'bad id' "$c/home/state/t1.meta" \
    github github.com octo/repo 42 away && fail "bad task id accepted"
  fm_merge_authority_persist "$c/home/state" t1 "$c/home/state/t1.meta" \
    github github.com octo/repo 43 away && fail "number mismatch with meta accepted"
  fm_merge_authority_persist "$c/home/state" t1 "$c/home/state/t1.meta" \
    github github.com other/repo 42 away && fail "path mismatch with meta accepted"
  fm_merge_authority_persist "$c/home/state" t1 "$c/home/nometa" \
    github github.com octo/repo 42 away && fail "missing meta accepted"
  fm_merge_authority_persist "$c/nostate" t1 "$c/home/state/t1.meta" \
    github github.com octo/repo 42 away && fail "missing state dir accepted"
  ln -s "$c/home/state" "$c/linkstate"
  fm_merge_authority_persist "$c/linkstate" t1 "$c/home/state/t1.meta" \
    github github.com octo/repo 42 away && fail "symlinked state dir accepted"
  assert_absent "$c/home/state/t1.merge-authority" "refusals must not publish a record"
  pass "persist refuses retired/unknown authority, bad ids, mismatched identity, unsafe state"
}

test_read_treats_bad_records_as_external() {
  local c rec
  c=$(make_case badrecords)
  rec="$c/home/state/t1.merge-authority"
  read_auth "$c" && fail "absent record read ok"
  assert_equals external "$FM_MERGE_AUTHORITY" "absent record is external"

  persist "$c" away || fail "persist failed"
  read_auth "$c" 43 && fail "number mismatch read ok"
  assert_equals external "$FM_MERGE_AUTHORITY" "mismatch is external"
  assert_equals "" "$FM_MERGE_AUTHORITY_RECORD_IDENTITY" "mismatch yields no identity"

  chmod 644 "$rec"
  read_auth "$c" && fail "group/world readable record accepted"

  printf 'fm-merge-authority-v1\ngithub\ngithub.com\nocto/repo\n42\nwarp\n' > "$rec"
  chmod 600 "$rec"
  read_auth "$c" && fail "unknown authority value accepted"
  printf 'fm-merge-authority-v2\ngithub\ngithub.com\nocto/repo\n42\naway\n' > "$rec"
  read_auth "$c" && fail "wrong version accepted"
  printf 'fm-merge-authority-v1\ngithub\ngithub.com\nocto/repo\n42\naway\nextra\n' > "$rec"
  read_auth "$c" && fail "trailing line accepted"
  printf 'fm-merge-authority-v1\ngithub\n' > "$rec"
  read_auth "$c" && fail "truncated record accepted"
  assert_equals external "$FM_MERGE_AUTHORITY" "malformed is external"

  printf 'fm-merge-authority-v1\ngithub\ngithub.com\nocto/repo\n42\nyolo\n' > "$rec"
  read_auth "$c" || fail "retired yolo value must still be readable"
  assert_equals yolo "$FM_MERGE_AUTHORITY" "retired value read as recorded"
  printf 'fm-merge-authority-v1\ngithub\ngithub.com\nocto/repo\n42\naway-grant\n' > "$rec"
  read_auth "$c" || fail "retired away-grant value must still be readable"

  rm -f "$rec"
  ln -s "$c/elsewhere" "$rec"
  read_auth "$c" && fail "symlinked record accepted"
  rm -f "$rec"
  persist "$c" away || fail "persist failed"
  ln "$rec" "$c/hardlink"
  read_auth "$c" && fail "multi-link record accepted"
  pass "read maps absent, mismatched, unsafe, and malformed records to external"
}

test_remove_if_matches() {
  local c rec ident
  c=$(make_case remove)
  rec="$c/home/state/t1.merge-authority"
  persist "$c" away || fail "persist failed"
  read_auth "$c" || fail "read failed"
  ident=$FM_MERGE_AUTHORITY_RECORD_IDENTITY

  fm_merge_authority_remove_if_matches "$c/home/state" t1 github github.com octo/repo 42 \
    attended "$ident"
  assert_present "$rec" "wrong authority must keep the record"
  fm_merge_authority_remove_if_matches "$c/home/state" t1 github github.com octo/repo 42 \
    away "other-identity"
  assert_present "$rec" "wrong file identity must keep the record"
  fm_merge_authority_remove_if_matches "$c/home/state" t1 github github.com octo/repo 43 \
    away "$ident"
  assert_present "$rec" "other PR identity must keep the record"
  fm_merge_authority_remove_if_matches "$c/home/state" t1 github github.com octo/repo 42 \
    away "$ident" || fail "exact match removal failed"
  assert_absent "$rec" "exact match removes the record"
  fm_merge_authority_remove_if_matches "$c/home/state" t1 github github.com octo/repo 42 \
    away "$ident" || fail "removing an absent record must succeed"
  assert_absent "$rec.lock" "lock released"

  persist "$c" away || fail "persist failed"
  chmod 644 "$rec"
  fm_merge_authority_remove_if_matches "$c/home/state" t1 github github.com octo/repo 42 \
    away "$ident" && fail "unsafe record removal reported success"
  assert_present "$rec" "unsafe record is left in place"
  pass "guarded removal needs authority, file identity, and PR identity to all match"
}

test_resolve
test_persist_read_round_trip
test_persist_refusals
test_read_treats_bad_records_as_external
test_remove_if_matches

echo '# all fm-merge-authority-lib tests passed'
