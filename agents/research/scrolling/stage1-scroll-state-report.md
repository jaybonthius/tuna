# Scroll state, stage 1: report

Branch `scroll-state` in `/home/jay/Code/workbench-gerbil/tuna__scroll-state`, commits `b00ba08` (scroll state on items, measured, with placements) and `ae28537` (hold the top item still where Chrome does not anchor). Not merged, not pushed. The kernel (`tuna/`) is unchanged: `git diff 1a61c35 --name-only` lists nothing under `tuna/`.

## Result

The view scroller now follows the brief's model. Nothing is guessed: no spacers, no height estimates, no average line height. The server stores no pixel size or position. Every pixel number comes from the browser's measurements.

- `make test` passes under the memory cap: all Gerbil suites plus 20 frontend tests.
- Browser check (`check.js`, ported): **0 blank frames, 0 jumps, the first item reachable, 0 reports while idle** in all 8 configurations. That covers `*long*` and `*rows*`, at 1280×700 and 393×700, with 0 ms and 80 ms round trips: 1,700 frames each.
- Reload keeps your place exactly, on both buffers (same item, same pixel offset).
- Dragging the handle to 50% lands at the middle item. Clicking the track pages both ways.
- **Key cost is higher than the plan's target.** A key in `*long*` costs 34–39 ms of server CPU and 185–376 KB per screen at 20,000 px each way. That is proportional to the items drawn, not about a screenful (see Performance).

## Changes by module

For each changed module: the contracts it imports, and the services it declares.

| Module | What changed | Imports contracts | Services |
|---|---|---|---|
| `plugins/buffers/contract.ss` | **Items:**<br>- `item` (node, or a text position plus revision);<br>- `node-opening` (`lines`, `children`, `whole`);<br>- `node-item-count`, `node-item-at`, `node-item-index`, `node-child-items`, `item-line`, `item=?`, `item-token`, `token-item`;<br>- `items:` on `context-define-node-kind!` (`'children`, `'whole`, or `#f` for "children's items if it has children, else one item"); text nodes open into their lines.<br><br>**On the view** (the old anchor and request fields are gone):<br>- scroll state: `view-scroll-item`, `view-scroll-offset`, `set-view-scroll!`;<br>- `placement` (number, target, align, offset) with `view-placement` and `place-view!`;<br>- `scroll-facts`: last visible item, visible count, width, height;<br>- `view-last-visible-item`;<br>- the derived drawn-before and drawn-after counts (`set-view-drawn-items!`, `initial-drawn-after` = 200);<br>- the `drawn-above` and `drawn-below` settings, moved here, default 20000. | text-store, settings (unchanged); new `HashTable` import from the runtime | defines `buffers-service` |
| `plugins/buffers/plugin.ss`, `tests/support/toy-buffers.ss` | `node-kind-info` gained `items` (#f for text) | unchanged | provides buffers; requires text-store, settings (unchanged) |
| `plugins/keys/contract.ss` | `scroll-event` reshaped to measured items and pixels plus a placement number. New `scroll-bar-event` (view posn with area `vertical-scroll-bar`; part `handle`, `above-handle` or `below-handle`; fraction) and `scroll-bar-event-keys`. `event-start` handles both. | buffers (`node` only, unchanged) | — |
| `plugins/keys/plugin.ss` | `resolve-scroll!` resolves both event kinds under their keys: `<scroll>`, `<vertical-scroll-bar> <drag-mouse-1>` and `<vertical-scroll-bar> <mouse-1>`. | keys, commands, settings, buffers subset (unchanged) | provides input; requires commands; optional settings, buffers (unchanged) |
| `plugins/renderer/plugin.ss` (+ `rules.css`, `tokens.css`) | Draws only the run from (scroll item − before) to (scroll item + after), inside the minimal ancestor structure. Each item element carries `data-item` (its token). Line ids are pinned to text. The scroller's attributes: `data-scroll-root`, the drawn-above and drawn-below px, `data-run-at-start` and `data-run-at-end`, the measured size. Also draws the placement marker (`view-V-placement-N`, constant `data-init="@tunaPlace()"`) and the scroll bar. Items get no margins; the native scrollbar is hidden. | stylesheets, keys subset, settings, renderer, buffers, layout (unchanged) | provides renderer; requires buffers, layout, settings; optional input (unchanged) |
| `plugins/renderer/contract.ss` | `drawn-above` and `drawn-below` moved out (deviation 1) | unchanged | — |
| `plugins/scrolling/plugin.ss` | `view-scrolled`: ignores stale placements, adopts the measured item and offset, keeps the facts, and adjusts the counts by measured density (`adjusted-count`, `fetching-step` = 16). New commands: `scroll-bar-drag` (item ⌊fraction × count⌋ at the top) and `scroll-bar-page` (the last visible item to the top, or the top item to the bottom). Names no lines. | commands, keys, **settings (new)**, buffers, layout | requires commands, input, buffers, layout, **settings (new)** |
| `plugins/web/plugin.ss` | Strict parsing of the new `scroll` and `scroll-bar` items: tokens are digits and dots, at most 64 characters; counts are non-negative; pixels are bounded; the fraction is in 0..1. | keys subset (adds the scroll-bar names), renderer, stylesheets | provides display; optional renderer (unchanged) |
| `plugins/web/frontend/` | **`tuna-scroll.ts`:**<br>- `tunaScroll` measures and reports by the rules below;<br>- `tunaPlace` applies top, centre, bottom or an exact offset;<br>- a report holds its top item still through the next screen (deviation 4).<br><br>**`tuna-scroll-bar.ts`:** `tunaScrollBar` previews the handle under the pointer and sends the newest fraction, one in flight; a track click pages.<br><br>**`input-sender.ts`:** `send` returns a promise. | — | — |
| `demo/rows.ss` and `rows.css` (new), `demo/init.ss` | `*rows*`: 10,000 `row` nodes (each one item; every seventh has two lines) under a `rows` node (`items: 'children`), bound to `C-c G` | kernel, commands, keys, buffers, layout, stylesheets | requires commands, input, buffers, layout |
| `tests/support/theme-terminal/renderer.css` | Scroll bar tokens replace the spacer token | — | — |

`make test` checks the boundaries mechanically: no plugin imports another plugin, contracts do not re-export, and every service used is declared (`demo-check` included).

### Reports (browser to server)

A report carries what the browser measured:
- the screen revision;
- the view and the node its scroller draws from;
- the last placement it applied;
- the top item's token, and the px of that item above the edge;
- the last visible item's token;
- how many items are drawn before and after the top item;
- the px drawn above (`scrollTop`) and below;
- the view's width and height.

It reports when any of these holds:
- less than half of drawn-above is drawn above, and the run does not start at the first item;
- the same below, against the last item;
- more than twice the setting is drawn, and an item lies more than half the setting beyond the edge, so drawing fewer still leaves enough;
- the size differs from the last one the server heard;
- `scrollend`;
- after a placement.

One report is in flight at a time. Thresholds pass as attributes and arguments, never as signals written in the effect.

## Tests

| Test | What it covers |
|---|---|
| `tests/integration/buffers-contract-test.ss` (both providers) | Items for text, container, atomic, empty and `items: 'whole` nodes: count, index to item and back, out of range, nodes inside a whole item, `node-child-items`. Identity through edits: line insertion above, deletion into the line, tokens from before an edit, malformed tokens, a node removed from the tree. |
| `plugins/scrolling/tests/integration/scrolling-test.ss` | Adopting state and facts (placement keeps its number). The item relocates through an edit. Counts grow by density and are clamped at both ends. `adjusted-count` grows by density with the minimum step, holds in the band, and shrinks to 1.5 settings but not below the items in view. Stale placement reports are rejected. Wrong-node reports are rejected. Drag to 0, 0.5 and 1. Track paging both ways. |
| `tests/integration/html-renderer-test.ss` | Initial draw: 201 items, no spacers, the attributes, the marker, no bar. A run around the scroll item, the marker naming the current state, a new marker on placement, the handle's percentages. A container drawn with only its children's run. Line ids stay with their text through an edit above. |
| `plugins/web/tests/integration/web-test.ss` | Valid scroll and scroll-bar items, and malformed or forged ones (25 and 13 variants) dropped with 204. Key names. |
| `plugins/web/tests/unit/input.test.mjs` | `tunaPlace` alignment math with fake boxes: top, a negative offset, centre, bottom, clamped at the end, no target, an undrawn target. `tunaScroll`: nothing before a placement; the measured body; one in flight; each trigger (short or long above and below, run ends, size); owed `rest`; holding the top item; a new marker applied before reporting. Scroll bar: track click paging and `stopPropagation`; drag preview, newest-only and one in flight, end of drag, preview ended by placement. |

Commands, all under `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout …`: `make deps`; `make`; `make test` (final run: exit 0, `OK`, frontend 20 pass, 0 fail); focused `gerbil test` runs per suite.

## Browser numbers

Headless desktop Chrome through `agent_browser`. The demo config runs in a private `XDG_STATE_HOME`.

The 80 ms round trip comes from `phone-proxy.py 127.0.0.2 9470 40`:
- it listens on loopback alias 127.0.0.2:9470;
- it adds 40 ms each way;
- it rewrites Host and Origin to 127.0.0.1:9470, which Tuna checks.

`check.js` runs 1,700 frames per configuration: down 9,000 px/s, a decaying 24,000 px/s fling, up 9,000 px/s, a fling to the top, then down 3,000 px/s.

| Configuration | Blank frames | Jumps | First item at top | Idle reports | Reports in run |
|---|---|---|---|---|---|
| 393×700, 0 ms, `*long*` | 0 | 0 | yes | 0 | 1,138 |
| 393×700, 0 ms, `*rows*` | 0 | 0 | yes | 0 | 999 |
| 393×700, 80 ms, `*long*` | 0 | 0 | yes | 0 | 222 |
| 393×700, 80 ms, `*rows*` | 0 | 0 | yes | 0 | 205 |
| 1280×700, 0 ms, `*long*` | 0 | 0 | yes | 0 | 428 |
| 1280×700, 0 ms, `*rows*` | 0 | 0 | yes | 0 | 891 |
| 1280×700, 80 ms, `*long*` | 0 | 0 | yes | 0 | 179 |
| 1280×700, 80 ms, `*rows*` | 0 | 0 | yes | 0 | 208 |

Report counts are high at 0 ms because headless Chrome fires `scrollend` after every synthetic `scrollBy`. A report inside the band changes neither count (the reported drawn counts are kept), so the drawn run and its HTML stay as they were.

**Reload** (scroll by hand, then reload; 1280×700):

| Buffer | Before | After |
|---|---|---|
| `*long*` | line 25,387, 13 px above the edge | line 25,387, 13 px |
| `*rows*` | Row 5283, 7 px | Row 5283, 7 px |

An earlier deep test (line 4,796, 14 px, `scrollTop` 30,004) was also identical.

**Scroll bar** (real mouse drag, 1280×700, 637 px track):
- Handle to the middle: `*long*` lands on line 25,040 and `*rows*` on Row 5008. The handle was grabbed 5 px from its top and dropped 1 px below the exact middle (fraction 0.5008), and 1 px of track is 78 lines or 16 rows.
- Track click below the handle: `*long*` 25,040 at the top and 25,065 last → 25,065 at the top. Rows 5008 to 5028 → 5028 at the top.
- Track click above the handle: the top item goes to the bottom. `*rows*`: Row 5028 last, Row 5008 at the top with 8 px above.

Screenshot: `scroll-state-rows.png` beside this report.

## Performance: a key in `*long*`

Method:
- Configuration: the starter plugins plus the long-buffer demo (`measure-config/init.ss`), without the demo's digit highlighter. That highlighter rescans the whole text after each key and would dominate.
- A real browser at 1280×700 is scrolled where stated and presses `b` 30 times, 300 ms apart.
- `stage1-measure-listen.py` (beside this report) listens on its own confirmed stream and reads CPU from `/proc/PID/stat`. It loads no page, so the browser's input numbering is untouched.
- Point is at line 1, so each key changes the drawn text node.

| View | Items drawn | Server CPU per screen (minus idle) | Bytes per screen |
|---|---|---|---|
| at line 1 (0 px above, 19,994 below) | 820 | 34 ms | 185 KB |
| at line 25,040 (20,509 above, 20,005 below) | 1,656 | 39 ms | 376 KB |

There were 40 screens for 30 keys. The earlier stage 1 (209 lines, 3,000/4,000 px estimated) measured 5 ms and 46 KB. Cost per drawn line is about the same, roughly 225 B. The difference is how much is drawn at the owner's 20,000 px each way.

The plan's "a key costs about a screenful" is therefore not met. Two follow-ups would lower it:
- reuse HTML per line, so an edit redraws only the changed lines (CPU);
- stream compression, roadmap item 8 (bytes).

## Deviations and why

1. **`drawn-above` and `drawn-below` moved from the renderer contract to the buffers contract.** The scrolling plugin reads them to set the counts, but it does not call the renderer, so it could not declare `renderer-service` (`demo-check` rejected the import). They describe a view's scrolling, beside the view's counts, which already live there.
2. **`items:` on a kind takes `'children`, `'whole` or `#f`, not a procedure.** The brief's sample shows `items: node-children`. An enumeration keeps the item API efficient and checkable: counts are kept per node and revision, index lookups use binary search, and nothing walks every item. Text nodes always open into lines. Kinds with other openings (for example a list with virtual rows) would need this widened when one exists.
3. **`scroll-facts` keeps the visible count measured at report time** (index of the last visible item − index of the top + 1), with the last visible item and the size. The handle's top uses the scroll item's current index.
4. **The page holds its top item still through the next screen.** Measured: Chrome does not scroll-anchor content inserted above while the first drawn item is in view. Inserting 50 lines above at `scrollTop` 0, 1, 7, 8, 9, 12 or 20 did not adjust; at 30 it did.

   Effect: a placement with `before` = 0 (dragging from the top) drifted upward a few hundred lines per report. Two drags landed at lines 2,582 and 183 instead of 25,000.

   Fix: after a report, if the scroller has not moved by the next screen and the reported item moved, the page puts it back at its measured offset. This is presentation, from measurements only. It never writes `scrollTop` while the view is moving, so iOS momentum is not at risk.

   Also, the report trigger waits for a new placement marker to be applied before reporting. Otherwise it reported against the old placement first, which cost a stale round trip.
5. **Extra report rules.**
   - A `scrollend` during an in-flight report is remembered ("owed") and sent with the next screen.
   - The "far more than asked for" trim also requires an item beyond half the setting. Without that, one tall item would make the page report forever while idle.
6. **Count shrink and band.** The `after` side counts the visible items too. It shrinks to (items in view + ⌈1.5 × setting × density⌉), at least one fewer than now and never fewer than in view. Inside the band, the counts are the measured drawn counts, so the run does not move between reports.
7. **No scroll bar until the browser has measured the view**, and none when every item is in view.
8. **`check.js` no longer does random native-scrollbar jumps:** the native bar is hidden. Real handle drags and track clicks were tested separately (above).
9. **Keymap names** follow Emacs's scroll bar events: drag `<vertical-scroll-bar> <drag-mouse-1>` → `scroll-bar-drag`; track `<vertical-scroll-bar> <mouse-1>` → `scroll-bar-page`. The parts are `handle`, `above-handle` and `below-handle`.
10. **The Gerbil MCP balance and syntax tools from `agents/guides/gerbil.md` were not available here.** Every edit was checked by `gerbil build` and the test suites instead.

## Open points

- **Key cost at 20,000 px** (Performance). Decide whether per-line HTML reuse belongs in stage 2 or later.
- **Coarse-pointer indicator.** The `.scrolling` class and its CSS are in place, but headless Chrome reports a fine pointer, so it is untested. The owner's phone trial is still the acceptance step.
- **Splitting a view starts the new view at its first item** (`copy-view`), as on main. Emacs keeps the window start. Stage 2 (placements for commands) is the natural place to change it.
- **Finding nodes is a tree walk.** `token-item` for a node token and `posn-node` walk the tree when the node is not a direct child of the scroller's root. That is fine for the demos, but worth an index once deep trees scroll.
- **The demo's digit highlighter rescans the whole 50,000-line text per key.** That made the first measurement 148 ms per screen; it is a demo fixture, not the scroller.
- **Records** (ADR, `emacs-equivalents.md`, overview) are stage 3 and were not touched.

All Tuna processes and the proxy started for this work were stopped by PID: 9470, 9471, and the proxy on 127.0.0.2.
