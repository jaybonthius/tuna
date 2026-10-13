# Plan: buffers, views and layout

Owner-approved brief: [`docs/briefs/2026-10-buffers-views-layout.md`](../../docs/briefs/2026-10-buffers-views-layout.md) (2026-10-13). Decision record: [ADR 13](../adr/0013-views-layout-and-frames.md). Evidence: [`agents/research/layout-state/`](../research/layout-state/README.md).

## Invariants (every stage)

- **Placement.** Contracts in `tuna/services/`, defaults in `tuna/plugins/`, contract doubles in `tuna/test-support/`. The kernel gains nothing; the boundary test is unchanged. No `tuna/lib/` tree library.
- **Immediate mode.** Every redraw sends the whole visible screen as one fat morph; no per-part patches.
- **Replaceability is proved, not claimed.** Each new or reshaped contract has a second provider among the test doubles, and a test swaps providers while Tuna runs.
- `make test` stays green; each stage is checked in a real browser in an isolated run (not the real `~/.local/state/tuna`). Each merge reports placement and kernel line change.

## Stages

1. **Names and the buffers contract.** The screen looks the same as today.
   - Merge `window` into `view`: a view gains an identity and the layout's role; `WindowManager` becomes the layout contract (`tuna/services/layout.ss`, `layout-service`); `window-commands` becomes `view-commands`; rename throughout code, tests, the starter and the demo.
   - Split `tuna/services/buffers.ss` (audit P1-1): the contract keeps vocabulary and thin dispatchers; editing, undo, the journal, highlights, positions and relocation, and node creation move behind `Buffers` methods into `tuna/plugins/buffers.ss`. Nodes gain `parent` and `revision` (stamped up the parent path on each change), exposed through the contract.
   - Text links to files are not built here (no files yet); nothing may assume the link is on the buffer.
   - Buffers handover: replacing the provider carries buffers and the selected view across.
   - A toy buffers provider in `tuna/test-support/` passes the same contract tests; a test swaps it in while Tuna runs.
2. **The layout plugin**, replacing `single-window` in the starter.
   - Frozen layout value: fit and tabbed containers, each horizontal or vertical, sizes on parent links, last-focused child per container.
   - Commands: split below and right (`C-x 2`, `C-x 3`), delete (`C-x 0`), delete others (`C-x 1`), next view (`C-x o`), move to a neighbor, make a tabbed container and switch tabs; `display-buffer` with side and size hints; a dedicated view closes with its buffer.
   - Frames: the frame target (container, view, or view plus node), zoom in one level toward the selected view, zoom out, frame onto the node at point, frame marks (set, jump, list). Starter key bindings must not collide with Emacs defaults the starter already uses.
   - Session slot `layout`: layout and frame marks as plain data; restore tolerates missing buffers; the old `windows` slot is ignored.
   - The renderer draws from the frame target with CSS layout (no geometry on the server).
   - The two-window double becomes a toy layout provider; a test swaps layout providers while Tuna runs and keeps the views.
3. **Everything on screen is the layout.**
   - The minibuffer, echo area and help become buffers shown in views (`display-buffer` at the bottom; the minibuffer view exists only while a prompt waits and restores the previously selected view). The renderer's special cases go away.
   - HTML reuse: a part's HTML is reused when its revision, its view state, and the display-wide inputs are unchanged. A test proves an unchanged buffer's node renderers are not called on the next redraw, and that a face or setting change redraws everything.
   - After merge: update `docs/overview.md` (text, glossary, diagrams) to what was built.

## Keep in-view drawing possible (every stage)

- A tree's children can be counted and read as a range (`children 200 to 260`) through the contracts, even if the default walks a list today.
- Scroll position is view state the server may hold, not only browser state; nothing assumes otherwise.
- Every view, container and node element carries a stable id, so a fat morph keeps the browser's native scroll position and a component can later take an element over.
- The server computes no geometry; sizes stay CSS (fractions on parent links).

## Not in this plan

Scroll containers and drawing only what is in view (owner, 2026-10-13: deferred to keep this simple; later, with Datastar in the style of hyperlith's virtual scroll, or with a Rocket component); mouse input and node keymaps; files and the file link on texts; several browser tabs with their own frames; layout undo; narrowing a text node to an arbitrary region by frame.
