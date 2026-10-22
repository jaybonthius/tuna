# 17. Drawing only what changed: `memo` pieces over revisioned sources

Status: accepted (2026-10-22). Owner-approved brief: [`docs/briefs/2026-10-drawing-only-what-changed.md`](../../docs/briefs/2026-10-drawing-only-what-changed.md). Research: [`agents/research/rendering/`](../research/rendering/). Amends ADR 13 ("Drawing": HTML reuse keyed by hand) and ADR 7 (screen assembly); keeps ADR 7's fat morph and ADR 12's kernel unchanged.

## Context

Every redisplay sends the whole visible screen as one fat morph (owner decision, 2026-10-13). The server should still not recompute HTML for parts whose state did not change.

Today the renderer reuses HTML per node, all or nothing, keyed by a hand-written list of inputs: the node revision, view state, renderer identity, face remapping and keymap generation. The audit (`tuna-render-audit.md`) found three problems:
- **Every drawn line is rebuilt on any key.** A text node is one unit, so one key, or `C-f`, rebuilds every drawn line: 3 ms and 10 MB per tab.
- **The hand-written key is incomplete.** Line ids are dropped under reused ancestors (reproduced). A rebind repaints everything. Any renderer that reads a setting goes stale.
- **External state has no way in.** Nothing carries git status or a process list into the screen, and an idle editor rebuilds screens every 2 s.

The prior art splits four ways (`incremental-prior-art.md`):
- revision tags with recorded reads: Glimmer, Salsa, Adapton;
- reference equality: Elm, React, Clojure;
- content hashing: Merkle trees, Unison;
- hand-written keys or dirty flags: Hyperlith components, Emacs flags, today's Tuna.

Every editor surveyed avoids redrawing lines by comparing small per-line inputs after edits, never through the text store's structure (`text-rendering-prior-art.md`).

## Decision

- **Sources.** Everything a screen can depend on is a source with a revision that changes when the source does:
  - buffer nodes, through their attributes, children and keymap;
  - each text, as characters per line;
  - decoration layers;
  - cursors and selections;
  - keymaps;
  - settings;
  - each client's measurements;
  - plugin-owned outside sources such as git status and `/proc`.

  Reads go through the accessors of the contract that owns the source, and those accessors record the read.
- **`memo`.** Every piece of the screen is drawn through one function, `(memo key thunk)`. Pieces are the screen, a view, a node, an item (a line or a row), and any part a renderer chooses. `memo` runs the thunk in a tracking frame that records every source read. It reuses the piece's last HTML while no recorded source has a newer revision.
  - Pieces nest. A piece's reads include its children's, so an unchanged subtree is reused in one check.
  - Renderers stay ordinary recursive functions that never mention revisions.
  - `memo` is a library (`tuna/lib/`), not kernel vocabulary.
- **Automatic recording, not hand-written keys** (owner decision, 2026-10-22). A test mode renders every frame twice, memoized and from scratch, and fails when they differ. It also fails any write to a source during rendering. Together these catch a renderer that reads state behind the accessors.
- **Equality cutoff.** A derived value may be compared with `equal?`; when equal, its revision does not move. Leaves use it:
  - a line's inputs (its text, the decoration spans clipped to it, and the cursor and selection columns in it) are compared by value. Its position and the text's global revision are not inputs, so inserting a line leaves the others reused for any text store;
  - a node attribute set to an equal value stamps nothing.
- **Outside and asynchronous state.**
  - A source's reader runs off the editor thread, in a job that may post several results (ADR 3). It compares each reading with the last and posts only differences. When nothing differs, no task runs, nothing is drawn and nothing is sent.
  - Highlighting results carry the text revision they were computed for. They are rebased through the change journal, replace spans only in their range, and redraw only the lines whose spans changed.
- **Idle is idle.** Each owner of visible state keeps a generation. The display provider skips a tab when no generation moved since its last screen. Session saving is armed by a change, not by a repeating timer.
- **Tabs share pieces.** A piece that read no per-client source is shared by every client. A piece that read one belongs to that client.
- **Assembly.** Pieces are kept as UTF-8 bytes and written into the stream in order, not concatenated into one string. Each frame is still one whole-screen morph.
- **Cache lifetime.** A piece lives while the last frame of some client used it (mark and sweep per frame). It is not kept in Gambit weak-key tables, because they keep entries whose values point at their keys (`gerbil-mechanics.md`).

## Consequences

- One key or one cursor move redraws the lines whose inputs changed, plus small view parts. A live list redraws the rows that changed. An idle editor does no work.
- Every source owner must read and stamp through its contract's accessors, and the double-render test mode enforces this.
- Recording costs about 29 ns per read, and validating a piece about 0.01–0.14 µs (measured).
- A single very long line is still one item. Splitting long lines is later work.

## Alternatives

- **Hand-written keys per renderer.** Rejected by the owner: they drift, which is the class of bug the audit found.
- **Merkle or content hashing.** Not needed. Revisions already say what changed, and hashing costs O(size) per check. Revisit for cross-machine equality.
- **Line identity through a line-number shadow** (xi's `LineCacheShadow`). Not needed while lines are compared by value. Revisit if comparing lines shows up in profiles.
- **Patching individual elements instead of a fat morph.** Excluded by the owner's 2026-10-13 decision.

## Divergence from Emacs

Emacs redisplay compares glyph matrices and uses buffer-wide change counters. Tuna records each piece's reads and compares per-line inputs by value. External sources update rows in place, where `proced` and `magit` erase and reinsert. Record this in `docs/emacs-equivalents.md` when it is built.
