#!/usr/bin/env bash
# tests/fm-remote-secondmate-spend-profile.test.sh - a REMOTE second mate follows
# the spend profile (bin/fm-spend-profile-lib.sh) of its registered scope.
#
# The parent resolves the profile from its own registry, because the remote host
# holds none, and hands it to the host. These assertions drive the real chain -
# parent fm-spawn -> fm-on -> the real remote entrypoint ->
# fm-remote-secondmate-control -> the remote host's own fm-spawn - against a fake
# herdr CLI and a fake pi whose sign-in answer depends on the store, so which
# store and model the remote pane would run is observable. The relaunch wrapper
# and the restart pass are covered in tests/fm-remote-secondmate-relaunch.test.sh
# and tests/fm-secondmate-restart.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-spend-profile)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; rm -rf -- "$TMP_ROOT"' EXIT

# The remote host's tracked code root is this branch, as a real git repository:
# fm-on and the remote entrypoint both require the dispatched command to be
# tracked there, and the remote side runs the real scripts under test.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)

# The remote host runs the Herdr fixture, whose every invocation is logged
# verbatim, so the pre-launch `export TRACEPARENT=` line and the launch
# literal's FM_TRACE_CONTEXT prefix are both observable exactly as the pane
# received them. The tmux fixture below only keeps the remote home's own
# non-second-mate tooling resolvable.
cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '❯\n'; exit 0 ;;
  send-keys) exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
# The remote job PATH starts at the host's own bin directory, so the fake pi
# lives there. Its `pi auth check` is ready when the selected store lists the provider.
cat > "$REMOTE_ROOT/bin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    if grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"api_key"}\n' "\$provider"; exit 0
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"; exit 1
    ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/pi"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
# The readiness gate is answered here rather than by the real doctor, which
# would inspect the RUNNER's own account; tests/fm-remote-doctor.test.sh owns
# the doctor's behavior against controlled account fixtures.
if printf '%s' "$4" | base64 --decode 2>/dev/null | tr '\0' '\n' | head -1 | grep -q '^fm-remote-doctor.sh$'; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

CHEAP=openrouter/deepseek/deepseek-v4.1-flash
SONNET=openrouter/anthropic/claude-sonnet-5.5
STORE="$TMP_ROOT/pi-personal"

write_dispatch() {
  cat > "$PARENT/config/crew-dispatch.json" <<JSON
{
  "spend_profiles": {
    "work": { "pi_account": { "root": "ordinary", "providers": ["openrouter"] },
      "default": { "harness": "pi", "model": "$SONNET", "effort": "medium" } },
    "personal": { "pi_account": { "root": "$STORE", "providers": ["openrouter"] },
      "default": { "harness": "pi", "model": "$CHEAP", "effort": "low" } }
  },
  "project_profiles": { "cappz-core": "personal", "animus": "personal", "spire": "work" },
  "rules": [],
  "default": { "harness": "pi", "model": "$SONNET" }
}
JSON
}
set_scope() { # <projects-csv>
  sed -i "s/projects: [^;)]*;/projects: $1;/" "$PARENT/data/secondmates.md"
}
spawn_mate() { remote_env env PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-spawn.sh" ios --secondmate "$@" 2>&1; }

# Provision and register the remote route from the captain-facing primary.
FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route"

write_dispatch
set_scope "cappz-core, animus"

# --- a missing store on the host refuses loudly and publishes nothing --------
OUT=$(spawn_mate); RC=$?
[ "$RC" -ne 0 ] || fail "a remote mate whose profile store is missing on the host must refuse: $OUT"
assert_contains "$OUT" "$STORE" "the refusal should name the missing store"
assert_absent "$PARENT/state/ios.meta" "a refused remote launch must publish no parent record"
! grep -q "^pane send-text .*launch\." "$HERDR_LOG" 2>/dev/null || fail "a refused remote launch must start no agent"
pass "remote: a mate whose profile store is missing on the host is refused before any agent starts"

# --- a single-profile scope launches on that profile's store and model -------
mkdir -p "$STORE"
printf 'openrouter\n' > "$STORE/signed-in"
reset_remote_herdr_fixture "$HERDR_STATE"
: > "$HERDR_LOG"
OUT=$(spawn_mate); RC=$?
expect_code 0 "$RC" "a remote mate whose scope is one profile should launch: $OUT"
assert_contains "$OUT" "account=$STORE profile=personal" "the spawn should report the profile and store"
assert_grep "profile=personal" "$PARENT/state/ios.meta" "the parent record should carry the profile"
assert_grep "account=$STORE" "$PARENT/state/ios.meta" "the parent record should carry the store"
assert_grep "account_provider=openrouter" "$PARENT/state/ios.meta" "the parent record should carry the provider"
assert_grep "model=$CHEAP" "$PARENT/state/ios.meta" "the parent record should carry the profile's model"
assert_grep "effort=low" "$PARENT/state/ios.meta" "the parent record should carry the profile's effort"
assert_grep "profile=personal" "$REMOTE_HOME/state/parent-route/ios.meta" "the host's endpoint record should carry the profile"
STAGED=$(remote_herdr_staged_launch "$HERDR_LOG")
[ -n "$STAGED" ] && [ -f "$STAGED" ] || fail "no staged remote launch to inspect"
assert_contains "$(cat "$STAGED")" "PI_CODING_AGENT_DIR='$STORE'" "the remote agent should launch on the profile's store, at the same absolute path"
assert_contains "$(cat "$STAGED")" "$CHEAP" "the remote agent should launch the profile's model"
pass "remote: a mate whose scope maps to one profile launches on that store, model, and effort on the host"

# --- a mixed scope keeps today's launch ------------------------------------
set_scope "cappz-core, spire"
rm -f "$PARENT/state/ios.meta"
reset_remote_herdr_fixture "$HERDR_STATE"
rm -f "$REMOTE_HOME/state/parent-route/ios.meta"
: > "$HERDR_LOG"
OUT=$(spawn_mate); RC=$?
expect_code 0 "$RC" "a remote mate spanning two profiles keeps today's launch: $OUT"
assert_not_contains "$OUT" "profile=" "a mixed scope must report no profile"
assert_no_grep "profile=" "$PARENT/state/ios.meta" "a mixed scope must record no profile"
assert_no_grep "account=" "$PARENT/state/ios.meta" "a mixed scope must record no account"
assert_contains "$(cat "$(remote_herdr_staged_launch "$HERDR_LOG")")" "codex" "a mixed scope keeps the configured secondmate pin"
pass "remote: a mate with a mixed scope keeps the launching home's pin and records no profile"

# --- a remote mate takes no per-spawn captain override ----------------------
OUT=$(spawn_mate --profile work --captain-override "x"); RC=$?
[ "$RC" -ne 0 ] || fail "--profile must refuse on a remote mate"
assert_contains "$OUT" "--profile applies to a local secondmate only" "the refusal should say why"
pass "remote: --profile is refused for a remote mate"

echo "ALL TESTS PASSED"
