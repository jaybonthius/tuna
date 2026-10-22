# Tab-switch scroll creep: root cause and fix

Branch `tab-scroll` in `/home/jay/Code/workbench-gerbil/tuna__tab-scroll`, one commit on `f391ec6`:
`a44d8d1 scrolling: page only measures and places; fix tab-switch creep`. Not merged, not pushed. The kernel is unchanged (`git diff f391ec6 -- tuna/` is empty). `make test` passes: exit 0, last line `OK`, 51 Gerbil modules, 21/21 frontend tests.

## Root cause

Two faults combined. The first one corrupted the scroll state. The second one, in Chrome, turned that corrupted state into the creep.

1. **Every view's report trigger listened to one page-wide signal.** Each scroller's `data-effect` read `$_tunaScrolls`, and every scroll on any scroller incremented it. On a tab switch, `tunaPlace` on the incoming scroller sends a synthetic `scroll` event. That ran the effect of the **outgoing** scroller too, while the morph was removing it. A detached element measures all zeros. The page therefore reported, for the outgoing view, "top edge in the spacer below, 0 px from the last drawn item, view 0 × 0 px".
   - The server adopted that report as a legitimate one.
   - It counted the scroll state as the item after the drawn run, about 50–130 lines further down.
   - Its wanted px came out as 0 (`drawn-screens` × height 0), so it set the drawn counts to 0 / 0, leaving one item drawn.
   - So the scroll state was per view as designed. It was corrupted by a report from a scroller that was no longer on the page.
2. **A one-item run is anchored as a whole by Chrome.** When that view was shown again, its run was a single item. That item was fully visible, so Chrome chose the run's container (the text node element) as the scroll anchor instead of the line. Chrome keeps an anchor until the user scrolls. So each later screen that drew items above held the **container's top** still. The view stayed glued to the first drawn item.
   - Each report then said "nothing drawn above" (`before 0`, `above 0`), so the server drew about 48 more items above.
   - The view moved up by those items on every screen, until it reached line 1.

### Evidence

- **Reproduction on the old code:** `views-check.js`, "tabs" mode, desktop Chrome, 1280×700. *long* was at 0.4 of its range, so line 19,992 was at the top.
  - Switch 1 showed line 19,896, then crept through 72 different top lines to 15,056 within 1.5 s.
  - By switch 6, the other view was at line 1. Its server state was `…1.0@0`.
  - 9 of the 10 switches failed.
- **The outgoing view's report.** The fetch log at a switch shows a report for the outgoing view 79: `spacer: "below"`, `spacerDistance 0`, `before 124`, `after 0`, `above 0`, `below 0`. That is exactly what `tunaScroll` computes when every rectangle is 0. In the same millisecond, the incoming view 563 was drawn with `n: 1` item. That one-item run came from its own corrupted report at the previous switch.
- **No page code moved the view.** I wrapped the `scrollTop` setter during the creep. It logged only `tunaPlace`'s single write. Every later movement came from Chrome.
- **What Chrome held still.** At every screen, the change in `scrollTop` equalled the change in the spacer above (for example 246,830 → 245,188 px, and `scrollTop` 246,838 → 245,196). So Chrome held the container's top, not the line.
- **Chrome reproduced without Tuna.** A plain scroller with a spacer above, a container, and a spacer below; each "screen" inserts 10 lines above and shrinks the spacer by the same 200 px:

  | Starting run | Results |
  |---|---|
  | 1 line | the view moves to the first drawn line each time (top line `N0-9`, `N1-9`, `N2-9`), and stays glued even once the container is taller than the view |
  | 40 lines | the line in view holds still (`L1000` three times) |

- **Double reports.** Reports came in pairs because the page-wide signal also re-ran the effects of the other scrollers, the minibuffer and the echo area. Any screen also restores every trigger.

## The fix, following the owner's direction

The page now does two things only:
1. measure and report, one report in flight;
2. apply each placement once.

Everything the deleted corrections did is either solved by removing the shared signal, or moved to the server.

### `plugins/web/frontend/tuna-scroll.ts`

The file went from 257 to 186 lines; 180 to 137 lines of code without comments and blank lines.

**Deleted:**
- `holdStill` and `putAtTop`;
- the `held` record and its `counted` sub-record (the item the server counted, compared with the marker);
- the near-top correction (at `scrollTop` 0, the reported item moved by the scroll since);
- the "put the counted item at the top after a blank spacer report" rule;
- `drawnItem` and `spacerOn`; their remaining uses are inlined as selectors.

**What remains:**
- **Per-scroller state** is the last placement applied and one `owed` flag. A report is owed in three cases:
  - after a placement, so the server learns what it shows;
  - after a scroll end that could not be sent while a report was in flight (unchanged);
  - **after a report from a spacer** (new, one line). The screen that answers such a report draws the counted item about where the spacer said it was. The item is off by how much the items drawn before it differ from the average, so the page reports what is really there. This replaces the client-side "put the counted item at the top".
- **The only `scrollTop` write is in `tunaPlace`.**

### `plugins/renderer/plugin.ss`

The scroller's triggers are now its own:
- `data-on:scroll="@tunaScroll('moved')"`;
- `data-effect="@tunaScroll('moved')"`, an effect reading no signal, so it runs only when a screen puts it back after a report removed it;
- `data-on:scrollend` (unchanged).

`data-signals__ifmissing` and the `$_tunaScrolls` counter are deleted. This is the fix for cause 1: a scroller that is being removed can no longer be triggered by another scroller.

| Contracts imported | Services |
|---|---|
| stylesheets, keys (subset), settings, renderer, buffers, layout (unchanged) | provides renderer; requires buffers, layout, settings; optional input (unchanged) |

### `plugins/scrolling/plugin.ss`

Under `spacer-item-height` = `'measured` (the default), the average item height is now taken from the view's first report and from **a report from a spacer with drawn items in view**. It is no longer taken from a spacer report with nothing drawn in view.

The new helper `drawn-in-view?` decides this:
- a spacer below is always blank;
- a spacer above is blank once its distance is at least the view's height.

Why this is needed once the client hold is gone:
- A new average moves everything below a spacer by (items × change). Deep in *long*, that is thousands of px for a 0.1 px change.
- With a drawn item in view, Chrome's anchoring absorbs this.
- Under a blank view, nothing holds the view, and the content lands elsewhere. That needs another spacer report, which could repeat. The old client hid this with `counted` and `putAtTop`.
- Counting still uses the average the spacer was drawn with.

The `'first` setting and numeric values of the setting are unchanged. The doc comment and the setting's description are updated.

| Contracts imported | Services |
|---|---|
| commands, keys, settings, buffers, layout (unchanged) | requires commands, input, buffers, layout, settings (unchanged) |

### `agents/adr/0015-scroll-state.md`

Amended (status line dated "later on 2026-10-21"):
- triggers belong to each scroller;
- a report is owed after a spacer report;
- the page writes no scroll position except to apply a placement;
- the rule for when the average changes;
- the description of a spacer report's answer.

I did not touch `agents/plans/` or `agents/STATUS.md`.

### Server-side checks the owner suggested

- **"Reports from a view not in the screen are ignored":** not added. Once the triggers belong to each scroller, no detached report occurs (0 in all runs). A report already in flight when the user switches tabs was measured on screen, so it is legitimate.
- **"A report measured before the newest placement is ignored":** already exists and is unchanged.
- **"Never leave `scrollTop` at exactly 0 above undrawn items":** already true through `to-the-end`. Near the start, every item is drawn rather than a spacer shorter than `drawn-screens` view heights. So at `scrollTop` 0 the view is either on drawn items with nothing undrawn above, or wholly inside a spacer, which is a blank spacer report counted to item 1. The "fling to the top" and "first item at the top" checks pass at 0 ms and at 80 ms without the near-top correction.

## What could not move off the client, and why

| What stays | Why it stays |
|---|---|
| The report-trigger thresholds (short or long on either side, compared with `drawn-screens` view heights) | Only the browser knows the drawn px. Reporting every scroll instead would send one report per round trip: about 60 screens a second at roughly 10 ms of server CPU each. |
| Spacer detection, and `lastVisible` | Only the browser knows where the edge is. |
| `tunaPlace`'s centre and bottom alignment | They need the item's measured height. |
| `owed` | Without it: a scroll end dropped while a report was in flight leaves the server's state stale. And after a blank jump, the server keeps the counted item while the view shows its neighbours. Measured: after 6 random jumps, the server's target and offset equal what is shown, every time (for example `18272@2` shown, `18272@2` on the server). |

## Tests added (failing before, passing after)

| Test | Before (old code) | After |
|---|---|---|
| `plugins/scrolling/tests/support/views-check.js` (new browser check; modes `tabs` and `split`) | tabs: 9 of 10 switches failed, crept to line 1 | 10 of 10 kept, in both modes |
| `input.test.mjs`: "only a placement moves the view: a screen that moves what is drawn leaves it where the browser has it" (replaces the two hold tests) | fails | passes |
| `input.test.mjs`: "after a report from a spacer, the page reports what the next screen drew there" (replaces the counted-item test) | fails | passes |
| `scrolling-test.ss`: blank spacer reports below and above count by the kept 25 px average and keep it (`[2041 0.]`, `[960 0.]`) | fails | passes |
| `html-renderer-test.ss`: the scroller's own `data-on:scroll` and `data-effect` triggers, and no `data-signals` | fails | passes |

The "before" results were confirmed by stashing the source changes and rebuilding.

The unit-test fake element now understands `[name="value"]` selectors.

## Browser results

**Setup:** headless Chrome, demo configuration, private `XDG_*` directories, Tuna on port 9461, and `check.js` and `views-check.js` served from 127.0.0.1:9469. The 80 ms round trip came from `phone-proxy.py 127.0.0.2 9461 40`.

**Tab switch, 10 switches:** every switch showed the remembered line in the first painted frame and kept it for 1.5 s, with the server state unchanged. View 79 showed 19,992 every time, and view 544 showed 9,995. This held at 0 ms and at 80 ms.

**Side by side (`C-x 3`):** *long* in both halves, at 0.4 and 0.2 of the range. I scrolled one half by a screen, 10 times, alternating halves. The other half never moved, and its server state was unchanged.

**`check.js` at 0 ms:**

| Configuration | Blank frames / jumps (5 runs) | First item at top | Idle reports | Random jumps: stuck, relapses, median / worst ms | Double jump | Reports in total |
|---|---|---|---|---|---|---|
| 1280 *long* | 0/0 in all | yes | 0 / 0 | 0, 0, 18 / 118 | 28 ms | 1395 |
| 1280 *rows* | 0/0 in all | yes | 0 / 0 | 0, 0, 17 / 19 | 22 ms | 1498 |
| 393 *long* | 0/0 in all | yes | 0 / 0 | 0, 0, 17 / 117 | 10 ms | 1453 |
| 393 *rows* | 1 blank frame in the fling, otherwise 0; 0 jumps | yes | 0 / 0 | 0, 0, 27 / 216 | 37 ms | 1395 |

For comparison, the old code on 1280 *long* had 1387 reports in total, so report traffic is unchanged.

**`check.js` at 80 ms:**

| Configuration | Blank frames (down 9,000 px/s / fling / up 9,000 px/s) | Other runs | Jumps | First item at top | Jumps: median / worst ms |
|---|---|---|---|---|---|
| 1280 *long* | 191 / 54 / 147 | 0, 0 | 0 | yes | 100 / 151 |
| 393 *rows*, first run | 193 / 33 / 258 | 0, 0 | 0 | yes | 100 / 145 |
| 393 *rows*, second run | 180 / 53 / 149 | 0, 0 | 0 | yes | 100 / 166 |

Stage 4 recorded 152 / 47 / 148 and 158 / 31 / 198. These blank frames are the expected spacer frames at 9,000 px/s, within run-to-run variance.

**Reload** keeps place exactly: line 19,994 at 8 px, `scrollTop` 502,654, before and after.

**Restart** keeps place exactly. I filled *scratch* with 300 lines, scrolled to the middle, stopped Tuna by PID and restarted it on the same state directory: line 136 at 8 px, `scrollTop` 2,562, before and after.

**Commands:**
- `C-v`: from 19,994–20,018 to 20,016–20,038, then 20,036–20,062, keeping 2 lines of context.
- `M-v`: line 20,036 at the bottom.
- `C-l` cycles centre, top (20,036 at the top), bottom (20,036 at the bottom).
- `M->`: line 50,000 at the bottom.
- `M-<`: line 1 at `scrollTop` 0, offset −8 px.

## Two browser tabs on one Tuna

Each tab gets its own stream with the same screens. Each view has one scroll state, so the tab that reported last wins.

**What happened** (with the new code):
1. Tab B opened at tab A's place, line 19,992.
2. Scrolling B by 3,000 px moved the server's state to 20,110.
3. Tab A, never touched, sent no reports. It drifted to 20,097, because the morph reused its line elements and Chrome's anchoring followed them.
4. After B jumped to 0.8 and then to 0.2, A followed within a few lines each time: 39,982, then 9,991 against the server's 9,995. No script wrote `scrollTop` in A; I checked this by wrapping the setter and tagging the elements.

**Assessment:**
- There was no ping-pong and no creep; idle traffic stayed at 0.
- The background tab shows roughly, not exactly, the place the server holds. It does not report this until it is scrolled or resized.
- This is the transport's one-tab assumption, not the tab-switch cause, so I fixed nothing here.

## Open points

- **The average rule needs the owner's confirmation.** The `'measured` setting's average now changes on the first report and on spacer reports with drawn items in view, instead of on every spacer report. This follows from removing the client hold. The owner added the setting on 2026-10-21, so it should be confirmed with him.
- **No guard against zero-size reports.** A scroller with zero height (not laid out) would still be adopted, and its counts collapse toward 0. That could recreate a short run and Chrome's container anchoring. No such report occurred once the triggers belonged to each scroller. A server rule such as "a 0 × 0 report measures nothing" would be a separate decision.
- **Where the counted item lands after a blank jump.** The item counted across a spacer appears about where it was counted, off by the difference between the drawn items before it and the average. The page then reports the truth, so the server is exact. The user sees the neighbourhood of the thumb position, not an exact item. This was always an estimate.
- **Not exercised:**
  - iOS momentum, which needs the owner's phone trial. The page now never writes `scrollTop` during momentum except through a placement.
  - Real scroll-bar thumb drags: headless Chrome has overlay scroll bars, so I set `scrollTop` instead.
- **Pre-existing behaviour seen while testing.** Keys sent before Tuna's editor loop is running are lost with "The editor loop is not running". This happened when a page reconnected to a restarted Tuna before start-up finished.

**Processes:** the Tuna instances I started on port 9461, `phone-proxy.py` on 127.0.0.2:9461 and the CORS file server on 9469 were all stopped by PID, and the browser session was closed. The owner's proxies on 9450, 9452 and 9453 were not touched.
