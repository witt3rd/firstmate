#!/usr/bin/env bash
# fm-ceilings.sh - the host ceilings bin/fm-spawn.sh enforces before it creates
# anything new, so regrowth stops at the creator instead of waiting for a
# janitor.
#
# Usage: fm-ceilings.sh check [--project <dir>]
#        fm-ceilings.sh show  [--project <dir>]
#
# The ceilings live in one file, ${FM_CEILINGS_FILE:-~/.config/fleet/ceilings.env}
# (rendered per host by fleet-ops; this script only reads it): KEY=value lines,
# '#' comments, numeric values. A key that is absent sets no ceiling and an
# absent file sets none at all, so a host that declares nothing is never blocked.
#
#   DISK_PCT           percent used of the filesystem holding $HOME
#   CONTAINERS         docker containers, all states
#   CONTAINERS_RUNNING docker containers running
#   VOLUMES            docker volumes
#   IMAGE_TAGS         docker image tags
#   POOL_SLOTS         populated Treehouse slots for --project (empty numbered
#                      directories do not count; bin/fm-pool-lib.sh)
#   TMP_GB             GB used of the filesystem holding ${TMPDIR:-/tmp}
#
# A value at or above its ceiling is over: `check` prints one
# `over: <KEY> <value> >= <ceiling>` line per breach and exits 1. A measurement
# that cannot be taken (no docker, no pool) never counts as a breach.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pool-lib.sh
. "$SCRIPT_DIR/fm-pool-lib.sh"

CMD=${1:-}
[ "$#" -eq 0 ] || shift
PROJECT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT=${2:-}; shift ;;
    *) echo "usage: fm-ceilings.sh check|show [--project <dir>]" >&2; exit 2 ;;
  esac
  shift
done
case "$CMD" in check|show) ;; *) echo "usage: fm-ceilings.sh check|show [--project <dir>]" >&2; exit 2 ;; esac

FILE=${FM_CEILINGS_FILE:-${HOME:-}/.config/fleet/ceilings.env}
[ -f "$FILE" ] || exit 0

ceiling() {  # <KEY> -> numeric ceiling, or empty
  local v
  v=$(awk -F= -v k="$1" '$1 == k { gsub(/[[:space:]]/, "", $2); v = $2 } END { print v }' "$FILE")
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$v"
}

# Lines a command prints; nothing at all when it is absent or fails, so a
# docker that cannot answer is "unmeasurable" and not a count of zero.
count_lines() {
  local out
  command -v "$1" >/dev/null 2>&1 || return 0
  out=$("$@" 2>/dev/null) || return 0
  printf '%s' "$out" | awk 'END { print NR }'
}

measure() {  # <KEY> -> measured value, or empty when it cannot be taken
  case "$1" in
    DISK_PCT)
      df -P "${HOME:-/}" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }' ;;
    TMP_GB)
      df -Pm "${TMPDIR:-/tmp}" 2>/dev/null | awk 'NR == 2 { print int($3 / 1024) }' ;;
    CONTAINERS) count_lines docker ps -aq ;;
    CONTAINERS_RUNNING) count_lines docker ps -q ;;
    VOLUMES) count_lines docker volume ls -q ;;
    IMAGE_TAGS) count_lines docker images --format '{{.Repository}}:{{.Tag}}' ;;
    POOL_SLOTS)
      [ -n "$PROJECT" ] && fm_pool_populated_count "$PROJECT" ;;
  esac
  return 0
}

rc=0
for key in DISK_PCT CONTAINERS CONTAINERS_RUNNING VOLUMES IMAGE_TAGS POOL_SLOTS TMP_GB; do
  limit=$(ceiling "$key")
  [ -n "$limit" ] || continue
  value=$(measure "$key")
  case "$value" in ''|*[!0-9]*) continue ;; esac
  if [ "$CMD" = show ]; then
    printf '%s %s ceiling %s\n' "$key" "$value" "$limit"
  fi
  if [ "$value" -ge "$limit" ]; then
    [ "$CMD" = show ] || printf 'over: %s %s >= %s\n' "$key" "$value" "$limit"
    rc=1
  fi
done
exit "$rc"
