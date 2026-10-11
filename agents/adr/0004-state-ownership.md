# 4. Owner-confined mutable objects, persistent text, revision counters

Status: accepted (2026-10-11); amended after the [capability audit](../research/capability-audit/README.md) (split revisions, thread-scoped context; settings moved to ADR 9).

## Context

UI is a function of state, so rendering must read one coherent state. Earlier research recommended a single immutable application root with pure transitions ([research](../research/editor-corpus/prior-art/workbench-gerbil/research/tuna-clean-immutable-state-recommendation.md)), and the previous Gerbil attempt built module-owned models with prepare/apply/rollback machinery. Gerbil has no installed persistent hash map or vector ([research](../research/editor-corpus/prior-art/workbench-gerbil/research/gerbil-immutable-state-feasibility.md)), so an immutable root requires building them and forces package authors to write state transitions instead of `(insert "x")`. Emacs packages are written imperatively against mutable buffers, windows, and variables.

## Decision

- **Objects.** Editor state is a graph of ordinary mutable objects (`defclass`): texts, buffers, views, windows, frames, the minibuffer, keymaps, input sessions, and plugin-owned state. Plugins define their own state objects.
- **Confinement.** Only the thread holding the editor baton ([ADR 3](0003-command-loop-and-jobs.md)) may read or mutate live editor objects. Other threads receive immutable snapshots or plain data.
- **Persistent text.** Text content and its properties are persistent: an edit produces a new version that shares structure with the old one, so a snapshot is free ([ADR 6](0006-buffers-nodes-and-text-store.md)).
- **Revisions.** Renderable objects carry monotonically increasing revisions. A text has two: a *character* revision (characters changed) and a *content* revision (characters or properties changed), as Emacs has `buffer-chars-modified-tick` and `buffer-modified-tick`. Decorations that are not content (overlays, highlights, diagnostics, selection) have their own *decoration* revision. Jobs check the revisions their inputs depend on; rendering checks all of them.
- **Change journal.** Each text keeps a bounded journal of change records since recent revisions. Markers, overlays, undo, hooks, and job rebasing ([ADR 3](0003-command-loop-and-jobs.md)) all consume the same records.
- **Command context.** `current-buffer`, match data, and similar per-command context are thread-scoped values ([ADR 9](0009-settings-and-scoped-values.md)), so suspended commands never see each other's context.
- **No transactional rollback.** A command that fails midway leaves its partial changes, as in Emacs. User-facing recovery is undo. A command that needs atomicity uses explicit helpers, such as a cancellable undo group.
- **Undo** belongs to a text ([ADR 6](0006-buffers-nodes-and-text-store.md)), is recorded from change records with boundaries per command, and is memory-only at first.
- **Settings** are specified in [ADR 9](0009-settings-and-scoped-values.md).

## Consequences

- Package code reads like Emacs code: fetch the current buffer, mutate it.
- Rendering runs on the baton or reads from snapshots; it never observes a half-applied command, because tasks do not yield mid-edit except at documented yield points.
- There is no time travel over the whole application state. Per-object revisions plus text snapshots are enough for jobs and rendering.
- Safety relies on the baton discipline rather than on immutability. Debug builds may assert baton ownership in mutating APIs.

## Alternatives considered

- **Single immutable root with pure transitions.** Rejected: needs persistent collections Gerbil lacks, burdens every package author, and buys rollback that Emacs users do not expect.
- **Fact database or event sourcing.** Rejected: no requirement justifies it.
- **One revision per buffer.** Rejected: adding an overlay or a highlight would invalidate every in-flight job.
