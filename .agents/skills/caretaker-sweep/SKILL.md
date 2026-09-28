---
name: caretaker-sweep
description: >-
  Agent-only procedure for a caretaker second mate's declared scheduled health sweep.
  Load on a check notification whose line names the caretaker health sweep from bin/fm-caretaker-sweep.sh, and before starting, recording, or reporting such a sweep.
  Owns the bounded read-only sweep, parked finding filing, the single parent-channel digest, and schedule upkeep.
user-invocable: false
metadata:
  internal: true
---

# caretaker-sweep

Use this procedure only in a secondmate home whose `data/charter.md` declares a scheduled health sweep, when that home's own check notification reports the sweep due.
The charter's `# Scheduled health sweep` section is the authority for the sweep.
`bin/fm-caretaker-sweep.sh` owns the schedule, its durable record, and the read-only snapshot, and `bin/fm-caretaker-lib.sh` owns the cadence line and the recurrence-ledger format.
Nothing here authorizes any other self-directed work: a home without a declared cadence, or a sweep its check has not reported due, stays idle by default.

## Boundaries

- A sweep is read-only: it never edits, commits, fetches, pulls, prunes, stashes, or cleans a project clone, and never runs a fleet sync, a deploy, or a live-host command.
- A sweep spawns no worker.
  A check that needs more than a bounded read, such as a reproduction, running code, or a whole-document consistency pass, becomes a finding that recommends that investigation.
  A worker's own terminal line would also reach the parent channel by itself, and a sweep reports exactly once.
- A sweep ships nothing: acting on any finding requires work the main firstmate routes or the captain authorizes, and every merge, destructive-action, and live-host boundary in the charter and the local `AGENTS.md` still applies.

## Procedure

1. Handle the notification after the ordinary wake drain, then run `bin/fm-caretaker-sweep.sh start` before anything else, so the watcher stops re-ringing while the sweep runs.
   A sweep that never records completion comes due again after the in-progress bound in the script header.
2. Run `bin/fm-caretaker-sweep.sh snapshot` and keep its output for the report.
3. Review these sources, and only these:
   - Drift: each clone's default branch against origin, its checkout, local changes, stashes, linked worktrees, and local branches missing from origin.
     A clone that is merely behind origin is expected between session-start refreshes and is not a finding by itself; a clone off its default branch, carrying local changes, diverged, or holding branches or worktrees no live task of this home owns is.
   - The recurrence ledger: every class the snapshot marks recurring whose remedy status names no root-cause investigation or remedy under way.
     When the snapshot reports a hand-written ledger outside the canonical section, review that ledger directly and migrate it to the canonical heading and row format.
   - Contract and document consistency, and broken invariants: only the documents and invariants named by the charter's domain rules and each project's `AGENTS.md`, read at the clone's local default branch.
     Record what you did not check because it needs a deeper investigation.
   - Stale or dangling artifacts this home already knows about: open, parked, or held backlog items whose premise the snapshot or origin now contradicts, work already shipped but still open, task records with no live worker (`bin/fm-crew-state.sh`), and unresolved decisions still open since the previous sweep.
4. Deduplicate against the backlog: an existing item that still describes a finding is reported as still open, not filed again.
5. File each new finding as its own backlog item in this home, then park it so it waits for routing instead of being dispatched:
   `bin/fm-tasks-axi.sh add <id> "<title>" --kind <ship|scout> --repo <project> --body "<evidence and recommended next step>"`, then `bin/fm-tasks-axi.sh hold <id> --kind parked --reason "health sweep finding - awaits routed work or captain authorization"`.
   Record the occurrence on its recurrence-ledger row, or add a row for a new class; a class's second occurrence is filed as a root-cause investigation, not a fix.
6. Write the sweep report to `data/health-sweep-<YYYY-MM-DD>/report.md`: the snapshot, each finding with its evidence and item id, the items still open from earlier sweeps, and what was not checked.
7. Append exactly one digest line to the parent channel with the charter's status command, for example `done [key=health-sweep-<YYYY-MM-DD>] [at=<epoch>]: health sweep: <n> new findings parked (<ids>), <m> still open; report data/health-sweep-<YYYY-MM-DD>/report.md`.
   A clean sweep sends the same single line saying it found nothing new.
8. Run `bin/fm-caretaker-sweep.sh complete`, then return to idle.

If the sweep cannot be carried out, append one `blocked` line naming why and leave the record started, so the schedule re-rings once the bound passes.

## Acting on a finding later

When the main firstmate routes a parked finding or the captain authorizes it, lift its hold with `bin/fm-tasks-axi.sh unhold <id>` and handle it as ordinary routed work under the charter's caretaker practice.

## Schedule upkeep

Every locked session start arms the check through `bin/fm-caretaker-sweep.sh arm --if-declared`, and retires it when the charter no longer declares a sweep.
After a mid-session charter change, run that same command yourself.
`bin/fm-caretaker-sweep.sh status` prints the cadence, the record, the current verdict, and whether the check is armed.
