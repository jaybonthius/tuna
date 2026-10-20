# Plan: scrolling a view

**Status: approved 2026-10-17; stage 1 merged 2026-10-17 (report `/home/jay/Code/workbench-gerbil/scratch/tuna-scrolling/stage1-report.md`); stage 2 next.** Brief: [`docs/briefs/2026-10-scrolling.md`](../../docs/briefs/2026-10-scrolling.md). Evidence: [`agents/research/scrolling/README.md`](../research/scrolling/README.md), section "The prototype as rebuilt", and the prototype in `agents/research/scrolling/proto/` (`server.py` holds the placement and windowing arithmetic to port; `check.js` is the browser check).

## Invariants

- The kernel gains nothing. Reports are ordinary numbered input items; the anchor is view state in the buffers contract.
- Immediate mode stays: every screen is the whole visible UI as one morph. The stream re-sends the newest screen every tick, whether or not it changed; rendering still happens only when state changes.
- The browser owns only motion. It reports what it sees: the line at the top, its offset, the last visible line, `scrollTop`, where the drawn lines start and end, the viewport height, and the scroll request it last applied. It never computes positions for the server.
- Front-end code is Datastar attributes the renderer writes, plus one small action, `tunaScroll`, that sends a report through `input-sender.ts`, as `tunaPointer` does.
- The server never maps a raw pixel offset through estimates of the whole buffer. It places the anchor from the reported top line. In a spacer, it counts from the nearest edge of the drawn lines using the average line height measured from the drawn ones.

## Placement

| Piece | Owner |
|---|---|
| Anchor (line-start position plus pixel offset), last reported facts, scroll request number; `scroll-view-to!`, `view-first-visible-line`, `view-last-visible-line`; the anchor moves with edits as point does | buffers contract (`view`) and the buffers plugin |
| `scroll-event` and its keymap name | keys contract, like `pointer-event` |
| Parse the `scroll` item; `tunaScroll` action (`frontend/tuna-scroll.ts`); re-send the newest screen every `screen-interval` ms (plugin option, default 50; replaces the 15 s heartbeat); `TCP_NODELAY` on the stream if the HTTP server lacks it | web plugin |
| Window the text node holding the anchor: lines within about 3,000 px above and a screen plus 4,000 px below; spacers with `overflow-anchor: none`; `data-line` on each line; on the view's `.buffer` scroller, `data-effect` (report when the top line leaves the range, remove itself; the next screen restores it), `data-on:scrollend` (always report), and `data-init` keyed by the request number (jump once). The drawn range is part of the kept-HTML key. | renderer plugin |
| `view-scrolled` (bound to the scroll event: ignore reports older than the view's request, record facts, set the anchor, move point into view unless `scroll-moves-point` is off); keep point visible after other commands (a scroll request when point leaves the reported visible lines); `scroll-up-command` (`C-v`), `scroll-down-command` (`M-v`), `recenter-top-bottom` (`C-l`) | new `plugins/scrolling/` (no contract) |

## Stages

1. **Windowed drawing and reports.** Everything in the table except point visibility and the three commands. Add a demo buffer of 50,000 generated lines. Tests:
   - placement arithmetic for top-line, spacer-above and spacer-below reports;
   - drawn range and spacer heights;
   - a stale report is ignored;
   - parsing the scroll item;
   - the stream re-sends an unchanged screen.

   **Accept:** in Chrome on the demo buffer, `check.js` ported to the demo passes (no blank frames, no jumps, content after every scrollbar jump, line 1 reachable at the top, nothing posted while idle), with real wheel input too. A key in the 50,000-line buffer costs a screenful of render time and bytes, against the resource audit's 489 ms and 3.35 MB. The owner tries it on his iPhone.
2. **Point and commands.**
   - Point visibility after commands.
   - Scroll requests, `C-v`, `M-v`, `C-l`; `M-<` and `M->` work through point visibility.
   - The `scroll-moves-point` setting.
   - The anchor saved with the session.
   - Tests for each command and both values of the setting.

   **Accept:** the brief's walkthrough runs in the browser.
3. **Records.**
   - A new ADR: native scrolling with a server-owned anchor, reports as input, a continuous re-send, and the alternatives tried (server-moved pixels, client prediction).
   - ADR 7: layout facts settled for scrolling.
   - `docs/overview.md` with the two diagrams.
   - `docs/emacs-equivalents.md`: window-start and vscroll map to the anchor; native scrolling is a divergence.
   - `TODO.md`: the large-buffer redraw item, and the idle re-send from the resource audit.

## Not in this plan

Windowing nodes other than text (with the first rich buffer kind), horizontal scrolling, layout scroll containers, Brotli (roadmap item 8), the phone input proxy.
