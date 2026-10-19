# Scrolling a view, and how the server learns layout facts

Research report, 2026-10-17. Read-only on every repository; the only files written are this report and a throwaway prototype in `agents/research/scrolling/proto/`. Labels: **Fact** (read in source/spec or measured), **Inference** (my reasoning), **Unverified** (not checked). Tuna checkout: `main` at `dbd014e`.

## Short answer

**Recommendation: native scroll container, server-side windowing, server-owned anchor (design B below).** It is the only candidate that can feel native on a phone, and it fits Tuna's rules. Pure backend scrolling (design A) is viable on a desktop on loopback, but on touch it is a show-stopper for "very smooth". A client-predicted hybrid (design C) ends up reimplementing native scrolling in JavaScript, and does it worse.

- **Who owns the scroll position.** The server owns each view's **scroll anchor**. That is Emacs's `window-start` plus `vscroll`, generalized to node trees: *(node id, a position inside that node or none, a pixel offset)*. The anchor is authoritative: it is saved with the session, used by commands (`C-v`, `recenter`, keeping point visible), and used to choose what to render. The browser owns only the **motion** between anchor reports: finger drag, momentum, rubber-banding and the scrollbar. Under ADR 7 that is presentation state.
- **What the server sends.** For each view, the blocks around the anchor plus an overscan margin, between two spacers sized from a per-view **height map**. Every redraw is still one fat morph. Tuna's existing per-node HTML reuse keeps the window cheap.
- **What the client reports, per view.** (1) Viewport size, from `ResizeObserver`. (2) The anchor: the first visible block and its pixel offset, plus the last visible block. This goes out when the visible range nears the edge of the rendered window (thresholds the server writes on the view, as hyperlith does), at `scrollend`, and after a server scroll request. (3) Measured heights of rendered blocks whose height differs from the estimate the server wrote on them.
- **How it is reported.** As numbered input items through the existing ordered `/commands` channel (`plugins/web/frontend/input-sender.ts`), not Datastar signals. A scroll must be ordered with keys and clicks, and Datastar posts *all* signals on every request (`agents/reference/datastar/docs.md:979`). Reports are coalesced per animation frame, and **at most one report per view waits for its screen**. While it waits, only the newest facts are kept.
- **Touch and momentum.** The browser's native physics, on its compositor thread, unchanged on every platform. The server only refills the window. The browser's **scroll anchoring** (`overflow-anchor`; Chrome 56, Firefox 66, Safari 27 from 2026-09-14) keeps the view still when spacers or newly measured blocks change size above the viewport.
- **Prototype evidence** (desktop Chrome, headless; section 4):
  - Native scrolling with server windowing showed **0 px of visible jump on every frame**, at 0, 30 and 80 ms of added one-way latency, with deliberately wrong height estimates.
  - With scroll anchoring turned off, the same runs jumped by up to **404 px** at 0 ms and **1,927 px** at 80 ms.
  - Pure backend scrolling missed smooth motion on **40%** of frames even on loopback, and on **91%** at 30 ms of added latency.

## Terms

- **View**: a leaf of the layout showing one buffer (Emacs's window). **Scroller**: the element that scrolls inside a view (today `.buffer`).
- **Block**: the unit the renderer windows and measures. An atomic node is one block. A text node's blocks are its logical lines (or groups of lines). Wrapping inside a block is the browser's business. "Line" is never the general unit.
- **Anchor**: the block at the top of the viewport plus a pixel offset into it. This is Emacs's `window-start` (a buffer position) plus `vscroll` (pixels).
- **Window (render window)**: the blocks the server actually renders, which are the visible ones plus **overscan** above and below. **Spacers** are empty elements sized to stand in for everything outside the window.
- **Height map**: per view, the measured or estimated height of every block, with prefix sums, so that pixels and blocks convert both ways.
- **Scroll anchoring**: the browser keeps the visible content still when content above it changes size, by adjusting the scroll offset ([CSS Scroll Anchoring](https://drafts.csswg.org/css-scroll-anchoring/)).
- **Momentum (fling)**: scrolling continues and decelerates after the finger lifts. **Compositor thread**: the browser thread that moves scrolled pixels independently of JavaScript.

## 1. What Tuna does today

**Fact:**
- Each view's `.buffer` is already a native scroller: `overflow: auto; overscroll-behavior: contain` (`plugins/renderer/rules.css:29-34`). Morphing keeps its scroll position because views and nodes have stable ids (`plugins/renderer/plugin.ss:12-13`). Nothing reports scroll or size to the server; the frontend sends only keys and clicks (`plugins/web/frontend/tuna-keyboard.ts`, `tuna-pointer.ts`).
- The renderer draws **every** line of a text node (`plugins/renderer/plugin.ss:125-150`). HTML reuse is keyed by node revision and view state (`:98-121`), so moving point or typing redraws the whole text node.
- Effect: in a 50,000-line text, a key cost 489 ms of server CPU and 3.35 MB on the wire (`agents/research/resource-audit-2026-10-15.md`, finding 1). Layout-state research measured about 2.5 ms to write viewport-sized output against about 32 ms (raw writes) to 250 ms (`write-sxml`) for 50k nodes (`agents/research/layout-state/README.md:17`).
- `view` holds point, focus node, revision and goal column. It has **no scroll state** (`plugins/buffers/contract.ss:181-187`).
- Screen pipeline:
  - The editor loop redisplays after pending input, and at least every 100 ms under sustained input (`tuna/kernel/loop.ss:156,385-410`).
  - `redisplay!` renders the whole screen **on the editor thread, every time** (`plugins/web/plugin.ss:116-129`).
  - Each stream's writer thread takes the newest screen and skips intermediate ones (`:134-150`, `:370-387`).
  - Sending is a blocking write plus flush to the socket (`.gerbil/pkg/git.cons.io/jay/gerbil-sse/sse.ss:40-51`). Backpressure therefore exists only at the TCP buffer. The server never knows whether the browser has applied a screen.
  - While idle, an unchanged screen is re-sent every ~2 s (resource audit, finding 2).
- ADR 7 already allows the browser "scroll within already-rendered content" as presentation state and requires layout-dependent commands to get facts from the client (`agents/adr/0007-rendering-and-transport.md`, "Layout belongs to the browser", "Presentation-only browser state"). The owner's 2026-10-13 note in `agents/STATUS.md` named hyperlith-style native scrolling with in-view rendering as "probably" right; the 2026-10-17 position prefers backend scrolling. This report weighs the two.

## 2. Prior art

### Emacs: the model for a server-owned position

**Fact** (Emacs checkout `541f693ca2e8`):
- A window's **start** is a marker: "The character after this position is the one that appears at the upper left corner of the window" (`doc/lispref/windows.texi:6024-6029`).
- "The display routines insist that the position of point be visible", and redisplay picks a new start when point is off screen (`:6112-6125`). `scroll-margin` and `scroll-conservatively` say how far redisplay scrolls (`:6383-6420`).
- **vscroll** is a pixel offset that raises the window contents for lines or images taller than the window (`:6548-6600`).
- `pixel-scroll-precision-mode` scrolls by pixels by setting `window-start` and then `vscroll` (`lisp/pixel-scroll.el:492-498`, `:501-549`).
- Emacs computes **momentum in Lisp**: a loop that scrolls, calls `redisplay`, and `sit-for`s 10 ms ticks over 1.75 s (`:761-822`, defaults `:155-176`).

**Inference:** Emacs's anchor model, (position, pixel offset) with "point stays visible", carries over to Tuna. Its momentum model (the editor drives every frame) works because Emacs's redisplay is local and incremental. In Tuna each such frame would cross the network and a full morph.

### hyperlith: native scroll plus server windowing (owner-cited)

**Fact** (`/home/jay/Code/hyperlith` at `34dbe2e`, `src/hyperlith/extras/ui/virtual_scroll.clj`):
- The scroller is native: `overflow: scroll; overscroll-behavior: contain; overflow-anchor: none; scroll-behavior: smooth` (`:224-231`).
- The window is a `transform: translate(...)` layer inside a full-size `contain: strict` box (`:232-253`).
- Scroll position goes into signals on every `scroll` event (`:9-11`). Size is posted on init and on a 100 ms-debounced window resize (`:5-7,117-121`).
- A self-removing `data-effect` posts `/scroll` only when the position leaves server-computed thresholds, with `retryMaxCount: Infinity`. The next morph re-adds the attribute (`:13-24`).
- The overscan default is 4,000 px of items, "as user scroll speed not visible items determines how much you need to buffer" (`:33-38`). Thresholds sit at half the overscan (`:55-64`).
- **Items have one fixed size** (`item-size`). That is why `overflow-anchor: none` and transforms are safe there.
- Usage: `examples/billion_cells/src/app/main.clj:236-253` (handlers store x/y and width/height per tab), `:459-477`.

**Inference:** The idea transfers to Tuna; the fixed-size assumption does not. With unknown heights Tuna needs a height map and must leave scroll anchoring **on**. Scroll anchoring is suppressed by `transform` changes on the path from the anchor to the scroller ([spec, suppression triggers](https://drafts.csswg.org/css-scroll-anchoring/)), so Tuna should size spacers that are siblings of the blocks rather than translate a wrapper. The prototype does this.

### hyperlith's render handler: frame pacing

**Fact** (`src/hyperlith/impl/datastar.clj:112-162`):
- Each connection's `render` function checks `(or (nil? @last-put_) (d/realized? @last-put_))`, "Only render again if previous event was sent this gives you back pressure and frame dropping" (`:139-146`).
- A batch loop drains queued actions every `batch-tick-ms` (default 50) and then calls every connection's render function (`src/hyperlith/core.clj:117-139,146-148`).
- The stream is Brotli-compressed per connection (`datastar.clj:124-130`).

**Inference:** "Sent" here means the server-side stream accepted the bytes, not that the browser applied them. The gain is that a slow client costs no rendering CPU. The owner's own spike `/home/jay/Code/go-latest-frame-spike/main.go` goes further: each screen carries a `data-init` that posts `/next` after it is applied, and the server writes the next screen only after that (`:41-43,63-69,73-81`). That is true client-side readiness.

### Web terminals and emacs-web

**Fact:**
- **go-web-terminal** (`0218968`, `assets/go-web-terminal.js`):
  - Wheel deltas of compatible direction, modifiers and position are summed (`:73-80`) into one pending item flushed per animation frame (`:171-208`). Pointer motion keeps only the newest.
  - `ResizeObserver` plus `document.fonts.ready` re-measure the viewport and cell, and a resize is sent only when the column/row count changes (`:244-259,411-412,435-437`).
  - The wheel listener is non-passive so it can `preventDefault` (`:315-321,418`).
  - Server side: `wheelDelta` converts pixels to cells and carries the remainder to the next event (`interaction_linux.go:920-945`).
  - Subscriptions keep **one trailing render-only update** (latest wins) but queue eventful updates up to a bound, then stop the lagging subscription (`subscription.go:134-165`).
  - The `-singular` checkout's asset is byte-identical.
- **emacs-web** (`d181d61`, `web/input.js`):
  - Wheel deltas accumulate into discrete notches, where a notch is 100 px, 3 lines or 1 page: "Discrete native wheel input, not a JavaScript scrolling model" (`:172-191`).
  - Adjacent wheel and motion items coalesce in the send queue (`:93-108`).
  - `ResizeObserver` posts `/resize` after a 100 ms debounce (`:206-225`).
  - Publishing waits for Emacs to be idle (`emacs-web.el:155-159`).
  - Its README: "Touch/pen … smooth pixel scrolling and edge autoscroll are not part of this slice" (`README.md:13`).
- **ghostty-web** (`lib/terminal.ts`): wheel always `preventDefault` and animates a fractional `viewportY` locally (`:1557-1612,993-1060`). There is no touch scrolling; touch is used only for an iOS caret workaround (`:414-415`).
- **xterm.js 6.0** vendors VS Code's `Gesture`, a JavaScript inertia loop with constant friction (`src/vs/base/browser/touch.ts:72,212-230,299-330`). **Monaco's README:** "Is the editor supported in mobile browsers…? No." ([monaco-editor README](https://github.com/microsoft/monaco-editor/blob/main/README.md)).
- **Weevil** planned exactly design B, as a hyperlith port with transform-translate (`/home/jay/Code/weevil-terminal/plans/virtual-scroll-plan.md`). Its notable fixes: no revision bump on an unchanged scroll report (FIX 11); server-ordered re-anchoring must set `scrollTop` instantly, not smoothly, or the animation sweeps through the thresholds and triggers posts (FIX 5).
- Tuna's own earlier research reached the same verdict: native vertical scroll in each pane, with the server only reading the scroll offset and keeping spacer heights consistent (`agents/research/window-management/niri/04-datastar-cqrs-multipane.md:28-36,80-112,192-200,239-240`; `agents/research/layout-state/README.md:105`).

**Inference:** None of the server-rendered terminals offers smooth touch scrolling. The custom-scroll editors (Monaco, xterm via VS Code's base library) either disclaim mobile or ship their own physics. Every input path that works well coalesces high-rate input per frame and keeps only the newest state.

### CodeMirror 6: unknown heights over native scrolling

**Fact** (`@codemirror/view` 6.43.13, `dist/index.js` in `/home/jay/Code/job-getter-9000/pi-web/node_modules`):
- `HeightOracle` estimates a line's height from its length, the measured line height and characters per line, and wrapping (`:5399-5420`).
- `HeightMap` is a tree of blocks and gaps with per-node heights and an "outdated" flag. Measured heights replace estimates (`:5555-5570`).
- The viewport is the visible range plus a 1,000 px margin, **biased toward the scroll direction** (`getViewport`, `:6470-6491`). It is recomputed only when the current one stops covering the visible range plus 10–250 px (`viewportIsAppropriate`, `:6501-6510`).
- After every measurement, the view finds a scroll anchor (the block at the top), re-measures, and corrects the scroll offset by the anchor's movement (`:8186-8280`).
- **iOS:** "Set to a time stamp by scroll events when touch isn't active on iOS, to work around an issue where Safari will abort the scroll momentum if we set scrollTop" (`:4528-4531,4962-4968`). The correction is skipped during iOS momentum (`:8268`).
- Documents taller than 7,000,000 px are scaled (`BigScaler`, `:6306,6765-6777`).

**Inference:** CodeMirror's strategy (estimate, render a window, measure, correct around an anchor) maps directly onto Tuna's node trees. The difference is that Tuna's height map lives on the server and its corrections can be left to the browser's own scroll anchoring. CodeMirror is evidence that native scrolling plus a virtualized DOM works on phones. Its iOS workaround also warns that **writing `scrollTop` during momentum kills the fling**.

## 3. Browser facts that decide the touch question

| Fact | Source |
|---|---|
| Browsers scroll on the compositor: "the visual scroll position is updated in the compositor thread and is visible to the user before the `scroll` event is … fired on the main thread." | [MDN, Scroll-linked effects](https://firefox-source-docs.mozilla.org/performance/scroll-linked_effects.html) |
| `touchstart`, `touchmove`, `wheel` listeners on window/document/html/body default to **passive**. Non-passive touch listeners "must block scrolling". | [DOM Standard, default passive value](https://dom.spec.whatwg.org/#default-passive-value) and §2.8 |
| To receive a finger drag yourself, the element needs `touch-action: none` (or `pan-x`): "Direct manipulation interactions that begin on the element MUST NOT trigger behaviors related to viewport panning and zooming". Otherwise the browser fires `pointercancel` when it starts panning. | [Pointer Events, touch-action](https://w3c.github.io/pointerevents/#the-touch-action-css-property) |
| Scroll events are queued per document and fired in "run the scroll steps", so at most once per rendering update. `scrollend` fires when "the user has completed their gesture" and offsets are applied. | [CSSOM View, scrolling events](https://drafts.csswg.org/cssom-view/#scrolling-events) |
| Support: `scrollend` in Chrome 114, Firefox 109, Safari 26.2. | MDN browser-compat-data `api/Element.json` (fetched 2026-10-17) |
| Scroll anchoring "aims to minimize surprising content shifts … by adjusting the scroll position to compensate for the changes outside the viewport". The anchor node is a fully visible node near the top. **Suppression triggers:** changes to `top/left/…`, margin, padding, size or `transform` on the path from the anchor to the scroller, a `position` change, or scroll offset 0. | [CSS Scroll Anchoring](https://drafts.csswg.org/css-scroll-anchoring/) |
| Support: `overflow-anchor` (scroll anchoring) in Chrome 56, Firefox 66, **Safari 27** (released 2026-09-14). | BCD `css/properties/overflow-anchor.json`, `browsers/safari.json` |
| `overscroll-behavior`: Safari 16 partial ("no effect on scroll containers that have no scrollable overflow"); Chrome 63, Firefox 59 likewise until 144/150. | BCD `css/properties/overscroll-behavior.json` |
| `ResizeObserver`: Chrome 64, Firefox 69, Safari 13.1. `content-visibility`: Chrome 85, Firefox 125, Safari 18 (skips rendering off-screen content). | BCD |
| Writing `scrollTop` during iOS momentum aborts the momentum. | CodeMirror source comment (above). **Unverified** on a device here. |

**Inference: can a page get momentum touch scrolling without native scrolling?** Yes, but only by owning the gesture. You set `touch-action: none`, track pointers, estimate velocity, and run a friction loop in `requestAnimationFrame` (VS Code's `Gesture`; my prototype). The costs:
- The physics will not match each platform's native curve, rubber band, or scroll-to-top tap.
- Pinch-zoom inside the view is lost (`touch-action: none`), and so is native scroll chaining.
- Assistive-technology scroll gestures act on native scrollers. **Unverified** in detail.
- The animation runs on the main thread, so every Datastar morph (synchronous DOM work) can drop frames. Native scrolling keeps moving on the compositor during a morph.
- Under pure server-side scrolling, each frame of motion also waits for a round trip.

## 4. Prototype findings

**What was built** (`agents/research/scrolling/proto/`, about 330 lines; not Tuna code):
- A Python server holds a 20,000-node "rich buffer": paragraphs that wrap, code blocks, headings, and tall boxes. The server cannot know their heights.
- It keeps one view's anchor, size and height map, and sends each screen as **one Datastar v1.0.2 fat morph over SSE** (Tuna's vendored bundle).
- `--bad-estimates` makes every estimate 24 px, to stress correction. `--latency MS` delays every screen and every POST by MS (one way).
- Three modes:
  - **native** (design B): a native scroller with spacers and thresholds, and the report rule "at most one report waits for its screen".
  - **backend** (design A): `touch-action: none`; wheel and drag deltas go to the server, which moves the anchor and re-renders. The client does no local motion.
  - **hybrid** (design C): like backend, but the client moves the rendered content locally by the unacknowledged deltas, and runs its own fling physics.

**How it was measured:**
- Headless desktop Chrome through `agent_browser`.
- Each frame scrolls D px (native: `scrollBy`; others: the same delta path wheel events use). The test tracks one rendered node and records how far it strays from where the scroll alone should put it. A stray is a visible jump or lag.
- Native runs jump first to 300,000 px (unmeasured territory), then scroll up 300×40 px, down 600×40 px, and "fling" 120×150 px (9,000 px/s).
- A fresh server was used per configuration, so earlier measurements could not help.

**Native mode (design B):**

| Configuration | Up (300 fr) | Down (600 fr) | Fling (120 fr) | Screens |
|---|---|---|---|---|
| 0 ms, anchoring on | 0 px, 0 frames >1 px | 0 px | 0 px | 915 |
| 0 ms, anchoring **off** | max **404 px**, 298 frames | max 8 px, 14 | max 8 px, 10 | 946 |
| 30 ms each way, on | 0 px | 0 px | 0 px | 175 |
| 80 ms each way, on | 0 px | 0 px | 0 px for 22 frames, then **ran past the rendered window** (blank) | 64 |
| 80 ms each way, **off** | max **1,927 px** | max 1,616 px | — | 62 |

**Backend and hybrid** (20 px per frame for 300 frames at 60 fps; latency is input-to-applied-screen):

| Mode | Added latency | Frames off the smooth path (>1 px) | Worst | Input→screen p50 / p95 |
|---|---|---|---|---|
| backend | 0 ms | 121 / 300 (40%) | 40 px | 9.6 / 33.9 ms |
| backend | 30 ms each way | 272 / 300 (91%) | 60 px | 31.6 / 120 ms |
| backend | 80 ms each way | 299 / 300 | 80 px | 827 / 1,376 ms (queueing; see caveats) |
| hybrid | 0 ms | 3 / 300 | 20 px | 9.8 / 34.1 ms |
| hybrid | 80 ms each way | 49 / 300 | 200 px | — |

**What this shows:**
1. Native scrolling plus server windowing is visually exact *when scroll anchoring is on*, even with wildly wrong estimates and 160 ms round trips. Anchoring is load-bearing: without it the view jumps by hundreds to thousands of pixels whenever newly measured blocks enter above the viewport.
2. The one native failure is **running out of rendered content** during a very fast fling on a slow link. The fix is to size overscan by velocity × round trip, bias it in the scroll direction (CodeMirror's `bias`), and draw cheap placeholders in spacers.
3. Pure backend scrolling cannot keep content under the finger. Even on loopback, the server, the morph and the network make motion arrive in bursts. On a remote phone, every frame is a round trip late.
4. Hybrid hides latency only within the overscan, and reconciling local deltas with server screens produced visible corrections (up to 200 px at 80 ms).
5. **Facts traffic must be paced.** My first version reported on every `scrollend` with no pacing. At 80 ms the browser's six-connection limit queued the posts and the window fell seconds behind. The rule "one report outstanding per view; keep only the newest" fixed this: 62–64 screens for 1,020 frames at 80 ms.

**Caveats:**
- Headless desktop Chrome with synthetic scrolling. **No real touch, no iOS, no feel judgement.**
- The backend 80 ms latency figure is inflated by unpaced per-frame posts and the browser's per-host connection limit. Read it as "unpaced input collapses", not as a property of backend scrolling.
- The 8 px deviations are my measurement's treatment of collapsed box margins.
- Server render cost (Python, ~40 nodes) was 4–7 ms per screen.

**How the owner can feel it:** run `python3 server.py --port 8765 [--host <tailscale-ip>] [--latency 80] [--bad-estimates]` and open `/?mode=native`, `/?mode=hybrid` or `/?mode=backend`, optionally with `&point=stay`. The bottom bar has server-side commands (page up/down, move point, type) and a toggle between "point follows scroll" (Emacs) and "point stays put". Arrow keys, PageUp/PageDown and letters do the same on a keyboard; tapping a node puts point there.

## 5. Candidate designs compared

| | **A. Pure backend** (Emacs-like; client sends wheel/touch deltas, server moves anchor and re-renders; `touch-action: none`) | **B. Native scroller + server windowing** (recommended) | **C. Hybrid** (server-owned position, client moves rendered content locally, own touch physics) |
|---|---|---|---|
| Feel, desktop wheel/trackpad | Acceptable on loopback; bursty (40% of frames off at 0 ms); degrades with every ms of latency | Native, pixel-smooth | Smooth within overscan; occasional corrections |
| Feel, phone touch | **Show-stopper**: content lags the finger by a round trip plus a morph; custom fling on the main thread stalls during morphs; no native rubber band, chaining or pinch-zoom | Native drag, fling and rubber band on the compositor; only risk is a blank region if a fling outruns the overscan on a slow link | Content follows the finger locally, but the physics are custom (non-native feel), stall during morphs, and blank beyond overscan |
| Client code | Small (gesture capture), plus custom fling to be bearable | Small: report facts, apply server scroll requests, set thresholds | Largest: gesture capture, fling physics, prediction and reconciliation |
| Server code | Height map, anchor arithmetic, windowing | Same height map, anchor arithmetic and windowing, plus estimates fed by measurements | Same as B plus delta bookkeeping |
| Immediate mode / fat morph | Yes; one morph per motion frame (the stream becomes the frame clock) | Yes; morphs only when the window must move or heights change | Yes, but the browser holds predicted offsets the server has not seen |
| Minimal client state | Yes | Yes: scroll offset is presentation state (ADR 7), and the server holds the anchor | Weakest: client-side prediction, which the owner ruled out for editor state ("no client-side prediction", `agents/STATUS.md`) |
| Accessibility, find-in-page | Lost | Native for rendered content; find-in-page cannot reach unrendered blocks (true of any windowing) | Lost |
| Kernel | Unchanged | Unchanged | Unchanged |

**Inference: why B and not A, given the owner's preference.** B keeps everything the owner wants from backend scrolling:
- the server decides what is rendered (only the window is sent);
- the server owns the position, as Emacs does, and commands set it;
- the server knows what is visible.

B delegates only the per-frame pixel motion, which the server cannot deliver at 60–120 Hz over a network anyway. A is the right design only if Tuna gives up smooth touch scrolling or runs only on loopback desktops.

**Plugin ownership** (proposal for the primary agent; the same for A, B and C except where noted):
- **Renderer** (`plugins/renderer`): windowing (which blocks, spacers, thresholds, the `data-est` estimate on each block), the per-view height map (derived state, never saved; it already keeps per-view HTML at `plugin.ss:44-59`), and per-kind estimates (a node renderer may supply an estimate hint; text uses line count × line height plus a wrap estimate, as CodeMirror's `HeightOracle` does).
- **Buffers contract `view`** (`plugins/buffers/contract.ss:181-187`): the anchor (block plus pixel offset), next to point. It is view state saved with the session, as Emacs saves `start` and `vscroll` in window state.
- **Web transport** (`plugins/web`): parses and validates a new `view-facts` input item (alongside `parse-pointer-event`, `plugin.ss:480-505`) and carries out frame pacing (section 7). Its frontend gains a small `tuna-scroll.ts` that measures and reports through `input-sender.ts`, and applies server scroll requests.
- **A scrolling concept package** (new, e.g. `plugins/scrolling/`): scroll commands (`C-v`, `M-v`, `C-l`, scroll-other-view), the point-visibility policy (`scroll-margin`, `scroll-conservatively`-like settings), and handling of facts.
- **Emacs-faithful option:** resolve a facts item through keymaps as an event (like Emacs's `<wheel-down>` bound to `mwheel-scroll`), so the handling is a rebindable, advisable command. The Input service would need to resolve this item kind; that is a decision for the plan.

## 6. Recommended design in more detail

### 6.1 Position model

- `anchor = (node-id, block-key, offset-px)`. `block-key` is #f for an atomic node, or for a text node the 1-based text position at the start of its logical line.
- `offset-px ≥ 0` is how far the viewport top sits below the block's top: Emacs's vscroll.
- This handles wrapped lines, mixed fonts, images, and nodes taller than the viewport, and never assumes a universal line.
- Edits move the anchor's position as a marker would. If its node is deleted, the anchor falls back to the nearest surviving block, through the existing parent links.

**Pixel-smooth or steps:** gestures are pixel-smooth (native). Commands can land on block boundaries (`offset-px = 0`), as Emacs commands do even under `pixel-scroll-precision-mode`. This choice is open for the owner (section 8).

### 6.2 What the server stores per view

| State | Kept where | Saved? |
|---|---|---|
| Anchor | View (buffers contract) | Yes, with the session |
| Viewport width and height (px) | Renderer, from facts | No |
| Height map: measured px per block, tagged with the node revision when measured, plus estimates for the rest; prefix sums (a sum tree over document order, or per-subtree sums using the node tree's parent links, so folded sections are cheap) | Renderer | No; cleared when width or stylesheets change |
| Last reported visible range and the request number it answers | Renderer or scrolling plugin | No |

**How unknown heights are handled:** estimate, measure, correct.
- **Estimate:** unrendered blocks use the kind's estimate. Total height and the spacers use estimates for unseen blocks, so the scrollbar is approximate until regions are visited. That is the same trade CodeMirror makes.
- **Measure:** after a screen is applied, the client measures each rendered block as the distance to the next block's top (this includes collapsed margins). It reports only blocks whose height differs from `data-est` by more than 0.5 px. Traffic is therefore proportional to new content, not to scrolling.
- **Correct:** the server replaces the estimate and re-renders the spacers. The browser's scroll anchoring keeps the visible block still, so the server never writes `scrollTop` for corrections. That matters because of the iOS momentum issue.
- **Invalidate:** an edit to a node bumps its revision, so its measured height becomes an estimate again until the next report.
- **Never rendered:** when the viewport lands entirely in a spacer (a scrollbar drag or a fast fling), the client reports the raw pixel offset and the server converts it to an anchor through the height map. The prototype needed this.

### 6.3 Facts and when they are sent

| Fact | Trigger | Coalescing |
|---|---|---|
| View size | `ResizeObserver` on the scroller, and once fonts are ready (as go-web-terminal does) | One per frame |
| Anchor plus visible range | The visible range crosses thresholds the server put on the view (hyperlith pattern); `scrollend`; and once after applying a server scroll request | Per frame; at most **one report outstanding per view** until a screen acknowledges it; while waiting, only "send newest when acked" is remembered |
| Measured heights | After a screen is applied, for blocks whose height differs from `data-est` | Rides on the next report |

Screens carry the newest input number they include (for example `data-input`, next to today's `data-revision`). That is how the client knows a report has been acknowledged. Facts items are numbered input like keys and clicks: they are ordered with them, retried, and not duplicated (ADR 7).

### 6.4 Server scroll requests and keeping point visible

- A command (`C-v`, `recenter`, search, or point leaving the view) sets a new anchor and a **request number** on the view. The renderer writes both on the scroller.
- The client applies a request exactly once, instantly (Weevil's FIX 5): it sets `scrollTop` so the anchor block sits at its offset.
- Reports name the last request applied, and the server ignores reports older than its newest request. This removes the fight between a fling in progress and a command.
- Applying a request during iOS momentum ends the fling. That is acceptable for an explicit command.
- After a command, the server checks point against the height map and the last visible range, Emacs's "point must be visible" (`windows.texi:6112-6125`), and issues a request only if needed.

### 6.5 Placement and the kernel

- No kernel change: input items are opaque to the kernel, and `Display` is unchanged.
- One mechanism for buffers and for layout scroll containers (Niri strips): any server-windowed native scroller with an id, reporting the same facts.
- Layout strips have few children, so they may need no windowing at all.
- Scroll anchoring along the horizontal axis is **Unverified**.

## 7. Frame pacing and backpressure for the whole page stream

| | Today in Tuna | hyperlith | Owner's spike |
|---|---|---|---|
| When rendering happens | Every redisplay, on the editor thread, whether or not a client can take it (`web/plugin.ss:116-129`) | Only if the previous frame was accepted by the stream; at most every 50 ms batch tick | Only after the client applied the previous frame |
| What is sent | Newest screen; intermediate ones are skipped (`:134-150`) | Newest render | Newest render |
| Readiness signal | Blocking socket write (`sse.ss:50-51`): TCP buffer level | Stream accepted the bytes | Client posts `/next` from the applied screen's `data-init` |
| Unchanged screens | Re-sent (idle every ~2 s) | Rendered and sent | n/a |

**Recommendation** (all inside the web plugin; kernel unchanged):

1. **Do not send a screen identical to the last one sent.** Compare strings in the writer. This cuts the idle traffic now; the audit's root cause, redisplay on unchanged saves, should still be fixed.
2. **Client-applied acknowledgement.** After each morph, the frontend reports the screen revision it applied: a tiny post, or the go spike's `data-init` pattern. The writer keeps at most one unacknowledged screen in flight and sends only the newest when the ack arrives. On loopback this costs one small POST per screen. On a phone over a slow link it stops kernel and proxy buffers from piling up stale screens that the browser must morph one by one.
3. **Render only when a screen can be sent** (hyperlith's property). While a screen is in flight, `redisplay!` records "wanted" instead of rendering. When the ack arrives, the request thread asks the editor loop to redisplay, using the existing `result-poster` (`tuna/kernel/loop.ss:262-270`, exported from `tuna/kernel.ss:78`). A slow client then costs no render CPU. The kernel's own throttle (redisplay after input, at least every 100 ms) stays.
4. **Facts pacing**, as in 6.3: the client side of the same idea.

**Inference:** with design B, pacing never limits scrolling smoothness, because the compositor moves pixels and the stream only refills the window. With design A, pacing *is* the scroll frame rate: 1 / (RTT + render + morph).

## 8. Questions only the owner can decide

1. **Native motion or server motion?** Will you accept the browser moving pixels between server-owned anchors (B), given the touch evidence? Or should Tuna keep pure server-side scrolling (A) and accept that phones will not feel smooth?
2. **When you scroll by finger or wheel and point leaves the view**, should Tuna move point back into the view, as Emacs does (point is always visible)? Or should point stay where it is, off screen, as in most modern editors?
3. **Browser floor.** Is requiring scroll anchoring acceptable (Chrome 56+, Firefox 66+, Safari 27+; Safari 27 shipped 2026-09-14)? The alternative is to pay for a fallback that writes `scrollTop`, which can stop iOS flings.
4. **Gesture smoothness versus command steps.** Gestures pixel-smooth, and commands (`C-v`) snapping to block boundaries the way Emacs does?
5. **Frame acknowledgement.** Is one extra small POST per screen acceptable, so that Tuna never sends a screen before the browser has applied the last one?
6. **One mechanism everywhere.** Should layout scroll containers (Niri-style strips) use the same native-scroll mechanism as buffer views?

## 9. Risks and unverified points

- **No real-device test.** Touch feel on iOS and Android is untested: the prototype ran headless desktop Chrome with synthetic scrolling. Next step: the owner tries `proto/` on a phone.
- **Not verified on a device:** whether iOS keeps a fling alive while Datastar morphs siblings of the anchor (CodeMirror suggests yes, as long as `scrollTop` is not written), and how scroll anchoring behaves during iOS momentum.
- **Fast flings on slow links** can show blank spacer regions. Overscan size, direction bias and placeholder styling need tuning against real phones.
- **Find-in-page and assistive technology** cannot see unrendered blocks. Tuna's own search is server-side, so this is an accepted cost of windowing.
- **Rich-node subtleties are untested.** Collapsible sections, columns and other horizontal layouts inside one block may need a node kind to opt out of windowing or to define its own blocks.
- **Horizontal scroll anchoring** has not been checked.
