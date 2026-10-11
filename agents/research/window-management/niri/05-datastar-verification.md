# Datastar verification (real Racket SDK + spike)

Brief `04-datastar-cqrs-multipane.md` was produced WITHOUT live web access, so its
attribute/option names were flagged `[VERIFY]`. This note records what I verified
directly against the **actual Racket SDK** (`../datastar-racket/datastar-lib`) and the
in-repo `DATASTAR_DOCS.md`, plus a runnable spike. These are the load-bearing facts the
design depends on; treat them as confirmed.

## Verified from the Racket SDK source (`datastar-lib/http/sse.rkt`)

- `patch-elements/xexprs` accepts **`(or/c xexpr/c (listof xexpr/c))`**. Passing a LIST
  emits ONE `datastar-patch-elements` event whose `data: elements` line concatenates all
  top-level elements; Datastar morphs each **by its `id`**. → **Scoped multi-pane patches
  are natively supported**; we can patch only the panes that changed in a single event.
- Optional kwargs: **`#:selector <css>`**, **`#:mode (or/c 'outer 'inner 'remove 'replace
  'prepend 'append 'before 'after)`** (default `outer` = Idiomorph morph),
  `#:namespace`, `#:use-view-transitions?`, `#:event-id`, `#:retry-duration`.
- `patch-signals` accepts a `jsexpr?` (hash) or string → emits `datastar-patch-signals`
  with **no DOM morph**. `remove-elements` / `remove-signals` exist.
- `execute-script` is implemented as a `patch-elements` `append` to `body` carrying a
  `<script data-effect="el.remove()">` (auto-remove). This is exactly how the current
  cursor re-anchor (`reanchor-script` in `session-state.rkt`) runs plain browser JS.

## Verified from `DATASTAR_DOCS.md`

- Default patching morphs by element **id**; "Morphing ensures that only modified parts
  of the DOM are updated … **preserving state**." (l.58) Top-level elements are matched by
  id; an element with that id must already exist (l.71, l.1316).
- Multiple separate `datastar-patch-elements` events in one stream compose (l.1393-1394).
- `patch-signals` updates named signals on the client without touching the DOM.

## Spike (ran against the real SDK; `/tmp/weevil-niri-ref/spike.rkt`)

```racket
(patch-elements/xexprs sse
  (list `(div ((id "pane-12") (style "transform:translateX(0px);")) "pane twelve")
        `(div ((id "pane-13") (style "transform:translateX(640px);")) "pane thirteen")))
(patch-signals sse (hash 'stripX 1280 'frame 2))
(patch-elements/xexprs sse `(span "L42 C3") #:selector "#mode-line-pane-12" #:mode 'inner)
```

Emitted wire output:

```
event: datastar-patch-elements
data: elements <div id="pane-12" ... style="transform:translateX(0px);">pane twelve</div><div id="pane-13" ... style="transform:translateX(640px);">pane thirteen</div>

event: datastar-patch-signals
data: signals {"frame":2,"stripX":1280}

event: datastar-patch-elements
data: mode inner
data: selector #mode-line-pane-12
data: elements <span>L42 C3</span>
```

## Consequences for the design (all confirmed, not assumed)

1. **Inline `style` for layout geometry is already the house pattern.** `render.rkt`
   already renders the virtual-scroll layers' `height`/`transform:translateY(...)` as
   inline `style`. Rendering the strip's `transform: translateX(-view-offset)` and each
   column's width / pane's height as inline `style` is consistent — **the horizontal
   strip offset and frame layout can be fully server-rendered with no client signal and
   no native horizontal scrollbar.**
2. **Scoped per-pane patches are available now** (list-of-xexprs and/or `#:selector`), so
   the future optimization "patch only the changed pane(s)" is a pure render-path change,
   not an SDK limitation.
3. **Per-pane native vertical scroll preservation across a whole-root morph** rests on the
   *same* Idiomorph in-place-morph-by-id property that already preserves the single
   pane's `scrollTop` today; it extends to N scrollers **iff each pane's scroller carries
   a stable, globally-unique `id`**. This is the one behavioural claim I could not unit-
   prove without a browser; the design gates it behind an explicit **2-pane manual check
   early in Phase 1** (open two columns, scroll each, type in one, confirm neither
   scroll position jumps).
4. **Per-pane scroll/resize reporting** can bake the pane id straight into the rendered
   `@post` payload string — exactly how `select-input-target-expression` already bakes a
   pane id into a `@post('/key', {payload:{… id …}})` — so **no nested-signal machinery
   (`$panes['id'].scrollTop`) is required**. (Nested signals work too, per `patch-signals`
   above, but baking the id is simpler and matches existing code.)
