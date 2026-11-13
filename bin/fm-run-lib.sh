#!/usr/bin/env bash
# fm-run-lib.sh - shared ledger, probe, and removal primitives for bin/fm-run,
# bin/fm-run-shim.sh, and bin/fm-created-check. The contract is docs/fm-run.md.
#
# Whatever creates a thing destroys it, in the same code path. A launch through
# bin/fm-run keeps a per-run ledger of everything it created (docker objects by
# exact name, scratch directories by exact path) and this library removes
# exactly those entries: never a filter, a name pattern, an age, or a prune.
#
# Ledger line (TAB separated): <kind> <name> <proof>
#   kind   container | network | volume | image | project | dir
#   name   the exact docker name or id, or the absolute directory path
#   proof  key=value label the object must still carry before it is removed
#          (fm.task=<task-id> for objects the shim created), or - for a dir
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no ${var,,}.

# shellcheck disable=SC2034  # read by bin/fm-run-shim.sh, which sources this file
FM_RUN_LABEL_KEY=fm.task
# shellcheck disable=SC2034
FM_RUN_RUN_KEY=fm.run
FM_RUN_DOCKER_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.:/@-]*$'

# fm_run_heavy_host_guard: refuse (exit 75, one line) on a host listed in the
# tracked bin/fm-no-heavy-hosts.default, plus any hosts a home's own config adds. The
# tracked default is always read from this checkout, so an override can only add.
# FM_HEAVY_HOSTNAME replaces `hostname -s` (test hook).
fm_run_heavy_host_guard() {
  local code_root host file line
  code_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || return 0
  host=${FM_HEAVY_HOSTNAME:-$(hostname -s 2>/dev/null)}
  [ -n "$host" ] || return 0
  for file in "$code_root/bin/fm-no-heavy-hosts.default" "${FM_HOME:+$FM_HOME/config/no-heavy-hosts}"; do
    [ -n "$file" ] && [ -r "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      [ "$line" = "$host" ] || continue
      printf "%s is the captain's desktop: heavy work runs on x, chef, et or mcfeely\n" "$host" >&2
      exit 75
    done <"$file"
  done
  return 0
}

fm_run_root() {
  printf '%s' "${FM_RUN_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/fm-run}"
}

# A task id is also the guard's label (bin/fm-destructive-command-policy.mjs
# --own-label), which it only honors at three characters or more.
fm_run_valid_task() {
  case "$1" in
    '' | *[!A-Za-z0-9._-]* | [!A-Za-z0-9]*) return 1 ;;
  esac
  [ "${#1}" -ge 3 ] && [ "${#1}" -le 64 ]
}

fm_run_valid_runid() {
  case "$1" in
    r[0-9]*-[0-9]*) ;;
    *) return 1 ;;
  esac
  case "${1#r}" in
    *[!0-9-]* | *-*-*) return 1 ;;
  esac
  return 0
}

# The scratch root is derived from the task id and run id, never read from the
# ledger, so an edited ledger cannot declare a different root.
fm_run_scratch_for() {  # <task-id> <run-id>
  printf '%s/fm-run-%s-%s' "$(fm_run_tmpbase)" "$1" "$2"
}

# Scratch base: a short on-disk path, never /tmp (RAM-backed tmpfs on worker
# hosts, and a long path breaks Postgres unix socket paths). See docs/fm-run.md.
fm_run_tmpbase() {
  printf '%s' "${FM_RUN_TMPBASE:-$HOME/.t}"
}

# 0 when the base's filesystem is at or under the limit in bytes and inodes;
# otherwise prints one plain line and returns 1. A filesystem that reports no
# inode count (btrfs, 0 or -) is judged on bytes alone.
fm_run_disk_check() {  # <dir>
  local dir=$1 max=${FM_RUN_MAX_USED_PCT:-90} flag kind pct
  for flag in -P -Pi; do
    pct=$(df "$flag" -- "$dir" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
    case "$pct" in '' | *[!0-9]*) continue ;; esac
    if [ "$pct" -gt "$max" ]; then
      kind=bytes
      [ "$flag" = -Pi ] && kind=inodes
      printf 'fm-run: refusing to start: %s is %s%% full in %s (limit %s%%); free disk space first\n' "$dir" "$pct" "$kind" "$max"
      return 1
    fi
  done
  return 0
}

# PATH without any fm-run shim directory (a directory holding .fm-run-shim).
fm_run_real_path() {
  local entry out='' rest=${PATH:-}
  while :; do
    entry=${rest%%:*}
    if [ ! -e "$entry/.fm-run-shim" ]; then
      out=${out:+$out:}$entry
    fi
    case "$rest" in
      *:*) rest=${rest#*:} ;;
      *) break ;;
    esac
  done
  printf '%s' "$out"
}

fm_run_docker() {
  PATH=$(fm_run_real_path) docker "$@"
}

fm_run_pid_token() {  # <pid> -> stable start-time token, empty when not running
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'
}

fm_run_record() {  # <ledger> <kind> <name> [proof]
  local ledger=$1 kind=$2 name=$3 proof=${4:--}
  case "$kind" in
    container | network | volume | image | project | dir) ;;
    *) return 1 ;;
  esac
  [ -n "$name" ] || return 1
  case "$name$proof" in
    *$'\t'* | *$'\n'*) return 1 ;;
  esac
  printf '%s\t%s\t%s\n' "$kind" "$name" "$proof" >>"$ledger"
}

# 0 when a ledger entry is well formed for its kind.
fm_run_entry_valid() {  # <kind> <name>
  case "$1" in
    container | network | volume | image | project)
      printf '%s' "$2" | grep -Eq "$FM_RUN_DOCKER_NAME_RE"
      ;;
    dir)
      case "$2" in
        /*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# present | gone | unknown
fm_run_probe() {  # <kind> <name>
  local kind=$1 name=$2 out rc
  case "$kind" in
    dir)
      if [ -e "$name" ] || [ -L "$name" ]; then echo present; else echo gone; fi
      ;;
    container | network | volume | image)
      out=$(fm_run_docker "$kind" inspect --format x -- "$name" 2>&1)
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo present
      else
        case "$out" in
          *[Nn]o\ such* | *not\ found*) echo gone ;;
          *) echo unknown ;;
        esac
      fi
      ;;
    *) echo unknown ;;
  esac
}

# 0 when the live object still carries the proof label the ledger recorded.
fm_run_proof_ok() {  # <kind> <name> <proof>
  local kind=$1 name=$2 proof=$3 key val got tmpl
  [ "$proof" != - ] || return 0
  key=${proof%%=*}
  val=${proof#*=}
  case "$kind" in
    container | image) tmpl='{{index .Config.Labels "'$key'"}}' ;;
    network | volume) tmpl='{{index .Labels "'$key'"}}' ;;
    *) return 1 ;;
  esac
  got=$(fm_run_docker "$kind" inspect --format "$tmpl" -- "$name" 2>/dev/null) || return 1
  [ "$got" = "$val" ]
}

# 0 when the path may be removed: strictly inside (or exactly) the run's own
# derived scratch root, no dot components, and no symlinked parent that leaves it.
fm_run_dir_removable() {  # <path> <scratch-root>
  local path=$1 root=$2 parent root_real
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path/" in
    */../* | */./* | *//*) return 1 ;;
  esac
  [ "$path" != / ] || return 1
  if [ "$path" = "$root" ]; then
    return 0
  fi
  case "$path" in
    "$root"/*) ;;
    *) return 1 ;;
  esac
  parent=$(CDPATH='' cd -P -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || return 1
  root_real=$(CDPATH='' cd -P -- "$root" 2>/dev/null && pwd -P) || return 1
  case "$parent/" in
    "$root_real"/*) return 0 ;;
  esac
  return 1
}

fm_run_remove_docker() {  # <kind> <name>
  case "$1" in
    container) fm_run_docker rm -f -v -- "$2" >/dev/null 2>&1 ;;
    network) fm_run_docker network rm -- "$2" >/dev/null 2>&1 ;;
    volume) fm_run_docker volume rm -- "$2" >/dev/null 2>&1 ;;
    image) fm_run_docker rmi -- "$2" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

fm_run_remove_dir() {  # <path>
  [ -L "$1" ] || { [ ! -d "$1" ] || chmod -R u+rwX -- "$1" 2>/dev/null; }
  rm -rf -- "$1"
}

# Read-only listing of the objects a compose project owns, one "kind<TAB>name"
# per line. Used only for a project this run proved empty before it started.
fm_run_project_members() {  # <project>
  local project=$1 filter line
  filter=label=com.docker.compose.project=$project
  fm_run_docker ps -a --filter "$filter" --format '{{.Names}}' 2>/dev/null | while IFS= read -r line; do
    [ -z "$line" ] || printf 'container\t%s\n' "$line"
  done
  fm_run_docker network ls --filter "$filter" --format '{{.Name}}' 2>/dev/null | while IFS= read -r line; do
    [ -z "$line" ] || printf 'network\t%s\n' "$line"
  done
  fm_run_docker volume ls --filter "$filter" --format '{{.Name}}' 2>/dev/null | while IFS= read -r line; do
    [ -z "$line" ] || printf 'volume\t%s\n' "$line"
  done
  fm_run_docker image ls --filter "$filter" --format '{{.ID}}' 2>/dev/null | sort -u | while IFS= read -r line; do
    [ -z "$line" ] || printf 'image\t%s\n' "$line"
  done
}

# Ledger entries, de-duplicated, in the order removal must happen: containers,
# networks, volumes, image tags, image ids, then directories deepest first.
fm_run_ordered_entries() {  # reads ledger-format lines on stdin
  awk -F'\t' '
    NF >= 2 && !seen[$1 "\t" $2]++ {
      rank = 9
      if ($1 == "container") rank = 1
      else if ($1 == "network") rank = 2
      else if ($1 == "volume") rank = 3
      else if ($1 == "image") rank = ($2 ~ /^sha256:/ || $2 ~ /^[0-9a-f]+$/) ? 5 : 4
      else if ($1 == "dir") rank = 6
      else if ($1 == "project") rank = 0
      printf "%d\t%d\t%s\t%s\t%s\n", rank, (rank == 6 ? 100000 - length($2) : NR), $1, $2, (NF >= 3 ? $3 : "-")
    }' | sort -t "$(printf '\t')" -k1,1n -k2,2n | cut -f3-
}

# fm_run_settle <run-dir> <task-id> <remove: 1|0>
# Walk one run's ledger. With remove=1 remove exactly what it names; with
# remove=0 only observe. Emits one line per entry on stdout:
#   CREATED<TAB>kind<TAB>name
#   REMOVED<TAB>kind<TAB>name<TAB>note        (gone: removed now or already gone)
#   REMAINING<TAB>kind<TAB>name<TAB>reason
fm_run_settle() {
  local rundir=$1 task=$2 remove=$3 ledger extra='' runid scratch tab line kind name proof members mkind mname state entries
  ledger=$rundir/ledger
  runid=$(basename -- "$rundir")
  scratch=$(fm_run_scratch_for "$task" "$runid")
  tab=$(printf '\t')
  [ -f "$ledger" ] || return 0

  # A compose project this run found empty and created is named in the ledger;
  # its members are added by exact name before anything is removed.
  while IFS= read -r line; do
    kind=${line%%"$tab"*}
    [ "$kind" = project ] || continue
    name=${line#*"$tab"}
    name=${name%%"$tab"*}
    fm_run_entry_valid project "$name" || continue
    members=$(fm_run_project_members "$name")
    [ -z "$members" ] || while IFS="$tab" read -r mkind mname; do
      fm_run_entry_valid "$mkind" "$mname" || continue
      extra=$extra$(printf '%s\t%s\t%s' "$mkind" "$mname" "com.docker.compose.project=$name")$'\n'
      [ "$remove" -ne 1 ] || fm_run_record "$ledger" "$mkind" "$mname" "com.docker.compose.project=$name"
    done <<EOF
$members
EOF
  done <<EOF
$(fm_run_ordered_entries <"$ledger")
EOF

  entries=$({ cat "$ledger"; printf '%s' "$extra"; } | fm_run_ordered_entries)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%"$tab"*}
    line=${line#*"$tab"}
    name=${line%%"$tab"*}
    proof=${line#*"$tab"}
    [ "$kind" != project ] || continue
    printf 'CREATED\t%s\t%s\n' "$kind" "$name"
    if ! fm_run_entry_valid "$kind" "$name"; then
      printf 'REMAINING\t%s\t%s\tmalformed ledger entry, not acted on\n' "$kind" "$name"
      continue
    fi
    state=$(fm_run_probe "$kind" "$name")
    case "$state" in
      gone)
        printf 'REMOVED\t%s\t%s\talready gone\n' "$kind" "$name"
        continue
        ;;
      unknown)
        printf 'REMAINING\t%s\t%s\tcannot verify (docker did not answer)\n' "$kind" "$name"
        continue
        ;;
    esac
    if [ "$kind" = dir ]; then
      if ! fm_run_dir_removable "$name" "$scratch"; then
        printf 'REMAINING\t%s\t%s\toutside this run'"'"'s scratch root %s: refused\n' "$kind" "$name" "$scratch"
        continue
      fi
    elif ! fm_run_proof_ok "$kind" "$name" "$proof"; then
      printf 'REMAINING\t%s\t%s\tdoes not carry label %s: not removed\n' "$kind" "$name" "$proof"
      continue
    fi
    if [ "$remove" -ne 1 ]; then
      printf 'REMAINING\t%s\t%s\tstill present\n' "$kind" "$name"
      continue
    fi
    if [ "$kind" = dir ]; then fm_run_remove_dir "$name"; else fm_run_remove_docker "$kind" "$name" || true; fi
    state=$(fm_run_probe "$kind" "$name")
    if [ "$state" = gone ]; then
      printf 'REMOVED\t%s\t%s\tremoved\n' "$kind" "$name"
    else
      printf 'REMAINING\t%s\t%s\tremoval did not take effect\n' "$kind" "$name"
    fi
  done <<EOF
$entries
EOF
}

# fm_run_report [heading]: reads fm_run_settle output on stdin, prints the three lists.
fm_run_report() {
  local heading=${1:-} text word count
  text=$(cat)
  [ -z "$heading" ] || printf '%s\n' "$heading"
  for word in CREATED REMOVED REMAINING; do
    count=$(printf '%s\n' "$text" | awk -F'\t' -v w="$word" '$1 == w' | wc -l | tr -d ' ')
    printf '%s (%s):\n' "$word" "$count"
    printf '%s\n' "$text" | awk -F'\t' -v w="$word" '
      $1 == w {
        if (NF >= 4 && $4 != "") printf "  %s %s  [%s]\n", $2, $3, $4
        else printf "  %s %s\n", $2, $3
      }'
  done
}

fm_run_remaining_count() {  # reads fm_run_settle output on stdin
  awk -F'\t' '$1 == "REMAINING"' | wc -l | tr -d ' '
}

# Run directories of one task, oldest first.
fm_run_rundirs() {  # <task-id>
  local base entry
  base=$(fm_run_root)/$1
  [ -d "$base" ] || return 0
  for entry in "$base"/r*-*; do
    [ -d "$entry" ] || continue
    fm_run_valid_runid "$(basename -- "$entry")" || continue
    printf '%s\n' "$entry"
  done
}

# 0 when the run directory belongs to a fm-run that is still alive.
fm_run_rundir_live() {  # <run-dir>
  local pidfile=$1/pid pid token now
  [ -f "$pidfile" ] || return 1
  pid=$(sed -n '1p' "$pidfile")
  token=$(sed -n '2p' "$pidfile")
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  now=$(fm_run_pid_token "$pid")
  [ -n "$now" ] && [ "$now" = "$token" ]
}
