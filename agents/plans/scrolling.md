# Plan: scrolling

**Status: approved 2026-10-17; stage 1 merged 2026-10-17 (report `agents/research/scrolling/stage1-scroll-state-report.md`); stage 2 merged 2026-10-17 (report `agents/research/scrolling/stage2-scroll-state-report.md`); stage 3 next.** Briefs: [`docs/briefs/2026-10-scroll-state.md`](../../docs/briefs/2026-10-scroll-state.md) (the model; it supersedes the spacer and height-guess parts of [`2026-10-scrolling.md`](../../docs/briefs/2026-10-scrolling.md)). Evidence: [`agents/research/scrolling/README.md`](../research/scrolling/README.md). Already on `main` and kept: windowed drawing, one report in flight, screens sent only once the page applied the last (`/applied`), input bodies read before answering, the `drawn-above`/`drawn-below` settings, the `*long*` demo.

## Invariants

- **Nothing is guessed.** The server never stores or estimates a size or a position in pixels. Every pixel quantity comes from the browser's measurement of what is drawn. Counts of items to draw are only a fetching step derived from the last measurement.
- **A scroller holds only drawn items.** No spacer elements. Its native scroll range is what is drawn.
- **The scroller is generic.** It knows items, never lines, rows or nodes. A node kind says what its items are (`items:` on the kind, in the buffers contract beside the text projection): a text node's are its lines, a container's are its children's items in order, any other node is one item. An item's identity survives edits around it: a node, or a text position that relocates as point does.
- **Scroll state** per scroller = (item identity, pixels of it above the top edge as measured). Server-owned. Today the scrollers are views; node scrollers and layout scroll containers come when a concrete node kind or the strip layout needs them.
- **Two flows only:** the browser reports what it measured (one report in flight); the server places an item (top, centre or bottom) once per placement, and reports older than the newest placement are ignored.
- **The browser side is Datastar attributes the renderer writes plus small actions** in `plugins/web/frontend/`: report (measure), place (measure and move), and the scrollbar thumb's drag preview. No browser-owned editor state.
- The kernel does not change. Each piece lives in the plugin that owns its concept.

## Placement

| Piece | Owner |
|---|---|
| Item vocabulary: `items:` on node kinds; item identity; text items as lines | buffers contract (+ buffers plugin for text) |
| Scroll state, last measured facts, placement (target, alignment, number) on the view | buffers contract `view` |
| Report and scrollbar input events, their keymap names | keys contract (+ keys plugin resolves them) |
| Parse report and scrollbar items; `tunaScroll`, `tunaPlace`, thumb preview | web plugin |
| Draw the run of items around scroll state; placement marker; the scrollbar (position in items) | renderer plugin |
| `view-scrolled` (adopt measured state, adjust before/after counts from measured pixels), scrollbar commands, later the scroll commands and point policy | scrolling plugin |

## Stages

1. **Scroll state on items.** Replace spacers and every height guess with the model above, for view scrollers. Items for text nodes and containers; a second demo buffer of 10,000 non-text row nodes, scrolled the same way, proves the scroller is generic. The server-drawn scrollbar: thumb from the top item to the last visible item over the item count; dragging places the item at that fraction; clicking the track pages. A refresh keeps your place (the page's first screen carries a placement to the current scroll state). **Accept:** `make test`; the browser check ported (no blank frames, no jumps, top reachable, no reports while idle) on `*long*` and on the row demo, desktop and phone widths, 0 and 80 ms round trip; a reload test lands on the same item; a drag to 50% lands at the middle item; a key in the 50,000-line buffer costs about a screenful; the owner tries it on his phone.
2. **Commands, point and persistence.** `C-v`, `M-v`, `C-l`, `M-<`, `M->` as placements; after other commands, point's item is placed into view when it is outside the last reported visible items; scrolling by hand moves point into view unless `scroll-moves-point` is off; scroll state saved and restored with the session; showing a buffer in a view places point. **Accept:** the brief's walkthrough runs in the browser; tests for each command and both setting values; restart keeps place.
3. **Records.** A new ADR (scroll state on items, measured positions, placement, Tuna's scrollbar, the native-versus-server-scrolling evidence); ADR 7's layout-facts item settled for scrolling; `docs/overview.md` with the diagrams; `docs/emacs-equivalents.md` (window-start and vscroll map to scroll state; native motion and an item-counting scrollbar diverge); `TODO.md`; `agents/STATUS.md`.

## Not in this plan

Node scrollers and layout scroll containers (the model covers them; build with their first user), horizontal scrolling, stream compression (roadmap item 8), the phone input proxy.
