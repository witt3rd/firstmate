# fm-run: whatever creates a thing destroys it

`bin/fm-run` launches a builder's heavy work so that every docker object and temp directory it creates is recorded as it is created and removed by exact name in the same code path.
`bin/fm-created-check` is the read-only closing check.
The destructive-command guard ([`destructive-guard.md`](destructive-guard.md)) refuses a removal the pane cannot show it owns, so a builder that creates a thing cannot otherwise remove it, and the cleanup fell on a person.

## Use

```sh
bin/fm-run <task-id> -- <command> [args...]
bin/fm-created-check <task-id>
```

The ship brief scaffold tells a builder to launch heavy work this way and to treat the work as unfinished until `CREATED`, `REMOVED`, and `REMAINING` are printed and `REMAINING` is empty.

## Heavy-host refusal

Heavy work never runs on the captain's desktop.
`bin/fm-run` and the execution modes of `bin/fm-test-run.sh` (not `--list*`, `--check-coverage`, or `--aggregate-json`) exit 75 with `<host> is the captain's desktop: heavy work runs on x, chef, et or mcfeely` when `hostname -s` is listed in the tracked `bin/fm-no-heavy-hosts.default` (roger, prince, king).
A home's own `$FM_HOME/config/no-heavy-hosts` may only add hosts; the tracked default is always read.
The shared check is `fm_run_heavy_host_guard` in `bin/fm-run-lib.sh`; `FM_HEAVY_HOSTNAME` replaces the hostname for tests.

## What a run does

- Sets `FM_TASK_LABEL` to the task id, which is the label the guard names (`--own-label`), plus `FM_RUN_ID`, `FM_RUN_LEDGER`, and `FM_RUN_SCRATCH`.
  `TMPDIR` points at the run's own scratch root, `~/.t/fm-run-<task-id>-<run-id>` (override the base with `FM_RUN_TMPBASE`).
  The base is on disk and short on purpose: `/tmp` is RAM-backed tmpfs on worker hosts, where a big build fills it and fails with "No space left on device", and a long path broke the Postgres unix socket path limit.
  A run refuses to start (exit 75, one line) when the base's filesystem is over 90% full in bytes or inodes (`FM_RUN_MAX_USED_PCT` overrides the limit).
- Puts a shim directory first on `PATH` (`bin/fm-run-shim.sh`):
  - `docker` and `docker-compose` stamp every container, network, volume, and image build with the labels `fm.task=<task-id>` and `fm.run=<run-id>`, name an unnamed create `<task-id>-<hex>`, and append the exact name to the ledger before the create runs.
    Named volumes a `run` or `create` would make implicitly are created labelled first.
    A compose project is forced to the `<task-id>-` prefix, and what `up`, `create`, `run`, or `build` adds to it is recorded by exact name.
    A caller-supplied `fm.task` or `fm.run` label, a `-H`/`--context` create, and any create outside a run are refused.
    Reads, removals, and everything else pass through to the next `docker`, whose own guard still applies.
  - `mktemp` records every path it makes; a bare or `-t` call lands in the scratch root through `TMPDIR`, and a `/tmp` template is relocated into it.
- On exit (normal, error, SIGTERM, SIGINT, SIGHUP) it removes exactly the ledger entries and prints three lists on stderr.
  `docker rm -f -v`, `network rm`, `volume rm`, and `rmi` act on one exact name each, and only while the object still carries the recorded label.
  `rm -rf` acts only on a recorded path inside this run's own scratch root, derived from the task id and run id and never read from the ledger; a path outside it, a dot-dot path, or a path under a symlink that leaves the root is refused and listed under `REMAINING`.
- The exit status is the command's own, or 3 when the command succeeded but `REMAINING` is not empty.
  SIGINT reaches the command as SIGTERM, and a second signal is SIGKILL.

## A hard kill or a host crash

SIGKILL or a crash leaves the ledger under `${FM_RUN_ROOT:-~/.cache/fm-run}/<task-id>/<run-id>/`.
The next `fm-run` of the same task id first removes what that prior ledger names (exact names from the creator's own record, no sweep), reports it as a recovered run, and then runs.
A run directory with a live owner is never touched.

## The closing check

`bin/fm-created-check <task-id>` reads the task's ledgers on this host and verifies each recorded object is gone (`docker inspect` by exact name, `test -e` by exact path).
It prints `CLEAN`, or the exact remaining names with the one command that removes them on that host (`fm-run <task-id> -- true`), and exits 0 or 1.
It prints `NO-LEDGER` and exits 2 when nothing was ever launched through `fm-run` for the task id on this host, because that is a flag and not a clean bill.

## The guard

The guard's own-name rule is unchanged: a removal names plain literals that start with the task label.
It also treats a literal that appears in the task's own ledger as owned, so a builder can remove an object it created by exact name before the run ends.
`fm-run <task-id> -- <command>` is judged as the wrapped command, so it is never a way around a refusal.
Filters, labels, globs, variables, pipes, `xargs`, and prunes stay refused.

## Limits

- It covers only what is launched through it.
  Docker run directly (`/usr/bin/docker`, `command docker`, a container that talks to the socket itself), other hosts reached over `ssh`, work on a host without this script, and anything created by a process the command detaches and outlives are not covered.
  `NO-LEDGER` from the closing check is the flag for the first and third cases.
- A compose project is recorded by what it adds when the project was empty before the run, so a project that already had objects is only recorded for what the run adds.
  Images a compose `build` makes are found by the compose project label.
- The ledger is the builder's own record; the label proof at removal time protects against a mistaken or stale entry, not against a hostile one.
- Nothing here is a reaper: no timer, no scan, no age or pattern rule.
  Roll-out to hosts rides the ordinary self-update.

## Validation

`tests/fm-run.test.sh` launches the real scripts against the real docker daemon with throwaway, uniquely named objects and checks the outcome with independent `docker inspect`, `docker ps`, and `test -e` queries.
