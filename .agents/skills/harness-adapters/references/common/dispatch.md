# Dispatch and start

Load this with the selected tool reference for dispatch, start, or adapter verification; add `references/common/model-and-effort.md` for either profile axis.

## Resolution

Use the router's detection and safety sections for static crew and secondmate harness resolution and all explicit overrides.
`config/crew-dispatch.json` can override that static default for one crewmate or scout with concrete harness, model, and effort axes.
For a profile array, load `quota-array-dispatch` after establishing harness and provider facts here.
When the opt-in `bin/fm-dispatch-resolve.sh` is on, its `clear` answer already names the concrete axes; `docs/configuration.md` "Typed dispatch resolution" owns that contract.

`../secondmate-provisioning/SKILL.md` owns inherited local material.
Its harness consequence is that a secondmate's workers receive literal `config/crew-harness` and `config/crew-dispatch.json`, while the primary-only `config/secondmate-harness` is never inherited because secondmates do not spawn secondmates.
A concrete crew value such as `codex` carries that runtime into the secondmate home.
Unset or `default` carries no concrete value, so its workers use that home's own or detected harness rather than the primary's effective crew harness.
The inherited dispatch file applies the same best-fit profiles there.

## Owners

`../../../bin/fm-spawn.sh` owns launch, autonomy, concrete flags, task-kind compatibility, and worker turn-end wiring.
Natural-language rules stay with firstmate, while scripts receive concrete axes.

`../../../bin/fm-busy-lib.sh` owns semantic busy trust.
Composer shapes, glyphs, placeholders, popups, rendered delivery signals, and the `empty` / `pending` / `pending-unproven` / `unknown` decision belong only to `../../../bin/fm-composer-lib.sh`.
Tool references record empirical knowledge for those executable owners.

## Destructive-command guard convention

Every Firstmate-launched worker, primary, and secondmate pane refuses destructive bulk deletes before they run: docker prunes, filtered, piped, or wildcard docker removals, recursive wildcard `rm` under the home directory or `/mnt`, `git clean -f` outside the worker's own worktree, `find -delete` outside `/tmp/fm-*`, block-device writes, btrfs subvolume deletes, and `systemctl disable`/`mask`.
A worker may still remove resources it named with its own task id and anything inside its own worktree, so a brief that needs cleanup should tell the worker to label what it creates.
Each denial is logged in the owning home's `data/destructive-guard.log` and surfaces as the worker's `note:` status line; treat it as an attempted destructive action to reconcile with the worker, not as a blocker.
The only override is `FM_DESTRUCTIVE_OK=<ticket>` in the harness environment, which main grants to one launch with `fm-spawn.sh --destructive-ok <ticket>` and only on the captain's explicit word for that destructive action.
A ship or scout worker on a runtime the guard cannot reach per task (anything but Pi, pi-signed, omp, Claude, and OpenCode, or a raw launch command) is refused at spawn; prefer a guarded runtime, and grant `--unguarded-runtime <ticket>` only on the captain's explicit word.
`../../../docs/destructive-guard.md` owns the exact refused shapes, coverage gaps, and log fields.

## Adapter verification

For an approved new adapter check, use the spawn owner's raw-launch escape hatch only for a trivial supervised task.
Verify detection in `../../../bin/fm-harness.sh`, launch in `../../../bin/fm-spawn.sh`, busy state in `../../../bin/fm-busy-lib.sh`, shared composer behavior in `../../../bin/fm-composer-lib.sh`, lifecycle in `../../../bin/fm-control-lib.sh`, and tmux liveness in `../../../bin/backends/tmux.sh` when secondmate use is supported.
Also verify primary integration through `references/common/primary-hooks.md`, model discovery through `references/common/model-and-effort.md`, and one tool record.
A value remains unreachable until its executable owner, portable regression, applicable credentialed live guard, and verification record land together.
`../firstmate-coding-guidelines/SKILL.md` owns harness-dependent proof.
