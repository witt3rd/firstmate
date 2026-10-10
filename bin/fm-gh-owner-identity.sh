#!/usr/bin/env bash
# A stand-in for the GitHub CLI that runs each gh call as the identity that owns
# the repository the call targets, so a pipeline that shells out to plain `gh`
# (the no-mistakes PR and CI steps) does not act as whichever account happens to
# be the active one. Without it, an active Enterprise Managed User account makes
# `gh pr create` on a personal repository fail with "As an Enterprise Managed
# User, you cannot access this content".
#
# Install it by symlinking this script as `gh` into a directory that precedes the
# real gh on the PATH of the process that runs gh, for example
#   ln -s "$FM_ROOT/bin/fm-gh-owner-identity.sh" ~/.local/share/fm-gh-shim/gh
# and putting that directory first on the PATH of the no-mistakes daemon.
# Installing it, and restarting the shared daemon so it sees that PATH, is the
# captain's step: this script never edits a PATH, a service, or the daemon.
#
# Identity map: $FM_GH_IDENTITIES, else $FM_HOME/config/gh-identities. One entry
# per line, "<repo-owner> <gh-login>"; blank lines and # comments are skipped,
# and an owner is matched without regard to case. An owner that has no entry
# keeps the ambient account, so an enterprise repository's own login is never
# replaced, and an absent map file makes the whole script a pass-through. A line
# that is not exactly two fields refuses the call plainly rather than being
# guessed at.
#
# The target repository owner is read, in order, from -R/--repo, GH_REPO, a
# github.com URL argument, an `api repos/<owner>/...` path, and finally the
# `origin` remote of the current directory. A call whose target cannot be read,
# or whose host is not github.com, is passed through unchanged. A mapped owner
# whose login has no token (the login is not signed in to gh) refuses the call
# with a message naming the owner and login, and never falls back to the ambient
# account, because that fallback is exactly the failure this script exists to
# prevent.
#
# The token is read with `gh auth token -u <login>` and handed to the one real gh
# process it was read for, as that process's GH_TOKEN environment variable. It is
# never printed, logged, written to a file, or placed on a command line, and no
# `gh auth` state is switched, logged in, or refreshed. A call that already
# carries GH_TOKEN or GITHUB_TOKEN, and every `gh auth` and `gh config` call,
# passes through untouched, so an explicit single-command token wins and
# credentials are never inspected or changed here.
#
# The real gh is the first `gh` on PATH that does not resolve to this script;
# FM_GH_REAL names it explicitly.
#
# Usage: gh <any gh arguments>   (through the symlink described above)
set -eu

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SELF_DIR=$(dirname "$SELF")
FM_HOME_DIR="${FM_HOME:-$(cd "$SELF_DIR/.." && pwd)}"
IDENTITIES_FILE="${FM_GH_IDENTITIES:-$FM_HOME_DIR/config/gh-identities}"

refuse() {
  printf 'fm-gh-owner-identity: %s\n' "$*" >&2
  exit 1
}

find_real_gh() {
  local candidate dir resolved
  if [ -n "${FM_GH_REAL:-}" ]; then
    [ -x "$FM_GH_REAL" ] || refuse "FM_GH_REAL=$FM_GH_REAL is not executable"
    printf '%s' "$FM_GH_REAL"
    return 0
  fi
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    candidate="$dir/gh"
    { [ -x "$candidate" ] && [ ! -d "$candidate" ]; } || continue
    resolved=$(readlink -f "$candidate" 2>/dev/null) || continue
    [ "$resolved" != "$SELF" ] || continue
    printf '%s' "$candidate"
    return 0
  done <<EOF
$(printf '%s\n' "$PATH" | tr ':' '\n')
EOF
  refuse "the real gh was not found on PATH"
}

REAL_GH=$(find_real_gh)

passthrough() {
  exec "$REAL_GH" "$@"
}

# Calls that read or change credentials or gh's own configuration, and calls that
# already carry an explicit token, are never given an identity here.
case "${1:-}" in
  auth|config) passthrough "$@" ;;
esac
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  passthrough "$@"
fi
[ -f "$IDENTITIES_FILE" ] || passthrough "$@"

# The owner of a github.com repository reference, or nothing: the bare
# OWNER/REPO form of -R, a github.com URL, or an ssh or https remote URL.
repo_owner_of() {
  local ref=$1 rest
  case "$ref" in
    https://github.com/*|http://github.com/*) rest=${ref#*://github.com/} ;;
    ssh://git@github.com/*) rest=${ref#ssh://git@github.com/} ;;
    git@github.com:*) rest=${ref#git@github.com:} ;;
    *://*|*@*) return 0 ;;
    */*/*) return 0 ;;
    */*) rest=$ref ;;
    *) return 0 ;;
  esac
  rest=${rest%%/*}
  case "$rest" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  printf '%s' "$rest"
}

target_owner() {
  local arg expect_repo=false repo='' url_owner='' path_owner='' api=false remote
  for arg in "$@"; do
    if [ "$expect_repo" = true ]; then
      repo=$arg
      expect_repo=false
      continue
    fi
    case "$arg" in
      -R|--repo) expect_repo=true ;;
      --repo=*) repo=${arg#--repo=} ;;
      -R?*) repo=${arg#-R} ;;
      api) api=true ;;
      https://github.com/*|http://github.com/*)
        [ -n "$url_owner" ] || url_owner=$(repo_owner_of "$arg")
        ;;
      http://*|https://*) return 0 ;;
      repos/*|/repos/*)
        if [ "$api" = true ] && [ -z "$path_owner" ]; then
          path_owner=${arg#/}
          path_owner=${path_owner#repos/}
          path_owner=$(repo_owner_of "${path_owner%%/*}/x")
        fi
        ;;
    esac
  done
  if [ -n "$repo" ]; then
    repo_owner_of "$repo"
    return 0
  fi
  if [ -n "${GH_REPO:-}" ]; then
    repo_owner_of "$GH_REPO"
    return 0
  fi
  if [ -n "$url_owner" ]; then
    printf '%s' "$url_owner"
    return 0
  fi
  if [ -n "$path_owner" ]; then
    printf '%s' "$path_owner"
    return 0
  fi
  remote=$(git remote get-url origin 2>/dev/null || true)
  [ -z "$remote" ] || repo_owner_of "$remote"
}

OWNER=$(target_owner "$@")
[ -n "$OWNER" ] || passthrough "$@"

# The login mapped to this owner. Every line is validated, so a typo is a refusal
# and never a silent pass-through to the wrong account.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
LOGIN=''
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%%#*}
  entry_owner=''
  entry_login=''
  entry_extra=''
  read -r entry_owner entry_login entry_extra <<EOF
$line
EOF
  [ -n "$entry_owner$entry_login$entry_extra" ] || continue
  if [ -z "$entry_login" ] || [ -n "$entry_extra" ]; then
    refuse "$IDENTITIES_FILE line $lineno must be \"<repo-owner> <gh-login>\""
  fi
  case "$entry_owner$entry_login" in
    *[!A-Za-z0-9._-]*) refuse "$IDENTITIES_FILE line $lineno holds characters a GitHub owner or login cannot have" ;;
  esac
  if [ "$(lower "$entry_owner")" = "$(lower "$OWNER")" ]; then
    LOGIN=$entry_login
  fi
done < "$IDENTITIES_FILE"
[ -n "$LOGIN" ] || passthrough "$@"

TOKEN=$("$REAL_GH" auth token -u "$LOGIN" 2>/dev/null) || TOKEN=''
if [ -z "$TOKEN" ]; then
  refuse "repository owner $OWNER maps to gh login $LOGIN, which has no token in gh (not signed in); refusing rather than acting as another account"
fi
GH_TOKEN=$TOKEN
export GH_TOKEN
unset TOKEN
passthrough "$@"
