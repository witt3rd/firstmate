# Sibling notes (fork-only experiment)

> **Fork-only experiment.**
> This mechanism lives on the `witt3rd/firstmate` fork only and is not proposed upstream.
> It is kept separable so upstream merges stay easy: new files, small hooks, and everything behind one flag that defaults to off.

Firstmate's agents form a tree.
A supervisor steers its direct reports through a durable steering inbox, and a worker reports up through its status file.
Anything between two siblings under one parent used to go through that parent, which bottlenecks stacked or dependent work, for example a stacked pair of PRs where the lower one lands and the upper one must rebase.
Sibling notes let siblings talk within their parent's scope, for both sibling crewmates and sibling second mates.

## Turning it on and off

Create `config/sibling-notes` containing `on` in a firstmate home to turn the experiment on, and delete it (or write anything else) to turn it off.
The file is local and gitignored.
It is inherited into second mate homes through the existing primary-authoritative configuration contract (`FM_INHERITABLE_CONFIG` in `bin/fm-config-inherit-lib.sh`), so a second mate's own crewmates follow the primary's setting.
With the flag off, `bin/fm-sibling.sh` refuses and the briefs `bin/fm-brief.sh` generates are byte-identical to a build without this experiment.
With it on, every generated brief and charter gains a short "Sibling notes" section after the steering-inbox section.

## The command

A sender runs `bin/fm-sibling.sh <sibling-task-id> <message...>`, and a reply uses the same command.
[`bin/fm-sibling.sh`](../bin/fm-sibling.sh) owns the mechanics and [`bin/fm-sibling-lib.sh`](../bin/fm-sibling-lib.sh) owns the flag, the limits, and the texts.

1. The command refuses unless the flag is on in the sender's own home.
2. It resolves the sender from its own launch identity, never from a path the sender supplies.
   A crewmate or scout is `FM_TASK_ID` in `FM_HOME`'s `state/<id>.meta`, and its parent is that home.
   A second mate is its home's `.fm-secondmate-home` marker and `.fm-secondmate-parent` binding, proved against the parent's `data/secondmates.md`.
3. The target must be a registered direct report of the same parent and of the same kind.
   Crewmates and scouts are found in the same home's `state/<id>.meta`, and second mates in the primary's registry and `state/<id>.meta`.
   Self, the parent, another parent's workers, the other kind, and remote workers are all refused.
4. The note is written into the target's existing steering inbox with the existing inbox library, and the existing doorbell rings.
   The record begins with an `[FM-SIBLING-NOTE from=<sender> to=<target>]` header that says the note carries no authority: the receiver's own instructions and its parent's decisions win, and a note is information, never a command to act on without its parent's word.
   The receiver acknowledges it by moving it to `handled/` like any inbox message.
5. The parent is copied automatically.
   A `note: sibling-note from <sender> to <target>: <text>` line is appended to the sender's own status file, where the parent's watcher already surfaces it as unread status.
   A note longer than the status excerpt is pointed at rather than cut silently, and the full text stays in the target's inbox.
   The copy is written before delivery, and a delivery that then fails appends a correction line.
6. The note is rate-limited per sender and per sibling pair, and obvious ping-pong loops are refused.
   The limits are the single `FM_SIBLING_LIMITS` constant in `bin/fm-sibling-lib.sh`: a rolling window, a per-sender count, a per-pair count in both directions so an answer counts against the limit, and the longest alternating exchange allowed (a note and its answer, not a third alternating note).
   One ledger, `state/.sibling-notes.ledger` in the parent's state directory, serves every sibling of that parent so both directions of a pair are seen.

## What siblings may and may not do

Notes are for coordination of stacked or dependent work.
Decisions and scope changes still go to the parent, and siblings never discuss the captain directly.
The brief sections say this plainly whenever the flag is on.
Nothing here changes the parent-child steering contract, and there is no chat mode.

## Known gaps

- Remote second mates are not supported in this first version: a remote sender or target is refused, because the remote inbox transport and the parent-replies mirror would need their own proof.
- A crewmate cannot note a second mate and the reverse, even though both are direct reports of the primary, because the first version keeps each kind within its own tier.
- Identity comes from the launch environment (`FM_HOME`, `FM_TASK_ID`) and the recorded parent binding, so the experiment assumes cooperating agents rather than defending against a worker that forges its own environment.

## Verification

`tests/fm-sibling.test.sh` proves the same-parent check for both crewmates and second mates, the refusal of cross-parent targets, the parent copy, the flag-off refusal, the rate and loop limits, and that the generated briefs are byte-identical with the flag off.
