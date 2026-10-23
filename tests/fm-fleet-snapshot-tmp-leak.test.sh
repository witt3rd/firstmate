#!/usr/bin/env bash
# The snapshot must not leave fm-fleet-* scratch directories in TMPDIR on the
# contribution path, on success or on an early failure exit.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-snapshot-leak)
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
REAL_JQ=$(command -v jq)

home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/data" "$TMP_ROOT/tmp"

run_case() {  # <name> <extra-path-dir|-> ; prints leftovers
  local name=$1 fb=$2 path=$PATH
  [ "$fb" = - ] || path="$fb:$PATH"
  rm -rf "$TMP_ROOT/tmp" && mkdir -p "$TMP_ROOT/tmp"
  PATH=$path TMPDIR="$TMP_ROOT/tmp" FM_HOME="$home" "$SNAPSHOT" --contribution-input >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
  echo "$name rc=$?" >>"$TMP_ROOT/rcs"
  find "$TMP_ROOT/tmp" -mindepth 1 -maxdepth 1 -name 'fm-fleet-*'
}

left=$(run_case success -)
[ -z "$left" ] || { echo "FAIL success path leaked: $left"; exit 1; }
grep -q 'rc=0' "$TMP_ROOT/rcs" || { echo "FAIL success run did not exit 0"; cat "$TMP_ROOT/success.err"; exit 1; }

# Early failure: the contribution task read (jq -s) fails after the
# snapshot scratch dirs already exist.
fb="$TMP_ROOT/fb"; mkdir -p "$fb"
cat >"$fb/jq" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = -s ] && exit 3; done
exec "$REAL_JQ" "\$@"
SH
chmod +x "$fb/jq"
left=$(run_case failure "$fb")
grep -q 'failure rc=[1-9]' "$TMP_ROOT/rcs" || { echo "FAIL failure run did not fail"; exit 1; }
[ -z "$left" ] || { echo "FAIL failure path leaked: $left"; exit 1; }
echo "ok: no fm-fleet-* scratch left on contribution path"
