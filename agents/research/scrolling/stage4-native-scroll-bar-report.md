# Native scroll bar (scrolling stage 4): report

Branch `native-bar` in `/home/jay/Code/workbench-gerbil/tuna__native-bar`, four commits on `6661a78`. Not merged, not pushed.

| Commit | Subject |
|---|---|
| `7c84758` | scrolling: native scroll bar over spacers sized by measured average |
| `c0731b8` | scrolling: count across a spacer by its drawn average; hold at the top |
| `53624d2` | scrolling: records for the native scroll bar (ADR 15, overview) |
| `1679f08` | scrolling: comment fixes |

**The kernel is unchanged:** `git diff 6661a78 --stat -- tuna/` is empty.

**`make test` passes** under the memory cap: exit 0, last line `OK`, 51 Gerbil modules OK, and 22 frontend tests pass with 0 failures.

## Result

- Each view's scroller now holds a spacer above the drawn run and a spacer below it. Each spacer is as high as its items would be at the view's measured average item height. So the browser's own scroll bar covers the whole buffer.
- Tuna's drawn scroll bar is gone, with its events, commands, browser code and tests.
- A spacer in view asks for a report (`data-on-intersect`).
- When a report lands in a spacer, Tuna counts items from the nearest drawn item. It counts by the average that spacer was drawn with.
- `drawn-screens` (default 2) replaces `drawn-above` and `drawn-below`.

**Browser results, desktop Chrome at 0 ms:**
- `*long*` and `*rows*`, at 1280×700 and 393×700: 0 blank frames, 0 jumps, the first item reachable, 0 reports while idle.
- 20 random scroll-bar jumps per configuration: none stuck, none blank again after content arrived, median 17 ms to content.
- The double jump shows content in 22–44 ms, with no further input.

**Browser results at 80 ms:**
- 0 jumps in all four configurations of the final run, and the first item reachable.
- Steady 9,000 px/s runs do show spacer frames (about 25–65 % of frames). Two view heights cannot cover 9,000 px/s at that round trip.
- 3,000 px/s shows 0 blank frames.
- Jumps reach content in 100–190 ms, never stuck.

**Other checks:**
- Reload keeps place exactly, and so does restart.
- `C-v`, `M-v`, `C-l`, `M-<` and `M->` work.

**Key cost** in `*long*` at drawn-screens 2: about 10–11 ms of server CPU and 25–36 KB per screen. At 20,000 px it was 34–39 ms and 185–376 KB.

## Changes by module

For each module: what changed, the contracts it imports, and the services it declares. No module gained an import or a service.

| Module | What changed | Imports contracts | Services |
|---|---|---|---|
| `plugins/buffers/contract.ss` | The `drawn-screens` setting (view heights, default 2) replaces `drawn-above` and `drawn-below`.<br>The view gains `average-item-height`: derived, never saved, `#f` until measured. It is read by `view-average-item-height` and written by `set-view-average-item-height!`.<br>`reset-view!` and `show-point!` forget it, through the internal `forget-measured!`, together with facts and counts.<br>`copy-view` copies it, so a split view's spacers are as high.<br>Documentation: the average is the only estimate, used only for spacer heights and counting across a spacer. | text-store, settings (unchanged); runtime `HashTable` | defines buffers-service |
| `plugins/keys/contract.ss` | `scroll-event` gains:<br>- `spacer` (`'above`, `'below` or `#f`);<br>- `spacer-distance` (px from the drawn item next to the spacer to the top edge);<br>- `drawn-height` (px from the first drawn item's top to the last one's bottom).<br>`px-above` and `px-below` now count drawn items only.<br>Deleted: `scroll-bar-event`, `scroll-bar-event-keys` and their documentation. | buffers (`node` only, unchanged) | — |
| `plugins/keys/plugin.ss` | `resolve-scroll!` handles only scroll reports, as special events. The scroll-bar dispatch is gone. | keys, commands, settings, buffers subset (unchanged) | provides input; requires commands; optional settings, buffers (unchanged) |
| `plugins/renderer/plugin.ss` | Draws `div.spacer` siblings around the root node's run inside the scroller. Each has `data-spacer="above"` or `"below"`, `aria-hidden`, a stable id, and `style="--spacer-block-size: Npx"` (items × average, rounded). Each also carries `data-on-intersect="@tunaScroll('spacer', FIRST, LAST)"`. The arguments are the run's item indexes, so a new run re-observes.<br>No spacers before the view has an average.<br>`data-drawn-screens` (for the view's buffer) replaces the two px attributes.<br>Deleted: `scroll-bar`, `percent-of`, `setting-pixels`. | stylesheets, keys subset, settings, renderer, buffers, layout (unchanged) | provides renderer; requires buffers, layout, settings; optional input (unchanged) |
| `plugins/renderer/rules.css`, `tokens.css` | The native scroll bar is back: the `scrollbar-width: none` and `::-webkit-scrollbar` rules are removed.<br>`.buffer > .spacer { margin-block: 0; overflow-anchor: none }` uses real specificity, so a spacer is never the scroll anchor.<br>`:where(.spacer)` has a faint line pattern, from the new token `--spacer-line`.<br>All scroll-bar rules and tokens are deleted. | — | — |
| `plugins/scrolling/plugin.ss` | See [the scrolling plugin](#the-scrolling-plugin) below. | commands, keys, settings, buffers, layout (unchanged) | requires commands, input, buffers, layout, settings (unchanged) |
| `plugins/web/plugin.ss` | Strict parsing of the new fields:<br>- `spacer` must be present: `null`, `"above"` or `"below"`;<br>- a spacer requires a non-null `top`;<br>- `spacerDistance`, `drawnHeight`, `above` and `below` must be non-negative pixel numbers no larger than 10^9.<br>Deleted: scroll-bar parsing, `scroll-bar-parts`, and the scroll-bar names in the keys import. `scroller-posn` lost its area argument. | keys subset (fewer names), renderer, stylesheets | provides display; optional renderer (unchanged) |
| `plugins/web/frontend/tuna-scroll.ts` (+ bundle `web/tuna-input.js`) | See [the page](#the-page-tuna-scrollts) below. | — | — |
| `plugins/web/frontend/tuna-scroll-bar.ts` | Deleted. | — | — |
| `plugins/web/frontend/input-sender.ts`, `tuna-input.ts`, `Makefile` | `send` no longer returns a promise; only the scroll bar used it. The bundle and the Makefile no longer list the scroll bar. | — | — |
| `tests/support/theme-terminal/renderer.css` | Scroll-bar tokens replaced by `--spacer-line`. | — | — |
| `plugins/layout/tests/unit/tree-test.ss` | The view constructor takes the new slot. | — | — |

### The scrolling plugin

**`view-scrolled!`:**
- If the report names a spacer, it counts across it with `item-across-spacer`:
  - It counts from the named edge item, by the average the spacer was drawn with (the view's current average).
  - Above the drawn items it rounds up; below them it rounds down. The rest becomes the offset.
  - Past the first or last item, it stops there and keeps the rest as the offset: negative above item 1, which is exactly the buffer padding at `scrollTop` 0.
- The counted item becomes the scroll state through `set-view-scroll!`, with the same placement number and an exact offset.
- **Average:** it is set from the report (drawn height over drawn items) on the view's first report and on spacer reports, after counting. Other reports leave it.
- **Counts:** the px targets are drawn-screens × the measured view height.
- **New `to-the-end`:** near an end, it draws every item to that end instead of a spacer shorter than the target.
- **Deleted:** `scroll-bar-drag`, `scroll-bar-page`, `page!`, `place-at-fraction!`, `scroll-bar-target` and their keymap entries.

### The page (`tuna-scroll.ts`)

**`tunaScroll`:**
- It finds its scroller with `closest("[data-scroll-root]")`, so it also works when called from a spacer.
- Reason `'spacer'` (like `'rest'`) always reports, unless a report is in flight. A spacer report that is dropped is not owed.
- The px target is drawn-screens × `clientHeight`.
- `above` and `below` are measured from the drawn items.

**Spacer detection.** The top edge is in a spacer when:
- the first drawn item is more than 0.5 px below the edge and there is a spacer above; or
- the edge is past the last item's bottom and there is a spacer below.

Then:
- `top` names that edge item, and `spacerDistance` is the distance to it.
- `lastVisible` is `null` unless an item is wholly in view.
- `drawnHeight` is always sent.

**What a report holds (`held`).** Each report holds the item it named.
- When the report came from a spacer with nothing drawn in view, it also remembers the marker's target and offset at that moment.
- **After the next screen:**
  - If nothing was drawn in view, the view has not moved, and the marker now names another item: that counted item is put at the top at its offset.
  - Otherwise, the reported item is put back where it was, if the view has not moved since the report or is at `scrollTop` 0.
  - At `scrollTop` 0 the item goes where the scrolling since the report took it.
- **`tunaPlace`** no longer calls into the scroll bar.

### Records

| File | Change |
|---|---|
| `agents/adr/0015-scroll-state.md` | Status: amended 2026-10-21. "Nothing is guessed" became "Positions are always measured", with the spacer estimate, the owner's decision and drawn-screens. New bullet: a report from a spacer. The drawn scroll bar bullet became the browser's scroll bar plus the top-of-scroller correction. Placement, consequences and alternatives updated, including the drawn scroll bar as a replaced alternative, and spacers adopted for sizes only. |
| `agents/adr/README.md` | Row 15 updated. |
| `docs/briefs/2026-10-scroll-state.md` | Dated note at the top: superseded in part, native scroll bar. |
| `docs/overview.md` | Status line and Scrolling section updated; glossary gains **Spacer**. |
| `docs/emacs-equivalents.md` | The scroll-bar row is now the browser's own scroll bar. The item-counting divergence is replaced by a pixel-and-average divergence with no scroll-bar events. |
| `docs/diagrams/scroller-items.d2` / `.svg` | Spacers sized by the measured average; the native scroll bar; a far jump answered by counting. Rendered with d2 0.7.1 (ELK) and checked visually in Chrome. |
| `docs/diagrams/scroll-report-and-placement.d2` / `.svg` | Step 3's px numbers fitted to drawn-screens (700 px above, 2,600 below). Re-rendered and checked. Outside the task's file list; see Deviations. |

## Tests

| Test | What it covers |
|---|---|
| `plugins/scrolling/tests/integration/scrolling-test.ss` | Counts grow toward two view heights by density; `drawn-screens` 1 halves the target.<br>Near an end, everything is drawn (`to-the-end`, unit and through a report).<br>Spacer report above: line 1,000, 450 px, 20 px each gives line 977 at 10 px. The placement keeps its number with an exact offset; drawn counts become [75 112].<br>Spacer report below: line 2,000, 455 px gives line 2,023 at 15 px.<br>Clamping: line 1 at −4,820 px and line 5,000 at +4,820 px.<br>`item-across-spacer` unit checks: exact steps, remainders, both clamps.<br>The average is measured on the first report, kept on an ordinary report (30 px measured, 20 kept), and on a spacer report counted by the drawn 20 then updated to 25; showing another buffer forgets it.<br>Deleted: the three scroll-bar tests. |
| `tests/integration/html-renderer-test.ss` | No spacers before measurement; `data-drawn-screens="2."`.<br>Spacers around the run at 20.25 px each: 504,205 and 500,175 px, in order above-run-below, with `@tunaScroll('spacer', 24899, 25299)`.<br>No spacer below at the end; no `scroll-bar` markup. |
| `tests/integration/scrolling-commands-test.ss` | A split copies the average. The report constructor gains the new fields. |
| `plugins/web/tests/integration/web-test.ss` | Valid reports: no spacer, and a spacer below with its distance (`'below` 1234.5, `lastVisible` #f).<br>13 new malformed variants: bad or missing `spacer`, negative, string, null or missing `spacerDistance`, negative, huge or missing `drawnHeight`, negative `above` and `below`.<br>A spacer with a null `top` is dropped and does not hold up later items.<br>Deleted: the scroll-bar item tests. |
| `plugins/web/tests/unit/input.test.mjs` | The harness no longer has `tunaScrollBar`.<br>The `drawn-screens` trigger band.<br>A spacer intersect reports; it is not sent while a report is in flight, and not owed.<br>The spacer report body above and below (edge item, distance, before/after, `drawnHeight`).<br>After a blank spacer report: the counted item goes to the top; a moving view is left alone; an early screen (marker unchanged) changes nothing and reports again; an item in view is held.<br>At `scrollTop` 0 the reported item goes where the scrolling took it.<br>Deleted: the two scroll-bar tests. |
| `plugins/scrolling/tests/support/check.js` | Ported to the new DOM (it already used `data-item`).<br>A jump counts only for an item that should still be in view.<br>New phase: 20 seeded random native scroll-bar jumps (`scrollTop` set to random fractions of `scrollHeight`). Each must show drawn items within 1.5 s and stay non-blank for 0.5 s.<br>New phase: the double jump (0.2 then 0.85 of the range, 5 ms apart, then nothing; content within 3 s).<br>Idle reports measured before and after the jumps. |

**Commands**, all under `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 1800 …`:
- `make deps`;
- `make`;
- `gerbil build`, repeatedly;
- focused `gerbil test ./plugins/scrolling/... ./plugins/web/... ./tests/integration/html-renderer-test.ss ./tests/integration/scrolling-commands-test.ss ./tests/integration/session-restart-test.ss`;
- `make test-frontend`;
- `make test`, three full runs. The final run exited 0 with `OK` and 22/22 frontend tests.

## Browser numbers

**Setup:**
- Headless desktop Chrome through `agent_browser`.
- `.gerbil/bin/tuna --port 9490 --config demo/init.ss`, with private `XDG_*` directories under `/tmp/nb-xdg-PORT`.
- The 80 ms round trip came from `phone-proxy.py 127.0.0.2 9490 40`.
- `check.js` was served to the page from a loopback CORS file server on 127.0.0.2:9499.
- Each configuration: fresh page load, `C-c g` or `C-c G`, `scrollTop` 0, then the check.
- Runs are 300/200/600/300/300 frames: down 9,000 px/s, a decaying 24,000 px/s fling, up 9,000 px/s, a fling to the top, then down 3,000 px/s.

**Final code, at 0 ms.** All five runs had 0 blank frames and 0 jumps unless the row says otherwise.

| Configuration | First item at top | Idle reports, before / after jumps | Random jumps: stuck, relapses, median / worst ms | Double jump, ms |
|---|---|---|---|---|
| 1280×700 `*long*` | yes | 0 / 0 | 0, 0, 17 / 22 (rerun 17 / 101) | 31 |
| 1280×700 `*rows*` | yes | 0 / 0 | 0, 0, 17 / 86 | 24 |
| 393×700 `*long*` | yes | 0 / 0 | 0, 0, 17 / 18 | 26 |
| 393×700 `*rows*` | yes | 0 / 0 | 0, 0, 17 / 85 | 24 |

**Variance at 0 ms:** one of three 1280 `*long*` runs on the final code had 2 single blank frames in "up 9,000 px/s"; the other two had 0.

**Final code, at 80 ms.** Blank frames are counted over 300 / 200 / 600 frames for the three fast runs.

| Configuration | Blank: down 9,000 / fling / up 9,000 | Blank: up fling, down 3,000 | Jumps | First item at top | Idle reports | Random jumps: stuck, median / worst ms | Double jump, ms |
|---|---|---|---|---|---|---|---|
| 1280×700 `*long*` | 152 / 47 / 148 | 0, 0 | 0 | yes | 0 / 0 | 0, 103 / 188 | 195 |
| 1280×700 `*rows*` | 124 / 22 / 178 | 0, 0 | 0 | yes | 0 / 0 | 0, 100 / 134 | 178 |
| 393×700 `*long*` | 69 / 14 / 173 | 0, 0 | 0 | yes | 0 / 0 | 0, 100 / 184 | 179 |
| 393×700 `*rows*` | 158 / 31 / 198 | 0, 0 | 0 | yes | 0 / 0 | 0, 100 / 167 | 181 |

At 80 ms, a steady 9,000 px/s outruns two view heights (about 1,300 px at 637 px). The view then shows spacer lines until the next screen. Neither the "0 blank frames in steady runs" target nor the old 20,000 px design has this problem; see Open points.

**Reload:**

| Buffer | Before | After |
|---|---|---|
| `*long*`, scrolled to 0.4 of the range plus a wheel | line 20,049, 17 px, `scrollTop` 507,277 | identical |
| `*rows*`, at 0.6 | Row 6041, 23 px, `scrollTop` 185,545 | identical |

Line 20,049 at 0.4 and Row 6041 at 0.6 show that the native thumb's position matches the content.

**Restart.** `*scratch*` with 401 lines was scrolled to line 202, 17 px. The saved view data was `(74 202 top 17.)`. After stopping Tuna by PID and restarting with the same state directory: line 202, 17 px, `scrollTop` 3,787, point on line 202.

**Scroll commands, in `*long*` at 1280×700:**
- `C-v`: 20,058–20,085 became 20,084–20,107, then 20,106–20,130. Two lines of overlap.
- `M-v`: 20,107 at the bottom.
- `C-l` ×3 on line 20,106: centre (20,095–20,118), then top, then bottom.
- `M->`: 49,971–50,000, with line 50,000 at the bottom.
- `M-<`: line 1 at the top, `scrollTop` 0.

**Native scroll bar:** headless Chrome draws overlay scroll bars that take no width (`offsetWidth` = `clientWidth`). So no real thumb drag was possible. The random-jump and double-jump phases set `scrollTop` the way a thumb drag does.

**Screenshots:**
- `native-bar-spacer.png`: the spacer's faint lines while the view sits in a spacer, from a debugging run.
- `native-bar-long.png`: `*long*` at the top.

## Performance: a key in `*long*`, drawn-screens 2

**Method:**
- The stage 1 method and listener: `stage1-measure-listen.py PORT PID 11`.
- Configuration `scratch/tuna-scrolling/native-bar-measure/init.ss`: the starter plugins plus the long-buffer demo, without the digit highlighter.
- 1280×700, 30 `b` keys 300 ms apart, dispatched as keydown events in the page.

| View | Items drawn | Server CPU per screen | Bytes per screen |
|---|---|---|---|
| at line 1 | 106 | 10 ms (idle 0) | 25.3 KB |
| at line ~25,003 (point there) | 149 | about 11 ms raw: 0.24 s for 21 screens | 35.6 KB |

The idle sample in the middle run was 43–53 ms/s, so "minus idle" is meaningless there. The cause: the page was idle (0 posts), but the server redisplayed about every 1.5 s after the edits. That is presumably the session autosave of the edited buffer, not scrolling.

Stage 1, at 20,000 px each way, measured 34–39 ms and 185–376 KB.

## Deviations and why

1. **A spacer report keeps the placement number** (`set-view-scroll!`) instead of making a new placement. The view's placement still names the counted item with its exact offset, and the page puts it at the top, but only when nothing drawn was in view and the view has not moved since the report.
   - A new placement number would make `tunaPlace` write `scrollTop` unconditionally, throwing the user back over whatever they scrolled during the round trip.
   - It would also interrupt a fling or a thumb drag.
   - When the view moved on, its next report measures where it is: measurement wins.
2. **Counting uses the average the spacer was drawn with, not the one the report measures.** Counting with the new average sent drags to the very top to item ~2,000 instead of item 1 (observed). The newly measured average is kept afterwards for the next spacers.
3. **Clamped counts keep the remainder as the offset**, negative above item 1. The task said clamp to the first or last item. Keeping the remainder makes the top of the spacer exactly `scrollTop` 0 (offset −8 px, the buffer padding), so "first item at top" holds after flings and jumps.
4. **No spacers until the view's first report.** The task allowed "the first screen's measurement or 24 px". This keeps the estimate always measured.
5. **The average is updated on the first report and on spacer reports**, as the approved demo did. It is not updated on every report: that would swing deep spacers by thousands of px.
6. **`to-the-end`: no short spacer near either end.** Without it, a fast scroll reaching the top at 80 ms hopped 25–129 px. A short spacer above was replaced by shorter real items at `scrollTop` 0, where the scroll range cannot absorb it. Neither the browser's anchoring nor the page can hold the view still there. This only changes the fetching step.
7. **The Chrome near-top correction is still needed, and was re-measured and narrowed.**
   - Chrome anchors at every `scrollTop` except exactly 0. This contradicts stage 1's "1–20 px": inserting 100 px above at 0 moved the item by 100 px; at 5, 10, 20, 30, 40, 60, 100 and 200 px it adjusted.
   - With spacers, Chrome anchors fine deep in the scroller even with the first drawn item in view.
   - So the hold stays, generalized: the reported item goes back where it was if the view has not moved, or, at `scrollTop` 0, where the scrolling since the report took it.
8. **`check.js` counts a jump only for an item that should still be in view after the scroll step.** With spacers the viewport can leave every drawn item; such an item then moves with the drawn content while only a spacer shows, which nobody sees.
9. **Spacers are siblings of the root node inside the scroller**, not inside the text node as in the demo. That keeps the scroller generic, knowing items and never nodes. The root's own padding counts as drawn height.
10. **`scroll-report-and-placement.d2` was edited too**, outside the listed files. Its step 3 showed 9,000 and 31,000 px drawn, contradicting the overview text. Only the numbers changed.
11. **The Gerbil MCP balance and syntax tools were not available**, as in stages 1 and 2. Every edit was checked by `gerbil build` and the suites.

## Open points

- **80 ms fast scrolling shows spacers.** At 9,000 px/s with drawn-screens 2, about half the frames sit in a spacer at an 80 ms round trip. At 0 ms, or at 3,000 px/s, there are none.
  - This is the owner's chosen trade-off: two screens felt right on his phone in the demo.
  - Raising `drawn-screens` buys margin at proportional key cost.
  - A direction-aware fetch (draw more ahead of the motion) would be a separate design.
- **iOS momentum.** The page writes `scrollTop` only:
  - after a blank spacer report, if the view has not moved;
  - for the hold, if the view has not moved or is at 0;
  - on placements.

  It never writes while the view moves away from 0. The owner's phone trial is still the acceptance step.
- **Element height limit.** Chrome caps an element at about 33.5 million px. That is enough for about 1.3 million items at 25 px; a larger buffer would need spacers capped or scaled.
- **An unexplained first run.** The very first check run of the session (fresh Tuna, page loaded before the viewport resize) stayed blank after entering the spacer. The server adopted the spacer reports (a reload showed the counted state), but the page kept showing the old run, while screens with new revisions were applied. It never recurred in about 30 later runs, including fresh restarts and the same sequence. Possibly a one-off morph or stream issue in that session; worth watching on the phone.
- **Headless Chrome has no visible scroll bar**, so real thumb dragging was not exercised; `scrollTop` jumps stand in.
- **Pre-existing, not touched:**
  - the restart bug for plugin-owned buffers (stage 2 open point);
  - the input-flood ordering issue;
  - there is no `C-x b` command yet, so the restart test used `*scratch*` in a fresh instance.
- `agents/plans/scrolling.md` and `agents/STATUS.md` are for the primary agent to update. They still name `drawn-above` and `drawn-below` and Tuna's scroll bar.

All processes started for this work were stopped by PID:
- Tuna on 9490, 9491 and 9492;
- `phone-proxy.py` on 127.0.0.2:9490;
- the CORS file server on 127.0.0.2:9499;
- the d2 preview on 127.0.0.1:9498.

The browser session was closed. The owner's 9450, 9451, 9420 and 9422 processes were not touched.
