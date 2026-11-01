# shellcheck shell=bash
# fm-branch-retire-lib.sh - the one place a task's REMOTE head branch is deleted,
# shared by bin/fm-teardown.sh (a task proven landed) and bin/fm-pr-close.sh (a
# PR that was closed), so the creator removes the branch it made as its last act.
#
# A branch is deleted only when ALL hold; any doubt keeps it:
#   - its name is not protected: never evidence/, archive/, shots/ or capture/
#     (kept on purpose, never carry a PR), never HEAD or a trunk name, never
#     the project's base branch;
#   - origin exists and its tip for that exact branch is the tip the caller
#     proved (landed, or preserved elsewhere): a branch someone advanced since
#     is never deleted out from under them;
#   - the delete succeeds as an ordinary `git push --delete`; nothing is forced.
# The deleted tip is appended to $DATA/retired-branches.md (when DATA is set) so
# it can be recreated with `git push origin <sha>:refs/heads/<name>`.

# 0 when <branch> must never be deleted by a cleanup.
fm_branch_is_protected() {  # <branch> [<base-branch>]
  local branch=$1 base=${2:-}
  case "$branch" in
    ''|HEAD|main|master|develop|trunk|release|release/*) return 0 ;;
    evidence/*|archive/*|shots/*|capture/*) return 0 ;;
  esac
  [ -z "$base" ] || [ "$branch" != "$base" ] || return 0
  return 1
}

# fm_branch_remote_delete <worktree> <branch> <proved-tip> [<base-branch>] [<why>]
# Returns 0 when the branch is gone (or already absent), 1 when it was kept.
fm_branch_remote_delete() {
  local wt=$1 branch=$2 tip=$3 base=${4:-} why=${5:-proven landed} line remote_tip
  fm_branch_is_protected "$branch" "$base" && return 1
  [ -n "$tip" ] || return 1
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  line=$(git -C "$wt" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null) || {
    echo "note: remote branch $branch left in place - origin could not be read" >&2
    return 1
  }
  remote_tip=$(printf '%s\n' "$line" | awk 'NR == 1 { print $1 }')
  [ -n "$remote_tip" ] || return 0
  if [ "$remote_tip" != "$tip" ]; then
    echo "note: remote branch $branch ($remote_tip) left in place - it is not at the proved tip $tip" >&2
    return 1
  fi
  if ! git -C "$wt" push --quiet origin --delete "$branch" >/dev/null 2>&1; then
    echo "note: remote branch $branch left in place - the delete was refused" >&2
    return 1
  fi
  echo "retired remote branch $branch @ $tip - $why" >&2
  if [ -n "${DATA:-}" ] && mkdir -p "$DATA" 2>/dev/null; then
    printf '%s %s %s remote: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$tip" "$why" >> "$DATA/retired-branches.md" || true
  fi
  return 0
}
