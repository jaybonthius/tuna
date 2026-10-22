# Plan: drawing only what changed

**Status:** approved 2026-10-22 (brief `docs/briefs/2026-10-drawing-only-what-changed.md`, ADR 17). Stage 1 merged 2026-10-22 (`16f0891`); stage 2 merged 2026-10-22 (`965eeac`; design and as-built notes in `agents/plans/drawing-stage2-design.md`). Stage 3 merged 2026-10-22 (`6d00e95`; design and as-built notes in `agents/plans/drawing-stage3-design.md`). Next: stage 4.

## Invariants

- **The output does not change.** Every frame is still one whole-screen fat morph, and the HTML the browser receives is the same as without memoization. The double-render test mode proves this on every test screen.
- **The kernel does not change.** `memo` and sources live in `tuna/lib/`, and each source lives in its owner's contract and plugin.
- **Renderers never mention revisions.** They read through contract accessors, which record what they read.
- **Writes are never part of drawing.** Drawing writes no source and no renderer-global table (test mode fails otherwise); line-id pins move to a view-owned source updated outside drawing. Today's render-time side effects (point relocation, scroll-item rewrite, creating client views) move out of the read path or become explicit derived caches.
- **Idle is zero:** zero tasks, zero screens built, zero bytes beyond heartbeats.
- **No backward compatibility.** Delete the hand-written key (`kept-html` with its `view-state`, `how` and `inputs`) when `memo` replaces it.

## Placement

| Piece | Owner |
|---|---|
| `memo`, sources, tracking frame, equality cutoff, double-render test mode | `tuna/lib/memo.ss` (library) |
| Node, text, decoration, cursor and client-view sources; recorded reads in their accessors; no stamp on an equal value; per-layer highlight ranges | buffers contract and plugin |
| Keymap and settings sources | keys and settings contracts and plugins |
| Generations per owner; the display provider skips unchanged tabs; pieces written as bytes; tabs sharing pieces | the contracts above, web plugin, renderer plugin |
| Drawing every piece through `memo`; per-item pieces with value inputs; tokens without the global revision | renderer plugin |
| Jobs that post several results | `tuna/lib/jobs.ss` (ADR 3) |
| Change-driven session save | session and autosave plugins |
| A source helper, if three users repeat the job loop | `tuna/lib/`, only then |
| Process-list proof | new `plugins/proced/` |

## Stages

1. **Fix the line-id bug, and make idle idle.**
   - Fix the bug: carry line pins forward for text nodes that are reused but not visited.
   - Add a generation to each owner of visible state, and have the web plugin skip tabs whose generations did not move.
   - Make `set-node-attribute!` stamp nothing for an equal value.
   - Arm session and autosave by a change instead of a repeating timer.
   - Tests:
     - The bug's reproduction from the audit (`bench pin`).
     - 60 s idle with two tabs: zero tasks, zero screens built.
2. **`memo` and sources.**
   - Build `tuna/lib/memo.ss` with `(memo key inputs thunk)`: `inputs` compared by `equal?`, the thunk closing over nothing else; explicit keys only, duplicate keys an error in test mode; per-client mark and sweep that keeps the descendants of reused pieces live.
   - Dynamic parameters read while drawing (`rendering-view`, `rendering-lines`) become sources or `inputs`.
   - Client measurements are rounded and compared before they count as changed.
   - Make the contract accessors record reads.
   - The renderer draws the screen, views and nodes through `memo`, keyed by identity. Delete the hand-written key.
   - Add the double-render test mode to the renderer and web tests.
   - Tests:
     - A renderer reading a setting is redrawn when the setting changes.
     - A rebind redraws only nodes whose keymap changed (`TODO.md`).
     - A piece with no per-client reads is drawn once for two tabs.
3. **Lines and rows by value.**
   - Items become `memo` pieces whose inputs are values: the line's text, the spans clipped to it, and the cursor and selection columns in it.
   - Tokens stop embedding the global revision.
   - Point becomes an input of its line, no longer of every ancestor.
   - Highlight layers record changed ranges.
   - Tests:
     - A key redraws one line; `C-f` redraws one; three cursors redraw three.
     - Inserting a line above leaves the drawn lines reused.
     - A highlight result redraws only the lines whose spans changed.
     - The same results with the toy text store.
4. **Bytes on the wire.**
   - The owner approved this approach on 2026-10-22: the owner's packages gain general streaming primitives, and their existing API is unchanged.
     - **gerbil-sse** gets a "write one event" primitive (lock, the stream's writer, flush). `sse-send!` is built on it.
     - **gerbil-datastar** keeps the SDK specification's functions (`patch-elements`, `patch-signals`, `execute-script`) and gains a helper, `call-with-patch-elements`. It writes the event header, hands the caller a writer for the elements (newlines become new `data: elements` lines), then ends the event. Its internal send stays the single path for every event, as the SDK specification asks.
     - The wire bytes are unchanged (the Clojure SDK's `patch-elements-seq!`, templ writing to an io.Writer, and Hyperlith all stream the same way).
     - Measure a scratch prototype first.
   - Pieces are kept as UTF-8 bytes and written into the event in order.
   - Remove the whole-screen copies: the revision stamp, the `/applied` stamp, line splitting.
   - Tests: identical bytes to before; measured frame cost.
5. **Outside state, and the proof.**
   - Jobs may post several results.
   - New `plugins/proced/`: a `*Processes*` buffer with one row node per pid, read from `/proc` (a plugin option sets the root, so tests use fixtures) once a second in a job that posts only differences.
   - Measure outside the plugin:
     - rows drawn equal rows changed, with one and with two tabs;
     - 60 idle seconds cost zero tasks, zero screens and zero bytes;
     - typing latency (p95) is unchanged while every row changes.
   - Check in two real browsers.
6. **Records.**
   - Amend ADRs 7 and 13 to point at ADR 17.
   - `docs/overview.md`: a drawing section with the brief's diagrams.
   - `docs/emacs-equivalents.md`: redisplay, `proced`.
   - `agents/STATUS.md`, `TODO.md` (remove the items this closes), roadmap.

After each stage: measure `*long*` and `*mixed*` with the audit's benchmark (`scratch/rendering-audit/bench`) and compare with the audit's numbers.

## Not in this plan

- Splitting very long lines into chunk items.
- Replacing the SXML writer (the owner's typed XML module).
- Compression (roadmap item 8).
- A "buffer shown or hidden" hook, so sources stop while no view shows them (add it with its second user).
- magit.
