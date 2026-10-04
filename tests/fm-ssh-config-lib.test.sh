#!/usr/bin/env bash
# Behavior tests for bin/fm-ssh-config-lib.sh Host-line alias matching.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-ssh-config-lib)
mkdir -p "$TMP_ROOT"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
# shellcheck source=bin/fm-ssh-config-lib.sh
. "$ROOT/bin/fm-ssh-config-lib.sh"

CFG="$TMP_ROOT/config"
printf 'Host alpha beta\n  HostName 10.0.0.1\n\nhost=gamma delta # trailing delta2\r\nHOST wild* !neg ok\nHost solo\n' > "$CFG"

same() { fm_ssh_config_same_host "$CFG" "$1" "$2"; }

test_identical_names_match_without_a_file() {
  fm_ssh_config_same_host "$TMP_ROOT/absent" x x || fail "identical names should match even with no config"
  pass "identical names always match"
}

test_aliases_on_one_host_line_match() {
  same alpha beta || fail "alpha and beta share a Host line"
  same beta alpha || fail "matching should be symmetric"
  same gamma delta || fail "case-insensitive keyword with '=' separator should list both"
  pass "aliases on one Host line match"
}

test_non_aliases_do_not_match() {
  same alpha gamma && fail "tokens on different Host lines must not match"
  same alpha solo && fail "a single-token stanza is not an alias of another"
  same delta delta2 && fail "a token after # is a comment, not an alias"
  same wild-x ok && fail "wildcard patterns never match a name"
  same neg ok && fail "negated patterns never match a name"
  pass "names on different lines, comments, wildcards and negations do not match"
}

test_missing_or_unreadable_config_does_not_match() {
  fm_ssh_config_same_host "$TMP_ROOT/absent" a b && fail "a missing config cannot alias distinct names"
  pass "a missing config yields no match for distinct names"
}

test_identical_names_match_without_a_file
test_aliases_on_one_host_line_match
test_non_aliases_do_not_match
test_missing_or_unreadable_config_does_not_match

echo "# all fm-ssh-config-lib tests passed"
