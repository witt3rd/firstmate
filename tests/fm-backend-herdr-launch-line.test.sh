#!/usr/bin/env bash
# tests/fm-backend-herdr-launch-line.test.sh - portable regression for the line
# bin/fm-spawn.sh types into a Herdr pane to start a staged launch file
# (bin/backends/herdr.sh fm_backend_herdr_launch_line).
#
# Herdr registers an agent only by probing the pane's foreground process group,
# so the agent must take the terminal foreground as its OWN process group when
# it starts (docs/herdr-backend.md "Agent registration at launch"). A pane shell
# that does not job-control sourced commands - fish, or any shell with monitor
# mode off - runs a sourced `. '<file>'` agent inside the shell's own group, and
# Herdr never notices it. This suite runs the real typed line from exactly such
# a shell inside a real pseudo-terminal, with a stand-in agent that reports its
# own process group and the terminal's foreground group, so the guarantee is
# proven with real processes and no Herdr. The counterfactual `. '<file>'` line
# runs from the same shell and must still share the shell's group, so the case
# can never pass vacuously. The real-Herdr, real-Pi half of the proof is
# tests/fm-herdr-pi-launch-registration-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (the pty driver needs it)"; exit 0; }
[ -x /bin/sh ] || { echo "skip: /bin/sh not found"; exit 0; }
command -v bash >/dev/null 2>&1 || { echo "skip: bash not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-launch-line)

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

# The stand-in agent: records "<pid> <pgid> <terminal foreground pgid>" and
# exits with the status its caller asked for, so status propagation is checked
# too.
AGENT="$TMP_ROOT/agent"
cat > "$AGENT" <<'PY'
#!/usr/bin/env python3
import os, sys
fd = os.open("/dev/tty", os.O_RDONLY)
with open(os.environ["FM_TEST_AGENT_OUT"], "a") as out:
    out.write("%d %d %d\n" % (os.getpid(), os.getpgrp(), os.tcgetpgrp(fd)))
sys.exit(int(os.environ.get("FM_TEST_AGENT_STATUS", "0")))
PY
chmod +x "$AGENT"

# The pty driver: the child becomes a session leader holding a fresh terminal
# as its foreground group, exactly like a Herdr pane's top shell, then runs
# <argv...>. Output is drained until the child exits; its status is returned.
PTY="$TMP_ROOT/pty.py"
cat > "$PTY" <<'PY'
import os, sys
pid, master = os.forkpty()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
while True:
    try:
        if not os.read(master, 4096):
            break
    except OSError:
        break
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8))
PY

# stage_launch <dir> <agent-status>: a staged launch file shaped like the ones
# fm-spawn writes (exports, then an env-prefixed agent command), in a directory
# whose name carries a space and a single quote so the line's quoting is real.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
stage_launch() {  # <dir> <agent-status>
  local dir=$1 status=$2 file
  mkdir -p "$dir"
  file="$dir/launch.s1.sh"
  printf 'export COMPACT_ADVISER_DISABLE=1; env -u CURSOR_AGENT FM_TEST_AGENT_STATUS=%s FM_TEST_AGENT_OUT=%s %s --tui-mode regular\n' \
    "$status" "$(sq "$dir/agent.out")" "$(sq "$AGENT")" > "$file"
  printf '%s' "$file"
}

# run_in_pane_shell <dir> <typed-line>: run the typed line from a bash that has
# job control OFF (the fish-like pane shell), inside a real pty, then record the
# shell's own group, the terminal foreground after the line returned, and the
# line's exit status.
run_in_pane_shell() {  # <dir> <typed-line>
  local dir=$1 line=$2
  # shellcheck disable=SC2016  # expanded by the pane-shell bash, not here
  python3 "$PTY" bash --norc --noprofile -c '
    set +m
    eval "$1"
    rc=$?
    python3 -c "import os; print(os.getpgrp(), os.tcgetpgrp(os.open(\"/dev/tty\", os.O_RDONLY)), $rc)" > "$2"
  ' pane-shell "$line" "$dir/shell.out"
}

test_launch_line_gives_the_agent_its_own_foreground_group() {
  local dir file line agent_pid agent_pgid agent_fg shell_pgid shell_fg rc
  dir="$TMP_ROOT/it's a launch dir"
  file=$(stage_launch "$dir" 7)
  line=$(fm_backend_herdr_launch_line "$file")
  run_in_pane_shell "$dir" "$line" || fail "the pty driver failed for: $line"
  [ -s "$dir/agent.out" ] || fail "the typed Herdr launch line never started the staged agent: $line"
  read -r agent_pid agent_pgid agent_fg < "$dir/agent.out"
  read -r shell_pgid shell_fg rc < "$dir/shell.out"
  [ "$agent_pgid" = "$agent_pid" ] \
    || fail "the agent must lead its own process group (pid $agent_pid, pgid $agent_pgid)"
  [ "$agent_pgid" != "$shell_pgid" ] \
    || fail "the agent still shares the pane shell's process group ($shell_pgid), so Herdr sees no group change"
  [ "$agent_fg" = "$agent_pgid" ] \
    || fail "the agent's group ($agent_pgid) must hold the terminal foreground while it runs, got $agent_fg"
  [ "$shell_fg" = "$shell_pgid" ] \
    || fail "the terminal must return to the pane shell's group ($shell_pgid) after the agent exits, got $shell_fg"
  [ "$rc" = 7 ] || fail "the typed line must return the agent's exit status (7), got $rc"
  pass "herdr launch line: from a shell without job control, the agent runs as its own foreground process group and the terminal returns to the shell"
}

test_plain_source_line_shares_the_shell_group() {
  local dir file agent_pid agent_pgid agent_fg shell_pgid shell_fg rc
  dir="$TMP_ROOT/plain source"
  file=$(stage_launch "$dir" 0)
  run_in_pane_shell "$dir" ". $(sq "$file")" || fail "the pty driver failed for the plain source line"
  [ -s "$dir/agent.out" ] || fail "the plain source line never started the staged agent"
  read -r agent_pid agent_pgid agent_fg < "$dir/agent.out"
  read -r shell_pgid shell_fg rc < "$dir/shell.out"
  [ "$agent_pgid" = "$shell_pgid" ] \
    || fail "counterfactual drifted: a sourced agent under a shell without job control now gets its own group ($agent_pgid vs shell $shell_pgid), so the first case no longer proves anything"
  [ "$agent_fg" = "$shell_pgid" ] || fail "counterfactual drifted: the foreground group moved to $agent_fg"
  pass "herdr launch line counterfactual: a plain '. <file>' agent shares the pane shell's group, the shape Herdr never registers"
}

test_launch_line_gives_the_agent_its_own_foreground_group
test_plain_source_line_shares_the_shell_group
