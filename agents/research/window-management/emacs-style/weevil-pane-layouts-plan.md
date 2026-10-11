# Pane Layouts Plan (Tiling / Multiple Visible Panes)

Status: planned
Scope: SINGLE frame, MULTIPLE simultaneously visible panes via a recursive
window tree; equal CSS-flex splits (no stored sizes); split/delete/cycle ops on
simple single chords. No mouse/keyboard resize, no weights, no prefix keys.
Date: 2026-06-15

## Goal

Let Weevil's one frame display several panes at once by turning
`frame-state-root` into a real recursive window tree (leaves + splits), so a
pane CONTAINS a buffer and multiple panes may show the same buffer with
independent point/mark (Emacs window-point).

## Emacs design anchors

- **Window tree**: a frame has one root; interior nodes are vertical or
  horizontal *combinations*; leaves show one buffer (`frame-root-window`,
  `window-parent`, `window-child`). We mirror this with `pane-leaf` +
  `pane-split`.
- **`split-window-below` (`C-x 2`) / `split-window-right` (`C-x 3`)**: split the
  selected window; both resulting windows show the SAME buffer initially; the new
  window inherits buffer + point. Selection STAYS on the original window.
- **`delete-window` (`C-x 0`)**: remove the selected window, give its space to a
  sibling, collapse now-redundant single-child internal nodes; cannot delete the
  sole window.
- **`delete-other-windows` (`C-x 1`)**: promote the selected window to fill the
  frame (root becomes that leaf).
- **`other-window` (`C-x o`)**: move selection to the next leaf in a stable
  depth-first cyclic order (top→bottom, left→right); wrap.
- **`set-window-buffer`**: point a window at a buffer without changing selection
  or layout (mechanism, not `display-buffer` policy).
- **Axis naming**: `'vertical` = stacked (split-below), `'horizontal` =
  side-by-side (split-right), matching Emacs vertical/horizontal *combinations*.

## Key decisions (bake these in to avoid known traps)

1. **ONE tree representation.** Extend `frame-state.rkt` with a recursive node:
   the existing `pane-leaf` (holds `pane-id` indexing the `panes` hash) PLUS a new
   `(struct pane-split (axis children) #:transparent)` where `axis` is
   `'vertical` or `'horizontal` and `children` is an ordered non-empty list of
   nodes. The leaf continues to reference the `panes` hash by id (no buffer/marker
   data is moved into the tree).

2. **Retire the parallel model.** `weevil/private/core/window-state.rkt`
   (`window-internal`/`window-leaf`/`window-minibuffer`) is unused scaffolding
   that encodes a SECOND, incompatible representation (buffer/marker ids in
   leaves, child-*id* indirection in internals). DELETE it so only one
   representation exists. Grep first to confirm no `require` references it outside
   its own module (recon says none).

3. **No destructive selection.** `frame-state-with-visible-pane` currently
   COLLAPSES `root` to a single `pane-leaf`. Splitting/cycling MUST NOT use it.
   Selection changes update only `frame-state-selected-pane-id` and leave `root`
   intact; layout changes rebuild `root` non-destructively (replace just the
   target leaf / collapse just the affected split).

4. **Selection lives in `frame-state-selected-pane-id`** (a leaf pane-id).
   `frame-visible-pane-ids` recurses into `pane-split` children and returns ALL
   visible leaf ids in deterministic depth-first order. Cycling
   (`focus-next-pane`/`other-pane`) advances selected-pane-id across that ordered
   leaf list and wraps; it does NOT rebuild `root`.

5. **Split clones the buffer with FRESH markers.** Splitting allocates a NEW
   pane-state via `make-pane-state` showing the SAME `buffer-id` as the source
   leaf, with point/mark initialized from the SOURCE pane's CURRENT point/mark
   bytes (Emacs: new window inherits point). Markers are never aliased
   (`make-pane-state` keys markers by `pane-id:role`, so distinct panes are
   independent — confirm no shared marker object).

6. **All transitions route through `state-with-rev`** for monotonic `rev`
   (SSE diff). No-op cases (`delete-pane`/`other-pane`/`delete-other-panes` with a
   single leaf, cycle with one visible leaf) return the input `state`
   `eq?`-stable with NO rev bump.

7. **Selection after split STAYS on the source leaf** (matches Emacs
   `split-window`: selected window does not move to the new window). Stated
   explicitly so tests pin it.

## Operations (v1)

Layer per op: `frame-state.rkt` tree helper → `session-state.rkt` mutator
(through `state-with-rev`) → `weevil/pane.rkt` public fn → `weevil/defaults.rkt`
command + keybinding.

- **`split-pane-below`** (Emacs `C-x 2`, chord `C-2`): split selected leaf into a
  `pane-split` with `axis 'vertical`, ordered `(source-leaf new-leaf)`; new leaf
  shows same buffer with fresh markers from source point/mark; selection STAYS on
  source. If selected leaf's parent is already a `'vertical` split, FLATTEN
  (insert new leaf as a sibling after source) rather than nest, keeping the tree
  shallow (Emacs combination flattening).
- **`split-pane-right`** (Emacs `C-x 3`, chord `C-3`): identical but `axis
  'horizontal`; flatten into an existing `'horizontal` parent.
- **`delete-pane`** (Emacs `C-x 0`, chord `C-0`): remove the selected leaf from
  its parent split; if the split is left with one child, collapse it (promote the
  surviving child into the grandparent slot); choose a new selected leaf = the
  nearest sibling leaf in depth-first order. No-op (eq?-stable) if only one leaf.
- **`delete-other-panes`** (Emacs `C-x 1`, chord `C-1`): set `root` to
  `(pane-leaf selected-pane-id)`; selection unchanged. No-op if root is already
  that single leaf.
- **`focus-next-pane` / `other-pane`** (Emacs `C-x o`, chord `C-p`): advance
  `selected-pane-id` to the next id in `frame-visible-pane-ids` order, wrap; set
  `selected-input-target` to that pane; save outgoing pane view to buffer defaults
  (mirror existing `buffers-with-saved-pane-view`). No-op if <2 visible leaves.

### Reconciling existing commands

- **`C-p` (other-pane)**: KEEP, re-pointed at `focus-next-pane` cycling across
  VISIBLE leaves (not `pane-order`). With one leaf it stays a no-op.
- **`C-n` (make-scratch-pane)**: today it CREATES a scratch buffer+pane and
  REPLACES the visible leaf (destructive `frame-state-with-visible-pane`). RETIRE
  the replace behavior. Repurpose `C-n` to `set-pane-buffer` semantics: switch the
  SELECTED pane to a NEW scratch buffer in place — NO layout change, selection and
  tree unchanged. (Concretely: keep allocating a new scratch buffer, but update
  only the selected pane's `buffer-id`+view via the existing
  `session-state-switch-selected-pane-to-buffer`-style path; do not touch `root`.)
- **`pane-order`**: cycle order is now DERIVED from `frame-visible-pane-ids`
  (tree leaves in depth-first order), so `pane-order` is no longer needed for
  cycling. Decision: keep the `pane-order` field for now (creation-order bookkeeping
  for buffer-defaults save and to avoid a struct-arity churn), but STOP using it to
  drive `other-pane`. Re-grep usages; if nothing else reads it after the cycle
  rewrite, a later cleanup may drop it (out of scope here).
- **`s-o` (cycle-focus-target-command)**: unchanged — it already iterates
  `current-frame-focus-targets`, which derives from `frame-visible-pane-ids`, so it
  works across multiple visible panes for free once the walk recurses.

Future prefix-key equivalents to note in defaults.rkt comments: `C-x 2`, `C-x 3`,
`C-x 0`, `C-x 1`, `C-x o`.

## Tasks

### 1. Add `pane-split` node + recursive tree ops
- File: `weevil/private/core/frame-state.rkt`
- Add `(struct pane-split (axis children) #:transparent)`; provide it.
- Generalize `frame-visible-pane-ids` `walk` to recurse: `pane-leaf` → `(list
  id)`; `pane-split` → `(append-map walk children)`. Depth-first, child order.
- Add pure tree helpers (all return new trees, never mutate, never call the
  destructive `frame-state-with-visible-pane`):
  - `frame-state-split` `(-> frame-state? symbol? symbol? (or/c 'vertical
    'horizontal) frame-state?)` taking `(frame source-pane-id new-pane-id axis)`:
    locate the source leaf, replace it with a split (or flatten into the parent
    split of the same axis), inserting `new-leaf` AFTER source; selection stays on
    source. Returns frame with new `root`, unchanged `selected-pane-id`.
  - `frame-state-delete-pane` `(-> frame-state? symbol? frame-state?)` taking
    `(frame pane-id)`: remove that leaf, collapse single-child splits, pick new
    selected leaf (nearest depth-first sibling). No-op frame if single leaf.
  - `frame-state-promote-pane` `(-> frame-state? symbol? frame-state?)`: set
    `root` to `(pane-leaf pane-id)`.
  - `frame-state-with-selected-pane` `(-> frame-state? symbol? frame-state?)`:
    update only `selected-pane-id` (root untouched). NON-destructive replacement
    for selection changes.
- Acceptance: unit tests build expected tree shapes; `frame-visible-pane-ids`
  returns N ids in depth-first order; selection helpers leave `root` `eq?` when
  only id changes is impossible (struct-copy ok) but never collapse splits.

### 2. Remove the parallel window-state model
- File: `weevil/private/core/window-state.rkt` (DELETE)
- Grep repo for `window-state` / `window-internal` / `window-leaf` /
  `window-minibuffer` / `window-node-child-ids`; confirm only self-references and
  remove the file. If any test or build manifest lists it, remove that reference.
- Acceptance: full build + suite green with the file gone; no dangling `require`.

### 3. Session-state split mutators
- File: `weevil/private/core/session-state.rkt`
- `session-state-split-pane` `(-> session-state? (or/c 'vertical 'horizontal)
  session-state?)`: allocate `new-pane-id` from `next-pane-id`; read source =
  `session-selected-pane`; make `new-pane` via `make-pane-state` with source's
  `buffer-id`, `#:point-byte (pane-state-point-byte source)`,
  `#:mark-byte (pane-state-mark-byte source)`,
  `#:mark-active? (pane-state-mark-active? source)`; add to `panes` (and
  `pane-order` append for bookkeeping); set `#:frame (frame-state-split frame
  selected-id new-pane-id axis)`; bump `next-pane-id`; route via `state-with-rev`.
  Selection/input-target UNCHANGED (stays on source).
- Acceptance: from single-pane state, one split → 2 panes, both same `buffer-id`,
  distinct pane-states with independent markers, `root` is a `pane-split` of the
  right axis with `(source new)`, selected pane still source, `rev` +1.

### 4. Session-state delete mutators
- File: `weevil/private/core/session-state.rkt`
- `session-state-delete-pane` `(-> session-state? session-state?)`: if
  `frame-visible-pane-ids` has <2, return `state` (eq?, no rev). Else set `#:frame
  (frame-state-delete-pane frame selected-id)`; set `#:selected-input-target` to
  the frame's new selected pane; bump rev. (Leave the orphaned pane-state in
  `panes`; it is simply no longer visible — acceptable for v1.)
- `session-state-delete-other-panes` `(-> session-state? session-state?)`: if
  root is already the single selected leaf, no-op (eq?). Else `#:frame
  (frame-state-promote-pane frame selected-id)`; rev +1; selection unchanged.
- Acceptance: delete collapses split + reselects sibling; delete-other-panes makes
  root a lone leaf; single-leaf cases are eq?-stable.

### 5. Rewrite `session-state-other-pane` to cycle visible leaves
- File: `weevil/private/core/session-state.rkt`
- Replace `pane-order`-driven body with: `ids = frame-visible-pane-ids`; if
  `(< (length ids) 2)` return `state` (eq?, no rev); else advance from
  `selected-pane-id`, wrap; save outgoing view via `buffers-with-saved-pane-view`;
  set `#:frame (frame-state-with-selected-pane frame next-id)` and
  `#:selected-input-target (input-target 'pane next-id)`; rev +1. Do NOT rebuild
  root.
- Acceptance: with a 2-leaf split, `C-p` toggles selection and wraps; with one
  leaf it is eq?-stable.

### 6. Public pane API
- File: `weevil/pane.rkt`
- Add `split-pane-below!`, `split-pane-right!`, `delete-pane!`,
  `delete-other-panes!` using the `command-context-set-state!` pattern; keep
  `other-pane!` (now visible-leaf cycle) and `select-pane-input-target!`.
- `make-scratch-pane!`: change to the in-place `set-pane-buffer` semantics
  (switch selected pane to a new scratch buffer, no layout change) — or RETIRE if
  redundant; Task 8 picks. Update contracts in `provide`.
- Acceptance: each fn flows through command-context and produces the expected
  next-state in `frame-pane-api-test.rkt`.

### 7. Commands + keybindings
- File: `weevil/defaults.rkt`
- Add `split-pane-below-command`, `split-pane-right-command`,
  `delete-pane-command`, `delete-other-panes-command`. Bind in `global-keymap`
  only: `C-2`→below, `C-3`→right, `C-0`→delete, `C-1`→delete-other. Keep `C-p`→
  `other-pane-command` (now visible-leaf cycle). Re-point/repurpose `C-n`
  (`make-scratch-pane-command`) per Task 6, or unbind if retired.
- Update the existing comment to list the future Emacs prefix equivalents
  (`C-x 2 / C-x 3 / C-x 0 / C-x 1 / C-x o`).
- Acceptance: keymap dispatch hits the new commands; minibuffer keymap unchanged.

### 8. Decide make-scratch-pane fate
- Files: `weevil/pane.rkt`, `weevil/defaults.rkt`, `weevil/private/core/session-state.rkt`
- Concrete choice: repurpose `make-scratch-pane!` → `set-pane-buffer` (selected
  pane shows a NEW scratch buffer, no layout change) reusing the existing
  `session-state-switch-selected-pane-to-buffer` machinery plus scratch-buffer
  allocation; remove `frame-state-with-visible-pane` use. Keep `C-n` bound to it.
- Acceptance: `C-n` does not change the tree shape; only the selected pane's
  buffer/view changes; `frame-visible-pane-ids` count unchanged.

### 9. Retire `frame-state-with-visible-pane`
- File: `weevil/private/core/frame-state.rkt` (+ callers)
- After Tasks 3–8, its only callers (`create-scratch-pane`, `other-pane`) no
  longer use it. Remove it (and its provide) or, if any path still needs a
  "single visible pane" reset, route that through `frame-state-promote-pane`.
- Acceptance: grep shows no remaining callers; build green.

### 10. Render: extract `render-pane` + walk the tree
- File: `weevil/private/web/render.rkt`
- Extract `(render-pane state pane-id)` from the inline `.weevil-pane` section. It
  looks up the pane via the `panes` hash (NOT `session-current-*` selected-pane
  shortcuts): get the pane-state, its `buffer-id`, buffer text, and the pane's own
  point byte; build the projection from THOSE. `--input-target` class compares
  per-pane against `session-input-target-id`.
- Add `(render-node state node)`: `pane-leaf` → `(render-pane state pane-id)`;
  `pane-split` → a container `div` with class `weevil-split weevil-split--vertical`
  / `--horizontal` whose children are `(map (render-node state) children)`.
- `render-editor-app` calls `(render-node state (frame-state-root frame))` inside
  `.weevil-frame`; minipane stays a SIBLING outside the recursive walk.
- Stable ids: each pane gets `id="pane-<pane-id>"` AND keeps `data-pane-id`; inner
  stateful elements (the `.editor` surface, title `h2`) get pane-derived stable
  ids so Datastar morph-by-id preserves per-pane cursor/scroll/focus across the
  whole-`#weevil-root` fat morph. New panes get a new id (fresh mount); surviving
  panes keep ids. Each split container also gets a stable id derived from its
  position is NOT safe (index shifts) — instead key the container off the FIRST
  leaf's pane-id or omit container ids and rely on stable child pane ids (children
  morph in place). Keep whole-`#weevil-root` fat morph; no SSE mode changes.
- Replace hardcoded `(data-frame-id "frame-1")` with
  `(frame-state-id (session-state-frame state))`.
- Acceptance: render of a split state emits N `.weevil-pane` elements with
  distinct stable ids and a `weevil-split` container of the correct axis class.

### 11. CSS for nested splits
- File: `static/weevil.css`
- Add `.weevil-split { display:flex; min-height:0; min-width:0; flex:1; }`
  `.weevil-split--horizontal { flex-direction:row; }`
  `.weevil-split--vertical { flex-direction:column; }` and make
  `.weevil-split > * { flex:1 1 0; min-height:0; min-width:0; }` so children
  divide space EQUALLY (no stored sizes; balancing is automatic). Ensure
  `.weevil-pane` already has `flex:1`/`min-height:0` so it fills its slot.
- Acceptance: two panes split right render side-by-side at equal width; split
  below render stacked at equal height; nested splits divide recursively.

### 12. Tests — new layout suite
- New file: `tests/core-pane-layout-test.rkt`
  - split-below / split-right produce the expected tree shape + axis.
  - new leaf shares the source `buffer-id` but has an independent pane-state
    (move source point, assert new pane point unchanged → markers not aliased).
  - new pane point initialized from source's current point byte.
  - selection stays on source after split.
  - `delete-pane` collapses the split and reselects a sibling; single-leaf
    delete is eq?-stable.
  - `delete-other-panes` promotes selected leaf to root; single-leaf is
    eq?-stable.
  - `focus-next-pane`/`other-pane` cycles across visible leaves and wraps;
    single-leaf is eq?-stable.
  - `frame-visible-pane-ids` returns multiple ids in depth-first order.

### 13. Tests — update single-pane invariants + add render assertion
- Files: `tests/web-render-test.rkt`, `tests/core-pane-management-test.rkt`,
  `tests/frame-pane-api-test.rkt`
- `web-render-test.rkt`: the "exactly one `.weevil-pane`", `data-pane-id "pane-1"`,
  hardcoded `data-frame-id` assertions need updating to derive frame id and allow
  the single-pane baseline; ADD a test that after a split the render has N panes
  with distinct stable ids and a `weevil-split` container.
- `core-pane-management-test.rkt`: replace assumptions tied to the destructive
  `make-scratch-pane`/`pane-order` cycling with the new in-place `set-pane-buffer`
  behavior and visible-leaf cycling.
- `frame-pane-api-test.rkt`: `current-frame-focus-targets` now returns multiple
  `(pane …)` entries after a split; update the single-visible expectations and
  add a post-split multi-target assertion.
- Acceptance: full suite green.

## Files to modify

- `weevil/private/core/frame-state.rkt` — add `pane-split`, recursive walk, tree
  ops, non-destructive selection; retire `frame-state-with-visible-pane`.
- `weevil/private/core/session-state.rkt` — split/delete/promote mutators; rewrite
  `other-pane`; repurpose `create-scratch-pane`; stop using `pane-order` for
  cycling.
- `weevil/pane.rkt` — new public split/delete fns; repurpose `make-scratch-pane!`.
- `weevil/defaults.rkt` — new commands + `C-2/C-3/C-0/C-1` bindings; `C-p`/`C-n`
  reconcile; comment future prefix keys.
- `weevil/private/web/render.rkt` — `render-pane`/`render-node` tree walk; stable
  per-pane ids; `frame-state-id` instead of `"frame-1"`.
- `static/weevil.css` — `.weevil-split` flex containers.
- `tests/web-render-test.rkt`, `tests/core-pane-management-test.rkt`,
  `tests/frame-pane-api-test.rkt` — update single-pane invariants + add multi-pane
  render assertion.

## New files

- `tests/core-pane-layout-test.rkt` — split/delete/promote/cycle + tree shape +
  marker independence + visible-leaf ordering.

## Deleted files

- `weevil/private/core/window-state.rkt` — the unused parallel representation.

## Dependencies

- Task 1 (tree + ops) is the foundation for Tasks 3–5, 10, 12.
- Task 2 (delete window-state) is independent but should land early to lock the
  single-representation decision.
- Tasks 3/4/5 depend on Task 1; Task 6 depends on 3/4/5; Task 7 depends on 6.
- Task 8 (scratch fate) depends on 6/7; Task 9 (retire with-visible-pane) depends
  on 3/5/8.
- Tasks 10/11 (render+CSS) depend on Task 1's walk; Tasks 12/13 depend on the
  features they cover. Land in small vertical slices (one op end-to-end at a time)
  keeping the suite green.

## Risks

- **Destructive `frame-state-with-visible-pane`**: any accidental reuse during
  split/cycle silently collapses the tree. Route all selection changes through
  `frame-state-with-selected-pane`; remove the destructive fn once callers are
  gone (Task 9).
- **Marker aliasing**: a split must allocate a fresh pane-state; never copy the
  source pane's marker objects. Test by mutating one pane's point.
- **Datastar id churn**: index-based pane/container ids shift on split and cause
  teardown+rebuild (lost cursor/scroll/focus). Use pane-id-derived stable ids;
  give genuinely new panes new ids only.
- **`rev` discipline / no-op semantics**: single-leaf delete/cycle and
  delete-other on a lone leaf must be eq?-stable with NO rev bump (SSE diff
  correctness; existing tests rely on this pattern).
- **`pane-order` drift**: cycle order now derives from the tree; leaving the field
  populated but unused risks confusion — comment it as bookkeeping-only and re-grep
  before any later removal.
- **Struct arity**: adding `pane-split` is additive (new struct, not a field
  change); confirm no positional `match`/constructor on `frame-state` breaks.
- **Combination flattening**: nested same-axis splits should flatten to keep the
  tree shallow and CSS equal-division intuitive; getting the insert-after-source
  position right matters for depth-first cycle order.
- **Orphaned pane-states**: `delete-pane` leaves the removed pane-state in the
  hash (not garbage-collected). Acceptable for v1; note for a later cleanup.

## Non-goals (deferred)

- Mouse OR keyboard resize; stored pixel sizes; per-child weights; `balance-panes`
  (splits are always equal via flex).
- Multiple frames.
- Prefix-key sequences (`C-x …`); only single chords for now.
- Persistence / serialization of the layout (`window-state-get/put`).
- `display-buffer` / `display-buffer-alist` policy engine.
- The `window-state.rkt` parallel model (being deleted, not migrated).
