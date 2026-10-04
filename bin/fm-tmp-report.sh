#!/usr/bin/env bash
# fm-tmp-report.sh - read-only size report of per-task scratch under /tmp.
#
# Finished tasks must not leave /tmp/fm-<id>/ behind (fm-teardown removes it);
# /tmp is often RAM-backed, so leaks cost memory. This lists the filesystem
# use of the scratch root, each /tmp/fm-* directory with its size, and marks
# those no live state/*.meta of this home records as tasktmp= ("unreferenced":
# a leak, or another home's task). Never deletes anything.
#
# Usage: fm-tmp-report.sh        (env: FM_TMP_ROOT scratch root, default /tmp;
#        FM_TMP_WARN_PCT warn threshold, default 60; FM_HOME / FM_STATE_OVERRIDE)
# Prints nothing when there is nothing to report and use is below the threshold.
set -u
ROOT=${FM_TMP_ROOT:-/tmp}
WARN=${FM_TMP_WARN_PCT:-60}
case "$WARN" in ''|*[!0-9]*) WARN=60 ;; esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$(dirname "$SCRIPT_DIR")}/state}

pct=$(df -P "$ROOT" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
case "$pct" in ''|*[!0-9]*) pct= ;; esac

lines=
total_kb=0
for d in "$ROOT"/fm-*; do
  [ -d "$d" ] && [ ! -L "$d" ] || continue
  kb=$(timeout 10 du -sk "$d" 2>/dev/null | awk '{print $1}')
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  total_kb=$((total_kb + kb))
  mark=
  if ! grep -qsx "tasktmp=$d" "$STATE"/*.meta 2>/dev/null; then mark=' (unreferenced by this home)'; fi
  lines="$lines$(printf '  %8s KiB  %s%s' "$kb" "$d" "$mark")
"
done

[ -n "$lines" ] || [ -z "$pct" ] || [ "$pct" -lt "$WARN" ] || lines=' '
[ -n "$lines" ] || exit 0
printf 'scratch root %s: %s%% used, task scratch total %s KiB\n' "$ROOT" "${pct:-?}" "$total_kb"
[ "$lines" = ' ' ] || printf '%s' "$lines"
[ -z "$pct" ] || [ "$pct" -lt "$WARN" ] || printf 'WARNING: %s is at or above %s%% - remove unreferenced fm-* scratch after confirming no live task uses it.\n' "$ROOT" "$WARN"
exit 0
