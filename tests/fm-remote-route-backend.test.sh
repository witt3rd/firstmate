#!/usr/bin/env bash
# tests/fm-remote-route-backend.test.sh - the per-route remote backend setting.
#
# A remote second-mate route runs on herdr (the default, written as nothing) or on
# tmux (`backend: tmux` in its data/secondmates.md record). Pins the setting where
# each consumer reads it: the registry parser, the readiness gate's doctor
# arguments, the seed that writes it, and the spawn that refuses a launch flag
# disagreeing with it. An unmarked record must stay exactly the herdr route it
# always was.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-route-backend)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config"
REG="$PARENT/data/secondmates.md"

HERDR_LINE='- hm - Herdr mate. (host: et; root: /opt/fm; home: /home/x/hm; scope: herdr scope; projects: ; added 2026-10-31)'
TMUX_LINE='- tm - Tmux mate. (host: et; root: /opt/fm; home: /home/x/tm; backend: tmux; scope: tmux scope (with parens); projects: alpha; added 2026-10-31)'
LOCAL_LINE='- lm - Local mate. (home: /home/x/lm; scope: local scope; projects: ; added 2026-10-31)'

test_registry_reads_the_route_backend() {
  printf '%s\n%s\n%s\n' "$HERDR_LINE" "$TMUX_LINE" "$LOCAL_LINE" > "$REG"
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  assert_equals herdr "$(secondmate_registry_field "$REG" hm backend)" "an unmarked remote record is not the herdr route"
  assert_equals tmux "$(secondmate_registry_field "$REG" tm backend)" "a tmux record was not read"
  assert_equals 'tmux scope (with parens)' "$(secondmate_registry_field "$REG" tm scope)" "the backend field disturbed the scope"
  assert_equals alpha "$(secondmate_registry_field "$REG" tm projects)" "the backend field disturbed the projects"
  assert_equals /home/x/tm "$(secondmate_registry_field "$REG" tm home)" "the backend field disturbed the home"
  if secondmate_registry_field "$REG" lm backend >/dev/null 2>&1; then fail "a local record claimed a remote backend"; fi
  printf '%s\n%s\n' "$HERDR_LINE" "$TMUX_LINE" > "$TMP_ROOT/remote-only.md"
  secondmate_registry_validate_bindings "$TMP_ROOT/remote-only.md" secondmate_registry_path_key tm /home/x/tm \
    || fail "a tmux route did not validate: $SECONDMATE_REGISTRY_ERROR"
  printf '%s\n' "${TMUX_LINE/backend: tmux/backend: zellij}" > "$TMP_ROOT/bad.md"
  if secondmate_registry_field "$TMP_ROOT/bad.md" tm backend >/dev/null 2>&1; then fail "an unknown backend was accepted"; fi
  pass "the registry reads herdr by default and tmux when the record says so, and refuses anything else"
}

# A stand-in for bin/: fm-on.sh logs its arguments and answers from a script.
make_stub_bin() { # <dir> <answers: rc per call, space separated>
  local dir=$1
  mkdir -p "$dir"
  ln -sf "$ROOT/bin/fm-secondmate-registry-lib.sh" "$dir/fm-secondmate-registry-lib.sh"
  cat > "$dir/fm-on.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/calls.log"
n=\$(wc -l < "$dir/calls.log" | tr -d ' ')
rc=\$(printf '%s\n' $2 | sed -n "\${n}p")
exit "\${rc:-0}"
SH
  chmod +x "$dir/fm-on.sh"
}

readiness() { # <bin-dir> <id>
  # shellcheck source=bin/fm-remote-readiness-lib.sh
  . "$ROOT/bin/fm-remote-readiness-lib.sh"
  set +e
  FM_HOME="$PARENT" fm_remote_readiness_ensure "$1" "$2" >/dev/null
  READINESS_RC=$?
  set -e
}

test_readiness_passes_the_route_backend_to_the_doctor() {
  printf '%s\n%s\n' "$HERDR_LINE" "$TMUX_LINE" > "$REG"
  make_stub_bin "$TMP_ROOT/stub-tmux" '1 0 0'
  readiness "$TMP_ROOT/stub-tmux" tm
  expect_code 0 "$READINESS_RC" "a repaired tmux route was not ready"
  assert_equals $'tm fm-remote-doctor.sh --backend tmux\ntm fm-remote-doctor.sh --backend tmux --fix\ntm fm-remote-doctor.sh --backend tmux' \
    "$(cat "$TMP_ROOT/stub-tmux/calls.log")" "the gate did not check, repair, and re-check the tmux route"
  make_stub_bin "$TMP_ROOT/stub-herdr" '1 0 0'
  readiness "$TMP_ROOT/stub-herdr" hm
  expect_code 0 "$READINESS_RC" "a repaired herdr route was not ready"
  assert_equals $'hm fm-remote-doctor.sh\nhm fm-remote-doctor.sh --fix\nhm fm-remote-doctor.sh' \
    "$(cat "$TMP_ROOT/stub-herdr/calls.log")" "a herdr route's doctor calls changed"
  make_stub_bin "$TMP_ROOT/stub-red" '1 1 1'
  readiness "$TMP_ROOT/stub-red" tm
  expect_code 1 "$READINESS_RC" "a host that stayed red was reported ready"
  make_stub_bin "$TMP_ROOT/stub-unknown" '255'
  readiness "$TMP_ROOT/stub-unknown" tm
  expect_code 255 "$READINESS_RC" "an unreachable host was not reported unknown"
  assert_equals 1 "$(wc -l < "$TMP_ROOT/stub-unknown/calls.log" | tr -d ' ')" "an unknown completion was repaired anyway"
  pass "the readiness gate checks a tmux route with --backend tmux and a herdr route exactly as before"
}

seed() { # <backend-args...> -- ; fake ssh records the registry at the moment of the call
  mkdir -p "$TMP_ROOT/seed/p/data" "$TMP_ROOT/seed/p/state" "$TMP_ROOT/seed/p/config" "$TMP_ROOT/seed/fake"
  : > "$TMP_ROOT/seed/ssh.log"
  rm -f "$TMP_ROOT/seed/registry.during"
  cat > "$TMP_ROOT/seed/fake/fake-ssh" <<SH
#!/usr/bin/env bash
cp "$TMP_ROOT/seed/p/data/secondmates.md" "$TMP_ROOT/seed/registry.during" 2>/dev/null
printf '%s\n' "\$*" >> "$TMP_ROOT/seed/ssh.log"
exit 1
SH
  chmod +x "$TMP_ROOT/seed/fake/fake-ssh"
  set +e
  SEED_OUT=$(FM_HOME="$TMP_ROOT/seed/p" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$TMP_ROOT/seed/fake/fake-ssh" \
    FM_SECONDMATE_CHARTER='Seed charter.' FM_SECONDMATE_SCOPE='seed scope' \
    "$ROOT/bin/fm-remote-home-seed.sh" "$@" 2>&1)
  SEED_RC=$?
  set -e
}

doctor_argv_of_first_ssh_call() {
  local b64
  b64=$(head -1 "$TMP_ROOT/seed/ssh.log" | awk '{print $NF}')
  printf '%s' "$b64" | base64 -d 2>/dev/null | tr '\0' ' '
}

test_seed_records_the_route_backend() {
  rm -rf "$TMP_ROOT/seed"
  seed sm1 et /opt/fm/root /home/x/fm-home --backend tmux --no-projects
  expect_code 1 "$SEED_RC" "the fake host was not red"
  assert_contains "$(cat "$TMP_ROOT/seed/registry.during")" '/home/x/fm-home; backend: tmux; scope: seed scope;' \
    "the route was not recorded with its backend before the host was gated"
  assert_contains "$(doctor_argv_of_first_ssh_call)" 'fm-remote-doctor.sh --backend tmux' "the host was not gated on the tmux readiness"
  assert_absent "$TMP_ROOT/seed/p/data/secondmates.md" "a failed gate left the route registered"
  rm -rf "$TMP_ROOT/seed"
  seed sm1 et /opt/fm/root /home/x/fm-home --backend=herdr --no-projects
  assert_not_contains "$(cat "$TMP_ROOT/seed/registry.during")" 'backend:' "an explicit herdr route changed the record's shape"
  assert_not_contains "$(doctor_argv_of_first_ssh_call)" '--backend' "a herdr route's doctor call changed"
  rm -rf "$TMP_ROOT/seed"
  seed sm1 et /opt/fm/root /home/x/fm-home --no-projects
  assert_not_contains "$(cat "$TMP_ROOT/seed/registry.during")" 'backend:' "the default route changed the record's shape"
  pass "the seed writes backend: tmux only for a tmux route and gates the host on it"
}

test_seed_refuses_a_bad_or_changing_backend() {
  rm -rf "$TMP_ROOT/seed"
  seed sm2 et /opt/fm/root /home/x/fm-home --backend zellij --no-projects
  expect_code 1 "$SEED_RC" "an unknown backend was seeded"
  assert_contains "$SEED_OUT" 'invalid remote backend: zellij' "the refusal did not name the backend"
  seed sm2 et /opt/fm/root /home/x/fm-home --no-projects --backend
  expect_code 1 "$SEED_RC" "a --backend with no value was seeded"
  # An already-registered route keeps its backend.
  rm -rf "$TMP_ROOT/seed"
  mkdir -p "$TMP_ROOT/seed/p/data"
  printf '%s\n' '- sm3 - Seed charter. (host: et; root: /opt/fm/root; home: /home/x/fm-home; backend: tmux; scope: seed scope; projects: ; added 2026-10-31)' \
    > "$TMP_ROOT/seed/p/data/secondmates.md"
  cp "$TMP_ROOT/seed/p/data/secondmates.md" "$TMP_ROOT/seed.reg.before"
  seed sm3 et /opt/fm/root /home/x/fm-home --no-projects
  expect_code 1 "$SEED_RC" "reseeding a tmux route as herdr was accepted"
  assert_contains "$SEED_OUT" 'already registered on the tmux backend' "the refusal did not name the route's backend"
  cmp -s "$TMP_ROOT/seed.reg.before" "$TMP_ROOT/seed/p/data/secondmates.md" || fail "the refused reseed changed the registry"
  assert_equals '' "$(cat "$TMP_ROOT/seed/ssh.log")" "a refused reseed reached the host"
  pass "a route's backend is validated and never changed by reseeding"
}

test_spawn_refuses_a_flag_that_disagrees_with_the_route() {
  local home="$TMP_ROOT/spawn"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/secondmate-harness"
  printf '%s\n' "$TMUX_LINE" > "$home/data/secondmates.md"
  set +e
  SPAWN_OUT=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN=/bin/false "$ROOT/bin/fm-spawn.sh" tm --secondmate --backend herdr 2>&1)
  SPAWN_RC=$?
  set -e
  expect_code 1 "$SPAWN_RC" "a herdr flag was honored on a tmux route"
  assert_contains "$SPAWN_OUT" "runs only on its route's tmux backend, not 'herdr'" "the refusal did not name the route's backend"
  printf '%s\n' "$HERDR_LINE" > "$home/data/secondmates.md"
  set +e
  SPAWN_OUT=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN=/bin/false "$ROOT/bin/fm-spawn.sh" hm --secondmate --backend tmux 2>&1)
  SPAWN_RC=$?
  set -e
  expect_code 1 "$SPAWN_RC" "a tmux flag was honored on a herdr route"
  assert_contains "$SPAWN_OUT" "runs only on its route's herdr backend, not 'tmux'" "the refusal did not name the route's backend"
  pass "a launch flag that disagrees with the route is refused before any host is touched"
}

route_backend() { # <args...>; output in RB_OUT, status in RB_RC
  set +e
  RB_OUT=$(FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-route-backend.sh" "$@" 2>&1)
  RB_RC=$?
  set -e
}

test_route_backend_command_edits_only_the_one_field() {
  local tricky='- tx - Tricky (host: a; root: /r; home: /h; scope: x) summary. (host: et; root: /opt/fm; home: /home/x/tx; scope: s (a; b: y); projects: ; added 2026-10-31)'
  mkdir -p "$TMP_ROOT/lm"
  printf '%s\n%s\n%s\n%s\n' "$HERDR_LINE" "$TMUX_LINE" "$tricky" "${LOCAL_LINE//\/home\/x\/lm/$TMP_ROOT/lm}" > "$REG"
  cp "$REG" "$TMP_ROOT/reg.original"
  route_backend hm
  assert_equals herdr "$RB_OUT" "an unmarked record did not read herdr"
  route_backend tm
  assert_equals tmux "$RB_OUT" "a tmux record did not read tmux"
  route_backend hm tmux
  expect_code 0 "$RB_RC" "setting tmux failed: $RB_OUT"
  assert_equals 'set: hm backend herdr -> tmux' "$RB_OUT" "the change was not reported"
  assert_grep '(host: et; root: /opt/fm; home: /home/x/hm; backend: tmux; scope: herdr scope;' "$REG" "the field was not written in place"
  assert_equals 3 "$(grep -c -v '^- hm ' "$REG")" "other records changed"
  route_backend hm tmux
  assert_equals 'already: hm is on tmux' "$RB_OUT" "a repeat was not a no-op"
  route_backend hm herdr
  expect_code 0 "$RB_RC" "setting herdr failed: $RB_OUT"
  cmp -s "$TMP_ROOT/reg.original" "$REG" || fail "going back to herdr did not restore the registry byte for byte"
  route_backend tm herdr
  assert_not_contains "$(grep '^- tm ' "$REG")" 'backend:' "setting herdr left the field behind"
  route_backend tm tmux
  # Parenthesised, semicolon-bearing summary and scope text is never mistaken for the structured fields.
  route_backend tx tmux
  expect_code 0 "$RB_RC" "a record with look-alike text was refused: $RB_OUT"
  assert_grep '(host: a; root: /r; home: /h; scope: x) summary. (host: et;' "$REG" "the summary text was disturbed"
  assert_grep 'home: /home/x/tx; backend: tmux; scope: s (a; b: y); projects:' "$REG" "the structured field was not the one changed"
  route_backend lm tmux
  expect_code 1 "$RB_RC" "a local record was given a remote backend"
  route_backend nobody tmux
  expect_code 1 "$RB_RC" "an unknown id was accepted"
  route_backend hm zellij
  expect_code 2 "$RB_RC" "an unknown backend was accepted"
  pass "the route-backend command rewrites exactly one field of one record and goes back byte for byte"
}

fm_test_run \
  test_registry_reads_the_route_backend \
  test_route_backend_command_edits_only_the_one_field \
  test_readiness_passes_the_route_backend_to_the_doctor \
  test_seed_records_the_route_backend \
  test_seed_refuses_a_bad_or_changing_backend \
  test_spawn_refuses_a_flag_that_disagrees_with_the_route
