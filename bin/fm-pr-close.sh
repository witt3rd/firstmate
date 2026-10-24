#!/usr/bin/env bash
# fm-pr-close.sh - close a GitHub PR and delete its head branch in the same act,
# so a closed PR leaves no branch behind (the leak is branches no merge touches).
#
# Usage: fm-pr-close.sh <pr-number-or-url> --repo-dir <clone> [--repo <owner/repo>] [--branch <name>]
#
#   <pr>          the PR number, or its https://github.com/<owner>/<repo>/pull/<n> URL
#   --repo-dir    any checkout of the repository; its origin is the remote the branch lives on
#   --repo        owner/repo for gh-axi (taken from a URL when one is given)
#   --branch      the PR's head branch; when omitted, the one remote branch whose tip is the PR head
#
# The PR is closed with `gh-axi pr close` unless it is already closed or merged,
# and its state is read back. The head branch is then deleted only when
# bin/fm-branch-retire-lib.sh allows it: not evidence/, archive/, shots/ or
# capture/, and its tip equal to refs/pull/<n>/head on origin. GitHub keeps that
# ref for every closed or merged PR, so the work stays recoverable from the forge
# whatever happens to the branch (reopen, or `git fetch origin pull/<n>/head`).
# Unmerged work is therefore never lost by this script, and a branch that moved
# past the PR head is kept. Exit 0 when the PR is closed or merged (the branch
# result is printed); 1 when it could not be closed or read back.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-branch-retire-lib.sh
. "$SCRIPT_DIR/fm-branch-retire-lib.sh"

usage() {
  echo "usage: fm-pr-close.sh <pr-number-or-url> --repo-dir <clone> [--repo <owner/repo>] [--branch <name>]" >&2
  exit 2
}

PR=${1:-}
[ -n "$PR" ] || usage
shift
REPO_DIR= REPO= BRANCH=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir) REPO_DIR=${2:-}; shift ;;
    --repo) REPO=${2:-}; shift ;;
    --branch) BRANCH=${2:-}; shift ;;
    *) usage ;;
  esac
  shift
done
[ -d "$REPO_DIR" ] || usage

case "$PR" in
  https://github.com/*/*/pull/*)
    rest=${PR#https://github.com/}
    REPO=${rest%%/pull/*}
    NUMBER=${rest##*/pull/}
    NUMBER=${NUMBER%%[!0-9]*}
    ;;
  *[!0-9]*|'') usage ;;
  *) NUMBER=$PR ;;
esac
[ -n "$NUMBER" ] || usage
[ -n "$REPO" ] || usage

pr_state() {
  gh-axi pr view "$NUMBER" --repo "$REPO" 2>/dev/null | awk '$1 == "state:" { print tolower($2); exit }'
}

state=$(pr_state)
case "$state" in
  merged|closed) ;;
  open)
    if ! gh-axi pr close "$NUMBER" --repo "$REPO" >/dev/null 2>&1; then
      echo "error: could not close PR $NUMBER on $REPO" >&2
      exit 1
    fi
    state=$(pr_state)
    case "$state" in
      closed|merged) ;;
      *) echo "error: PR $NUMBER on $REPO reads '$state' after closing; branch left in place" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "error: could not read the state of PR $NUMBER on $REPO; nothing changed" >&2
    exit 1
    ;;
esac
echo "PR $NUMBER on $REPO is $state"

head_sha=$(git -C "$REPO_DIR" ls-remote origin "refs/pull/$NUMBER/head" 2>/dev/null | awk 'NR == 1 { print $1 }')
if [ -z "$head_sha" ]; then
  echo "note: refs/pull/$NUMBER/head is not on origin, so the head branch is left in place" >&2
  exit 0
fi
if [ -z "$BRANCH" ]; then
  matches=$(git -C "$REPO_DIR" ls-remote --heads origin 2>/dev/null | awk -v sha="$head_sha" '$1 == sha { sub("^refs/heads/", "", $2); print $2 }')
  if [ "$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n + 0 }')" -ne 1 ]; then
    echo "note: no single remote branch is at the PR head $head_sha; name it with --branch" >&2
    exit 0
  fi
  BRANCH=$matches
fi
fm_branch_remote_delete "$REPO_DIR" "$BRANCH" "$head_sha" "" "PR $NUMBER $state; head preserved at refs/pull/$NUMBER/head" \
  || echo "kept remote branch $BRANCH"
exit 0
