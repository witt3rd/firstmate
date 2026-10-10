# shellcheck shell=bash
# Shared per-line cap for agent-facing digest lines.
# Usage: . bin/fm-line-cap-lib.sh; fm_cap_line "<line>" [<max>]
#
# Status and decision text (the wake digest's OPEN DECISIONS section and the
# session-start digest's status tails) is never clipped: fm_fold_line_var below
# folds it. The per-line cap that follows remains for non-status report lines
# (mail, tool updates) and status-record writers. The cap's original rationale:
# the two digests render the same kind of
# content - an agent-written status line, which AGENTS.md section 8 treats as a
# wake EVENT rather than current state - into a size-bounded view. An agent
# reading both must recognize one truncation marker, and the two caps must not
# drift apart, so the cut and its marker live here.
#
# Callers keep their own composite policy: fm-wake-drain.sh still owns the
# OPEN DECISIONS global byte cap and its "N more omitted" disclosure, and
# fm-session-start.sh still owns how many tail lines it prints per task. This
# file owns only the per-line cut.
#
# The cap counts characters, so a plain-ASCII line - what status lines are in
# practice - is bounded to the same number of bytes, and a multibyte character
# is never cut in half into an invalid sequence.
# Truncation stays recoverable because the session-start digest prints each
# task's full status log path, while every OPEN DECISIONS entry begins with the
# task id that identifies its durable state/<id>.status source.

FM_LINE_CAP_DEFAULT=220
FM_LINE_CAP_SUFFIX=' [truncated]'

# fm_cap_line_var <line> [<max>]: put <line> in FM_LINE_CAP_LINE, cut to <max>
# characters with FM_LINE_CAP_SUFFIX in place of the tail when it is longer. A
# line at or under the cap is kept unchanged, marker and all bytes intact.
# This is the rule itself. It assigns rather than prints so a caller that needs
# the value - the wake digest builds its section in a variable to weigh each
# item against a global budget - never pays a command substitution per item on
# a path that runs at the top of every wake-handling turn.
fm_cap_line_var() {
  local line=$1 max=${2:-$FM_LINE_CAP_DEFAULT} keep
  if [ "${#line}" -le "$max" ]; then
    FM_LINE_CAP_LINE=$line
    return 0
  fi
  keep=$((max - ${#FM_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  FM_LINE_CAP_LINE="${line:0:$keep}$FM_LINE_CAP_SUFFIX"
}

# fm_cap_line <line> [<max>]: the same cut, printed on stdout, for a caller that
# is streaming lines rather than accumulating them.
fm_cap_line() {
  fm_cap_line_var "$@"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}

# Display-time folding for status and decision text. Text written for diagnosis
# is never clipped: fm_fold_line_var splits a long line across physical lines
# of at most FM_FOLD_WIDTH characters and loses nothing. Every continuation
# line starts with FM_FOLD_CONT_PREFIX, so the split is explicit and a reader
# (or a test) rejoins the pieces by dropping that prefix and the newline.
# A line at or under the width is kept unchanged.
FM_FOLD_WIDTH=200
FM_FOLD_CONT_PREFIX='  | '

# fm_fold_line_var <line> [<width>]: put the folded text in FM_FOLD_LINE (no
# trailing newline). Assigns rather than prints for the same reason as
# fm_cap_line_var.
fm_fold_line_var() {
  local line=$1 width=${2:-$FM_FOLD_WIDTH} out
  case "$width" in ''|*[!0-9]*|0) width=$FM_FOLD_WIDTH ;; esac
  if [ "${#line}" -le "$width" ]; then
    FM_FOLD_LINE=$line
    return 0
  fi
  out=${line:0:width}
  line=${line:width}
  while [ -n "$line" ]; do
    out="$out
$FM_FOLD_CONT_PREFIX${line:0:width}"
    line=${line:width}
  done
  FM_FOLD_LINE=$out
}

# fm_fold_line <line> [<width>]: the same fold, printed with a trailing newline.
fm_fold_line() {
  fm_fold_line_var "$@"
  printf '%s\n' "$FM_FOLD_LINE"
}
