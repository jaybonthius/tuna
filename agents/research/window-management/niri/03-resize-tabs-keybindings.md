# Niri Research — Resize Model, Tabbed Columns, and Default Keybindings

Source of truth (commit cloned at `/tmp/weevil-niri-ref/niri`):

- `resources/default-config.kdl` — default keybinds + layout block
- `niri.wiki/Configuration:-Key-Bindings.md`
- `niri.wiki/Configuration:-Layout.md`
- `niri.wiki/Tabs.md`
- `src/layout/scrolling.rs` — the `ScrollingSpace`/`Column` resize + tab logic
- `src/layout/tile.rs` — per-tile geometry (window vs. tile size, borders)
- `niri-config/src/layout.rs`, `niri-config/src/appearance.rs` — config defaults
- `niri-ipc/src/lib.rs` — `SizeChange`, `ColumnDisplay` enums
- `src/input/mod.rs` — Action → layout-method dispatch

Wayland protocol / GPU rendering is intentionally ignored. This brief covers
**the layout server model only** — the data structures, the geometry math, and
the action semantics we need to reimplement server-side in Racket.

---

## 0. Mental model (data structures)

A workspace's tiling area is a **`ScrollingSpace`** = a horizontal, infinitely
scrollable strip of **columns**. Each column is a vertical stack of **tiles**
(one tile == one window). Geometry vocabulary used everywhere below:

- **working area** — the output rectangle minus layer-shell panels minus
  `struts`. All proportional sizing is relative to this, *not* the raw output.
- **tile size** — a window plus its border decoration (`window + 2*border` on
  each axis when border is on).
- **window size** — the client content rectangle, *excluding* the border.
- **gaps** — uniform spacing placed *around* every tile (so they act as both
  inner and outer gaps; `struts` add extra outer-only gaps).
- **extra size** — space consumed by the tab indicator when
  `place-within-column` is set (0 otherwise, and 0 for non-tabbed columns).

Key Rust types (from `scrolling.rs` and `niri-ipc`):

```rust
// Width of a whole column.
enum ColumnWidth { Proportion(f64), Fixed(f64) }   // Proportion is 0..1, Fixed is logical px

// Height of one window within a column.
enum WindowHeight {
    Auto { weight: f64 },   // share of leftover height, weighted
    Fixed(f64),             // window height in logical px
    Preset(usize),          // index into preset-window-heights
}

// How a column lays out its tiles.
enum ColumnDisplay { Normal, Tabbed }

// Sizing override for the whole column.
enum SizingMode { Normal, Maximized, Fullscreen }

// The "change" requested by set-column-width / set-window-height actions.
enum SizeChange {
    SetFixed(i32),         // "1000"   -> exact px
    SetProportion(f64),    // "25%"    -> percent of working area (0..100)
    AdjustFixed(i32),      // "+5"/"-5"-> add/subtract px
    AdjustProportion(f64), // "+10%"/"-10%" -> add/subtract percent
}
```

A `Column` stores: `tiles: Vec<Tile>`, `data: Vec<TileData>` (per-tile
`WindowHeight` + cached size), `active_tile_idx`, `width: ColumnWidth`,
`preset_width_idx: Option<usize>`, `is_full_width: bool`,
`is_pending_fullscreen: bool`, `is_pending_maximized: bool`,
`display_mode: ColumnDisplay`, and a `TabIndicator`.

**Important asymmetry between width and height:**

- **Column width** is stored as `Proportion` *or* `Fixed` and stays that way.
  Proportional widths are deliberately kept proportional so columns keep their
  relative size when moved to a differently sized monitor (e.g. two 50% columns
  stay 50/50).
- **Window height** changes are *always converted to and stored as `Fixed`*
  immediately (proportional height is computed then frozen to px). The rationale
  in the source: windows in a column already auto-fill the available height, so
  the only reason to set an explicit height is to fit something exactly (e.g. 30
  terminal lines). Only **one** window per column may be non-`Auto`; setting a
  height converts all *other* windows back to `Auto` (weight-preserving).

---

## 1. Keyboard resize operations

### 1.1 Default preset values (config defaults)

From `niri-config/src/layout.rs` `impl Default for Layout`:

| Knob | Default value |
| --- | --- |
| `preset-column-widths` | `proportion 1/3`, `proportion 1/2`, `proportion 2/3` |
| `preset-window-heights` | `proportion 1/3`, `proportion 1/2`, `proportion 2/3` |
| `default-column-width` | `proportion 0.5` |
| `gaps` | `16` |

The shipped `default-config.kdl` writes the widths as `0.33333 / 0.5 / 0.66667`
and **comments out** `preset-window-heights` (so the code default 1/3,1/2,2/3
applies). `default-column-width { proportion 0.5; }` is set explicitly. An empty
`default-column-width {}` means "let the window pick its own initial width".

Each preset is a `PresetSize`:

```rust
enum PresetSize { Proportion(f64), Fixed(i32) }
```

`Proportion(p)` → resolved as a *tile* size; `Fixed(px)` → resolved as a
*window* size. The distinction matters because borders/tab-indicators are added
to/subtracted from differently (see §1.7).

### 1.2 `switch-preset-column-width` (Mod+R) / `-back` (Mod+Shift+R)

Action dispatch: `SwitchPresetColumnWidth → toggle_width(true)`,
`SwitchPresetColumnWidthBack → toggle_width(false)`
(`Column::toggle_width(tile_idx, forwards)`).

Cycle logic:

1. If the column already remembers a preset index (`preset_width_idx`) **and**
   it is not full-width / not maximized: advance it `(idx ± 1) mod len`
   (`+1` forwards, `+len-1` i.e. `-1` backwards).
2. Otherwise (custom width, or coming out of full-width/maximized): find the
   *first preset wider than* the current width (forwards) or the *last preset
   narrower than* current (backwards). If none qualifies, wrap to index `0`
   (forwards) or `len-1` (backwards). A `+1px` slack is allowed for fractional
   scaling.
3. Apply via `set_column_width(SizeChange::from(preset), …)` then record
   `preset_width_idx`.

Net effect: pressing Mod+R repeatedly walks 1/3 → 1/2 → 2/3 → 1/3 → …, and if
you're at some odd custom width it jumps to the next-larger preset first.

### 1.3 `switch-preset-window-height` (Mod+Ctrl+Shift+R) / `-back` (not bound)

`Column::toggle_window_height(tile_idx, forwards)`. Same cycling shape as widths
but over `preset-window-heights`, with two wrinkles:

- It first calls `convert_heights_to_auto()` if the target tile is currently
  `Auto`, so other tiles keep their visual heights.
- The stored result is `WindowHeight::Preset(idx)` (not frozen to Fixed),
  because presets are re-resolved against the working area on each layout.
- Resolution: a `Proportion` preset becomes a tile height
  `(working_h − gaps)*p − gaps − extra`, then converted to a window height; a
  `Fixed` preset is taken as the window height directly.

### 1.4 `maximize-column` (Mod+F) — toggle full width

Action dispatch: `MaximizeColumn → toggle_full_width()`.

`Column::toggle_full_width()`:

- If currently maximized (`is_pending_maximized`), treat the press as *unmaximize*:
  clear both `is_pending_maximized` and `is_full_width`.
- Otherwise flip `is_full_width`.
- When `is_full_width`, the column resolves its width as
  `ColumnWidth::Proportion(1.0)` while the *stored* `width` is preserved for
  restore-on-untoggle.

**Full width still keeps gaps and the border** — proportion `1.0` resolves to
`(working_w − gaps)*1 − gaps − extra`, i.e. the working area minus the outer
gaps. This is what the config comment means by "maximize-column leaves gaps and
borders around the window".

### 1.5 `maximize-window-to-edges` (Mod+M)

Action dispatch: `MaximizeWindowToEdges → set_maximized(true)` on the window
(`SizingMode::Maximized`). Unlike `maximize-column`, this fills the **parent
area** edge-to-edge with **no gaps and no border** (`request_maximized(parent_area.size)`).
It mirrors a classic titlebar double-click maximize. (`fullscreen-window`, Mod+Shift+F,
is the same idea but `SizingMode::Fullscreen`, covering layer-shell panels too.)

### 1.6 `set-column-width` / `set-window-height` (fixed / proportional / relative)

Default binds:

```
Mod+Minus       { set-column-width "-10%"; }   // AdjustProportion(-10)
Mod+Equal       { set-column-width "+10%"; }   // AdjustProportion(+10)
Mod+Shift+Minus { set-window-height "-10%"; }
Mod+Shift+Equal { set-window-height "+10%"; }
```

The string argument parses to a `SizeChange` (per the config comment, which is
authoritative):

| String | SizeChange | Meaning |
| --- | --- | --- |
| `"1000"` | `SetFixed(1000)` | exact width/height in logical px |
| `"+5"` / `"-5"` | `AdjustFixed(±5)` | add/subtract logical px |
| `"25%"` | `SetProportion(25)` | set to % of working area |
| `"+10%"` / `"-10%"` | `AdjustProportion(±10)` | add/subtract % of working area |

(Logical px are scale-independent: at scale 2.0, `set-column-width "100"` →
200 physical px.)

**`Column::set_column_width(change, tile_idx, animate)`:**

- `current` = `Proportion(1.)` if full-width/maximized, else stored `width`.
- `SetFixed(px)`: a special case — it computes a column width such that the
  *given window* gets exactly `px` (`tile_width_for_window_width(px)`), then
  clamps to `[1, 100000]` and stores as `ColumnWidth::Fixed`. (This is why
  fixed sizing exists: make a window's content exactly N px.)
- `SetProportion(p)`: store `ColumnWidth::Proportion(p/100)` clamped `[0, 10000]`.
- `AdjustFixed(d)`: `Fixed((current_px + d).clamp(1, MAX))`.
- `AdjustProportion(d)` when current is `Proportion(c)`: `Proportion(c + d/100)`.
- `AdjustProportion(d)` when current is `Fixed`: convert current px to a
  proportion first — `(current_px + gaps + extra) / (working_w − gaps)` — then
  add `d/100`.
- Side effects: clears `preset_width_idx`, clears `is_full_width` and
  `is_pending_maximized`, re-runs `update_tile_sizes`.

**`Column::set_window_height(change, tile_idx, animate)`:**

- First `convert_heights_to_auto()` if the target is currently `Auto` (so other
  tiles keep their look). Only one tile can be non-auto.
- Compute the requested **window** height:
  - `SetFixed(px)` → `px`.
  - `SetProportion(p)` → tile height `(working_h − gaps)*(p/100) − gaps − extra`,
    converted to window height.
  - `AdjustFixed(d)` → `current_window_px + d`.
  - `AdjustProportion(d)` → `current_prop + d/100` re-expanded to a tile then
    window height. `current_prop = (current_tile_px + gaps)/(working_h − gaps)`.
- Clamp against (a) other tiles' min heights so the column still fits, and
  (b) the window's own min/max size hints.
- Store as `WindowHeight::Fixed(clamped)` and clear `is_pending_maximized`.

(Note: in **tabbed** mode the "other tiles' min height" term is 0 because only
one tile is visible at a time — all tabs share the full height.)

### 1.7 Proportional vs. fixed resolution against the working area

`Column::resolve_column_width(width)`:

```
Proportion(p) -> (working_w - gaps) * p - gaps - extra_w   // a TILE width
Fixed(px)     -> px                                        // taken literally
```

`resolve_preset_size(preset, working_size, extra)`:

```
Proportion(p) -> ResolvedSize::Tile( (working - gaps)*p - gaps - extra )
Fixed(px)     -> ResolvedSize::Window( px )
```

Why proportion subtracts a gap and the extra: it makes columns *tile perfectly*.
A column's on-screen footprint is `tile_width + gap = (working_w − gaps)*p`. So
four `proportion 0.25` columns occupy `4 * (working_w − gaps)*0.25 = working_w − gaps`,
plus the final trailing gap = exactly `working_w`. This holds regardless of the
gap size — that's the headline guarantee in the wiki ("perfectly fit four
windows sized proportion 0.25").

Fixed widths/heights are interpreted as **window** content size and the
border/indicator is added back on top, so "fixed 1280" means a 1280px-wide
client, not a 1280px-wide tile.

The final tile width is additionally clamped to `[min_width, max_width]`
aggregated from the windows' own size hints.

### 1.8 `reset-window-height` (Mod+Ctrl+R)

`Column::reset_window_height(tile_idx)`:

- **Normal** mode: set the target tile's height back to `WindowHeight::auto_1()`
  (Auto weight 1.0). Other tiles keep whatever they had.
- **Tabbed** mode: reset **all** tiles to `auto_1()` (since any tab can be the
  fixed one, and all tabs share one height).

This drops the explicit fixed height so the window re-joins the automatic
height distribution.

### 1.9 `expand-column-to-available-width` (Mod+Ctrl+F)

`ScrollingSpace::expand_column_to_available_width()` — "fill the rest of the
visible space without disturbing other fully-visible columns":

1. No-op unless the column is in `Normal` sizing mode and not already full-width.
2. If centering mode is active, just fall back to `toggle_full_width()`.
3. Otherwise, walk all columns currently *fully visible* in the working area,
   summing their footprints (`width + gap`). Require the active column to be
   fully on screen (else no-op).
4. `available_width = working_w − gap − width_taken − extra`.
   If `≤ 0`, no-op.
5. If the active column was the *only* fully visible one, use
   `toggle_full_width()` (so you can intuitively toggle back).
6. Else set `width = Fixed(active_width + available_width)`, clear
   `preset_width_idx` and `is_full_width`, re-layout, and scroll so the
   leftmost visible column stays put.

### 1.10 `center-column` (Mod+C) and `center-visible-columns` (Mod+Ctrl+C)

- `center-column`: scroll the view so the active column is horizontally centered
  in the working area. Pure view-offset change; does not resize anything.
- `center-visible-columns`: center the *group* of fully-visible columns as a
  block. No-op if a centering mode is already forcing centering.

Related layout knob `center-focused-column` (`"never"` default / `"always"` /
`"on-overflow"`) governs automatic centering on focus change;
`always-center-single-column` forces centering whenever a workspace has one
column.

### 1.11 Auto-height distribution (how a column splits vertical space)

`update_tile_sizes` (Normal, non-fullscreen) computes per-tile heights:

1. Convert each tile's stored `WindowHeight` to a concrete tile height:
   `Auto` stays auto; `Fixed`/`Preset` resolve to fixed tile heights (clamped to
   working area and to the non-auto window's max).
2. Tiles with an exact constraint (`min.h == max.h`) become fixed.
3. `height_left = working_h − gaps*(n+1)` minus all fixed tiles.
4. Distribute `height_left` to the `Auto` tiles by **weight share**
   (`weight / total_weight`). Iterate: if any tile's share is below its min
   height, pin it to its min (fixed) and repeat with the remainder — so min
   heights are always respected (max heights are not enforced here, by design).
5. `convert_heights_to_auto()` (used before manual resize) recomputes weights so
   the *current* visual heights are preserved, normalizing the **median** tile
   height to weight 1.0 (weights are scale-invariant: `2,2,1 ≡ 4,4,2`).

---

## 2. Tabbed columns

`ColumnDisplay::Tabbed` is **a display flag on an ordinary `Column`** — the data
model is unchanged: it is still `tiles: Vec<Tile>` with an `active_tile_idx`.
The difference is purely in layout/rendering:

- **Normal**: all tiles stacked vertically, sharing the working-area height via
  the auto-height algorithm (§1.11).
- **Tabbed**: every tile gets the **same** height (`tabbed_height`), they are
  *overlaid* at the same position, and only `active_tile_idx` is opaque/visible;
  the others animate alpha to 0. A `TabIndicator` is shown on the side.

`toggle-column-tabbed-display` (**Mod+W**) → `toggle_column_tabbed_display()` →
flips `Normal ↔ Tabbed` via `set_column_display`. On switching:

- It cancels any interactive resize on the column.
- Recomputes `data`/tile sizes (with `place-within-column`, the indicator
  changes the column size immediately).
- If switching **away** from tabbed while the column has >1 window, it force-
  clears fullscreen and maximized (because those are only allowed for multi-tile
  columns when tabbed — see below).

Behavioral notes that fall out of the model:

- **All the usual binds still apply** to tabbed columns: `focus-window-down/up`
  switches the active tab; `consume-window-into-column` / `expel-window-from-column`
  add/remove tabs; resize, move, etc. (Tabs.md states this explicitly.)
- **Tabbed columns can go fullscreen with multiple windows**; normal columns
  cannot (`set_fullscreen`/`set_maximized` assert `tiles.len()==1 || tabbed`).
  When fullscreening a multi-tile *normal* column, niri first expels the window
  into its own column; in tabbed mode it just fullscreens the visible tab.
- In tabbed mode, height handling is special: `reset-window-height` resets all
  tabs; `set-window-height` ignores other tiles' min heights (one visible tab).
- `default-column-display "tabbed"` makes every new column tabbed by default.

### Tab indicator

`TabIndicator` is the little strip drawn beside a tabbed column; each tab maps to
one tile, and the active segment is highlighted. It represents **the set of
windows stacked in the column and which one is active** — clicking a segment
switches tabs. Two placement modes:

- **Default (outside)**: drawn outside the column; can overlay adjacent columns
  or run off-screen; contributes **0** to `extra_size` (no effect on sizing).
- **`place-within-column`**: drawn *inside* the column footprint; contributes to
  `extra_size`, shrinking the window to make room. Use for thick indicators or
  tiny gaps.

`hide-when-single-tab` hides the indicator when a tabbed column has only one
window.

Tab-indicator config defaults (`appearance.rs` `impl Default for TabIndicator`):

| Field | Default |
| --- | --- |
| `off` | `false` (on) |
| `hide-when-single-tab` | `false` |
| `place-within-column` | `false` |
| `gap` | `5` (px between indicator and window; may be negative) |
| `width` | `4` (thickness in px) |
| `length` | `total-proportion=0.5` (indicator spans half the window) |
| `position` | `"left"` (also `right`/`top`/`bottom`) |
| `gaps-between-tabs` | `0` |
| `corner-radius` | `0` |
| colors | unset → falls back to border/focus-ring active color |

Tab color precedence: window-rule `tab-indicator` colors → layout
`tab-indicator` colors → else match the active border/focus-ring color.

---

## 3. Mouse / interactive resize  *(OPTIONAL — deferrable)*

> This whole section is the pointer-drag path. It is **not required** for a
> keyboard-driven server-side reimplementation and can be deferred.

Conceptual model (`workspace.rs::resize_edges_under`, `scrolling.rs::interactive_resize_*`):

- **Edge detection**: the tile is divided into thirds on each axis. Pointer in
  the left third → `LEFT` edge, right third → `RIGHT`; top third → `TOP`, bottom
  third → `BOTTOM`. Corners combine (e.g. `BOTTOM_RIGHT`). Middle ninth → no edge.
  `ResizeEdge` is a bitflag (`LEFT|RIGHT|TOP|BOTTOM`, with `LEFT_RIGHT` /
  `TOP_BOTTOM` masks).
- **Begin** (`interactive_resize_begin`): only allowed when the column is in
  `Normal` sizing mode. Records the original window size and the chosen edges;
  stops any view animation/gesture.
- **Update** (`interactive_resize_update`, given a pointer `delta`):
  - Horizontal (`LEFT_RIGHT`): `dx = delta.x`, negated if dragging the `LEFT`
    edge; doubled if the column is force-centered. New width =
    `original.w + dx`, applied via `set_column_width(SetFixed(width))` — i.e. a
    drag pins the column to a **fixed** width.
  - Vertical (`TOP_BOTTOM`): `dy = delta.y`, negated for the `TOP` edge; ignored
    when dragging the top edge of the topmost tile (`TOP && tile_idx==0`). New
    height = `original.h + dy`, applied via `set_window_height(SetFixed(height))`.
- **End** (`interactive_resize_end`): clears the resize and animates the active
  window back into view.

So interactive resize is just a continuous stream of `SetFixed` width/height
changes keyed off which edge is grabbed; the *same* `set_column_width` /
`set_window_height` code path as the keyboard binds. Any keyboard resize on a
column cancels an in-progress interactive resize (`cancel_resize_for_column`).

The `Mod+MouseLeft` / `Mod+MouseRight` window-move/resize *gestures* (config-level)
are separate; binding those mouse buttons overrides the gesture.

---

## 4. Full default keymap (from `default-config.kdl`)

`Mod` = Super on a TTY, Alt when nested. All binds are exactly as shipped.
Non-layout binds (spawns, audio/brightness keys, screenshots, quit, lock,
keyboard-shortcut-inhibit, power-off) are listed at the end for completeness.

### 4.1 Focus movement

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+Left` / `Mod+H` | `focus-column-left` | Focus the column to the left |
| `Mod+Right` / `Mod+L` | `focus-column-right` | Focus the column to the right |
| `Mod+Down` / `Mod+J` | `focus-window-down` | Focus the next window down in the column |
| `Mod+Up` / `Mod+K` | `focus-window-up` | Focus the next window up in the column |
| `Mod+Home` | `focus-column-first` | Focus the first (leftmost) column |
| `Mod+End` | `focus-column-last` | Focus the last (rightmost) column |
| `Mod+WheelScrollRight` | `focus-column-right` | Focus column right (wheel) |
| `Mod+WheelScrollLeft` | `focus-column-left` | Focus column left (wheel) |
| `Mod+Shift+WheelScrollDown` | `focus-column-right` | Shift+wheel → horizontal focus right |
| `Mod+Shift+WheelScrollUp` | `focus-column-left` | Shift+wheel → horizontal focus left |

Commented-out alternatives in the config: `focus-window-or-workspace-down/up`
(cross into the next workspace when at the column ends) and `focus-workspace-previous`
on `Mod+Tab`.

### 4.2 Move column / window within a workspace

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+Ctrl+Left` / `Mod+Ctrl+H` | `move-column-left` | Swap the column one position left |
| `Mod+Ctrl+Right` / `Mod+Ctrl+L` | `move-column-right` | Swap the column one position right |
| `Mod+Ctrl+Down` / `Mod+Ctrl+J` | `move-window-down` | Move window down within its column |
| `Mod+Ctrl+Up` / `Mod+Ctrl+K` | `move-window-up` | Move window up within its column |
| `Mod+Ctrl+Home` | `move-column-to-first` | Move column to the very start |
| `Mod+Ctrl+End` | `move-column-to-last` | Move column to the very end |
| `Mod+Ctrl+WheelScrollRight` | `move-column-right` | Move column right (wheel) |
| `Mod+Ctrl+WheelScrollLeft` | `move-column-left` | Move column left (wheel) |
| `Mod+Ctrl+Shift+WheelScrollDown` | `move-column-right` | Shift+wheel move column right |
| `Mod+Ctrl+Shift+WheelScrollUp` | `move-column-left` | Shift+wheel move column left |

### 4.3 Monitor focus / move to monitor

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+Shift+Left` / `Mod+Shift+H` | `focus-monitor-left` | Focus monitor to the left |
| `Mod+Shift+Down` / `Mod+Shift+J` | `focus-monitor-down` | Focus monitor below |
| `Mod+Shift+Up` / `Mod+Shift+K` | `focus-monitor-up` | Focus monitor above |
| `Mod+Shift+Right` / `Mod+Shift+L` | `focus-monitor-right` | Focus monitor to the right |
| `Mod+Shift+Ctrl+Left` / `…+H` | `move-column-to-monitor-left` | Move column to left monitor |
| `Mod+Shift+Ctrl+Down` / `…+J` | `move-column-to-monitor-down` | Move column to monitor below |
| `Mod+Shift+Ctrl+Up` / `…+K` | `move-column-to-monitor-up` | Move column to monitor above |
| `Mod+Shift+Ctrl+Right` / `…+L` | `move-column-to-monitor-right` | Move column to right monitor |

Commented-out alternatives: `move-window-to-monitor-{dir}` (single window) and
`move-workspace-to-monitor-{dir}` (whole workspace).

### 4.4 Workspace switch / move

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+Page_Down` / `Mod+U` | `focus-workspace-down` | Focus next workspace down |
| `Mod+Page_Up` / `Mod+I` | `focus-workspace-up` | Focus next workspace up |
| `Mod+1` … `Mod+9` | `focus-workspace 1..9` | Focus workspace by index |
| `Mod+WheelScrollDown` (cooldown 150ms) | `focus-workspace-down` | Wheel → workspace down |
| `Mod+WheelScrollUp` (cooldown 150ms) | `focus-workspace-up` | Wheel → workspace up |
| `Mod+Ctrl+Page_Down` / `Mod+Ctrl+U` | `move-column-to-workspace-down` | Move column to workspace below |
| `Mod+Ctrl+Page_Up` / `Mod+Ctrl+I` | `move-column-to-workspace-up` | Move column to workspace above |
| `Mod+Ctrl+1` … `Mod+Ctrl+9` | `move-column-to-workspace 1..9` | Move column to workspace by index |
| `Mod+Ctrl+WheelScrollDown` (cooldown 150ms) | `move-column-to-workspace-down` | Wheel move column down |
| `Mod+Ctrl+WheelScrollUp` (cooldown 150ms) | `move-column-to-workspace-up` | Wheel move column up |
| `Mod+Shift+Page_Down` / `Mod+Shift+U` | `move-workspace-down` | Reorder workspace down |
| `Mod+Shift+Page_Up` / `Mod+Shift+I` | `move-workspace-up` | Reorder workspace up |

Workspace indices are "best effort": an index past the current count refers to
the bottommost (empty) workspace. Commented-out alternative:
`move-window-to-workspace-down/up` and `move-window-to-workspace N`.

### 4.5 Consume / expel (column composition)

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+BracketLeft` | `consume-or-expel-window-left` | If alone, merge into the column on the left; if in a column, expel out to the left |
| `Mod+BracketRight` | `consume-or-expel-window-right` | If alone, merge into the column on the right; if in a column, expel out to the right |
| `Mod+Comma` | `consume-window-into-column` | Pull the next column's top window into the bottom of this column |
| `Mod+Period` | `expel-window-from-column` | Push this column's bottom window out into its own column to the right |

(Full semantics in §6.)

### 4.6 Width / height resize

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+R` | `switch-preset-column-width` | Cycle column width through presets (1/3→1/2→2/3→…) |
| `Mod+Shift+R` | `switch-preset-column-width-back` | Same, reverse order |
| `Mod+Ctrl+Shift+R` | `switch-preset-window-height` | Cycle window height through presets |
| `Mod+Ctrl+R` | `reset-window-height` | Reset window height to automatic |
| `Mod+Minus` | `set-column-width "-10%"` | Shrink column width by 10% of working area |
| `Mod+Equal` | `set-column-width "+10%"` | Grow column width by 10% of working area |
| `Mod+Shift+Minus` | `set-window-height "-10%"` | Shrink window height by 10% |
| `Mod+Shift+Equal` | `set-window-height "+10%"` | Grow window height by 10% |

(`set-window-height` is meaningful only when a column holds >1 window.)

### 4.7 Maximize / fullscreen / fill / center

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+F` | `maximize-column` | Toggle column to full working-area width (keeps gaps + border) |
| `Mod+Shift+F` | `fullscreen-window` | Toggle real fullscreen (covers panels) |
| `Mod+M` | `maximize-window-to-edges` | Maximize window to screen edges (no gaps/border) |
| `Mod+Ctrl+F` | `expand-column-to-available-width` | Grow column into space not used by other visible columns |
| `Mod+C` | `center-column` | Scroll so the focused column is centered |
| `Mod+Ctrl+C` | `center-visible-columns` | Center all fully visible columns as a block |

### 4.8 Tabbed / floating

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+W` | `toggle-column-tabbed-display` | Toggle the focused column between normal and tabbed |
| `Mod+V` | `toggle-window-floating` | Move focused window between tiling and floating layers |
| `Mod+Shift+V` | `switch-focus-between-floating-and-tiling` | Move focus between the floating and tiling layers |

### 4.9 Overview / window lifecycle

| Bind | Action | Description |
| --- | --- | --- |
| `Mod+O` (repeat=false) | `toggle-overview` | Open/close the zoomed-out overview |
| `Mod+Q` (repeat=false) | `close-window` | Close the focused window |

### 4.10 Non-layout binds (for completeness)

| Bind | Action | Note |
| --- | --- | --- |
| `Mod+Shift+Slash` | `show-hotkey-overlay` | Important-hotkeys popup |
| `Mod+T` (repeat=false) | `spawn "alacritty"` | Terminal |
| `Mod+D` (repeat=false) | `spawn "fuzzel"` | App launcher |
| `Super+Alt+L` | `spawn "swaylock"` | Lock screen |
| `Super+Alt+S` (allow-when-locked) | `spawn-sh "pkill orca \|\| exec orca"` | Screen reader toggle |
| `XF86AudioRaiseVolume` / `LowerVolume` / `Mute` / `MicMute` (allow-when-locked) | `spawn-sh wpctl …` | Volume |
| `XF86AudioPlay`/`Pause`/`Stop`/`Prev`/`Next` (allow-when-locked) | `spawn-sh playerctl …` | Media |
| `XF86MonBrightnessUp` / `Down` (allow-when-locked) | `spawn brightnessctl …` | Brightness |
| `Print` | `screenshot` | Interactive screenshot UI |
| `Ctrl+Print` | `screenshot-screen` | Screenshot the focused screen |
| `Alt+Print` | `screenshot-window` | Screenshot the focused window |
| `Mod+Escape` (allow-inhibiting=false) | `toggle-keyboard-shortcuts-inhibit` | Escape hatch for KVM/RDP |
| `Mod+Shift+E` | `quit` | Quit (confirmation dialog) |
| `Ctrl+Alt+Delete` | `quit` | Quit |
| `Mod+Shift+P` | `power-off-monitors` | DPMS off |

**Bind properties seen in the default config**: `repeat=false` (don't auto-repeat
while held), `cooldown-ms=N` (rate-limit, used on wheel binds),
`allow-when-locked=true` (works while session locked), `allow-inhibiting=false`
(never swallowed by shortcut inhibitor), `hotkey-overlay-title="…"` / `=null`
(customize/hide the bind in the hotkey overlay). These belong on the bind, not
the action.

---

## 5. Layout geometry knobs (gaps / borders / focus-ring / struts / shadow)

All from the `layout {}` block; defaults from `niri-config/src` `impl Default`.

### `gaps` — default `16`
Uniform spacing inside *and* outside every tile (logical px, fractional allowed).
Acts as both inner and outer gaps. Subtracted in every proportional width/height
formula (§1.7).

### `struts` — default all `0`
Outer-only shrink of the working area, in logical px, on each side
(`left/right/top/bottom`). `compute_working_area` subtracts them from the parent
area before sizing:

```
working.w = max(0, parent.w - struts.left - struts.right);  working.x += struts.left
working.h = max(0, parent.h - struts.top - struts.bottom);  working.y += struts.top
```

Left/right struts keep the next side column slightly peeking; top/bottom add
extra outer gaps on top of layer-shell panels. Struts may be **negative** to
push windows past screen edges — combined with matching positive `gaps` this
emulates "inner gaps without outer gaps" (e.g. `gaps 16` + all struts `-16`).

### `focus-ring` — drawn only around the **active** window; does **not** affect sizing
Defaults (`impl Default for FocusRing`):

| Field | Default |
| --- | --- |
| `off` | `false` (focus ring **on** by default) |
| `width` | `4` |
| `active-color` | `#7fc8ff` (rgba 127,200,255,255) |
| `inactive-color` | `#505050` (80,80,80,255) |
| `urgent-color` | `#9b0000` (155,0,0,255) |
| gradients | unset |

### `border` — drawn around **all** windows; **affects sizing** (windows shrink to fit)
Defaults (`impl Default for Border`):

| Field | Default |
| --- | --- |
| `off` | `true` (border **off** by default) |
| `width` | `4` |
| `active-color` | `#ffc87f` (255,200,127,255) |
| `inactive-color` | `#505050` |
| `urgent-color` | `#9b0000` |
| gradients | unset |

The border is the only one of the two that changes geometry. In `tile.rs`:
`tile_size = window_size + 2*border` per axis when border is on (and
`effective_border_width` returns `None` in maximized/fullscreen sizing modes, so
those drop the border). `tile_width_for_window_width` / `tile_height_for_window_height`
add `2*border`; the inverse (`window_*_for_tile_*`) subtracts it. Focus ring and
border share the same option schema; you typically enable one and disable the
other.

### `shadow` — default off; purely visual (no geometry impact)
Defaults: `on=false`, `softness=30`, `spread=5`, `offset y=5` (x=0),
`draw-behind-window=false`, default color. Not relevant to layout geometry.

### `tab-indicator` — see §2 (only affects geometry with `place-within-column`).

### `insert-hint` — default on, color `#ffc87f80`; only shown during interactive moves, no steady-state geometry effect.

### Other layout flags
`center-focused-column "never"` (default), `always-center-single-column` (off),
`empty-workspace-above-first` (off), `default-column-display "normal"` (default),
`background-color` (default dark).

---

## 6. Consume / expel — exact semantics

These four actions convert between **side-by-side columns** and a **single
stacked column**, i.e. they move a tile across the column boundary. Source:
`ScrollingSpace::consume_or_expel_window_left/right`, `consume_into_column`,
`expel_from_column`.

### `consume-or-expel-window-left` (Mod+BracketLeft)

Operates on the focused window (call its column `S`, tile index `i`):

- **If `S` has exactly 1 tile** → *consume into the column on the left*:
  - No-op if `S` is already the leftmost column.
  - Remove the lone tile from `S` (which deletes column `S`) and append it to the
    **bottom** of the column immediately to the left (`S-1`). Net: two adjacent
    single-window columns become one 2-window stacked column. The previous-left
    column gets activated so the animation reads correctly.
- **If `S` has >1 tile** → *expel out to the left*:
  - Remove tile `i` from `S` and insert it as a **new column** at position `S`
    (i.e. just to the left of the remaining stack). Net: a stacked column loses
    its focused tile into a new neighboring column on the left.

### `consume-or-expel-window-right` (Mod+BracketRight)

Mirror image:

- **1 tile in `S`** → consume into the column on the right (`S+1`), appended at
  its bottom; no-op if `S` is already rightmost.
- **>1 tile in `S`** → expel tile `i` into a **new column** at `S+1` (to the
  right of the remaining stack).

### `consume-window-into-column` (Mod+Comma)

`consume_into_column()` — always pulls **from the next column to the right** into
the **active** column, regardless of how many tiles are involved:

- No-op if there are <2 columns or the active column is the rightmost.
- Take the **top** tile (index 0) of column `active+1` and append it to the
  **bottom** of the active column. If that empties the source column, it is
  removed and the strip closes up.

This is the "grow the current stack by eating the neighbor's top window" action,
the natural inverse of `expel-window-from-column`.

### `expel-window-from-column` (Mod+Period)

`expel_from_column()` — push the active column's **bottom** tile out to its own
column:

- No-op if the active column has only 1 tile.
- Remove the **last** tile (`tiles.len()-1`) of the active column and insert it
  as a **new column** at `active+1` (immediately to the right).

### Summary table

| Action | Source | What moves | Result |
| --- | --- | --- | --- |
| `consume-or-expel-window-left` | focused window | the focused tile | if alone: merge into left column's bottom; else: expel into new column on the left |
| `consume-or-expel-window-right` | focused window | the focused tile | if alone: merge into right column's bottom; else: expel into new column on the right |
| `consume-window-into-column` | active column | top tile of `active+1` | appended to bottom of active column (stack grows) |
| `expel-window-from-column` | active column | bottom tile of active column | becomes a new column at `active+1` (stack shrinks) |

Fullscreen interaction: fullscreening a window in a multi-tile **normal** column
implicitly performs a `consume-or-expel-window-right` first (extracts it into its
own column); in **tabbed** columns the window stays and the whole column
fullscreens.

---

## 7. Reimplementation checklist (server-side, Racket)

Minimum viable model to match niri's keyboard behavior:

1. **State**: workspaces → ordered columns → ordered tiles; per-column
   `width: (Proportion f) | (Fixed px)`, `preset-width-idx`, `full-width?`,
   `maximized?`, `fullscreen?`, `display: normal|tabbed`, `active-tile-idx`;
   per-tile `height: (Auto weight) | (Fixed px) | (Preset idx)`.
2. **Working area** = output − struts; everything proportional is vs. this.
3. **Width resolve**: `proportion p → (W−gaps)*p − gaps − extra`; `fixed → px`.
   Footprint = `tile_width + gap`. This guarantees N equal columns tile exactly.
4. **Height resolve**: auto-distribute leftover height by weight with min-height
   pinning; only one non-auto tile per column; height changes freeze to Fixed.
5. **Presets**: widths and heights default to 1/3, 1/2, 2/3; cycle forward/back
   with wrap and "next larger / next smaller than current" entry behavior.
6. **SizeChange** parser: `"N"`→SetFixed, `"±N"`→AdjustFixed, `"N%"`→SetProportion,
   `"±N%"`→AdjustProportion (percent 0..100). Fixed = *window* px; proportion =
   working-area fraction.
7. **Border** subtracts from window size (2×width/axis); focus-ring/shadow/insert-
   hint are visual only; tab-indicator only resizes with `place-within-column`.
8. **Tabbed** = a column display flag; equalize tile heights, show only the
   active tile; allow multi-window fullscreen.
9. **Consume/expel** = move a tile across the column boundary (merge into a
   neighbor's bottom, or split out into a new neighboring column).
10. Interactive (mouse) resize is the same `SetFixed` width/height path keyed off
    thirds-based edges — **defer** until keyboard parity is done.
