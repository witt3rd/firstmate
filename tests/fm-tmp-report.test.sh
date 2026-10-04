#!/usr/bin/env bash
# Tests for bin/fm-tmp-report.sh (scratch size report).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d); trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
mkdir -p "$T/tmp/fm-live/gotmp" "$T/tmp/fm-orphan" "$T/state"
head -c 4096 /dev/zero > "$T/tmp/fm-orphan/blob"
printf 'tasktmp=%s\n' "$T/tmp/fm-live" > "$T/state/live.meta"
run() { FM_TMP_ROOT="$T/tmp" FM_STATE_OVERRIDE="$T/state" FM_TMP_WARN_PCT=${1:-101} "$ROOT/bin/fm-tmp-report.sh"; }

out=$(run) || fail "nonzero exit"
echo "$out" | grep -q "fm-orphan.*unreferenced" || fail "orphan not flagged: $out"
echo "$out" | grep "fm-live" | grep -q unreferenced && fail "live dir flagged"
pass "flags only unreferenced scratch dirs"

[ -d "$T/tmp/fm-orphan" ] || fail "report deleted something"
pass "read-only"

out=$(run 0) || fail "nonzero exit"
echo "$out" | grep -q "WARNING" || fail "no warning at 0% threshold: $out"
pass "warns above threshold"

rm -rf "$T/tmp"/fm-*; mkdir -p "$T/tmp"
out=$(run) || fail "nonzero exit"
[ -z "$out" ] || fail "expected silence: $out"
pass "silent when clean"
