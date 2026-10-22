# Steady scroll height: report

Branch `steady-height` in `/home/jay/Code/workbench-gerbil/tuna__steady-height`, two commits on `main` (`3144a0f`). Not merged, not pushed.

| Commit | Subject |
|---|---|
| `289a0d8` | scrolling: constant scroll height per view; 'first average by default |
| `82f1cdd` | scrolling: grid scroller with a sizer, not a wrapper; drag and stale checks |

- **The kernel is unchanged:** `git diff main -- tuna/` is empty.
- **The page code is unchanged:** `git diff main -- plugins/web/` is empty, so `tuna-scroll.ts` did not grow.
- **`make test` passes** under the memory cap: exit 0, last line `OK`, 51 Gerbil modules, 21/21 frontend tests, and the demo configuration loads.

## Result

Each windowed view now has a constant total scroll height, `T`. `T` is the item count times the view's per-item height. The per-item height defaults to `'first`.

In the browser, on desktop Chrome at 0 ms, `scrollHeight` **never changed** in the default mode. That held for 30-step thumb-drag emulations on `*long*` and `*rows*`, at 1280×700 and 393×700, sampled after every move, on every animation frame, and after 2 s of rest. It also held in the end zone.

`'measured` still changes it. When a drag outruns the drawn run, it changes 9 to 13 times per 30 moves.

### One deviation from the approved design, approved by the supervisor during the run

The flex-column **wrapper** broke Chrome's scroll anchoring. Measured with 24 scroll-bar jumps, comparing the server's scroll state with what the page shows:

| Build | Jumps left stale | Size of the error |
|---|---|---|
| `main` | 0 of 24 | — |
| Wrapper, `'first` | 10 of 24 | 12–61 px |
| Wrapper, `'measured` | 4 of 24 | — |

**Cause.** When a jump lands in a spacer, the view is blank. The spacers are excluded from anchoring, so the partially visible wrapper is Chrome's only anchor candidate. Chrome selects it and keeps it until the user scrolls. The wrapper's top never moves, so the following screens shifted the drawn items under the view without compensation. Traces show `scrollTop` unchanged while 16 lines were added above with a net +41 px.

**What replaced it.** There is no wrapper.
- The scroller (`article.buffer`) is itself a CSS grid. The scroller is never an anchor candidate.
- The grid has two columns: `minmax(0, 1fr)` and `0`.
- The rows are `auto auto 1fr`:
  - the spacer above is in row 1, with `min-block-size` equal to its items × the per-item height;
  - the root run is in row 2;
  - the spacer below is in row 3 and fills it.
- The server renders an empty `div.scroll-sizer`. It is `aria-hidden`, has `overflow-anchor: none` and `pointer-events: none`, and sits in the zero-width column spanning every row. Its height is `T`, so the `1fr` row takes `T − top − run`.
- **At the end of the buffer** (no spacer below), the rows are `1fr auto`. The spacer above has `min-block-size: 0` and takes what the run leaves. So `T` holds whether the run is shorter or longer than its share. The total grows past `T` only if the drawn run alone is taller than `T`.
- **The scroller is a grid with or without spacers.** A version that became a grid only once a sizer appeared lost the anchor on the first-spacers screen, because the display change rebuilt the run's boxes. That showed as a restart landing about 380 lines off.

**Views that are not windowed are unaffected.** Minibuffer, echo area, `*welcome*`, the sidebar, `*Help*`, the `M-x` completion list and a short `*scratch*` render identically. I compared every box rect and the scroll size of every non-windowed buffer, with the grid and with `display: block` forced. In all five states there were 0 differences. The minibuffer and echo-area selectors (`.buffer > .minibuffer`, `.buffer:has(> .echo-area)`) are unchanged from `main`.

The supervisor approved the grid with the sizer, on condition that the sizer is server-rendered, `aria-hidden`, takes no width and no pointer events, is not an anchor, and causes no side effects. I verified each condition.

## Changes by module

| Module | Change | Contracts imported | Services |
|---|---|---|---|
| `plugins/renderer/plugin.ss` | New helpers `items-pixels` and `scroll-sizer`.<br>The spacer above keeps `--spacer-block-size`; the spacer below has no style.<br>When there are spacers, the scroller ends with `div.scroll-sizer` (`aria-hidden`, `--scroll-sizer-block-size: <count × average>px`).<br>`render-view` computes the spacers once and passes them to the sizer.<br>Doc comments updated. | stylesheets, keys (subset), settings, renderer, buffers, layout (unchanged) | provides renderer; requires buffers, layout, settings; optional input (unchanged) |
| `plugins/renderer/rules.css` | `.buffer` is a grid (real specificity) with the row and area placement described above.<br>The end-zone rules use `:has()`.<br>The sizer rule.<br>`.spacer` uses `min-block-size` instead of `block-size`.<br>`.scroll-sizer` is added to the published styling-surface list. | — | — |
| `plugins/scrolling/plugin.ss` | `spacer-item-height` defaults to `'first`.<br>The setting's comment and documentation say `'measured` changes the scroll height and drops drag movement on Chrome for macOS.<br>The header comment is updated.<br>A misplaced comment above the setting was moved back to `scroll-moves-point`.<br>Counting across a spacer, reports, placements and the `'first` and `'measured` rules are unchanged. | commands, keys, settings, buffers, layout (unchanged) | requires commands, input, buffers, layout, settings (unchanged) |
| `plugins/minibuffer/rules.css`, `plugins/echo-area/rules.css` | Net unchanged from `main`. The first commit changed them for the wrapper, and the second reverted that. | — | — |
| `agents/adr/0015-scroll-state.md` | Status: amended 2026-10-22.<br>New bullet, **Constant total scroll height**: the Chromium cause (`cc/input/scrollbar_controller.cc`, `ScrollbarController::HandlePointerMove`), the grid and sizer, what still changes `T`, an edit during a drag, why there is no wrapper, and why the scroller is always a grid.<br>The average rule now names `'first` as the default.<br>The placement and consequences bullets are updated. | — | — |
| `docs/overview.md` | Scrolling paragraph: one sentence on the fixed total height and why. | — | — |

The buffers contract is unchanged: the view's average was already there.

## Tests

| Test | What it covers |
|---|---|
| `tests/integration/html-renderer-test.ss` (updated) | No spacers and no `scroll-sizer` before measurement.<br>Order: spacer above (`--spacer-block-size: 504205px`), first and last drawn line, spacer below with no style (`data-spacer="below" data-on-intersect`), then `class="scroll-sizer" aria-hidden="true" style="--scroll-sizer-block-size: 1012500px"`. That is 50,000 × 20.25.<br>No `--spacer-block-size: 500175px` (the spacer below has no fixed height).<br>At the end of the buffer: a spacer above, none below, and the sizer still 1,012,500 px. |
| `plugins/scrolling/tests/integration/scrolling-test.ss` (new case) | "by default the average item height is measured on the first report, then kept": 20 px after the first report, kept after an ordinary report, a spacer report with drawn items in view (count `[997 10.]`) and a blank spacer report below (count `[2051 0.]`); forgotten when the view shows another buffer. |
| `plugins/scrolling/tests/integration/scrolling-test.ss` (existing case) | The `'measured` case now sets `spacer-item-height 'measured` on the buffer and keeps its old expectations. |
| `plugins/scrolling/tests/support/drag-height-check.js` (new browser check) | Thumb-drag emulation: 4 drags of 30 moves, 50 ms apart:<br>- down from 0, 0.4 and 0.7 by 1/100 of the range;<br>- up from 0.9 by 2.5 view heights, so each move lands in the spacer above with drawn items in view.<br>Counts `scrollHeight` changes per move, per frame, and after rest. Result in `window.__drag`. |
| `plugins/scrolling/tests/support/stale-check.js` (new browser check; the supervisor asked for it) | 24 scroll-bar jumps, 2.5 s apart. After each, it compares the placement marker's item and offset with where the page shows that item. It also records each `scrollHeight`. Result in `window.__stale`. |

**Not confirmed by reverting.** Both new Gerbil expectations would fail on the old code, by construction:
- `main`'s default `'measured` would give 25 after the spacer report;
- `main` emits no sizer and gives the spacer below a fixed height.

I did not revert the code to confirm this.

## Browser results

**Setup:**
- Headless desktop Chrome through `agent_browser`.
- `.gerbil/bin/tuna --port 9470 --config demo/init.ss` with private `XDG_*` directories.
- `'measured` ran on port 9471 with a temporary copy of the demo configuration that set the setting. That copy is deleted.
- The check scripts were served from a loopback CORS server on 127.0.0.1:9479.
- All runs were at 0 ms round trip.
- All numbers below are from the final commit unless noted.

### `scrollHeight` changes during a 30-move thumb drag

Each cell shows (changes after moves + changes on frames) for the four drags: from 0, from 0.4, from 0.7 (into the end zone), and up from 0.9.

| Mode | Buffer, width | From 0 | From 0.4 | From 0.7 | Up from 0.9 | Range seen |
|---|---|---|---|---|---|---|
| `'first` (default) | `*long*` 1280 | 0 | 0 | 0 | 0 | 1,257,230 only |
| `'first` (default) | `*rows*` 1280 | 0 | 0 | 0 | 0 | 306,484 only |
| `'first` (default) | `*long*` 393 | 0 | 0 | 0 | 0 | 4,122,211 only |
| `'first` (default) | `*rows*` 393 | 0 | 0 | 0 | 0 | 306,484 only |
| `'measured` | `*long*` 1280 | 0 | 0 | 0 | **13 + 13** | 1,187,516 – 1,318,233 |
| `'measured` | `*rows*` 1280 | 0 | 0 | 0 | **9 + 9** | 306,484 – 308,695 |
| `'measured` | `*long*` 393 | 0 | 0 | 0 | **12 + 12** | 3,755,830 – 4,418,621 |
| `'measured` | `*rows*` 393 | 0 | 0 | 0 | **9 + 9** | 306,484 – 308,695 |

**Why `'measured` shows 0 on the downward drags.** Steps of 1/100 land with nothing drawn in view, and `'measured` never re-measures then. So `T` changes only when a report from a spacer has drawn items in view.

**For comparison, on `main`** (from the task statement): 28 of 30 moves changed the total in every mode.

**An earlier variant had a small end-zone change.** With the spacer above only allowed to grow at the end, `*rows*` showed one +4 px change entering the end zone. The final rule, where the spacer above takes what the run leaves, removed it.

### Stale-state check (24 jumps, default mode)

0 of 24 stale in all four configurations: `*long*` and `*rows*`, at 1280 and 393. Each scroller had a single `scrollHeight` throughout.

`main` on the same check: 0 of 24.

### `check.js` (default mode)

| Configuration | Blank frames / jumps (5 runs) | First item at top | Idle reports | Random jumps: stuck, relapses, median / worst ms | Double jump | Reports in total |
|---|---|---|---|---|---|---|
| 1280 `*long*` | 0 / 0 | yes | 0 / 0 | 0, 0, 17 / 19 | 29 ms | 1365 |
| 1280 `*rows*` | 0 / 0 | yes | 0 / 0 | 0, 0, 17 / 18 | 21 ms | 1491 |
| 393 `*long*` | 0 / 0 | yes | 0 / 0 | 0, 0, 17 / 18 | 11 ms | 1505 |
| 393 `*rows*` | 1 blank frame in the fling, otherwise 0; 0 jumps | yes | 0 / 0 | 0, 0, 17 / 85 | 21 ms | 1486 |

The tab-switch report had the same single blank frame in the 393 `*rows*` fling on `main`. Report traffic matches `main`: 1395–1498 in that report.

### Other checks

- **`views-check.js`, tabs:** 10 of 10 switches kept their place (views 79 and 537: lines 19,993 and 9,996, server state unchanged).
- **`views-check.js`, split:** 10 of 10: the watched half never moved.
- **Reload:** keeps place exactly. Line 27,486 at 56 px with `scrollTop` 691,126 before, and the same after.
- **Commands at 1280 on `*long*`:**
  - `C-v`: from 19,991–20,015 to 20,014 at the top, with 2 lines of context; then 20,033.
  - `M-v`: line 20,034 at the bottom.
  - `C-l` cycles: centre, then 20,033 at the top, then 20,033 at the bottom.
  - `M->`: line 50,000 at the bottom, 8 px of padding.
  - `M-<`: line 1, `scrollTop` 0.
  - `scrollHeight` stayed 1,257,230 throughout.
- **Edits:** `RET` raised `T` by one item (+25 px) and `Backspace` restored it, as designed.
- **Restart:** `*scratch*` with 1,201 lines, scrolled to the middle (line 585 at 14 px), Tuna stopped by PID and restarted on a copy of its state directory. Results were mixed:
  - Exact in 2 of 6 runs on the final build.
  - Off in 4 runs, landing at 568 or 570 instead of 584. The traced failing run shows the first screen arriving before the renderer's stylesheet applied (`display: block` and no `overflow: auto` on `.buffer`), so `tunaPlace` could not scroll. The page then reported line 384 at the top, and the scrolling plugin placed point (585) instead.
  - **`main` fails the same way**: a fresh browser on a restarted `main` gave exactly 570 @ 10 px.
  - So this is a pre-existing start-up race, not caused by this change. See open points.

## Open points

1. **Pre-existing restart race, seen on `main` too.** After a restart, the first screen can be applied before the renderer's stylesheet, so the placement does nothing. A possible fix: `tunaPlace` waits for the stylesheets, or the server owes another placement. That would be a separate decision.
2. **The `'first` average survives width changes.** A view measured at one width keeps that average after a resize, a phone rotation or `C-x 3`/`C-x 1`. `T` stays constant, which is the point, but the thumb-to-item mapping drifts. Near the end, the spacer above absorbs the difference. Possible follow-up for the owner: re-measure when the measured width changes (a resize is not a drag).
3. **A resize does not trigger a report.** After `C-x 1` widened a view, the page did not report until the next scroll, so the server's offset was stale (seen once as 16 px off, then corrected by the next scroll). This also applies to `main`, where only a scroll or a screen's `data-effect` runs `tunaScroll`.
4. **When `T` still changes:**
   - an edit that adds or removes items, which can drop one move of a drag in progress;
   - showing another buffer;
   - `'measured` re-measuring;
   - a drawn run taller than the whole sizer (only for barely windowed buffers whose last screens are far taller than the first).
5. **Session save error on restart with `*long*`.** Restarting with a view on `*long*`, a demo buffer whose contents are not saved, left only the minibuffer and echo area. The log then showed "Session slot layout failed to save: (Argument 1, pair) PAIR expected". Neither the layout plugin nor the session plugin changed on this branch. It is not investigated.
6. **Not exercised:**
   - real macOS Chrome thumb drags, which need the owner's machine (the cc rule was checked by emulation only);
   - iOS;
   - round trips of 80 ms.
7. **Not updated:** `agents/guides/html-css.md` still lists the older styling-surface subset. `.scroll-sizer` is recorded in `rules.css`'s header.

**Processes:**
- Every Tuna I started (ports 9470–9473) was stopped by exact PID.
- The CORS server on 9479 was stopped.
- The extra browser sessions (`shtrace`, `shtrace2`, `shmain`, `shmain2`, `shmain3`) were closed; the shared session was left on `about:blank`.
- The owner's ports 9450, 9452 and 9453 were not touched.
