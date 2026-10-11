# Implementation Plan — Buffer Storage: Augmented Persistent Rope (benchmark-gated swap behind `buffer-model`)

Status: proposed
Date: 2026-06-16
Scope: Replace Weevil's whole-string + dual line-index buffer storage with a
benchmarked, **augmented persistent rope** (Zed "SumTree" style) behind the
EXISTING `buffer-model` API — and make the benchmark the decision gate. The
plan ships three phases: (A) a swap seam + benchmark harness + differential/
property test scaffold (no new structure yet), (B) the rope implementation
behind the same API, (C) benchmark-driven decision with a specified piece-tree
fallback. Public/editing API, `buffer-text-state`/`buffer-state` callers,
`marker-state`, and canonical UTF-8-byte positions are all UNCHANGED, with **one
deliberate, owner-approved addition** to the frozen surface — a render-window
slice accessor (`buffer-model-line-range-text`, see Design and Finding/SHOULD-FIX
#1). No new external dependencies.

> **Output-path note (read first):** The chain footer said write to `plan.md`,
> but the primary task instruction says write to
> `plans/buffer-rope-implementation-plan.md`. On a case-insensitive macOS
> filesystem `plan.md` and the protected root `PLAN.md` are the **same inode**,
> so writing `plan.md` would clobber `PLAN.md` (the `plans/virtual-scroll-plan.md`
> header documents this exact hazard). This plan is therefore written ONLY to
> `plans/buffer-rope-implementation-plan.md`.

> **Decision discipline (read second):** This plan does NOT assume the rope
> wins. Phase B builds the rope; Phase C runs the harness from Phase A and lets
> the numbers decide between (1) ship rope, (2) ship piece-tree fallback, or
> (3) keep string for v1 spike. The thresholds are written down in Phase C
> *before* the numbers exist, per ADR "Buffer Representation and Benchmark Gate."

---

## Goal

Make per-keystroke editing and the per-render coordinate conversions
(byte↔char↔UTF-16↔line, line lookup, visible-range slice) **O(log n)** instead
of the current **O(n)** whole-buffer rebuild, by swapping the private storage
behind `weevil/private/core/buffer-model.rkt` for an augmented persistent rope —
gated on a benchmark harness and proven safe by a differential test against the
current string implementation. A required part of realizing the render win is
giving the render path an O(log n + window) slice accessor instead of
materializing the whole buffer (see SHOULD-FIX #1 below).

---

## Background facts verified in the codebase (do not re-derive)

All anchors below were read directly from the working tree on 2026-06-16.

- **`buffer-model.rkt` is the swap seam.** `(struct buffer-model (text
  line-starts line-start-bytes) #:transparent)` (buffer-model.rkt:65). The
  struct is an immutable Racket string PLUS two parallel immutable vectors:
  `line-starts` (char index of each line start) and `line-start-bytes` (byte
  offset of each line start), both length = line count.
- **The O(n) rebuild is real and per-edit.** `buffer-model-from-string`
  (buffer-model.rkt:67-85) does a single O(n) pass building both vectors. It is
  called by `buffer-model-insert` (buffer-model.rkt:176-184, via
  `string-append`+`substring`) and `buffer-model-delete`
  (buffer-model.rkt:186-203). `buffer-model-backspace` (205-211) routes through
  `-delete`. So every keystroke is O(n) string copy + O(n) index rebuild.
- **Lookups are index-assisted but sit on a wholesale-rebuilt structure.**
  `vector-floor-index` (buffer-model.rkt:87-99) is an O(log n) binary search
  over a line vector. `buffer-model-byte->char` (124-141) and
  `buffer-model-byte->line/utf16-column` (216-235) binary-search the line then
  scan within the line — O(log lines + line length). Good shape; wrong
  foundation (the vectors are rebuilt every edit).
- **Render materializes the WHOLE buffer (the headline risk — confirmed).**
  The production render path does NOT slice the storage cheaply. The only LIVE
  render-path full-materialize is at `weevil/private/web/render.rkt:227`, where
  `render-editor-window` does `(define text (buffer-model-text model))` (full
  O(n) materialize) and THEN slices the visible window by CHAR index via
  `(buffer-model-line-start-char model offset)` / `slice-end-char` and
  `(substring text slice-start-char slice-end-char)` over a LINE-range window
  (offset → end-line). So with a rope backend, this `buffer-model-text` call is a
  full O(n) materialize on every render/keystroke, **negating the rope win**
  unless the render path is switched to a slice accessor. (The
  `weevil/private/web/buffer-view.rkt:113` `editor-state->buffer-projection` →
  `(editor-state-text state)` → `buffer-model-text` (editor-state.rkt:45) path is
  presently UNCALLED — grep confirms NO live caller of `editor-state-text` /
  `buffer-view.rkt:113` / `editor-state.rkt:45` `buffer-model-text` in the tree —
  so it is NOT an active materialize today. B6 audits-and-routes it but expects
  to find no live caller.) This plan commits to fixing the live `render.rkt:227`
  materialize (SHOULD-FIX #1; Phase B5/B6).
- **`position.rkt` is pure string helpers, several O(n).** `utf-8-byte-length`
  allocates a fresh UTF-8 byte string every call (`(bytes-length
  (string->bytes/utf-8 text))`). `char-utf-8-byte-length` does this PER CHAR.
  `byte-offset->char-index`, `char-index->byte-offset`,
  `byte-offset->line/utf16-column`, `line/utf16-column->byte-offset`, and the
  word/line scanners (`word-boundary-forward/-backward`, `beginning-of-line-byte`,
  `end-of-line-byte`) are linear scans over the whole string. These are the
  conversions the rope must internalize.
- **Public error `who` symbols currently leak internal names.** Several public
  errors originate in `position.rkt` and carry internal `who` symbols:
  `raise-invalid-byte-offset`/`-char-index` (position.rkt:41-51) are called with
  `who` ∈ `{'char-index->byte-offset, 'byte-offset->char-index}` (e.g.
  position.rkt:78), and `raise-invalid-line-column` (position.rkt:200) is called
  with `'line/utf16-column->byte-offset` (position.rkt:219,232,247). These `who`
  values are visible in `exn-message`. The rope backend must reproduce them
  (see SHOULD-FIX #6 / shared error module).
- **CRLF: only LF is a line break.** The current line index counts ONLY
  `#\newline` (LF); a bare `#\return` is an ordinary character and does not start
  a line. The rope summary MUST match exactly (count only `#\newline`). A CRLF
  case is added to both corpora (SHOULD-FIX #9).
- **Public `provide` of `buffer-model.rkt` (the frozen contract surface,
  buffer-model.rkt:6-52):** `buffer-model?`, `buffer-model-from-string`,
  `make-empty-buffer-model`, `buffer-model-text`, `buffer-model-byte-length`,
  `buffer-model-valid-byte-offset?`, `buffer-model-check-byte-offset`,
  `buffer-model-byte->char`, `buffer-model-char->byte`, `buffer-model-line-count`,
  `buffer-model-line-start-char`, `buffer-model-line-start-byte`,
  `buffer-model-char->line`, `buffer-model-previous-boundary`,
  `buffer-model-next-boundary`, `buffer-model-forward-word`,
  `buffer-model-backward-word`, `buffer-model-beginning-of-line`,
  `buffer-model-end-of-line`, `buffer-model-insert`, `buffer-model-delete`,
  `buffer-model-backspace`, `buffer-model-byte->line/utf16-column`,
  `buffer-model-line/utf16-column->byte`. **Every one keeps its identical
  signature/contract.** The ONLY addition is `buffer-model-line-range-text`
  (SHOULD-FIX #1) — a deliberate, owner-approved extension of the otherwise-frozen
  surface.
- **`buffer-text-state.rkt` wraps the model** (`(struct buffer-text-state (id
  model))`), exposing `buffer-text-state-text`, `-byte-length`, and
  `buffer-text-state-with-model` (struct-copy). It only ever calls public
  `buffer-model-*`. No change needed.
- **`buffer-state.rkt` keeps text one level deeper.** `buffer-state-model`,
  `buffer-state-with-model` (buffer-state.rkt:84-92), `buffer-state-point-char`
  → `buffer-model-byte->char`. `make-buffer-state` and
  `buffer-state-with-default-view` call `buffer-model-check-byte-offset`. No
  change needed.
- **`marker-state.rkt` is storage-independent.** `marker-state-after-insert` /
  `-after-delete` adjust an external byte offset by an edit delta with Emacs
  insertion-type bias. It never touches the model. **Keep exactly as-is.**
- **Editing-API callers (must NOT change):**
  - `editor-state.rkt:83` `buffer-model-insert`, `:97` `buffer-model-backspace`,
    `:131` `buffer-model-delete` (also uses `utf-8-byte-length` from
    `position.rkt` to advance point).
  - `session-state.rkt:758-759` (`buffer-model-delete` then `-insert` to replace
    minibuffer text), `:823-825` (`buffer-model-insert` + `buffer-state-with-model`),
    `:840-841` (`buffer-model-backspace`), `:877-878` (`buffer-model-delete`),
    `:944-945` (`buffer-model-delete`).
  - **Render path (will change in Phase B6, the ONLY caller edit):**
    `render.rkt:227` (`buffer-model-text` + `substring` window — the only LIVE
    full-materialize on the render path). The `editor-state-text` materialize at
    `buffer-view.rkt:113` is presently UNCALLED (grep-confirmed no live caller);
    B6 audits-and-routes it but expects to find none.
- **Tests already contain a differential precedent.**
  `tests/buffer-model-line-index-test.rkt` has a brute-force
  `reference-line-starts` that cross-checks the index — exactly the style the
  Phase A differential scaffold generalizes. Tests run with `raco test tests`,
  and the repo convention is **`raco make weevil tests` BEFORE `raco test tests`
  every time** to avoid stale `compiled/*.zo` masking edits (see
  `plans/text-editing-motion-plan.md:249-252`, `plans/completion-system-plan.md`).
- **`Taskfile.yml` currently has only a `fmt` task** (no `test`, no `bench`).
  This plan adds both `test` and `bench` tasks (SHOULD-FIX #14, see Files to
  modify and Phase A3).
- **Deps (`weevil/info.rkt`):** `base`, `component-lib`, `koyo-lib`,
  `web-server-lib`, `datastar`; build-dep `rackunit-lib`. Adding the rope and
  harness needs only `racket/base` + existing deps. The harness needs nothing
  beyond `racket/base` (`time-apply`, `current-process-milliseconds`,
  `current-memory-use`, `collect-garbage`). `rackunit` is already a build dep
  for the differential tests.
- **Racket runtime: Racket CS v9.1 (confirmed via `racket --version` →
  `9.1 [cs]`).** Open Question #1 is resolved. (If a newer CS with a faster
  `treelist`/`bytes` path lands later, revisit the chunk-sequence experiment.)

The research brief's recommendation (augmented persistent rope; piece-tree
fallback; "treelist rope was too slow" per racket-langserver PR #201; benchmark
in Racket CS) is the authority for the Design below.

---

## Design

### Storage swap seam — keep the module-swap seam (do NOT introduce `gen:`)

**Decision: keep the existing module-level seam. `buffer-model.rkt` stays the
single public module; its provided functions ARE the storage interface.** The
concrete representation moves into private implementation modules that
`buffer-model.rkt` selects between.

Rationale (minimal, justified):
- `buffer-model?` is already an opaque predicate to every caller; nobody
  pattern-matches the struct fields outside `buffer-model.rkt`
  (`buffer-text-state`/`buffer-state` only call provided functions; grep
  confirms callers use `buffer-model-insert/-delete/-backspace` and
  `buffer-state-with-model`). So we can change the struct internals freely.
- A `gen:` interface (generic methods + a dispatching wrapper) adds an indirect
  call on every hot-path conversion and a vtable per value, for no benefit:
  there is exactly one production implementation at a time, and the differential
  harness already runs string-vs-rope side by side without needing runtime
  polymorphism in production. **Avoid the per-call dispatch cost in Racket CS.**
- Concretely: introduce a private back-end module per implementation and have
  `buffer-model.rkt` re-export the chosen one. The differential test requires
  each back-end module to expose the SAME function names, so the test can
  `require` both under prefixes and compare.

Module layout for the seam:
- `weevil/private/core/buffer-model.rkt` — unchanged public surface; becomes a
  thin re-export of the active back-end plus any back-end-independent glue. **It
  is the single production place that applies the frozen contract spec from
  `buffer-model-contract.rkt` (see "Contract placement" below).**
- `weevil/private/core/buffer-model-contract.rkt` — the SHARED frozen contract
  spec (exported `contract-out` data + a `wrap-backend` macro/function that
  applies it to a back-end's raw bindings), applied by BOTH `buffer-model.rkt`
  (production) and `bench/buffer-bench.rkt` (each dynamically-required back-end),
  so the spec lives in exactly one place and is never duplicated.
- `weevil/private/core/buffer-model-string.rkt` — the CURRENT implementation,
  extracted verbatim (string + two line vectors). This is the reference impl and
  the baseline-to-beat. Keep it forever as the differential oracle.
- `weevil/private/core/buffer-model-rope.rkt` — Phase B rope implementation.
- `weevil/private/core/buffer-model-piecetree.rkt` — Phase C fallback (only if
  the gate says so).
- `weevil/private/core/rope.rkt` — the generic augmented-rope data structure
  (node/leaf/summary), independent of the buffer-model contract; the rope-model
  is a thin adapter over it.
- `weevil/private/core/buffer-model-errors.rkt` — shared error constructors
  (extracted from `position.rkt`) so BOTH back-ends raise byte-for-byte
  identical errors (see "Error parity" / SHOULD-FIX #6).

### Back-end selection mechanism (production vs bench)

**Resolved (Open Question #3): two different mechanisms for two different
consumers.**

- **Production = compile-time/static `require` selection.** `buffer-model.rkt`
  selects the active back-end with a SINGLE plain `(require "buffer-model-<x>.rkt")`
  line in ONE place (no env var, no `dynamic-require`, no runtime indirection).
  Flipping the production default in Phase C is a one-line edit. This keeps the
  hot path fully statically resolvable/inlinable in Racket CS.
- **Bench harness = env-var / `dynamic-require` selection, ONLY in the harness.**
  `bench/buffer-bench.rkt`'s `--backend string|rope|piecetree` flag (or
  `WEEVIL_BUFFER_BACKEND`) uses `dynamic-require` to load whichever back-end
  module it is measuring. This indirection lives entirely in the bench runner and
  never touches the production path.

This removes the earlier contradiction between "compile-time swap" and "env var":
production is static; A/B benchmarking is dynamic and confined to the harness.

### Contract placement (single frozen contract spec, no double-contracting)

**Resolved (SHOULD-FIX #3).** Back-end modules
(`buffer-model-string.rkt`, `buffer-model-rope.rkt`, `buffer-model-piecetree.rkt`)
export **raw, uncontracted** functions (plain `provide` of the function names).
The frozen contract spec lives in ONE shared module
`buffer-model-contract.rkt`, which EXPORTS the spec (the per-function
`contract-out` data plus a `wrap-backend` macro/function that applies it to a
back-end's raw bindings). `buffer-model.rkt` re-exports the active back-end and
applies that shared spec as the **single, frozen** public contract surface; the
bench harness applies the SAME spec to each dynamically-required back-end (see
A3), so neither place duplicates the spec. Consequences:

- The hot path is contracted **exactly once** (at the public boundary), never
  double-wrapped — a back-end that internally called another back-end function
  would otherwise pay the contract twice.
- The benchmark measures the **contracted public path**: it wraps each
  dynamically-required back-end with the shared `buffer-model-contract.rkt` spec
  (the same one `buffer-model.rkt` applies in production), so a raw
  dynamically-loaded back-end is never measured uncontracted — bench numbers are
  production-representative rather than measuring raw internals, with no
  duplicated spec.
- The differential test may import raw back-end functions under prefixes for
  speed, but at least one pass must exercise the contracted public `buffer-model.rkt`
  surface so contract behavior (including error `who`) is covered.

### Data model — augmented persistent rope (`rope.rkt`)

A B+-tree of bounded UTF-8 string chunks. Internal nodes hold children +
aggregate summaries; leaves hold one immutable Racket string chunk + its
summary. All nodes are immutable structs; edits rebuild O(log n) nodes on the
path and share the rest (persistence ⇒ O(1) snapshot = share the root).

```racket
;; rope.rkt
;; Summary pruned to the MINIMAL fields actually consumed (SHOULD-FIX #8, #12).
(struct summary
  (utf8           ; exact-nonnegative-integer? : UTF-8 byte length of subtree
   chars          ; exact-nonnegative-integer? : codepoint count of subtree
   utf16          ; exact-nonnegative-integer? : UTF-16 code-unit length of subtree
   newlines       ; exact-nonnegative-integer? : count of #\newline (LF only) in subtree
   last-line-utf16) ; utf16 units AFTER the subtree's last newline (for column math)
  #:transparent)

(struct leaf (str sum) #:transparent)            ; str : immutable string chunk
(struct branch (children sum height) #:transparent) ; children : (vectorof node)
```

**Pruned/removed fields and why (SHOULD-FIX #8, #12):**
- Removed `first-line-chars/-utf16/-utf8` and `last-line-chars/-utf8`: the review
  confirms these are **not consumed** by any conversion. byte/char/utf16/line
  seeks use `utf8`/`chars`/`utf16`/`newlines`; the only per-line partial actually
  read is `last-line-utf16` (for the UTF-16 *column* in
  `byte->line/utf16-column`). Within-leaf walks compute byte/char column locally,
  so no `last-line-chars/-utf8` summary field is needed.
- **Removed `longest-line-utf16` (resolves Open Question #6).** No public API
  exposes a longest-line / max-row width, so it is uncovered by the differential
  test, and its merge has a non-obvious, dangerous boundary term (see equations
  below). Per the review we DROP it until the horizontal-scroll/longest-row
  feature actually exists. If re-added later, it requires re-introducing
  `first-line-utf16` (needed only for its boundary term) and the documented merge
  rule.

**Summary is a monoid — the EXACT merge rules (SHOULD-FIX #5).**
`summary-empty = (summary 0 0 0 0 0)`. `leaf->summary` scans the (short) chunk
once, counting bytes/chars/utf16 and `#\newline`s, and tracking `last-line-utf16`
= utf16 units since the chunk's last `#\newline` (or the whole chunk's utf16 if
it has none). `summary-append` (associative; left arg `l`, right arg `r`):

```racket
(define (summary-append l r)
  (summary
   (+ (summary-utf8     l) (summary-utf8     r))
   (+ (summary-chars    l) (summary-chars    r))
   (+ (summary-utf16    l) (summary-utf16    r))
   (+ (summary-newlines l) (summary-newlines r))
   ;; utf16 units after the LAST newline of the COMBINED subtree:
   (if (> (summary-newlines r) 0)
       (summary-last-line-utf16 r)               ; r has a newline -> last line lives entirely in r
       (+ (summary-last-line-utf16 l)            ; r has NO newline -> r extends l's last line
          (summary-last-line-utf16 r)))))        ; (note: r.last-line-utf16 == r.utf16 when r.newlines = 0)
```

Branch summary = fold `summary-append` over children (left to right). Because
the merge is order-sensitive at the line boundary, **associativity must be
tested directly** — add a `rope.rkt` unit test asserting
`(summary-append a (summary-append b c)) = (summary-append (summary-append a b) c)`
over random summaries, since NO public API would otherwise reveal a bad
`last-line-utf16` merge.

> **Documented-but-deferred longest-line merge (for if/when it returns).** The
> dangerous boundary term is:
> `longest-line-utf16 = max(l.longest-line-utf16, r.longest-line-utf16,
>                           l.last-line-utf16 + r.first-line-utf16)`
> i.e. the line that straddles the l/r boundary can be longer than any line
> wholly inside l or r. This is precisely why it needs `first-line-utf16` and is
> easy to get wrong — and why it's excluded until a feature consumes it.

- `leaf->summary` computes a leaf's summary in one pass over its (short) chunk.
  This summary is the single source of truth that REPLACES both `line-starts` /
  `line-start-bytes` vectors AND the `position.rkt` scans.
- **Chunk-size parameter.** `(define max-chunk-bytes 1024)` and
  `(define min-chunk-bytes 512)` as starting values (research: Zed ~128 chars,
  ropey ~1KB; Racket per-char ops are dear, so start larger and tune by
  benchmark). Branching factor `(define max-children 16)` / `min-children 8`.
  ALL of these are top-level constants explicitly tuned in Phase C.
- **Chunk-byte budget is char-atomic (SHOULD-FIX #10).** `max-chunk-bytes` is an
  *approximate* budget: a chunk is NEVER split mid-codepoint, so a leaf may
  slightly exceed `max-chunk-bytes` when the boundary falls inside a multibyte
  char — the budget is a target, and chunk sizes are only approximate near the
  max. Splitting always lands on a char boundary.
- **Codepoint-boundary safety.** A chunk is split only on a UTF-8 codepoint
  boundary; since leaves hold Racket strings (sequences of chars, never partial
  codepoints), splitting at a char index is automatically codepoint-safe. When
  combining/normalizing byte offsets at the rope API edge, snap/validate exactly
  as `position.rkt` does today (`check-byte-offset` semantics preserved).
- **Cursor / seek (the O(log n) engine).** Implement a `rope-seek` that descends
  the tree accumulating a running summary, targeting ONE dimension (byte, char,
  utf16, or line) and returning the leaf + in-leaf offset + accumulated summary
  in the OTHER dimensions. Every conversion below is one `rope-seek`:
  - `byte->char`: seek to byte offset; accumulated `chars` + in-leaf char count.
  - `char->byte`: seek to char index; accumulated `utf8` + in-leaf byte count.
  - `byte->line/utf16-column`: seek to byte; `newlines` gives line; column =
    running utf16 since the last newline (carried by the seek accumulator using
    the `last-line-utf16` partials of fully-traversed left siblings) + in-leaf
    utf16 since the last newline.
  - `line/utf16-column->byte`: seek to newline #line, then walk utf16 columns
    within that line to the byte.
  - `line-count` = `(add1 newlines)` of root; `line-start-byte`/`-char` = seek to
    newline #N.
- **Edits.**
  - `rope-insert(rope, byte, str)`: seek to byte → split target leaf → build new
    leaf(s) for the inserted text (splitting into ≤ `max-chunk-bytes` chunks,
    char-atomic) → rebuild the spine → rebalance (B+-tree split/merge to keep
    `min..max-children`). O(log n + m) for m inserted bytes.
  - `rope-delete(rope, start, end)`: seek both ends → drop interior leaves →
    trim boundary leaves → rebuild spine → rebalance. O(log n + range).
  - `rope-slice(rope, start-byte, end-byte) -> string`: seek + concatenate
    boundary partials with interior leaf strings. O(log n + range). This is the
    visible-range render path AND `buffer-model-text` (full slice) AND the
    `buffer-model-line-range-text` accessor below.
- **Self-insert coalescing.** Track the most-recently-touched ("active") leaf
  (e.g. carry an optional `active-byte`/`active-leaf` hint on the rope-model
  wrapper, NOT inside the pure tree). When the next insert is a single char
  contiguous to the previous insert and the active leaf has room
  (`< max-chunk-bytes`), append into a freshly-built copy of that leaf instead
  of allocating a new node — so typing a word touches O(1) leaves, not one per
  keystroke. Mirrors the ADR's `self-insert` undo coalescing. Coalescing is an
  optimization only: results MUST be identical to non-coalesced (the differential
  test enforces this).

### Render-window slice accessor (`buffer-model-line-range-text`) — SHOULD-FIX #1

**Decision: commit to realizing the rope's render win.** Add ONE function to the
frozen public surface (deliberate, owner-approved):

```racket
;; buffer-model-line-range-text : buffer-model? exact-nonnegative-integer?
;;                                exact-nonnegative-integer? -> string?
;; Returns the text of lines [start-line, end-line), EXCLUDING the trailing
;; #\newline that separates line (end-line - 1) from line end-line. When
;; end-line >= line-count, returns through end-of-buffer.
;; Contract: 0 <= start-line <= end-line <= (buffer-model-line-count model).
(buffer-model-line-range-text model start-line end-line)
```

Semantics chosen to match EXACTLY what `render.rkt:227` computes today:
`[line-start-char(start-line), (if (< end-line line-count)
(sub1 (line-start-char end-line)) total-char-length)]`. Equivalently a single
`rope-slice` over the corresponding byte range — O(log n + window) on the rope,
O(window) `substring` on the string backend.

**Why line-range, not a char-range `buffer-model-slice` (justification).** The
render path is line-range native (it picks a window `offset → end-line` and
already needs the line→byte/char mapping). A `buffer-model-line-range-text`
accessor lets the model do ONE descent to resolve both line boundaries and
return the window string, instead of the caller doing two `line-start-char`
lookups plus a `substring`. It keeps the trailing-newline-drop rule (which is
render-specific) inside the model where the rope can satisfy it from a single
seek. (A general char-range `buffer-model-slice` was the alternative; we prefer
the line-range form because it maps 1:1 onto the only caller that needs it.)

The string backend implements it as `substring` over the same char range (so
behavior is identical and the differential test covers it). `buffer-model-text`
is RETAINED for the save/serialize path only (full materialize is O(n) by
definition there).

### Rope buffer-model adapter (`buffer-model-rope.rkt`)

A `buffer-model` value becomes `(struct buffer-model (rope) #:transparent)` (or
keep the name `buffer-model` and store the rope). Map EACH public function:

| Public `buffer-model-*` | Rope implementation |
| --- | --- |
| `buffer-model?` | struct predicate |
| `buffer-model-from-string` | chunk the string into ≤`max-chunk-bytes` (char-atomic) leaves, bulk-build a balanced tree (bottom-up), wrap |
| `make-empty-buffer-model` | single empty leaf rope |
| `buffer-model-text` | `rope-slice` over the whole rope (full materialize; SAVE/serialize path only — O(n) by definition) |
| `buffer-model-line-range-text` | `rope-slice` over the byte range of lines `[start-line, end-line)` minus the trailing newline (render-window path; O(log n + window)) |
| `buffer-model-byte-length` | root `summary-utf8` (O(1)) |
| `buffer-model-valid-byte-offset?` | seek to byte; valid iff it lands on a leaf char boundary (O(log n)) |
| `buffer-model-check-byte-offset` | as above, raise via shared error module on failure (identical `who`/fields) |
| `buffer-model-byte->char` | `byte->char` seek |
| `buffer-model-char->byte` | `char->byte` seek |
| `buffer-model-line-count` | `(add1 (summary-newlines root))` |
| `buffer-model-line-start-char` | seek to newline #line, return accumulated chars |
| `buffer-model-line-start-byte` | seek to newline #line, return accumulated utf8 |
| `buffer-model-char->line` | `char->...` seek, return accumulated newlines |
| `buffer-model-previous-boundary` | seek to byte, step one char left |
| `buffer-model-next-boundary` | seek to byte, step one char right |
| `buffer-model-forward-word` / `-backward-word` | seek to byte, then walk chars across leaves applying the same `default-word-char?` predicate (keep the `#:word-char?` seam available internally; public model fns have fixed signatures) |
| `buffer-model-beginning-of-line` / `-end-of-line` | use `newlines`/line-start seeks + within-line walk |
| `buffer-model-insert` | `rope-insert` (+ coalescing hint); preserve empty-insert short-circuit and `check-byte-offset` |
| `buffer-model-delete` | `rope-delete`; preserve start≤end check + empty-range short-circuit + identical error messages |
| `buffer-model-backspace` | `(values (delete prev point) prev)` exactly as today |
| `buffer-model-byte->line/utf16-column` | combined line+utf16 seek |
| `buffer-model-line/utf16-column->byte` | line seek + within-line utf16 walk; preserve the three `raise-invalid-line-column` error conditions (past EOL, inside multi-unit char, no such position) |

### Error parity (SHOULD-FIX #6)

**Decision: option (a) — share error constructors in a common module both
back-ends call, reproducing the CURRENT `who`/fields.** Extract
`raise-invalid-byte-offset`, `raise-invalid-char-index`, and
`raise-invalid-line-column` from `position.rkt` into
`buffer-model-errors.rkt` (or re-provide them from there), preserving the exact
`who` symbols the public functions pass today (e.g. `'char-index->byte-offset`,
`'byte-offset->char-index`, `'line/utf16-column->byte-offset`) and the exact
field lists/messages. Both the string and rope back-ends call these shared
constructors, so errors are byte-for-byte identical. The differential test then
compares the FULL `exn-message` (predicate + message + fields) — not just the
predicate. This keeps test and impl consistent and avoids each backend
re-deriving `who` strings. (Option (b) — normalize `who` to the public name and
compare on predicate + key fields only — is explicitly NOT chosen.)

### Undo integration (scope, deferred per ADR)

The ADR says full undo impl can be deferred; ownership is server-side,
command-granularity. This plan does NOT build the undo stack. It only ensures
the storage SUPPORTS cheap undo: because the rope is persistent, retaining the
previous root reference is an O(1) snapshot, and `buffer-state-with-model`
already threads whole models. Document that a future undo subsystem can store
either prior roots (structural sharing) or inverse edits; no storage change is
needed when undo lands. Out of scope here beyond a one-paragraph note + a
`bench` case that simulates "keep N prior snapshots alive" to measure retained
memory.

---

## Phased rollout

### Phase A — Storage seam + benchmark harness + differential/property scaffold (ships FIRST, before any new structure)

A1. **Extract the current impl to a back-end module.** Create
   `buffer-model-string.rkt` containing today's `buffer-model.rkt` body verbatim
   (struct + all functions), exporting them **raw/uncontracted** (plain
   `provide`). Add `buffer-model-string-line-range-text` (the string `substring`
   form of the new accessor). Reduce `buffer-model.rkt` to: a single static
   `require` of the active back-end + the shared frozen contract spec from
   `buffer-model-contract.rkt` applied as the public re-export (now including
   `buffer-model-line-range-text`). Acceptance:
   `raco make weevil tests && raco test tests` green with zero behavior change
   (existing `buffer-model-*` and line-index tests pass untouched).

A2. **Define the back-end contract doc + the shared contract spec.** Create
   `buffer-model-contract.rkt` exporting the frozen contract spec (the
   per-function `contract-out` data + a `wrap-backend` macro/function). In
   `buffer-model.rkt`, add a module comment listing the exact function set each
   back-end must provide (the frozen `provide` list above plus
   `buffer-model-line-range-text`) as RAW/uncontracted functions, and stating
   that the contract spec lives ONLY in `buffer-model-contract.rkt` and is
   applied by both `buffer-model.rkt` (production) and the bench harness. No code
   behavior change. Also extract the shared error constructors into
   `buffer-model-errors.rkt` (SHOULD-FIX #6) and have the string back-end call
   them (behavior-identical).

A3. **Benchmark harness.** New dir `bench/` with `bench/buffer-bench.rkt`
   (runner) + `bench/corpus.rkt` (synthetic input generators). Specify:
   - **Inputs / sizes:** generate UTF-8 corpora at **1 MB, 10 MB, 100 MB**
     (ADR gate). Variants: (a) typical source (≈40–80 col lines, mixed ASCII +
     some multibyte), (b) ONE pathological very-long line (single line near the
     whole size, no newlines), (c) many short lines, (d) a **CRLF** corpus
     (`\r\n` line endings) to confirm only LF counts as a break (SHOULD-FIX #9).
     Generators are deterministic (seeded `make-pseudo-random-generator`) so runs
     are comparable.
   - **Backend selection:** the harness chooses a back-end via `--backend
     string|rope|piecetree` (or `WEEVIL_BUFFER_BACKEND`) using `dynamic-require`,
     then wraps the raw back-end with the shared `buffer-model-contract.rkt` spec
     (the SAME spec `buffer-model.rkt` applies in production) so it measures the
     production-representative contracted path without duplicating the spec
     (Contract placement, above). A raw, unwrapped back-end is never measured.
   - **Operations measured (the ADR gate list + Weevil hot paths):**
     1. `load/open` — `buffer-model-from-string` on each corpus.
     2. `insert-char-at-point` — single-char insert at a fixed mid-buffer byte.
     3. `type-word` — run of ~5–10 contiguous single-char inserts (exercises
        coalescing).
     4. `scattered-insert` — N single-char inserts at random valid byte offsets.
     5. `delete-char` and `backward-delete-word` (`-backspace` + word scan).
     6. `delete-range` — delete a mid-buffer span.
     7. `large-paste` — insert a 64 KB / 1 MB block (bulk path).
     8. `line-N-lookup` — `buffer-model-line-start-byte`/`-char` for random N.
     9. `conversions` — `byte->char`, `char->byte`, `byte->line/utf16-column`,
        `line/utf16-column->byte` at random valid positions.
     10. `slice` — `buffer-model-line-range-text` for a ~60-line render window
         (rope: `rope-slice`; string: `substring`). **This op measures the
         path production actually uses after the Phase B6 render switch**, so the
         "rope wins" claim is gated on the real render path (SHOULD-FIX #1).
     11. `undo-retain` — perform K edits keeping all prior models referenced;
         measure peak `current-memory-use`.
     12. `serialize` — `buffer-model-text` (model → string, the save path).
   - **Edit PATTERNS:** localized typing (3), scattered edits (4), one
     pathological long line (corpus b), large paste (7).
   - **Which ops are timed individually vs batched (SHOULD-FIX #4).** At 10 MB,
     ops whose single-shot cost is comfortably ABOVE the process-timer resolution
     — `load/open`, `large-paste`, `delete-range` (large span), `serialize`, and
     (for the string backend) `insert-char-at-point`/`delete-char` — are timed
     **individually**, one `time-apply` per op, and reported as median/p95 over
     ≥30 iterations. Ops that are sub-resolution per call at 10 MB on the rope —
     `insert-char-at-point`, `delete-char`, `backspace`, all `conversions`,
     `line-N-lookup`, boundary steps, and `slice` — are **batched**: M calls
     inside ONE `time-apply`, yielding a **per-batch MEAN** (= batch-cpu/M). We
     then collect ≥30 such batch means and report **median + p95 over the batch
     means** (so "p95" is the 95th percentile of per-batch means, not of single
     calls). This reconciles the earlier "median + p95 over ≥30 iters" wording:
     individually-timed ops → percentiles over single-op times; batched ops →
     percentiles over batch means. M is chosen per op/size so each batch runs
     ≳ 50× the timer resolution. **Cross-backend caution:** because string ops
     may be timed individually (p95 over single-op times) while the SAME ops on
     the rope are batched (p95 over batch means), the two p95 columns are
     DIFFERENT statistics and MUST NOT be compared directly across backends —
     cross-backend comparison relies on MEDIANS and on the growth-vs-size shape,
     not on lining up p95 columns.
   - **State threading per op (SHOULD-FIX #4).** `insert-char-at-point` runs
     against a FIXED base model at a known size — each iteration inserts into the
     SAME base (non-threaded), isolating per-op cost and keeping buffer size
     constant across the batch. `delete-char`/`backspace` likewise run against a
     fixed base. By contrast `type-word`, `scattered-insert`, and any coalescing
     measurement MUST **thread state** (each edit produces the model the next
     edit consumes), since coalescing and growth depend on the running model.
     `undo-retain` threads AND retains every intermediate root.
   - **Timing/memory in Racket CS:** wrap each measured unit in
     `(collect-garbage)`×2 → record `(current-memory-use)` baseline →
     `time-apply` (returns cpu/real/gc ms); ≥5 warmup iterations before the ≥30
     measured ones (warmup JIT + tree shape). Record `(current-memory-use)` after
     a forced GC for memory rows, plus the gc-ms from `time-apply`.
   - **Output:** print a table (op × size × backend) of median/p95 ms and
     bytes; also write a machine-readable `.rktd`/CSV under `bench/results/`
     for the Phase C decision record.
   - **Run target:** add a `bench` task to `Taskfile.yml`:
     `raco make weevil bench && racket bench/buffer-bench.rkt`
     (with flags `--size 1m|10m|100m`, `--backend string|rope|piecetree`,
     `--only <op>`). 100 MB run is opt-in (slow/memory) and gated behind
     `--size 100m`. Also add a `test` task wrapping
     `raco make weevil tests && raco test tests` (Taskfile currently has only
     `fmt`).
   - Acceptance: harness runs end-to-end against the `string` backend at 1 MB
     and 10 MB and emits a results table; 100 MB runs without OOM on the dev
     box (or documents the limit).

A4. **Differential / property test scaffold.** New
   `tests/buffer-model-differential-test.rkt` (rackunit + a small hand-rolled
   randomized loop; no new dep). It:
   - `require`s both back-ends under prefixes (`str:` and `rope:`/`pt:`). **This
     works because each back-end module defines its OWN `struct buffer-model`,
     yielding DISTINCT opaque predicates** — `str:buffer-model?` and
     `rope:buffer-model?` are different — and each back-end's functions are only
     ever called with their own values, so there is no cross-contamination
     (SHOULD-FIX #15). When a candidate back-end does not yet exist (Phase A), it
     diffs `string` against itself via the public API as a smoke harness and is
     wired to add the rope in Phase B.
   - Generates a random seeded edit sequence (mix of insert/delete/backspace at
     random valid byte offsets, with multibyte chars, newlines, **CRLF runs**
     (SHOULD-FIX #9), empty edits, boundary positions 0 and byte-length, and one
     very-long-line case).
   - After EACH edit asserts the two impls agree on: `buffer-model-text`
     (identical string), `buffer-model-line-range-text` (identical window string
     over a sweep of line ranges, incl. the trailing-newline-drop edge), AND
     every conversion/scanner in the API at a sweep of positions — `byte->char`,
     `char->byte`, `byte->line/utf16-column`, `line/utf16-column->byte`,
     `line-count`, `line-start-char/-byte`, `char->line`, `previous-/next-boundary`,
     `forward-/backward-word`, `beginning-/end-of-line`, `byte-length`,
     `valid-byte-offset?` — and that error CASES raise the SAME error
     (full `exn-message` compare, per the shared error module) on the same inputs
     (invalid offsets, mid-codepoint, past-EOL columns).
   - **Position sweep (SHOULD-FIX #11):** for SMALL buffers, EXHAUSTIVELY sweep
     EVERY valid byte boundary (0..byte-length, snapping over multibyte chars)
     for the conversions; for large buffers, SAMPLE a fixed random/representative
     set (including 0, byte-length, and around newlines/multibyte chars).
   - A separate property block reuses the existing brute-force oracle style from
     `tests/buffer-model-line-index-test.rkt` (`reference-line-starts`) as a
     third independent check on line indexing.
   - Acceptance: `raco test tests/buffer-model-differential-test.rkt` green
     against `string`-vs-`string` now; becomes the correctness gate for Phase B.

### Phase B — Implement the augmented persistent rope behind the same API

B1. **`rope.rkt` core.** Implement `summary` monoid (`summary-empty`,
   `leaf->summary`, `summary-append` per the EXACT equations above),
   `leaf`/`branch` structs, bulk build (`string->rope`), `rope-seek` (the
   multi-dimension cursor), `rope-insert`, `rope-delete`, `rope-slice`,
   rebalancing (B+-tree split/merge on `min/max-children`, leaf split/merge on
   `min/max-chunk-bytes`, char-atomic). Unit-test `rope.rkt` in isolation
   (`tests/rope-test.rkt`): build/slice round-trips, summary correctness vs
   brute force, **summary associativity (`summary-append`) over random
   summaries** (SHOULD-FIX #5 — since no public API reveals a bad
   `last-line-utf16` merge), seek correctness, balance invariants after many
   random edits, and a CRLF case (only LF counts). Acceptance: rope unit tests
   green.

B2. **`buffer-model-rope.rkt` adapter.** Implement every public `buffer-model-*`
   (plus `buffer-model-line-range-text`) per the mapping table, exporting RAW
   functions, preserving signatures, short-circuits, and EXACT error
   conditions/messages via the shared `buffer-model-errors.rkt`. Acceptance: it
   satisfies the back-end contract (A2).

B3. **Wire the differential test to the rope.** Flip the differential scaffold
   to diff `string` vs `rope`. Fix until green across all generated sequences
   and sizes (incl. exhaustive small-buffer byte sweep and CRLF). This is the
   gate that proves the swap is safe. Acceptance: `raco test tests` fully green
   with the differential test diffing string vs rope.

B4. **Coalescing.** Add the active-leaf coalescing hint to the rope-model
   wrapper for contiguous single-char inserts. Acceptance: differential test
   still green (coalescing must be behavior-transparent); `type-word` bench
   shows fewer allocations / lower per-char time than non-coalesced.

B5. **Keep `string` backend as the default in production** until Phase C
   decides. (Differential test + bench can target rope without flipping prod.)

B6. **Switch the render path to the slice accessor (REQUIRED before the Phase C
   "rope wins" claim).** The required fix is the LIVE materialize at
   `render.rkt:227`: change `render-editor-window` to use
   `buffer-model-line-range-text model offset end-line` instead of
   `buffer-model-text` + `substring`, and keep using `buffer-model-line-start-byte`
   for point rebasing. Also audit the `editor-state-text` →
   `buffer-model-text` path at `buffer-view.rkt:113` and route it away from a
   full materialize — but note it is presently UNCALLED (grep-confirmed no live
   caller of `editor-state-text` in the tree), so this is an audit-and-route step
   expected to find NO live caller (don't leave a hidden whole-buffer
   materialize if a caller is later added); reserve `buffer-model-text` for
   save/serialize. Acceptance: existing render/virtual-scroll tests stay green;
   the `slice` bench op exercises this exact path. **This step gates the Phase C
   "rope wins" decision** — the benchmark must measure the path production
   actually uses.

### Phase C — Benchmark, decide, and (conditionally) the piece-tree fallback

C1. **Run the gate.** Execute the harness for `string` vs `rope` at 1/10/100 MB
   across all ops/patterns (including the `slice` op against the post-B6 render
   path); capture `bench/results/`.

C2. **Decision criteria — RELATIVE IMPROVEMENT over the current string
   baseline, not absolute numbers.** We deliberately do NOT pin absolute
   millisecond/× targets now (premature guessing). The string impl runs in the
   SAME harness as the control, and the rope wins on its merits if it
   measurably improves the things that hurt today without unacceptably
   regressing the rest. "How fast is fast enough" in absolute terms is deferred
   until there are real numbers to look at (and to the owner).
   - **Statistic-comparability caveat (read first).** When a single-char op is
     timed individually on `string` but batched on `rope` (A3), their p95
     columns are DIFFERENT statistics — compare backends on MEDIANS and on the
     growth-vs-size shape, never by lining up p95 columns directly.
   - **Ship the rope** when, measured against the string baseline in the same
     harness:
     - **Per-keystroke scaling improves in shape.** The string's single-char
       insert / delete / backspace cost grows ~linearly with buffer size (the
       1→10→100 MB rows climb roughly with size); the rope's must be
       *substantially flatter* — i.e. close to constant across the size steps,
       the O(log n) signature. The point is the SHAPE (flat vs linear), proven
       by the size sweep, not a fixed millisecond number.
     - **The per-render work that is O(n) today gets cheaper at scale.** The
       conversions (byte↔char↔utf16↔line), line lookup, and the `slice` render
       window (`buffer-model-line-range-text`, the path render uses after B6)
       should be roughly size-independent / log-scaling on the rope, versus the
       string's growth — a clear improvement on the larger corpora.
     - **Snapshots are cheap.** `undo-retain` peak memory for K live snapshots
       is far below K×buffer (structural sharing working) — an improvement that
       the string cannot match.
     - **No unacceptable regression on the non-hot-path ops.** `load/open` and
       `serialize` (not per-keystroke) may cost somewhat more than the raw
       string; that is acceptable as long as it is a modest, bounded overhead
       and not a new scaling problem. If the rope were SLOWER than the string
       on the per-keystroke / scaling axes, that is a fail.
   - **Trigger the piece-tree fallback (C3)** if the rope CLEARS correctness
     (B3 green) but does NOT actually improve over the string in Racket CS —
     specifically if per-keystroke ops are not meaningfully flatter than the
     string's linear growth (constant factors swamp O(log n)) or memory is
     worse — mirroring the racket-langserver "treelist rope too slow" outcome.
   - **Keep `string` for the spike only** if BOTH rope and piece-tree fail to
     improve over it (record as a blocker, not a v1 ship).
   - Whatever ships, the measured numbers are recorded in `bench/results/` and
     are what later set any PUBLIC large-file claims (C4) — that is the right
     time to discuss absolute targets, with data in hand.

C3. **Piece-tree fallback design (implement only if C2 says so).**
   `buffer-model-piecetree.rkt` + `piece-tree.rkt`:
   - **Two byte sources:** `original` (immutable bytes of the loaded file/string,
     read-only) + append-only `add` buffer (a growable byte string the editor
     appends typed text to; never mutated in place, only appended).
   - **Pieces:** `(struct piece (source start length))` where `source` ∈
     `{original, add}`. The document is an ordered sequence of pieces.
   - **Balanced tree keyed on subtree metadata** (VS Code piece tree): a balanced
     BST (red-black or weight-balanced) whose per-node summary carries the SAME
     metrics as the rope summary — utf8 length, **char length**, **utf16 length**,
     newline count (LF only), and the `last-line-utf16` partial — so
     byte↔char↔utf16↔line conversions are O(log P), not just offset+linebreak.
     This is the "extra metadata beyond VS Code's default" the research brief
     calls out.
   - **Consecutive insert extension:** a single-char insert that is contiguous
     with the trailing add-buffer piece extends that piece's length instead of
     creating a new piece (the piece-tree analog of leaf coalescing).
   - **Periodic coalescing/compaction:** when piece count P crosses a threshold
     (e.g. relative to document length), rebuild a compacted add buffer +
     fewer pieces to fight fragmentation (research: ocaml-piecerope note).
   - Same public `buffer-model-*` mapping (incl. `buffer-model-line-range-text`
     and the shared error module); run it through the SAME differential test
     (add a `pt:` prefix) and the SAME harness. Decide rope vs piece-tree on the
     numbers.

C4. **Flip the default + set claims.** Change the single static `require` in
   `buffer-model.rkt` to the winning back-end. Record the gate results in
   `bench/results/` and update the ADR's large-file claims from the measured
   numbers (the ADR explicitly defers public large-file guarantees to "after
   benchmarks" — this is where they get set). Acceptance: full suite + bench
   green; default backend is the winner; `string` backend retained as the
   differential oracle.

---

## Testing strategy

- **Differential (primary correctness gate):**
  `tests/buffer-model-differential-test.rkt` runs random seeded edit sequences
  against `string` (oracle) and the candidate, asserting identical text,
  identical `buffer-model-line-range-text` windows, AND identical results/errors
  (full `exn-message`) for every public conversion/scanner after each edit, with
  an EXHAUSTIVE byte-boundary sweep for small buffers and sampling for large
  (Phase A scaffold; Phase B wires the rope; Phase C adds piece-tree). Covers
  CRLF (LF-only line counting).
- **Property checks:** balance invariants (`min..max-children`,
  `min..max-chunk-bytes` char-atomic, codepoint-boundary leaves), summary
  correctness vs a brute-force recompute over the materialized string,
  **`summary-append` associativity over random summaries** (since no public API
  exposes the `last-line-utf16` merge), round-trip
  `string->rope->text = identity`. Reuse the `reference-line-starts` oracle from
  `tests/buffer-model-line-index-test.rkt`.
- **Existing tests unchanged:** `tests/buffer-model-line-index-test.rkt`,
  `tests/core-buffer-text-state-test.rkt`, and all callers' tests must stay green
  with zero edits — proof the seam held. (Render/virtual-scroll tests stay green
  across the B6 slice-accessor switch.)
- **Benchmark (decision gate):** `bench/buffer-bench.rkt` per Phase A3; results
  archived under `bench/results/` and cited in the Phase C decision. The `slice`
  op measures the post-B6 render path.
- **Run convention:** `raco make weevil bench tests && raco test tests` (always
  `raco make` first to avoid stale `.zo`); `task test` and `task bench` once the
  Taskfile tasks are added.

---

## Files to modify

- `weevil/private/core/buffer-model.rkt` — reduce to a single static `require`
  of the active back-end + apply the shared frozen contract spec from
  `buffer-model-contract.rkt` as the public re-export (now including
  `buffer-model-line-range-text`); add back-end contract doc comment; flip the
  static require to the winner in Phase C. **Public surface unchanged
  except the one owner-approved `buffer-model-line-range-text` addition.**
- `weevil/private/core/position.rkt` — extract the three error constructors into
  the shared `buffer-model-errors.rkt` (or re-export from it), preserving exact
  `who`/fields/messages. (No behavior change for existing callers.)
- `weevil/private/web/render.rkt` — Phase B6: `render-editor-window`
  (`:227`) switches from `buffer-model-text` + `substring` to
  `buffer-model-line-range-text` for the visible window (keep
  `buffer-model-line-start-byte` for point rebasing). This is the ONLY live
  full-buffer materialize on the render path.
- `weevil/private/web/buffer-view.rkt` — Phase B6: audit the
  `editor-state-text`/`buffer-model-text` path at `:113` (presently UNCALLED —
  grep-confirmed no live caller) and route it away from a full materialize;
  audit-and-route expected to find no live caller.
- `Taskfile.yml` — add a `test` task (`raco make weevil tests && raco test
  tests`) and a `bench` task (`raco make weevil bench && racket
  bench/buffer-bench.rkt`). (Currently only `fmt` exists.)
- `ADR.md` — Phase C only: set large-file claims from measured numbers under
  "Buffer Representation and Benchmark Gate" (no API/decision changes).
- (No changes to `buffer-text-state.rkt`, `buffer-state.rkt`, `marker-state.rkt`,
  `editor-state.rkt`, `session-state.rkt` — verified callers only use the public
  API.)

## New files

- `weevil/private/core/buffer-model-string.rkt` — current impl extracted verbatim
  (reference oracle + baseline), exporting raw/uncontracted functions + the
  string `buffer-model-line-range-text`.
- `weevil/private/core/buffer-model-contract.rkt` — the SHARED frozen contract
  spec (exported `contract-out` data + a `wrap-backend` macro/function) applied
  by BOTH `buffer-model.rkt` (production) and `bench/buffer-bench.rkt` (each
  dynamically-required back-end), so the spec lives in exactly one place
  (SHOULD-FIX #3, contract-wrapping seam for the bench harness).
- `weevil/private/core/buffer-model-errors.rkt` — shared error constructors
  (extracted from `position.rkt`) so both back-ends raise byte-for-byte identical
  errors (SHOULD-FIX #6).
- `weevil/private/core/rope.rkt` — generic augmented persistent rope
  (summary monoid, leaf/branch, seek, insert/delete/slice, rebalance).
- `weevil/private/core/buffer-model-rope.rkt` — rope adapter implementing the
  `buffer-model-*` contract (raw/uncontracted).
- `weevil/private/core/piece-tree.rkt` — (Phase C, conditional) generic piece
  tree.
- `weevil/private/core/buffer-model-piecetree.rkt` — (Phase C, conditional)
  piece-tree adapter.
- `bench/buffer-bench.rkt` — benchmark runner.
- `bench/corpus.rkt` — deterministic synthetic-corpus generators (incl. CRLF).
- `bench/results/` — archived results (`.csv`/`.rktd`) for the decision record.
- `tests/buffer-model-differential-test.rkt` — string-vs-candidate differential.
- `tests/rope-test.rkt` — rope unit/property tests (incl. summary associativity).
- (Phase C) `tests/piece-tree-test.rkt`.

## Dependencies (task ordering)

- A1 → A2 → A3, A4 (A3/A4 independent of each other, both after A1/A2).
- A4 (scaffold) must exist before B3.
- B1 → B2 → B3 → B4. B5 is a non-action (keep default) until C4.
- **B6 (render slice switch) is REQUIRED before C1/C2** so the bench measures the
  real render path; B6 depends on B2 (`buffer-model-line-range-text` exists) and
  is validated by the differential test (B3) + render tests.
- C1 needs A3 + B2/B3 + B6. C2 (criteria) can be written now/in parallel. C3
  only if C2 triggers it; C3 reuses A3 harness + A4 scaffold. C4 last.
- No new external deps at any step (`racket/base` + existing `rackunit-lib`).

## Risks & tradeoffs

- **Racket CS constant factors (the headline risk).** racket-langserver found a
  treelist-based rope "too slow for big files" and hand-rolled a custom rope.
  Mitigation: custom chunked tree from the start, larger leaf chunks (≥512 B),
  benchmark-driven tuning, and the piece-tree fallback. The plan REFUSES to
  assume the rope wins.
- **Render materialization defeating the rope (now mitigated, not deferred).**
  `render.rkt:227` materializes the whole buffer via `buffer-model-text` today
  (the only LIVE full-materialize on the render path); the rope win is only real
  once render uses `buffer-model-line-range-text` (Phase B6) and the bench
  measures that path (the `slice` op). This is now a REQUIRED gate, not an open
  question.
- **`position.rkt` allocates per-char UTF-8 byte strings** (`char-utf-8-byte-length`
  via `string->bytes/utf-8`). The rope must compute byte widths without that
  per-char allocation (compute width from `char->integer` ranges) or the
  constant factor will hurt. Note as an implementation detail for `rope.rkt`.
- **Error-message parity.** Resolved by the shared `buffer-model-errors.rkt`
  module (option (a)): both back-ends call the same constructors, reproducing the
  current internal `who` symbols and fields; the differential test compares full
  `exn-message`.
- **Summary merge bugs are invisible to the public API.** `last-line-utf16`
  (and, if ever re-added, `longest-line-utf16`) are not directly exposed, so a
  bad `summary-append` could pass the differential text/conversion checks in some
  shapes. Mitigation: the EXACT merge equations are specified above and a direct
  `summary-append` associativity unit test is required (B1).
- **`buffer-model-text` is O(n) by definition** (full materialize) — now confined
  to the save/serialize path; the render window uses `buffer-model-line-range-text`
  (Phase B6).
- **`treelist` experiment scope.** Optional only: try a `treelist` chunk-sequence
  layer as an A/B inside `rope.rkt` validated by the harness; do NOT block on it,
  given the racket-langserver result.
- **100 MB harness cost.** Building/holding 100 MB corpora + snapshots stresses
  the dev box. Mitigation: gate 100 MB behind `--size 100m`, force GC between
  ops, document the machine used in `bench/results/`.
- **Coalescing correctness.** A coalescing bug could silently diverge from the
  oracle. Mitigation: coalescing is behavior-transparent and covered by the
  differential test after EVERY edit.

## Open questions

1. **~~Exact Racket version.~~ RESOLVED.** `racket --version` → **`9.1 [cs]`**.
   Plan targets Racket CS 9.1. (If a newer CS with a faster `treelist`/`bytes`
   path is adopted later, revisit the chunk-sequence experiment.)
2. **~~Render slice seam.~~ RESOLVED.** Confirmed the production render path
   materializes the whole buffer at `render.rkt:227` (`buffer-model-text` +
   `substring`) — the only LIVE full-materialize; the `buffer-view.rkt:113`
   `editor-state-text` path is presently uncalled (grep-confirmed no live
   caller). The plan COMMITS to adding the owner-approved
   `buffer-model-line-range-text` accessor to the frozen surface and switching
   the live render materialize to it (Phase B6), gating the Phase C "rope wins"
   claim on the real render path.
3. **~~Back-end selection mechanism.~~ RESOLVED.** Production uses a single
   compile-time/static `require` in `buffer-model.rkt` (one-line flip in Phase C,
   no runtime indirection). The env-var / `dynamic-require` mechanism is reserved
   for the BENCH harness's `--backend` flag only.
4. **~~Decision thresholds.~~ RESOLVED — RELATIVE, NOT ABSOLUTE.** Per owner:
   we are concerned with IMPROVEMENT over the current string impl, not with
   pre-committed millisecond/× targets. Phase C C2 now decides on relative
   improvement vs the string baseline run in the same harness (per-keystroke
   scaling SHAPE flat-vs-linear, cheaper per-render conversions/slice at scale,
   cheap snapshots, no unacceptable regression on non-hot-path ops). Absolute
   public large-file claims are set LATER (C4) from the measured numbers. Open
   sub-point: is 100 MB a hard gate or informational for v1? (Treated as
   informational/stress unless the owner says otherwise.)
5. **~~Undo timing.~~ RESOLVED — OUT OF SCOPE.** Per owner, undo comes later.
   This work only ensures the persistent storage makes O(1) snapshots possible;
   it does NOT build the undo subsystem.
6. **~~`longest-line-utf16` in the summary.~~ RESOLVED — DROPPED.** No public API
   consumes a longest-line/max-row metric, so it would be uncovered by the
   differential test, and its boundary-straddling merge term is error-prone. It
   is removed from the summary until a horizontal-scroll/longest-row feature
   needs it (at which point re-add it plus `first-line-utf16` per the documented
   merge equation in the Design).
