# Phase 0.5 — Display-Projection Seam: Implementation Plan

Status: **ready to implement** (behaviour-preserving refactor; adds zero deps)
Date: 2026-06-17
Scope: Extract the implicit per-line projection in `render-editor-window` into
an explicit, minimal **display-projection provider** seam that the window
renderer consumes. The text path stays **byte-identical**; a future terminal
buffer (and syntax highlighting) become additional providers/decorators with
**no `render-terminal-pane` special case**.

Grounded in: `plans/terminal-design.md` §5.0 ("Content model vs display
projection") + §5.4; `plans/terminal-research/00-weevil-constraints.md`;
`02-eat-pure-emulator.md` §6 (the `eat-term-*` callback seam — the emulator is a
pure state machine, the host wires it); `05-rendering-and-performance.md` §2
(grid → run-length spans through weevil's class-based segment renderer).

Emacs is the conceptual reference (buffer text + faces/overlays → one uniform
display pipeline, many producers). We deliberately do **not** port Emacs's
`display`/`invisible`/`composition` surface — add capabilities only when a
consumer needs them.

---

## 0. Summary of the change

Today `render-editor-window` (`weevil/private/web/render.rkt:226`) hard-codes the
text content model into the renderer. It pulls the buffer-model
(`session-selected-pane-model`, `render.rkt:227`) and calls, against that one
model: `buffer-model-line-count`, `buffer-model-line-range-text`,
`buffer-model-line-start-byte`, `buffer-model-byte->line/utf16-column`, then
builds a `buffer-projection` and injects the cursor with
`render-buffer-lines` / `render-buffer-lines/no-cursor` (`render.rkt:245-256`).

We replace those direct calls with a **provider** (`display-projection`) that
answers four questions about a buffer's *display*:

1. `line-count` — how many display lines (drives `compute-window`).
2. `rendered-lines start end` — the styled segments for lines `[start, end)`.
3. `cursor` — `(cursor-pos line col type)` in **display** coords, or `#f`.
4. `display->content line col` — reserved hook (Phase 3 mouse), returns `#f` now.

Plus one reserved decoration hook (`decorations`) for server-owned overlays
(text region highlight + terminal selection share it).

The **text provider** reproduces the current windowed slice exactly. The window
renderer becomes content-model-agnostic; `virtual-scroll.rkt` and
`session-state.rkt` are **unchanged**.

---

## 1. The interface — `weevil/private/web/projection.rkt` (new)

A **struct-of-procedures** (matches the `eat-term-*` callback-seam pattern in
brief 02 §6, and `terminal-design.md` §5.1's engine seam sketch). Simpler than
`racket/generic` and trivially constructed per buffer kind.

### 1.1 Data shapes

- **`rendered-segment`** = the existing `buffer-segment`
  (`weevil/private/web/buffer-view.rkt:31`: `start-byte end-byte text classes`).
  **Reuse it** — `render-segment` (`render.rkt:86`) already turns a
  `buffer-segment` into `(span ((class …)) text)`. `classes` are **CSS class
  strings** (see §1.4). The "reserved link/overlay slot" (OSC 8 hyperlinks /
  terminal cell metadata) is *not* added now — reserve the design space; add a
  5th `buffer-segment` field only when a consumer needs it (kept minimal).
  - Display-line segment text **never contains a newline** (the line is the
    unit). `start-byte`/`end-byte` are unused by `render-segment`; the text
    provider sets `0`/`(utf-8-byte-length text)`.
- **`rendered-line`** = `(listof buffer-segment)` — the styled runs of one
  display line. Empty line = `(list (buffer-segment 0 0 "" '()))`.
- **`cursor-pos`** (new struct): `(struct cursor-pos (line col type) #:transparent)`
  - `line` — absolute display-line index (0-based).
  - `col` — **codepoint** index of point within that line (0 … line-length).
  - `type` — cursor shape symbol (`block`/`bar`/`underline`/`hollow`),
    resolved by the caller (see §1.4).
- **`decoration`** (new struct, reserved): `(struct decoration (line start-col end-col class) #:transparent)`
  — a server-owned range that adds `class` to covered segments at render time.

### 1.2 The provider struct

```racket
;; weevil/private/web/projection.rkt
(struct display-projection
  (line-count-proc        ; (-> exact-nonnegative-integer?)
   rendered-lines-proc    ; (start end -> (listof rendered-line))   ; [start,end)
   cursor-proc            ; (-> (or/c cursor-pos? #f))
   decorations-proc       ; (-> (listof decoration?))   ; reserved; '() today
   display->content-proc) ; (line col -> (or/c exact-nonnegative-integer? #f)) ; Phase 3
  #:transparent)

;; Thin accessors the renderer calls (so call sites never touch the procs):
(define (projection-line-count p)            ((display-projection-line-count-proc p)))
(define (projection-rendered-lines p s e)    ((display-projection-rendered-lines-proc p) s e))
(define (projection-cursor p)                ((display-projection-cursor-proc p)))
(define (projection-decorations p)           ((display-projection-decorations-proc p)))
(define (projection-display->content p l c)  ((display-projection-display->content-proc p) l c))
```

Provide (contract-out): `struct cursor-pos`, `struct decoration`,
`display-projection?`, `make-display-projection` (positional ctor with keyword
defaults for the reserved procs: `decorations` → `'()`, `display->content` →
`#f`), the five accessors, `rendered-line?` predicate, and `apply-decorations`
(§5).

### 1.3 The decoration application helper (§5; identity today)

```racket
(define (apply-decorations segments line decorations)
  (if (null? decorations)
      segments                                  ; <- guarantees byte-identical text path
      (for/fold ([segs segments])
                ([d (in-list decorations)] #:when (= (decoration-line d) line))
        (decorate-segments segs (decoration-start-col d) (decoration-end-col d)
                           (decoration-class d)))))
```

`decorate-segments` (private) splits the line's segments at `start-col`/`end-col`
(codepoint boundaries) and appends `class` to the covered runs' `classes`.
Phase 0.5 ships it + a unit test, but no provider emits decorations yet, so the
render path passes `'()` and `apply-decorations` returns the input list
unchanged.

### 1.4 Where faces/classes are named vs mapped to CSS (per ADR)

Per `ADR.md:704` ("The Racket core owns concrete DOM structure, **CSS class
mapping**…"): `rendered-segment.classes` are **CSS class strings owned by
core**. Providers are core-internal modules, so the text provider emits `'()`
(unstyled, exactly as today) and the future terminal provider emits
`term--bold`, `term-fg-3`, etc. directly. A user-facing *face naming* layer (if
introduced later) maps **face name → CSS class** in core *before* the segment is
built — it is **not** part of this seam. The cursor `type` is likewise resolved
by the caller via `effective-cursor-type` (`render-editor-app`, `render.rkt:441`)
and handed to the provider; the provider does not read options. Keeps the seam
minimal and option-free.

---

## 2. The text provider — `weevil/private/web/text-projection.rkt` (new)

```racket
(define (make-text-projection model point-byte cursor-type)
  (make-display-projection
   #:line-count    (lambda () (buffer-model-line-count model))
   #:rendered-lines (lambda (start end) (text-rendered-lines model start end))
   #:cursor        (lambda () (text-cursor model point-byte cursor-type))))
   ;; decorations/display->content take the reserved defaults ('() / #f)
```

### 2.1 `text-rendered-lines` (byte-identical to today's slice)

Mirrors `render-editor-window`'s current slice
(`render.rkt:245` `buffer-model-line-range-text` + the implicit
`split-text-lines` inside `piece-lines`):

```racket
(define (text-rendered-lines model start end)
  (define slice (buffer-model-line-range-text model start end)) ; drops last LF, like today
  (for/list ([chunk (in-list (split-text-lines slice))])        ; reuse split-text-lines
    (list (buffer-segment 0 (utf-8-byte-length chunk) chunk '()))))
```

`buffer-model-line-range-text` (`buffer-model-rope.rkt:347`) already returns lines
`[start,end)` joined by `\n` with the trailing newline dropped, and
`split-text-lines` (`render.rkt:165`) yields exactly `(end-start)` chunks — so
this returns `grid-count` rendered lines, one plain `buffer-segment` each,
identical to today's per-line output. (`split-text-lines` must be exported from
`render.rkt` or copied into `text-projection.rkt`; exporting is cleaner — it is
pure and dependency-free.)

### 2.2 `text-cursor` (absolute display coords)

```racket
(define (text-cursor model point-byte cursor-type)
  (define-values (line _col) (buffer-model-byte->line/utf16-column model point-byte))
  (define line-start (buffer-model-line-start-byte model line))
  (define col (- (buffer-model-byte->char model point-byte)        ; codepoints within line
                 (buffer-model-byte->char model line-start)))
  (cursor-pos line col cursor-type))
```

- `line` via `buffer-model-byte->line/utf16-column` — same call the renderer uses
  today (`render.rkt:247`); the utf16 column is discarded just as today.
- `col` is the **codepoint** offset of point within its line, multibyte-safe
  (subtracting two `buffer-model-byte->char` results). This is exactly what
  today's path computes implicitly: it rebases point into the slice
  (`local-point-byte`, `render.rkt:251`) then `split-segment-at-point` →
  `byte-offset->char-index` (`render.rkt:96`), and `piece-lines` lands the cursor
  on point's line at that codepoint offset.
- The text provider **always** returns a `cursor-pos` (never `#f`); the renderer
  draws it only if `line` falls in the rendered window (§3.2), reproducing
  today's `point-line-rendered?` gating (`render.rkt:248`). A terminal provider
  will return `#f` when DECTCEM-hidden or scrolled into scrollback.

---

## 3. Refactor `render-editor-window` to consume the provider

### 3.1 Call sites that must move behind the seam

All in `render-editor-window` (`render.rkt:226-273`):

| Current code (file:line) | Becomes |
|---|---|
| `(session-selected-pane-model state)` `render.rkt:227` | dropped; build provider from `session-selected-pane-buffer` |
| `(buffer-model-line-count model)` `render.rkt:228` | `(projection-line-count provider)` |
| `(buffer-model-line-range-text model offset end-line)` `render.rkt:245` | inside `text-rendered-lines` |
| `(buffer-model-line-start-byte model offset)` `render.rkt:246` | no longer needed (cursor is absolute) |
| `(buffer-model-byte->line/utf16-column model point-byte)` `render.rkt:247` | inside `text-cursor` |
| `(make-buffer-projection slice-text local-point-byte)` + `render-buffer-lines` `render.rkt:250-253` | `projection-rendered-lines` + new cursor-injecting loop (§3.2) |
| `(make-buffer-projection slice-text 0)` + `render-buffer-lines/no-cursor` `render.rkt:254-255` | same loop; plain lines (no cursor) |

`session-selected-pane-point-byte` (`session-state.rkt:251`),
`-scroll-top-px` (`:254`), `-view-height-px` (`:257`) stay in
`render-editor-window`. `buffer-model` stays required by `render.rkt` only for
`render-mode-line` (`render.rkt:418`) — that surface is **out of scope**.

### 3.2 The new window body (byte-identical)

```racket
(define (render-editor-window state buffer-name resolved-cursor-type rev)
  (define pane-buffer (session-selected-pane-buffer state))
  (define point-byte  (session-selected-pane-point-byte state))
  (define provider    (buffer->display-projection pane-buffer point-byte resolved-cursor-type))
  (define line-count  (projection-line-count provider))
  (define scroll-top-px (session-selected-pane-scroll-top-px state))
  (define raw-view-h  (session-selected-pane-view-height-px state))
  (define view-height-px (if (<= raw-view-h 0) default-view-height-px raw-view-h))
  (define win (compute-window line-count scroll-top-px view-height-px))   ; UNCHANGED
  (define offset (vs-window-offset-lines win))
  (define grid-count (vs-window-grid-count win))
  (define end-line (+ offset grid-count))
  (define rlines (projection-rendered-lines provider offset end-line))
  (define cur    (projection-cursor provider))
  (define decos  (projection-decorations provider))                       ; '() for text
  (define lines
    (for/list ([segs (in-list rlines)] [i (in-naturals offset)])
      (define segs* (apply-decorations segs i decos))                     ; identity today
      (cond
        [(and cur (= (cursor-pos-line cur) i))
         (render-line (line-pieces-with-cursor segs*
                                               (cursor-pos-col cur)
                                               (cursor-pos-type cur)))]
        [else
         (render-line (map segment->text-piece segs*))])))
  ;; … the existing editor/editor__virtual/editor__translate/editor__view/
  ;;    editor__buffer wrapper (render.rkt:257-273) is UNCHANGED, spliced with `lines`.
  )
```

Gating note: the loop iterates only `[offset, end-line)`, so a cursor whose line
is outside the window is never matched → no cursor drawn — exactly today's
`point-line-rendered?` behaviour, with no explicit predicate call.

### 3.3 New private helpers in `render.rkt`

Cursor lives in `render.rkt` (it produces the private `text-piece` /
`cursor-piece`, `render.rkt:45,51`). `line-pieces-with-cursor` is the per-line,
codepoint-indexed equivalent of `projection->pieces-with-cursor`
(`render.rkt:102`), and is **byte-identical** for the single-plain-segment
case the text provider emits (equivalence argued below):

```racket
(define (segment->text-piece s)
  (text-piece (buffer-segment-text s) (buffer-segment-classes s)))

;; Inject the cursor into ONE display line's segments at codepoint column `col`.
(define (line-pieces-with-cursor segments col type)
  (let loop ([segs segments] [acc 0] [pieces '()] [done? #f])
    (cond
      [(null? segs)
       (reverse (if done? pieces (cons (cursor-piece type #f '()) pieces)))]
      [else
       (define s (car segs))
       (define t  (buffer-segment-text s))
       (define cs (buffer-segment-classes s))
       (define len (string-length t))
       (cond
         [(and (not done?) (<= acc col) (< col (+ acc len)))
          (define local (- col acc))
          (let* ([p (cons (text-piece (substring t 0 local) cs) pieces)]              ; before
                 [p (cons (cursor-piece type (substring t local (add1 local)) cs) p)] ; glyph
                 [p (cons (text-piece (substring t (add1 local) len) cs) p)])         ; after
            (loop (cdr segs) (+ acc len) p #t))]
         [else
          (loop (cdr segs) (+ acc len) (cons (text-piece t cs) pieces) done?)])])))
;; (the else branch carries `done?` through unchanged)
```

`render-line` (`render.rkt:180`) is reused verbatim: it sets
`editor__line--active` iff a `cursor-piece` is present (`line-has-cursor?`,
`render.rkt:176`) and serializes pieces via `render-piece` (`render.rkt:77`).

**Equivalence argument** (proven by the golden test, §6.1):
- *Real glyph at point* — peels exactly one codepoint into the cursor cell with
  the segment's classes → matches `projection->pieces-with-cursor`'s real-glyph
  branch (`render.rkt:155`). Multibyte (`λ`) peels one codepoint.
- *Newline at point* — `byte->line/utf16-column` returns the line the LF
  terminates with `col == line-length`; the injector appends a synthetic
  (`glyph #f`) cell to that line, which still breaks because lines are already
  separate units → matches the newline branch (`render.rkt:143`) +
  `piece-lines` (`render.rkt:171`).
- *End of buffer* — last line, `col == line-length` → synthetic `'()` cell →
  matches the EOB branch (`render.rkt:159`).
- *Empty line* — `(buffer-segment 0 0 "" '())`; `render-text-piece ""` → `'()`
  (`render.rkt:72`), so a non-cursor empty line yields a childless
  `editor__line` and the cursor empty line yields just the synthetic cell —
  matches the trailing-empty-line case in `tests/web-render-test.rkt`.
- The synthetic-EOL classes are `'()` (vs the newline branch's segment classes).
  The text provider's segments are always unstyled (`'()`), so this is
  byte-identical for the text path; it would only differ under a styled
  line-final newline, which no Phase 0.5 provider produces. A future
  syntax/terminal provider refines it if ever needed.

`render-buffer-lines`, `render-buffer-lines/no-cursor`,
`projection->pieces-with-cursor`, `projection->plain-pieces`, and `piece-lines`
(`render.rkt:185,196,102,192,168`) become **dead** for the window path. Leave
them in place if still used by `render-minibuffer-input-parts` (`render.rkt`,
which calls `projection->pieces-with-cursor` directly); otherwise delete in a
later cleanup commit. The minibuffer input surface is **out of scope** (single
line, no virtual-scroll) — leave it unchanged.

---

## 4. Provider selection by `kind`; session-state / virtual-scroll compatibility

### 4.1 The kind dispatcher

`buffer-state` already carries `kind` (`buffer-state.rkt:24`, default `'normal`
at `:53`; minibuffer buffers use `'minibuffer`, `session-state.rkt:535,595`).
Add a small dispatcher in `projection.rkt`:

```racket
(define (buffer->display-projection buffer point-byte cursor-type)
  (case (buffer-state-kind buffer)
    [(normal minibuffer fundamental) (make-text-projection (buffer-state-model buffer)
                                                            point-byte cursor-type)]
    [(terminal) (error 'buffer->display-projection "terminal provider not yet implemented")]
    [else (make-text-projection (buffer-state-model buffer) point-byte cursor-type)]))
```

`buffer-state-model` is `buffer-state.rkt:86`. This `case` is the entire
"selection" mechanism for Phase 0.5. **Extension note:** later this can become
an extension-point/parameter registry (ADR pattern) so syntax highlighting is a
*decorator* wrapping `make-text-projection` (same `line-count`/`cursor`, richer
`rendered-lines` classes) and the terminal is a sibling provider — neither a
renderer special case.

### 4.2 Where the modules live

```
weevil/private/web/projection.rkt        ; interface struct + accessors +
                                          ; cursor-pos/decoration + apply-decorations +
                                          ; buffer->display-projection dispatcher
weevil/private/web/text-projection.rkt    ; make-text-projection (the byte-identical text path)
weevil/private/web/render.rkt             ; consumes the provider (§3); owns cursor injection
```

`projection.rkt` requires `buffer-view.rkt` (for `buffer-segment`),
`buffer-state.rkt` (for `kind`/`model`), and `text-projection.rkt`.
`text-projection.rkt` requires `buffer-model.rkt`, `buffer-view.rkt`, and the
exported `split-text-lines`/`utf-8-byte-length`. The future terminal provider
lives under `weevil/private/term/` and is wired into the dispatcher's
`(terminal)` arm. **No web-layer code learns about terminals beyond that arm.**

### 4.3 Why `session-state` + `virtual-scroll` are untouched

- `compute-window` (`virtual-scroll.rkt:90`), `vs-window`, `point-line-rendered?`
  (`:139`), `point-line-visible?` (`:134`), `reanchor-scroll-top-px` (`:147`),
  `line-height-px` are **content-agnostic 1D line math** — they consume a
  `line-count` integer, which the provider supplies (identical value to
  `buffer-model-line-count` for text). No changes.
- `session-state-ensure-point-visible` (`session-state.rkt:310`) still uses
  `buffer-model-byte->line/utf16-column` + `compute-window` directly on the
  selected pane's model. The terminal will need its own line-count there
  (scrollback ring + live rows), but that is a **Phase 1** concern; Phase 0.5
  leaves it exactly as is (text buffers are unaffected).
- The `editor` / `editor__virtual` / `editor__translate` / `editor__view` /
  `editor__buffer` DOM wrapper (`render.rkt:257-273`) and all
  `data-on:scroll`/`data-effect`/`data-init` wiring are untouched — only the
  `lines` it splices change source.

---

## 5. Region/overlay decoration hook (reserved, minimal — §1.3 + §3.2)

One shared mechanism, server-owned: a `decoration` (`line start-col end-col
class`) adds a CSS class to the covered segments **at render time**, splitting
runs at codepoint boundaries (`decorate-segments`). It is:

- **Reserved, not exercised** by any Phase 0.5 provider — `decorations-proc`
  defaults to `'()`, and `apply-decorations` on `'()` returns the input list
  object, so the text golden is byte-identical.
- **Shared** by the two future consumers named in `terminal-design.md` §5.0/§5.6:
  text-buffer region highlight (`--selected` class) and terminal selection
  (`term--selected`). Both will return decorations from their provider's
  `decorations-proc`; the renderer code path is identical.
- Unit-tested now (§6.2) on a hand-built provider to prove the hook works
  without wiring it into any real provider.

`display->content-proc` is the symmetric **mouse** hook (Phase 3,
`terminal-design.md` §5.0/§5.6): maps a clicked `(line col)` back to a content
position. Reserved as `#f` in Phase 0.5; the text provider can implement it via
`buffer-model-line/utf16-column->byte` (`buffer-model.rkt`) when the
browser→server pointer path lands.

---

## 6. Test strategy

### 6.1 Render equivalence (golden) — the behaviour-preserving proof

New `tests/projection-render-golden-test.rkt`. Because the old code can't run
after the refactor, **pin** the current output first (commit A, §7), then keep
it green across the refactor.

- A **state battery** covering every text-path branch (each constructed via
  `session-state-from-text` / the minibuffer/completions helpers already used in
  `tests/web-render-test.rkt`):
  1. single line `"aλb"` point mid-line (multibyte peel);
  2. point at EOB `"ab"` (synthetic `'()` cell);
  3. multiline with empty + trailing lines `"a\n\nλb\n"`;
  4. newline-at-point `"a\nb"` (synthetic cell, line still breaks);
  5. HTML-unsafe `"<&\""` (xexpr escaping);
  6. 1000-line buffer scrolled to 4800px, view 240px — cursor **in** the
     buffered margin (drawn) and cursor at line 900 **off-window** (no cursor),
     reusing the `state-at-line` setup from `tests/web-render-test.rkt`;
  7. minibuffer active + completions (ensures non-window surfaces are untouched).
- For each, assert `(render-editor-app state)` serializes identically to a
  committed golden. Serialize with `(with-output-to-string (λ () (write (render-editor-app state))))`
  and compare to a golden string loaded with `define-runtime-path` +
  `file->string` (same mechanism as the stylesheet test in
  `tests/web-render-test.rkt`). Golden file: `tests/golden/projection-render.rktd`.
- Keep `tests/web-render-test.rkt` unchanged — its structural assertions
  (`line-tokens`, `editor__cursor`, `editor__line--active`, `editor__cursor--TYPE`,
  off-window no-cursor at line 900, 344 line divs) already encode the exact
  behaviour the refactor must preserve; they are a second, independent guard.

### 6.2 Provider-interface unit tests

New `tests/display-projection-test.rkt` (rackunit, no web server, mirrors
`tests/virtual-scroll-window-test.rkt`'s style):

- **`make-text-projection`** over a known buffer:
  - `projection-line-count` equals `buffer-model-line-count`.
  - `projection-rendered-lines 0 n` returns `n` `rendered-line?`s whose
    concatenated text equals `buffer-model-line-range-text 0 n`; one segment per
    line, classes `'()`; empty/trailing lines yield `(buffer-segment 0 0 "" '())`.
  - `projection-cursor`: correct `(line col type)` for mid-line ASCII, multibyte
    (`λ` → codepoint col), EOB, newline-at-point (`col == line-length`), empty
    buffer (`0 0`).
  - `projection-display->content` returns `#f` (reserved).
- **`apply-decorations`**: a hand-built provider returning one `decoration`
  splits the target line's segment and adds the class to the covered run; on
  `'()` returns the same list object (identity).
- **`line-pieces-with-cursor`** (export for test): for the single-segment cases
  produces piece lists equal to `projection->pieces-with-cursor` over the
  equivalent one-line projection (locks the byte-identical claim at the unit
  level, independent of the golden).

Run everything with `raco test tests` (per `CLAUDE.md`); single files with
`raco test tests/projection-render-golden-test.rkt`.

---

## 7. Commit sequence (each leaves `raco test tests` green)

1. **A — pin current output.** Add `tests/projection-render-golden-test.rkt` +
   `tests/golden/projection-render.rktd` generated from the *current*
   `render-editor-app`. Green (pins pre-refactor behaviour). No code change.
2. **B — interface + text provider, unwired.** Add
   `weevil/private/web/projection.rkt` (struct, accessors, `cursor-pos`,
   `decoration`, `apply-decorations`, `buffer->display-projection`) and
   `weevil/private/web/text-projection.rkt`; export `split-text-lines` (and
   `utf-8-byte-length` if not already) from where they live. Add
   `tests/display-projection-test.rkt`. Nothing in `render.rkt` calls the
   provider yet. Green (new tests pass; golden unchanged).
3. **C — route the window through the provider.** Rewrite
   `render-editor-window` (§3.2) + add `line-pieces-with-cursor` /
   `segment->text-piece` (§3.3); drop the direct `buffer-model` window calls
   (§3.1). Golden test + `tests/web-render-test.rkt` stay green → **byte-identical
   refactor proven**.
4. **D — reserve the hooks.** Confirm `decorations`/`display->content` are wired
   as no-ops in the render loop (apply-decorations on `'()` + cursor `#f`
   handling); add the decoration + `display->content` unit tests. Green.
5. **E — dead-code cleanup (optional).** If `render-minibuffer-input-parts` is
   the only remaining caller, keep `projection->pieces-with-cursor` etc.;
   otherwise remove the now-unused window helpers. Green.

---

## 8. Out of scope / minimality guardrails

- **No `render-terminal-pane`** and no terminal code — the `(terminal)`
  dispatcher arm errors until Phase 1.
- **No Emacs display/invisible/composition** model — only `line-count`,
  windowed `rendered-lines`, `cursor`, reserved `decorations` +
  `display->content`.
- **Minibuffer input rendering unchanged** (`render-minibuffer-input-parts`) —
  it is a single-line, non-windowed surface; routing it through a provider is a
  future option, not Phase 0.5.
- **`session-state.rkt` / `virtual-scroll.rkt` unchanged.** The provider only
  supplies the `line-count` integer they already consume.
- **CSS class mapping stays in core** (ADR.md:704); providers emit class strings
  directly; cursor `type` resolved by the caller. No options leak into the seam.
