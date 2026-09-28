#!/usr/bin/env bash
# fm-caretaker-lib.sh - the one owner of a caretaker charter's machine-read lines.
#
# A caretaker is a persistent secondmate whose charter adds the generic
# caretaker practice to its domain rules; bin/fm-brief.sh scaffolds it with
# `--secondmate --caretaker [--sweep-every <cadence>]` and owns the prose.
# This library owns only what scripts read back:
#   - FM_CARETAKER_PRACTICE_HEADING, the charter section whose presence makes a
#     charter a caretaker charter (seeding keys the ledger initialization on it);
#   - FM_CARETAKER_SWEEP_HEADING and the one declaration line inside it,
#     `Health sweep cadence: every <N><h|d|w>`, whose grammar is a positive
#     whole number of hours, days, or weeks between 1h and 366d inclusive;
#     a caretaker charter without that section declares no scheduled sweep and
#     stays idle by default like any other secondmate;
#   - FM_CARETAKER_LEDGER_HEADING and FM_CARETAKER_LEDGER_ROW, the recurrence
#     ledger's heading and row format in the home's data/learnings.md, and the
#     idempotent seed-time initialization of that section.
# bin/fm-caretaker-sweep.sh owns the sweep schedule, its durable record, the
# watcher check, and the read-only snapshot built on these lines.
#
# Sourced by bin/fm-brief.sh, bin/fm-home-seed.sh,
# bin/fm-remote-home-provision.sh, bin/fm-caretaker-sweep.sh, and tests.
# No side effects on source.

# The constants and output globals below are read by sourcing callers.
# shellcheck disable=SC2034
FM_CARETAKER_PRACTICE_HEADING='# Caretaker practice'
FM_CARETAKER_LEDGER_SECTION_HEADING='# Recurrence ledger'
FM_CARETAKER_SWEEP_HEADING='# Scheduled health sweep'
FM_CARETAKER_CADENCE_PREFIX='Health sweep cadence: every '
FM_CARETAKER_LEDGER_HEADING='## Recurrence ledger'
FM_CARETAKER_LEDGER_ROW='- <problem class> | <YYYY-MM-DD> <occurrence>; <YYYY-MM-DD> <occurrence> | <remedy status> <!--P-->'
FM_CARETAKER_CADENCE_MAX_SECS=$((366 * 86400))

# Output globals, set by the parsers below.
FM_CARETAKER_CADENCE=
FM_CARETAKER_CADENCE_SECS=
FM_CARETAKER_CADENCE_ERROR=

# fm_caretaker_cadence_parse <spec>
# Validate a cadence such as 7d, 12h, or 2w. On success sets
# FM_CARETAKER_CADENCE (the spec) and FM_CARETAKER_CADENCE_SECS and returns 0;
# otherwise sets FM_CARETAKER_CADENCE_ERROR and returns 1.
fm_caretaker_cadence_parse() {
  local spec=${1-} count unit secs
  local LC_ALL=C
  FM_CARETAKER_CADENCE=
  FM_CARETAKER_CADENCE_SECS=
  FM_CARETAKER_CADENCE_ERROR=
  case "$spec" in
    [1-9]h|[1-9][0-9]h|[1-9][0-9][0-9]h|[1-9][0-9][0-9][0-9]h) unit=3600 ;;
    [1-9]d|[1-9][0-9]d|[1-9][0-9][0-9]d) unit=86400 ;;
    [1-9]w|[1-9][0-9]w) unit=604800 ;;
    *)
      FM_CARETAKER_CADENCE_ERROR="cadence '$spec' is not a positive whole number of hours, days, or weeks such as 12h, 7d, or 2w"
      return 1
      ;;
  esac
  count=${spec%?}
  secs=$((count * unit))
  if [ "$secs" -gt "$FM_CARETAKER_CADENCE_MAX_SECS" ]; then
    FM_CARETAKER_CADENCE_ERROR="cadence '$spec' is longer than 366d"
    return 1
  fi
  FM_CARETAKER_CADENCE=$spec
  FM_CARETAKER_CADENCE_SECS=$secs
}

# _fm_caretaker_section <charter> <heading>
# Print the body of a top-level charter section, excluding its heading.
_fm_caretaker_section() {
  awk -v heading="$2" '
    $0 == heading { in_section = 1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$1"
}

# fm_caretaker_charter_is_caretaker <charter>
# Exit 0 when the charter carries the caretaker practice section.
fm_caretaker_charter_is_caretaker() {
  local charter=$1
  [ -f "$charter" ] && [ ! -L "$charter" ] || return 1
  grep -Fxq -- "$FM_CARETAKER_PRACTICE_HEADING" "$charter"
}

# fm_caretaker_charter_cadence <charter>
# Read the sweep declaration. Returns 0 with FM_CARETAKER_CADENCE and
# FM_CARETAKER_CADENCE_SECS set for a valid declaration in a caretaker
# charter, 1 when the charter declares no scheduled sweep (including a
# charter that is absent or not a caretaker charter), and 2 with
# FM_CARETAKER_CADENCE_ERROR set when a declaration is present but unusable.
fm_caretaker_charter_cadence() {
  local charter=$1 body lines count spec
  FM_CARETAKER_CADENCE=
  FM_CARETAKER_CADENCE_SECS=
  FM_CARETAKER_CADENCE_ERROR=
  fm_caretaker_charter_is_caretaker "$charter" || return 1
  grep -Fxq -- "$FM_CARETAKER_SWEEP_HEADING" "$charter" || return 1
  body=$(_fm_caretaker_section "$charter" "$FM_CARETAKER_SWEEP_HEADING") || {
    FM_CARETAKER_CADENCE_ERROR="the charter could not be read"
    return 2
  }
  lines=$(printf '%s\n' "$body" | awk -v prefix="$FM_CARETAKER_CADENCE_PREFIX" 'index($0, prefix) == 1')
  count=$(printf '%s' "$lines" | grep -c '' || true)
  if [ "$count" -ne 1 ]; then
    FM_CARETAKER_CADENCE_ERROR="the '${FM_CARETAKER_SWEEP_HEADING#\# }' section must carry exactly one '${FM_CARETAKER_CADENCE_PREFIX}<cadence>' line, found $count"
    return 2
  fi
  spec=${lines#"$FM_CARETAKER_CADENCE_PREFIX"}
  fm_caretaker_cadence_parse "$spec" || return 2
}

# fm_caretaker_ledger_present <learnings>
# Exit 0 when the file already carries a recurrence ledger, in the canonical
# heading form or as an older hand-written "Recurrence ledger" heading or
# bullet, so initialization never adds a second ledger beside an existing one.
fm_caretaker_ledger_present() {
  [ -f "$1" ] || return 1
  grep -Eq '^(#+|[-*])[[:space:]]+Recurrence ledger([^[:alnum:]]|$)' "$1"
}

# fm_caretaker_ledger_init <learnings>
# Idempotently give <learnings> its recurrence ledger section. An absent file
# is created with a Learnings heading; an existing regular file without a
# ledger gets the section appended; a file that already has one is untouched.
# Refuses a symlink or other non-regular path. Returns 0 on success.
fm_caretaker_ledger_init() {
  local learnings=$1 dir tmp
  if [ -L "$learnings" ] || { [ -e "$learnings" ] && [ ! -f "$learnings" ]; }; then
    printf 'error: recurrence ledger target is not a regular file: %s\n' "$learnings" >&2
    return 1
  fi
  fm_caretaker_ledger_present "$learnings" && return 0
  dir=$(dirname "$learnings")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.learnings.XXXXXX") || return 1
  {
    if [ -s "$learnings" ]; then
      cat "$learnings"
      # Keep the appended heading off the previous line and one blank line apart.
      [ "$(tail -c 1 "$learnings")" = '' ] || printf '\n'
      printf '\n'
    else
      printf '# Learnings\n\n'
    fi
    printf '%s\n' "$FM_CARETAKER_LEDGER_HEADING"
    # shellcheck disable=SC2016 # The backticks are literal Markdown code quotes.
    printf 'One row per problem class: `%s`. <!--P-->\n' "$FM_CARETAKER_LEDGER_ROW"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -f "$learnings" ]; then
    chmod "$(_fm_caretaker_file_mode "$learnings")" "$tmp" 2>/dev/null || true
  fi
  mv -f -- "$tmp" "$learnings" || { rm -f -- "$tmp"; return 1; }
}

_fm_caretaker_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}
