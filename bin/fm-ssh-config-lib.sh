#!/usr/bin/env bash
# Parse ssh_config Host lines into their patterns.
#
# One `Host` line may list several whitespace-separated patterns
# (`Host mcfeely tensor`); every exact (non-wildcard, non-negated) token is an
# alias for the same stanza. Wildcard (`*`, `?`) and negated (`!`) patterns
# never match a name exactly. A `#` token starts a comment.
#
# fm_ssh_config_same_host <config-file> <a> <b>
#   Succeeds when a equals b, or some Host line lists both as exact tokens.

fm_ssh_config_same_host() {
  local cfg=$1 a=$2 b=$3
  [ "$a" = "$b" ] && return 0
  [ -f "$cfg" ] && [ -r "$cfg" ] || return 1
  awk -v a="$a" -v b="$b" '
    { sub(/\r$/, "") }
    {
      line = $0
      if (!match(line, /^[ \t]*[Hh][Oo][Ss][Tt]([ \t]+|[ \t]*=[ \t]*)/)) next
      line = substr(line, RLENGTH + 1)
      n = split(line, tok, /[ \t]+/)
      fa = 0; fb = 0
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t == "") continue
        if (substr(t, 1, 1) == "#") break
        if (t ~ /[*?!]/) continue
        if (t == a) fa = 1
        if (t == b) fb = 1
      }
      if (fa && fb) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$cfg"
}
