# 15. Scroll state on items: measured, placed, scrolled natively

Status: accepted (2026-10-17). Owner-approved briefs: [`docs/briefs/2026-10-scroll-state.md`](../../docs/briefs/2026-10-scroll-state.md) (the model) and [`docs/briefs/2026-10-scrolling.md`](../../docs/briefs/2026-10-scrolling.md) (native scrolling; its spacer and height-guess design is superseded). Plan: [`agents/plans/scrolling.md`](../plans/scrolling.md). Evidence: [`agents/research/scrolling/`](../research/scrolling/README.md), including the stage reports. Settles the scrolling part of ADR 7's layout-facts research item.

## Context

A buffer can be gigantic; drawing all of it cost 489 ms and 3.35 MB per key on a 50,000-line text (resource audit, 2026-10-15). Tuna must draw only what is near what the user looks at, keep scrolling smooth on desktops and phones, work over a slow link, and leave commands like `C-v` and session restore able to say where a view is. Layout belongs to the browser (ADR 7): only the browser knows how big anything is. Buffers are trees of arbitrary UI nodes (ADR 6, ADR 13), so nothing may assume uniform lines.

Prototypes tried every family of solution, on desktop Chrome and the owner's iPhone, at 0 and 80 ms round trips (research README):
- **The server moves the pixels** (Emacs-style; wheel and finger deltas go to the server, which redraws). Even with compressed, pipelined frames and server-side smoothing it trails input by one round trip; over lag the owner found it unacceptable.
- **Native scrolling over spacers** (a scroller covering the whole buffer, empty blocks standing in for undrawn content, sized by estimated heights). Smooth, but every bug came from the estimates: blank regions when estimates drifted, a scrollbar thumb sliding away from the pointer as the estimated total changed, special cases for unknown heights.
- **Native scrolling over drawn items only** (this decision). Smooth, and nothing is guessed.

## Decision

- **Items.** A scroller lays out *items*. A node kind says how it opens into items (`items:` on the kind: its children's items, or whole); a text node's items are its lines; any other node is one item. Each item has an identity that survives edits around it (a node, or a text position that relocates as point does), and a token the page carries on its element. Scrolling code knows items, never lines, rows or nodes.
- **Scroll state** per scroller (today each view): the item at the top edge and the px of it above the edge, as the browser measured. It lives on the view in the buffers contract with the last measured facts (last item wholly in view, visible count, size) and the derived before/after counts of items to draw, which are only a fetching step and are never saved.
- **Nothing is guessed.** The server never stores or estimates a pixel size or position. A scroller holds only drawn items; its native scroll range is what is drawn. How many items to draw on each side follows the density the browser measured, toward the `drawn-above`/`drawn-below` settings (default 20,000 px each, chosen by the owner on his phone).
- **Two flows.** The browser *reports* what it measured (one report in flight; a report removes its trigger, and the next screen restores it). The server *places* an item (top, centre, bottom, or an exact offset) once per placement, through a marker element whose id carries the placement number; reports measured before the newest placement are ignored. A refresh places the current scroll state, so it keeps place; a restart restores the saved newest placement.
- **The browser moves the pixels.** Native scrolling, momentum and touch, on the compositor thread. The browser holds the measured top item still when items are added above it (scroll anchoring, and a correction where Chrome does not anchor near the top). Screens are sent only once the page applied the last one (`/applied`), and the page reads every input body before it is answered.
- **Tuna's scroll bar** replaces the browser's: drawn by the renderer, its handle at the top item's index over the item count, sized by the items in view; dragging places the item at that fraction; clicking the track pages. On phones it is a thin indicator while scrolling.
- **Scroll reports are special events** (Emacs's `special-event-map`): handled as soon as they arrive through `call-special-command`, never `this-command` or `last-command`, no command hooks, a pending prefix untouched. The event kind decides. Scroll bar events and scroll commands are ordinary commands.
- **Point and the view: whichever moved last wins.** After a command that moved point or edited its text, a point outside the measured visible items is placed: at the edge it passed, or the centre when more than a screen away. After scrolling, point moves into view keeping its column, unless `scroll-moves-point` is off. `C-v`/`M-v` keep two items of context; `C-l` cycles centre, top, bottom. Splitting copies the placement; showing a buffer places point.
- **Placement in plugins:** items, scroll state, placements and facts in the buffers contract; report and scroll bar events in the keys contract; parsing and the browser actions (`tunaScroll`, `tunaPlace`, `tunaScrollBar`) in the web plugin; drawing the item run, the marker and the scroll bar in the renderer; `view-scrolled`, the commands and the point policy in the scrolling plugin; saving placements with the layout's view data. The kernel is unchanged.

## Consequences

- No estimate can drift, so blank regions and a sliding thumb cannot come from it. Places nobody has seen cost nothing.
- A fling can briefly reach the end of what is drawn; with 20,000 px each way it is rare. Dragging the scroll bar far shows the old items for one round trip.
- The scroll bar counts items, so its handle reflects position in content, not in pixels; tall and short items weigh the same.
- Each key redraws every drawn item: about 39 ms and 370 KB per screen at 20,000 px. Per-item HTML reuse and stream compression are follow-ups (`TODO.md`, roadmap item 8).
- Items taller than the view scroll by whole items with the commands (Emacs scrolls inside a tall line with vscroll).
- Node scrollers (a node scrolling in its own box) and the layout's scroll containers use the same model; they are built with their first user.

## Alternatives considered

- **Server-moved pixels** (three variants, including pipelined compressed frames, server-side smoothing, and a local preview that slides the frame by unshown input). Rejected: one round trip behind the finger; the preview variant is client-side prediction, which the owner ruled out.
- **Spacers sized by estimates**, with per-item estimates and remembered measurements (CodeMirror's height map). Rejected: still estimates, and the owner judged guessing sizes unacceptable for arbitrary UI.
- **Hyperlith's fixed-size virtual scroll.** The pattern this decision adapts (native scroll, server windowing, threshold reports, one in flight), without the fixed item size.
