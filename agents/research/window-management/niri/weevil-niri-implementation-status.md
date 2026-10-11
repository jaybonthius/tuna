# Scrollable Tiling Layout — Implementation Status

Branch: `niri-layout` (worktree). Design: `plans/niri-scrollable-layout-design.md`.
All `raco test tests` green (≈681k assertions, 0 failures). Built in small,
reviewed, individually-green commits.

## What's implemented (the v1 core, as planned)

**Model (server-side state).** `frame → column → pane`, three clean levels:
- `column-state` (new): a non-empty list of pane-ids + active index + width policy.
- `frame-state` (rewrote): a scrolling strip = ordered columns + active-column
  index + horizontal `view-offset` (+ restore slot, minipane id). Plus the
  consume/expel ops.
- `session-state`: a **stack of frames** (`frames` + `active-frame-idx`);
  `session-state-frame` returns the active one. Per-pane height policy lives on
  `pane-state`. A `viewport` (w.h) reported by the client.
- `layout-geometry.rkt` (new, pure, dependency-free): gaps-aware width resolve,
  Niri least-motion view-offset fit, weighted auto height distribution, preset
  cycling. `layout.rkt` (new): frame px geometry + fit + width/center helpers.

**Behavior (all keyboard-driven, Super = the window-manager layer):**
- Columns on an infinite strip; horizontal scroll is server-computed
  (`view-offset` fit, rebased on every active-column change for least-motion) and
  rendered by absolutely positioning only the **on-screen** columns (horizontal
  virtualization). No native horizontal scrollbar.
- Open a column (`s-Enter`), close a pane/column (`s-x q`), focus columns
  (`s-h`/`s-l`/arrows/`s-Home`/`s-End`), move columns (`s-S-h`/`s-S-l`).
- Vertical stacking in a column via consume/expel (`s-[` `s-]` `s-,` `s-.`);
  focus/move panes within a column (`s-j`/`s-k`, `s-S-j`/`s-S-k`); multi-pane
  columns distribute height by weight.
- Stacked frames: switch (`s-u`/`s-i`, `s-PageDown`/`s-PageUp`), create-on-demand
  when scrolling past the bottom, reorder (`s-x j`/`s-x k`), close-removes-empty
  frame. Render only the active frame; per-pane native scroll is restored on
  remount (frame switch / column re-enter) from server-stored `scroll-top-px`.
- Width resize: presets `s-r`/`s-S-r` (1/3·1/2·2/3), `s--`/`s-=` (±10%), `s-f`
  (full-width), `s-c` (center). Height resize: `s-S--`/`s-S-=` (grow/shrink),
  `s-x 0` (reset).
- Rendering stays the existing **single `#weevil-root` fat morph**; the editor
  wiring is now **per-pane and signal-free** (each pane bakes its id into its
  `/scroll` + `/resize` posts and reads `el` directly). Cost is bounded purely by
  rendering only on-screen content (active frame, visible columns, visible lines).

## Keymap (Super family)

| Key | Action | | Key | Action |
| --- | --- | --- | --- | --- |
| `s-h`/`s-←` | focus column left | | `s-S-h`/`s-S-l` | move column left/right |
| `s-l`/`s-→` | focus column right | | `s-S-j`/`s-S-k` | move pane down/up |
| `s-j`/`s-↓` | focus pane down | | `s-[` / `s-]` | consume/expel left / right |
| `s-k`/`s-↑` | focus pane up | | `s-,` / `s-.` | consume-into / expel-from column |
| `s-Home`/`s-End` | first/last column | | `s-u`/`s-i` | focus frame down/up |
| `s-Enter` | new column | | `s-PageDown`/`s-PageUp` | focus frame down/up |
| `s-x q` | close pane | | `s-x j`/`s-x k` | move frame down/up |
| `s-r`/`s-S-r` | preset width fwd/back | | `s-S-=`/`s-S--` | grow/shrink pane height |
| `s--`/`s-=` | width −/+10% | | `s-x 0` | reset pane height |
| `s-f` | maximize column | | `s-c` | center column |

`s-o` was removed from Super (its focus-cycle stays on `C-x o`). Chrome reserves
only `s-w`/`s-q`, which the map avoids.

## Deliberate deviations / deferred (honest list)

- **Frame model (vs design D9):** every frame holds ≥1 pane (switch-down creates
  a *populated* frame; close drops an emptied one), rather than Niri's
  always-empty-bottom. This guarantees the active frame is never empty, so the
  selected pane is never `#f`. Cleaner/safer; recorded as a deviation.
- **`restore-view-offset`** (Niri "close returns the camera home") — field exists
  but is not yet wired (open-then-close re-fits instead). Minor fidelity gap.
- **move-column/pane-to-frame** (cross-frame moves) — not built (not in the
  explicit core list; "switching frames" is). Frame ops are in place to add it.
- **`s-1..9` focus-frame-by-number** — deferred (up/down covers navigation).
- **Mouse resize** — out for v1 (owner decision).
- **Tabbed columns, always/on-overflow centering, persistence** — out (planned
  later).
- **Inter-pane vertical gaps** — multi-pane columns currently tile with no gap
  between stacked panes (horizontal column gaps are present). Cosmetic.

## The one browser-only gate (not unit-testable here)

§5.4 of the design: a whole-root morph preserving the **native scrollTop of
multiple** pane scrollers relies on Idiomorph reusing nodes by stable id (proven
for one pane today). The server-side mechanism + a `data-init` scroll-restore on
remount are in place; **needs a 2-pane manual check in the browser** (open two
columns, scroll each, type in one, confirm neither scroll jumps). Fallback if it
ever regresses: the server re-asserts each pane's scrollTop via its
scroll-restore script — still one fat morph, never scoped patches.

## Commit sequence (branch `niri-layout`)

geometry kernel → strip data model → session column ops → per-pane signal-free
scroll/resize → frame layout + view-offset fit → strip render → nav commands+keys
→ width resize → consume/expel stacking → frame stack (state) → frame switching +
scroll-restore → frame keys → pane height distribution+resize → height keys →
click-sync + least-motion rebasing.
