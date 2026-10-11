# Code Review — Track 03: Core Buffer / Rope Model

Date: 2026-06-19
Scope: `weevil/private/core/{rope, buffer-model, buffer-model-rope,
buffer-model-string, buffer-model-contract, buffer-model-errors, buffer-state,
buffer-text-state, marker-state, position, virtual-scroll}.rkt`
Cross-read: `tests/buffer-model-differential-test.rkt`, `tests/rope-test.rkt`,
`ADR.md` (Canonical Position Unit; Buffer Representation and Benchmark Gate),
`plans/buffer-rope-implementation-plan.md`, `plans/buffer-rope-benchmark-results.md`.

Verdict: **This is the strongest, most carefully engineered layer in the
codebase I reviewed.** The rope is correct, well-tested, and matches the ADR
decision. The seam design is genuinely elegant. The main issues are (a) a
test-oracle's implementation details leaking into the production backend, (b)
unexercised marker-edit-tracking that may mislead future work, and (c) comment
density / change-history tags that the owner already flagged.

---

## What is GOOD (keep / replicate this elsewhere)

- **The storage seam (`buffer-model.rkt`) is excellent.** A single static
  `require` selects the production backend; the frozen public contracts are
  applied exactly once at the boundary so the hot path is never double-wrapped;
  swapping backends is a one-line change. This is textbook CQRS/fat-morph
  hygiene and directly satisfies the ADR "buffer storage is private/replaceable"
  goal.
- **The rope itself (`rope.rkt`) is well-engineered.** Self-contained (no
  dependency on buffer-model/contract/position); immutable + structurally
  shared; a single `seek-leaf-by` descent funnels *every* coordinate conversion;
  the summary monoid is associative (tested) and computes UTF-8/char/UTF-16/
  newline/last-line-width without per-char `string->bytes/utf-8` allocations.
  This precisely implements the ADR's augmented-persistent-rope decision.
- **`rope-check-invariants`** is a real, thorough structural invariant
  (equal-depth leaves, child-count bounds, leaf-size bounds, recomputed-summary
  equality) and is exercised by the test suite.
- **The differential test is exactly right.** Seeded random edit sequences drive
  the string oracle and the rope side-by-side, asserting agreement across the
  *entire* public surface plus an independent brute-force oracle, and asserting
  invalid inputs raise identically. This is the correct way to earn confidence
  in a subtle data structure, and it is the strongest justification for keeping
  the dual-backend design.
- **No improper byte/char/utf16 leak into higher layers.** `buffer-text-state`/
  `buffer-state` thread the opaque model and expose `point-char` via conversion;
  the canonical-byte / public-char split from the ADR is respected. The
  byte/char/utf16 coordinate triple lives inside the (private) buffer-model
  interface where it belongs.
- **`buffer-text-state` indirection** (text payload one level below
  `buffer-state`) is good forward-thinking for Emacs-style indirect buffers
  sharing text without sharing buffer-local metadata.
- **`virtual-scroll.rkt`** is cleanly separated, dependency-free, single source
  of windowing truth, with a loud startup invariant guarding the tuning
  constants.
- **`marker-state` adjustment logic is itself correct** Emacs insertion-bias
  semantics (insert: shift if `pos>at` or `pos==at && insertion-type`; delete:
  unaffected if `pos<=start`, clamp to `start` if inside, shift if past). See
  caveat #2 — it is just not wired in yet.

---

## Findings (prioritized: severity · type · file:line)

### 1. MED · coupling/abstraction-leak · `buffer-model-rope.rkt` (whole file, esp. 110–250)
The rope adapter is contorted to reproduce the **string oracle's incidental
error provenance**. ~10 functions each do a *manual* `rope-valid-byte-offset?`
check and `raise-invalid-*` with a hand-picked `who` symbol copied from
`position.rkt` — e.g. `buffer-model-previous-boundary` raises with
`'previous-codepoint-boundary`, `buffer-model-forward-word` raises
`'byte-offset->char-index`, `buffer-model-beginning-of-line` raises
`'byte-offset->char-index` — even though the rope path never calls those
functions. The *only* reason is the differential test's strict full-`exn-message`
equality. Consequences:
- The production backend's error messages are now coupled to a test oracle's
  arbitrary internal `who` choices. Change the oracle and you must change the
  rope.
- It duplicates validation the rope ops already perform internally (e.g.
  `rope-insert` calls `rope-check-byte`), so many offsets are validated twice.

**Recommendation:** Relax the differential test to compare error **class +
structured fields** (the `raise-arguments-error` field alist) rather than the
exact `who`/message string. That frees both backends from lock-step error-string
coupling and lets the rope adapter drop most of its manual pre-checks (rely on
the rope's own checks), shrinking this file noticeably. This is the single
biggest simplification available in this track.

### 2. MED · dead-code / latent-bug-trap · `marker-state.rkt:20,28` (+ `pane-state.rkt`)
`marker-state-after-insert` and `marker-state-after-delete` are **never called
in production** — only in `tests/core-marker-state-test.rkt`. Point/mark are
repositioned exclusively via explicit `marker-state-move` in `pane-state.rkt`.
So markers do **not** currently track edits; the insertion-bias machinery is
unexercised outside tests. The ADR explicitly says insertion-bias "should be
part of the buffer/marker design, not bolted on later" — the design is present
but disconnected. Risk: when overlays / diagnostics / multiple live markers
arrive, a developer will reasonably assume edit-tracking already works and build
on a no-op. **Recommendation:** either wire `after-insert`/`after-delete` into
the edit path (the buffer/pane mutation site that calls `buffer-model-insert`/
`-delete`), or add an explicit comment in `marker-state.rkt` + `pane-state.rkt`
that markers are presently position holders and do not auto-adjust.

### 3. LOW-MED · simplification / placement · `buffer-model-string.rkt` (whole file, 247 lines)
The string backend is **production-dead** — used only as the differential-test
oracle and the bench harness. Keeping a simple reference oracle is *defensible
and valuable* (it is what validates the rope), so do **not** delete it. But it
currently sits in `weevil/private/core/` beside the production backend, in the
production module graph, where it reads as a selectable backend. **Recommendation:**
move it to a test-support location (e.g. `tests/support/` or a clearly named
`*-oracle` module) and/or add a one-line header "TEST ORACLE ONLY — not a
production backend." Same applies to making the test-only status of the
contract-parameterization explicit (see #4).

### 4. LOW-MED · complexity · `buffer-model.rkt:47–75` + `buffer-model-contract.rkt`
The parameterized contract spec (`buffer-model-contracts model?`) + 25 individual
`(hash-ref contracts 'name)` lines in the `contract-out` block is heavyweight.
Its parameterization exists *only* for two non-production consumers (the bench
harness and the differential test), which dynamically apply the same spec to a
`dynamic-require`d backend. Now that the rope is the chosen backend:
- Keeping the **shared spec module** is justified (the differential test/bench
  genuinely reuse it — don't duplicate the spec).
- But the 25 hand-written `hash-ref` lines in `buffer-model.rkt` are pure
  boilerplate and could collapse to a small macro / `define-syntax` that expands
  `buffer-model-contract-names` into the `contract-out` clauses, removing a
  whole class of "did I keep these two lists in sync" bugs.

This is a readability/maintenance simplification, not a correctness issue.

### 5. LOW · correctness-edge (practically unreachable) · `rope.rkt` `resplit`/`find-balanced-split` (~205–230)
When `resplit` is given a merged string with `total > max-chunk-bytes` and
`find-balanced-split` returns `#f`, it returns a *single* chunk that can exceed
`max-chunk-bytes + max-chunk-slack`, which would violate the leaf-size invariant
that `rope-check-invariants` enforces. In practice this is unreachable: the
merged string is `prev (<=1024) + tail (<512) < 1536`, the search window is
`[512, total-512]` (width `>= 1`), and with codepoints `<= 4` bytes a boundary
always lands in any window `>= 4` bytes wide, so a split is always found.
**Recommendation:** add a one-line assertion or comment documenting the "a
codepoint boundary always exists in the window" assumption so a future change to
the chunk constants can't silently break the invariant.

### 6. LOW · comment-density / change-history-noise · multiple files (owner-flagged)
Comment ratios: `buffer-model.rkt` 51%, `buffer-model-errors.rkt` 41%,
`buffer-model-rope.rkt` 32%, `buffer-model-contract.rkt` ~25% (large block
comments). Much of this is *valuable* invariant documentation (the summary
monoid, the seam rationale, error-parity intent) — keep that. But a meaningful
fraction is **change-history / issue-tracker residue that belongs in git, not
the source**:
- `[FIX 2]`, `[FIX 3]` — `buffer-model-string.rkt:130,168`
- `[FIX 6]`, `[FIX 7]`, `[FIX 8]`, `[FIX 11]`, `[FIX 12]`, `[FIX 13]` —
  `virtual-scroll.rkt`, `pane-state.rkt`
- `Phase A4 / B2 / B3 / B6` plan-phase cross-references scattered across
  `buffer-model-*.rkt` headers and `tests/`.

These tags reference plan documents and an ordinal "FIX" numbering that won't
survive and mean nothing to a future reader. **Recommendation:** strip the
`[FIX N]` and `Phase X` tags; keep the substance of the comment where it
explains a non-obvious invariant. Net effect is fewer, higher-signal comments.

---

## Answers to the track questions

- **Is the buffer layer clean / simple / well-abstracted?** Yes — notably so.
  The seam, the rope, and the test strategy are the high-water mark of the
  codebase. The main drags are the oracle-coupled error reproduction (#1) and
  comment noise (#6), not the core abstraction.
- **Is the dual-backend + contract machinery worth it now that the rope won?**
  The **oracle is worth keeping** (it is what makes the rope trustworthy, and
  differential testing remains valuable for future edits). The **contract
  parameterization is worth keeping** (real reuse by the test/bench). What can
  be simplified *now*: (a) relax the differential error comparison so the rope
  needn't mimic the oracle's `who` symbols (#1); (b) macro-generate the 25
  `contract-out` lines (#4); (c) relocate/label the string backend as test-only
  so it is not mistaken for a production option (#3).
- **Any byte/char/utf16 leak across the API?** No improper leak into higher
  layers. The triple coordinate system is intrinsic to the (private)
  buffer-model interface; `buffer-state`/`buffer-text-state` correctly expose
  only the char-based public view per the ADR. The 25-function interface is
  *wide* but that width is inherent to the conversions the editor needs, not an
  abstraction failure.
- **Dead code?** Yes: `marker-state-after-insert/-after-delete` (production-
  unused, #2) and the whole string backend (oracle-only, #3). Both are
  defensible to keep but should be labeled/wired so they don't mislead.
- **Marker / position insertion-bias smells?** The logic is *correct*; the smell
  is that it is **disconnected from the edit path** (#2).
- **Comment density?** High and owner-flagged; the actionable part is stripping
  `[FIX N]`/`Phase X` change-history tags (#6).

## Suggested priority order
1. (#1) Relax differential error comparison; drop the rope adapter's oracle-mimic
   pre-checks. Biggest simplification + decoupling.
2. (#2) Wire markers into edits, or document them as non-tracking.
3. (#3) Relocate/label the string backend as a test oracle.
4. (#4) Macro-generate the `contract-out` block.
5. (#6) Strip `[FIX N]`/`Phase X` tags.
6. (#5) Document/assert the resplit boundary assumption.

(No code was modified; this track is review-only and the findings are advisory.)
