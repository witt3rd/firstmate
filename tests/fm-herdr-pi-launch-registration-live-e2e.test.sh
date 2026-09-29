#!/usr/bin/env bash
# Default-on live guard: a Pi started by Firstmate's Herdr launch line registers
# as a Herdr agent even when the pane shell does not job-control sourced
# commands, against the REAL Herdr and the REAL Pi.
#
# Herdr registers an agent only by probing the pane's foreground process group,
# and re-probes an agent-free pane only when that group changes or in a short
# window after its screen has been still. fish, or any shell with monitor mode
# off, runs a sourced `. '<file>'` agent inside the shell's own group, so an
# agent that starts after a busy launch and keeps redrawing is never probed:
# the pane reads agent-free for as long as the agent works, and its lifecycle
# hook reports are held back (docs/herdr-backend.md "Agent registration at
# launch"). The launch line fm-spawn.sh types on Herdr,
# fm_backend_herdr_launch_line, gives the agent its own foreground group.
#
# This guard reproduces that shape in two panes of one isolated lab session: a
# bash with monitor mode off (the fish shape, available everywhere), a launch
# that keeps the screen busy for longer than Herdr's acquisition window, then a
# real Pi whose screen never goes still. The pane started through the Herdr
# launch line must register `pi`; the pane started through the plain source line
# is the control, and whether this Herdr release still misses it is reported
# rather than asserted, so a vendor fix does not fail the guard. It fails naming
# both versions when the launch line no longer registers Pi.
#
# Pi runs with an empty scratch agent directory and no prompt, so no model token
# is spent and the shared live gate runs it by default wherever the tools are
# installed. Every Herdr call goes through bin/fm-herdr-lab.sh on a named,
# throwaway lab session, never the default one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HERDR_PI_LAUNCH_REGISTRATION_LIVE_E2E herdr pi jq bash

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION, pi $PI_VERSION]"
}

LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB_HELPER" name pi-launch-reg) || fail "could not generate an isolated Herdr lab session name"
TMP_ROOT=$(fm_test_tmproot fm-herdr-pi-launch-reg)
cleanup_all() {
  local rc=$?
  trap - EXIT
  "$LAB_HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_all EXIT
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab session"
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

PI_BIN=$(command -v pi)
mkdir -p "$TMP_ROOT/cwd" "$TMP_ROOT/pi-agent" "$TMP_ROOT/staged"

# Keeps Pi's screen changing every 150 ms, as a working agent's does, and grants
# session-only trust so no dialog is involved.
CHURN_EXT="$TMP_ROOT/churn-extension.ts"
cat > "$CHURN_EXT" <<'EOF'
export default function (pi: any) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("session_start", (_event: any, ctx: any) => {
    let tick = 0;
    setInterval(() => ctx.ui.setStatus("churn", `churn ${tick++}`), 150);
  });
}
EOF

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# A staged launch shaped like fm-spawn's: exports, a preamble that keeps the
# screen busy for 10 s (longer than Herdr's 8 s acquisition window), then Pi.
LAUNCH_FILE="$TMP_ROOT/staged/launch.s1.sh"
printf '%s\n' "export COMPACT_ADVISER_DISABLE=1; sh -c 'i=0; while [ \$i -lt 50 ]; do printf .; sleep 0.2; i=\$((i+1)); done; echo'; env -u CURSOR_AGENT PI_CODING_AGENT_DIR=$(sq "$TMP_ROOT/pi-agent") FM_PI_HARNESS=pi $(sq "$PI_BIN") --no-session --no-context-files --offline -e $(sq "$CHURN_EXT")" \
  > "$LAUNCH_FILE"

WS_OUT=$(lab workspace create --cwd "$TMP_ROOT/cwd" --label pi-launch-reg --no-focus) \
  || fail "could not create the lab workspace: $WS_OUT"
WS=$(printf '%s' "$WS_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$WS" ] || fail "workspace create returned no workspace id"

new_pane() {  # <label>
  lab tab create --workspace "$WS" --cwd "$TMP_ROOT/cwd" --label "$1" --no-focus \
    | jq -r '.result.root_pane.pane_id // empty'
}
FIXED_PANE=$(new_pane launch-line)
CONTROL_PANE=$(new_pane plain-source)
[ -n "$FIXED_PANE" ] && [ -n "$CONTROL_PANE" ] || fail "could not create the two lab panes"

# The pane shell with no job control for sourced commands: a nested bash with
# monitor mode turned off after startup (an interactive bash re-enables it past
# a `+m` flag, so it is switched off at the prompt).
for pane in "$FIXED_PANE" "$CONTROL_PANE"; do
  lab pane run "$pane" 'bash --norc --noprofile' >/dev/null || fail "could not start the nested bash in $pane"
done
sleep 1
for pane in "$FIXED_PANE" "$CONTROL_PANE"; do
  lab pane run "$pane" 'set +m' >/dev/null || fail "could not turn job control off in $pane"
done
sleep 0.5

type_line() {  # <pane> <line>
  lab pane send-text "$1" "$2" >/dev/null || fail "could not type the launch line into $1"
  lab pane send-keys "$1" Enter >/dev/null || fail "could not submit the launch line in $1"
}
type_line "$FIXED_PANE" "$(fm_backend_herdr_launch_line "$LAUNCH_FILE")"
type_line "$CONTROL_PANE" ". $(sq "$LAUNCH_FILE")"

registered_agent() {  # <pane>
  lab pane get "$1" 2>/dev/null | jq -r '.result.pane.agent // empty' 2>/dev/null
}
foreground() {  # <pane>
  lab pane process-info --pane "$1" 2>/dev/null \
    | jq -c '[.result.process_info.foreground_processes[]? | {name, argv0}]' 2>/dev/null
}

FIXED_AGENT=
for _ in $(seq 1 150); do
  FIXED_AGENT=$(registered_agent "$FIXED_PANE")
  [ "$FIXED_AGENT" = pi ] && break
  sleep 0.2
done
[ "$FIXED_AGENT" = pi ] || version_fail \
  "a Pi started through the Herdr launch line from a shell without job control never registered (pane agent '${FIXED_AGENT:-none}' after 30 s, foreground $(foreground "$FIXED_PANE")); fm_backend_herdr_launch_line no longer puts the agent in a foreground group Herdr probes"
note_line="pi $PI_VERSION under herdr $HERDR_VERSION: launch-line pane registered pi, foreground $(foreground "$FIXED_PANE")"
printf '# %s\n' "$note_line"
pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a Pi started through the Herdr launch line registers as an agent even when the pane shell has no job control"

# The control pane started at the same moment. Give it the same budget again
# before reading it, so a miss here is a real miss, not a slower start.
sleep 10
CONTROL_AGENT=$(registered_agent "$CONTROL_PANE")
if [ -z "$CONTROL_AGENT" ]; then
  printf '# herdr %s still leaves a sourced, continuously redrawing Pi unregistered under a shell without job control (foreground %s): the launch line is what registers it\n' \
    "$HERDR_VERSION" "$(foreground "$CONTROL_PANE")"
else
  printf '# herdr %s now registers the plain sourced Pi too (agent %s): the launch line is no longer the only thing registering it\n' \
    "$HERDR_VERSION" "$CONTROL_AGENT"
fi
