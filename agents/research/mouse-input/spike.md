# Mouse input spike: report

2026-10-13. Throwaway prototype on branch `mouse-spike` (worktree `/home/jay/Code/workbench-gerbil/tuna__mouse-spike`), commit **`cb11bb0`** on top of `main` at `074ccd0`. Not for merge. The kernel (`tuna/kernel*`) is unchanged; nothing in this spike needed a kernel change, because the kernel treats input items as opaque and the keys plugin resolves them.

Short answer: the research's recommended design holds up in a real browser, with three corrections. (1) A drag preview must not live in attributes of morphed elements: the next screen wipes it. Put it in a `<style>` element in `<head>`, keyed by element id. (2) `preventDefault` on `mousedown` stops the browser's built-in drag from starting, so do not call it on draggable parts. (3) Clicking a bar view (the echo area) selects it, so a real design needs views that a click cannot select.

## What was built

| Piece | File | Owner |
|---|---|---|
| Pointer listener: clicks (on release), split-handle drag, tab drag | `frontend/tuna-pointer.ts` (bundled into `web/tuna-keyboard.js`) | input plugin (frontend) |
| Shared queue, client id and sequence counter | `frontend/tuna-keyboard.ts` (imports the pointer module; `Makefile` dependency) | input plugin (frontend) |
| Delegated `data-on:*__document="@tunaPointer()"` on `<html>`; `data-revision` on `#screen`; parsing and validation of pointer items | `tuna/plugins/web.ss` | web transport |
| `posn` and `pointer-event` structs; event names (`mouse-1`, `double-mouse-1`, `drag-mouse-1`, modifier prefixes); lookup keys `"<AREA> <EVENT>"` then `"<EVENT>"`, double/triple falling back to single | `tuna/services/keys.ss` | keys contract |
| `resolve!` and `arrival` take pointer events; `last-command-event` holds either kind | `tuna/plugins/keys.ss` | keys plugin |
| `data-part`, ids, `data-clickable`, `draggable` on tabs; split handles between weighted children of fit containers; commands `mouse-select-view`, `tab-select`, `mouse-drop-part` (resize, move tab), bound to `<mouse-1>`, `<tab> <mouse-1>`, `<handle> <drag-mouse-1>`, `<tab> <drag-mouse-1>` | `tuna/plugins/layout.ss` | layout plugin |
| `data-part` on views and status lines | `tuna/plugins/html-renderer.ss` | HTML renderer |
| Hover, pressed, handle, drop-target styles | `web/tuna.css` | (stylesheet) |
| Spike aids: `C-c n` new buffer, `C-c t` ticking message every 250 ms, `C-c z` close the tab after 1.5 s | `spike/tick.ss`, `spike/init.ss` (the starter plus this plugin) | spike only |

Item format as sent:

```json
{"version":1,"type":"pointer","clientId":"…","sequence":37,"revision":66,
 "kind":"click","button":0,"clicks":1,
 "modifiers":{"alt":false,"ctrl":false,"meta":false,"shift":false},
 "target":"tab:30","node":12}
{"…":"…","kind":"drop","from":"handle:220:0","fraction":0.3336}
{"…":"…","kind":"drop","from":"tab:226","to":"tab:219","edge":"before"}
```

Part strings are `AREA:ID…`: `tab:P` (P is the tab's child part), `view:V`, `status-line:V`, `handle:C:I` (container C, after child index I). The server validates each field, as it does for keydowns, and builds `(posn area ids node)`. Commands read the event through `last-command-event` and resolve the ids themselves.

## How it was run

Isolated: `XDG_STATE_HOME`, `XDG_CONFIG_HOME` and `XDG_RUNTIME_DIR` under `/tmp/tuna-spike/`, `gerbil env tuna --port 43723 --config spike/init.ss`; Chrome driven by agent-browser with real CDP mouse and key events, at a 1200×700 viewport. The page records a timeline in `window.tunaSpike.log` (items sent, screen revisions arriving, lost pointer capture). For frame-by-frame checks, a `requestAnimationFrame` sampler recorded the left child's width on each frame (about 16 ms apart).

A free finding: the session plugin's 2-second save timer redraws the whole screen every 2 s, even when nothing changed. So every test of a drag of more than 2 s also tested "a redraw arriving mid-drag".

## Answers

### 1. Clicking a tab and clicking a view

**Both work, and typing goes to the right view immediately after, in order.** Sequence with no waits between steps: `1 2`, click tab 1, `3 4`, click right view, `5 6`, click tab 2, `7 8`, all within about 370 ms. Result: right view `c1256`, tab 1 `a34`, tab 2 `b78`. Every key and click went to the view selected by the click before it.
- Before: `q1-before.png`; after: `q1-after-rapid.png` (tab 2 and right view); `q1-tab1.png` (tab 1 holds `a34`).
- Latency on loopback, from the item being sent to the next screen: a tab click 10 ms, a view click 16 ms.
- Focus stays on `<body>` after clicks (`document.activeElement` is `BODY`), so the document-level key listener keeps working. Tabs are `<li>`s, which cannot take focus, so nothing steals it.
- First screenshots `01-initial.png`, `02-three-buffers.png` were taken before a bug fix (below) and show a tab click that did nothing.

### 2. The split-border preview

**It is smooth, and it does not snap back on release.** The preview follows every `pointermove` on the next frame. After release the border stays put on every frame until the new screen arrives, 3–7 ms later (four drops measured: 3, 6, 6, 7 ms). The sampler shows no frame with the old width (`q2-after-release-fixed.png`, and the samples in the timing runs).
- Mid-drag: `q2-mid-drag.png`, `q3-held-still-after-morph-fixed.png` (handle highlighted, held still).
- This holds because the preview stays in place until the screen arrives. If the preview were removed on release, the old size would show for about one frame.
- No recording: headless screenshots plus the frame sampler gave exact per-frame data, which a recording would not improve on.

### 3. A redraw arriving mid-drag

**Pointer capture survives every morph. The first version's preview did not.**
- First version (preview as inline `--tuna-size` on the two children, and `data-dragging` on the handle): every morph reset both to the server's values. Holding the pointer still for 3 s, the border jumped back from 300 px to 400 px on the first frame after the screen arrived and stayed there until the pointer moved again. The handle highlight vanished too. Sampler: width 300 → 400 at the morph, back to 320 on the next move. Screenshot of the earlier state: `q3-held-still-after-morph.png`.
- Fixed version: the preview is a `<style id="tuna-drag-preview">` in `<head>` with `#ID { --tuna-size: X !important }` rules for the two children and the handle. The morph replaces only `#screen`, so it never touches the preview. Held still over 2 morphs: constant width, highlight kept. During a 20-second drag with 12 morphs, including two `tuna reload`s (a changed spike plugin), the width never changed between moves, capture was never lost, and `lostpointercapture` fired only on release (`q3-mid-drag-after-tuna-reload.png`).
- The element under capture keeps its identity across morphs because it has a stable id (`container-C-handle-I`); the morph rewrites its attributes in place.
- Built-in drag: a screen arrived between `dragstart` and `drop` (log: drag start 19917 ms, screen 19964 ms, drop 20008 ms) and the drop still completed and was applied (`q4-after-tab-to-tab.png`).

### 4. Tab drag with built-in drag and drop

**It works and the server applies it, but it is the weakest part of the spike, and part of it could not be observed headless.**
- **Blocker found and fixed:** calling `preventDefault()` on `mousedown` (done to keep focus and stop text selection on chrome) **stops Chrome from starting a built-in drag**. With it, no `dragstart` fired. Stopping only that handler made the drag start. The fix: skip `preventDefault` on draggable parts; `user-select: none` already prevents selection, and an `<li>` takes no focus.
- Drops: a tab onto another group's tab → inserted before it, selected (`q4-after-tab-to-tab.png`); a tab onto a view → a new fit container split at the edge, through the existing `remove-part`, `insert-link` and `replace-part` (`q4-after-drop-left-edge.png`). A tab group left with one tab stays a one-tab group (a tabbed container keeps one child).
- **Ghost image:** not visible. Chrome draws it outside the page, so headless screenshots do not contain it. The owner should look at it by hand in a real browser (drag a tab after `C-x 3`, `C-x t 2`). The default ghost is a translucent snapshot of the `<li>`; it can be replaced only with `setDragImage` and an image or element.
- **Drop feedback:** CSS can highlight drop targets. `html[data-dragging="tab"]` outlines every tab and view; `[data-drop-edge=…]` paints an accent bar on the chosen edge (`q4-manual-drag-over.png` shows the outlines during a real drag; `q4-drop-target-css.png` shows the edge bars with the attributes set by hand, because automated drags in headless Chrome either do not deliver ongoing `dragover` events or finish in one step). `<html>` is never morphed, so its attribute survives; the per-target `data-drop-edge` is wiped by a morph and re-set by the next `dragover`, which a real browser sends about every 50 ms.
- Problems:
  - Press, move off and release does not cancel a tab click: past the browser's drag threshold of a few pixels, it is a drag, and releasing over a view **moves the tab** (it happened by accident in the hover test: `q6-hover-status.png` shows the resulting split). Escape cancels a built-in drag; there is no "release elsewhere to cancel".
  - Drop targets include the bar's views (echo area, minibuffer), which should refuse; the server must mark what accepts drops (`data-drop-accepts`), not CSS.
  - If the dragged element were removed by a morph mid-drag, `dragend` would fire on a detached node and never reach the document listener, leaving `html[data-dragging]` stuck. Not reproduced; a real implementation needs a fallback reset (on the next `pointermove` with no buttons pressed, or on the next screen after `drop`).
  - In Chrome, `dragleave`'s `relatedTarget` is often null, so the highlight is cleared and re-set while moving over child elements. It is not visible because `dragover` re-sets it right away, but it is noisy.
  - No touch: built-in drag and drop does not start from touch in most mobile browsers (not tested here).

### 5. Stale clicks

**Handled by part identity; the message names the screen.** `C-c z` (wait 1.5 s, then close the current tab), then a click on that tab 300 ms later. The editor loop was busy, so the click queued behind the command; when it ran, part 226 no longer existed and the echo area said `Stale click: the tab is gone (clicked on screen 80)`; the screen was then at revision 83 (`q5-stale-click.png`; the moment of the click: `q5-before-close-arrives.png`). Nothing else happened, which is right.
- Because parts are named by stable id, not position, a click computed on an old screen acts on the part the user saw, or reports it gone; it never hits whatever moved into that spot. The revision was not needed to decide, only to explain.
- Weak spot: `handle:C:I` uses a child index, so inserting a child into C would make a stale drop resize the wrong pair. Name handles by the two children's ids (`handle:C:A:B`) instead.

### 6. Hover and pressed styles

**They look right and respond on the next frame, with no server involvement** (pure CSS on `[data-clickable]`).
- Tab hover and pressed are distinct: `z-q6b-tab-hover-vs-pressed.png` (top hover, bottom pressed; crops of `q6b-hover-tab.png`, `q6b-pressed-tab.png`). Status line hover: `z-q6b-hover-status.png`. Split handle: the 1 px rule turns accent blue with a `col-resize` cursor, and an invisible 9 px hit area (`::before`, inset −4 px) catches the pointer 3 px off the line (`q6c-hover-handle.png`; computed background `rgb(9,105,218)`).
- Two CSS mistakes found by looking, worth knowing for the design pass: a hover `background-color` on a status line *replaced* its bar color with a translucent one, which looked like no change (`q6-hover-status.png`); use an overlay (`background-image: linear-gradient(…)`). And `.container.fit > .split-handle` outranked `.split-handle:hover`, so the handle never highlighted (`q6-hover-handle.png`).

## Surprises

1. **`:std/list/list`'s `append-map` reverses each sublist.** `(append-map (lambda (x) [x (f x)]) '(a b))` returns `((f a) a (f b) b)` (source: `gerbil/src/std/list/list.ss`, `foldl cons` over each result). It made `"<mouse-1>"` match before `"<tab> <mouse-1>"`, so the first tab clicks did nothing. **Tuna already uses it**: `buffer-texts` in `tuna/services/buffers.ss` (line 648) walks children with `append-map`, so for any node with more than one text node beneath a child, the order is wrong. Worth a `TODO.md` entry and an upstream report; not fixed on `main` (out of scope).
2. The session's 2-second save timer redraws the whole screen every 2 s while idle, because every task is followed by a redisplay.
3. Clicking the echo area selects it (the global `<mouse-1>` selects any clicked view), and typing then says "No text to edit here" (`extra-click-echo-area.png`). Emacs refuses to select an inactive minibuffer window. The bar's views need either a keymap that ignores `<mouse-1>` or a "not selectable by click" mark.
4. While a command runs (here `C-c z` sleeping), no screens arrive at all, including timer redraws; clicks queue behind it in order, as keys do.
5. Headless Chrome cannot show the drag ghost and does not deliver ongoing `dragover` events for CDP mouse drags, so built-in drag and drop needs a manual check in a real browser.

## Recommendation for the real design

Confirmed by the spike:
- **One delegated listener on `<html>`, one queue.** Pointer items in the keyboard's queue with the same `clientId` and `sequence` keep keys and clicks in typed order with no extra machinery (question 1). Keep it.
- **Click on release** (the browser's `click` event): it worked, and it is what lets a press become a drag instead. Latency to the new screen was 10–16 ms on loopback, so release does not feel slow. Keep the recommendation.
- **Part kind as a prefix key** (`"<tab> <mouse-1>"`, then `"<mouse-1>"`) and commands reading `last-command-event`: small and enough. Emacs's double → single fallback is easy in the key list.
- **Pointer capture for split borders**: robust across morphs and reloads.
- **One `drop` item, facts not intents** (`from`, `to`, `edge`, `fraction`), resolved as `<AREA> <drag-mouse-1>` on `from`'s area: worked for both resize and tab moves without the browser naming a command. Keep the format, with `fraction` as the share of the two neighbours (what the browser can measure) and handle names by child ids.
- **Part identity plus revision for stale clicks**: identity decides, the revision explains.

Contradicted or corrected:
- **Do not keep previews in attributes of morphed elements** (the research suggested `data-style:--drag-x` or inline styles and "let the morph overwrite"). A redraw mid-drag, which happens every 2 s today, snaps the preview back. Put the preview in a `<head>` style element keyed by element ids, keep it after release until the next screen (or a 1 s timeout), then remove it. Datastar `_` signals bound with `data-style` on elements inside `#screen` would have the same problem, since the morph rewrites `style`; I did not test signals separately. A real implementation should clear the preview on the screen that reflects the drop, not just the next screen: an unrelated screen arriving between the drop and its processing would clear it early and show one stale frame (not seen here; drops took 3–7 ms).
- **`preventDefault` on `mousedown` for chrome** (research section 4) must exclude draggable parts; with `user-select: none` it may not be needed at all.
- **"A click never selects implicitly" plus a global `<mouse-1>` → select view** needs exceptions for views that must not take input (the bar).

Built-in drag and drop versus pointer events for tabs: **use built-in drag and drop for now, but expect to switch to pointer events.** It worked and survived a morph, and the ghost is free. But it has no "release elsewhere to cancel", no touch support, a ghost Tuna cannot style, fragile `dragleave`, and a stuck-state risk when its source element is removed. Pointer capture already works well for handles, and the same code could drive tab moves with a live, styled preview (a `<head>` style placing a ghost), so the two drags would share one mechanism. Decide after the owner has seen the built-in ghost in a real browser.

## What a real implementation must add

- Tests: parser tests for pointer items (bad part strings, missing fields, edge and fraction ranges); keys-plugin tests for lookup order, double → single fallback, unbound events ignored, prefix cancelled; layout tests for resize (clamping, stale handles, content-sized neighbours) and tab moves (into itself, locked parts, last tab, tabbed one-child rule); a frontend test like `tests/keyboard.test.mjs` for pointer items (the existing one still passes, since `tunaKeyboard` registers last). The spike breaks two `layout-test.ss` checks that count a fit container's children, because handles are now interleaved (`layout-test.ss:310`, `:407`); a real version should render handles so the tests can tell them from children (or update the tests).
- Node keymaps (ADR 8) so buttons inside buffers resolve from the clicked node upward; the spike sends `node` but nothing uses it.
- `data-clickable` driven by bindings (only where a non-global binding exists), and a keymap generation in the HTML-reuse key.
- Server-rendered drop acceptance (`data-drop-accepts`), excluding locked parts and the bar; views that a click must not select.
- `defcommand` event arguments (`interactive "e"`) instead of commands reading `last-command-event` and parsing ids themselves; `event-start`/`event-end`/`posn-*` accessors; a layout-owned resolver from `posn` to part, view and node.
- Handle part names by child ids; keyboard-operable handles (`role="separator"` with `aria-valuenow` and arrow keys) and real `<button>`s or `role` for clickables (accessibility).
- Preview cleanup tied to the screen that reflects the drop; fallback resets for stuck drag state; Escape to cancel a handle drag.
- An ADR for the pointer item, the part-string grammar and Emacs event names, and lines in `docs/emacs-equivalents.md` (`posn` shape, `"<tab> <mouse-1>"` for `[tab-line mouse-1]`).

Screenshots are in this directory; file names start with the question number (`q1`–`q6`, `extra-`; `z-` files are zoomed crops).
