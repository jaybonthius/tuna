# Plan: mouse input (clicks and node keymaps)

Owner-approved brief: [`docs/briefs/2026-10-mouse-input.md`](../../docs/briefs/2026-10-mouse-input.md) (2026-10-13, trimmed: no dragging). Evidence: [`agents/research/mouse-input/`](../research/mouse-input/) (research and spike report; spike screenshots in `/home/jay/Code/workbench-gerbil/scratch/tuna-mouse/`).

## Invariants

- The server processes everything (STATUS owner decision): a click changes nothing until the server's screen arrives; the browser never names a command; the browser owns only presentation (hover, pressed, cursor).
- Pointer items share the keyboard's ordered queue, client id and sequence counter (research 2.3; spike question 1).
- Emacs event names and lookup: `mouse-1`, modifiers, `double-`/`triple-` with fallback to single, the part kind as a prefix key (`<tab> <mouse-1>`), lookup at the clicked part, not the selected view. A click selects nothing by itself; selecting is what the default binding does.
- Parts are named by stable id, never position; a click on a part that is gone reports it in the echo area and does nothing.
- Placement: browser code in `frontend/`; parsing in the web transport; events, `posn`, and lookup in the keys contract and plugin; bindings in the plugins that own the parts. The kernel is unchanged.
- `make test` green; each stage checked in a real browser in an isolated run with screenshots.

## Stages

1. **Clicks.** **Done 2026-10-13** (merged; report `/home/jay/Code/workbench-gerbil/scratch/tuna-mouse/stage1-report.md`; part kind `tab-line`, not `tab`; input bundle now `web/tuna-input.js`). Pointer listener (click on release) in `frontend/`; `data-part` on views, tabs and status lines and `data-revision` on the screen; server-side validation; `posn` and pointer events; `last-command-event` holds either kind, with `event-start`, `posn-view`, `posn-part`, `posn-node`; bindings `<view> <mouse-1>` (select the view), `<tab> <mouse-1>` (switch tab), `<status-line> <mouse-1>` (select its view). Views marked `no-other-view` (the bar) refuse selection by click. Clickable parts marked by the server (`data-clickable`) with hover, pressed and pointer styles; `preventDefault` on `mousedown` for chrome so keyboard input continues. Stale clicks report. Also fix `buffer-texts`' use of `append-map` (which reverses sublists; TODO upstream item).
2. **Node keymaps.** Keymaps on buffer nodes and layout parts; lookup for clicks starts at the clicked node, and for keys at the focused node, walking up through the buffer, the view and its containers, then the global map. The minibuffer's keys move from a pushed input target to its prompt buffer's keymap, fixing the `RET`-after-leaving bug. `data-clickable` comes from real bindings beyond the global fallbacks; a keymap generation number joins the HTML-reuse key. A demo sidebar of buttons (`<mouse-1>` and `RET`).

## Not in this plan

Dragging of any kind (parts, split borders) and the drag mechanism, deferred to the layout outline work; clicking or selecting inside text; touch; context menus.
