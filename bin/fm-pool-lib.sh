#!/usr/bin/env bash
# shellcheck shell=bash
# fm-pool-lib.sh - the Treehouse pool slot rules bin/fm-spawn.sh applies under
# the shared project lock, so a pool slot is never named by two records and a
# slot whose task is still on the books is never handed to another task.
#
# Source after bin/fm-wake-lib.sh (which owns the claim file, its location and
# its states) and bin/fm-backend.sh (fm_meta_get).
#
# THE RULE: the claim file <pool>/<slot>/.fm-slot-owner is the only truth about
# who holds a slot; a record's worktree= line is a copy made from it.
#   - fm_pool_demote_records: a spawn that claims a slot demotes every OTHER
#     record naming it to a `#stale-worktree-record(...)` comment, in the same
#     critical section as the claim, so a later teardown of an older task can
#     never reach the new task's slot. Only the worktree= line changes; the
#     path stays in the comment as evidence.
#   - fm_pool_protect_claimed: a slot whose claim names a task that still has a
#     record is leased in place under that task's id (`treehouse lease`, a
#     state-only call that never touches the checkout) before every
#     `treehouse get`, so the pool never offers it. Only teardown frees a slot:
#     it removes the record and returns the lease together. A claim naming a
#     task with no record is stale and is not protected.
#   - fm_pool_prune_empty: numbered pool directories with nothing in them (a
#     cut that never finished, a teardown remnant) hold no slot and must not
#     count against max_trees; rmdir removes only an empty directory, so nothing
#     with content can be lost by it.

# The pool directories whose slots belong to <project>'s repository: every
# <root>/<pool>/ with a treehouse-state.json whose first numbered slot shares
# the project's Git common directory. <root> is $TREEHOUSE_ROOT, else
# ~/.treehouse.
fm_pool_dirs() {  # <project>
  local project=$1 root pool slot repo want got
  root=${TREEHOUSE_ROOT:-${HOME:-}/.treehouse}
  [ -d "$project" ] && [ -d "$root" ] || return 0
  want=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  want=$(CDPATH='' cd -- "$want" 2>/dev/null && pwd -P) || return 0
  for pool in "$root"/*/; do
    pool=${pool%/}
    [ -f "$pool/treehouse-state.json" ] || continue
    for slot in "$pool"/[0-9]*/; do
      [ -d "$slot" ] || continue
      for repo in "$slot"*/; do
        [ -e "$repo/.git" ] || continue
        got=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
        got=$(CDPATH='' cd -- "$got" 2>/dev/null && pwd -P) || continue
        [ "$got" != "$want" ] || printf '%s\n' "$pool"
        break 2
      done
    done
  done
}

# Remove the empty numbered directories of <project>'s pools; prints how many.
fm_pool_prune_empty() {  # <project>
  local project=$1 pool slot n=0
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    for slot in "$pool"/[0-9]*/; do
      [ -d "$slot" ] && [ ! -L "${slot%/}" ] || continue
      rmdir "$slot" 2>/dev/null && n=$((n + 1))
    done
  done < <(fm_pool_dirs "$project")
  printf '%s\n' "$n"
}

# Count of numbered pool directories that hold something (the slots that really
# count against max_trees) across <project>'s pools.
fm_pool_populated_count() {  # <project>
  local project=$1 pool slot n=0
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    for slot in "$pool"/[0-9]*/; do
      [ -d "$slot" ] || continue
      [ -z "$(ls -A "$slot" 2>/dev/null)" ] || n=$((n + 1))
    done
  done < <(fm_pool_dirs "$project")
  printf '%s\n' "$n"
}

# Lease in place every claimed slot whose claimant still has a record in one of
# the given state directories. Failures are ignored: an already-leased slot is
# the common case, and a pool that cannot lease still refuses a full pool on its
# own.
fm_pool_protect_claimed() {  # <project> <state-dir>...
  local project=$1 pool slot name claim task state protected=0
  shift
  command -v treehouse >/dev/null 2>&1 || { printf '0\n'; return 0; }
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    for slot in "$pool"/[0-9]*/; do
      slot=${slot%/}
      name=${slot##*/}
      claim="$slot/.fm-slot-owner"
      [ -f "$claim" ] && [ ! -L "$claim" ] || continue
      task=$(fm_meta_get "$claim" task)
      [ -n "$task" ] || continue
      for state in "$@"; do
        [ -f "$state/$task.meta" ] || continue
        ( cd "$project" && treehouse lease "$name" --lease-holder "$task" >/dev/null 2>&1 ) || true
        protected=$((protected + 1))
        break
      done
    done
  done < <(fm_pool_dirs "$project")
  printf '%s\n' "$protected"
}

# Demote every record, other than <claimant>'s own, whose worktree= names the
# slot <worktree>. Prints one `demoted <task>` line per record.
fm_pool_demote_records() {  # <worktree> <claimant-id> <state-dir>...
  local worktree=$1 claimant=$2 slot meta state id line path tmp changed
  shift 2
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 0
  for state in "$@"; do
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      id=$(basename "$meta" .meta)
      [ "$id" != "$claimant" ] || continue
      path=$(fm_meta_get "$meta" worktree)
      [ -n "$path" ] || continue
      [ "$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P)" = "$slot" ] || continue
      tmp="$meta.demote.${BASHPID:-$$}"
      changed=0
      : > "$tmp" || continue
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          worktree=*)
            printf '#stale-worktree-record(superseded-by=%s) %s\n' "$claimant" "${line#worktree=}" >> "$tmp"
            changed=1
            ;;
          *) printf '%s\n' "$line" >> "$tmp" ;;
        esac
      done < "$meta"
      if [ "$changed" = 1 ] && mv -f "$tmp" "$meta" 2>/dev/null; then
        printf 'demoted %s\n' "$id"
      else
        rm -f "$tmp"
      fi
    done
  done
}
