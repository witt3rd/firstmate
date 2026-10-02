#!/usr/bin/env bash
# tests/fm-sibling.test.sh - FORK-ONLY EXPERIMENT: sibling notes
# (bin/fm-sibling.sh, bin/fm-sibling-lib.sh, docs/sibling-notes.md).
#
# Drives the real command over stubbed tmux and pins:
#   1. flag off (absent or anything but "on") refuses and writes nothing;
#   2. a crewmate or scout notes a sibling of the SAME home: durable inbox
#      record marked as a sibling note without authority, doorbell rung on the
#      target only, and the parent copied on the SENDER's status file;
#   3. everything else is refused and writes nothing: self, the parent, an
#      unregistered or cross-parent worker, the other kind, an empty note, a
#      caller that is not a registered worker;
#   4. the same holds for secondmates against the primary's registry, including
#      a secondmate registered under a different primary and a remote one;
#   5. the per-sender, per-pair, and ping-pong limits, and window expiry;
#   6. with the flag off every generated brief is byte-identical to one without
#      the flag, and with it on only the sibling section is added;
#   7. the flag is in the inherited-config set that reaches secondmate homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIBLING="$ROOT/bin/fm-sibling.sh"
TMP_ROOT=$(fm_test_tmproot fm-sibling)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\t%s\n' "${target:-}" "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf 'claude\n'; exit 0 ;;
        *pane_tty*) printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-a fm-b fm-c fm-s fm-sm1 fm-sm2 fm-x; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
export FM_SEND_LOG="$TMP_ROOT/send.log"
: > "$FM_SEND_LOG"

write_meta() {  # <state> <id> <kind>
  mkdir -p "$1"
  printf 'window=fm-%s\nkind=%s\nharness=claude\nbackend=tmux\n' "$2" "$3" > "$1/$2.meta"
}

# A primary home with crewmates a, b, scout s, secondmates sm1 and sm2 (local),
# sm3 (remote), and a flag set by the caller.
make_primary() {  # <dir> <flag|none>
  local p=$1 flag=$2
  mkdir -p "$p/state" "$p/data" "$p/config"
  write_meta "$p/state" a ship
  write_meta "$p/state" b ship
  write_meta "$p/state" s scout
  write_meta "$p/state" sm1 secondmate
  write_meta "$p/state" sm2 secondmate
  printf 'window=fm-sm3\nkind=secondmate\nharness=claude\nbackend=tmux\nremote_host=far\n' > "$p/state/sm3.meta"
  : > "$p/data/secondmates.md"
  local id
  for id in sm1 sm2; do
    mkdir -p "$p/homes/$id/state" "$p/homes/$id/config"
    printf '%s' "$id" > "$p/homes/$id/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$p" > "$p/homes/$id/.fm-secondmate-parent"
    printf -- '- %s - test mate (home: %s; scope: test; projects: none; added 2026-01-01)\n' "$id" "$p/homes/$id" >> "$p/data/secondmates.md"
    [ "$flag" = none ] || printf '%s\n' "$flag" > "$p/homes/$id/config/sibling-notes"
  done
  printf -- '- sm3 - far mate (host: far; root: /r; home: /h; scope: test; projects: none; added 2026-01-01)\n' >> "$p/data/secondmates.md"
  [ "$flag" = none ] || printf '%s\n' "$flag" > "$p/config/sibling-notes"
  : > "$p/state/a.status"
  : > "$p/state/b.status"
  : > "$p/state/sm1.status"
  : > "$p/state/sm2.status"
  return 0
}

# Run the command as a crewmate of <home> (FM_TASK_ID set) or as the home's
# secondmate (no task id). Prints combined output; returns its exit code.
sib() {  # <home> <task-id|-> <args...>
  local home=$1 tid=$2
  shift 2
  if [ "$tid" = - ]; then
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_TASK_ID PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$SIBLING" "$@" 2>&1
  else
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_TASK_ID="$tid" "$SIBLING" "$@" 2>&1
  fi
}

count_records() {  # <inbox-dir>
  local n=0 f
  for f in "$1"/*.msg; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

# Nothing may have been written for a refused note.
assert_nothing_written() {  # <state-dir> <why>
  local st=$1 why=$2 d
  for d in "$st"/*.inbox; do
    [ -e "$d" ] || continue
    [ "$(count_records "$d")" -eq 0 ] || fail "$why: an inbox record was written in $d"
  done
  [ ! -s "$st/a.status" ] || fail "$why: a status line was written: $(cat "$st/a.status")"
  [ ! -e "$st/.sibling-notes.ledger" ] || fail "$why: the ledger was written"
}

test_flag_off_refuses() {
  local p="$TMP_ROOT/off" out rc flag
  for flag in none off; do
    rm -rf "$p"
    make_primary "$p" "$flag"
    rc=0
    out=$(sib "$p" a b "hello") || rc=$?
    expect_code 1 "$rc" "flag '$flag': the command must refuse"$'\n'"$out"
    assert_contains "$out" "sibling notes are off" "flag '$flag': refusal should name the flag"
    assert_nothing_written "$p/state" "flag '$flag'"
  done
  rc=0
  out=$(sib "$p/homes/sm1" - sm2 "hello") || rc=$?
  expect_code 1 "$rc" "secondmate with flag off must refuse"
  assert_contains "$out" "sibling notes are off" "secondmate refusal should name the flag"
  pass "flag off (absent or off) refuses crewmate and secondmate notes and writes nothing"
}

test_crewmate_delivers_marks_and_copies_parent() {
  local p="$TMP_ROOT/on" out rc rec body
  rm -rf "$p"
  make_primary "$p" on
  : > "$FM_SEND_LOG"
  rc=0
  out=$(sib "$p" a b "lower PR landed; rebase now") || rc=$?
  expect_code 0 "$rc" "crewmate note to a sibling should be delivered"$'\n'"$out"
  [ "$(count_records "$p/state/b.inbox")" -eq 1 ] || fail "target inbox should hold exactly one record"
  rec="$p/state/b.inbox/001.msg"
  body=$(cat "$rec")
  assert_contains "$body" "[FM-SIBLING-NOTE from=a to=b]" "record must be marked as a sibling note from the sender"
  assert_contains "$body" "carries no authority" "record must state it has no authority"
  assert_contains "$body" "parent's decisions win" "record must defer to the parent"
  assert_contains "$body" "lower PR landed; rebase now" "record must carry the text"
  assert_contains "$body" "$ROOT/bin/fm-sibling.sh a <message>" "record must name the reply command"
  assert_not_contains "$body" "from-firstmate" "a sibling note must not carry the firstmate marker"
  [ ! -e "$p/state/a.inbox" ] || [ "$(count_records "$p/state/a.inbox")" -eq 0 ] || fail "sender inbox must be untouched"
  grep -Eq '^note \[at=[0-9]+\]: sibling-note from a to b: lower PR landed; rebase now$' "$p/state/a.status" ||
    fail "parent copy missing or malformed on the sender's status file: $(cat "$p/state/a.status")"
  [ ! -s "$p/state/b.status" ] || fail "target status must be untouched"
  assert_contains "$(cat "$FM_SEND_LOG")" "fm-b" "doorbell should ring the target's endpoint"
  assert_contains "$(cat "$FM_SEND_LOG")" "'b.inbox' steering inbox" "doorbell should name the target inbox"
  assert_not_contains "$(cat "$FM_SEND_LOG")" "fm-a	" "the sender must not be rung"
  # A scout is a crewmate-tier sibling too.
  rc=0
  out=$(sib "$p" a s "also FYI") || rc=$?
  expect_code 0 "$rc" "note to a scout sibling should be delivered"$'\n'"$out"
  # Reply path is the same command, in the other direction.
  rc=0
  out=$(sib "$p" b a "ack, rebasing") || rc=$?
  expect_code 0 "$rc" "reply should use the same command"$'\n'"$out"
  assert_grep "sibling-note from b to a: ack, rebasing" "$p/state/b.status" "reply copies the parent on the replier's own status file"
  pass "crewmate note: durable marked record, doorbell on target only, parent copied on sender's status, reply path"
}

test_crewmate_refusals_write_nothing() {
  local p="$TMP_ROOT/refuse" other="$TMP_ROOT/refuse-other" out rc
  rm -rf "$p" "$other"
  make_primary "$p" on
  make_primary "$other" on
  write_meta "$other/state" x ship
  # An id that exists only under another parent must not resolve here.
  rc=0; out=$(sib "$p" a x "hi") || rc=$?
  expect_code 1 "$rc" "cross-parent target must be refused"
  assert_contains "$out" "not a registered worker under your parent" "cross-parent refusal reason"
  rc=0; out=$(sib "$p" a a "hi") || rc=$?
  expect_code 1 "$rc" "self must be refused"; assert_contains "$out" "refusing to note yourself" "self refusal reason"
  rc=0; out=$(sib "$p" a firstmate "hi") || rc=$?
  expect_code 1 "$rc" "the parent must be refused"
  rc=0; out=$(sib "$p" a sm1 "hi") || rc=$?
  expect_code 1 "$rc" "a crewmate must not note a secondmate"
  assert_contains "$out" "not a sibling crewmate" "kind refusal reason"
  rc=0; out=$(sib "$p" a "../b" "hi") || rc=$?
  expect_code 1 "$rc" "a path-shaped target must be refused"
  rc=0; out=$(sib "$p" a b "   ") || rc=$?
  expect_code 1 "$rc" "an empty note must be refused"
  rc=0; out=$(sib "$p" ghost b "hi") || rc=$?
  expect_code 1 "$rc" "an unregistered caller must be refused"
  assert_contains "$out" "no task record" "unregistered caller reason"
  rc=0; out=$(sib "$p" - b "hi") || rc=$?
  expect_code 1 "$rc" "the main home (no task, no secondmate identity) must be refused"
  rc=0; out=$(sib "$p" sm1 b "hi") || rc=$?
  expect_code 1 "$rc" "a secondmate task record is not a crewmate caller"
  assert_nothing_written "$p/state" "crewmate refusals"
  assert_nothing_written "$other/state" "crewmate refusals (other parent)"
  pass "crewmate refusals: cross-parent, self, parent, other kind, bad id, empty note, unregistered caller"
}

test_secondmate_siblings() {
  local p="$TMP_ROOT/mates" other="$TMP_ROOT/mates-other" out rc rec
  rm -rf "$p" "$other"
  make_primary "$p" on
  make_primary "$other" on
  # sm9 is registered only under the other primary.
  write_meta "$other/state" sm9 secondmate
  printf -- '- sm9 - x (home: %s; scope: t; projects: none; added 2026-01-01)\n' "$other/homes/sm9" >> "$other/data/secondmates.md"
  rc=0
  out=$(sib "$p/homes/sm1" - sm2 "need your schema before I rebase") || rc=$?
  expect_code 0 "$rc" "secondmate note to a registered sibling should be delivered"$'\n'"$out"
  rec="$p/state/sm2.inbox/001.msg"
  [ -f "$rec" ] || fail "record should land in the primary's steering inbox for sm2"
  assert_contains "$(cat "$rec")" "[FM-SIBLING-NOTE from=sm1 to=sm2]" "secondmate record marker"
  assert_not_contains "$(cat "$rec")" "from-firstmate" "no firstmate marker on a sibling note"
  assert_grep "sibling-note from sm1 to sm2: need your schema before I rebase" "$p/state/sm1.status" \
    "parent copy lands on the secondmate's parent channel"
  assert_contains "$(cat "$FM_SEND_LOG")" "fm-sm2" "doorbell should ring the sibling secondmate"
  # Refusals.
  rc=0; out=$(sib "$p/homes/sm1" - sm9 "x") || rc=$?
  expect_code 1 "$rc" "a secondmate registered under another primary must be refused"
  assert_contains "$out" "not a secondmate registered under your parent" "cross-parent secondmate reason"
  rc=0; out=$(sib "$p/homes/sm1" - a "x") || rc=$?
  expect_code 1 "$rc" "a secondmate must not note a crewmate"
  rc=0; out=$(sib "$p/homes/sm1" - sm1 "x") || rc=$?
  expect_code 1 "$rc" "a secondmate must not note itself"
  rc=0; out=$(sib "$p/homes/sm1" - sm3 "x") || rc=$?
  expect_code 1 "$rc" "a remote secondmate must be refused"
  assert_contains "$out" "remote" "remote refusal reason"
  [ "$(count_records "$p/state/sm3.inbox")" -eq 0 ] || fail "no record for the remote target"
  [ "$(count_records "$p/state/a.inbox")" -eq 0 ] || fail "no record for a crewmate target"
  [ "$(count_records "$other/state/sm9.inbox")" -eq 0 ] || fail "no record under the other primary"
  # A home whose registry entry names a different home is not that secondmate.
  printf -- '- sm1 - t (home: %s; scope: t; projects: none; added 2026-01-01)\n' "$TMP_ROOT/elsewhere" > "$p/data/secondmates.md"
  printf -- '- sm2 - t (home: %s; scope: t; projects: none; added 2026-01-01)\n' "$p/homes/sm2" >> "$p/data/secondmates.md"
  rc=0; out=$(sib "$p/homes/sm1" - sm2 "x") || rc=$?
  expect_code 1 "$rc" "a home not matching its registry entry must be refused"
  # A remote parent route is not supported.
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$p/homes/sm2/.fm-secondmate-parent"
  rc=0; out=$(sib "$p/homes/sm2" - sm1 "x") || rc=$?
  expect_code 1 "$rc" "a remote parent route must be refused"
  pass "secondmate notes: same-primary registry proof, parent copy, cross-primary/remote/kind/self refused"
}

test_limits() {
  local p="$TMP_ROOT/limits" out rc
  rm -rf "$p"
  make_primary "$p" on
  # Per-sender limit.
  rc=0
  out=$(FM_SIBLING_LIMITS='window=600 sender=2 pair=50 alternation=50' sib "$p" a b "1") || rc=$?
  expect_code 0 "$rc" "first note within the sender limit"$'\n'"$out"
  out=$(FM_SIBLING_LIMITS='window=600 sender=2 pair=50 alternation=50' sib "$p" a s "2") || rc=$?
  out=$(FM_SIBLING_LIMITS='window=600 sender=2 pair=50 alternation=50' sib "$p" a b "3") && rc=0 || rc=$?
  expect_code 1 "$rc" "third note exceeds the per-sender limit"
  assert_contains "$out" "rate limit" "per-sender refusal reason"
  [ "$(count_records "$p/state/b.inbox")" -eq 1 ] || fail "refused note must not be recorded"

  # Per-pair limit counts both directions (an answer counts against it).
  rm -rf "$p"; make_primary "$p" on
  local lim='window=600 sender=50 pair=3 alternation=50'
  FM_SIBLING_LIMITS=$lim sib "$p" a b "1" >/dev/null
  FM_SIBLING_LIMITS=$lim sib "$p" b a "2" >/dev/null
  FM_SIBLING_LIMITS=$lim sib "$p" a b "3" >/dev/null
  rc=0; out=$(FM_SIBLING_LIMITS=$lim sib "$p" b a "4") || rc=$?
  expect_code 1 "$rc" "fourth note between the pair exceeds the pair limit"
  assert_contains "$out" "rate limit" "pair refusal reason"
  rc=0; out=$(FM_SIBLING_LIMITS=$lim sib "$p" a s "other pair is unaffected") || rc=$?
  expect_code 0 "$rc" "another pair is not limited by this pair"$'\n'"$out"

  # Ping-pong: note, answer, answer-to-the-answer is refused by default limits.
  rm -rf "$p"; make_primary "$p" on
  rc=0; sib "$p" a b "q" >/dev/null || rc=$?; expect_code 0 "$rc" "ping 1"
  rc=0; sib "$p" b a "answer" >/dev/null || rc=$?; expect_code 0 "$rc" "a note and its answer are allowed"
  rc=0; out=$(sib "$p" a b "answer to the answer") || rc=$?
  expect_code 1 "$rc" "a third alternating note is a ping-pong and is refused"
  assert_contains "$out" "loop guard" "ping-pong refusal reason"
  [ "$(count_records "$p/state/b.inbox")" -eq 1 ] || fail "ping-pong note must not be recorded"
  # The same sender repeating itself is not an alternation.
  rc=0; sib "$p" b a "follow-up from the same side" >/dev/null || rc=$?
  expect_code 0 "$rc" "same-direction follow-up is not a ping-pong"

  # Window expiry: old ledger entries stop counting and are pruned.
  rm -rf "$p"; make_primary "$p" on
  printf '%s\ta\tb\n%s\tb\ta\n' "$(( $(date +%s) - 100000 ))" "$(( $(date +%s) - 99999 ))" > "$p/state/.sibling-notes.ledger"
  rc=0; sib "$p" a b "fresh" >/dev/null || rc=$?
  expect_code 0 "$rc" "expired ledger entries must not count"
  [ "$(wc -l < "$p/state/.sibling-notes.ledger")" -eq 1 ] || fail "expired entries should be pruned from the ledger"
  pass "limits: per-sender, per-pair (answers count), ping-pong, same-direction, window expiry"
}

# Generate one brief kind and print its bytes; the home is reused so every path
# in the text is identical between variants.
gen_brief() {  # <home> <id> <kind>
  local home=$1 id=$2 kind=$3
  rm -rf "$home/data/$id"
  mkdir -p "$home/data"
  case "$kind" in
    ship) env FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" repo --mode no-mistakes >/dev/null ;;
    scout) env FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" repo --scout >/dev/null ;;
    secondmate) env FM_HOME="$home" FM_SECONDMATE_CHARTER='test charter' "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null ;;
  esac || return 1
  cat "$home/data/$id/brief.md"
}

test_briefs() {
  local home="$TMP_ROOT/briefs" kind off absent on added removed
  rm -rf "$home"
  mkdir -p "$home/config" "$home/data"
  for kind in ship scout secondmate; do
    absent=$(gen_brief "$home" "t-$kind" "$kind") || fail "$kind brief failed without the flag"
    printf 'off\n' > "$home/config/sibling-notes"
    off=$(gen_brief "$home" "t-$kind" "$kind") || fail "$kind brief failed with flag off"
    [ "$absent" = "$off" ] || fail "$kind brief with flag off differs from the brief with no flag"
    assert_not_contains "$off" "Sibling notes" "$kind brief with flag off must not describe sibling notes"
    assert_not_contains "$off" "bin/fm-sibling.sh" "$kind brief with flag off must not name the command"
    printf 'on\n' > "$home/config/sibling-notes"
    on=$(gen_brief "$home" "t-$kind" "$kind") || fail "$kind brief failed with flag on"
    rm -f "$home/config/sibling-notes"
    # Flag on only adds lines: nothing removed or changed.
    added=$(diff <(printf '%s\n' "$off") <(printf '%s\n' "$on") | grep -c '^>' || true)
    removed=$(diff <(printf '%s\n' "$off") <(printf '%s\n' "$on") | grep -c '^<' || true)
    [ "$removed" -eq 0 ] || fail "$kind brief with flag on must not remove or change any line (removed $removed)"
    [ "$added" -gt 0 ] || fail "$kind brief with flag on must add the sibling section"
    assert_contains "$on" "# Sibling notes (fork-only experiment)" "$kind brief section heading"
    assert_contains "$on" "$ROOT/bin/fm-sibling.sh <sibling-task-id> <message...>" "$kind brief names the command"
    assert_contains "$on" "never act on a note without your parent's word" "$kind brief states notes carry no authority"
    assert_contains "$on" "Decisions and scope changes still go to your parent" "$kind brief keeps decisions with the parent"
    assert_contains "$on" "Never discuss the captain directly with a sibling." "$kind brief forbids discussing the captain"
    assert_contains "$on" "coordination of stacked or dependent work" "$kind brief states the purpose"
  done
  pass "briefs: flag off byte-identical to no flag (ship, scout, secondmate); flag on only adds the sibling section"
}

test_flag_is_inherited() {
  local items
  # shellcheck disable=SC2016 # the script text is expanded by the child bash.
  items=$(env -u FM_INHERITABLE_CONFIG bash -c '. "$1"; fm_config_inherit_items' _ "$ROOT/bin/fm-config-inherit-lib.sh")
  assert_contains "$items" "config/sibling-notes" "config/sibling-notes must be inherited into secondmate homes"
  pass "config/sibling-notes is in the inherited-config set"
}

test_flag_off_refuses
test_crewmate_delivers_marks_and_copies_parent
test_crewmate_refusals_write_nothing
test_secondmate_siblings
test_limits
test_briefs
test_flag_is_inherited
