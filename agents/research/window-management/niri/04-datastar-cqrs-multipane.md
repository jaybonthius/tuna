# Research: Multi-pane, horizontally-scrollable tiling + stacked frames over Datastar SSE (server-authoritative CQRS)

> **⚠️ Verification status (read first).** This brief was produced in an environment
> where only file read/write tools were available — **no live web access** (the
> `web_search`/`fetch_content` tools were not present). Everything below is
> synthesized from working knowledge of **Datastar v1**, **Idiomorph**, and
> **Hyperlith / Anders Murphy's** Datastar work as of early 2026. Each non-obvious
> claim is tagged:
> - **[HIGH]** core mechanism I'm confident about
> - **[MED]** correct in spirit; exact attribute/option name should be confirmed
> - **[VERIFY]** plausible but I could not confirm name/signature — check the doc URL
>
> Canonical sources to verify against are listed at the bottom. Before shipping any
> attribute name, confirm it on `data-star.dev/reference`.
>
> **Datastar v0 → v1 rename (important when reading old examples):**
> `datastar-merge-fragments` → **`datastar-patch-elements`**, and
> `datastar-merge-signals` → **`datastar-patch-signals`**. Many blog posts/examples
> still use the old names. Your terminology (`patch-elements`, `Idiomorph morph-by-id`)
> is already v1. **[HIGH]**

---

## Summary

For a server-authoritative editor, the winning shape is: **one** long-lived SSE
stream per browser tab carrying many small, **id-scoped** `datastar-patch-elements`
events; **native `overflow:auto` vertical scroll inside each pane** (browser owns the
pixel, server only *reads* `scrollTop` to choose the virtualization window and emits
consistent spacer heights so it never has to write scrollTop back); and a
**server-authoritative horizontal strip offset + frame index expressed as signals**
(`datastar-patch-signals`) applied via a CSS `transform` — *not* a native horizontal
scrollbar — so the server owns horizontal/frame position without fighting the browser.
Patches must be **scoped per-pane (and ideally per-line)** by stable unique `id`;
whole-`#weevil-root` morph per keystroke works but is wasteful and scales badly with K
panes. Idiomorph preserves `scrollTop`/focus/caret of any node it **reuses** (matched
by `id`); it loses them only when a node is **replaced** (id mismatch, tag change,
`mode:replace`, or an ancestor getting replaced).

---

## Findings

### Q1 — `datastar-patch-elements`, morph-by-id, multi-subtree, state preservation, gotchas

**1. The default patch mode morphs with Idiomorph; `id` is the matching key. [HIGH]**
A `datastar-patch-elements` SSE event carries (one `data:` line per field):

```
event: datastar-patch-elements
data: mode outer
data: elements <div id="pane-3"> … </div>

```

- `mode` defaults to **`outer`** = *morph the outer HTML* of the target via Idiomorph. **[HIGH]**
- Modes (v1): **`outer`** (morph outer, default), **`inner`** (morph inner HTML),
  **`replace`** (raw outerHTML swap, **no morph**), `prepend`, `append`, `before`,
  `after`, `remove`. **[MED — confirm the exact mode list/names on the SSE reference page]**
- If **no `selector`** is supplied, Datastar locates the target **by the `id` of each
  top-level element in the fragment** and morphs `#<that-id>` in place. This is the
  "morph by id" behavior. **[HIGH]**

**2. YES — you can patch multiple independent subtrees in one SSE event. [HIGH]**
Put several top-level elements, each with its own `id`, in a single event:

```
event: datastar-patch-elements
data: elements <div id="pane-1"> … </div>
data: elements <div id="pane-4"> … </div>
data: elements <aside id="status-bar"> … </aside>

```

Datastar matches `#pane-1`, `#pane-4`, `#status-bar` independently and morphs each in
place. Untouched panes are not visited at all. You can **also** send multiple separate
`datastar-patch-elements` events back-to-back in one flush (blank line between events).
Both compose. **[HIGH]** Use this to update only the panes that changed.

**3. Morph PRESERVES scrollTop / focus / caret of any node it REUSES. [HIGH]**
Idiomorph's design: it matches nodes (heavily using `id` sets) and **mutates existing
DOM nodes in place** (attributes + children) instead of recreating them. Because the
*same live DOM node* survives, its runtime state survives with it:
- a scroll container's `scrollTop`/`scrollLeft` is untouched by morphing (morph never
  assigns scroll),
- a focused `<input>`/`[contenteditable]` keeps focus and caret/selection,
- this holds whether the node is "untouched" or "morphed-in-place".

The catch: adding/removing children *inside* a preserved scroll container changes its
`scrollHeight`. The pixel `scrollTop` is preserved, but if you removed content *above*
the viewport without compensating, the visible content shifts. (See virtualization
spacer fix below.) **[HIGH]**

**4. Morph LOSES scroll/focus/caret only when a node is REPLACED. The gotchas: [HIGH]**
- **`mode: replace`** (or `prepend/append/before/after`) — does a raw DOM swap/insert,
  no node reuse → child scroll containers recreated → scroll/focus reset. *Use `outer`/
  `inner` (morph) for anything holding live state.*
- **`id` mismatch / missing id** — if the new element has a different/absent `id`,
  Idiomorph can't match it and replaces the node. **Every pane, column, frame, and
  ideally every line must have a stable, globally-unique `id`.** **[HIGH]**
- **Tag change** (e.g. `<div>`→`<section>`) on the matched node forces replacement. Keep
  tags stable. **[HIGH]**
- **Ancestor replacement** — if a *parent* is replaced (or you morph at the root and the
  parent structure diverges enough that Idiomorph rebuilds), descendants are recreated
  even if their ids match. Scope patches to the smallest stable subtree. **[HIGH]**
- **Duplicate ids** anywhere in the document break Idiomorph matching and cause churn.
  Pane/column/line ids must be unique. **[HIGH]**
- **Re-rendering content above the viewport without a height-preserving spacer** — the
  classic virtualization jump: `scrollTop` (pixels) is preserved but now points at
  different logical content. Fix: keep total scroll height constant (top spacer =
  `firstRow*cellH`, bottom spacer = `(totalRows-lastRow)*cellH`). Then native scrollTop
  stays valid across morphs and the server never writes scrollTop. **[HIGH]**
- **`display:none` ↔ visible toggling** resets a container's scrollTop in some browsers.
  Relevant if you hide inactive frames with `display:none`. **[MED]**

**5. How to avoid full-subtree replacement / protect state: [HIGH/MED]**
- **Stable unique ids** on every independently-updated unit (pane, column, frame, line,
  gutter). This is the #1 lever — it tells Idiomorph "reuse this node." **[HIGH]**
- **Scope the patch** to the smallest element (send `#pane-3` or even `#pane-3-line-42`,
  not `#weevil-root`). Less tree to diff = less chance of replacement + faster. **[HIGH]**
- **`data-ignore-morph`** on a subtree tells Idiomorph to skip it entirely (preserve it
  verbatim). Good for a client-stateful widget the server doesn't want to clobber.
  **[VERIFY — believe this is a v1 attribute; confirm exact name on the attributes ref]**
- **`data-preserve-attr="<attr-list>"`** preserves specific attribute values across
  morphs (e.g. an `open` state). **[VERIFY — confirm name/semantics]**
- **`data-bind` for inputs** — bind an input's value to a signal instead of rendering the
  value in server HTML; then morph never rewrites `value`, so caret never jumps. **[HIGH]**
- **View transitions** (`useViewTransition: true` on the patch, or `data-view-transition`)
  exist for animated swaps — **explicitly not wanted** for your non-animated frame switch,
  but available later for animated column motion. **[MED — confirm flag name]**

---

### Q2 — Reporting N independent scroll positions (many scroll containers)

**6. Use ONE SSE stream for output, but per-pane scroll *reporting* is a separate input
channel. Don't open N SSE connections.** One long-lived `@get` SSE per tab carries all
patches for all panes/frames; scroll/key/resize reports go out as short `@post`s. **[HIGH]**

**7. Idiomatic option A — `data-on-scroll` per pane, namespaced signal. [HIGH/MED]**
Datastar event attrs are `data-on-<event>` with `__modifier.arg` modifiers. Scroll fires
constantly, so **throttle**:

```html
<!-- server-rendered for each pane; stable id; native vertical scroll -->
<div id="pane-3"
     class="pane"
     data-pane-id="pane-3"
     style="overflow:auto"
     data-on-scroll__throttle.100ms="$panes['pane-3'].scrollTop = evt.target.scrollTop; @post('/scroll')">
  …windowed lines…
</div>
```

- `evt` is the native event in the expression; `evt.target.scrollTop` reads the pane. **[HIGH]**
- Signals are nested objects with dynamic keys → namespace by pane id:
  `$panes['pane-3'].scrollTop`. **[HIGH]**
- `__throttle.100ms` (and `.leading`/`.trail` variants) caps the post rate. Use throttle,
  not debounce, for scroll (you want periodic updates, not just the final one). **[MED —
  confirm throttle modifier + trailing/leading arg names]**

**8. Idiomatic option B — single delegated handler via capture phase. [MED/VERIFY]**
Scroll events **do not bubble**, but they *can* be captured. If Datastar exposes a
`__capture` modifier you can put **one** handler on the strip:

```html
<div id="strip"
     data-on-scroll__capture__throttle.100ms="
       $panes[evt.target.dataset.paneId].scrollTop = evt.target.scrollTop; @post('/scroll')">
  …columns/panes, each with data-pane-id…
</div>
```

This avoids N attributes. **[VERIFY — confirm Datastar supports a capture modifier; if
not, fall back to option A (per-pane attribute), which is guaranteed to work.]**

**9. Don't post *all* signals on every scroll — filter. [MED/VERIFY]**
`@post('/scroll')` serializes signals to the server. With many panes that payload grows.
Send only the pane namespace:

```html
data-on-scroll__throttle.100ms="
  $panes['pane-3'].scrollTop = evt.target.scrollTop;
  @post('/scroll', {filterSignals:{include:/^panes\./}})"
```

**[VERIFY — `filterSignals` with `include`/`exclude` regex is believed to be a v1 action
option; confirm exact shape on the actions reference. If unavailable, keep the scroll
namespace small or encode pane id in the URL: `@post('/scroll/pane-3')`.]** Note: `@post`
sends *signals*, not an arbitrary body, so put the value in a signal first. **[HIGH]**

**10. Avoid the re-render-fights-scroll feedback loop. [HIGH]** The cure is architectural,
not a flag:
- The server treats a scroll report as a **command** that updates *server* scroll state
  and selects the virtualization window. It must **never echo `scrollTop` back into the
  pane's DOM** (don't render an attribute or run JS that sets `scrollTop`). The browser
  owns the pixel.
- Because the pane node is morphed **in place** (stable id) and total scroll height is
  held constant by **spacer elements** (top/bottom padding = off-screen rows × cellH),
  the native `scrollTop` stays valid after each content morph → no jump, no fight. **[HIGH]**
- Throttle reports (≥~80–100 ms) so you emit at most ~10 windowing morphs/sec while the
  user drags, and each morph only swaps the few newly-revealed lines. **[HIGH]**

---

### Q3 — Strip offset & frame switching: server HTML vs signal vs native scroll

**11. Three options, with the recommendation = a hybrid. [HIGH reasoning]**

| Approach | Who owns position | Re-render cost | Fights browser? | Verdict |
|---|---|---|---|---|
| (a) Server-rendered `transform: translateX()` on `#strip` | Server | morph the strip element (style attr only) | No | Good; cheap if scoped |
| (b) Signal-driven `transform` (server sets signal, client applies) | Server (sets signal) | **patch-signals only, no HTML morph** | No | **Best for the moving offset** |
| (c) Native `overflow-x` scroll of the strip | Browser | none, but server must *read* scrollLeft | **Yes** — server can't set it without writing scrollLeft (jank) | Avoid for server-authoritative horizontal nav |

- **Horizontal strip offset → use (b) signal + transform.** Niri-style horizontal column
  navigation is *discrete and server-decided* (focus column N → snap offset), not free
  pixel scrolling. The server computes the offset and pushes a tiny `datastar-patch-signals`:

  ```
  event: datastar-patch-signals
  data: signals {"stripX": 1280, "focusedCol": 3}
  ```

  The strip applies it with no HTML morph:

  ```html
  <div id="strip" data-attr-style="`transform: translate3d(${-$stripX}px,0,0); will-change: transform;`">
    <section id="col-0">…</section>
    <section id="col-1">…</section>
  </div>
  ```

  `data-attr-style` sets the whole inline `style` from the expression. **[HIGH for
  `data-attr-<name>`; `data-style-transform` may also exist as a per-property convenience
  — VERIFY.]** This keeps horizontal navigation off the HTML-morph path entirely: moving
  between columns is a ~30-byte signal patch. The server still owns the number. **[HIGH]**

- **Native scroll (c) is right for the *vertical* axis inside each pane** (Q2): natural
  momentum, scrollbar, accessibility, and the server only needs to *read* it for
  windowing. The asymmetry is deliberate: **native scroll where the server only observes
  (vertical text), transform where the server commands (horizontal columns + frames).**
  **[HIGH reasoning]**

- Option (a) is a fine fallback if you'd rather not introduce a client signal — but every
  column move then re-morphs `#strip`'s style attribute. Cheaper than it sounds (one attr,
  children preserved by id) but strictly more than a signal patch. **[HIGH]**

**12. How hypermedia/Datastar apps render scrolling/virtualized content. [MED — general
pattern, specific demos not live-verified]** The dominant pattern (Anders Murphy /
Hyperlith, and htmx-era infinite-scroll) is **server windowing + spacers, never
server-set scroll**: a tall outer height (or top/bottom spacer) represents the full
content; the server renders only the visible slice positioned by spacer/padding;
`scrollTop` is native and preserved by morph. Anders Murphy's large-grid/"many cells"
Datastar demos lean on (1) **server-side diffing** — keep the last view per client, emit
only changed elements by `id` — and (2) **compressing the SSE stream (gzip/brotli)**,
which is extremely effective because repeated markup compresses to almost nothing, so
even chunky patches are cheap on the wire. **[MED — verify specifics on andersmurphy.com
and the Hyperlith repo.]**

---

### Q4 — Stacked frames (Niri-workspace-style), non-animated switching

**13. Render ONLY the active frame. [HIGH recommendation]** Since switching is
non-animated and only one frame is ever visible:
- **Render-active (recommended):** the server emits just the active frame's strip. A
  "switch frame" command morphs `#frames`'s child (or replaces `#strip`'s content). Min
  DOM, min morph cost, and the server never has to keep K hidden frames' content up to
  date. Frame N's scroll/layout lives in **server state** (you're server-authoritative
  anyway) and is restored via windowing on re-render — no client-side scroll restore
  needed because vertical position is logical (row index) + spacer math. **[HIGH]**
- **Render-all + `data-show`/translateY (only if instant client toggle matters and K is
  tiny):**
  ```html
  <div id="frames">
    <section id="frame-0" data-show="$frame === 0">…</section>
    <section id="frame-1" data-show="$frame === 1">…</section>
  </div>
  ```
  Switching = one `datastar-patch-signals` setting `$frame` → instant, zero HTML morph.
  **Cost:** the server must render and keep *all* K frames (and all their panes) live in
  the DOM and patched, which multiplies steady-state morph traffic by K even though K−1
  are hidden. `display:none` may also drop hidden panes' native `scrollTop`. **[MED]**

**Verdict:** for an editor with potentially many frames each holding multiple
virtualizing panes, **render only the active frame**. Reserve render-all+`data-show` for
a small fixed K where you've measured that the round-trip on switch feels too slow.
translateY between frames buys nothing over `display`/`data-show` when switching is
non-animated and only one is visible — skip it. **[HIGH]**

---

### Q5 — Performance: whole-root morph vs scoped per-pane patches

**14. Whole-`#weevil-root` morph per keystroke "works" but doesn't scale; scope it. [HIGH]**
- Idiomorph cost is roughly proportional to the size of the two trees compared (old
  subtree + new fragment). Today's single-pane root is small, so whole-root morph is fine.
  With **K panes × ~50 visible rows × spans/gutter**, the root can be thousands of nodes;
  morphing all of it on every keystroke is wasteful and risks accidental node replacement
  in untouched panes. **[HIGH]**
- **Scope patches by id to what changed:**
  - keystroke editing one pane → patch only `<div id="pane-P">…</div>` (or, finer, only
    the changed `<div id="pane-P-line-42">`). **[HIGH]**
  - several panes changed (e.g. a command touching multiple) → multiple top-level elements
    in one `datastar-patch-elements` event, or several events in one flush. **[HIGH]**
  - whole-root / `#strip` morph **only** when topology changes (column added/removed/
    reordered, frame switch). **[HIGH]**
- **Server-side diffing** (Hyperlith-style): keep the last rendered DOM per client, diff
  it against the new render, and emit only the changed elements by `id`. This is what lets
  Datastar apps drive large UIs from the server at interactive rates. **[MED — verify on
  Hyperlith/andersmurphy.]**
- **Compress the SSE stream** (gzip/brotli). Repeated editor markup compresses to near
  nothing; this is the cheap lever that makes "larger than ideal" patches a non-issue.
  Confirm your server/proxy doesn't buffer SSE (disable proxy buffering; flush per event).
  **[MED]**
- **Stable unique ids everywhere** double as the performance lever: good Idiomorph
  matching = minimal DOM churn = fast morph + preserved scroll/focus. **[HIGH]**

Rule of thumb: a keystroke should produce a patch on the order of *one line to one pane*,
not the whole tree.

---

### Q6 — Datastar features that specifically help

- **`data-on-load="@get('/updates')"`** on the root/body — opens the **single long-lived
  SSE GET** that pushes all `patch-elements`/`patch-signals`. This is the read side. **[HIGH]**
- **`datastar-patch-signals`** — push server-authoritative scalars (`stripX`, `frame`,
  `focusedPane`) with **no DOM morph**; pair with `data-attr-style` / `data-show` /
  `data-class` / `data-text` to apply. Ideal for horizontal nav + frame switch. **[HIGH]**
- **`data-computed-x="…"`** — derived client signals (e.g. compute the transform string,
  or `isVisible`, from base signals) without server round-trips. **[HIGH]**
- **`data-on-keydown__window="@post('/key', …)"`** — global keystroke capture → the
  command stream (CQRS write side). Use modifiers/`evt.key` to encode the key. **[HIGH]**
- **`data-on-resize`** (ResizeObserver) per pane and **`data-on-resize__window`** for the
  viewport — replaces today's single `$viewH/$viewW`/`/resize` post with per-pane metrics.
  **[MED — confirm `data-on-resize` is the resize plugin name; it may be `data-on-resize`
  via ResizeObserver or a dedicated `data-resize` plugin.]**
- **`data-ref-<name>`** — get an element handle into a signal; use it to measure a
  reference glyph for `cellW`/`cellH` (read `getBoundingClientRect`) and post once. **[MED]**
- **`data-on-intersect__once`** (IntersectionObserver) — sentinel-driven lazy mounting /
  infinite-scroll trigger; an alternative or complement to scroll-position windowing
  (fire when a top/bottom sentinel enters the pane). Modifiers like `__once`/`__full`/
  `__half`. **[MED — confirm modifier names.]**
- **`data-ignore-morph`** — fully protect a client-stateful subtree from morphing. **[VERIFY]**
- **`data-preserve-attr`** — keep specific attribute values across morphs. **[VERIFY]**
- **Multiple top-level elements per event + multiple events per flush** — the mechanism
  for scoped multi-pane updates (Q1.2, Q5). **[HIGH]**
- **`data-bind`** for any input so the server never renders `value` and caret never jumps
  on morph. **[HIGH]**

---

## Recommended architecture for weevil (concrete)

**DOM skeleton (server-rendered, all ids stable + globally unique):**

```html
<div id="weevil-root" data-on-load="@get('/updates')"
     data-on-keydown__window="@post('/key')">
  <div id="frames">
    <!-- only the ACTIVE frame is rendered -->
    <div id="strip"
         data-attr-style="`transform: translate3d(${-$stripX}px,0,0); will-change: transform;`">
      <section id="col-0" class="column">
        <div id="pane-12" class="pane" data-pane-id="pane-12" style="overflow:auto"
             data-on-scroll__throttle.100ms="$panes['pane-12'].scrollTop = evt.target.scrollTop; @post('/scroll', {filterSignals:{include:/^panes\\./}})"
             data-on-resize="$panes['pane-12'].viewH = evt.target.clientHeight; $panes['pane-12'].viewW = evt.target.clientWidth; @post('/resize')">
          <div class="vspace-top"  style="height: 504px"></div>   <!-- firstRow*cellH -->
          <div id="pane-12-line-42">…</div>
          <div id="pane-12-line-43">…</div>
          <!-- … visible rows … -->
          <div class="vspace-bot"  style="height: 9999px"></div>  <!-- (total-last)*cellH -->
        </div>
      </section>
      <section id="col-1" class="column"> … stacked panes … </section>
    </div>
  </div>
</div>
```

**Data flow (CQRS):**
- **Write side (commands, short `@post`):** `/key`, `/scroll`, `/resize`, `/focus-col`,
  `/switch-frame`. These mutate server state only.
- **Read side (one long-lived SSE):** `/updates` pushes:
  - `datastar-patch-signals` for `stripX`, `frame`, `focusedPane` (horizontal nav + frame
    switch — no HTML morph),
  - `datastar-patch-elements` scoped by id for content edits (one pane, or one line),
  - `datastar-patch-elements` on `#strip`/`#frames` only on topology change.
- **Vertical scroll:** native `overflow:auto`; server reads `$panes[id].scrollTop`, picks
  the window, renders consistent `vspace-top`/`vspace-bot` so native scrollTop never needs
  writing back.
- **Horizontal + frame:** server-authoritative signals → transform / active-frame render.
  Server owns the number; browser just applies it. No native horizontal scroll container.

**Migration from today's single `$scrollTop/$viewH/$viewW/$cellW/$cellH`:** move to a
`$panes` object keyed by pane id (`$panes['pane-12'].scrollTop`, `.viewH`, …). Measure
`cellW/cellH` once via a `data-ref` glyph (cell size is global, not per-pane). Keep ONE
SSE stream — do not open one per pane.

---

## Sources (canonical — verify names/signatures here; not live-fetched in this run)

- **Datastar docs/reference** — `https://data-star.dev/` ; SSE events
  (`datastar-patch-elements`, `datastar-patch-signals`, modes, `useViewTransition`),
  attributes (`data-on-*`, `data-attr`, `data-bind`, `data-computed`, `data-show`,
  `data-ref`, `data-on-intersect`, `data-ignore-morph`, `data-preserve-attr`,
  `data-view-transition`), and actions (`@get`/`@post` options incl. `filterSignals`).
  **The single most important verification target.**
- **Datastar GitHub (org `starfederation`)** — `https://github.com/starfederation/datastar`
  — SDKs (each documents the exact SSE wire format it emits) + `/examples`.
- **Idiomorph** — `https://github.com/bigskysoftware/idiomorph` — id-set matching,
  node-reuse semantics (why scroll/focus survive), `morphStyle`, callbacks, ignore set.
- **Hyperlith** — `https://github.com/andersmurphy/hyperlith` — real Clojure+Datastar app:
  one SSE stream, server-side diffing, id-scoped patches.
- **Anders Murphy's blog** — `https://andersmurphy.com` — Datastar performance posts:
  server-side diffing, gzip/brotli SSE compression, large interactive grids.

## Gaps / could-NOT-verify (do these before relying on exact syntax)

1. **No live verification was possible in this run** (no web tools). Treat all
   attribute/option *names* as needing a quick confirm on `data-star.dev/reference`.
2. **`filterSignals` action option** (Q2.9) — believed to exist with `include`/`exclude`
   regex; confirm shape. If absent, encode pane id in the URL instead.
3. **`__capture` scroll modifier** (Q2.8) — confirm Datastar supports capture-phase
   delegation; if not, use per-pane `data-on-scroll` (guaranteed).
4. **`data-ignore-morph` / `data-preserve-attr`** (Q1.5, Q6) — confirm exact names and
   semantics on the attributes reference.
5. **`data-attr-style` vs a dedicated `data-style-transform`** — `data-attr-<name>` is
   safe; confirm whether a per-style-property plugin exists for cleaner transform binding.
6. **Exact `mode` enum** for `datastar-patch-elements` and the **`useViewTransition`** flag
   name — confirm on the SSE reference.
7. **`data-on-resize` plugin name** and **`data-on-intersect` modifiers** — confirm.
8. **Anders Murphy / Hyperlith specifics** (server-diff algorithm, compression knobs,
   the exact large-grid demo) — described from memory; verify on the repo/blog.
9. **Quantitative morph cost** (ms per N nodes) is asserted qualitatively, not benchmarked.
   Recommend a quick local benchmark: morph a synthetic K-pane × 50-line root vs a single
   `#pane` patch, measure with `performance.now()` around the morph, to set your
   "scope-per-pane" threshold empirically.
