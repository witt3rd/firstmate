#!/usr/bin/env bash
# Stable PreToolUse transport for the destructive-command guard.
#
# A worker once deleted about 370 shared docker workspace volumes with a cleanup
# filter that carried one stray extra pattern. A brief rule did not stop it, so
# this guard makes the harness refuse a destructive bulk delete - docker prune,
# a filtered/piped/wildcard docker removal, a recursive rm over a glob under the
# home directory or /mnt, git clean outside the pane's own worktree, find
# -delete outside /tmp/fm-*, block-device writes, btrfs subvolume deletes, and
# systemctl disable/mask - in every worker and mate pane that loads it.
# bin/fm-destructive-command-policy.mjs is the sole owner of the allow/deny
# decision. This wrapper acquires the harness payload, supplies the pane's
# identity and own worktree, honors the captain-or-main override, logs every
# denial and override, tells the pane's parent, and renders the established
# harness responses. It never executes, sources, evaluates, or expands the
# submitted command. See docs/destructive-guard.md for the complete contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-destructive-pretool-check.sh [options]
#   bin/fm-destructive-pretool-check.sh --command '<cmd>' [options]
#   bin/fm-destructive-pretool-check.sh --grant <ticket> --state <dir> --task <id>
#
# Options:
#   --command <cmd>   the exact shell command (OpenCode, Pi, pi-signed, omp).
#   --claude          Claude's stderr-only deny rendering.
#   --cursor          Cursor's own returned-object deny rendering.
#   --primary         the tracked primary adapter: stand down (allow) when
#                     FM_TASK_ID is set, because fm-spawn installs a per-task
#                     adapter in every worker pane it covers and that adapter
#                     owns the decision there.
#   --state <dir>     the parent home's state directory (per-task adapters).
#   --task <id>       the worker's task id; also the worker's own resource label.
#   --worktree <dir>  the isolated worktree fm-spawn created for this worker.
#   --grant <ticket>  record that main granted FM_DESTRUCTIVE_OK=<ticket> to the
#                     named task's launch; prints nothing, exits 0, or exits 1
#                     when the ticket is malformed. Used by bin/fm-spawn.sh.
#   --check-ticket <ticket>
#                     exit 0 when the ticket is well formed, else print the
#                     required shape and exit 1. Used by bin/fm-spawn.sh.
#
# Override: the guard honors FM_DESTRUCTIVE_OK=<ticket> only from its OWN process
# environment, which it inherits from the harness process. A worker cannot grant
# it to itself: a FM_DESTRUCTIVE_OK= assignment or export inside the submitted
# command changes the command's environment, never the harness's. The ticket
# must match [A-Za-z0-9][A-Za-z0-9._:#/-]{0,79}; a malformed value grants
# nothing. An honored override allows the command and is logged.
#
# Log: every denial, override, and grant appends one JSON line (when, who,
# where, code, decision, ticket, command) to <home>/data/destructive-guard.log,
# where <home> is the parent of --state, else FM_HOME, else the code root.
# A worker denial also appends a `note:` line to <state>/<task>.status so the
# supervisor sees the attempt; a secondmate primary's denial goes to its parent
# channel (bin/fm-parent-channel-lib.sh). A log or note failure never turns a
# denial into an allow.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0
PRIMARY_MODE=0
STATE_DIR=""
TASK=""
WORKTREE=""
GRANT=""
GRANT_SET=0
CHECK_TICKET=""
CHECK_TICKET_SET=0

usage() {
  cat <<'EOF'
Usage: fm-destructive-pretool-check.sh [--command <cmd>] [--claude|--cursor]
         [--primary] [--state <dir> --task <id> [--worktree <dir>]]
       fm-destructive-pretool-check.sh --grant <ticket> --state <dir> --task <id>
       fm-destructive-pretool-check.sh --check-ticket <ticket>

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Exits 0 to allow and 2 to deny a destructive bulk delete.
FM_DESTRUCTIVE_OK=<ticket> in this process's own environment overrides a
denial; the same assignment inside the command grants nothing.
Every denial and override is logged to <home>/data/destructive-guard.log.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

need_value() {
  [ "$2" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) need_value "$1" "$#"; CMD=$2; CMD_SET=1; shift 2 ;;
    --command=*) CMD=${1#--command=}; CMD_SET=1; shift ;;
    --claude) CLAUDE_MODE=1; shift ;;
    --cursor) CURSOR_MODE=1; shift ;;
    --primary) PRIMARY_MODE=1; shift ;;
    --state) need_value "$1" "$#"; STATE_DIR=$2; shift 2 ;;
    --task) need_value "$1" "$#"; TASK=$2; shift 2 ;;
    --worktree) need_value "$1" "$#"; WORKTREE=$2; shift 2 ;;
    --grant) need_value "$1" "$#"; GRANT=$2; GRANT_SET=1; shift 2 ;;
    --check-ticket) need_value "$1" "$#"; CHECK_TICKET=$2; CHECK_TICKET_SET=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
CODE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0

ticket_valid() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:#/-]{0,79}$ ]]
}

json_string() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}

log_home() {
  if [ -n "$STATE_DIR" ]; then
    (CDPATH='' cd -- "$STATE_DIR/.." 2>/dev/null && pwd -P)
  else
    printf '%s\n' "${FM_HOME:-$CODE_ROOT}"
  fi
}

# append_log <decision> <code> <ticket> <command>
append_log() {
  local home log now iso who command=$4
  home=$(log_home) || return 1
  [ -n "$home" ] && [ -d "$home" ] || return 1
  mkdir -p "$home/data" 2>/dev/null || return 1
  log="$home/data/destructive-guard.log"
  now=$(date +%s)
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -n "$TASK" ]; then who="task:$TASK"; else who="primary"; fi
  [ "${#command}" -le 4000 ] || command="${command:0:4000}..."
  printf '{"at":%s,"time":%s,"who":%s,"home":%s,"host":%s,"harness":%s,"pid":%s,"cwd":%s,"decision":%s,"code":%s,"ticket":%s,"command":%s}\n' \
    "$now" "$(json_string "$iso")" "$(json_string "$who")" "$(json_string "$home")" \
    "$(json_string "$(uname -n 2>/dev/null || echo unknown)")" \
    "$(json_string "${FM_PI_HARNESS:-${FM_OMP_HARNESS:-${CLAUDECODE:+claude}}}")" \
    "$PPID" "$(json_string "$(pwd -P 2>/dev/null || pwd)")" "$(json_string "$1")" \
    "$(json_string "$2")" "$(json_string "$3")" "$(json_string "$command")" >>"$log" 2>/dev/null
}

# notify_parent <line>: tell the pane's supervisor about the attempt.
notify_parent() {
  local line=$1 status home
  if [ -n "$STATE_DIR" ] && [ -n "$TASK" ]; then
    case "$TASK" in ''|.*|*/*) return 1 ;; esac
    status="$STATE_DIR/$TASK.status"
    [ ! -L "$status" ] || return 1
    printf '%s\n' "$line" >>"$status" 2>/dev/null
    return
  fi
  home=${FM_HOME:-$CODE_ROOT}
  [ -f "$home/.fm-secondmate-home" ] || return 0
  [ -f "$SCRIPT_DIR/fm-parent-channel-lib.sh" ] || return 1
  (
    # shellcheck source=bin/fm-parent-channel-lib.sh
    . "$SCRIPT_DIR/fm-parent-channel-lib.sh" >/dev/null 2>&1 || exit 1
    fm_parent_channel_report "$home" "${FM_STATE_OVERRIDE:-$home/state}" "$line" >/dev/null 2>&1
  )
}

excerpt() {
  local s=$1
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//$'\t'/ }
  [ "${#s}" -le 160 ] || s="${s:0:160}..."
  printf '%s' "$s"
}

TICKET_SHAPE='[A-Za-z0-9][A-Za-z0-9._:#/-]{0,79}'
if [ "$CHECK_TICKET_SET" -eq 1 ]; then
  ticket_valid "$CHECK_TICKET" && exit 0
  echo "error: a destructive-guard ticket must match $TICKET_SHAPE" >&2
  exit 1
fi

if [ "$GRANT_SET" -eq 1 ]; then
  ticket_valid "$GRANT" || { echo "error: --grant ticket must match $TICKET_SHAPE" >&2; exit 1; }
  [ -n "$STATE_DIR" ] && [ -n "$TASK" ] || { echo "error: --grant requires --state and --task" >&2; exit 1; }
  append_log grant - "$GRANT" "FM_DESTRUCTIVE_OK granted to the launch of $TASK" || true
  exit 0
fi

if [ "$PRIMARY_MODE" -eq 1 ] && [ -n "${FM_TASK_ID:-}" ]; then
  exit 0
fi

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor; without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). After dropping the bytes the classifier joins inside a shell word,
# a command that names none of the guarded tools - and carries no quoting-decoder
# marker ($'...' ANSI-C or $"..." locale) that could reconstruct one - cannot be
# denied, so it skips the Node process. This marker set is COUPLED to the
# classifier's decoder set in bin/fm-arm-command-policy.mjs.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *docker*|*podman*|*nerdctl*|*rm*|*find*|*git*|*dd*|*mkfs*|*mke2fs*|*mkswap*|\
      *wipefs*|*blkdiscard*|*parted*|*fdisk*|*btrfs*|*systemctl*|*shred*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

POLICY="$SCRIPT_DIR/fm-destructive-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_ARGS=(--command "$CMD" --cwd "$(pwd -P 2>/dev/null || pwd)")
[ -z "${HOME:-}" ] || POLICY_ARGS+=(--home "$HOME")
[ -z "$WORKTREE" ] || POLICY_ARGS+=(--own-worktree "$WORKTREE")
[ -z "$TASK" ] || POLICY_ARGS+=(--own-label "$TASK")
POLICY_OUTPUT=$(node "$POLICY" "${POLICY_ARGS[@]}" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

NOW=$(date +%s)
TICKET=${FM_DESTRUCTIVE_OK:-}
if [ -n "$TICKET" ] && ticket_valid "$TICKET"; then
  append_log override "$CODE" "$TICKET" "$CMD" || true
  notify_parent "note [at=$NOW]: destructive-command guard override FM_DESTRUCTIVE_OK=$TICKET allowed [$CODE]: $(excerpt "$CMD")" || true
  exit 0
fi

append_log deny "$CODE" "" "$CMD" || true
notify_parent "note [at=$NOW]: destructive-command guard denied [$CODE]; the command did not run: $(excerpt "$CMD")" || true

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] destructive-command guard: $REASON. The command did not run and the attempt was logged for your supervisor. Name the exact resources you created instead, or ask your supervisor; only the captain or main can authorize it, by launching the session with FM_DESTRUCTIVE_OK=<ticket> - setting it inside the command grants nothing."
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
