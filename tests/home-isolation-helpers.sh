#!/usr/bin/env bash
# tests/home-isolation-helpers.sh - run a suite under a temporary HOME so its
# fixtures leave nothing in the operator's real home.
#
# Source it from a suite runner and call fm_test_home_enter / fm_test_home_leave,
# or source tests/lib.sh, which does both for every suite that reaches it.
#
# Why: tools a fixture drives for real (treehouse above all) write pool
# directories, slot records and caches under $HOME. A suite that ran the real
# treehouse against a fixture repository left a pool of slot records in
# ~/.treehouse every run (112 test pools and 621 slot records had piled up), and
# the stock cleanup never reached them because nothing owned them. With HOME
# pointing at a directory the suite itself removes on exit, a fixture cannot
# leave a pool record, a slot, or a cache behind.
#
# FM_TEST_REAL_HOME keeps the operator's home for the one thing that must see it:
# a live-harness guard (tests/lib.sh fm_live_gate restores it before it lets a
# live run proceed). FM_TEST_KEEP_HOME=1 opts a hand run out entirely.
# tests/fm-test-fixtures.test.sh is the regression.

# fm_test_home_enter: point HOME at a fresh directory under the test tmp dir.
# Idempotent: a suite started by an already-isolating runner keeps that home.
# Sets FM_TEST_FAKE_HOME to the directory it made (empty when it made none).
fm_test_home_enter() {
  FM_TEST_FAKE_HOME=
  [ -z "${FM_TEST_HOME_ISOLATED:-}" ] || return 0
  [ "${FM_TEST_KEEP_HOME:-0}" != 1 ] || return 0
  local base=${TMPDIR:-/tmp}
  base=${base%/}
  [ -d "$base" ] || base=/tmp
  FM_TEST_FAKE_HOME=$(mktemp -d "$base/fm-test-home.XXXXXX") || return 1
  FM_TEST_REAL_HOME=${FM_TEST_REAL_HOME:-${HOME:-}}
  export FM_TEST_REAL_HOME
  HOME=$FM_TEST_FAKE_HOME
  export HOME
  FM_TEST_HOME_ISOLATED=1
  export FM_TEST_HOME_ISOLATED
}

# fm_test_home_leave: remove the home fm_test_home_enter made, if any. The temp
# home can hold read-only directories (a git object store), so open them first.
fm_test_home_leave() {
  [ -n "${FM_TEST_FAKE_HOME:-}" ] || return 0
  if [ -d "$FM_TEST_FAKE_HOME" ] && [ ! -L "$FM_TEST_FAKE_HOME" ]; then
    find "$FM_TEST_FAKE_HOME" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    rm -rf "$FM_TEST_FAKE_HOME"
  fi
  FM_TEST_FAKE_HOME=
}
