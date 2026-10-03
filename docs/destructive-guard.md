# Destructive-command guard

This document is the authoritative contract for the destructive-command guard: what it refuses, where it runs, how the captain or main overrides it, and where every denial is recorded.
`bin/fm-destructive-command-policy.mjs` is the single decision owner.
`bin/fm-destructive-pretool-check.sh` is the transport: it supplies the pane's identity and own worktree, honors the override, writes the log and the supervisor note, and renders each harness's deny shape.
The tracked harness adapters and the per-task adapters `bin/fm-spawn.sh` writes forward the command text without classifying it.

## Purpose and boundary

A worker once deleted about 370 shared docker workspace volumes with a cleanup filter that carried one stray extra pattern.
A rule in the worker's instructions did not prevent it, so this guard makes the harness itself refuse a destructive bulk delete before it runs, whatever the worker intended.

The threat model is agent mistakes, the same as the sibling seatbelts ([`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md)).
The policy tokenizes the submitted bytes with the shared classifier owned by `bin/fm-arm-command-policy.mjs` and never executes, sources, or expands any part of them.
It is not a sandbox: a destructive command hidden in a script file the agent writes and then runs, or assembled from opaque runtime data, is out of scope.

## What is refused

Each denial carries one stable code in square brackets before its prose reason.

| Code | Refused shape |
| --- | --- |
| `docker-prune` | `docker` (also `podman`, `nerdctl`) `system`, `volume`, `container`, `image`, or `network` `prune`, with any options or remote `-H`/`--context`. `builder prune` (rebuildable cache) is allowed. |
| `docker-bulk-rm` | `rm`, `rmi`, or `volume`/`container`/`image`/`network` `rm` whose targets come from a command substitution, a variable, a wildcard, `--filter`, `-a`/`--all`, `xargs`, or a pipe, including inside a loop, `ssh`, `sudo`, `bash -c`, or `eval`. |
| `docker-rm-unowned` | A removal whose literal target names lack the pane's own task label. |
| `rm-glob-protected` | Recursive `rm` over a wildcard or variable path whose static location is under the home directory, `/mnt`, `/home`, `/media`, `/srv`, or `/`, including a preceding `cd`. |
| `rm-protected-root` | Recursive `rm` of `/`, the home directory, a shared top-level directory under it (`.treehouse` and its pools and slots, `.local`, `.local/state`, `.local/share`, `Documents`, `backups`, `src`, `cloud`, `.config`, `.ssh`), `/mnt` or a mount under it, or any `--no-preserve-root`. |
| `rm-bulk-piped` | `rm` fed by `xargs` or `parallel`. |
| `find-delete` | `find` with `-delete` or `-exec`/`-execdir`/`-ok` running `rm`, `rmdir`, `unlink`, `shred`, or a docker CLI, unless every start path is under `/tmp/fm-*`. |
| `git-clean` | A forced `git clean` (not `-n`/`-i`) whose repository is not inside the worktree spawned for this pane. |
| `device-write` | `dd of=/dev/...`, `mkfs*`, `mke2fs`, `mkswap`, `wipefs`, `blkdiscard`, `shred`, or a partitioner (`parted`, `fdisk`, `sfdisk`, `sgdisk`, `gdisk`) naming a block device; listing (`-l`, `print`) and `wipefs -n` are allowed. |
| `btrfs-subvolume-delete` | `btrfs subvolume delete` and its abbreviations. |
| `systemctl-disable` | `systemctl disable` or `mask`, system or `--user`, because host units are managed by fleet-ops. |
| `unclassifiable-destructive` | Syntax the classifier cannot tokenize, such as a `case` arm, that visibly mentions one of the destructive verbs above. |

Quoted text, comments, heredoc bodies, and later argument words are data, so `echo 'docker volume prune -f'` and `grep -rn 'rm -rf' docs` are allowed.

## What stays allowed

- A docker removal of explicitly named literal resources that carry the pane's own task label, such as `docker volume rm <task-id>-db`.
  A worker names the containers, volumes, and networks it creates with its task id so it can remove them.
- Any recursive `rm`, `git clean`, or wildcard removal inside the worktree spawned for this pane, and wildcard removals under `/tmp`.
- `find ... -delete` under `/tmp/fm-*`.
- Every read-only form: `docker ps`, `docker volume ls -f ...`, `parted -l`, `systemctl status`, `git clean -n`.

## Where it runs

Every pane Firstmate launches runs it in at least one of two forms.

- **Worker panes.** `bin/fm-spawn.sh` installs a per-task adapter that passes the task's state directory, task id, and spawned worktree: the generated `state/<id>.pi-ext.ts` for Pi and pi-signed, `state/<id>.omp-ext.ts` for omp, a `PreToolUse` Bash entry in the worktree's `.claude/settings.local.json` for Claude, and `tool.execute.before` in the worktree's generated OpenCode plugin.
- **Primary and secondmate panes.** The tracked adapters run the guard with `--primary`: `.pi/extensions/fm-primary-turnend-guard.ts` (Pi and pi-signed primaries and secondmates), `.omp/extensions/fm-primary-turnend-guard.ts`, `.claude/settings.json`, `.codex/hooks.json`, `.grok/hooks/fm-primary-destructive-check.json`, `.opencode/plugins/fm-primary-destructive-check.js`, and `.cursor/hooks.json`.
  When one of them fires in a worker pane (`FM_TASK_ID` set), it applies the worker policy from the identity `bin/fm-spawn.sh` exports into every worker launch: the task id, the parent home's state directory beside `FM_TASK_INBOX`, and the linked worktree the pane runs in.
  When both forms deny the same command in one worker pane within ten seconds, only the first logs and notes it.

**Unguarded runtimes are refused at launch.** A ship or scout worker on any runtime without a per-task adapter (Codex, Grok, Cursor, Gemini, Muse, Kimi, AGY, Rovo, Devin) or from a raw launch command would run unguarded, because those runtimes either expose no hook Firstmate wires per task or, like Codex workers, launch with project hooks disabled.
`bin/fm-spawn.sh` therefore refuses it before creating anything, naming the guarded runtimes, unless main or the captain grants an explicit override: `--unguarded-runtime <ticket>` on the spawn, or `FM_UNGUARDED_RUNTIME_OK=<ticket>` in the spawning process's environment.
The ticket has the same shape as the command override below, and the grant is logged before launch.
Secondmates are guarded by their home's tracked primary hooks and are not refused.

A session started outside Firstmate (a captain's own shell, a pane launched by hand without the tracked extensions) is not guarded.
The class-level remedy for that gap is a host-level install of the same transport into each runtime's user-wide hook surface (for example `~/.pi/agent/extensions/`, `~/.claude/settings.json`, `~/.codex/hooks.json`), owned by the fleet configuration rather than this repository.

## Override

The guard honors `FM_DESTRUCTIVE_OK=<ticket>` only from its own process environment, which it inherits from the harness process.
The ticket must match `[A-Za-z0-9][A-Za-z0-9._:#/-]{0,79}`; a malformed value grants nothing.
A worker cannot grant it to itself: an assignment, `export`, or `env` prefix inside the submitted command changes that command's environment, never the harness's, so such a command is still denied.

Only the captain or main sets it:

- The captain launches a session with the variable in its environment.
- Main grants one worker launch with `bin/fm-spawn.sh ... --destructive-ok <ticket>`, which logs the grant and exports the variable into that launch only; a relaunch does not inherit it.

An honored override allows the command, logs it with its ticket, and notes it for the supervisor exactly like a denial.
Destructive and irreversible work still needs the captain's explicit word under `AGENTS.md` before main grants a ticket.

## Where denials are recorded

Every denial, override, and grant (command override or unguarded runtime) appends one JSON line to `data/destructive-guard.log` in the home that owns the pane: the parent home for a worker, the pane's own home for a primary or secondmate.
Each line records `at` and `time` (when), `who` (`task:<id>` or `primary`), `home`, `host`, `harness`, `pid`, and `cwd` (who and where), and `decision`, `code`, `ticket`, and `command` (what).

A worker's denial or override also appends a stamped `note:` line to `state/<task-id>.status`, which reaches the supervisor through its unread-status surface without opening a decision or claiming the worker is blocked.
A secondmate primary's denial is published on its parent channel through `bin/fm-parent-channel-lib.sh`.
A failure to write the log or note never turns a denial into an allow.

## Transport and fail-open behavior

The transport accepts the same entry forms as the cd-guard: stdin JSON at `.tool_input.command` (Claude with `--claude`, Codex, Cursor with `--cursor`) or `.toolInput.command` (Grok), and `--command <exact string>` (OpenCode, Pi, pi-signed, omp).
A strict-superset prefilter skips the Node process when the de-quoted command names none of the guarded tools and carries no `$'` or `$"` decoder marker; that marker set is coupled to the shared classifier's decoder set exactly as [`cd-guard.md`](cd-guard.md#transport-and-fail-open-behavior) describes.
Empty stdin, unparseable JSON, missing `jq` on the stdin path, missing Node, a missing policy owner, or an invalid policy response fail open with exit 0, because a broken hook must not deny every shell call.
Unclassifiable syntax that visibly names a destructive verb fails closed with `unclassifiable-destructive`.

The output contract is identical in shape to [`arm-pretool-check.md`](arm-pretool-check.md#output-contract): allow is exit 0 with no output, deny is exit 2 with the Claude-shaped object on stderr plus the Grok object on stdout unless `--claude`, and `--cursor` prints Cursor's returned decision object with exit 0.

## Automated validation

`tests/fm-destructive-pretool-check.test.sh` owns the acceptance matrix, led by the xwvol incident command shapes, across all five entry forms.
It also proves the override and its self-grant refusal, the log fields and the supervisor note, the primary adapters' worker policy in worker panes and its single record when two hooks deny, the secondmate parent-channel note, fail-open transport, every per-task worker adapter `bin/fm-spawn.sh` writes, every tracked primary adapter, the `--destructive-ok` grant, and the unguarded-runtime refusal and its override.

Run:

```sh
bin/fm-lint.sh bin/fm-destructive-pretool-check.sh
node --check bin/fm-destructive-command-policy.mjs
tests/fm-destructive-pretool-check.test.sh
```

## Live validation record, 2026-10-03

Each harness ran as a worker in a scratch spawn fixture: a fake home, project, and worktree built by `tests/fixtures.sh`, the real `bin/fm-spawn.sh` writing that worker's per-task adapter, and a `docker` stub first on `PATH` that only appended its arguments to a sentinel file.
No real docker, rm, or device command ran, and no live fleet state was touched.
Each harness was told to run, as three separate tool calls, `docker volume ls -q -f name=xwvol`, then the incident shape `docker volume ls -q -f name=xwvol | xargs docker volume rm`, then `docker volume rm <task-id>-db`.

- **Pi 0.87.1** (`pi -p --model openrouter/anthropic/claude-haiku-4.5 --no-context-files --no-session -e <state>/<id>.pi-ext.ts "$PROMPT"`) - blocked. The model reported `[docker-bulk-rm]` for the second call; the sentinel recorded only `volume ls -q -f name=xwvol` and `volume rm <task-id>-db`; the task's status stream gained the `note:` denial line and the home's log gained the matching JSON line.
- **Claude Code 2.1.284** (`claude -p --model haiku --dangerously-skip-permissions --output-format text "$PROMPT"` in the worktree carrying the generated `.claude/settings.local.json`) - blocked, with the same sentinel, note, and reason code.

Re-run this record after a Pi or Claude Code upgrade before trusting it for the newer version.
