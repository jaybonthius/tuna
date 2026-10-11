# Niri layout model: workspaces, monitors, focus & movement

Research brief for reimplementing Niri's *spatial layout model* server-side in
Racket (text editor project). This covers the **containment hierarchy**, the
**vertical workspace stack**, the **focus model**, and the **movement /
switching operations**. Wayland protocol, GPU rendering, and animation math are
deliberately ignored except where they reveal model state (e.g. the fractional
"view position between workspaces").

Source files (niri @ `/tmp/weevil-niri-ref/niri`):
- `src/layout/mod.rs` (≈5000 lines) — top-level `Layout`, `MonitorSet`, public ops, focus model.
- `src/layout/monitor.rs` — `Monitor` owns the vertical `Vec<Workspace>` + active index.
- `src/layout/workspace.rs` — a single `Workspace` = scrolling strip + floating layer.
- `src/layout/scrolling.rs` — `ScrollingSpace`, `Column`, the strip mechanics.
- `src/layout/tile.rs` — `Tile` (a window + decorations).
- `niri.wiki/Workspaces.md` — user-facing mental model.

The whole layout is generic over `W: LayoutElement` (the "window" trait). For a
text editor, `W` is your buffer/pane element; `W::Id` is its unique id.

---

## 1. HIERARCHY — exact containment and ownership

```
Layout<W>
└── monitor_set : MonitorSet<W>            (enum: Normal | NoOutputs)
    └── monitors : Vec<Monitor<W>>         (when outputs connected)
        └── workspaces : Vec<Workspace<W>> (vertical stack; ALWAYS ≥ 1)
            ├── scrolling : ScrollingSpace<W>   (the horizontal strip)
            │   └── columns : Vec<Column<W>>
            │       └── tiles : Vec<Tile<W>>
            │           └── window : W           (the actual element)
            └── floating  : FloatingSpace<W>     (overlapping floating layer)
                └── (its own tiles)
```

Each level and what it *owns* (real field names):

### `Layout<W>` (mod.rs:335)
The single root object. Fields:
```rust
struct Layout<W> {
    monitor_set: MonitorSet<W>,        // all monitors + workspaces live here
    is_active: bool,                   // does the layout draw as focused
    last_active_workspace_id: HashMap<String, WorkspaceId>, // per-output-name memory
    interactive_move: Option<InteractiveMoveState<W>>,      // drag in progress
    dnd: Option<DndData<W>>,
    clock: Clock,
    update_render_elements_time: Duration,
    overview_open: bool,
    overview_progress: Option<OverviewProgress>,
    options: Rc<Options>,              // config (layout, animations, gestures…)
}
```

`MonitorSet<W>` is an enum with two states (mod.rs:372):
```rust
enum MonitorSet<W> {
    Normal {
        monitors: Vec<Monitor<W>>,
        primary_idx: usize,            // which monitor is "primary"
        active_monitor_idx: usize,     // which monitor has focus
    },
    NoOutputs {
        workspaces: Vec<Workspace<W>>, // monitorless parking lot for workspaces
    },
}
```
**Key idea:** when *no* outputs are connected, workspaces still exist — they're
parked in `NoOutputs.workspaces` (no monitor, no active index). When an output
connects, those workspaces get re-homed onto a `Monitor`. For a server-side
editor with no real displays this `NoOutputs` mode is essentially "headless
state"; you may collapse the two modes, but note niri keeps workspaces alive
without a monitor.

### `Monitor<W>` (monitor.rs:47)
Owns one output and its **vertical stack of workspaces**.
```rust
struct Monitor<W> {
    output: Output,
    output_name: String,
    scale, view_size, working_area,        // geometry (ignore details)
    workspaces: Vec<Workspace<W>>,         // "Must always contain at least one."
    active_workspace_idx: usize,           // index into workspaces
    previous_workspace_id: Option<WorkspaceId>, // for back-and-forth
    workspace_switch: Option<WorkspaceSwitch>,  // in-progress vertical switch
    insert_hint: Option<InsertHint>,
    overview_open: bool,
    overview_progress: Option<OverviewProgress>,
    clock, base_options, options, layout_config,
}
```

### `Workspace<W>` (workspace.rs:44)
A single workspace = **one scrolling strip + one floating layer**, plus identity.
```rust
struct Workspace<W> {
    scrolling: ScrollingSpace<W>,      // the scrollable tiling strip
    floating: FloatingSpace<W>,        // floating windows on top
    floating_is_active: FloatingActive,// which layer has focus (enum below)
    original_output: OutputId,         // "home" output (string id), remembered
    output: Option<Output>,            // current output, None when parked
    scale, transform, view_size, working_area,
    name: Option<String>,              // None = dynamic, Some = named/static
    layout_config: Option<LayoutPart>, // per-workspace config override
    id: WorkspaceId,                   // unique, stable id (u64)
}
```
`FloatingActive` (workspace.rs:163) tri-state:
```rust
enum FloatingActive { No, NoButRaised, Yes }
```
`Yes` = floating layer focused; `No` = scrolling focused; `NoButRaised` =
scrolling focused but floating still drawn on top (focus-follows-mouse nicety).

### `ScrollingSpace<W>` (scrolling.rs:35)
The horizontal strip of columns. Owns the **horizontal scroll position**.
```rust
struct ScrollingSpace<W> {
    columns: Vec<Column<W>>,           // left→right columns
    data: Vec<ColumnData>,             // parallel cache (column widths)
    active_column_idx: usize,          // which column is focused
    view_offset: ViewOffset,           // horizontal camera (Static|Animation|Gesture)
    activate_prev_column_on_removal: Option<f64>,
    view_offset_to_restore: Option<f64>,
    closing_windows: Vec<ClosingWindow>,
    view_size, working_area, parent_area, scale, clock, options,
}
```
Note: `columns` and `data` are **parallel vectors** indexed together; any insert/
remove must touch both.

### `Column<W>` (scrolling.rs:146)
A vertical stack of tiles that share a width.
```rust
struct Column<W> {
    tiles: Vec<Tile<W>>,               // "Must be non-empty."
    data: Vec<TileData>,               // parallel cache (heights/sizes)
    active_tile_idx: usize,            // which tile is focused inside the column
    width: ColumnWidth,                // Proportion(f64) | Fixed(f64)
    preset_width_idx: Option<usize>,
    is_full_width: bool,
    is_pending_fullscreen: bool,
    is_pending_maximized: bool,
    display_mode: ColumnDisplay,       // Normal | Tabbed
    tab_indicator, move_animation,
    view_size, working_area, parent_area, scale, clock, options,
}
```
**Invariant:** a `Column` is never empty. Removing the last tile removes the
whole column (see §5). `ColumnWidth` (scrolling.rs:236) and `WindowHeight`
(scrolling.rs:257) encode sizing; heights are mostly `Auto { weight }` so a
column fills the workspace height.

### `Tile<W>` (tile.rs:40)
Wraps one window/element plus its chrome.
```rust
struct Tile<W> {
    window: W,                         // the actual element (W::Id identifies it)
    border, focus_ring, shadow,
    sizing_mode: SizingMode,           // Normal | Maximized | Fullscreen
    restore_to_floating: bool,
    floating_window_size, floating_pos, floating_preset_width_idx, …,
    open/resize/move/alpha animations,
    interactive_move_offset, unmap_snapshot, view_size, scale, clock, options,
}
```

**Translation note for Racket:** model these as nested structs/objects holding
vectors + an active index at each level. The four "active indices" —
`active_monitor_idx`, `active_workspace_idx`, `active_column_idx`,
`active_tile_idx` (+ the `floating_is_active` flag) — *are* the focus path
(see §4). Stable ids (`WorkspaceId`, `W::Id`) are used for lookups; positional
indices are used for navigation.

---

## 2. WORKSPACE STACK — dynamic workspaces, active index, vertical switching

### How a monitor holds workspaces
`Monitor.workspaces: Vec<Workspace<W>>` + `Monitor.active_workspace_idx: usize`.
That's the whole stack. Index 0 is the **top**, `len-1` is the **bottom**.
There is no separate "list of workspace ids per monitor" — the `Vec` order *is*
the on-screen vertical order.

Accessors (monitor.rs):
```rust
fn active_workspace_idx(&self) -> usize
fn active_workspace_ref(&self) -> &Workspace<W>        // &workspaces[active_workspace_idx]
fn active_workspace(&mut self) -> &mut Workspace<W>
```

### The "dynamic workspaces" model (always one empty at the bottom)
Two hard invariants, enforced in `Monitor::verify_invariants` (monitor.rs:~1990):
- **"monitor must have an empty workspace in the end"** — `workspaces.last()`
  has no windows and no name.
- With the optional config `empty_workspace_above_first`, **the first workspace
  must also be empty/unnamed.**
- Also: "non-active workspace can't be empty and unnamed except the last one"
  (no empty gaps left lying around while idle).

So the steady state is: `[named/occupied…] [bottom empty]`, with the active
index pointing anywhere. The bottom empty workspace is the "scratch" you open
onto; opening a window there triggers a new empty workspace below it.

**Auto-create** happens in `add_tile` / `add_column` (monitor.rs:489, 461):
```rust
if workspace_idx == self.workspaces.len() - 1 {
    // Insert a new empty workspace.
    self.add_workspace_bottom();
}
if self.options.layout.empty_workspace_above_first && workspace_idx == 0 {
    self.add_workspace_top();
    workspace_idx += 1;
}
```
`add_workspace_bottom()` = `add_workspace_at(len)`; `add_workspace_top()` =
`add_workspace_at(0)`. `add_workspace_at(idx)` (monitor.rs:404) inserts a fresh
`Workspace::new(...)`, and **fixes up indices**:
```rust
self.workspaces.insert(idx, ws);
if idx <= self.active_workspace_idx { self.active_workspace_idx += 1; }
if let Some(switch) = &mut self.workspace_switch {
    if idx as f64 <= switch.target_idx() { switch.offset(1); }
}
```

**Auto-remove** is `clean_up_workspaces()` (monitor.rs:565). It walks the stack
(skipping the protected first slot if `empty_workspace_above_first`, and always
skipping the last and the active one) and removes any workspace that is empty
and unnamed, decrementing `active_workspace_idx` when removing above it:
```rust
for idx in (range_start..self.workspaces.len() - 1).rev() {
    if self.active_workspace_idx == idx { continue; }
    if !self.workspaces[idx].has_windows_or_name() {
        self.workspaces.remove(idx);
        if self.active_workspace_idx > idx { self.active_workspace_idx -= 1; }
    }
}
```
`has_windows_or_name()` (workspace.rs:331) = `has_windows() || name.is_some()` —
this is the predicate that decides "is this workspace allowed to persist while
empty." `clean_up_workspaces` must NOT run mid-switch (it `assert!`s
`workspace_switch.is_none()`); callers gate on that.

### Tracking the active workspace & vertical switching
`activate_workspace_with_anim_config(idx, cfg)` (monitor.rs:425) is the core:
```rust
let current_idx = self.workspace_render_idx();         // fractional current pos
if self.active_workspace_idx != idx {
    self.previous_workspace_id = Some(self.workspaces[self.active_workspace_idx].id());
}
let prev_active_idx = self.active_workspace_idx;
self.active_workspace_idx = idx;                       // <-- the actual state change
…
if prev_active_idx == idx { return; }                  // nothing moved, no anim
self.workspace_switch = Some(WorkspaceSwitch::Animation(
    Animation::new(self.clock, current_idx, idx as f64, 0., config)));
```
So switching is just: remember previous id, set `active_workspace_idx`, and
kick off an animation from the old fractional position to the new integer index.

The vertical-switch commands (monitor.rs):
- `switch_workspace_up()` → `activate_workspace(active_idx.saturating_sub(1))`.
- `switch_workspace_down()` → `activate_workspace(min(active_idx+1, len-1))`.
- `switch_workspace(idx)` → `activate_workspace(min(idx, len-1))`.
- `switch_workspace_auto_back_and_forth(idx)` → if already on `idx`, jump to
  `previous_workspace_idx()`; else go to `idx`.
- `switch_workspace_previous()` → go to `previous_workspace_idx()` (looked up by
  `previous_workspace_id`).

`Layout` just forwards these to `active_monitor()` (mod.rs:2172-2205).

### "switch-to-workspace N" semantics
N is **positional, not identity** (wiki: "addressing workspaces by index"). The
public `Layout::switch_workspace(idx)` and `find_workspace_by_ref(Index(n))`
resolve against the *current* stack order, so `focus-workspace 2` always lands
on whatever is currently 2nd. (Note: `WorkspaceReference::Index` is 1-based —
`find_workspace_by_ref` does `index.saturating_sub(1)`; `focus_column` does the
same 1-based adjust.)

### Is there a fractional "view position between workspaces"? — YES
`Monitor.workspace_switch: Option<WorkspaceSwitch>` is exactly that. Definition
(monitor.rs:91):
```rust
enum WorkspaceSwitch {
    Animation(Animation),               // animating between two indices
    Gesture(WorkspaceSwitchGesture),    // finger/DnD-driven scrub
}
```
`WorkspaceSwitch::current_idx() -> f64` and `target_idx() -> f64` give the
fractional vertical camera position. The gesture variant holds `center_idx`,
`start_idx: f64`, `current_idx: f64`, a `SwipeTracker`, `is_clamped`, etc.
`Monitor::workspace_render_idx() -> f64` returns this fractional index (or the
plain `active_workspace_idx as f64` when no switch is in progress); the renderer
lays workspaces out vertically at `-render_idx * (ws_height + gap)`
(`workspaces_render_geo`, monitor.rs:1473).

**Are switches animated?** Yes — `WorkspaceSwitch::Animation`. The model truth
(`active_workspace_idx`) flips *immediately*; only the camera animates from the
previous fractional position to the new integer index. For a server-side editor
you can ignore the animation entirely and treat `active_workspace_idx` as the
state, but the data model literally supports a continuous between-workspaces
position.

---

## 3. NAMED (static) vs DYNAMIC workspaces — how they coexist

The only difference is `Workspace.name: Option<String>`:
- `None` → **dynamic**: subject to auto-create/auto-remove. Disappears when it
  becomes empty and non-active.
- `Some(name)` → **named / quasi-static**: `has_windows_or_name()` returns true
  even when empty, so `clean_up_workspaces` never removes it. It "remembers"
  its `original_output` and can be referred to by name.

Coexistence rules:
- They live in the **same `Vec<Workspace>`**, interleaved freely. Naming doesn't
  move a workspace; it just pins it.
- The **bottom** (and, if configured, the **top**) workspace must stay *unnamed*
  and empty (verify_invariants asserts `workspaces.last().name.is_none()`).
- `set_workspace_name(name, ref)` (mod.rs:4521): rejects duplicate names
  (case-insensitive), sets `ws.name`, then — because a freshly named workspace
  might be the first or last — calls `add_workspace_top()` / `add_workspace_bottom()`
  to restore the empty-edge invariants.
- `unname_workspace*` clears the name and re-runs `clean_up_workspaces` (so a
  now-empty unnamed workspace can be garbage-collected).
- Named workspaces are created from config via `ensure_named_workspace(cfg)`
  (mod.rs:2906): if no workspace with that name exists, build one with
  `Workspace::new_with_config` and `insert_workspace(ws, 0, false)` (inserted at
  the top of its chosen monitor, not activated). Lookup is
  `find_workspace_by_name` / `Monitor::find_named_workspace` (case-insensitive).
- Named workspaces also carry `original_output` so they return to their home
  monitor on reconnect.

Wiki guidance: indices are positional and *workspaces have no intrinsic index*;
names are the way to get stable references. You can emulate static workspaces by
naming them "one", "two", … and binding `focus-workspace "one"`.

---

## 4. FOCUS MODEL — where "what is focused" lives and how it resolves

Focus is **not a pointer/handle** — it's a *chain of active indices* down the
hierarchy:

```
Layout.monitor_set.active_monitor_idx           → which Monitor
  Monitor.active_workspace_idx                  → which Workspace
    Workspace.floating_is_active                → scrolling vs floating layer
      ScrollingSpace.active_column_idx          → which Column
        Column.active_tile_idx                  → which Tile  → its window
```

### Resolving the focused window
`Layout::focus_with_output()` (mod.rs:2279) is the canonical resolver:
```rust
pub fn focus_with_output(&self) -> Option<(&W, &Output)> {
    if let Some(InteractiveMoveState::Moving(move_)) = &self.interactive_move {
        return Some((move_.tile.window(), &move_.output)); // a dragged window wins
    }
    let MonitorSet::Normal { monitors, active_monitor_idx, .. } = &self.monitor_set else {
        return None;
    };
    let mon = &monitors[*active_monitor_idx];
    mon.active_window().map(|win| (win, &mon.output))
}
pub fn focus(&self) -> Option<&W> { self.focus_with_output().map(|(w,_)| w) }
```
Drilling down:
- `Monitor::active_window()` (monitor.rs) = `self.active_workspace_ref().active_window()`.
- `Workspace::active_window()` (workspace.rs:457): branch on `floating_is_active`
  → `floating.active_window()` or `scrolling.active_window()`.
- `ScrollingSpace::active_window()` (scrolling.rs:424):
  ```rust
  let col = &self.columns[self.active_column_idx];
  Some(col.tiles[col.active_tile_idx].window())
  ```

So "what is focused" = follow the active indices; there's no redundant stored
"focused window id" to keep in sync. (`NoOutputs` mode has no active monitor, so
`focus()` returns `None`.)

### How focus is *applied* to windows (the "activated" flag)
`Layout::refresh(is_active)` (mod.rs:4843) walks every monitor/workspace and
computes booleans, then pushes them down:
```rust
let is_active = self.is_active && idx == *active_monitor_idx && !moving;
for (ws_idx, ws) in mon.workspaces.iter_mut().enumerate() {
    let is_focused = is_active && ws_idx == mon.active_workspace_idx;
    ws.refresh(is_active, is_focused);
}
```
`Workspace::refresh` forwards activeness to the scrolling/floating spaces
respecting `floating_is_active`, which ultimately calls
`window.set_activated(true)` on the one active tile. **Translation:** keep focus
as indices; derive each element's `activated`/`focused` boolean during a single
top-down refresh pass.

### How focus operations traverse
Most `Layout::focus_*` methods (mod.rs:1922+) operate on the active workspace
only and delegate straight down:
```rust
pub fn focus_left(&mut self) {
    let Some(workspace) = self.active_workspace_mut() else { return };
    workspace.focus_left();
}
```
`Workspace::focus_left/right/up/down` branch on `floating_is_active` and call
into `scrolling` or `floating`. In the scrolling strip (scrolling.rs:1551):
- `focus_left` → if `active_column_idx==0` return false else
  `activate_column(active_column_idx-1)`.
- `focus_right` → if at last column return false else
  `activate_column(active_column_idx+1)`.
- `focus_down`/`focus_up` → delegate to the active `Column`, which moves
  `active_tile_idx` via `activate_idx(min/saturating_sub)` (scrolling.rs:4734).
- `focus_column(index)` → `activate_column((index-1).min(len-1))` (1-based).

The **boolean return values matter**: they encode "couldn't move further." That
lets the monitor/Layout layer escalate to the *next container*:
- `Monitor::focus_window_or_workspace_down()` (monitor.rs:632):
  ```rust
  if !self.active_workspace().focus_down() { self.switch_workspace_down(); }
  ```
  i.e. "move down a tile; if you're at the bottom tile, switch down a workspace."
- `Layout::focus_column_left_or_output(output)` (mod.rs:1993): "move left a
  column; if at the leftmost, jump focus to the neighboring monitor"
  (`focus_output`).

So focus *traversal escalates outward*: tile → column → workspace → monitor,
each level only taking over when the inner level reports it can't move.

### Setting focus from a window id (reverse lookup)
`Layout::activate_window(id)` (mod.rs:1514) scans all monitors/workspaces, calls
`ws.activate_window(id)` (which sets the column/tile/floating indices and returns
true on hit), and then fixes the *outer* indices: `*active_monitor_idx =
monitor_idx;` and `mon.switch_workspace(workspace_idx)` (unless a vertical swipe
is currently straddling that workspace). This is how clicking/raising a window
re-aligns the whole focus chain.

---

## 5. MOVING THINGS BETWEEN WORKSPACES (vertical, within a monitor)

All of these live on `Monitor` and are forwarded from `Layout`. The common
pattern is **remove from source strip → add to destination workspace** via
`MonitorAddWindowTarget::Workspace { id, column_idx }`, reusing the same
`add_tile`/`add_column` path that auto-creates/cleans up workspaces.

### `move_to_workspace_up/down(focus)` — move the active *window* (one tile)
(monitor.rs:683 / 718)
```rust
let new_idx = active_idx.saturating_sub(1);            // or min(active+1, len-1)
if new_idx == active_idx { return; }
let new_id = self.workspaces[new_idx].id();            // resolve by ID, not idx
let removed = workspace.remove_active_tile(Transaction::new())? ;  // RemovedTile
self.add_tile(removed.tile,
    MonitorAddWindowTarget::Workspace { id: new_id, column_idx: None },
    if focus { ActivateWindow::Yes } else { ActivateWindow::Smart },
    true, removed.width, removed.is_full_width, removed.is_floating);
```
`RemovedTile<W>` (mod.rs:492) is the carrier of all the info needed to re-add:
```rust
struct RemovedTile<W> {
    tile: Tile<W>,
    width: ColumnWidth,      // width the source column had
    is_full_width: bool,
    is_floating: bool,
}
```
`remove_active_tile` (workspace.rs) pulls from floating or scrolling depending on
`floating_is_active`, calls `window.output_leave(output)`, and fixes the layer
focus (`update_focus_floating_tiling_after_removing`). In the scrolling strip,
`remove_active_tile` → `remove_tile_by_idx`; **if the tile was the only one in
its column, the whole column is removed**, otherwise the column stays and other
tiles shift up (scrolling.rs:1040+).

### `move_to_workspace(window, idx, activate)` — move a specific window to idx N
(monitor.rs:760) Same shape, but: the source workspace is found by which one
`has_window(window)` (or the active one if `window=None`); destination is
`min(idx, len-1)` resolved to an id; uses `remove_tile(window, …)` for a named
window or `remove_active_tile` otherwise; finishes with `clean_up_workspaces()`
when no switch is animating.

### `move_column_to_workspace_up/down(activate)` — move a whole *column*
(monitor.rs:826 / 845)
```rust
let workspace = &mut self.workspaces[active_idx];
if workspace.floating_is_active() {
    self.move_to_workspace_up(activate);  // floating has no columns → move the tile
    return;
}
let column = workspace.remove_active_column()?;   // Column<W>
self.add_column(new_idx, column, activate);
```
`remove_active_column` (workspace.rs:592 → scrolling.rs:1154) lifts the entire
`Column<W>` (all its tiles, width, fullscreen flags) out of the source strip;
`Monitor::add_column(workspace_idx, column, activate)` (monitor.rs:461) inserts
it into the destination `ScrollingSpace` via `Workspace::add_column` →
`ScrollingSpace::add_column(None, …)` (appends right of active column), then runs
the same bottom/top auto-create logic and optionally activates the destination
workspace. `move_column_to_workspace(idx, activate)` is the by-index variant.

### Data transformations summary (the part a Racket port must replicate)
1. **Detach** from source `ScrollingSpace`:
   - remove `Tile` from `Column.tiles` (+ parallel `Column.data`); if column now
     empty, remove `Column` from `columns` (+ parallel `data`) and adjust
     `active_column_idx`. For a column move, remove the whole `Column` at
     `active_column_idx`.
   - On removal niri also calls `window.output_leave(output)` and adjusts
     `active_column_idx` / `active_tile_idx` so focus stays valid.
2. **Carry** width/full-width/floating flags in `RemovedTile` (single tile) or in
   the `Column` itself (column move).
3. **Attach** to destination `Workspace` keyed **by `WorkspaceId`** (not index —
   indices shift as workspaces auto-create):
   - single tile → `Workspace::add_tile(... target=Auto/NewColumnAt ...)` which
     makes a new single-tile column (or places it per target).
   - column → `Workspace::add_column` appends it to the destination strip.
4. **Re-home**: the destination workspace's `original_output` is reset to the
   current monitor if it's unnamed (`workspace.original_output = OutputId::new(&output)`).
5. **Maintain invariants**: if the destination was the bottom workspace, append a
   new empty bottom; if it was the top and `empty_workspace_above_first`, prepend
   a new empty top; then `clean_up_workspaces()` (when not mid-switch) reaps any
   now-empty source workspace.

### Across monitors / outputs (for completeness)
`Layout::move_to_output(window, output, ws_idx, activate)` (mod.rs:3283) and
`move_column_to_output` (mod.rs:3385) do the same detach→attach but the
destination is another `Monitor`'s workspace; `move_workspace_to_output*`
(mod.rs:3421) moves an *entire workspace* between monitors using
`Monitor::remove_workspace_by_idx` + `insert_workspace`.

---

## 6. MOVING WORKSPACES THEMSELVES (reordering the vertical stack)

`Monitor::move_workspace_down()` / `move_workspace_up()` (monitor.rs:1146 / 1170)
swap the active workspace with its neighbor and keep focus on it:
```rust
let mut new_idx = min(active_idx + 1, len - 1);   // (up: active.saturating_sub(1))
if new_idx == active_idx { return; }
self.workspaces.swap(active_idx, new_idx);        // <-- reorder the Vec
if new_idx == len - 1 { self.add_workspace_bottom(); }   // keep empty at bottom
if empty_workspace_above_first && active_idx == 0 { self.add_workspace_top(); new_idx += 1; }
let previous_workspace_id = self.previous_workspace_id;
self.activate_workspace(new_idx);                 // follow the moved workspace
self.workspace_switch = None;                     // cancel any animation
self.previous_workspace_id = previous_workspace_id; // don't clobber back-and-forth
self.clean_up_workspaces();
```
Key points for a port:
- Reordering is a plain `Vec::swap` (adjacent) — the workspace keeps its
  `WorkspaceId`; only its *position* (and therefore its positional index) changes.
- `active_workspace_idx` is updated to keep pointing at the **same** workspace it
  followed (focus tracks the moved workspace).
- After the swap, the empty-edge invariants are re-established and
  `clean_up_workspaces` runs (switch must be cancelled first).

`Monitor::move_workspace_to_idx(old_idx, new_idx)` (monitor.rs:1194) is the
general (non-adjacent) reorder: `remove(old_idx)` then `insert(new_idx)`, with
careful `active_workspace_idx` fix-up for all three cases (the active workspace
*was* the moved one; it sat between old and new and got shifted up; or shifted
down). `Layout::move_workspace_down/up/to_idx` (mod.rs:4476+) just forward to the
active monitor.

**The wiki's "new workspace in the middle" trick** falls out of this: open a
window on the bottom empty workspace (auto-creating a new empty bottom), then
`move-workspace-up` repeatedly to slide it to the desired position.

---

## 7. EMPTY-WORKSPACE / CLEANUP RULES (what keeps the stack tidy)

Invariants (from `Monitor::verify_invariants`, monitor.rs:~1980):
1. `workspaces` is **never empty** (≥ 1).
2. `active_workspace_idx < workspaces.len()`.
3. The **last** workspace has no windows and **no name** ("empty workspace in the
   end").
4. If `empty_workspace_above_first`: the **first** workspace is likewise empty &
   unnamed, and the stack length is never exactly 2 (must be 1, or ≥ 3).
5. When no switch is in progress: **no interior empty+unnamed workspaces** — every
   non-last (and non-first if that option is set), non-active workspace must
   satisfy `has_windows_or_name()`.

Mechanisms that enforce them:
- **`add_workspace_bottom()` / `add_workspace_top()`** auto-append/prepend an
  empty workspace whenever a window lands on the last/first slot (called from
  `add_tile`, `add_column`, `move_workspace_*`, `set_workspace_name`,
  `remove_workspace_by_idx`, `insert_workspace`, `append_workspaces`).
- **`clean_up_workspaces()`** (monitor.rs:565) reaps interior empty+unnamed
  workspaces, never touching the protected first slot, the last slot, or the
  active one; decrements `active_workspace_idx` for each removal above it. It
  **asserts `workspace_switch.is_none()`** — cleanup is deferred until any
  vertical switch finishes (`advance_animations` calls `clean_up_workspaces`
  when the switch animation completes, monitor.rs:~1245).
- **Inline cleanup on window removal** — `Layout::remove_window` (mod.rs:1112)
  removes a now-empty, non-active, non-last workspace immediately (when no switch
  is running), plus the special `empty_workspace_above_first && len==2` collapse.
- **`has_windows_or_name()`** is the single predicate gating persistence: named
  workspaces survive empty; unnamed ones don't.
- **Switch-aware deferral**: most ops check `if self.workspace_switch.is_none()`
  before cleaning, because removing workspaces mid-animation would jump the view.

For a server-side port without animation, you can collapse this to: *after any
structural mutation, (a) ensure the bottom (and optional top) workspace is empty/
unnamed by appending one if needed, then (b) remove every interior workspace that
is empty AND unnamed AND not active.*

---

## 8. How a window first ENTERS the layout + empty-state rendering

### Entry path
`Layout::add_window(window, target, width, height, is_full_width, is_floating,
activate)` (mod.rs:928) returns the output it landed on. `AddWindowTarget`
(mod.rs:516) chooses *where*:
```rust
enum AddWindowTarget<'a, W> {
    Auto,                 // active monitor + active workspace
    Output(&Output),      // that monitor, its active workspace
    Workspace(WorkspaceId),
    NextTo(&W::Id),       // same column-neighborhood as an existing window
}
```
Flow (Normal mode):
1. Resolve `(mon_idx, MonitorAddWindowTarget)`:
   - `Auto` → `(active_monitor_idx, Auto)`.
   - `Output` → find monitor by output, `Auto`.
   - `Workspace(id)` → find the monitor containing that workspace id, target
     `Workspace { id, column_idx: None }`.
   - `NextTo(id)` → find the monitor whose workspace `has_window(id)`, target
     `NextTo(id)`.
2. `mon.resolve_add_window_target(target)` (monitor.rs:521) turns that into a
   `(workspace_idx, WorkspaceAddWindowTarget)` pair:
   ```rust
   enum WorkspaceAddWindowTarget<'a, W> { Auto, NewColumnAt(usize), NextTo(&W::Id) }
   ```
   `Auto` → the monitor's `active_workspace_idx`.
3. Compute `scrolling_width` from the chosen workspace, then
   `mon.add_window(window, target, activate, width, is_full_width, is_floating)`.
   `Monitor::add_window` (monitor.rs:436) makes a `Tile` (via
   `workspaces[0].make_tile(window)` — tile config is uniform across a monitor's
   workspaces) and calls `add_tile`.
4. `Monitor::add_tile` (monitor.rs:478) → `workspace.add_tile(...)`, then:
   - re-home the workspace (`original_output = OutputId::new(&output)` if unnamed),
   - if it was the **last** workspace, `add_workspace_bottom()` (this is the
     "empty workspace immediately appears below" behavior),
   - if it was the **first** and `empty_workspace_above_first`,
     `add_workspace_top()`,
   - if `activate` resolves true, `activate_workspace(workspace_idx)`.

### Which workspace/column the window goes to
Inside `Workspace::add_tile` (workspace.rs:518), with `target = Auto`:
```rust
let activate = activate.map_smart(|| !self.is_active_pending_fullscreen());
if is_floating && tile.window().pending_sizing_mode().is_normal() {
    self.floating.add_tile(tile, activate);
    if activate || self.scrolling.is_empty() { self.floating_is_active = Yes; }
} else {
    self.scrolling.add_tile(None, tile, activate, width, is_full_width, None);
    if activate { self.floating_is_active = No; }
}
```
- Non-floating (default tiling) → `ScrollingSpace::add_tile(col_idx=None, …)`
  which wraps the tile in a **new single-tile `Column`** and inserts it; with
  `col_idx=None` it goes **right of the active column** (or at 0 if the strip was
  empty) — see `add_column` (scrolling.rs:963). If the strip was empty, the
  `view_offset` is reset to 0 and the column is centered without animation.
- `NewColumnAt(idx)` → inserts the new column at a specific index.
- `NextTo(id)` → `scrolling.add_tile_right_of(id, …)` (new column right of the
  one containing `id`), unless floating, in which case it floats above the
  neighbor.

`ActivateWindow` (mod.rs:504) governs whether the new window grabs focus:
`Yes` / `Smart` (heuristic — e.g. don't steal focus from a fullscreen window) /
`No`. When activated, the active indices (`active_column_idx`, `active_tile_idx`,
`floating_is_active`, and the monitor's `active_workspace_idx`) are updated to
point at the new tile.

In `NoOutputs` mode, `add_window` lazily creates a `Workspace::new_no_outputs`
if there are none, then adds to it the same way (no monitor bookkeeping).

### Empty-state rendering (what an empty workspace shows)
Each `Workspace` owns a `background_buffer: SolidColorBuffer` sized to the view
and colored `options.layout.background_color`; `render_background()`
(workspace.rs) emits a single solid-color element. An empty workspace therefore
renders as just that background (plus, in the overview, a `shadow`). There is no
window content and no placeholder text — the scrolling strip simply has
`columns.is_empty()` and the floating layer is empty. The monitor positions each
workspace vertically via `workspaces_render_geo()` at
`y = -workspace_render_idx * (ws_height + gap)`, so the always-present empty
bottom workspace is what you scroll down into. **For a text editor port:** an
empty workspace = "no panes," draw the background/placeholder; it still occupies
a slot in the stack and is the landing pad for the next opened pane.

---

## Appendix — minimal Racket-oriented data model

```racket
;; Root
(struct layout
  (monitors            ; vector of monitor   (or a 'no-outputs parked list)
   active-monitor-idx  ; exact nonneg int
   primary-idx
   is-active?
   last-active-ws-id   ; hash: output-name -> workspace-id
   overview-open?
   options) #:mutable)

(struct monitor
  (output-name
   workspaces          ; vector of workspace, ALWAYS length >= 1
   active-workspace-idx
   previous-workspace-id    ; or #f
   workspace-switch         ; or #f: (switch from-idx to-idx) — fractional camera
   view-size working-area scale) #:mutable)

(struct workspace
  (id                  ; stable unique id
   name                ; string or #f  (#f = dynamic, string = named/static)
   original-output     ; output-name string ("home")
   scrolling           ; scrolling-space
   floating            ; floating-space
   floating-active?)   ; 'no | 'no-but-raised | 'yes
  #:mutable)

(struct scrolling-space
  (columns             ; vector of column
   active-column-idx
   view-offset)        ; horizontal camera (number)
  #:mutable)

(struct column
  (tiles               ; vector of tile, NON-EMPTY
   active-tile-idx
   width               ; (proportion f) | (fixed px)
   full-width?
   fullscreen? maximized?
   display-mode)       ; 'normal | 'tabbed
  #:mutable)

(struct tile (window sizing-mode …) #:mutable)  ; window = your pane/buffer

;; Focus is the chain of active indices — no separate "focused" pointer:
(define (focused-window L)
  (and (layout-active? L)
       (let* ([m  (vector-ref (layout-monitors L) (layout-active-monitor-idx L))]
              [ws (vector-ref (monitor-workspaces m) (monitor-active-workspace-idx m))])
         (if (eq? (workspace-floating-active? ws) 'yes)
             (floating-active-window (workspace-floating ws))
             (let ([s (workspace-scrolling ws)])
               (and (positive? (vector-length (scrolling-space-columns s)))
                    (let ([c (vector-ref (scrolling-space-columns s)
                                         (scrolling-space-active-column-idx s))])
                      (tile-window
                       (vector-ref (column-tiles c)
                                   (column-active-tile-idx c))))))))))
```

Operation cheat-sheet (Layout-level → what changes):
- `focus-left/right`            → `active-column-idx` ± 1 (returns #f at edge).
- `focus-up/down`               → active column's `active-tile-idx` ± 1.
- `focus-window-or-workspace-down` → tile down; if at bottom, `switch-workspace-down`.
- `switch-workspace-up/down/N`  → set `active-workspace-idx`; remember previous id.
- `move-to-workspace-up/down`   → detach active tile → attach to neighbor ws (by id).
- `move-column-to-workspace-*`  → detach whole column → attach to neighbor ws.
- `move-workspace-up/down`      → `vector-swap!` workspaces; keep focus on it.
- `move-workspace-to-idx`       → remove+insert; fix `active-workspace-idx`.
- add window                    → new single-tile column right of active; maybe
                                  auto-append empty bottom workspace.
- after any structural change   → ensure empty bottom (+top); reap interior
                                  empty+unnamed non-active workspaces.
```
```
