# 4. Owner-confined mutable objects, persistent text, revision counters

Status: accepted (2026-10-11)

## Context

UI is a function of state, so rendering must read one coherent state. Earlier research recommended a single immutable application root with pure transitions ([research](../../research/editor-corpus/prior-art/workbench-gerbil/research/tuna-clean-immutable-state-recommendation.md)), and the previous Gerbil attempt built module-owned models with prepare/apply/rollback machinery. Gerbil has no installed persistent hash map or vector ([research](../../research/editor-corpus/prior-art/workbench-gerbil/research/gerbil-immutable-state-feasibility.md)), so an immutable root requires building them and forces package authors to write state transitions instead of `(insert "x")`. Emacs packages are written imperatively against mutable buffers, windows, and variables.

## Decision

- **Objects.** Editor state is a graph of ordinary mutable objects (`defclass`): buffers, windows, frames, the minibuffer, keymaps, and plugin-owned state. Plugins define their own state objects.
- **Confinement.** Only the thread holding the editor baton ([ADR 3](0003-command-loop-and-jobs.md)) may read or mutate live editor objects. Other threads receive immutable snapshots or plain data.
- **Persistent text.** Text content is persistent: an edit produces a new version that shares structure with the old one, so a snapshot is free. Buffers hold the current version mutably ([ADR 6](0006-buffers-nodes-and-text-store.md)).
- **Revisions.** Each buffer (and other renderable object) has a monotonically increasing revision, incremented on every change. Revisions drive render invalidation and stale-job rejection.
- **No transactional rollback.** A command that fails midway leaves its partial changes, as in Emacs. User-facing recovery is per-buffer undo. A command that needs atomicity uses explicit helpers (for example an undo amalgamation group that it can cancel).
- **Undo** is per buffer, recorded as a list of change records, and memory-only at first.
- **Buffer-local and scoped values.** Settings resolve from the most specific scope outward (node, buffer, mode, global), implemented as ordinary data in owning objects, not as dynamic variables.

## Consequences

- Package code reads like Emacs code: fetch the current buffer, mutate it.
- Rendering runs on the editor thread or reads from snapshots; it never observes a half-applied command, because commands do not yield the baton mid-edit except at explicit suspension points.
- There is no time travel over the whole application state. Per-object revisions plus text snapshots are enough for jobs and rendering.
- Safety relies on the baton discipline rather than on immutability. Debug builds may assert baton ownership in mutating APIs.

## Alternatives considered

- **Single immutable root with pure transitions.** Rejected: needs persistent collections Gerbil lacks, burdens every package author, and buys rollback that Emacs users do not expect.
- **Fact database or event sourcing.** Rejected: no requirement justifies it.
- **Mutable gap-buffer text with copied snapshots.** Not chosen as the default because every job snapshot would cost O(n); still allowed as an alternative `TextStore` ([ADR 6](0006-buffers-nodes-and-text-store.md)).
