# Treehouse pool: worktree leases and pool sizing

This page is the current behavior of how Firstmate takes a task worktree from a [treehouse](https://github.com/kunchenguid/treehouse) pool, when it gives it back, and how to size the pool.
It applies to ship and scout workers on every session backend except Orca, which owns its own worktrees ([docs/orca-backend.md](orca-backend.md)).
A secondmate home takes its slot the same way through `bin/fm-home-seed.sh`.

## Lease lifecycle

A task's worktree is held by a durable Treehouse lease named after the task, from acquisition until the task is cleaned up.

1. `bin/fm-spawn.sh` runs `treehouse get --lease --lease-holder <task-id>` from the spawning project.
   The non-interactive form prints only the worktree path and records the task as the lease holder in the pool's persistent state.
   Later `treehouse get` calls never hand that slot out and `treehouse prune` never removes it, even with no process running inside it.
   The lease is taken before the task's endpoint exists, so a refusal there leaves nothing behind (see "Fast failure on exhaustion").
2. The spawn checks that the path is an isolated worktree, claims the slot for the task, moves the task's pane into it with a `cd`, and only then starts the worker.
3. `bin/fm-teardown.sh` runs `treehouse return --force <path>` when the task is cleaned up, which releases the lease and puts the slot back in the pool. Before the return, a non-`--force` teardown runs a best-effort `cargo clean` in Cargo worktrees so a free slot stays lean.
4. A spawn that fails or is interrupted after the lease was taken, and before a task record exists, returns the lease itself with `treehouse return --force --if-lease-holder <task-id> <path>`.
   The one exception is a worker that was already launched and whose endpoint could not be closed: it may still be working in the slot, so the lease stays and the spawn prints the exact return command to run once it has stopped.

`treehouse status` shows each slot's holder, so a leased slot can always be traced to a task.
If a slot is leased by a task id that has no task record, return it by hand with the command above.

### Why not the interactive form

The interactive `treehouse get` opens a subshell and records only a process lease.
That lease lapses when the worker exits, and nothing then says which task the slot belonged to, so a finished task's slot could not be told apart from a live one.
On a busy host this exhausted the pool: every slot was held, some by live workers and some by tasks that were already done, and the next spawn failed with `treehouse get did not enter an isolated worktree within 60s` and lost its window.
The lease form removes both problems: it never needs a subshell, and the holder survives the worker.

### Launch-boundary isolation check

After the `cd`, the spawn reads the pane's foreground process working directory and refuses to start a worker unless it is the leased worktree.
The foreground process's cwd is the right field.
A pane's plain cwd is frozen at the directory the pane was created in, which is the primary clone by design, so reading it would either refuse every spawn or pass on a stale value.
On Herdr that is `foreground_cwd`, not `cwd`; `tests/fm-backend-herdr.test.sh` pins the choice.

## Slot rules and disposal

Everything a task holds is removed by the home that created it, as the last step of that task, with no timer or sweep.

- **Automatic teardown.** Every main wake drain starts one detached `bin/fm-auto-teardown.sh` sweep (rate limited, one at a time per home) that runs `bin/fm-teardown.sh <id>`, never with `--force`, for each ship or scout whose current state reads done.
  Teardown's own landed-work refusals stand: an unmerged PR, a dirty copy or a scout without its report stays exactly as it was and is retried after a back-off.
  `FM_AUTO_TEARDOWN=0` turns the sweep off.
- **The claim file is the only truth.** `<pool>/<slot>/.fm-slot-owner` names the task holding a slot; a record's `worktree=` line is a copy of it.
  When a spawn claims a slot it demotes every other record that still names that slot to a `#stale-worktree-record(superseded-by=<task>) <path>` comment, under the same project lock, so a later teardown of an older task can never reach the new task's slot.
- **A slot still on the books is never offered.** Before each `treehouse get --lease`, a slot whose claimant still has a task record is leased in place under that task's id (`treehouse lease`, a state-only call), so the pool cannot hand it out.
  Only teardown frees a slot: it removes the record and returns the lease together.
- **Empty numbered directories** hold no slot: the spawn removes them before the get, and the slot ceiling never counts them.
  `bin/fm-pool-lib.sh` owns these rules.
- **Branches.** Teardown deletes the task's head branch on origin together with the local one, only when the work is proven landed (the local branch retired on its ancestor or patch-equivalence proof, or the task's merged PR contains the local work) and the remote branch is still at the proved tip; `bin/fm-pr-close.sh` closes a PR and deletes its head branch when it is still at `refs/pull/<n>/head`, which GitHub keeps.
  Branches under `evidence/`, `archive/`, `shots/` and `capture/` are never deleted (`bin/fm-branch-retire-lib.sh`).

## Host ceilings

`bin/fm-spawn.sh` refuses a fresh worker while the host sits at a declared ceiling, before any lease, endpoint or record exists.
Ceilings come from `~/.config/fleet/ceilings.env` (or `FM_CEILINGS_FILE`): `KEY=value` lines for `DISK_PCT`, `CONTAINERS`, `CONTAINERS_RUNNING`, `VOLUMES`, `IMAGE_TAGS`, `POOL_SLOTS` and `TMP_GB`.
A key or file that is absent sets no ceiling.
A value at or above its ceiling is over.
Before refusing, the spawn runs one `bin/fm-auto-teardown.sh` sweep for this home's own finished tasks and measures again; a host still over refuses, naming each breach and what the sweep kept.
`bin/fm-ceilings.sh` owns the measurements.

## Pool sizing

`max_trees` in the repository's `treehouse.toml` is the limit that paces concurrent workers on a host.
Every task holds one slot for its whole life, so a project can run at most `max_trees` workers at once, counting secondmate homes and any slot that is dirty or leased by something else.
When the pool is full, `treehouse get --lease` fails with a message of the form `all N worktrees are in use or dirty (max_trees = M)`.

### Fast failure on exhaustion

The spawn takes its lease before it creates the worker's endpoint, so a pool that cannot hand out a tree is reported at once.
It recognises Treehouse's limit message (any line that names `worktrees are in use` or `max_trees`), stops, and prints that message with a pointer to this page.
No window, tab, pane, or workspace is ever created for the refused spawn, so there is no sixty-second wait, no leftover endpoint, and nothing to clean up that could move the active workspace or tab.
Any other `treehouse get --lease` failure is refused at the same point with the tool's own message.
`tests/fm-spawn-worktree-settle.test.sh` pins both refusals against a stub pool, and `tests/fm-backend-herdr-presentation-e2e.test.sh` pins the focus guarantee against a real pool in an isolated Herdr lab.

Size it for the most workers you intend to run at once on that host, plus headroom for secondmate homes and for a slot that is briefly held while a task is cleaned up.
A lane-heavy host needs `max_trees` raised ahead of time rather than discovering the limit as a failed spawn.
`treehouse.toml` is host and repository configuration: set it where the pool lives, and check `treehouse status` for held slots before changing it.
Firstmate never edits it.

`config/project-capacity` ([docs/configuration.md](configuration.md) "Project capacity") caps how many workers Firstmate itself will start for a project and defers the rest with its backlog item still queued.
Keep that cap at or below `max_trees` so a deferral, which is quiet and retryable, is what the captain meets first rather than a pool error.
