# Treehouse pool: worktree leases and pool sizing

This page is the current behavior of how Firstmate takes a task worktree from a [treehouse](https://github.com/kunchenguid/treehouse) pool, when it gives it back, and how to size the pool.
It applies to ship and scout workers on every session backend except Orca, which owns its own worktrees ([docs/orca-backend.md](orca-backend.md)).
A secondmate home takes its slot the same way through `bin/fm-home-seed.sh`.

## Lease lifecycle

A task's worktree is held by a durable Treehouse lease named after the task, from acquisition until the task is cleaned up.

1. `bin/fm-spawn.sh` runs `treehouse get --lease --lease-holder <task-id>` from the spawning project.
   The non-interactive form prints only the worktree path and records the task as the lease holder in the pool's persistent state.
   Later `treehouse get` calls never hand that slot out and `treehouse prune` never removes it, even with no process running inside it.
2. The spawn checks that the path is an isolated worktree, claims the slot for the task, moves the task's pane into it with a `cd`, and only then starts the worker.
3. `bin/fm-teardown.sh` runs `treehouse return --force <path>` when the task is cleaned up, which releases the lease and puts the slot back in the pool.
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

## Pool sizing

`max_trees` in the repository's `treehouse.toml` is the limit that paces concurrent workers on a host.
Every task holds one slot for its whole life, so a project can run at most `max_trees` workers at once, counting secondmate homes and any slot that is dirty or leased by something else.
When the pool is full, `treehouse get --lease` fails with a message of the form `all N worktrees are in use or dirty (max_trees = M)`, and the spawn stops with an error that names `max_trees` and this page.

Size it for the most workers you intend to run at once on that host, plus headroom for secondmate homes and for a slot that is briefly held while a task is cleaned up.
A lane-heavy host needs `max_trees` raised ahead of time rather than discovering the limit as a failed spawn.
`treehouse.toml` is host and repository configuration: set it where the pool lives, and check `treehouse status` for held slots before changing it.
Firstmate never edits it.

`config/project-capacity` ([docs/configuration.md](configuration.md) "Project capacity") caps how many workers Firstmate itself will start for a project and defers the rest with its backlog item still queued.
Keep that cap at or below `max_trees` so a deferral, which is quiet and retryable, is what the captain meets first rather than a pool error.
