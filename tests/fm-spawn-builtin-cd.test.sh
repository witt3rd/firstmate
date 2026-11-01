#!/usr/bin/env bash
# The launcher must type `builtin cd --` so a shell whose cd is a wrapper
# rejecting `--` (zoxide) still lands in the worktree.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
grep -n 'spawn_send_text_line .*"cd ' "$SPAWN" && fail "a pane cd still bypasses builtin"
[ "$(grep -c 'spawn_send_text_line .*"builtin cd -- ' "$SPAWN")" -ge 2 ] || fail "builtin cd not typed"
d=$(mktemp -d "${TMPDIR:-/tmp}/fmcd.XXXXXX") || fail "mktemp"
trap 'rm -rf "$d"; fm_test_cleanup || true' EXIT
out=$(bash --norc -c 'cd() { [ "$1" = -- ] && { echo bad; return 1; }; builtin cd "$@"; }
builtin cd -- "$1" && pwd -P' _ "$d") || fail "builtin cd failed under rejecting wrapper"
[ "$out" = "$(cd "$d" && pwd -P)" ] || fail "did not land in dir"
echo ok
