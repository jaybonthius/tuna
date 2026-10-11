# Scrollable Tiling Layout (Niri-style) — Design Proposal

Status: **proposal, awaiting owner sign-off** (no editor code until approved)
Date: 2026-06-18
Research: `plans/niri-research/01..05` (Niri scrolling model, workspaces/focus/movement,
resize/tabs/keybindings, Datastar/CQRS, Datastar SDK verification)

---

## 0. TL;DR

Build weevil's layout as a **Niri workspace stack**, mapped 1:1 onto concepts weevil
already has:

| Niri | weevil | owns |
| --- | --- | --- |
| Monitor (vertical stack of workspaces) | **session** (already the top object) | the stack of frames + which frame is active |
| Workspace = a horizontal scrolling strip | **frame** (already "the container of panes") | ordered **columns**, active column, horizontal **view-offset** |
| Column (vertical stack of tiles) | **column** (new) | ordered **panes**, active pane, column **width** |
| Tile (a window) | **pane** (already a view onto a buffer) | point/mark/scroll + **height policy** |
| Window content | **buffer** (already) | text |

The whole layout is server state. Horizontal strip scrolling and frame switching are
**server-computed and rendered as inline position/size styles** (the same way `render.rkt`
already renders the virtual-scroll `translateY`) — *no* native horizontal scrollbar, *no*
client-side scroll math. The browser keeps owning only **per-pane native *vertical*
scrolling** of buffer text (the existing `virtual-scroll.rkt` mechanism, ported from
hyperlith), reporting each visible pane's `scrollTop` back to the server.

**The down-channel stays exactly what it is today: one long-lived SSE stream, one
whole-`#weevil-root` fat morph per revision — permanently. No per-pane / scoped patches.**
The fat morph stays cheap not by splitting it, but by **rendering only what is on screen**:
only the active frame, only the columns intersecting the viewport, and (within each pane)
only the visible buffer lines. An off-screen column or a non-active frame is simply not
rendered — the same principle that already bounds the vertical line window (and that
hyperlith's billion-checkboxes uses for its 2D grid).

This **supersedes** the unbuilt Emacs-style recursive-split plan
(`plans/pane-layouts-plan.md`): weevil gets a scrollable strip, not a binary split tree.

Single-frame strip ships first (columns, stacking, focus, move, scroll, resize), then the
**stacked-frames** dimension. Keyboard resize is in; **mouse resize is deferred**.

---

## Owner decisions locked (2026-06-18)

From the sign-off conversation — these are settled; the rest of the doc reflects them:

1. **Build single-frame strip first, add stacked frames after** — yes.
2. **Niri fidelity cutline** (§9 Decision 3 IN/OUT list) — yes.
3. **Keymap modifier = Super (`s-`).** Super is reserved for this window-manager layer.
   The one existing Super binding (`s-o`, a duplicate of `C-x o`) is removed from Super.
   Full map in §7.
4. **Mouse resize = OUT** for the first pass — yes.
5. **Fat morph is the ONLY state-down channel, permanently. No per-pane / scoped patches,
   no `data-ignore-morph`.** The server renders the whole on-screen UI every step; cost is
   bounded purely by rendering only on-screen content (§5.3). (Removed the old "Decision 6.")
6. **Containment is exactly frame → column → pane.** A frame directly holds columns; a
   column holds one or more vertically stacked panes. Width is per-column (shared); height
   policy is per-pane. No 4th "slot" concept.
7. **Minibuffer = one shared bottom line (Emacs-style)**; `minipane-id` hoisted to the
   session (§9 D8).
8. **Empty/dynamic frames: follow Niri** — always one empty frame at the bottom, auto-remove
   emptied ones (§9 D9).
9. **Abandon the old Emacs split-window plan**, delete dead `window-state.rkt`, repurpose
   `C-x p`/`C-n` (§9 D10).
10. **Edge fall-through: none** (match Niri's default); frames switch on their own keys
    (§9 D12).
11. **Terminals need no special layout handling** — just a buffer in a pane; size the pty
    from the pane's rect (§9 D11). Nothing in the terminal work is broken.

All §9 decisions are now settled.

---

## 1. What exists today (grounding)

- **One frame, one visible pane.** `frame-state = (id root selected-pane-id minipane-id)`
  where `root` is a single `pane-leaf`. `frame-state-with-visible-pane` *collapses* root
  to one leaf. Multiple panes exist (`panes` hash + `pane-order`) but only one is visible;
  `other-pane!` / `make-scratch-pane!` swap which one. (The recursive split tree in
  `pane-layouts-plan.md` was planned but **never built**.)
- **`pane-state = (id buffer-id point-marker mark-marker mark-active? scroll-top-px
  view-height-px)`** — per-pane point/mark and the client-authoritative native scroll
  position + viewport height in px.
- **Rendering** = `render-editor-app` builds the whole editor xexpr and
  `patch-elements/xexprs` morphs it into `#weevil-root` every revision (fat morph).
  `render-editor-window` virtualizes the *selected* pane (renders only ~visible lines via
  `virtual-scroll.rkt`), positioning them with an inline `transform: translateY(...)`.
  Native vertical scroll is reported via `$scrollTop`/`/scroll`; viewport via
  `$viewH`/`/resize`; the cursor re-anchor emits an instant-scroll `execute-script`.
- **Single-writer event loop**: every key/scroll/resize/file/terminal event rides one
  async-channel and one thread; `/scroll` and `/resize` act on the **selected pane**.
- **Datastar SDK (verified, `plans/niri-research/05`)**: `patch-elements/xexprs` takes a
  *list* of xexprs → multiple morph-by-id targets in one event; `#:selector`/`#:mode`
  target one element; `patch-signals` pushes signals with no DOM morph. Inline `style`
  for geometry is already the house pattern.

## 2. Research summary (what the Niri briefs concluded)

Full detail in `plans/niri-research/01..03`. The model essentials we are porting:

- **Three-level nesting, each with its own active index**: strip (`active_column_idx` +
  `view_offset`) → column (`active_tile_idx` + `width`) → tile (`height` policy). A column
  is **never empty** (removing its last tile removes the column).
- **`view_offset` is the horizontal scroll, stored *relative to the active column***, and
  recomputed on focus/add/remove/resize by a **fit** rule (least motion to keep the active
  column on screen, with ≤ one gap of padding) — default centering mode is `never`.
- **Column width** = `Proportion(p)` | `Fixed(px)`; proportions are **gaps-aware**
  (`(work−gaps)·p − gaps`) so N columns of `1/N` tile exactly. Presets default `1/3,
  1/2, 2/3`; `switch-preset-column-width` cycles them.
- **Window heights within a column**: every pane but one is `Auto{weight}`; the column
  auto-distributes leftover height by weight (with min-height pinning). Setting a height
  freezes it to `Fixed` and converts the others to weighted `Auto`. Only one non-auto per
  column.
- **Focus** is the chain of active indices; `focus_left/right` move columns,
  `focus_up/down` move within a column, and the ergonomic `focus_{up,down}_or_{left,right}`
  cross the column boundary when at an edge. No wraparound.
- **Movement**: `move_column_left/right` (reorder columns; focus follows),
  `move_window_up/down` (reorder within a column), `consume/expel` (merge a pane into a
  neighbor column / split it out), `swap_window_in_direction`.
- **Workspaces stack vertically on a monitor** (`Vec<Workspace>` + `active_workspace_idx`),
  with a **dynamic model**: always one empty workspace at the bottom; empty unnamed
  non-active workspaces are auto-removed. Switching sets the active index (animated in
  Niri; we switch plainly). Move-column/window-to-workspace = detach from one strip,
  attach to another (by id). `move_workspace_up/down` reorders the stack.
- **Resize** keyboard ops: switch-preset width/height, set/adjust width/height by px or %,
  maximize-column (full width, keeps gaps), expand-to-available-width, reset-window-height,
  center-column. **Mouse/interactive resize** is the same `SetFixed` path keyed off
  pointer edges — explicitly **deferrable**.
- **Tabbed columns** are just a display flag on a column (one tile visible, shared height,
  a tab indicator) — a clean later add, not core.

## 3. Design principles

1. **1:1 with Niri's data model, minus the Wayland/GPU/animation parts.** The model is
   pure integers/structs; we reproduce the strip/column/pane indices and the view-offset /
   width / height math, and skip everything visual-only.
2. **The layout is entirely server state**, mutated only on the single-writer event loop
   through `state-with-rev` (monotonic `rev`, eq?-stable no-ops), exactly like every
   existing transition.
3. **Server commands position; browser only observes where it must.** Horizontal strip
   offset, column widths, pane heights, and which frame is shown are **computed server-side
   and rendered as inline styles**. The browser owns only **native vertical scroll of each
   pane's text** and reports it back. (This asymmetry — server-commanded horizontal,
   browser-observed vertical — is the Datastar brief's headline recommendation and matches
   "the server owns scroll position.")
4. **No new client editor logic.** Same as today: HTML/`style` down via SSE morph; keys/
   scroll/resize up via `@post`. No client layout engine.
5. **One fat-morph down-channel; bound its cost by rendering only on-screen content.** The
   whole-`#weevil-root` fat morph per revision is the *sole* state-down channel — unchanged
   from today and not negotiable. It stays cheap by rendering only the active frame, only
   on-screen columns, and only visible lines per pane (never by splitting into per-pane
   patches). "Don't render what isn't on screen" is the same principle that already bounds
   the vertical line window and that hyperlith's billion-checkboxes uses for its 2D grid.
6. **Three levels, no parallel arrays.** Containment is exactly **frame → column → pane**.
   A column owns the one thing all its panes share (the width); a pane owns the one layout
   thing that's per-pane (its height policy). No 4th "slot" concept, and no parallel
   index-locked vectors (the footgun Niri itself flags with its `columns`/`data` pairs).

## 4. Server-side state model

New private modules (mirroring the existing `frame-state.rkt`/`pane-state.rkt` split):

```
weevil/private/core/column-state.rkt   ; a column = vertical stack of panes + a shared width
weevil/private/core/strip-state.rkt    ; (replaces frame-state.rkt) a frame = strip of columns
weevil/private/core/layout-geometry.rkt; pure px math: view-offset fit, widths, heights
```

### 4.1 Structs (immutable; persistent-update style like the rest of core)

```scheme
;; A column: a vertical stack of panes sharing one width. NON-EMPTY.
;; It just lists its panes by id (top->bottom); the per-pane height policy lives on the
;; pane itself (below), so there are no parallel id/height arrays to keep in sync.
(struct column-state
  (id
   pane-ids          ; (non-empty listof pane-id), top->bottom
   active-pane-idx   ; exact-nonneg < (length pane-ids)
   width             ; (proportion p) | (fixed px)   -- desired policy, SHARED by all panes
   preset-width-idx  ; (or/c #f exact)               -- cursor for switch-preset
   full-width?)      ; boolean
  #:transparent)

;; pane-state (existing, in the `panes` hash) gains ONE layout field: its height policy
;; within its column. A pane lives in exactly one column, so this is unambiguous.
;;   height : (auto weight:flonum) | (fixed px:real) | (preset idx:exact)

;; A frame = a scrolling strip of columns (Niri "workspace"). Reuses the name `frame`
;; (weevil already calls the pane container a frame). Renamed from frame-state's old shape.
(struct frame-state
  (id
   columns            ; (listof column-state), left->right; MAY be empty
   active-column-idx  ; (or/c #f exact-nonneg)  -- #f iff columns is empty
   view-offset        ; real px, horizontal scroll RELATIVE TO the active column
   restore-view-offset; (or/c #f real) -- Niri's activate_prev_column_on_removal: the
                      ;   camera offset to return to when a just-opened column is closed
   minipane-id)       ; (see Decision 8 re: minibuffer/minipane ownership across frames)
  #:transparent)
```

`session-state` change: replace the single `frame` field with a **stack**:

```scheme
;; was: frame
frames            ; (non-empty listof frame-state), top->bottom (vertical workspace stack)
active-frame-idx  ; exact-nonneg < (length frames)
;; everything else (buffers, panes hash, pane-order, selected-input-target,
;; minibuffer-stack, histories, rev, counters, message) is UNCHANGED.
```

The `panes` hash (pane-id → `pane-state`) and `buffers` hash stay exactly as they are. The
strip/column structures only ever hold **pane-ids**; the per-pane view state (point/mark/
scroll/buffer) keeps living in `panes`, just like `frame-state-root` references pane-ids
today. New helpers: `session-active-frame`, `session-active-frame-strip`, and
`session-selected-pane-id` becomes "active frame → active column → active pane".

### 4.2 Where geometry lives

The server needs pixel sizes to render. Two inputs come from the client, everything else is
derived:

- **viewport size** (the editor area's `clientWidth`/`clientHeight`) — reported once per
  resize (one global signal, replacing today's single-pane `$viewW`/`$viewH`).
- **cell metrics** `cellW`/`cellH` — global (monospace), measured once (the existing
  `.editor__measure` probe).

From those + the layout, a pure **layout pass** (`layout-geometry.rkt`) computes, for the
active frame: the working area, each column's x + width (px), and each pane's content
rect (px). It writes each visible pane's computed content-height into its `pane-state`
`view-height-px` so the **existing** windowing (`compute-window`) and cursor re-anchor
(`ensure-point-visible`) keep working unchanged — they already read `view-height-px`. The
only change is *who sets it*: a server layout pass on resize/structural-change, instead of
the client's per-pane `/resize`. **Per-pane vertical `scroll-top-px` stays client-reported**
(native scroll), routed to the right pane by id.

### 4.3 The view-offset (horizontal scroll) math — ported from Niri

`view-pos = column-x(active) + view-offset`. On focus/add/remove/resize, recompute
`view-offset` with the **fit** rule (`compute_new_view_offset` in brief 01 §4.3): if the
active column is already fully visible, leave it (re-based); else snap to whichever edge is
less motion, with ≤ `gaps` padding. Default centering = `never`. This keeps the active
column on screen and produces the "scroll the strip as you move right" feel. All pure;
no animation in v1 (snap instantly). `gaps` is a config constant (default 16px).

Two Niri details to port so the camera *feels* right (flagged by review):
- **Restore memory** (`restore-view-offset`): opening a column right of the active one
  records the current offset; closing that column returns the camera home instead of
  re-fitting from scratch.
- **Leading-gap convention**: Niri's `column-x(0) = 0` (no leading gap); the left margin is
  produced *entirely* by `view-offset` (≈ `-gaps`). The Phase-0 geometry kernel must pin
  this so the DOM (per-column `screen-x` positions) does not double-count the left gap.

Note weevil **collapses two Niri distinctions** that we therefore don't model: window-vs-
tile size (panes have no border) and desired-vs-realized column width (panes always accept
their assigned size, unlike Wayland clients that can refuse). Width still clamps to a pane
min/max.

### 4.4 Column width + pane height math — ported from Niri

- **Width resolve**: `proportion p → (working_w − gaps)·p − gaps`; `fixed → px`; clamp to
  pane min/max (panes have generous min widths). Presets `1/3,1/2,2/3`; `switch-preset`
  cycles (brief 01 §2.4–2.5, brief 03 §1.2).
- **Height distribute** (brief 01 §3.3): per column, convert each pane's `fixed`/`preset`
  height to px, subtract from the budget `working_h − gaps·(n+1)`, distribute the rest among
  the `auto` panes by weight with min-height pinning. Only one non-auto pane per column;
  setting a height converts the others to weighted `auto` (median = weight 1).

These are small pure numeric functions with unit tests — the natural first thing to build
and the easiest to get exactly right.

## 5. Datastar / CQRS rendering approach

### 5.1 DOM shape (server-rendered every revision)

```html
<main id="weevil-root" ... data-on:keydown__window=...>
  <section class="weevil-frame" data-frame-id="frame-3">
    <!-- the STRIP clips; ONLY on-screen columns are rendered, each at its server-computed
         screen-x = column-x(i) - view-pos. Off-screen columns are not in the DOM at all. -->
    <div class="weevil-strip" style="position:relative; overflow:hidden;">
      <section class="weevil-column" id="col-7" style="position:absolute; left: 0px; width: 760px;">
        <!-- one pane; height computed server-side -->
        <section class="weevil-pane" id="pane-12" style="height: 520px;" ...>
          <div class="editor" id="editor-pane-12" ...native vertical scroll...>…windowed lines…</div>
          <section class="weevil-mode-line" id="mode-line-pane-12">…</section>
        </section>
        <section class="weevil-pane" id="pane-19" style="height: 360px;" ...>…</section>
      </section>
      <section class="weevil-column" id="col-8" style="width: 900px; left: 776px;">…</section>
    </div>
  </section>
  <!-- session-level, below the active frame -->
  …minipane / echo / completions (unchanged)…
</main>
```

- **Strip = horizontally virtualized, server-positioned.** The server computes each
  column's on-screen x (`screen-x = column-x(i) - view-pos`, §4.3) and **renders only the
  columns that intersect the viewport** (optionally ± one margin column), each absolutely
  positioned at its `screen-x` with its computed px width. Off-screen columns are not
  rendered. **No native horizontal scrollbar, no client horizontal scroll math** — moving
  focus recomputes `view-offset` and the next fat morph re-positions the visible columns.
  (This is the "don't render off-screen" principle, the horizontal analog of the existing
  vertical line window.)
- **Each pane** keeps its own `.editor` native vertical scroller with a **stable unique
  id** (`editor-<pane-id>`) so Idiomorph reuses the node across morphs and preserves its
  `scrollTop`/focus. `render-editor-window` is generalized to take an explicit pane-id +
  its computed content-height (the pane-layouts-plan already anticipated extracting
  `render-pane`).
- **Per-pane scroll/resize reporting** bakes the pane id into the `@post` payload (exactly
  like `select-input-target-expression` bakes a pane id today):
  `data-on:scroll="@post('/scroll',{payload:{paneId:'pane-12',scrollTop:Math.floor(el.scrollTop)},…})"`.
  The event loop routes the report to *that* pane, not "the selected pane".
- **Per-pane scroll signals + the buffered-edge re-arm must be de-globalized (Phase-1
  blocker, flagged by review).** Today the buffer windowing relies on GLOBAL signals
  `$scrollTop`/`$viewH` and a self-removing `threshold-effect-expr` data-effect that posts
  `/scroll` only when the user scrolls past the buffered edge. With N scrollers, all panes
  would clobber the *same* `$scrollTop` signal (last-writer-wins) and the per-pane
  thresholds break. Fix in Phase 1: the threshold/re-arm expression reads the bound
  element's own `el.scrollTop`/`el.clientHeight` directly (not a shared signal), and the
  server renders each pane's own threshold bounds into that pane's `data-effect`. (Per-pane
  namespaced signals are the alternative, but reading `el` directly matches the existing
  `data-on:scroll` idiom and needs no nested-signal machinery.)
- **Cursor re-anchor / scroll-restore** `execute-script` must select the pane's scroller by
  id (`#editor-pane-12`) instead of the global `document.querySelector('.editor')`. This is
  a **latent bug**, not just a generalization: the current first-match query would always
  re-anchor the *first* pane the instant a second scroller exists — so it must be fixed as
  soon as Phase 1 renders two panes.

### 5.2 Stacked frames switching

Render **only the active frame** (Datastar brief Q4 recommendation). A frame switch
re-renders `#weevil-root` with the new frame's strip. Because only the active frame is in
the DOM, a pane re-mounts when you switch back → its native `scrollTop` would reset — but
**the server already stores each pane's `scroll-top-px`**, so on (re)render it emits a
per-visible-pane instant scroll-restore `execute-script` (the existing `reanchor-script`
generalized). Net: switching frames is plain and correct, with scroll restored from server
state. (Render-all-frames + `data-show` is rejected: it multiplies steady-state morph cost
by the number of frames and `display:none` can drop `scrollTop`.)

### 5.3 Why the fat morph stays cheap (no scoped patches — owner-locked)

The single whole-`#weevil-root` fat morph per revision is the only state-down channel,
permanently. We do **not** split it into per-pane / `#:selector` patches. It stays cheap
because the rendered tree only ever contains **on-screen content**:

- only the **active frame** (§5.2),
- only the **columns intersecting the viewport** (§5.1),
- within each visible pane, only the **visible buffer lines** (existing `virtual-scroll.rkt`).

So the DOM is ~(visible columns × their panes × ~visible lines) — a few hundred line divs
at most, comparable to today's single pane. **Stable, globally-unique ids** on
frame/column/pane/scroller/mode-line let Idiomorph reuse the existing nodes (mutating them
in place rather than recreating them), which is what preserves each pane's native
`scrollTop`/focus across a morph. The server always renders the full on-screen UI; the
client never withholds any of it.

### 5.4 The one behavioural gate

Whole-root morph preserving **multiple** native scrollers' `scrollTop` rests on the same
Idiomorph in-place-morph-by-id property already proven for the single pane. I can't
unit-prove it without a browser, so Phase 1 includes an explicit **2-pane manual check**
(two columns, scroll each independently, type in one; confirm neither pane's scroll
jumps). If it ever fails, the fallback is fully server-side and stays a single fat morph:
the server already stores each pane's scroll offset, so it re-asserts the right `scrollTop`
via the same scroll-restore `execute-script` it uses on frame switch. (No client-side
preservation, no scoped patches.)

## 6. Event-loop / command integration

- All layout ops are **pure `session-state` transitions** through `state-with-rev`, run on
  the existing single thread. No new concurrency, no new channels.
- `/scroll` gains a `paneId` and updates *that* pane's `scroll-top-px` (today it updates the
  selected pane). `/resize` reports the global viewport + cell metrics and triggers the
  layout pass that recomputes visible panes' `view-height-px`.
- `ensure-point-visible` (cursor re-anchor) runs for the **focused** pane after a key, as
  today; structural ops (add/remove/focus/move/resize/switch-frame) run the layout pass and
  may emit scroll-restore scripts for newly-visible panes.
- The deprecated `weevil/private/core/window-state.rkt` (dead scaffolding) is deleted, and
  `pane-layouts-plan.md`'s recursive split tree is **not** built (superseded).
- **Terminals are just panes — no special layout handling.** A terminal is a `'terminal`-kind
  buffer shown in an ordinary pane; the strip/column/focus/move code never knows the
  difference. The *only* terminal-specific bit is sizing the pty grid: today
  `maybe-resize-terminal!` reads the *global* viewport (fine when there's one pane). Since
  the layout pass already computes every pane's pixel rect, the change is just "size the
  controller from *this pane's* rect (× cell metrics) instead of the global viewport," and
  the wheel/scroll-back routes to the *reporting* pane's controller via the same `paneId`
  every pane already sends. It falls out of the layout pass — a few lines, not a punt, and
  nothing in the existing terminal work is broken.

## 7. Keymap / interaction design

**Modifier = Super (`s-`)** (locked). Super is the window-manager layer (Niri's Mod), so the
hot navigation/move/resize keys are **single `s-` chords** — the thing that makes Niri feel
fast. weevil's only current Super binding, `s-o` (a duplicate of `C-x o` →
`cycle-focus-target`), is **removed from Super**; `C-x o` keeps that function. `s-` maps to
`metaKey` (Cmd on macOS, Super on Linux/Windows), matching the existing `s-o` encoding.

Default map (Niri mnemonics; `hjkl` + arrows; `s-S-` = move; frame = Niri workspace):

**Focus** (move the selection)
| Key | Command | Niri analog |
| --- | --- | --- |
| `s-h` / `s-Left` | focus-column-left | `focus-column-left` |
| `s-l` / `s-Right` | focus-column-right | `focus-column-right` |
| `s-j` / `s-Down` | focus-pane-down (in column) | `focus-window-down` |
| `s-k` / `s-Up` | focus-pane-up | `focus-window-up` |
| `s-Home` / `s-End` | focus-column-first / -last | `focus-column-first/last` |

**Move** (relocate the focused column/pane)
| Key | Command | Niri analog |
| --- | --- | --- |
| `s-S-h` / `s-S-l` | move-column-left / -right | `move-column-left/right` |
| `s-S-j` / `s-S-k` | move-pane-down / -up (in column) | `move-window-down/up` |
| `s-[` / `s-]` | consume-or-expel-pane-left / -right | `consume-or-expel-window-left/right` |
| `s-,` / `s-.` | consume-pane-into-column / expel-pane | `consume-window-into-column` / `expel-window-from-column` |

**Frames** (the vertical workspace stack)
| Key | Command | Niri analog |
| --- | --- | --- |
| `s-u` / `s-i` (also `s-PageDown`/`s-PageUp`) | focus-frame-down / -up | `focus-workspace-down/up` |
| `s-S-u` / `s-S-i` | move-column-to-frame-down / -up | `move-column-to-workspace-down/up` |
| `s-1`…`s-9` | focus-frame N | `focus-workspace 1..9` |
| `s-x k` / `s-x j` | move-frame-up / -down (reorder the stack) | `move-workspace-up/down` |

**Open / close / resize**
| Key | Command | Niri analog |
| --- | --- | --- |
| `s-Enter` | new-column (open a scratch pane in a new column) | spawn window |
| `s-x q` | close-pane (Chrome eats single `s-q`, so it goes under the prefix) | `close-window` |
| `s-r` / `s-S-r` | switch-preset-column-width fwd / back | `switch-preset-column-width(-back)` |
| `s--` / `s-=` | set-column-width −10% / +10% | `set-column-width ±10%` |
| `s-f` | maximize-column (toggle full width) | `maximize-column` |
| `s-c` | center-column | `center-column` |
| `s-S--` / `s-S-=` | set-pane-height −10% / +10% | `set-window-height ±10%` |
| `s-x f` | expand-column-to-available-width | `expand-column-to-available-width` |
| `s-x r` / `s-x 0` | switch-preset-pane-height / reset-pane-height | `switch-preset-window-height` / `reset-window-height` |

A small **`s-x …` layout prefix** hosts the rarer ops (move-frame, expand-column, pane-
height presets/reset) so the hot keys stay single chords.

**OS/browser capture caveat (Chrome — owner-tested).** Owner confirmed on Chrome (and
Firefox/Safari) that the page receives essentially all `s-` chords — including `s-r`,
`s-f`, `s-c`, `s-1..9` — **except `s-w` and `s-q`**, which the browser keeps for close-tab
/ quit. The map avoids `s-w` entirely and puts close-pane on `s-x q` (under the prefix)
instead of `s-q`. Any further per-binding surprises get caught/remapped in Phase 1. The
existing `C-x p` / `C-n` pane commands are re-pointed at the
new model (open new column / cycle panes) or retired.

## 8. Phased plan

Each phase is independently green, reviewed, and committed (worker→reviewer loop).

- **Phase 0 — geometry kernel.** `layout-geometry.rkt`: pure view-offset fit, gaps-aware
  width resolve, auto-height distribution + unit tests. No rendering, no state wiring.
- **Phase 1 — single frame, single-pane columns (the MVP).** Replace `frame-state` with
  the strip model (columns each holding exactly one pane). Commands: new-column,
  close-pane (=remove column), focus-left/right, move-column-left/right. Render only
  on-screen columns, each absolutely positioned at its server-computed `screen-x` + width;
  per-pane `.editor` scrollers with stable ids; per-pane scroll routing by id. Explicit blockers in this phase (per review): (a)
  **de-globalize the scroll signals + buffered-edge re-arm** so each pane windows off its
  own `el.scrollTop` (§5.1); (b) **pane-scope the cursor re-anchor `execute-script`** to
  `#editor-<pane-id>` (§5.1 latent bug); (c) **server layout pass writes per-pane
  `view-height-px`** with a `default-view-height-px` fallback before the first viewport
  report (keep `compute-window` byte-identical for the single-pane golden tests); (d) the
  **2-pane scroll-preservation manual check (§5.4)**. Re-point `make-scratch-pane`/
  `other-pane`. Width resize (presets, ±%, full-width, center). → *This is the "single
  strip" slice you can drive and feel.*
- **Phase 2 — vertical stacking in a column.** Multiple panes per column;
  focus-up/down (+ `_or_left/right` edge crossing); move-pane-up/down; consume/expel;
  auto-height distribution + per-pane height resize/reset. Per-pane mode-lines with active
  highlighting.
- **Phase 3 — stacked frames.** `session.frames` + `active-frame-idx`; render active frame
  only; switch-frame up/down/by-number with scroll-restore; move-column/pane-to-frame;
  move-frame (reorder); the dynamic empty-bottom-frame model (Decision 9).
- **Phase 4 — polish (post-v1, individually optional).** Tabbed columns; always/on-overflow
  centering; mouse resize (Decision 5); persistence of the layout to SQLite. (No patch-
  scoping work — fat morph is permanent per Decision 6; any morph-cost tuning stays within
  the single morph — e.g. the server re-asserting scroll via its scroll-restore script.)

## 9. Decisions I need from you

1. **Terminology.** Reuse **`frame`** for the Niri-workspace (a strip of columns; weevil
   already calls the pane container a frame), add **`column`** (new), keep **`pane`** for a
   buffer view (= Niri tile). *Recommend: yes.* (Alternative: call the workspace-stack item
   a "workspace" and reserve "frame" — but that fights the existing ADR/code.)

2. **Build order / MVP.** Ship the **single-frame strip first** (Phases 1–2), add stacked
   frames (Phase 3) after. *Recommend: yes* — it's a coherent, demoable slice and frames
   are an additive outer layer.

3. **Niri fidelity for v1.** *Recommend IN:* columns, vertical stacking, focus (incl. edge-
   crossing), move column/pane, consume/expel, server-scrolled strip (fit, never-center),
   stacked frames, move-to-frame, move-frame, keyboard resize (preset/±%/full-width/
   expand/center for width; preset/±%/reset for height). *Recommend OUT/deferred:* tabbed
   columns, always/on-overflow centering, floating layer, fullscreen/maximize-to-edges,
   animations, named/static frames, overview, persistence, mouse resize.

4. **Keymap family = Super (`s-`) — LOCKED.** Mirrors Niri's Mod 1:1; `s-o` (a dup of
   `C-x o`) is removed from Super (§7). Platform = **Chrome** (owner-tested on Chrome/
   Firefox/Safari): all `s-` chords reach the page except **`s-w`** and **`s-q`**, which
   the browser keeps. Map avoids `s-w`; close-pane is `s-x q` (not `s-q`). Done — no further
   input needed.

5. **Mouse resize.** *Recommend OUT for the first pass* (keyboard resize covers the core;
   mouse drag is the same `SetFixed` path and can be added in Phase 4). Confirm deferral.

6. **Datastar patch scope — LOCKED: fat morph only.** Per your direction, the
   whole-`#weevil-root` fat morph is the sole state-down channel, permanently; we never
   split into per-pane patches. Cost is bounded by rendering only on-screen content (§5.3).
   (No action needed — recorded here so the decision is explicit.)

7. **Horizontal scroll mechanism — SETTLED.** Server-positioned columns: render only the
   on-screen columns, each absolutely positioned at its computed `screen-x` inside a
   clipping strip; no native horizontal scrollbar. Fully server-authoritative.

8. **Minibuffer = shared bottom line (Emacs-style) — CONFIRMED.** One prompt/echo line at
   the bottom, shared across all frames. `minipane-id` is hoisted to `session-state` so it
   no longer belongs to any one frame.

9. **Empty / dynamic frame model — CONFIRMED (follow Niri).** An "empty frame" is just a
   frame with no columns yet — blank space you scroll down into and start opening panes in.
   Niri's rule: always keep one empty frame waiting at the bottom of the stack, and
   auto-remove a frame once you leave it empty. We follow that.

10. **Supersede the recursive-split plan — CONFIRMED.** We abandon
    `plans/pane-layouts-plan.md` (Emacs `C-x 2/3/0/1` split tree), delete the dead
    `window-state.rkt`, and re-map/retire the current `make-scratch-pane`/`other-pane`/
    `C-x p`/`C-n` commands onto the new model.

11. **Terminals — RESOLVED (no special handling).** A terminal is just a `'terminal`-kind
    buffer in an ordinary pane; nothing in the existing terminal work is broken. The only
    terminal-specific bit is sizing the pty to *its pane's* computed rect (the layout pass
    already computes every pane's rect) and routing the wheel to the reporting pane's
    controller — a few lines, done as terminal panes start sharing a strip (Phase 2/3).

12. **Edge fall-through — CONFIRMED (match Niri's default = none).** Niri's *default* binds
    are non-escalating (`focus-window-down` stops at the bottom pane; the escalating
    variant ships commented-out). So pane up/down crosses only *column* edges; frames
    switch on their own keys (`s-u`/`s-i`). Easy to add escalation later if you want it.

## 10. Risks & open questions

- **Multi-scroller morph preservation (§5.4)** — the one unproven browser behaviour;
  gated by the Phase-1 manual check; fallback is the server re-asserting each pane's
  `scrollTop` via its scroll-restore script (§5.4) — still one fat morph, never scoped patches.
- **Horizontal overflow vs the existing virtual-scroll CSS.** Today `.editor__translate`
  uses `width:max-content` so long lines grow a *native horizontal* scrollbar inside the
  pane. Inside a fixed-width column that's fine (the pane clips/scrolls its own long
  lines); the **strip** clips and positions each visible column at its `screen-x` (a
  separate outer axis). Need to confirm the two horizontal axes (per-pane line overflow vs
  strip column positions) don't visually fight — verify in the Phase-1 browser check.
- **`view-height-px` ownership flip.** Moving it from client-`/resize` to server-layout-pass
  touches the windowing/re-anchor path; must keep `compute-window` byte-identical for the
  single-pane case (regression-test it).
- **Focus vs `selected-input-target` vs minibuffer.** The focus chain must always set
  `selected-input-target` to the focused pane; minibuffer activation still overrides it.
  Existing tests pin this; extend them for multi-pane.
- **Keymap collisions / browser capture.** Whatever family you pick, a few chords may be
  intercepted by the browser/OS; I'll verify reachability per binding (as the pane/terminal
  work already did) and note any that need an alternate.
- **First-paint geometry.** With `view-height-px` now set by a server layout pass, the very
  first render (before the client reports the viewport) must fall back to
  `default-view-height-px` (600) for visible panes — otherwise a pane paints ~1 line. Pin
  this so the single-pane `compute-window` golden output is unchanged.
- **Persistence shape.** Out of scope for v1, but the strip/column/frame structs should be
  serializable from the start (plain data + ids) so SQLite snapshotting is a later
  add, not a refactor.
```
