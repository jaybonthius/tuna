# Review 04 — Session-State God-Module & State Layer

Track scope: `weevil/private/core/{session-state, editor-state, pane-state,
window-state, frame-state, history-state, completion-table, file-completion,
file-io, file-path}.rkt`.

Reviewer focus: is `session-state.rkt` (1348 LOC) a god-module; enumerate its
responsibilities; assess cohesion/coupling; propose a decomposition that
PRESERVES the single-writer + immutable-threading model; status of
`editor-state.rkt`; dead/duplicated code; naming; comment density;
state-mutation that bypasses the functional model.

---

## Verdict (one line)

`session-state.rkt` **is a god-module** — one struct + ~90 exported names + ~15
unrelated responsibilities, 1016 code lines, referenced by 44 files. The pure
immutable-threading discipline itself is **good and consistent**; the problem is
that *all* domain logic is piled into one file, plus one layering leak
(browser JavaScript emitted from the pure core) and a dead/duplicated parallel
state module (`editor-state.rkt`).

---

## 1. Is it a god-module? Responsibilities bundled

`session-state.rkt` bundles at least **15 distinct concerns** behind one struct:

1. **Session struct + constructors** — `session-state` struct, `make-session`,
   `make-empty-session-state`, `session-state-from-text` (L132–227).
2. **The mega-updater** — `state-with-rev` (24-field struct-copy, L923),
   `state-with-current-pane`, `state-with-current-buffer+pane`.
3. **Pane/view selection + current-* accessors** — `session-selected-pane`,
   `session-selected-view`, `session-current-buffer/point/mark*` (L237–372).
4. **Viewport / scroll** — `session-state-set-scroll`, `set-view-height`,
   `ensure-point-visible`, **`reanchor-script`** (L271–335).
5. **Buffer registry + naming + file identity** — `session-buffer-list`,
   `buffer-name(s)`, `id-by-name`, `unique-buffer-name`, `other-buffer-name`,
   `internal-buffer-name?`, `buffer-visiting`, `canonical-visited-path`
   (L373–446).
6. **Input target / focus** — `select-pane-input-target`,
   `select-minibuffer-input-target`, `input-target-kind/id` (L448–490).
7. **Pending key sequence** — `with/clear-pending-key-sequence` (L464–470).
8. **History access** — `session-history-ref` (L507).
9. **Minibuffer lifecycle** — open read-string / completing-read (+ `*`
   variants), cancel, accept, return-target, drop buffer/view (L501–719).
10. **Completion display state** — show/hide/select-next/prev/reset,
    `clamp-selected-index`, `active-completion-count`, `selected-candidate`,
    `set-completion-table`, `set-snapshot-dir` (L721–913).
11. **Editing primitives** — insert/newline/backspace/forward/backward/delete
    (L970–1041).
12. **Motion commands** — bol/eol, forward/backward-word, backward-delete-word,
    beginning/end-of-buffer, goto-line (L1043–1142).
13. **Buffer switching + files** — `switch-selected-pane-to-buffer`,
    `find-file`, `save-buffer` (L1144–1323).
14. **Pane (window) management** — create-scratch-pane, create-terminal-pane,
    other-pane, `buffers-with-saved-pane-view`, `list-index` (L1173–1257,1328).
15. **Terminal snapshots** + **echo-area message** —
    `set-terminal-snapshot`, `buffer-terminal-snapshot`, `set-message`
    (L1258–1326).

## 2. Cohesion / coupling

- **Low cohesion.** Editing, file I/O folding, minibuffer UX, completion list
  selection, terminal VT snapshots, viewport scroll, and *browser JS string
  generation* share nothing but the `session-state` struct they thread through.
- **High efferent coupling.** Imports `buffer-model`, `buffer-state`,
  `completion-table`, `frame-state`, `history-state`, `pane-state`, `position`,
  `virtual-scroll`, `file-path` — i.e. it sits on top of the entire state layer.
- **High afferent coupling.** 44 modules/tests require it; ~90 exported names.
  This is the chokepoint the whole codebase leans on.
- **What it does *right*:** every transition is `state -> state` (or
  `(values state script)`), no `set!`, no mutable module globals, and many
  transitions are deliberately `eq?`-stable no-ops so the event loop's
  `(not (equal? before after))` gate skips redundant morphs. That discipline is
  exemplary and must be preserved by any refactor.

## 3. Proposed decomposition (preserves single-writer + immutable threading)

Keep ONE `session-state` struct as the shared spine, but move it (and the
`state-with-rev` updater + base accessors) into a small **core** module that the
domain modules depend on. Each domain module exports pure `state -> state`
transitions. `session-state.rkt` becomes a thin **aggregator that re-exports**,
so the 44 call sites do not change. Dependency direction is strictly one-way:

```
leaf structs (pane-state, frame-state, buffer-state,
              completion-table, history-state, virtual-scroll)
        ^
session-core.rkt        struct, state-with-rev, require-buffer/pane,
                        selected-pane/view, current-buffer/point/mark,
                        input-target, pending-key-sequence
        ^                ^                 ^               ^
session-edit   session-minibuffer   session-buffers   session-windows
(insert/motion) (open/accept/cancel  (registry/naming/  (panes, other-pane,
                 + completion-display  visiting/find-file/  create-scratch/
                 state)                save/switch)         terminal-pane)
        ^                ^                 ^               ^
session-viewport (scroll/view-height/ensure-point-visible — NO JS)
session-terminal (snapshot get/set)
session-echo     (set-message)
        ^
session-state.rkt   (aggregator: (require + provide) the above; no logic)
```

Concretely (≤8 modules):

1. **`session-core.rkt`** — `session-state` struct, constructors,
   `state-with-rev`, `state-with-current-pane/+buffer`, `require-*`,
   selected-pane/view + current-* accessors, input-target, pending-key-seq.
2. **`session-edit.rkt`** — insert/newline/backspace/forward/backward/delete +
   all motion (word/line/buffer/goto-line).
3. **`session-minibuffer.rkt`** — open/cancel/accept + completion-display
   selection (show/hide/next/prev/reset/clamp/selected-candidate/replace-input/
   set-table/set-snapshot-dir).
4. **`session-buffers.rkt`** — buffer registry, naming, `internal-buffer-name?`,
   visiting/`canonical-visited-path`, `switch-to-buffer`, `find-file`,
   `save-buffer`.
5. **`session-windows.rkt`** — create-scratch/terminal-pane, `other-pane`,
   `buffers-with-saved-pane-view` (Emacs "windows").
6. **`session-viewport.rkt`** — scroll/view-height/`ensure-point-visible`.
   **Move `reanchor-script` OUT** to the render/client layer (see Finding H1).
7. **`session-terminal.rkt`** — terminal snapshot get/set; +
   **`session-echo.rkt`** (or fold) — `set-message`.
8. **`session-state.rkt`** — pure aggregator: re-exports 1–7. Zero logic.

This is mechanical (cut/paste + re-export), risk-free for the single-writer
model because nothing about the threading changes, and it shrinks the largest
file in the tree to a 1-screen index. Do it module-by-module behind the
aggregator so tests stay green at each step.

## 4. `editor-state.rkt` — superseded dead/duplicated code

`editor-state.rkt` is the Phase-1 single-buffer state model. It is now
**superseded by `session-state`** and is effectively dead:

- Its editing logic (`editor-state-insert/newline/backspace/backward-char/
  forward-char/delete-forward-char`, L77–132) is a **near-verbatim duplicate**
  of the `session-state-*` editing transitions — two copies of the same buffer
  logic to keep in sync.
- Only non-test consumer is `buffer-view.rkt`'s `editor-state->buffer-projection`
  (buffer-view L112) — which **has no callers anywhere** (also dead).
- `event-loop.rkt`'s `current-editor-state` (L189) is a transitional alias that
  just calls `current-session-state`; its **only caller is one test**
  (`event-loop-subscriber-message-test.rkt:37`). The name is misleading — it
  returns `session-state?`, not `editor-state?` (see contract L29).

Recommendation: migrate the one test to `current-session-state`, delete
`current-editor-state`, delete `editor-state->buffer-projection`, and either
delete `editor-state.rkt` (move its focused unit tests' coverage onto
`session-state` editing) or explicitly demote it to a documented test fixture.
Leaving two divergent editing implementations is a long-term correctness trap.

## 5. State-mutation that bypasses the functional model

- **`session-state-set-message` (L1325) bypasses `state-with-rev`** — it does a
  direct `struct-copy session-state` and **does NOT bump `rev`**. Every other
  transition increments `rev`; this one relies on the event loop's `equal?`
  diff to notice the change. It is documented, but it is the lone exception to
  the "every mutation bumps rev" invariant and will silently break any
  subscriber that gates on `rev` instead of `equal?`. Recommend routing through
  `state-with-rev` (or add a tiny `state-without-rev` helper + a one-line
  invariant comment) so the rule has exactly one shape.
- No `set!` / mutable global was found in the track's pure modules — good. The
  only mutation is the event loop's `state` cell and `file-io.rkt`'s background
  `thread`s, both by design.

## 6. Naming inconsistencies

- `current-editor-state` returns `session-state?` (event-loop L189) — stale,
  misleading transitional alias (see §4).
- "pane" vs "window" vs "view": `pane-state` is the live struct, `window-state`
  / `window-leaf` / `window-minibuffer` (window-state.rkt) is an **unused**
  "persistence-ready vocabulary" the comment admits "not all call sites use yet"
  — a parallel naming for the same concept that currently confuses more than it
  helps. `frame-state` uses `pane-leaf`; `window-state` uses `window-leaf`. Pick
  one vocabulary or clearly quarantine the unused one as "future".
- `make-session` (L159) is a thin wrapper over the struct constructor whose only
  added value is a `#:message #f` default; both call sites pass no message.
  Marginal; fold into the struct constructor or keep with a one-line note.

## 7. Comment density

- session-state.rkt: 217 comment lines / 1348 (**16%**), with several
  17–24-line block comments. Most carry genuine design rationale (why no memo,
  read-only-until clamping, eq?-stable no-op contract) and are *valuable* — this
  is not gratuitous narration.
- **Excessive / misplaced:** the 17-line `reanchor-script` comment (L292–310)
  and 24-line candidate-filter memo warning (L761–785) read like design-doc
  prose embedded in code; better as a short pointer + a `plans/` note.
- **`[FIX N]` markers** (FIX 5/6/7/11 here; FIX 2/3/8/12/13 elsewhere) reference
  an external fix-numbering scheme that exists nowhere in the repo. To a future
  reader they are noise ("which fix was 7?"). Replace with the behavioral reason
  (most already state it inline) and drop the bare numbers.

---

## Findings (prioritized: severity · type · file:line · fix)

### High
- **H1 · layering leak · session-state.rkt:292 (`reanchor-script`) & 313–335**
  The PURE state core builds a browser-JavaScript string
  (`document.querySelector('.editor')... el.scroll(...)`) and threads it out of
  `ensure-point-visible` as a second return value. Client/render concern inside
  the model. *Fix:* return only the new scroll px (data); let the render/client
  layer translate px → scroll script. Move `reanchor-script` to the web layer.
- **H2 · dead + duplicated code · editor-state.rkt (whole) +
  buffer-view.rkt:112 + event-loop.rkt:189** Parallel single-buffer state model
  superseded by `session-state`; editing logic duplicated; only live touchpoints
  are an uncalled projection fn and a one-test alias. *Fix:* delete the alias and
  `editor-state->buffer-projection`, retire/demote `editor-state.rkt` (see §4).

### Medium
- **M1 · god-module / maintainability · session-state.rkt:1–1348** 15
  responsibilities, ~90 exports, 44 dependents. *Fix:* decompose behind a
  re-export aggregator (§3); no behavior change.
- **M2 · invariant inconsistency · session-state.rkt:1325
  (`set-message`)** Sole transition that mutates without bumping `rev`. *Fix:*
  route through `state-with-rev` or add an explicit single helper + invariant
  comment.
- **M3 · naming/dead vocab · window-state.rkt:1–18** Unused parallel
  window-* struct vocabulary alongside the live pane-* / pane-leaf naming.
  *Fix:* quarantine as clearly-future or remove until the migration lands.

### Low
- **L1 · misleading name · event-loop.rkt:29,189** `current-editor-state`
  returns `session-state?`. *Fix:* migrate the one test to
  `current-session-state`, delete the alias.
- **L2 · comment noise · core/*.rkt `[FIX N]` markers** Reference a
  nonexistent external numbering. *Fix:* keep the behavioral reason, drop the
  bare numbers.
- **L3 · over-long inline rationale · session-state.rkt:292–310, 761–785**
  Design-doc prose in code. *Fix:* shorten + link a `plans/` note.
- **L4 · marginal wrapper · session-state.rkt:159 (`make-session`)** Adds only
  a default; fold into struct constructor.

---

## What is GOOD (call it out)

- **Immutable threading is consistent and disciplined.** Every transition is
  `state -> state`; no `set!`, no mutable module-level cache in the pure layer.
  The explicit warning against reintroducing a render-time memo (L761–785),
  citing the cross-thread (render thread vs event-loop thread) data race, shows
  real understanding of the single-writer model.
- **`eq?`-stable no-ops are systematic.** Setters compare-first and return the
  SAME object on no change (pane-state.rkt:55; scroll/view-height; every motion
  command), so the event loop's `equal?` gate avoids redundant morphs. This is
  the correct, performance-aware way to express "nothing changed."
- **`read-only-until` as a uniform point-min** lets the same editing/motion code
  serve both normal buffers (lower bound 0) and the minibuffer (prompt end)
  without special-casing — clean and Emacs-faithful.
- **File layer is properly seam-isolated.** `file-path.rkt` is pure/I/O-free;
  `file-completion.rkt` closes over an immutable snapshot (no disk in render or
  TAB); `file-io.rkt` cleanly separates synchronous, unit-testable
  `*-event` functions from the thin `spawn-*-job!` thread wrappers, and does
  atomic writes (temp + rename) with mandatory `(mtime . size)` conflict checks.
  This is the textbook way to keep disk I/O off the single-writer loop.
- **`completion-table.rkt`** is a small, pure, well-factored protocol
  (`try/all/test/metadata`) with the prefix style isolated behind
  `style-match?`/`style-try` so a future `completion-styles` registry slots in
  without touching callers.
- **Smaller state structs** (`pane-state`, `frame-state`, `history-state`,
  `window-state`) are appropriately tiny and single-purpose — the god-module
  problem is confined to `session-state.rkt` itself.

