#!/usr/bin/env bash
# Regression: a relaunch must not duplicate tmux_socket= in the task meta.
# fm-spawn.sh writes tmux_socket= itself, so preserve_relaunch_meta must
# treat it as an owned key and drop the prior record's copy.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-spawn-relaunch-tmux-socket)
RELAUNCH_META="$TMP/x.meta"
printf 'window=a\ntmux_socket=/run/s\nremote_host=h\nbackend=tmux\n' > "$RELAUNCH_META"

# Replay the append: preserved lines followed by the fresh write.
eval "$(sed -n '/^preserve_relaunch_meta() {/,/^}/p' "$ROOT/bin/fm-spawn.sh")"
{ preserve_relaunch_meta; echo "tmux_socket=/run/s"; } > "$TMP/out.meta"

n=$(grep -c '^tmux_socket=' "$TMP/out.meta")
[ "$n" = 1 ] || fail "expected exactly one tmux_socket= line, got $n"
grep -q '^remote_host=h$' "$TMP/out.meta" || fail "unowned key remote_host not preserved"
pass "relaunch keeps a single tmux_socket= line"
