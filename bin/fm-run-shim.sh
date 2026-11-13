#!/usr/bin/env bash
# fm-run-shim.sh - the docker, docker-compose, and mktemp shims bin/fm-run puts
# first on the PATH of the command it launches (docs/fm-run.md). Each wrapper in
# the run's shim directory execs this script with the tool name first:
#   fm-run-shim.sh docker|docker-compose|mktemp <args...>
#
# Every docker object the launched command creates (container, network, volume,
# image, compose project) is stamped with the run's label (fm.task=<task-id>,
# fm.run=<run-id>) and its exact name is appended to the run's ledger BEFORE the
# create runs, so a kill between the two leaves the name on record. Every temp
# path mktemp makes is recorded by exact path. Reads, removals, and everything
# else pass straight through to the next docker on the PATH, whose own guard
# (the fleet docker shim) still applies; this shim adds no refusal of removals.
#
# Environment (set by bin/fm-run): FM_TASK_LABEL FM_RUN_ID FM_RUN_LEDGER
# FM_RUN_SCRATCH. Outside fm-run the shim refuses a create rather than let an
# unlabelled object through.

FM_RUN_SHIM_SELF=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
FM_RUN_SHIM_DIR=$(dirname -- "$FM_RUN_SHIM_SELF")
# shellcheck source=bin/fm-run-lib.sh
. "$FM_RUN_SHIM_DIR/fm-run-lib.sh"

TOOL=${1:-}
[ "$#" -eq 0 ] || shift

die() {
  printf 'fm-run shim: refused: %s\n' "$*" >&2
  exit 126
}

REAL_PATH=$(fm_run_real_path)

pass_through() {  # <tool> args...
  local tool=$1
  shift
  export PATH=$REAL_PATH
  exec "$tool" "$@"
}

require_run() {
  [ -n "${FM_TASK_LABEL:-}" ] && [ -n "${FM_RUN_ID:-}" ] && [ -n "${FM_RUN_LEDGER:-}" ] && [ -w "${FM_RUN_LEDGER:-/nonexistent}" ] ||
    die "this create is not inside a live fm-run launch, so it could not be recorded for removal (run it as: fm-run <task-id> -- <command>)"
}

rand6() {
  printf '%06x' $(((RANDOM << 15 | RANDOM) & 16777215))
}

# --- option scanning ------------------------------------------------------------
# scan_opts <bool-long-options> <value-short-chars> args...: sets SCAN_POS (index of
# the first positional, or the argument count) and SCAN_OPTS ("key=value" strings;
# long options keep their name, short ones their letter).
SCAN_POS=0
SCAN_OPTS=()
scan_opts() {
  local boolset=" $1 " valshort=$2 i=0 n a key rest c
  shift 2
  local -a args=("$@")
  n=$#
  SCAN_POS=$n
  SCAN_OPTS=()
  while [ "$i" -lt "$n" ]; do
    a=${args[$i]}
    case "$a" in
      --)
        SCAN_POS=$((i + 1))
        return 0
        ;;
      --*=*)
        key=${a%%=*}
        SCAN_OPTS+=("${key#--}=${a#*=}")
        ;;
      --*)
        key=${a#--}
        case "$boolset" in
          *" $key "*) SCAN_OPTS+=("$key=") ;;
          *)
            i=$((i + 1))
            SCAN_OPTS+=("$key=${args[$i]:-}")
            ;;
        esac
        ;;
      -?*)
        rest=${a#-}
        while [ -n "$rest" ]; do
          c=${rest:0:1}
          rest=${rest:1}
          case "$valshort" in
            *"$c"*)
              if [ -n "$rest" ]; then
                SCAN_OPTS+=("$c=$rest")
              else
                i=$((i + 1))
                SCAN_OPTS+=("$c=${args[$i]:-}")
              fi
              rest=''
              ;;
            *) SCAN_OPTS+=("$c=") ;;
          esac
        done
        ;;
      *)
        SCAN_POS=$i
        return 0
        ;;
    esac
    i=$((i + 1))
  done
}

# opt_values <key>...: every value given for any of the keys, one per line.
opt_values() {
  local entry key want
  for entry in ${SCAN_OPTS[@]+"${SCAN_OPTS[@]}"}; do
    key=${entry%%=*}
    for want in "$@"; do
      [ "$key" != "$want" ] || printf '%s\n' "${entry#*=}"
    done
  done
}

opt_last() {  # <key>...
  opt_values "$@" | tail -n 1
}

refuse_label_override() {  # uses SCAN_OPTS
  local value
  while IFS= read -r value; do
    case "$value" in
      "$FM_RUN_LABEL_KEY"=* | "$FM_RUN_LABEL_KEY" | "$FM_RUN_RUN_KEY"=* | "$FM_RUN_RUN_KEY")
        die "the labels $FM_RUN_LABEL_KEY and $FM_RUN_RUN_KEY belong to fm-run; remove --label $value"
        ;;
    esac
  done <<EOF
$(opt_values label l)
EOF
}

# --- docker ------------------------------------------------------------------------

exists_now() {  # <kind> <name>: 0 when the object exists (or its state is unknown)
  [ "$(fm_run_probe "$1" "$2")" != gone ]
}

# Record an object that does not exist yet. A pre-existing name is never recorded:
# it belongs to someone else, and the create will fail or reuse it.
record_new() {  # <kind> <name>
  exists_now "$1" "$2" || fm_run_record "$FM_RUN_LEDGER" "$1" "$2" "$FM_RUN_LABEL_KEY=$FM_TASK_LABEL"
}

# Run the real tool as a child so the shim can read results afterward, forwarding
# the terminating signals fm-run sends to its process tree.
CHILD_PID=''
forward() {
  [ -z "$CHILD_PID" ] || kill -"$1" "$CHILD_PID" 2>/dev/null
}
run_real() {  # <tool> args...
  local tool=$1 rc
  shift
  trap 'forward TERM' TERM
  trap 'forward INT' INT
  trap 'forward HUP' HUP
  PATH=$REAL_PATH "$tool" "$@" <&0 &
  CHILD_PID=$!
  wait "$CHILD_PID"
  rc=$?
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    wait "$CHILD_PID"
    rc=$?
  done
  CHILD_PID=''
  return "$rc"
}

DOCKER_VALUE_GLOBALS=' -H --host -c --context --config -l --log-level --tlscacert --tlscert --tlskey '
RUN_BOOL='rm detach interactive tty privileged init read-only publish-all no-healthcheck sig-proxy oom-kill-disable help quiet disable-content-trust use-api-socket'
RUN_VALSHORT='acehlmpuvw'

# Pre-create the named volumes a run/create would otherwise create unlabelled.
precreate_volumes() {
  local spec src type
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    case "$spec" in
      *:*) src=${spec%%:*} ;;
      *) continue ;;
    esac
    if printf '%s' "$src" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
      ensure_volume "$src"
    fi
  done <<EOF
$(opt_values v volume)
EOF
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    type=$(printf '%s' "$spec" | tr ',' '\n' | sed -n 's/^type=//p' | tail -n 1)
    src=$(printf '%s' "$spec" | tr ',' '\n' | sed -n 's/^\(source\|src\)=//p' | tail -n 1)
    [ -z "$type" ] || [ "$type" = volume ] || continue
    if printf '%s' "$src" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
      ensure_volume "$src"
    fi
  done <<EOF
$(opt_values mount)
EOF
}

ensure_volume() {  # <name>
  [ "$(fm_run_probe volume "$1")" = gone ] || return 0
  fm_run_record "$FM_RUN_LEDGER" volume "$1" "$FM_RUN_LABEL_KEY=$FM_TASK_LABEL"
  PATH=$REAL_PATH docker volume create --label "$FM_RUN_LABEL_KEY=$FM_TASK_LABEL" --label "$FM_RUN_RUN_KEY=$FM_RUN_ID" "$1" >/dev/null ||
    die "could not create the labelled volume $1"
}

docker_create_container() {  # <globals-count> args... (args hold the full docker argv)
  local verb_index=$1 name
  shift
  local -a argv=("$@")
  local -a head=("${argv[@]:0:$((verb_index + 1))}")
  local -a tail=("${argv[@]:$((verb_index + 1))}")
  local -a labels=(--label "$FM_RUN_LABEL_KEY=$FM_TASK_LABEL" --label "$FM_RUN_RUN_KEY=$FM_RUN_ID")
  scan_opts "$RUN_BOOL" "$RUN_VALSHORT" ${tail[@]+"${tail[@]}"}
  refuse_label_override
  name=$(opt_last name)
  if [ -z "$name" ]; then
    name=$FM_TASK_LABEL-$(rand6)
    labels+=(--name "$name")
  fi
  printf '%s' "$name" | grep -Eq "$FM_RUN_DOCKER_NAME_RE" || die "container name '$name' is not an exact literal name"
  precreate_volumes
  record_new container "$name"
  pass_through docker "${head[@]}" "${labels[@]}" ${tail[@]+"${tail[@]}"}
}

docker_create_simple() {  # <kind> <verb-index> args...   volume|network create
  local kind=$1 verb_index=$2 name bool=''
  shift 2
  local -a argv=("$@")
  local -a head=("${argv[@]:0:$((verb_index + 1))}")
  local -a tail=("${argv[@]:$((verb_index + 1))}")
  local -a labels=(--label "$FM_RUN_LABEL_KEY=$FM_TASK_LABEL" --label "$FM_RUN_RUN_KEY=$FM_RUN_ID")
  [ "$kind" != network ] || bool='internal attachable ipv6 ipv4 ingress config-only help'
  scan_opts "$bool" 'do' ${tail[@]+"${tail[@]}"}
  refuse_label_override
  local nameargs=()
  # The name is the first positional; a volume may omit it (docker then makes an
  # anonymous one, so the shim names it).
  name=''
  [ "$kind" != volume ] || name=$(opt_last name)
  if [ -z "$name" ] && [ "$SCAN_POS" -lt "${#tail[@]}" ]; then
    name=${tail[$SCAN_POS]}
  fi
  if [ -z "$name" ] && [ "$kind" = network ]; then
    die "network create needs a name"
  fi
  if [ -z "$name" ]; then
    name=$FM_TASK_LABEL-$(rand6)
    nameargs=("$name")
  fi
  printf '%s' "$name" | grep -Eq "$FM_RUN_DOCKER_NAME_RE" || die "$kind name '$name' is not an exact literal name"
  record_new "$kind" "$name"
  pass_through docker "${head[@]}" "${labels[@]}" ${tail[@]+"${tail[@]}"} ${nameargs[@]+"${nameargs[@]}"}
}

docker_build() {  # <verb-index> args...
  local verb_index=$1 i a tag iidfile own_iid=0 rc id
  shift
  local -a argv=("$@")
  local -a head=("${argv[@]:0:$((verb_index + 1))}")
  local -a tail=("${argv[@]:$((verb_index + 1))}")
  local -a labels=(--label "$FM_RUN_LABEL_KEY=$FM_TASK_LABEL" --label "$FM_RUN_RUN_KEY=$FM_RUN_ID")
  local -a extra=() tags=()
  iidfile=''
  i=0
  while [ "$i" -lt "${#tail[@]}" ]; do
    a=${tail[$i]}
    case "$a" in
      -t | --tag)
        i=$((i + 1))
        tags+=("${tail[$i]:-}")
        ;;
      --tag=*) tags+=("${a#--tag=}") ;;
      -t?*) tags+=("${a#-t}") ;;
      --iidfile)
        i=$((i + 1))
        iidfile=${tail[$i]:-}
        ;;
      --iidfile=*) iidfile=${a#--iidfile=} ;;
      --label | -l)
        case "${tail[$((i + 1))]:-}" in "$FM_RUN_LABEL_KEY"* | "$FM_RUN_RUN_KEY"*) die "the labels $FM_RUN_LABEL_KEY and $FM_RUN_RUN_KEY belong to fm-run" ;; esac
        ;;
      --label=*)
        case "${a#--label=}" in "$FM_RUN_LABEL_KEY"* | "$FM_RUN_RUN_KEY"*) die "the labels $FM_RUN_LABEL_KEY and $FM_RUN_RUN_KEY belong to fm-run" ;; esac
        ;;
    esac
    i=$((i + 1))
  done
  for tag in ${tags[@]+"${tags[@]}"}; do
    [ -n "$tag" ] || continue
    printf '%s' "$tag" | grep -Eq "$FM_RUN_DOCKER_NAME_RE" || die "image tag '$tag' is not an exact literal name"
    record_new image "$tag"
  done
  if [ -z "$iidfile" ]; then
    # shellcheck disable=SC2153  # set by bin/fm-run
    iidfile=$FM_RUN_DIR/iid.$(rand6)
    own_iid=1
    extra=(--iidfile "$iidfile")
  fi
  run_real docker "${head[@]}" "${labels[@]}" ${extra[@]+"${extra[@]}"} ${tail[@]+"${tail[@]}"}
  rc=$?
  if [ -s "$iidfile" ]; then
    id=$(sed -n '1p' "$iidfile")
    case "$id" in
      sha256:*) fm_run_record "$FM_RUN_LEDGER" image "$id" "$FM_RUN_LABEL_KEY=$FM_TASK_LABEL" ;;
    esac
  fi
  [ "$own_iid" -eq 0 ] || command rm -f -- "$iidfile"
  exit "$rc"
}

# --- compose -----------------------------------------------------------------------

# compose_main <tool> <prefix-count> args...: <tool> is docker or docker-compose; the
# first <prefix-count> args are docker's own (everything up to and including
# "compose"), the rest are compose arguments.
compose_main() {
  local tool=$1 prefix_count=$2 i a want project project_dir='' file_dir='' verb='' final lower
  shift 2
  local -a argv=("$@")
  local -a prefix=("${argv[@]:0:$prefix_count}")
  local -a rest=("${argv[@]:$prefix_count}")
  local -a kept=()
  project=''
  i=0
  while [ "$i" -lt "${#rest[@]}" ]; do
    a=${rest[$i]}
    case "$a" in
      -p | --project-name)
        i=$((i + 1))
        project=${rest[$i]:-}
        ;;
      --project-name=*) project=${a#--project-name=} ;;
      -f | --file)
        kept+=("$a" "${rest[$((i + 1))]:-}")
        [ -n "$file_dir" ] || file_dir=$(dirname -- "${rest[$((i + 1))]:-.}")
        i=$((i + 1))
        ;;
      --file=*)
        kept+=("$a")
        [ -n "$file_dir" ] || file_dir=$(dirname -- "${a#--file=}")
        ;;
      --project-directory)
        kept+=("$a" "${rest[$((i + 1))]:-}")
        project_dir=${rest[$((i + 1))]:-}
        i=$((i + 1))
        ;;
      --project-directory=*)
        kept+=("$a")
        project_dir=${a#--project-directory=}
        ;;
      --profile | --env-file | --ansi | --parallel | --progress)
        kept+=("$a" "${rest[$((i + 1))]:-}")
        i=$((i + 1))
        ;;
      -*) kept+=("$a") ;;
      *)
        verb=$a
        break
        ;;
    esac
    i=$((i + 1))
  done
  local -a tail=("${rest[@]:$((i + 1))}")
  case "$verb" in
    '' | version | help) pass_through "$tool" ${prefix[@]+"${prefix[@]}"} ${rest[@]+"${rest[@]}"} ;;
  esac
  want=''
  case "$verb" in up | create | run | build) want=1 ;; esac
  [ -n "$project" ] || project=${COMPOSE_PROJECT_NAME:-}
  if [ -z "$project" ]; then
    local base=${project_dir:-${file_dir:-$PWD}}
    project=$(basename -- "$(CDPATH='' cd -P -- "$base" 2>/dev/null && pwd -P || printf '%s' "$base")")
  fi
  project=$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '-')
  lower=$(printf '%s' "$FM_TASK_LABEL" | tr '[:upper:]' '[:lower:]')
  if ! { [ "$lower" = "$FM_TASK_LABEL" ] && printf '%s' "$lower" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; }; then
    [ -z "$want" ] || die "task id '$FM_TASK_LABEL' cannot prefix a compose project name (lowercase letters, digits, - and _ only)"
    pass_through "$tool" ${prefix[@]+"${prefix[@]}"} ${rest[@]+"${rest[@]}"}
  fi
  case "$project" in
    "$lower" | "$lower"-* | "$lower"_*) final=$project ;;
    *) final=$lower-$project ;;
  esac
  if [ -n "$want" ]; then
    require_run
    if [ -z "$(fm_run_project_members "$final")" ]; then
      fm_run_record "$FM_RUN_LEDGER" project "$final" "com.docker.compose.project=$final"
    fi
  fi
  if [ -z "$want" ]; then
    pass_through "$tool" ${prefix[@]+"${prefix[@]}"} -p "$final" ${kept[@]+"${kept[@]}"} "$verb" ${tail[@]+"${tail[@]}"}
  fi
  local before after kind name line tab
  tab=$(printf '\t')
  before=$(fm_run_project_members "$final")
  run_real "$tool" ${prefix[@]+"${prefix[@]}"} -p "$final" ${kept[@]+"${kept[@]}"} "$verb" ${tail[@]+"${tail[@]}"}
  local rc=$?
  after=$(fm_run_project_members "$final")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$before" | grep -Fxq -- "$line" && continue
    kind=${line%%"$tab"*}
    name=${line#*"$tab"}
    fm_run_entry_valid "$kind" "$name" && fm_run_record "$FM_RUN_LEDGER" "$kind" "$name" "com.docker.compose.project=$final"
  done <<EOF
$after
EOF
  exit "$rc"
}

docker_main() {
  local i=0 n=$# a remote='' sub next
  local -a argv=("$@")
  while [ "$i" -lt "$n" ]; do
    a=${argv[$i]}
    case "$a" in
      -H | --host | -c | --context)
        remote=1
        i=$((i + 2))
        ;;
      -H* | --host=* | --context=*)
        remote=1
        i=$((i + 1))
        ;;
      -*)
        case "$DOCKER_VALUE_GLOBALS" in
          *" $a "*) i=$((i + 2)) ;;
          *) i=$((i + 1)) ;;
        esac
        ;;
      *) break ;;
    esac
  done
  sub=${argv[$i]:-}
  next=${argv[$((i + 1))]:-}
  local kind='' verb_index=$i
  case "$sub" in
    run | create) kind=container ;;
    container)
      case "$next" in run | create) kind=container; verb_index=$((i + 1)) ;; esac
      ;;
    volume)
      [ "$next" != create ] || { kind=volume; verb_index=$((i + 1)); }
      ;;
    network)
      [ "$next" != create ] || { kind=network; verb_index=$((i + 1)); }
      ;;
    build) kind=image ;;
    builder)
      [ "$next" != build ] || { kind=image; verb_index=$((i + 1)); }
      ;;
    image)
      [ "$next" != build ] || { kind=image; verb_index=$((i + 1)); }
      ;;
    buildx)
      case "$next" in build | b) kind=image; verb_index=$((i + 1)) ;; esac
      ;;
    compose)
      [ -z "$remote" ] || die "compose through -H/--context is not covered by fm-run; run it on the host that owns the daemon"
      compose_main docker $((i + 1)) "$@"
      ;;
  esac
  [ -n "$kind" ] || pass_through docker "$@"
  [ -z "$remote" ] || die "a create with -H/--host/--context targets another daemon, which this run's ledger cannot clean; run it through fm-run on that host"
  require_run
  case "$kind" in
    container) docker_create_container "$verb_index" "$@" ;;
    volume | network) docker_create_simple "$kind" "$verb_index" "$@" ;;
    image) docker_build "$verb_index" "$@" ;;
  esac
}

# --- mktemp ------------------------------------------------------------------------

mktemp_main() {
  local -a args=("$@")
  local i=0 n=$# a tmpl='' tmpl_index=-1 has_dir=0 dry=0 path out rc dir
  while [ "$i" -lt "$n" ]; do
    a=${args[$i]}
    case "$a" in
      -p)
        has_dir=1
        i=$((i + 1))
        ;;
      -p?* | --tmpdir | --tmpdir=*) has_dir=1 ;;
      --dry-run) dry=1 ;;
      --*) ;;
      -*) case "$a" in *u*) dry=1 ;; esac ;;
      *)
        tmpl=$a
        tmpl_index=$i
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$dry" -eq 1 ] || [ -z "${FM_RUN_LEDGER:-}" ] || [ -z "${FM_RUN_SCRATCH:-}" ]; then
    pass_through mktemp "$@"
  fi
  if [ "$tmpl_index" -ge 0 ] && [ "$has_dir" -eq 0 ]; then
    case "$tmpl" in
      */*)
        dir=$(dirname -- "$tmpl")
        case "$dir" in
          /tmp | /var/tmp | "${TMPDIR:-/nonexistent}" | "$FM_RUN_SCRATCH")
            args[tmpl_index]=$(basename -- "$tmpl")
            args=(-p "$FM_RUN_SCRATCH" "${args[@]}")
            ;;
        esac
        ;;
    esac
  fi
  out=$(TMPDIR=$FM_RUN_SCRATCH PATH=$REAL_PATH mktemp "${args[@]}")
  rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  path=$out
  case "$path" in
    /*) ;;
    *) path=$PWD/$path ;;
  esac
  fm_run_record "$FM_RUN_LEDGER" dir "$path" - || true
  printf '%s\n' "$out"
}

case "$TOOL" in
  docker) docker_main "$@" ;;
  docker-compose) compose_main docker-compose 0 "$@" ;;
  mktemp) mktemp_main "$@" ;;
  *) die "unknown shim tool '$TOOL'" ;;
esac
