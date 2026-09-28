#!/usr/bin/env bash
# Behavior tests for the caretaker pattern's scheduled health sweep and seed-time
# recurrence ledger: bin/fm-caretaker-sweep.sh (due/not-due schedule, durable
# record, watcher-check arming, read-only snapshot) and the ledger that
# bin/fm-home-seed.sh and bin/fm-remote-home-provision.sh initialize for a
# caretaker charter. Charters come from
# the real bin/fm-brief.sh scaffold, so the lines the schedule reads back are
# the lines a caretaker home actually carries. The snapshot case fingerprints
# every byte, mode, and mtime under the project clones and their origin before
# and after, and first proves that an ordinary `git status` would have rewritten
# the index in the same fixture, so the read-only assertion cannot go vacuous.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-caretaker-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-caretaker-sweep)
T0=1800000000

# scaffold_charter <home> <id> [fm-brief flags...]: write <home>/data/charter.md
# from the real scaffold, the way seeding copies it into a secondmate home.
scaffold_charter() {
  local home=$1 id=$2 scratch
  shift 2
  scratch="$TMP_ROOT/scaffold-${home##*/}-$id"
  mkdir -p "$home/data" "$home/state" "$scratch"
  FM_HOME="$home" FM_DATA_OVERRIDE="$scratch" \
    FM_SECONDMATE_CHARTER="Persistent caretaker for $id." FM_SECONDMATE_SCOPE="$id work" \
    "$ROOT/bin/fm-brief.sh" "$id" --secondmate "$@" --no-projects >/dev/null \
    || fail "could not scaffold the $id charter"
  cp "$scratch/$id/brief.md" "$home/data/charter.md"
}

# due_at <home> <epoch>: the check body's output at that clock.
due_at() {
  local out status=0
  out=$(FM_HOME="$1" FM_CARETAKER_SWEEP_NOW="$2" "$SWEEP" due 2>&1) || status=$?
  expect_code 0 "$status" "due must always exit 0"
  printf '%s' "$out"
}

# tree_fingerprint <path>...: every entry's path, mode, size, and mtime, plus a
# content hash for files and the target for symlinks, sorted.
tree_fingerprint() {
  perl -MFile::Find -MDigest::SHA=sha256_hex -e '
    my @rows;
    find({ no_chdir => 1, wanted => sub {
      my @st = lstat($_) or die "lstat $_: $!\n";
      my $row = sprintf("%s %o %d %d", $_, $st[2], $st[7], $st[9]);
      if (-l _) {
        $row .= " -> " . readlink($_);
      } elsif (-f _) {
        open(my $fh, "<:raw", $_) or die "open $_: $!\n";
        local $/;
        my $bytes = <$fh>;
        $row .= " " . sha256_hex(defined $bytes ? $bytes : "");
      }
      push @rows, $row;
    }}, @ARGV);
    print "$_\n" for sort @rows;
  ' "$@"
}

commit_empty() {  # <repo> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "$2"
}

test_due_follows_the_declared_cadence_and_durable_record() {
  local home out
  home="$TMP_ROOT/due-home"

  # No charter, a plain charter, and a caretaker without a sweep declare nothing.
  mkdir -p "$home/data"
  [ -z "$(due_at "$home" "$T0")" ] || fail "a home with no charter reported a sweep"
  scaffold_charter "$home" plain
  [ -z "$(due_at "$home" "$T0")" ] || fail "a plain secondmate charter reported a sweep"
  scaffold_charter "$home" idle-keeper --caretaker
  [ -z "$(due_at "$home" "$T0")" ] || fail "a caretaker without --sweep-every reported a sweep"
  if FM_HOME="$home" "$SWEEP" start >/dev/null 2>&1; then
    fail "start succeeded without a declared sweep"
  fi
  assert_absent "$home/data/caretaker-sweep.record" "a refused start still wrote the record"

  # A declared cadence with no completed sweep is due at once.
  scaffold_charter "$home" keeper --caretaker --sweep-every 12h
  out=$(due_at "$home" "$T0")
  assert_contains "$out" 'caretaker health sweep due (every 12h; no sweep completed yet)' \
    "a never-swept caretaker was not reported due"
  assert_contains "$out" 'load the caretaker-sweep skill' "the due line does not name the sweep procedure"
  [ "$(printf '%s\n' "$out" | grep -c '')" = 1 ] || fail "the due check printed more than one line"
  if FM_HOME="$home" FM_CARETAKER_SWEEP_NOW="$T0" "$SWEEP" complete >/dev/null 2>&1; then
    fail "complete succeeded with no started sweep"
  fi

  # A started sweep silences the check for the in-progress bound (the smaller
  # of the cadence and the stall cap), then comes due again.
  FM_HOME="$home" FM_CARETAKER_SWEEP_NOW="$T0" "$SWEEP" start >/dev/null || fail "start failed"
  [ -z "$(due_at "$home" $((T0 + 1)))" ] || fail "a sweep in progress re-rang the check"
  [ -z "$(due_at "$home" $((T0 + 43199)))" ] || fail "a sweep in progress re-rang before its bound"
  out=$(due_at "$home" $((T0 + 43200)))
  assert_contains "$out" 'caretaker health sweep due again (every 12h; the sweep started' \
    "an abandoned sweep did not come due again at its bound"
  out=$(FM_HOME="$home" FM_CARETAKER_SWEEP_STALL_SECS=3600 FM_CARETAKER_SWEEP_NOW=$((T0 + 3600)) "$SWEEP" due)
  assert_contains "$out" 'due again' "the stall cap did not shorten the in-progress bound"

  # Completion starts the cadence; the record alone carries it across restarts,
  # so a fresh process neither re-sweeps early nor skips a sweep that came due.
  FM_HOME="$home" FM_CARETAKER_SWEEP_NOW=$((T0 + 600)) "$SWEEP" complete >/dev/null || fail "complete failed"
  assert_grep 'schema=fm-caretaker-sweep.v1' "$home/data/caretaker-sweep.record" "the record lost its schema"
  assert_grep "completed_at=$((T0 + 600))" "$home/data/caretaker-sweep.record" "the record lost its completion"
  [ -z "$(due_at "$home" $((T0 + 600 + 43199)))" ] || fail "a completed sweep came due before its cadence"
  out=$(due_at "$home" $((T0 + 600 + 43200)))
  assert_contains "$out" 'caretaker health sweep due (every 12h; last completed' \
    "a sweep did not come due one cadence after completion"
  out=$(due_at "$home" $((T0 + 600 + 43200 * 5)))
  assert_contains "$out" 'caretaker health sweep due (every 12h; last completed' \
    "a sweep that came due while the home was down was skipped"
  out=$(FM_HOME="$home" FM_CARETAKER_SWEEP_NOW=$((T0 + 700)) "$SWEEP" status)
  assert_contains "$out" 'cadence: every 12h' "status did not read the scaffolded cadence back"
  assert_contains "$out" 'verdict: waiting' "status did not report a waiting schedule"

  # A hand-broken declaration is reported by the check itself and blocks start.
  sed 's/^Health sweep cadence: every 12h$/Health sweep cadence: every 0d/' "$home/data/charter.md" > "$home/data/charter.tmp"
  mv "$home/data/charter.tmp" "$home/data/charter.md"
  out=$(due_at "$home" $((T0 + 700)))
  assert_contains "$out" 'caretaker health sweep declaration in data/charter.md is unusable' \
    "a malformed cadence was not reported"
  if FM_HOME="$home" "$SWEEP" start >/dev/null 2>&1; then
    fail "start accepted a malformed cadence"
  fi
  pass "fm-caretaker-sweep.sh: due follows the declared cadence, stays silent while a sweep runs, and survives restarts through its record"
}

test_arm_registers_the_check_only_for_a_declared_caretaker() {
  local home plain out before
  home="$TMP_ROOT/arm-home"
  plain="$TMP_ROOT/arm-plain-home"
  scaffold_charter "$home" keeper --caretaker --sweep-every 7d

  # A main home, without the secondmate marker, never arms a sweep.
  if FM_HOME="$home" "$SWEEP" arm >/dev/null 2>&1; then
    fail "arm succeeded in a home that is not a seeded secondmate"
  fi
  FM_HOME="$home" "$SWEEP" arm --if-declared >/dev/null || fail "arm --if-declared failed in an unmarked home"
  assert_absent "$home/state/caretaker-sweep.check.sh" "an unmarked home was armed"

  printf 'keeper\n' > "$home/.fm-secondmate-home"
  FM_HOME="$home" "$SWEEP" arm >/dev/null || fail "arm failed for a declared caretaker"
  assert_present "$home/state/caretaker-sweep.check.sh" "arm did not write the check shim"
  assert_present "$home/state/caretaker-sweep.check-trust" "arm did not bind the check shim"
  out=$(FM_HOME="$home" "$SWEEP" status)
  assert_contains "$out" 'check: armed' "the armed check does not validate as registered"
  # The watcher runs the registered bytes; they report this home's schedule.
  out=$(env -u FM_HOME "$home/state/caretaker-sweep.check.sh")
  assert_contains "$out" 'caretaker health sweep due (every 7d; no sweep completed yet)' \
    "the registered check did not report the home's due sweep"
  # A registered check keeps an otherwise idle caretaker's watcher needed.
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$ROOT/bin/fm-supervision-lib.sh"
  fm_supervision_needed "$home/state" || fail "an armed caretaker home does not need a watcher"

  # Re-arming is idempotent.
  before=$(tree_fingerprint "$home/state")
  FM_HOME="$home" "$SWEEP" arm --if-declared >/dev/null || fail "re-arming failed"
  [ "$(tree_fingerprint "$home/state")" = "$before" ] || fail "re-arming rewrote an already-armed check"

  # Dropping the declaration retires the check at the next arm --if-declared.
  scaffold_charter "$home" keeper-idle --caretaker
  FM_HOME="$home" "$SWEEP" arm --if-declared >/dev/null || fail "arm --if-declared failed after the declaration was removed"
  assert_absent "$home/state/caretaker-sweep.check.sh" "a removed declaration left the check armed"
  assert_absent "$home/state/caretaker-sweep.check-trust" "a removed declaration left the trust binding"
  fm_supervision_needed "$home/state" && fail "a disarmed idle caretaker still needs a watcher"

  # A symlink at the shim path is refused rather than followed.
  scaffold_charter "$plain" keeper --caretaker --sweep-every 7d
  printf 'keeper\n' > "$plain/.fm-secondmate-home"
  printf 'outside\n' > "$TMP_ROOT/arm-outside"
  ln -s "$TMP_ROOT/arm-outside" "$plain/state/caretaker-sweep.check.sh"
  if FM_HOME="$plain" "$SWEEP" arm >/dev/null 2>&1; then
    fail "arm followed a symlink at the check path"
  fi
  [ "$(cat "$TMP_ROOT/arm-outside")" = outside ] || fail "arm wrote through a symlinked check path"
  pass "fm-caretaker-sweep.sh: arm registers the watcher check only for a declared caretaker and retires it with the declaration"
}

test_snapshot_never_mutates_project_clones() {
  local home projects origin seed out before_projects before_origin control
  home="$TMP_ROOT/snapshot-home"
  projects="$home/projects"
  origin="$TMP_ROOT/snapshot-origin.git"
  seed="$TMP_ROOT/snapshot-seed"
  scaffold_charter "$home" keeper --caretaker --sweep-every 7d
  # The home is itself a git checkout, as a real Firstmate home is.
  git -C "$home" init -q -b main

  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$seed" 2>/dev/null
  commit_empty "$seed" one
  git -C "$seed" push -q origin main
  mkdir -p "$projects"
  git clone -q "$origin" "$projects/alpha"
  git clone -q "$origin" "$projects/gamma"
  # alpha: origin moved on unfetched, a local-only branch, tracked and untracked
  # changes, a stash, a linked worktree, and a file whose stat no longer matches
  # its index entry, so an ordinary status would rewrite the index.
  commit_empty "$seed" two
  git -C "$seed" push -q origin main
  # beta is current with origin; delta carries one unpushed commit.
  git clone -q "$origin" "$projects/beta"
  git clone -q "$origin" "$projects/delta"
  commit_empty "$projects/delta" unpushed
  printf 'tracked\n' > "$projects/alpha/tracked.txt"
  git -C "$projects/alpha" add tracked.txt
  git -C "$projects/alpha" -c user.name=t -c user.email=t@example.invalid commit -qm tracked
  printf 'stash me\n' >> "$projects/alpha/tracked.txt"
  git -C "$projects/alpha" -c user.name=t -c user.email=t@example.invalid stash -q
  git -C "$projects/alpha" worktree add -q -b feature "$TMP_ROOT/snapshot-alpha-feature"
  printf 'edit\n' >> "$projects/alpha/tracked.txt"
  printf 'new\n' > "$projects/alpha/untracked.txt"
  printf 'x\n' > "$projects/alpha/restat.txt"
  git -C "$projects/alpha" add restat.txt
  touch -t 200101010000 "$projects/alpha/restat.txt"
  # gamma: origin is gone, so only its last-fetched view can be reported.
  git -C "$projects/gamma" remote set-url origin "$TMP_ROOT/snapshot-missing.git"
  # notgit: a directory inside the home's own checkout that is not a clone.
  mkdir -p "$projects/notgit"

  cat > "$home/data/learnings.md" <<'EOF'
# Learnings

## Recurrence ledger
One row per problem class. <!--P-->
- docs drift from a changed rule | 2026-09-25 roadmap; 2026-09-27 venue swarm | root cause pending <!--P-->
- flaky ci | 2026-09-01 one run | fixed <!--P-->
EOF

  # Non-vacuity: in a byte copy of alpha, an ordinary status does rewrite the index.
  control="$TMP_ROOT/snapshot-control"
  cp -Rp "$projects/alpha" "$control"
  before_projects=$(tree_fingerprint "$control/.git/index")
  git -C "$control" status --porcelain >/dev/null
  [ "$(tree_fingerprint "$control/.git/index")" != "$before_projects" ] \
    || fail "fixture is vacuous: an ordinary git status did not rewrite the index"

  before_projects=$(tree_fingerprint "$projects" "$TMP_ROOT/snapshot-alpha-feature")
  before_origin=$(tree_fingerprint "$origin")
  out=$(FM_HOME="$home" FM_CARETAKER_SWEEP_NOW="$T0" "$SWEEP" snapshot) || fail "snapshot failed"
  FM_HOME="$home" FM_CARETAKER_SWEEP_NOW="$T0" "$SWEEP" due >/dev/null
  FM_HOME="$home" FM_CARETAKER_SWEEP_NOW="$T0" "$SWEEP" start >/dev/null || fail "start failed"
  FM_HOME="$home" FM_CARETAKER_SWEEP_NOW=$((T0 + 60)) "$SWEEP" complete >/dev/null || fail "complete failed"
  [ "$(tree_fingerprint "$projects" "$TMP_ROOT/snapshot-alpha-feature")" = "$before_projects" ] \
    || fail "the sweep changed a project clone or its linked worktree"
  [ "$(tree_fingerprint "$origin")" = "$before_origin" ] || fail "the sweep changed a project origin"

  assert_contains "$out" 'read-only: nothing was fetched or changed' "snapshot did not state its read-only posture"
  assert_contains "$out" 'behind origin now: its head' "alpha's unfetched origin head was not reported"
  assert_contains "$out" 'local branches not on origin now: feature' "alpha's local-only branch was not reported"
  assert_contains "$out" 'local changes: 2 tracked, 1 untracked' "alpha's local changes were not counted"
  assert_contains "$out" 'stashes: 1' "alpha's stash was not counted"
  assert_contains "$out" 'linked worktrees: 1' "alpha's linked worktree was not counted"
  assert_contains "$out" 'current with origin now at' "beta was not reported current with origin"
  assert_contains "$out" 'ahead 1, behind 0 against origin now' "delta's unpushed commit was not counted"
  assert_contains "$out" 'origin as last fetched (origin unreachable)' "gamma's unreachable origin was not reported"
  printf '%s\n' "$out" | grep -A1 -F '### notgit' | grep -F -- '- not a git clone' >/dev/null \
    || fail "a non-clone directory was read as the enclosing checkout"
  assert_contains "$out" '- docs drift from a changed rule: 2 dated occurrences; remedy: root cause pending - recurring' \
    "a recurring ledger class was not flagged"
  assert_contains "$out" '- flaky ci: 1 dated occurrence; remedy: fixed' "a single-occurrence ledger class was misreported"
  printf '%s\n' "$out" | grep -F 'flaky ci' | grep -F 'recurring' >/dev/null \
    && fail "a single-occurrence class was flagged recurring"
  pass "fm-caretaker-sweep.sh: the snapshot and schedule leave every project clone, worktree, and origin byte-identical"
}

test_snapshot_reports_a_hand_written_ledger_outside_the_canonical_section() {
  local home out
  home="$TMP_ROOT/snapshot-legacy-home"
  scaffold_charter "$home" keeper --caretaker --sweep-every 7d
  printf '# Learnings\n\n- Recurrence ledger (problem class | occurrences | remedy status):\n  - a class | 2026-09-26; 2026-09-27 | open\n' \
    > "$home/data/learnings.md"
  out=$(FM_HOME="$home" FM_CARETAKER_SWEEP_NOW="$T0" "$SWEEP" snapshot) || fail "snapshot failed"
  assert_contains "$out" 'hand-written recurrence ledger exists' "a hand-written ledger was not reported"
  assert_contains "$out" 'migrate it to the canonical heading' "the migration step was not stated"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  printf '%s\n' "$out" | grep -F 'No `## Recurrence ledger` section' >/dev/null \
    && fail "a hand-written ledger was reported as absent"
  printf '# Learnings\n\nnothing here\n' > "$home/data/learnings.md"
  out=$(FM_HOME="$home" FM_CARETAKER_SWEEP_NOW="$T0" "$SWEEP" snapshot) || fail "snapshot failed"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_contains "$out" 'No `## Recurrence ledger` section' "a home with no ledger was not reported as having none"
  pass "fm-caretaker-sweep.sh: the snapshot names a hand-written ledger it cannot count"
}

test_seed_initializes_the_ledger_for_caretaker_charters_only() {
  local main sub legacy plain_sub before
  main="$TMP_ROOT/seed-main"
  mkdir -p "$main/data" "$main/state" "$main/projects"

  # An existing home whose learnings have no ledger gets the section appended,
  # with its earlier content preserved as the prefix.
  sub="$TMP_ROOT/seed-caretaker-home"
  mkdir -p "$sub/bin" "$sub/data"
  : > "$sub/AGENTS.md"
  printf '# Learnings\n\n- an existing fact <!--a:2026-09-01-->' > "$sub/data/learnings.md"
  before=$(cat "$sub/data/learnings.md")
  FM_HOME="$main" FM_SECONDMATE_CHARTER='Persistent caretaker for the firstmate repo.' \
    "$ROOT/bin/fm-brief.sh" keeper --secondmate --caretaker --sweep-every 7d --no-projects >/dev/null \
    || fail "caretaker charter scaffold failed"
  FM_HOME="$main" "$ROOT/bin/fm-home-seed.sh" keeper "$sub" --no-projects >/dev/null \
    || fail "seeding a caretaker home failed"
  case "$(cat "$sub/data/learnings.md")" in
    "$before"*) ;;
    *) fail "ledger initialization did not preserve the existing learnings" ;;
  esac
  [ "$(grep -cFx '## Recurrence ledger' "$sub/data/learnings.md")" = 1 ] \
    || fail "seeding did not add exactly one recurrence ledger heading"
  assert_grep '<problem class> | <YYYY-MM-DD> <occurrence>' "$sub/data/learnings.md" \
    "the initialized ledger does not state its row format"
  assert_grep '- an existing fact <!--a:2026-09-01-->' "$sub/data/learnings.md" "the last existing entry lost its line"

  # Re-seeding the same home does not add a second ledger.
  FM_HOME="$main" "$ROOT/bin/fm-home-seed.sh" keeper "$sub" --no-projects >/dev/null \
    || fail "re-seeding a caretaker home failed"
  [ "$(grep -cFx '## Recurrence ledger' "$sub/data/learnings.md")" = 1 ] \
    || fail "re-seeding added a second recurrence ledger"

  # A hand-written ledger in the older bullet form is left byte-identical.
  legacy="$TMP_ROOT/seed-legacy-home"
  mkdir -p "$legacy/bin" "$legacy/data"
  : > "$legacy/AGENTS.md"
  printf '# Learnings\n\n- Recurrence ledger (problem class | occurrences | remedy status):\n  - a class | 2026-09-27 | open\n' \
    > "$legacy/data/learnings.md"
  before=$(tree_fingerprint "$legacy/data/learnings.md")
  FM_HOME="$main" FM_SECONDMATE_CHARTER='Persistent caretaker with a hand-kept ledger.' \
    "$ROOT/bin/fm-brief.sh" legacy-keeper --secondmate --caretaker --no-projects >/dev/null \
    || fail "legacy caretaker charter scaffold failed"
  FM_HOME="$main" "$ROOT/bin/fm-home-seed.sh" legacy-keeper "$legacy" --no-projects >/dev/null \
    || fail "seeding a caretaker home with a legacy ledger failed"
  [ "$(tree_fingerprint "$legacy/data/learnings.md")" = "$before" ] \
    || fail "seeding rewrote a home that already keeps a recurrence ledger"

  # A plain charter never creates learnings.
  plain_sub="$TMP_ROOT/seed-plain-home"
  mkdir -p "$plain_sub/bin"
  : > "$plain_sub/AGENTS.md"
  FM_HOME="$main" FM_SECONDMATE_CHARTER='Plain firstmate domain.' \
    "$ROOT/bin/fm-home-seed.sh" plain "$plain_sub" --no-projects >/dev/null \
    || fail "seeding a plain home failed"
  assert_absent "$plain_sub/data/learnings.md" "a plain secondmate seed created a learnings file"
  pass "fm-home-seed.sh: a caretaker seed initializes one recurrence ledger without disturbing existing learnings"
}

test_remote_provision_initializes_the_ledger_for_caretaker_charters_only() {
  local root remote_home plain_home manifest charter_dir status
  root=$(cd "$TMP_ROOT" && pwd -P)/remote-provision
  mkdir -p "$root"
  remote_home="$root/caretaker-home"
  plain_home="$root/plain-home"
  charter_dir="$root/charters"
  mkdir -p "$charter_dir/data" "$charter_dir/state"

  provision_manifest() {  # <id> <charter-file> <manifest>
    printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
      "$(printf '%s' "$1" | base64 | tr -d '\n')" "$(base64 < "$2" | tr -d '\n')" > "$3"
  }

  FM_HOME="$charter_dir" FM_SECONDMATE_CHARTER='Remote caretaker.' \
    "$ROOT/bin/fm-brief.sh" rkeeper --secondmate --caretaker --sweep-every 7d --no-projects >/dev/null \
    || fail "remote caretaker charter scaffold failed"
  manifest="$root/caretaker.manifest"
  provision_manifest rkeeper "$charter_dir/data/rkeeper/brief.md" "$manifest"
  FM_HOME="$remote_home" "$ROOT/bin/fm-remote-home-provision.sh" < "$manifest" >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "provisioning a remote caretaker home failed"
  [ "$(grep -cFx '## Recurrence ledger' "$remote_home/data/learnings.md")" = 1 ] \
    || fail "remote provisioning did not initialize one recurrence ledger"

  # Re-provisioning the same marked home keeps a single ledger, and restores
  # the section when it was removed by hand.
  FM_HOME="$remote_home" "$ROOT/bin/fm-remote-home-provision.sh" < "$manifest" >/dev/null 2>&1 \
    || fail "re-provisioning the remote caretaker home failed"
  [ "$(grep -cFx '## Recurrence ledger' "$remote_home/data/learnings.md")" = 1 ] \
    || fail "re-provisioning added a second recurrence ledger"
  printf '# Learnings\n\n- a remote fact <!--a:2026-09-01-->\n' > "$remote_home/data/learnings.md"
  FM_HOME="$remote_home" "$ROOT/bin/fm-remote-home-provision.sh" < "$manifest" >/dev/null 2>&1 \
    || fail "re-provisioning after a ledger removal failed"
  assert_grep '- a remote fact <!--a:2026-09-01-->' "$remote_home/data/learnings.md" \
    "re-provisioning lost an existing learning"
  [ "$(grep -cFx '## Recurrence ledger' "$remote_home/data/learnings.md")" = 1 ] \
    || fail "re-provisioning did not restore the recurrence ledger"

  FM_HOME="$charter_dir" FM_SECONDMATE_CHARTER='Remote plain domain.' \
    "$ROOT/bin/fm-brief.sh" rplain --secondmate --no-projects >/dev/null \
    || fail "remote plain charter scaffold failed"
  manifest="$root/plain.manifest"
  provision_manifest rplain "$charter_dir/data/rplain/brief.md" "$manifest"
  FM_HOME="$plain_home" "$ROOT/bin/fm-remote-home-provision.sh" < "$manifest" >/dev/null 2>&1 \
    || fail "provisioning a remote plain home failed"
  assert_absent "$plain_home/data/learnings.md" "remote plain provisioning created a learnings file"
  pass "fm-remote-home-provision.sh: a caretaker home gets one recurrence ledger and a plain home gets none"
}

test_due_follows_the_declared_cadence_and_durable_record
test_arm_registers_the_check_only_for_a_declared_caretaker
test_snapshot_never_mutates_project_clones
test_snapshot_reports_a_hand_written_ledger_outside_the_canonical_section
test_seed_initializes_the_ledger_for_caretaker_charters_only
test_remote_provision_initializes_the_ledger_for_caretaker_charters_only
