# Niri Scrolling Tiling Layout Model — Technical Brief

Source of truth (niri clone at `/tmp/weevil-niri-ref/niri`):

- `src/layout/scrolling.rs` — the scrollable strip of columns (~5600 lines, the core).
- `src/layout/tile.rs` — a tile = one window + its decorations.
- `src/layout/workspace.rs` — `ResolvedSize` enum (referenced from scrolling).
- `src/layout/mod.rs` — `SizingMode`, `LayoutElement` trait.
- `niri-ipc/src/lib.rs` — `SizeChange`, `ColumnDisplay`.
- `niri-config/src/layout.rs` — `PresetSize`, `CenterFocusedColumn`, `Layout` defaults.
- `niri.wiki/{Overview,Configuration:-Layout}.md` — user-facing semantics.

Scope note: this brief covers **only** the layout data model and algorithms.
Wayland protocol, GPU rendering, damage tracking, and spring/animation interpolation
are out of scope. Where an operation is *animated*, that is noted, but the spring
math is not transcribed. The model is deterministic and fully reconstructable from
integers/floats; animations are a pure visual overlay (`render_offset`, `move_animation`).

---

## 0. The big picture: a three-level nested model

The scrolling layout is a **horizontal strip of columns**, where each **column** is a
**vertical stack of tiles**, and each **tile** wraps a single window plus its
decorations. Three levels, each with its own "active/focused index":

```
ScrollingSpace                      (the strip — owns horizontal scroll)
├── active_column_idx : usize       (which column is focused)
├── view_offset       : ViewOffset  (horizontal scroll position)
└── columns: Vec<Column>            (ordered left → right)
        │
        Column                      (a vertical stack — owns its width)
        ├── active_tile_idx : usize (which tile in this column is focused)
        ├── width           : ColumnWidth
        └── tiles: Vec<Tile>        (ordered top → bottom; MUST be non-empty)
                │
                Tile                (one window + border/focus-ring/shadow)
                └── window: W        (the actual toplevel)
```

Key invariants enforced (`verify_invariants`):

- A `Column` is **never empty** (`assert!(!self.tiles.is_empty())`). Removing the last
  tile removes the whole column.
- `active_column_idx < columns.len()` (when non-empty); `active_tile_idx < tiles.len()`.
- `columns.len() == data.len()` and `tiles.len() == column.data.len()` — every level
  keeps a **parallel "data" vector** of cached geometry (see below).
- At most **one** tile per column may have a non-`Auto` (fixed/preset) height; the rest
  are `Auto`. (Enforced when setting a height; only one `Fixed` allowed.)
- A single-tile column must have its tile's auto weight reset to `1.0`.

The `<W: LayoutElement>` generic is the window abstraction. For a Racket port you can
treat `W` as "a window handle / id + reported size + min/max size + sizing mode". The
`LayoutElement` trait (in `mod.rs`) exposes `id()`, `size()`, `min_size()`, `max_size()`,
`requested_size()`, `request_size(...)`, etc. The layout never touches pixels of the
window content; it only reads/writes **sizes** and **ids**.

---

## 1. DATA MODEL — structs, fields, and what each level owns

### 1.1 `ScrollingSpace<W>` (the strip)

`scrolling.rs:35`

```rust
pub struct ScrollingSpace<W: LayoutElement> {
    /// Columns of windows on this space.
    columns: Vec<Column<W>>,

    /// Extra per-column data. Parallel to `columns` (same length, same order).
    data: Vec<ColumnData>,

    /// Index of the currently active column, if any.
    active_column_idx: usize,

    /// Ongoing interactive resize (mouse-drag resize). Mostly out of scope here.
    interactive_resize: Option<InteractiveResize<W>>,

    /// Offset of the view computed from the active column. (THE scroll position.)
    view_offset: ViewOffset,

    /// Whether to activate the previous, rather than next, column upon column removal.
    /// Stores the view offset that the previous column had, to restore it.
    activate_prev_column_on_removal: Option<f64>,

    /// View offset to restore after unfullscreening or unmaximizing.
    view_offset_to_restore: Option<f64>,

    /// Windows in the closing animation (visual only).
    closing_windows: Vec<ClosingWindow>,

    /// View size for this space (the full output logical size).
    view_size: Size<f64, Logical>,

    /// Working area: view_size minus layer-shell exclusive zones and niri struts.
    working_area: Rectangle<f64, Logical>,

    /// Working area excluding struts (used for popup unconstraining only).
    parent_area: Rectangle<f64, Logical>,

    /// Output scale (sizes are rounded to physical pixels using this).
    scale: f64,

    clock: Clock,           // animation clock
    options: Rc<Options>,   // config (gaps, presets, centering mode, etc.)
}
```

What the strip level **owns**:

- The ordered list of columns and which one is active.
- The single horizontal **scroll position** (`view_offset`) — there is exactly one
  scroll value, expressed relative to the active column (see §4).
- The viewport geometry: `view_size` (full output), `working_area` (after struts and
  panels), `parent_area` (after panels only, before struts).
- Two "restore" memories for nice UX: `activate_prev_column_on_removal` and
  `view_offset_to_restore`.

### 1.2 `ColumnData` (cached per-column geometry)

`scrolling.rs:107`

```rust
struct ColumnData {
    /// Cached actual column width (logical px). = max tile width (+ tab-indicator extra).
    width: f64,
}
```

This is a denormalized cache so that the strip can compute column X-positions without
walking every tile. It is recomputed via `ColumnData::update(column)` → `column.width()`
whenever a column changes. For a Racket port you can either cache it the same way or
compute `column-width` on demand (it's cheap: max over tile widths).

### 1.3 `Column<W>` (a vertical stack)

`scrolling.rs:146`

```rust
pub struct Column<W: LayoutElement> {
    /// Tiles in this column (top → bottom). MUST be non-empty.
    tiles: Vec<Tile<W>>,

    /// Extra per-tile data. Parallel to `tiles` (same length).
    data: Vec<TileData>,

    /// Index of the currently active tile.
    active_tile_idx: usize,

    /// Desired width of this column. If full-width/fullscreen, this is the width to
    /// restore when toggling back.
    width: ColumnWidth,

    /// Currently selected preset width index (for switch-preset-column-width cycling).
    preset_width_idx: Option<usize>,

    /// Whether this column is full-width (spans whole working area width).
    is_full_width: bool,

    /// Pending fullscreen state (compositor side; flips immediately).
    is_pending_fullscreen: bool,

    /// Pending maximized state. Can be true together with is_pending_fullscreen
    /// (means: effectively fullscreen, but unfullscreen → maximized rather than normal).
    is_pending_maximized: bool,

    /// How this column arranges windows: Normal (vertical stack) or Tabbed.
    display_mode: ColumnDisplay,

    tab_indicator: TabIndicator,        // visual; sizing only via extra_size()
    move_animation: Option<MoveAnimation>, // visual horizontal slide on swap

    // Cached viewport context (kept in sync with the parent space):
    view_size: Size<f64, Logical>,
    working_area: Rectangle<f64, Logical>,
    parent_area: Rectangle<f64, Logical>,
    scale: f64,
    clock: Clock,
    options: Rc<Options>,
}
```

What the column level **owns**:

- The ordered list of tiles and which one is active (`active_tile_idx`).
- The **column width** (one value for the whole column; all tiles share it).
- The width-preset cursor (`preset_width_idx`).
- Display mode (`Normal` vs `Tabbed`) and full-width / fullscreen / maximized flags.

Note: a column's **height** is not stored as a single value — it always fills the
working area height; per-tile heights are stored in `TileData.height` (see §3).

### 1.4 `TileData` (cached per-tile geometry)

`scrolling.rs:221`

```rust
struct TileData {
    /// Requested WINDOW height (excludes tile decorations). The height policy.
    height: WindowHeight,

    /// Cached actual tile size (window + borders), logical px.
    size: Size<f64, Logical>,

    /// Cached: is this tile being interactively resized by its LEFT edge?
    /// (affects horizontal alignment within the column)
    interactively_resizing_by_left_edge: bool,
}
```

`height` is the **policy** (auto/fixed/preset); `size` is the **resolved result** after
the height-distribution algorithm runs. Keep these distinct in a Racket port: policy is
input, size is output.

### 1.5 `Tile<W>` (window + decorations)

`tile.rs:38`. The layout-relevant fields and methods (ignoring render/animation buffers):

```rust
pub struct Tile<W: LayoutElement> {
    window: W,             // the toplevel
    border: FocusRing,     // border (affects size: window shrinks to fit border)
    focus_ring: FocusRing, // focus ring (does NOT affect size; drawn around active)
    shadow: Shadow,        // visual only
    sizing_mode: SizingMode, // Normal | Maximized | Fullscreen (lags pending state)
    // floating-related fields (floating_pos, floating_window_size, ...) — used by the
    // floating layout, not the scrolling strip; ignore for this brief.
    // animation fields (resize_animation, move_x/y_animation, alpha_animation) — visual.
    view_size, scale, clock, options, ...
}
```

The crucial **tile vs. window** distinction (a recurring theme):

- **Window size** = the geometry the client renders (what Wayland negotiates).
- **Tile size** = window size **+ border on all sides** (`2 * border.width`), unless
  border is off (then equal). Fullscreen tiles ignore borders.

Conversion helpers (`tile.rs:924-955`), all just add/subtract `border.width*2`:

```rust
tile_width_for_window_width(w)  = border.off ? w : w + 2*border.width
window_width_for_tile_width(w)  = border.off ? w : w - 2*border.width
tile_height_for_window_height(h)= border.off ? h : h + 2*border.width
window_height_for_tile_height(h)= border.off ? h : h - 2*border.width
```

`tile.tile_size()` (`tile.rs:765`): window size + border*2 (or, if fullscreen, the
`view_size`, taking max). `tile.window_loc()` centers the window inside the tile (so the
border is symmetric). For a Racket port: a tile is `window-size` plus a uniform border
inset; everything else is decoration drawn at those coordinates.

---

## 2. COLUMN WIDTH

### 2.1 Representation

`scrolling.rs:236`

```rust
pub enum ColumnWidth {
    Proportion(f64), // fraction of the working-area width, gaps-aware
    Fixed(f64),      // exact width in logical pixels
}
```

Plus, on the column itself:

- `is_full_width: bool` — when true, the column behaves as `Proportion(1.0)` but the
  stored `width` is preserved so toggling off restores the previous width.
- `preset_width_idx: Option<usize>` — index into `options.layout.preset_column_widths`.

Config presets are `PresetSize` (`niri-config/src/layout.rs:132`):

```rust
pub enum PresetSize {
    Proportion(f64), // e.g. 0.33333
    Fixed(i32),      // e.g. 1280 logical px
}
```

`ColumnWidth::from(PresetSize)` clamps: proportions to `[0, 10000]`, fixed to `[1, 100000]`
(`scrolling.rs:3912`). And `SizeChange::from(PresetSize)` maps `Proportion(p) →
SetProportion(p*100)` (percent), `Fixed(f) → SetFixed(f)` (`layout.rs:142`).

Defaults (`layout.rs:37`): `preset_column_widths = [1/3, 1/2, 2/3]`,
`default_column_width = Proportion(0.5)`.

### 2.2 Resolving a `ColumnWidth` to pixels

`Column::resolve_column_width` (`scrolling.rs:4401`):

```rust
fn resolve_column_width(&self, width: ColumnWidth) -> f64 {
    let working_size = self.working_area.size;
    let gaps = self.options.layout.gaps;
    let extra = self.extra_size(); // tab-indicator width if Tabbed & place_within_column

    match width {
        ColumnWidth::Proportion(p) => (working_size.w - gaps) * p - gaps - extra.w,
        ColumnWidth::Fixed(w)      => w,
    }
}
```

The `(working - gaps)*p - gaps` formula is **gaps-aware**: it makes N columns of
`Proportion(1/N)` tile exactly across the working area including the inter-column gaps.
This is why the wiki says "you can perfectly fit four windows sized `proportion 0.25`
regardless of the gaps setting."

The resolved width is then **clamped** against the tiles' min/max widths in
`update_tile_sizes` (`scrolling.rs:4485`):

```rust
let width = self.is_full_width ? ColumnWidth::Proportion(1.) : self.width;
let width = self.resolve_column_width(width);
let width = f64::max(f64::min(width, max_width), min_width);
```

where `min_width = max over tiles of min_size.w` and `max_width = min over tiles of
max_size.w` (ignoring 0 = "no max"), with `max_width = max(max_width, min_width)`.

### 2.3 The "actual" column width (`Column::width()`, `scrolling.rs:4712`)

```rust
fn width(&self) -> f64 {
    let mut tiles_width = max over self.data of data.size.w;   // widest tile
    if tabbed && normal-sizing { tiles_width += tab_indicator.extra_size().w; }
    tiles_width
}
```

So the **column width used for layout/X-positioning is the width of its widest tile**
(plus tab-indicator extra in tabbed mode). The `Column.width: ColumnWidth` field is the
*desired/target* width; `ColumnData.width` / `Column::width()` is the *realized* width
after windows have actually resized (windows can refuse exact sizes, e.g. a terminal
snapping to its character grid).

### 2.4 Width-change operations

All width setters live on `Column` and end by calling `update_tile_sizes(animate)`.

`set_column_width(change: SizeChange, tile_idx, animate)` (`scrolling.rs:4859`):

```rust
let current = (is_full_width || is_pending_maximized) ? Proportion(1.) : self.width;
let current_px = resolve_column_width(current);
let width = match (current, change) {
    (_, SetFixed(fixed)) => {
        // compute so the GIVEN window (usually active) gets exactly `fixed` px:
        Fixed( tile.tile_width_for_window_width(fixed).clamp(1, MAX_PX) )
    }
    (_, SetProportion(p))       => Proportion((p/100).clamp(0, MAX_F)),
    (_, AdjustFixed(delta))     => Fixed((current_px + delta).clamp(1, MAX_PX)),
    (Proportion(c), AdjustProportion(d)) => Proportion((c + d/100).clamp(0, MAX_F)),
    (Fixed(_), AdjustProportion(d)) => {
        // convert current px back to a proportion, then adjust:
        let full = working.w - gaps;
        let cur  = (current_px + gaps + extra.w) / full;
        Proportion((cur + d/100).clamp(0, MAX_F))
    }
};
self.width = width;
self.preset_width_idx = None;   // a manual resize drops the preset cursor
self.is_full_width = false;
self.is_pending_maximized = false;
self.update_tile_sizes(animate);
```

Note the special `SetFixed` semantics: the fixed value targets the **window** width of
the active tile, so the column gets `window + border*2`.

`toggle_full_width()` (`scrolling.rs:4847`): if maximized, treat as unmaximize; else flip
`is_full_width`. Then `update_tile_sizes`.

### 2.5 `switch-preset-column-width` cycling — `Column::toggle_width`

`scrolling.rs:4796`:

```rust
fn toggle_width(&mut self, tile_idx: Option<usize>, forwards: bool) {
    let tile_idx = tile_idx.unwrap_or(self.active_tile_idx);

    // If we already have a preset cursor (and aren't full-width/maximized), just step it:
    let preset_idx = (is_full_width || is_pending_maximized) ? None : self.preset_width_idx;
    let len = preset_column_widths.len();
    let preset_idx = if let Some(idx) = preset_idx {
        (idx + (forwards ? 1 : len-1)) % len      // cyclic step, with reverse support
    } else {
        // No cursor yet: pick the preset based on the CURRENT actual width.
        let current_window = tile.window_expected_or_current_size().w;
        let current_tile   = tile.tile_expected_or_current_size().w;
        let it = preset_column_widths.iter().map(|p| resolve_preset_width(p));
        if forwards {
            // first preset strictly wider than current (+1px slack for fractional scale)
            it.position(|r| match r {
                Tile(t)   => current_tile + 1. < t,
                Window(w) => current_window + 1. < w,
            }).unwrap_or(0)
        } else {
            // last preset strictly narrower than current
            it.rposition(|r| match r {
                Tile(t)   => t + 1. < current_tile,
                Window(w) => w + 1. < current_window,
            }).unwrap_or(len - 1)
        }
    };

    let preset = preset_column_widths[preset_idx];
    self.set_column_width(SizeChange::from(preset), Some(tile_idx), true);
    self.preset_width_idx = Some(preset_idx);  // re-establish cursor AFTER set_column_width cleared it
}
```

Behavior summary:

- If the column is already "on a preset" (`preset_width_idx` set), `switch-preset-column-width`
  simply advances the index cyclically (`+1`), and `switch-preset-column-width-back` goes
  `-1` (both mod len). `forwards` is the parameter.
- If not on a preset (e.g. width was set manually, or the window snapped its own size),
  it picks the next-larger preset (forwards) or next-smaller (backwards) relative to the
  *actual current width*, with a 1px slack for fractional scaling. If none is larger,
  wraps to index 0; if none smaller, wraps to `len-1`.
- The new-column constructor (`Column::new_with_tile`, `scrolling.rs:3946`) also tries to
  pre-match the initial width to a preset so the first `switch-preset` press isn't wasted.

`resolve_preset_width(PresetSize) -> ResolvedSize` (`scrolling.rs:4391` → `resolve_preset_size`
at `scrolling.rs:5554`):

```rust
match preset {
    Proportion(p) => ResolvedSize::Tile((view - gaps)*p - gaps - extra),  // a TILE width
    Fixed(w)      => ResolvedSize::Window(w),                              // a WINDOW width
}
```

`ResolvedSize` (`workspace.rs:161`) distinguishes Tile-space vs Window-space sizes so the
comparison code knows whether to add/subtract the border.

`update_config` clears `preset_width_idx` if the configured presets list changed
(`scrolling.rs:4029`).

---

## 3. WINDOW HEIGHTS WITHIN A COLUMN

### 3.1 Representation — `WindowHeight`

`scrolling.rs:257`. The doc comment is essential:

> Every window but one in a column must be `Auto`-sized so that the total height can add
> up to the workspace height. Resizing a window converts all others to `Auto`, weighted
> to preserve their visual heights at the moment of the conversion.
>
> In contrast to column widths, proportional height changes are converted to, and stored
> as, fixed height right away.

```rust
pub enum WindowHeight {
    Auto { weight: f64 }, // tile height distributed across the column by weight
    Fixed(f64),           // fixed WINDOW height in logical px
    Preset(usize),        // index into preset_window_heights
}
```

Stored per tile in `TileData.height`. Constructor `WindowHeight::auto_1()` = `Auto{weight:1.0}`.

Key asymmetry vs widths: heights default to **auto** because a column already auto-fills
the working-area height. You only set a fixed/preset height when you want something exact
(e.g. "fit 30 terminal lines"). At most one tile per column may be non-`Auto`.

### 3.2 Setting / cycling heights

`set_window_height(change, tile_idx, animate)` (`scrolling.rs:4914`):

```rust
let tile_idx = tile_idx.unwrap_or(active_tile_idx);

// Make this the ONLY non-auto tile: convert all heights to auto first
// (skipped if the current tile is already non-auto, to preserve weights).
if matches!(data[tile_idx].height, Auto {..}) { self.convert_heights_to_auto(); }

let current = data[tile_idx].height;
let current_window_px = match current {
    Auto|Preset => tile.window_size().h,
    Fixed(h)    => h,
};
// translate SizeChange into an absolute window height:
let mut window_height = match change {
    SetFixed(f)        => f,
    SetProportion(p)   => tile.window_height_for_tile_height((working - gaps)*(p/100) - gaps - extra),
    AdjustFixed(d)     => current_window_px + d,
    AdjustProportion(d)=> { let prop = current_prop + d/100; tile.window_height_for_tile_height((working-gaps)*prop - gaps - extra) }
};

// clamp so the OTHER tiles' min-heights still fit, then clamp to working area:
let min_height_taken = tabbed ? 0 : sum over other tiles of (max(1,min.h) + gaps);
let height_left = working - extra - gaps - min_height_taken - gaps;
window_height = min(max(1, tile.window_height_for_tile_height(height_left)), window_height);
// then clamp to the window's own min/max constraints:
if max_h>0 { window_height = min(window_height, max_h); }
if min_h>0 { window_height = max(window_height, min_h); }

data[tile_idx].height = WindowHeight::Fixed(window_height.clamp(1, MAX_PX));
is_pending_maximized = false;
update_tile_sizes(animate);
```

`reset_window_height(tile_idx)` (`scrolling.rs:4993`): sets the tile (or all tiles, if
tabbed) back to `Auto{weight:1}`, then `update_tile_sizes`.

`toggle_window_height(tile_idx, forwards)` (`scrolling.rs:5008`): mirrors
`toggle_width` but over `preset_window_heights`, storing `WindowHeight::Preset(idx)`.
Same "convert others to auto first" + "step cursor if already on a preset, else pick by
current size" logic. `forwards=false` = the `-back` variant.

`convert_heights_to_auto()` (`scrolling.rs:5070`) — the weight-preserving conversion:

```rust
fn convert_heights_to_auto(&mut self) {
    let heights = self.tiles.map(|t| t.tile_size().h);  // current visual tile heights
    let mut sorted = heights.clone(); sorted.sort();
    let median = sorted[sorted.len()/2];                // median height ⇒ weight 1
    for (data, h) in zip(data, heights) {
        data.height = Auto { weight: h / median };      // weights invariant to scaling
    }
}
```

Weights are invariant to multiplication (2,2,1 ≡ 4,4,2), so it normalizes by the median.

### 3.3 The height-distribution algorithm — `update_tile_sizes_with_transaction`

This is THE algorithm that turns per-tile `WindowHeight` policies into concrete tile
sizes. `scrolling.rs:4418`. Steps (Normal display mode; fullscreen/maximized short-circuit
to a single full-area request; tabbed is handled specially mid-way):

**Step 0 — fullscreen/maximized.** If `pending_sizing_mode` is Fullscreen or Maximized,
request each tile to the fullscreen (`view_size`) or maximized (`parent_area.size`) size
and return. (In tabbed mode only the active tile participates in the size transaction.)

**Step 1 — gather constraints.** Per tile compute `min_size` (clamped ≥1×1) and
`max_size`. Column width = clamp(resolve(width), min_width, max_width) as in §2.2.
`max_tile_height = working.h - 2*gaps - extra.h`.

**Step 2 — clamp the single non-auto window** (only if >1 tile and not tabbed). Find the
one non-auto tile; the height it may take is `max_tile_height - sum(other tiles' min.h +
gaps)`. Stored as `max_non_auto_window_height`.

**Step 3 — convert each tile's height policy to a tentative tile height** (`heights` vec):

```rust
let mut heights = zip(tiles, data).map(|(tile, data)| match data.height {
    Auto{..} => keep Auto,
    Fixed(h) => {
        let win_h = h.round().max(1);
        win_h = min(win_h, max_non_auto_window_height OR window_height_for(max_tile_height));
        Fixed(tile.tile_height_for_window_height(win_h))   // now a TILE height
    }
    Preset(idx) => {
        let preset = preset_window_heights[idx];
        let win_h = match resolve_preset_height(preset) {
            Tile(h)   => tile.window_height_for_tile_height(h),
            Window(h) => h,
        }.round().clamp(1, 100000);
        if let Some(max) = max_non_auto_window_height { win_h = min(win_h, max); }
        Fixed(tile.tile_height_for_window_height(win_h))
    }
}).collect();
```

**Step 3b — tabbed mode.** If `is_tabbed`, all tiles get the **same** height: the one
fixed height if any tile has one, else `max_tile_height`, then `max(..., min over tiles
of min.h)` (capped at `max_tile_height`). `heights.fill(Fixed(tabbed_height))`. (Tabs are
stacked, so they share the active tile's slot; vertical distribution is moot.)

**Step 4 — subtract fixed heights from the budget.**

```rust
let gaps_left = gaps * (tiles.len() + 1);   // gaps above, below, and between
let mut height_left = working.h - gaps_left;
let mut auto_tiles_left = tiles.len();
for (h, (min, max)) in zip(heights, zip(min_size, max_size)) {
    if min.h == max.h { *h = Fixed(min.h); }            // exact-size dialog ⇒ pin it
    if let Fixed(hh) = h {
        if max.h > 0 { hh = min(hh, max.h); }
        hh = max(hh, min.h);
        height_left -= hh;
        auto_tiles_left -= 1;
    }
}
let mut total_weight = sum of weights of remaining Auto tiles;
```

**Step 5 — distribute `height_left` among Auto tiles by weight, respecting min-heights.**
This is an iterative fixed-point loop because rounding to integer pixels and min-height
constraints interact:

```rust
'outer: while auto_tiles_left > 0 {
    let (mut height_left_2, mut total_weight_2) = (height_left, total_weight);
    for ((h, tile), min) in zip(zip(heights, tiles), min_size) {
        let Auto{weight} = h else { continue };
        let factor = weight / total_weight_2;
        let mut auto = height_left_2 * factor;          // this tile's share
        if min.h > auto {
            // min not satisfied: pin this tile to its min, remove it from the auto pool,
            // and RESTART the outer loop (others now have less budget).
            auto = min.h;
            *h = Fixed(auto);
            height_left -= auto; total_weight -= weight; auto_tiles_left -= 1;
            continue 'outer;
        }
        // round to integer WINDOW px (Wayland requirement) then back to tile px:
        auto = tile.tile_height_for_window_height(
                   tile.window_height_for_tile_height(auto).round().max(1));
        height_left_2 -= auto; total_weight_2 -= weight;
    }
    // all mins satisfied this pass: commit the shares.
    for (h, tile) in zip(heights, tiles) {
        let Auto{weight} = h else { continue };
        let auto = tile.tile_height_for_window_height(
                       tile.window_height_for_tile_height(height_left*weight/total_weight)
                           .round().max(1));
        *h = Fixed(auto);
        height_left -= auto; total_weight -= weight; auto_tiles_left -= 1;
    }
    assert_eq!(auto_tiles_left, 0);
}
```

Important nuance the comments call out: **max-heights are NOT respected in the auto loop**
(only min-heights), because combining max + min makes the fixed point non-monotone. The
common max-height case (fixed-size dialogs where `min.h == max.h`) is handled separately
in Step 4 by pinning.

**Step 6 — request sizes.** For each tile, `request_tile_size((width, height), animate,
transaction)`. In tabbed mode only the active tile joins the transaction (others get
`None`).

For a Racket port: the loop is straightforward — repeatedly try `share = budget *
weight/total_weight`; if any auto tile's share is below its min, pin it to min and
restart; otherwise commit all. Rounding each share to integer window pixels keeps the
sum exact (the budget shrinks by the rounded amount each step).

### 3.4 Resize semantics on commit (`Column::update_window`, `scrolling.rs:4326`)

When a window actually changes size, tiles **below it** in the column shift in tandem
(animated if a resize animation is active; otherwise they jump). This is visual; the
data model just recomputes `TileData.size` and re-runs distribution. Width changes
similarly shift adjacent **columns** (handled in `ScrollingSpace::update_window`,
`scrolling.rs:1272`).

---

## 4. SCROLL POSITION / VIEW

### 4.1 What `view_offset` means

There is **one** scroll value, but it is stored **relative to the active column**, not as
an absolute position. The absolute view position is:

```rust
pub fn view_pos(&self) -> f64 {            // scrolling.rs:2294
    self.column_x(self.active_column_idx) + self.view_offset.current()
}
pub fn target_view_pos(&self) -> f64 {     // end-of-animation value
    self.column_x(self.active_column_idx) + self.view_offset.target()
}
```

`view_pos` is the X (in strip coordinates, see §7) of the **left edge of the viewport**.
`view_offset` is therefore "how far the viewport's left edge is from the active column's
left edge." A `view_offset` of `-padding` puts the active column's left edge `padding`
pixels in from the screen's left (the usual left-gap look). Comment in the struct:

> Any gaps, including left padding from work-area left exclusive zone, is handled with
> this view offset (rather than added as a constant elsewhere). This allows natural
> handling of fullscreen windows, which must ignore work-area padding.

Storing the offset relative to the active column means that **inserting/removing/resizing
columns to the left of the active one doesn't change the visible position** — you just
keep the same `view_offset` and the active column stays put. Many operations explicitly
re-base the offset by `old_col_x - new_col_x` (`animate_view_offset_with_config`,
`scrolling.rs:702`) to preserve this.

### 4.2 `ViewOffset` — the three states

`scrolling.rs:113`:

```rust
pub(super) enum ViewOffset {
    Static(f64),          // not moving
    Animation(Animation), // smoothly animating toward a target
    Gesture(ViewGesture), // controlled by a live touchpad/DnD scroll gesture
}
```

`ViewGesture` (`scrolling.rs:123`) holds `current_view_offset`, a `SwipeTracker`, a
`delta_from_tracker`, a `stationary_view_offset` (the value to use for save/restore), and
DnD bookkeeping. The gesture math (velocity, projected end, deceleration) is animation
detail — out of scope — but the **snapping** logic (§4.5) is part of the model.

Accessors (`scrolling.rs:3795`): `current()` (live value), `target()` (end value),
`stationary()` (a value safe to save/restore — never an in-progress value),
`offset(delta)` (shift all internal offsets by delta — used for re-basing).

For a Racket port the simplest faithful model is: `view-offset` is a single number, with
an optional "animating toward target" overlay. The gesture variant can be collapsed to
"static" plus a separately-tracked interactive drag if you don't implement touch.

### 4.3 Centering modes

`CenterFocusedColumn` (`niri-config/src/layout.rs:162`): `Never` (default), `Always`,
`OnOverflow`. Plus a separate boolean `always_center_single_column`.

```rust
pub fn is_centering_focused_column(&self) -> bool {   // scrolling.rs:540
    center_focused_column == Always
        || (always_center_single_column && columns.len() <= 1)
}
```

The two primitives that compute a target `view_offset` for a column:

**Fit** (`compute_new_view_offset_fit`, `scrolling.rs:545`): scroll the minimum needed so
the column is fully visible, biased toward least motion.

```rust
fn compute_new_view_offset_fit(target_x, col_x, width, mode) -> f64 {
    if mode.is_fullscreen() { return 0.; }
    let (area, padding) = mode.is_maximized()
        ? (parent_area, 0.)
        : (working_area, gaps);
    let new_offset = compute_new_view_offset(target_x + area.loc.x, area.size.w, col_x, width, padding);
    new_offset - area.loc.x   // non-fullscreen always offset by at least the work-area X
}
```

`compute_new_view_offset` (free fn, `scrolling.rs:5457`) is the core "fit" math:

```rust
fn compute_new_view_offset(cur_x, view_width, new_col_x, new_col_width, gaps) -> f64 {
    if view_width <= new_col_width { return 0.; }              // wider than view ⇒ left-align
    let padding = ((view_width - new_col_width) / 2.).clamp(0., gaps); // gap, but never > half slack
    let new_x       = new_col_x - padding;
    let new_right_x = new_col_x + new_col_width + padding;
    if cur_x <= new_x && new_right_x <= cur_x + view_width {   // already fully visible
        return -(new_col_x - cur_x);                           // leave as is (re-based)
    }
    // else snap to whichever edge is less motion:
    let dist_to_left  = (cur_x - new_x).abs();
    let dist_to_right = ((cur_x + view_width) - new_right_x).abs();
    if dist_to_left <= dist_to_right { -padding }
    else { -(view_width - padding - new_col_width) }
}
```

**Centered** (`compute_new_view_offset_centered`, `scrolling.rs:571`):

```rust
fn compute_new_view_offset_centered(target_x, col_x, width, mode) -> f64 {
    if mode.is_fullscreen() { return fit(...); }
    let area = mode.is_maximized() ? parent_area : working_area;
    if area.size.w <= width { return fit(...); }     // too wide to center ⇒ left-align
    -(area.size.w - width) / 2. - area.loc.x          // center it
}
```

**Dispatch** (`compute_new_view_offset_for_column`, `scrolling.rs:620`):

```rust
if is_centering_focused_column() { return centered(idx); }
match center_focused_column {
    Always     => centered(idx),
    OnOverflow => {
        // If no previous column, or re-activating the same column ⇒ fit.
        // Else take the neighbor on the side of prev_idx as the "source":
        let source_idx = prev_idx > idx ? min(idx+1, last) : idx.saturating_sub(1);
        // total width of source..target span + 2*gaps:
        let total_width = (span between source and target) + 2*gaps;
        if total_width <= working.w { fit(idx) } else { centered(idx) }
    }
    Never      => fit(idx),
}
```

So `OnOverflow` centers the newly focused column only when it can't fit on screen
together with the previously focused one.

### 4.4 When the view offset is recomputed

Recomputation is driven through `animate_view_offset*` helpers
(`scrolling.rs:680-768`). The pattern: compute a new target offset for a column, re-base
the current offset by the change in column X, then either snap (if already there within
1px) or start an animation.

Triggers:

- **Focus moves** (`activate_column`, `scrolling.rs:769`): if the target differs from the
  active column, `animate_view_offset_to_column_with_config(None, idx, Some(prev_idx),
  config)` then update `active_column_idx`. Re-activating the same column is a no-op
  (unless a DnD scroll is active).
- **Config update** (`update_config`, `scrolling.rs:313`): re-applies centering by calling
  `animate_view_offset_to_column(None, active_column_idx, None)` (so toggling
  always-center takes effect immediately).
- **Column added** (`add_column`, `scrolling.rs:963`): other columns animate their X
  slide; if the new column is activated and the workspace **was empty**, the view offset
  is reset to `Static(0)` then set to the computed offset (no animation for the first
  window). Stores `activate_prev_column_on_removal` = previous offset if the new column is
  inserted immediately right of the active one (so closing it returns you home).
- **Tile/column removed** (`remove_tile_by_idx`/`remove_column_by_idx`,
  `scrolling.rs:1052`/`1162`): adjacent columns animate to fill the gap. If a column to
  the left of active was removed, `active_column_idx -= 1` (position preserved, no view
  motion). If the active column was removed and `activate_prev_column_on_removal` is set,
  activate the previous column and restore the saved offset; else activate
  `min(active_column_idx, last)`.
- **Resize/width change** (`update_window`, `scrolling.rs:1272`): if the active column
  resized, the offset is adjusted to keep the resized window visible: for centered mode,
  recenter; for a left-edge interactive resize, shift by `-offset`; otherwise leave it,
  then `animate_view_offset_to_column` to re-fit. Skipped while a gesture or interactive
  resize is freezing the view.
- **Fullscreen/unfullscreen**: when the active column goes non-normal,
  `view_offset_to_restore = view_offset.stationary()`; on returning to normal, restore it
  (`unfullscreen_offset`), then re-fit.
- **Explicit centering**: `center_column` / `center_window` / `center_visible_columns`
  (`scrolling.rs:2199-2293`).

### 4.5 Edge behavior & snapping (gesture end)

`view_offset_gesture_end` (`scrolling.rs:3161`) computes **snapping points** — view
positions where the viewport aligns with column boundaries — and picks the one nearest
the projected (post-deceleration) end position. Crucially it clamps the reachable range:

> Prevent the gesture from snapping further than the first/last column.

It computes `leftmost_snap` (first column's left snap) and `rightmost_snap` (last
column's right snap minus view width) and pushes those as bounds. So you **cannot scroll
the strip past the first column on the left or the last column on the right** via a
gesture (free scroll is bounded; it's "ok if leftmost > rightmost" when all columns
together are narrower than the view). For non-gesture focus moves, the fit/center math
above naturally keeps the active column on screen.

In `Always`-center mode, each column's snap is its centered position; in `Never`/
`OnOverflow`, snaps are at the left/right aligned positions (with the `OnOverflow`
center-vs-edge choice baked into the snap computation, mirroring §4.3).

### 4.6 Working area, view size, struts, gaps, borders

- `view_size` = the full output logical size (used for fullscreen).
- `parent_area` = view minus layer-shell exclusive zones (panels), before struts.
- `working_area` = `parent_area` minus niri **struts**, with location rounded up to a
  physical pixel. `compute_working_area` (`scrolling.rs:5491`):

```rust
working = parent_area;
working.size.w = max(0, w - struts.left - struts.right);  working.loc.x += struts.left;
working.size.h = max(0, h - struts.top  - struts.bottom); working.loc.y += struts.top;
// round loc up to a physical pixel, shrink size to match:
loc = working.loc.to_physical_precise_ceil(scale).to_logical(scale);
working.size -= (loc - working.loc); working.loc = loc;
```

Struts may be **negative** (push windows outside the screen edge) — used to emulate
inner-vs-outer gaps. `working_area.loc.x` is the left strut/panel inset; it shows up in
the view-offset math as the `area.loc.x` term and as `left_strut`/`right_strut` in the
snap computation.

- **Gaps** (`options.layout.gaps`, default 16) appear: (a) as inter-column spacing in
  `column_xs`, (b) above/below/between tiles in a column, (c) as the maximum left/right
  **padding** in `compute_new_view_offset` (so the active column peeks with at most one
  gap of margin), (d) folded into the proportion formula so proportions are gaps-aware.
- **Borders** shrink the window inside the tile (`tile_size = window_size + 2*border`),
  and are subtracted when computing toplevel bounds (`compute_toplevel_bounds`,
  `scrolling.rs:5521`). The **focus ring** is drawn only around the active window and does
  **not** affect sizes.
- **Tab indicator** adds `extra_size` to a tabbed column's width/height only when
  `place_within_column` is set (otherwise it overlays neighbors and is size-neutral).

---

## 5. FOCUS WITHIN THE STRIP

Two indices define focus: `ScrollingSpace.active_column_idx` (which column) and
`Column.active_tile_idx` (which tile in that column).

### 5.1 Horizontal focus (between columns)

`scrolling.rs:1551`:

```rust
pub fn focus_left(&mut self) -> bool {
    if active_column_idx == 0 { return false; }       // at left edge: no-op, returns false
    activate_column(active_column_idx - 1); true
}
pub fn focus_right(&mut self) -> bool {
    if active_column_idx + 1 >= columns.len() { return false; }  // at right edge
    activate_column(active_column_idx + 1); true
}
pub fn focus_column_first(&mut self)  { activate_column(0); }
pub fn focus_column_last(&mut self)   { activate_column(columns.len()-1); }
pub fn focus_column(&mut self, index) { activate_column(index.saturating_sub(1).min(last)); }
```

Edges: `focus_left`/`focus_right` return `false` and do nothing at the strip's ends (no
wraparound). The boolean return lets callers fall through to e.g. switching workspaces or
monitors. `focus_column(index)` is 1-based (clamped). Activating a column triggers the
view-offset recompute described in §4.4.

### 5.2 Vertical focus (within a column) — `scrolling.rs:1596`

```rust
pub fn focus_down(&mut self) -> bool { columns[active].focus_down() }
pub fn focus_up(&mut self)   -> bool { columns[active].focus_up() }
```

`Column` methods (`scrolling.rs:4729`):

```rust
fn focus_up(&mut self)   -> bool { activate_idx(active_tile_idx.saturating_sub(1)) }
fn focus_down(&mut self) -> bool { activate_idx(min(active_tile_idx+1, tiles.len()-1)) }
fn focus_top(&mut self)          { activate_idx(0); }
fn focus_bottom(&mut self)       { activate_idx(tiles.len()-1); }
fn focus_index(&mut self, i: u8) { activate_idx(min((i-1) as usize, tiles.len()-1)); } // 1-based
```

`activate_idx` (`scrolling.rs:4280`) returns `false` (no movement) if already at that
index; otherwise sets `active_tile_idx` and ensures the now-active tile animates to opaque
(important in tabbed mode where background tabs are transparent). Edges clamp (no
wraparound); `focus_up` at the top / `focus_down` at the bottom return `false`.

### 5.3 Combined "down-or-left" etc. — `scrolling.rs:1612`

For ergonomic single-key navigation that crosses column boundaries:

```rust
focus_down_or_left:  if !column.focus_down() { focus_left(); }
focus_down_or_right: if !column.focus_down() { focus_right(); }
focus_up_or_left:    if !column.focus_up()   { focus_left(); }
focus_up_or_right:   if !column.focus_up()   { focus_right(); }
```

I.e. try to move within the column; if at the column edge, move to the adjacent column.

### 5.4 Which tile is "active" after structural changes

After removing a tile (`remove_tile_by_idx`, §6), `active_tile_idx` is fixed up: if a tile
above the active one was removed, decrement; if the active tile itself was removed and it
was the bottom one, activate the new bottom; otherwise the index stays and the newly-at-
that-index tile becomes active. Adding a tile above the active index increments it.

---

## 6. STRUCTURAL OPERATIONS

All structural operations are pure data transformations on the `columns`/`tiles` vectors
plus index fix-ups; the `animate_move_*` / `render_offset` calls are visual sugar layered
on top and can be ignored for a server-side model (or reproduced as transitions). The
parallel `data` vectors are kept in lockstep (`data.insert/remove`, `data.update`).

### 6.1 Add a column — `add_column` (`scrolling.rs:963`)

```rust
idx = idx.unwrap_or(was_empty ? 0 : active_column_idx + 1);  // default: right of active
column.update_config(...);
data.insert(idx, ColumnData::new(&column));
columns.insert(idx, column);
if !was_empty && idx <= active_column_idx { active_column_idx += 1; } // keep pointing at same col
// (animate neighbors' X)
if activate {
    if was_empty { view_offset = Static(compute_new_view_offset_for_column(None, idx, None)); }
    let prev_offset = (!was_empty && idx == active_column_idx + 1).then(|| view_offset.stationary());
    activate_column_with_anim_config(idx, ...);
    activate_prev_column_on_removal = prev_offset;  // so closing returns home
}
```

`add_tile(col_idx, tile, activate, width, is_full_width, anim)` (`scrolling.rs:868`) wraps
a tile in a fresh single-tile `Column::new_with_tile` then `add_column`.

### 6.2 Add a tile into an existing column — `add_tile_to_column` (`scrolling.rs:890`)

```rust
tile_idx = tile_idx.unwrap_or(target.tiles.len());  // default: append at bottom
target.add_tile_at(tile_idx, tile);                 // inserts into tiles+data, re-runs distribution
data[col_idx].update(target);
if tile_idx <= prev_active_tile_idx { target.active_tile_idx += 1; }  // keep active pointing same
if activate { target.activate_idx(tile_idx); if active_column_idx != col_idx { activate_column(col_idx); } }
// tabbed: fade animations; widen-column-then-shift-neighbors handling
```

`Column::add_tile_at` (`scrolling.rs:4297`): inserts into `tiles` and `data`
(`TileData::new(tile, auto_1())` — new tiles start `Auto{1}`), clears pending
fullscreen/maximized unless tabbed, then `update_tile_sizes(true)`.

### 6.3 Remove a tile — `remove_tile_by_idx` (`scrolling.rs:1052`)

```rust
if columns[col].tiles.len() == 1 {        // last tile ⇒ remove whole column
    let mut column = remove_column_by_idx(col, anim);
    return RemovedTile { tile: column.tiles.remove(tile_idx), width, is_full_width, is_floating:false };
}
let tile = column.tiles.remove(tile_idx); column.data.remove(tile_idx);
if column.data.len() == 1 { reset that tile's Auto weight to 1; }   // invariant
// fix active_tile_idx (see §5.4); re-run distribution; animate neighbors
column.update_tile_sizes_with_transaction(true, transaction);
data[col].update(column);
```

`remove_column_by_idx` (`scrolling.rs:1162`): `columns.remove(idx)`, `data.remove(idx)`,
then the focus/offset fix-up described in §4.4. Returns the removed `Column` (so callers
can move it elsewhere, e.g. to another workspace). `RemovedTile` carries the tile plus its
column's `width` and `is_full_width` so it can be re-inserted preserving sizing.

### 6.4 Consume / expel (move a window between a column and its neighbor)

These implement "merge the active window into the adjacent column" (consume) and "split
the active window out into its own column" (expel). The direction-aware versions
(`consume_or_expel_window_left/right`) decide based on column membership:

`consume_or_expel_window_left` (`scrolling.rs:1765`):

- **If the source column has 1 tile** → *consume into the column on the left*: remove the
  whole source column and `add_tile_to_column(target = source_idx - 1, append)`. (No-op if
  already leftmost.)
- **If the source column has >1 tile** → *expel to the left*: remove the tile and
  `add_tile(Some(source_idx), ...)` — i.e. create a new column at the source's position,
  pushing the rest of the source column right.

`consume_or_expel_window_right` (`scrolling.rs:1873`) mirrors it:

- 1 tile → consume into `source_idx + 1` (no-op if rightmost).
- \>1 tile → expel into a new column at `source_idx + 1`.

Pure, dedicated variants:

`consume_into_column` (`scrolling.rs:1965`): take the **first tile of the next column**
and append it to the active column. No-op if `<2` columns or active is last.

```rust
target = active_column_idx; source = active_column_idx + 1;
removed = remove_tile_by_idx(source, 0, ...);     // top tile of next column
add_tile_to_column(target, None, removed.tile, false);  // append, don't activate
```

`expel_from_column` (`scrolling.rs:1994`): take the **last (bottom) tile of the active
column** and put it into a new column immediately to the right. No-op if active column has
1 tile.

```rust
source_tile_idx = source.tiles.len() - 1;
removed = remove_tile_by_idx(source, source_tile_idx, ...);
add_tile(Some(active_column_idx + 1), removed.tile, false, removed.width, removed.is_full_width, ...);
```

### 6.5 Move a column horizontally — `move_column_to` (`scrolling.rs:1680`)

```rust
fn move_column_to(&mut self, new_idx) {
    if active_column_idx == new_idx { return; }
    let column = columns.remove(active_column_idx); let data = self.data.remove(active_column_idx);
    cancel_resize_for_column(...);
    columns.insert(new_idx, column); self.data.insert(new_idx, data);
    // re-base view_offset so the camera stays put while moving left:
    view_offset.offset(-column_x(active_column_idx) + current_col_x);
    activate_column_with_anim_config(new_idx, ...);   // active follows the moved column
}
```

`move_left`/`move_right` (`scrolling.rs:1717`): step by ±1 (return false at edges).
`move_column_to_first`/`_last`/`_to_index` clamp. The active column **moves with** the
operation (the focus follows the window).

### 6.6 Move a window vertically within a column — `Column::move_up`/`move_down`

`scrolling.rs:4750`:

```rust
fn move_up(&mut self) -> bool {
    let new_idx = active_tile_idx.saturating_sub(1);
    if active_tile_idx == new_idx { return false; }      // at top: no-op
    tiles.swap(active_tile_idx, new_idx);
    data.swap(active_tile_idx, new_idx);                 // swap policies too!
    active_tile_idx = new_idx;
    // animate the two swapped tiles
    true
}
```

`move_down` is symmetric (clamped at the bottom). Both **swap the parallel `data` entries**
so each window keeps its own height policy. These return `false` at the column edges (the
strip-level `move_up`/`move_down` just delegate; they do **not** cross into other columns —
contrast with `focus_*_or_*`).

### 6.7 Swap a window across columns — `swap_window_in_direction` (`scrolling.rs:2032`)

Swaps the active tile with the active tile of the adjacent column:

- If at the first/last column for the given direction → no-op (the doc comment notes it's
  *equivalent to* consume/expel, but the code just returns).
- If **both** source and target columns are single-tile → it's just `move_column_to`.
- Otherwise: remove the source active tile, insert it at the target's active position,
  remove the (now shifted) target tile, and put it back into the source column at the
  source position (recreating the source column if it had been drained to empty). Restore
  both `active_tile_idx` values, animate, and `activate_column(target)`.

### 6.8 Display mode & fullscreen/maximize

- `toggle_column_tabbed_display` / `set_column_display(display)` (`scrolling.rs:2160`/`2174`):
  flips `Column.display_mode` between `Normal` and `Tabbed`; recomputes width/heights.
  Leaving tabbed mode with >1 tile forces fullscreen/maximized off.
- `set_fullscreen(window, bool)` (`scrolling.rs:2824`): if fullscreening a window that
  shares a non-tabbed column with others, it is first **expelled into its own column**
  (`consume_or_expel_window_right`), then `Column::set_fullscreen`. (A fullscreen column
  must be single-tile, OR tabbed.)
- `set_maximized(window, bool)` (`scrolling.rs:2855`): analogous.
- `expand_column_to_available_width` (`scrolling.rs:2727`): grows the active column to
  consume all free horizontal space among the currently fully-visible columns (sets
  `width = Fixed(active_width + available)`, clears preset, `update_tile_sizes`), or
  toggles full-width when it's the only on-screen column.

---

## 7. COORDINATE SYSTEM AND GAPS

### 7.1 Column X positions (left → right) — `column_xs` (`scrolling.rs:2304`)

```rust
fn column_xs(&self, data) -> impl Iterator<Item=f64> {
    let gaps = options.layout.gaps;
    let mut x = 0.;
    // (a dummy 0-width entry is appended so you can get "one past the last column" X)
    data.map(move |d| { let rv = x; x += d.width + gaps; rv })
}
fn column_x(&self, idx) -> f64 { column_xs(...).nth(idx).unwrap() }
```

So in **strip coordinates** (origin at the left edge of the first column):

```
column_x(0) = 0
column_x(1) = w0 + gaps
column_x(2) = w0 + gaps + w1 + gaps
column_x(k) = Σ_{i<k} (w_i + gaps)
```

where `w_i = data[i].width = columns[i].width()` (widest tile in the column, +tab extra).
There is **no leading gap** at strip x=0; the left margin is produced entirely by the
`view_offset` (which is typically `-gaps` or `-working_area.loc.x`), per §4.1.

### 7.2 Tile Y positions within a column — `tiles_origin` + `tile_offsets_iter`

`tiles_origin()` (`scrolling.rs:5169`) — the top-left of the first tile, in column-local
coordinates:

```rust
fn tiles_origin(&self) -> Point {
    match sizing_mode() {
        Normal     => (0, working_area.loc.y + gaps) + (tabbed ? tab_indicator.content_offset : 0),
        Maximized  => (0, parent_area.loc.y),
        Fullscreen => (0, 0),
    }
}
```

`tile_offsets_iter` (`scrolling.rs:5194`) walks tiles top→bottom:

```rust
let center = (center_focused_column == Always);
let mut origin = tiles_origin();
let tiles_width = max over data of size.w;   // column width sans tab extra
data.map(move |d| {
    let mut pos = origin;
    if center { pos.x += (tiles_width - d.size.w) / 2.; }        // center narrower tiles
    else if d.interactively_resizing_by_left_edge { pos.x += tiles_width - d.size.w; } // right-align
    if !tabbed { origin.y += d.size.h + gaps; }                  // stack downward (gap between tiles)
    pos
});
```

In **Normal** mode tiles stack vertically: tile `t` is at `y = origin.y + Σ_{i<t}(h_i +
gaps)`. In **Tabbed** mode `origin.y` does not advance, so all tiles share the same
position (only the active one is drawn opaque; the tab indicator shows the rest).
Horizontally, tiles in a column are left-aligned by default, **centered** if
`center_focused_column = Always`, or **right-aligned** while interactively resizing by the
left edge (so the right edge stays put).

### 7.3 Absolute (screen) position of a tile — `tiles_with_render_positions`

`scrolling.rs:2377`:

```rust
let view_off = (-view_pos(), 0.);                       // = -(column_x(active) + view_offset)
for (col, col_x) in columns_in_render_order() {
    let col_render_off = col.render_offset();           // animation only
    for (tile, tile_off, visible) in col.tiles_in_render_order() {
        let pos = view_off + (col_x, 0.) + col_render_off + tile_off + tile.render_offset();
        pos = round_to_physical_pixels(pos, scale);
        yield (tile, pos, visible);
    }
}
```

So, **ignoring animation offsets**, the on-screen top-left of a tile is:

```
screen_pos = (col_x - view_pos + tile_off.x,  tile_off.y)
           = (column_x(col_idx) - view_pos + tile_offset_x,  tiles_origin.y + Σ heights+gaps)
```

with `view_pos = column_x(active_column_idx) + view_offset.current()`. The Y term has no
`- view_pos` because the strip only scrolls horizontally (each column is full-height).

### 7.4 Where the active column ends up

Because `view_offset` is stored relative to the active column and the fit/center math sets
it so the active column is visible with at most one `gaps` of padding:

- **Never** mode: the active column sits at the left edge (with `gaps` padding) if it was
  off-screen left, or right edge if off-screen right; if already visible, it doesn't move
  (least-motion rule in `compute_new_view_offset`).
- **Always** / single-column-centering: the active column is horizontally centered in the
  working area (`view_offset = -(area.w - col.w)/2 - area.loc.x`), unless it's wider than
  the view (then left-aligned).
- **OnOverflow**: behaves like Never while the new + previous columns fit together; centers
  the new column when they don't.

A column **wider than the view** is always left-aligned (`view_width <= width ⇒ offset 0`),
both in fit and centered paths.

### 7.5 Rendering order vs. data order

Data order is strict left→right (`columns`) and top→bottom (`tiles`). For drawing,
`*_in_render_order` iterators put the **active** column/tile first (so it draws on top /
last), then the rest in order. This is purely a render concern; the logical model is the
plain vectors and indices.

---

## 8. Pseudo-data-structures for a Racket port

A faithful, animation-free transliteration. Treat all sizes as exact rationals/flonums in
logical pixels; round to integers only when issuing window size requests.

```scheme
;; The strip.
(struct scrolling-space
  (columns            ; vector/list of column, ordered left→right
   active-column-idx  ; exact nonneg int
   view-offset        ; flonum: viewport-left-edge minus active column's x
   view-size          ; (w . h) full output
   working-area       ; rect: after struts+panels  (x y w h)
   parent-area        ; rect: after panels only
   scale              ; flonum
   options)           ; config record (see below)
  #:mutable)

;; A column: a vertical stack sharing one width.
(struct column
  (tiles              ; NON-EMPTY vector of tile
   tile-heights       ; parallel vector of window-height (the POLICY)
   tile-sizes         ; parallel vector of (w . h) resolved sizes (cache)
   active-tile-idx
   width              ; column-width
   preset-width-idx   ; (or #f exact-int)
   full-width?        ; bool
   pending-fullscreen?
   pending-maximized?
   display-mode)      ; 'normal | 'tabbed
  #:mutable)

;; Width policy.
(struct cw-proportion (p))   ; fraction of working width (gaps-aware)
(struct cw-fixed      (px))  ; exact logical px

;; Height policy (per tile).
(struct wh-auto  (weight))   ; share of remaining height
(struct wh-fixed (px))       ; fixed WINDOW height
(struct wh-preset (idx))     ; index into preset-window-heights

;; A tile = window + uniform border inset.
(struct tile (window border-width sizing-mode) #:mutable)
;; sizing-mode ∈ {'normal 'maximized 'fullscreen}

;; Config (subset that matters for layout).
(struct options
  (gaps                       ; flonum (default 16)
   preset-column-widths       ; list of preset-size
   default-column-width       ; (or #f preset-size)
   preset-window-heights      ; list of preset-size
   center-focused-column      ; 'never | 'always | 'on-overflow
   always-center-single-column?
   default-column-display     ; 'normal | 'tabbed
   struts                     ; (left right top bottom)
   border-width border-off?))

(struct preset-proportion (p))
(struct preset-fixed (px))
```

Derived quantities (pure functions):

```scheme
;; widest tile width (+ tab extra if tabbed) — the realized column width
(define (column-realized-width col) (apply max (map car (column-tile-sizes col))))

;; cumulative left→right column x positions in STRIP coordinates
(define (column-x space k)
  (let loop ([i 0] [x 0.0])
    (if (= i k) x
        (loop (add1 i)
              (+ x (column-realized-width (vector-ref (cols space) i))
                 (options-gaps (opts space)))))))

;; viewport left edge in strip coordinates
(define (view-pos space)
  (+ (column-x space (active-column-idx space)) (view-offset space)))

;; on-screen top-left of a tile (ignoring animation offsets)
(define (tile-screen-pos space col-idx tile-idx)
  (define col (vector-ref (cols space) col-idx))
  (define tile-off (tile-offset col tile-idx))      ; (x . y) within the column
  (cons (+ (column-x space col-idx) (- (view-pos space)) (car tile-off))
        (cdr tile-off)))
```

Resolve a column width to px (gaps-aware), then clamp to tile min/max:

```scheme
(define (resolve-column-width space col w)
  (define working-w (rect-w (working-area space)))
  (define gaps (options-gaps (opts space)))
  (define extra (column-extra-width col))            ; tab indicator, else 0
  (match w
    [(cw-proportion p) (- (* (- working-w gaps) p) gaps extra)]
    [(cw-fixed px) px]))
```

Height distribution (Normal mode), the iterative weighted fill from §3.3:

```scheme
;; Inputs: list of (policy min-h max-h tile) ; budget = working-h - gaps*(n+1)
;; 1. Convert fixed/preset policies to fixed tile heights (clamped).
;; 2. Pin tiles with min-h == max-h to that height; subtract from budget.
;; 3. Loop: share_i = budget * weight_i / total_weight (rounded to int window px);
;;    if any auto share < its min-h, pin that tile to min-h and RESTART;
;;    else commit all shares. Each commit reduces budget by the rounded amount.
```

`switch-preset-column-width` (cyclic, with reverse):

```scheme
(define (toggle-width col forwards?)
  (define n (length (options-preset-column-widths (opts ...))))
  (define cur (and (not (column-full-width? col)) (column-preset-width-idx col)))
  (define idx
    (cond
      [cur (modulo (+ cur (if forwards? 1 (sub1 n))) n)]   ; already on a preset: step
      [forwards? (or (index-of-first-preset-wider-than-current ...) 0)]
      [else      (or (index-of-last-preset-narrower-than-current ...) (sub1 n))]))
  (set-column-width! col (preset->size-change (list-ref presets idx)) #t)
  (set-column-preset-width-idx! col idx))            ; re-set AFTER set-column-width clears it
```

---

## 9. Quick-reference: operation → function map

| User action / concept                       | Function (scrolling.rs)                         |
|---------------------------------------------|--------------------------------------------------|
| focus column left/right                     | `focus_left` / `focus_right`                     |
| focus window up/down                        | `focus_up` / `focus_down` (→ `Column::focus_*`)  |
| focus up/down crossing columns              | `focus_up_or_left` etc.                          |
| activate a column (drives view scroll)      | `activate_column` → `animate_view_offset_to_column` |
| move column left/right                      | `move_left` / `move_right` → `move_column_to`    |
| move window up/down in column               | `move_up` / `move_down` (→ `Column::move_*`, swaps data) |
| swap window across columns                  | `swap_window_in_direction`                       |
| consume/expel left/right                    | `consume_or_expel_window_left` / `_right`        |
| consume next col's top tile                 | `consume_into_column`                            |
| expel bottom tile to new column             | `expel_from_column`                              |
| add window (new column)                     | `add_tile` → `add_column`                        |
| add window into a column                    | `add_tile_to_column` → `Column::add_tile_at`     |
| remove a tile/column                        | `remove_tile_by_idx` / `remove_column_by_idx`    |
| switch preset column width (Mod+R)          | `toggle_width` → `Column::toggle_width`          |
| toggle full width                           | `toggle_full_width` → `Column::toggle_full_width`|
| set/adjust window width                     | `set_window_width` → `Column::set_column_width`  |
| switch preset window height                 | `toggle_window_height` → `Column::toggle_window_height` |
| set/adjust/reset window height              | `set_window_height` / `reset_window_height`      |
| expand column to available width            | `expand_column_to_available_width`               |
| center column / window                      | `center_column` / `center_window` / `center_visible_columns` |
| tabbed display toggle                       | `toggle_column_tabbed_display` / `set_column_display` |
| fullscreen / maximize                       | `set_fullscreen` / `set_maximized`               |
| height distribution                         | `Column::update_tile_sizes_with_transaction`     |
| resolve column width                        | `Column::resolve_column_width`                   |
| column x positions                          | `column_xs` / `column_x`                         |
| tile y positions                            | `Column::tiles_origin` / `tile_offsets_iter`     |
| view position                               | `view_pos` / `target_view_pos`                   |
| fit/center view math                        | `compute_new_view_offset(_fit/_centered/_for_column)` |
| working area from struts                    | `compute_working_area`                           |

---

## 10. Footnotes / gotchas for the reimplementation

1. **Two widths per column**: the *desired* `Column.width: ColumnWidth` (a policy) vs the
   *realized* `ColumnData.width = Column::width()` (max tile width). X-positioning and
   centering use the realized width; preset cycling reads the realized/expected size.
   Windows can refuse exact sizes, so these diverge — keep both.

2. **Heights are window-space, widths are tile-space (mostly)**. `WindowHeight::Fixed` is a
   *window* height; the distribution converts to *tile* heights via
   `tile_height_for_window_height` (adds borders). Column proportions resolve to *tile*
   widths. `SizeChange::SetFixed` for width targets the active *window* width. Track the
   border inset carefully at each conversion.

3. **Only one non-auto tile per column.** Setting any tile's height first converts all
   others to `Auto` with weights preserving current visual heights (median = weight 1).

4. **The auto-height loop ignores max-heights** (only respects min-heights); exact-size
   dialogs (`min.h == max.h`) are pinned beforehand. Don't try to honor arbitrary
   max-heights in the iterative fill — niri deliberately doesn't.

5. **`view_offset` is relative to the active column.** Re-base it (`offset(old_x - new_x)`)
   whenever the active column's strip-X changes (insert/remove/move/resize to the left), or
   the active column will appear to jump.

6. **No wraparound.** All `focus_*`/`move_*` clamp or return `false` at the strip ends and
   column ends. Gesture scrolling is bounded to first-column-left / last-column-right snaps.

7. **Gaps are everywhere and the proportion formula is gaps-aware.** `(working - gaps)*p -
   gaps` (minus tab extra) makes `1/N` proportions tile exactly. The left screen margin is
   *not* a leading gap in strip coordinates — it comes from `view_offset` (≈ `-gaps` /
   `-working_area.loc.x`) and the `≤ gaps` padding clamp in `compute_new_view_offset`.

8. **Working area vs view size vs parent area.** Fullscreen uses `view_size`; maximized uses
   `parent_area`; normal tiling uses `working_area`. Struts (which may be negative) shrink
   `working_area` from `parent_area`, and the working-area origin is rounded up to a
   physical pixel.

9. **Tabbed columns** stack all tiles at the same Y (only the active drawn opaque), share
   one height (the fixed one if present, else full), and add the tab-indicator `extra_size`
   to the column width only with `place_within_column`. A fullscreen/maximized column must
   be single-tile *or* tabbed.

10. **Parallel `data` vectors must stay in lockstep with `tiles`/`columns`** (insert/remove
    together; swap together in `move_up`/`move_down`; `update` after any geometry change).
```