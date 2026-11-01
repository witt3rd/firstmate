#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# The route's remote backend (herdr or tmux, from its data/secondmates.md record,
# herdr when the record names none) selects what the doctor checks: a tmux route
# passes --backend tmux, and a herdr route passes nothing, so its doctor calls
# are exactly the ones every herdr route has always made.
# fm_remote_readiness_backend <bin-dir> <secondmate-id> prints that backend.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_backend() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 root home data backend=
  # The registry parser is a sibling of this library; sourcing it here keeps the
  # callers' own sourcing lists unchanged.
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$bin_dir/fm-secondmate-registry-lib.sh"
  root=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$bin_dir/.." && pwd)}
  home=${FM_HOME:-$root}
  data=${FM_DATA_OVERRIDE:-$home/data}
  backend=$(secondmate_registry_field "$data/secondmates.md" "$id" backend 2>/dev/null || true)
  printf '%s\n' "${backend:-herdr}"
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 out rc backend
  local -a route_args=()

  backend=$(fm_remote_readiness_backend "$bin_dir" "$id")
  [ "$backend" != tmux ] || route_args=(--backend tmux)

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh ${route_args[@]+"${route_args[@]}"} < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh ${route_args[@]+"${route_args[@]}"} --fix < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh ${route_args[@]+"${route_args[@]}"} < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
