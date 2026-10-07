#!/usr/bin/env bash
# fm-spend-profile-lib.sh - the single owner of spend profiles: which models a
# project may spend and on which account (key store), declared together in the
# inherited config/crew-dispatch.json so the two can never be inherited
# differently.
#
# docs/configuration.md "Spend profiles" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh, bin/fm-control.sh, and bin/fm-bootstrap.sh;
# bin/fm-dispatch-resolve.sh calls the two read helpers below.
#
# The feature is opt-in and additive: a dispatch file with no top-level
# spend_profiles key is the legacy file, every function here is a silent no-op
# for it, and no launch changes by a byte. When the key is present:
#
#   spend_profiles   { <name>: { pi_account: {root, providers[]}, doppler?,
#                      rules?[], default } }   rules and default are the same
#                      shape as the top-level ones
#   project_profiles { <project clone dir name>: <profile name> }
#
# A key is never in the file: pi_account names a store root exactly like
# config/pi-account line 1 (`ordinary` or an absolute path) plus the providers
# that store may spend on (line 2). The optional doppler field is provenance for
# people and fleet-ops; Firstmate never calls Doppler.
#
# A persistent secondmate resolves its profile from its registered scope
# instead of one project (fm_spend_profile_secondmate_plan below): when every
# project in data/secondmates.md maps to ONE profile, the mate launches on that
# profile's store and default model, and a mixed or empty scope keeps the
# launching home's pin.
#
# Resolution order for one task: a captain override (--profile with
# --captain-override words), then the project's mapped profile, else refusal. A
# project that is not mapped never falls back to a default profile, so no
# project reaches a key by accident. Inside the profile, firstmate's existing
# rule matching runs on that profile's own rules, then its default; the chosen
# harness and model must be one of the profile's candidates (every rules[].use
# profile plus the default) unless a captain override is recorded.

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"

FM_SPEND_PROFILE_NAME_RE='^[a-z0-9]+(-[a-z0-9]+)*$'

# fm_spend_profile_active <config-dir>
# Returns 0 when the home's dispatch file declares spend_profiles, 1 (silently)
# when there is no dispatch file or it is a legacy one (including a legacy file
# that is not valid JSON, which bootstrap reports), and 2 with one error printed
# when a file that names spend_profiles cannot be evaluated: guards that cannot
# be read must not be skipped.
fm_spend_profile_active() {
  local file="$1/crew-dispatch.json" kind
  [ -f "$file" ] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    if grep -q '"spend_profiles"' "$file" 2>/dev/null; then
      echo "error: config/crew-dispatch.json declares spend_profiles but jq is not installed, so the spend profile guards cannot be evaluated" >&2
      return 2
    fi
    return 1
  fi
  kind=$(jq -r 'if type == "object" then (has("spend_profiles") | tostring) else "notobject" end' "$file" 2>/dev/null) || kind=
  case "$kind" in
  true) return 0 ;;
  false) return 1 ;;
  *)
    # A file that is not a JSON object cannot be a spend-profile file unless it
    # names the feature: only then must the unreadable guards stop the launch,
    # so a legacy home keeps launching exactly as before.
    if grep -q '"spend_profiles"' "$file" 2>/dev/null; then
      echo "error: config/crew-dispatch.json declares spend_profiles but is not a readable JSON object, so the spend profile guards cannot be evaluated; correct it (bootstrap reports the detail)" >&2
      return 2
    fi
    return 1
    ;;
  esac
}

# fm_spend_profile_validate <config-dir>
# Prints one error and returns 1 when the declared spend profiles are not well
# formed; silent success otherwise. Only the keys this feature owns are
# checked here; bin/fm-bootstrap.sh runs the existing rule/default schema check
# on every profile's rules and default as well.
fm_spend_profile_validate() {
  local file="$1/crew-dispatch.json" err
  err=$(jq -r --arg name_re "$FM_SPEND_PROFILE_NAME_RE" --arg home "${HOME:-}" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def root_of($p): if $p.pi_account.root == "ordinary" then $home + "/.pi/agent" else $p.pi_account.root end;
    def use_bad($v): ($v | type) as $t | ($t != "object" and $t != "array")
      or (profiles($v) | length) == 0
      or any(profiles($v)[]; type != "object"
        or ((.harness | type) != "string") or (.harness | length) == 0
        or (has("model") and (((.model | type) != "string") or (.model | length) == 0)));
    def candidates($p): [(($p.rules // [])[] | profiles(.use)[]), profiles($p.default)[]];
    .spend_profiles as $sp | (.project_profiles // null) as $map |
    if ($sp | type) != "object" or ($sp | length) == 0 then "spend_profiles must be a non-empty object"
    elif any($sp | keys[]; test($name_re) | not) then "spend profile names must match \($name_re)"
    elif any($sp[]; type != "object") then "each spend profile must be an object"
    elif any($sp[]; (.pi_account | type) != "object") then "each spend profile needs a pi_account object (root and providers)"
    elif any($sp[]; (.pi_account.root | type) != "string" or (.pi_account.root | test("\\A(ordinary|/[^\\x00-\\x1f\\x7f]*)\\z") | not)) then "pi_account.root must be ordinary or one absolute path with no control characters"
    elif any($sp[]; (.pi_account.providers | type) != "array" or (.pi_account.providers | length) == 0
        or any(.pi_account.providers[]; (type != "string") or (test("\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z") | not))) then "pi_account.providers must be a non-empty array of provider names"
    elif any($sp[]; has("doppler") and (((.doppler | type) != "string") or (.doppler | length) == 0)) then "doppler must be a non-empty string when present"
    elif any($sp[]; has("rules") and (.rules | type) != "array") then "each spend profile rules must be an array"
    elif any($sp[]; any((.rules // [])[]; type != "object" or use_bad(.use))) then "each spend profile rule needs a use profile with a harness"
    elif any($sp[]; (has("default") | not) or use_bad(.default)) then "each spend profile needs a default profile with a harness: a profile never falls back to config/crew-harness"
    elif any($sp[]; any(candidates(.)[]; (.harness != "pi" and .harness != "pi-signed"))) then "spend profile candidates must use harness pi or pi-signed: only a Pi store can be pinned by a profile in this version"
    elif any($sp[]; . as $p | any(candidates($p)[]; (.model // "") as $m
        | ($m | test("/") | not) or (($m | split("/")[0]) as $prov | ($p.pi_account.providers | index($prov)) == null))) then "every spend profile candidate needs a model <provider>/<id> whose provider is one of its pi_account.providers"
    elif ($map | type) != "object" then "project_profiles must be an object mapping project names to spend profile names"
    elif any($map[]; . as $v | (type != "string") or ($sp | has($v) | not)) then "project_profiles must map each project to a declared spend profile"
    elif has("default_profile") then "default_profile is not supported: a project that is not in project_profiles is refused until it is mapped"
    else
      ([$sp | to_entries[] | {name: .key, root: root_of(.value)}]) as $roots
      | ($roots | group_by(.root) | map(select(length > 1))) as $dup
      | if ($dup | length) > 0 then "spend profiles \($dup[0] | map(.name) | join(", ")) share the store root \($dup[0][0].root); one store must belong to one profile"
        else empty end
    end
  ' "$file" 2>/dev/null) || err="cannot evaluate spend_profiles"
  if [ -n "$err" ]; then
    echo "error: config/crew-dispatch.json spend_profiles invalid - $err" >&2
    return 1
  fi
  return 0
}

# fm_spend_profile_project_name <project-arg> <projects-dir>
# Prints the project's identity: its clone directory name, resolved exactly as
# bin/fm-spawn.sh resolves its project argument.
fm_spend_profile_project_name() {
  local path=$1 projects=$2
  case "$path" in
  projects/*) path="$projects/${path#projects/}" ;;
  esac
  if [ -d "$path" ]; then
    path=$(cd "$path" 2>/dev/null && pwd) || true
  fi
  basename "$path"
}

# fm_spend_profile_mapped <config-dir> <project>
# Prints the profile the project maps to, or nothing. The caller has run
# fm_spend_profile_active and fm_spend_profile_validate.
fm_spend_profile_mapped() {
  jq -r --arg p "$2" '(.project_profiles // {})[$p] // empty' "$1/crew-dispatch.json"
}

# fm_spend_profile_exists <config-dir> <profile>
fm_spend_profile_exists() {
  jq -e --arg n "$2" '.spend_profiles | has($n)' "$1/crew-dispatch.json" >/dev/null 2>&1
}

# fm_spend_profile_rules_doc <config-dir> <profile>
# Prints the profile's own {rules, default} document, the same shape as a
# legacy dispatch file, so bin/fm-dispatch-resolve.sh offers a task only the
# rules its profile may use.
fm_spend_profile_rules_doc() {
  jq --arg n "$2" '.spend_profiles[$n] | {rules: (.rules // []), default: .default}' "$1/crew-dispatch.json"
}

# fm_spend_profile_account <config-dir> <profile>
# Prints "root<TAB>providers" (providers space-separated) for the profile.
fm_spend_profile_account() {
  jq -r --arg n "$2" '.spend_profiles[$n].pi_account | "\(.root)\t\(.providers | join(" "))"' "$1/crew-dispatch.json"
}

# fm_spend_profile_candidate <config-dir> <profile> <harness> <model>
# Returns 0 when the harness and model pair is one of the profile's candidates.
# An absent model and `default` are the same model.
fm_spend_profile_candidate() {
  jq -e --arg n "$2" --arg h "$3" --arg m "$4" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def norm($x): if $x == null or $x == "default" then "" else $x end;
    .spend_profiles[$n] as $p
    | any([(($p.rules // [])[] | profiles(.use)[]), profiles($p.default)[]][]; .harness == $h and norm(.model) == norm($m))
  ' "$1/crew-dispatch.json" >/dev/null 2>&1
}

# fm_spend_profile_normalize_root <declared-or-root>
# Prints the store directory a root string selects (ordinary is $HOME/.pi/agent).
fm_spend_profile_normalize_root() {
  case "$1" in
  ordinary) printf '%s\n' "${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
  *) printf '%s\n' "$1" ;;
  esac
}

# fm_spend_profile_select <config-dir> <project> <profile-arg> <override> <recorded-profile> <recorded-override> <harness> <model> <raw-command>
# The whole launch-time decision. Prints nothing and returns 0 for a legacy
# home, so every launch stays byte-identical. For a home with spend profiles
# prints "profile<TAB>root<TAB>providers" once every guard passes; the caller
# exports the account as FM_WORKER_ACCOUNT_PROFILE_PIN="root<TAB>providers"
# before fm_worker_account_select, so the profile's store replaces
# config/pi-account. On refusal prints one error and returns 1. Relaunch passes
# the recorded profile and override, so a task keeps the profile it began with.
fm_spend_profile_select() {
  local config=$1 project=$2 profile_arg=$3 override=$4 recorded=$5 recorded_override=$6 harness=$7 model=$8 raw=${9:-}
  local rc profile mapped
  fm_spend_profile_active "$config"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    if [ -n "$profile_arg$recorded" ]; then
      echo "error: spend profile '${profile_arg:-$recorded}' was requested or recorded, but config/crew-dispatch.json declares no spend_profiles" >&2
      return 1
    fi
    return 0
  fi
  [ "$rc" -eq 0 ] || return 1
  fm_spend_profile_validate "$config" || return 1

  if [ -n "$profile_arg" ] && [ -n "$recorded" ]; then
    echo "error: a relaunch keeps the task's recorded spend profile '$recorded'; --profile cannot change it" >&2
    return 1
  fi
  if [ -n "$recorded" ]; then
    profile=$recorded
    override=$recorded_override
    fm_spend_profile_exists "$config" "$profile" || {
      echo "error: task is recorded under spend profile '$profile', which config/crew-dispatch.json no longer declares" >&2
      return 1
    }
    if [ -z "$override" ]; then
      mapped=$(fm_spend_profile_mapped "$config" "$project")
      if [ "$mapped" != "$profile" ]; then
        echo "error: task is recorded under spend profile '$profile', but project '$project' now maps to '${mapped:-nothing}'; refusing to relaunch it on a different account" >&2
        return 1
      fi
    fi
  elif [ -n "$profile_arg" ]; then
    if [ -z "$override" ]; then
      echo "error: --profile needs --captain-override \"<the captain's words>\": a profile other than the project's own is the captain's explicit decision" >&2
      return 1
    fi
    profile=$profile_arg
    fm_spend_profile_exists "$config" "$profile" || {
      echo "error: spend profile '$profile' is not declared in config/crew-dispatch.json" >&2
      return 1
    }
  else
    profile=$(fm_spend_profile_mapped "$config" "$project")
    if [ -z "$profile" ]; then
      echo "error: project '$project' is not in project_profiles of config/crew-dispatch.json, so it cannot launch until it is mapped to a spend profile (work or personal); map it, or pass --profile <name> --captain-override \"<the captain's words>\"" >&2
      return 1
    fi
  fi

  fm_spend_profile_guard "$config" "$profile" "project '$project'" "$override" "$harness" "$model" "$raw"
}

# fm_spend_profile_guard <config-dir> <profile> <label> <override> <harness> <model> <raw-command>
# The guards every launch under a resolved profile passes, whatever resolved the
# profile (a task's project, or a secondmate's registered scope): the model is
# one of the profile's candidates unless a captain override is recorded, the
# harness can carry a per-launch account pin, a raw Pi command is refused, and
# config/pi-account never disagrees with the profile. <label> names the subject
# in refusals, for example "project 'cappz-core'". Prints
# "profile<TAB>root<TAB>providers" on success and one error on refusal.
fm_spend_profile_guard() {
  local config=$1 profile=$2 label=$3 override=$4 harness=$5 model=$6 raw=${7:-}
  local account root providers file_pin file_root file_providers want_providers
  if [ -z "$override" ] && ! fm_spend_profile_candidate "$config" "$profile" "$harness" "${model:-default}"; then
    echo "error: spend profile '$profile' does not allow harness '$harness' with model '${model:-default}' for $label; its candidates are the models of its own rules and default (a captain override with --profile and --captain-override is the only exception)" >&2
    return 1
  fi

  case "$harness" in
  pi | pi-signed) ;;
  *)
    echo "error: spend profile '$profile' declares an account, and harness '${harness:-none}' has no per-launch account pin in this version, so the launch could spend a different key; launch with --harness pi or pi-signed" >&2
    return 1
    ;;
  esac
  [ -z "$raw" ] || {
    echo "error: spend profile '$profile' pins the Pi account, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
    return 1
  }

  account=$(fm_spend_profile_account "$config" "$profile")
  root=${account%%$'\t'*}
  providers=${account#*$'\t'}

  # config/pi-account is a second source of truth for the same store, so it
  # may repeat the profile's account but never disagree with it.
  file_pin=$(FM_WORKER_ACCOUNT_PROFILE_PIN='' fm_worker_account_resolve "$harness" "$config") || return 1
  if [ -n "$file_pin" ]; then
    file_root=${file_pin#*$'\t'}
    file_providers=${file_root#*$'\t'}
    file_root=${file_root%%$'\t'*}
    want_providers=$(printf '%s\n' "$providers" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    file_providers=$(printf '%s\n' "$file_providers" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    if [ "$file_root" != "$(fm_spend_profile_normalize_root "$root")" ] || [ "$file_providers" != "$want_providers" ]; then
      echo "error: config/pi-account pins Pi workers to ${file_pin%%$'\t'*} (providers: ${file_providers% }), but spend profile '$profile' for $label declares $root (providers: ${want_providers% }); refusing so one launch never has two answers about which key pays. Remove config/pi-account or make it agree" >&2
      return 1
    fi
  fi
  printf '%s\t%s\t%s\n' "$profile" "$root" "$providers"
}

# fm_spend_profile_scope <config-dir> <projects-field>
# Prints the one profile every project of a secondmate's registered scope maps
# to, or nothing when the scope has no projects, names a project that is not
# mapped, or spans more than one profile. <projects-field> is the registry's
# comma-separated projects value. The caller has run fm_spend_profile_active
# and fm_spend_profile_validate.
fm_spend_profile_scope() {
  jq -r --arg csv "$2" '
    ($csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $ps
    | (.project_profiles // {}) as $map
    | if ($ps | length) == 0 then empty
      else ([$ps[] | ($map[.] // "")] | unique) as $u
        | if ($u | length) == 1 and $u[0] != "" then $u[0] else empty end
      end
  ' "$1/crew-dispatch.json"
}

# fm_spend_profile_registered_scope <config-dir> <data-dir> <secondmate-id>
# Prints the scope profile for a secondmate registered in this home (possibly
# empty: none, mixed, or no spend profiles), or the single character ? when
# this home has no registry entry for the mate, as on a remote host whose parent
# resolved the scope instead. Always returns 0.
fm_spend_profile_registered_scope() {
  local config=$1 data=$2 id=$3 projects
  if ! projects=$(secondmate_registry_field "$data/secondmates.md" "$id" projects 2>/dev/null); then
    printf '?\n'
    return 0
  fi
  fm_spend_profile_active "$config" 2>/dev/null || return 0
  fm_spend_profile_validate "$config" 2>/dev/null || return 0
  fm_spend_profile_scope "$config" "$projects"
}

# fm_spend_profile_default_launch <config-dir> <profile>
# Prints "harness<TAB>model<TAB>effort" for the profile's default entry (the
# first one when the default is an array); model and effort are empty when the
# entry omits them.
fm_spend_profile_default_launch() {
  jq -r --arg n "$2" '
    .spend_profiles[$n].default as $d
    | (if ($d | type) == "array" then $d[0] else $d end)
    | [.harness, (.model // ""), (.effort // "")] | join("\t")
  ' "$1/crew-dispatch.json"
}

# fm_spend_profile_secondmate_plan <config-dir> <id> <scope> <profile-arg> <override> <recorded-profile> <recorded-override>
# Decides which spend profile a persistent secondmate launches under. <scope> is
# what fm_spend_profile_registered_scope printed: a profile name, empty for a
# none-or-mixed scope, or ? when the scope is unknown here. Prints nothing and
# returns 0 when no profile applies (a legacy home, a mixed or empty scope), so
# the launch keeps the launching home's pin. Otherwise prints
# "profile<TAB>harness<TAB>model<TAB>effort<TAB>override": the profile and the
# default launch it supplies, plus the captain-override words that chose it.
# Precedence matches fm_spend_profile_select: a recorded profile (a relaunch),
# then --profile with a captain override, then the registered scope. A recorded
# profile with no override must still match a known scope, so a relaunch never
# moves a mate onto a different account. On refusal prints one error, returns 1.
# The caller passes the printed harness and model through fm_spend_profile_guard
# unless it replaces them with an explicit per-spawn choice.
fm_spend_profile_secondmate_plan() {
  local config=$1 id=$2 scope=$3 profile_arg=$4 override=$5 recorded=$6 recorded_override=$7
  local rc profile launch
  fm_spend_profile_active "$config"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    # A scope handed in by a remote mate's parent is a request too: a host that
    # cannot read the profile table must not launch the mate on another store.
    if [ -n "$profile_arg$recorded" ] || { [ -n "$scope" ] && [ "$scope" != '?' ]; }; then
      echo "error: spend profile '${profile_arg:-${recorded:-$scope}}' was requested or recorded, but config/crew-dispatch.json declares no spend_profiles" >&2
      return 1
    fi
    return 0
  fi
  [ "$rc" -eq 0 ] || return 1
  fm_spend_profile_validate "$config" || return 1
  if [ -n "$scope" ] && [ "$scope" != '?' ]; then
    fm_spend_profile_exists "$config" "$scope" || {
      echo "error: secondmate '$id' scope maps to spend profile '$scope', which config/crew-dispatch.json does not declare" >&2
      return 1
    }
  fi

  if [ -n "$profile_arg" ] && [ -n "$recorded" ]; then
    echo "error: a relaunch keeps the secondmate's recorded spend profile '$recorded'; --profile cannot change it" >&2
    return 1
  fi
  if [ -n "$recorded" ]; then
    profile=$recorded
    override=$recorded_override
    fm_spend_profile_exists "$config" "$profile" || {
      echo "error: secondmate '$id' is recorded under spend profile '$profile', which config/crew-dispatch.json no longer declares" >&2
      return 1
    }
    if [ -z "$override" ] && [ "$scope" != '?' ] && [ "$scope" != "$profile" ]; then
      echo "error: secondmate '$id' is recorded under spend profile '$profile', but its registered scope now maps to '${scope:-no single profile}'; refusing to relaunch it on a different account" >&2
      return 1
    fi
  elif [ -n "$profile_arg" ]; then
    if [ -z "$override" ]; then
      echo "error: --profile needs --captain-override \"<the captain's words>\": a profile other than the secondmate's own is the captain's explicit decision" >&2
      return 1
    fi
    profile=$profile_arg
    fm_spend_profile_exists "$config" "$profile" || {
      echo "error: spend profile '$profile' is not declared in config/crew-dispatch.json" >&2
      return 1
    }
  else
    profile=$scope
    [ "$profile" != '?' ] || profile=
    [ -n "$profile" ] || return 0
  fi
  launch=$(fm_spend_profile_default_launch "$config" "$profile") || return 1
  printf '%s\t%s\t%s\n' "$profile" "$launch" "$override"
}
