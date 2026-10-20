# Scroll state, stage 2: report

Stage 2 of `agents/plans/scrolling.md` (commands, point and persistence) is done on branch `scroll-commands` in `/home/jay/Code/workbench-gerbil/tuna__scroll-commands`. Not merged, not pushed. There are three commits on top of `main`:

| Commit | Subject |
|---|---|
| `cd9f6e4` | scrolling: commands, point following, saved scroll state |
| `447ca9a` | scrolling: special scroll reports; point items name line starts |
| `c3d2557` | renderer: pin line ids by line end |

The kernel is unchanged: `git diff main --stat -- tuna/` is empty. `make test` passes under the memory cap: every Gerbil suite ends `OK`, and the frontend tests show 20 passed, 0 failed.

## What works now

- **`C-v` / `<next>`** puts the item one before the last item wholly in view at the top. The last two items in view stay visible (Emacs's `next-screen-context-lines`, 2). It always moves at least one item.
- **`M-v` / `<prior>`** puts the item one after the top item at the bottom.
- At the ends, `C-v` signals "End of buffer" and `M-v` signals "Beginning of buffer".
- **`C-l`** puts point's item at the centre, then the top, then the bottom, then the centre again (Emacs's `recenter-positions`).
- **Point and the view: whichever moved last wins.** This applies when point's item is known to be out of view.
  - **After a command that moves point or edits its text**, the view goes to point. Point's item goes to the edge it passed, or to the centre when it is more than a screen beyond that edge. A screen is the number of items last measured in view.
  - **After scrolling** (by hand, a scroll command or the scroll bar), point moves into view. It goes to the first line of its text in view if it was above, or the last if below, and keeps its column. The setting `scroll-moves-point` (default `#t`, in the scrolling plugin, readable per buffer) turns this off. Point then stays out of view until a command moves it or edits its text.
- **`M-<` / `M->`** (`beginning-of-buffer` / `end-of-buffer`, new in basic-editing) go through that rule. From far away, they place point's item at the centre, and the browser's scroll range turns that into the top or the bottom. Near, they place it at the edge.
- **Showing a buffer** places point's item at the centre (`set-view-showing!`, `new-view`). Near either end, that again becomes the top or the bottom.
- **Splitting a view** gives the new view the original's newest placement (item, alignment, offset) and its drawn counts (`copy-view`).
- **Each view's newest placement is saved with the session.** Once the browser has measured the view, that placement names its scroll state. After a restart, it is restored as a placement with the exact offset.
- **Scroll reports are special events** (Emacs's `special-event-map`), as the supervisor decided. They never become `this-command` or `last-command`, run no command hooks, and leave a pending prefix alone. So `C-l` keeps cycling and `C-n` keeps its goal column when a report arrives between keys. Scroll bar events stay ordinary commands.

## Changes by module

For each changed module: what changed, the contracts it imports, and the services it declares. Every import list and `requires:` list is the same as on `main`; no new dependencies.

| Module | What changed | Imports contracts | Services |
|---|---|---|---|
| `plugins/scrolling/plugin.ss` | See the [scrolling plugin](#the-scrolling-plugin) below. | commands, keys, settings, buffers, layout; runtime `HashTable` (new, as the buffers contract uses it) | requires commands, input, buffers, layout, settings (unchanged) |
| `plugins/buffers/contract.ss` | See the [buffers contract](#the-buffers-contract) below. | text-store, settings (unchanged) | defines buffers-service |
| `plugins/layout/contract.ss` | `saved-view-data` saves the newest placement: `(ITEM-NODE-ID LINE-START ALIGN OFFSET)` or `#f`. `restore-view-data` restores it with `place-view!` and the exact offset, falling back to centring point's item when the item is gone. An item node id the rebuilt tree lacks resolves to the root, as the view's node already does (node ids are not stable across restarts). | keys subset, settings, buffers (unchanged) | defines layout-service |
| `plugins/layout/plugin.ss`, `plugins/layout/tests/support/two-views.ss` | The saved view takes five fields. The `layout`, `layout-tree` and `layout-two-views` slots are now version 2, so old data is skipped (no migration). A stale comment on the saved format is fixed. | unchanged | requires commands, buffers, session, input, settings (unchanged) |
| `plugins/commands/contract.ss`, `plugins/commands/plugin.ss`, `plugins/commands/tests/support/toy-commands.ss` | New `call-special-command` on the `Commands` interface: runs a command, with its advice, outside the bookkeeping (no `this-command` or `last-command`, no pre- or post-command hooks). Implemented in both providers. | unchanged | provides commands |
| `plugins/keys/plugin.ss`, `plugins/keys/contract.ss` | Scroll reports resolve as special events through `call-special-command`; scroll bar events through `call-command`. The documentation says so. | keys, commands, settings, buffers subset (unchanged) | provides input; requires commands; optional settings, buffers (unchanged) |
| `plugins/basic-editing/plugin.ss` | `beginning-of-buffer` (`M-<`) and `end-of-buffer` (`M->`). | commands, keys, buffers (unchanged) | requires commands, input, buffers (unchanged) |
| `plugins/renderer/plugin.ss` | See the [renderer fix](#the-renderer-fix) below. | unchanged | provides renderer; requires buffers, layout, settings; optional input (unchanged) |
| `plugins/web/frontend/tuna-scroll.ts` (+ bundle) | `lastVisible` is now the last item wholly in view (0.5 px tolerance), or the top item when none is. It used to be the last item that starts above the bottom. | — | — |

### The scrolling plugin

- `C-v`, `<next>`, `M-v`, `<prior>` and `C-l` are bound in the plugin's keymap. No conflicts in the starter or demo keymaps; completion-vertical's `M-<` and `M->` are in its own local map.
- The point policy works through `pre-command-hook` and `post-command-hook`: snapshots form a stack, so nested commands such as `M-x` pair up.
- What the plugin keeps lives in one `scrolling-state` per activation (weak tables keyed by view):
  - which moved last in each view, point or the view;
  - one owed scroll per view;
  - the last placement made for point;
  - the `C-l` cycle.
- `view-scrolled` classifies each adopted report:
  - `placed`: the first report measured under that placement;
  - `moved`: the view scrolled by hand (same size, another top item or offset);
  - `still`: anything else.
- `scroll-bar-page` now waits for a measurement like `C-v`, and moves point.

### The buffers contract

- `scroll-facts` gains `placement` (the number it was measured under) and `root` (the node the scroller drew from).
- New `view-point-item` (the item among a root's items that holds a view's point; for a text inside a `'whole` node, that node) and `node-line-item` (a line as an item, named by its start).
- `place-view!` draws as many items on each side as the longer side now has.
- `initial-drawn-after` is renamed `initial-drawn-items` and now applies to both sides.
- `copy-view` keeps the placement and the drawn counts.
- `set-view-showing!` and `new-view` place point's item (`show-point!`); `reset-view!` still places the first item.

### The renderer fix

Line ids were pinned at the start of the first drawn line. They are now pinned at its end, so ids follow their text when a line is inserted exactly where drawing starts. That case broke walkthrough step 6 whenever the drawn run began at line 1.

The wording "the last item wholly in view" is also updated in the keys contract, the buffers contract and the renderer.

`make test`'s boundary checks pass: no plugin-to-plugin imports, no contract re-exports, declared use (`demo-check` included).

## Tests

| Test | What it covers |
|---|---|
| `plugins/scrolling/tests/integration/scrolling-test.ss` (13 new cases) | **C-v:** the last two items wholly in view go to the top; point moves there; a second press before the browser has measured waits and then runs.<br>**Ends:** C-v at the end and M-v at the start do nothing.<br>**M-v:** the first two items go to the bottom; point moves there.<br>**C-l:** cycles centre, top, bottom, centre, across an intervening report; a new point starts at the centre.<br>**Point out of view:** goes to the bottom or top edge, or the centre from far away; while a placement is pending, only certain cases are placed, and the report decides the rest.<br>**Loop guard:** a placement for point that the browser could not make is not made again.<br>**Scrolling by hand** moves point and keeps its column; a top item partly above the edge does not count as in view.<br>**`scroll-moves-point` off:** point stays, and the next point command places it.<br>**Scroll bar** moves point.<br>**Rows** (node items, point in a text inside a `'whole` row): showing the buffer centres the row; C-l; C-v pages rows; editing point's text brings its row back.<br>Older cases now start with a confirming report, so later reports count as hand scrolls. |
| `tests/integration/scrolling-commands-test.ss` (new; real layout, basic-editing, view-commands, minibuffer, echo-area) | **C-n / C-p** past the edges, one item at a time.<br>**M-> / M-<** centre from afar and go to the edge when near; the placement's token is the rendered line's.<br>**A report between keys** keeps the goal column and a pending `C-x` prefix.<br>**After C-v, typing** lands on the visible line.<br>**Showing a buffer** centres its point.<br>**C-x 2** copies the placement, offset and drawn counts. |
| `tests/integration/session-restart-test.ss` | **New case:** two views are saved, one measured (line 300, 5.5 px) and one placed (line 700, centre). After the restart, both placements come back exactly, along with the points. The page's marker carries `data-offset="5.5"`.<br>**Updated:** the slot version and the five-field view pattern. |
| `tests/integration/html-renderer-test.ss` | **New case:** line ids stay with their text when a line is inserted where drawing starts. It fails with the old pin and passes with the new one.<br>**Updated:** `make-scroll-facts` arity and `initial-drawn-items`. |
| `plugins/web/tests/unit/input.test.mjs` | `lastVisible` is the last item wholly in view. |

Commands, all run under `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 1800 …`:
- `make deps`;
- `make`;
- focused `gerbil test` runs per suite;
- `make test`. The final run exited 0 with `OK`; the frontend showed 20 passed, 0 failed.

## Browser results

Headless desktop Chrome through `agent_browser`, 1280×700. The demo config ran on port 9480 with a private `XDG_STATE_HOME` (`/tmp/tuna-s2-state`).

**Commands, in `*long*`:**
- **`C-v`:** lines 1–26 in view → 25 at the top. Then 48–71 → … Two lines of overlap each time; point follows to the new top.
- **`M-v`:** top 48 → 49 at the bottom. The next `M-v` from top 24 reaches the start, then "Beginning of buffer".
- **`C-n` ×40 from line 1:** point stays on the bottom line, line 41 (each step past the edge is a bottom placement).
- **`C-l` ×4 at line 41:**
  1. centre: lines 28–53;
  2. top: 41–62;
  3. bottom: 14–41;
  4. centre again.
- **`M->`:** line 50000 at the bottom.
- **`M-<`:** line 1 at the top.
- **Wheel down 3000 px:** point moved from line 52 to 148, the first line wholly in view. Typing `X` gave `X148…`, at the visible point.
- **`*rows*`:** `C-v`, `<next>` and `M-v` page rows (Row 489/509 → 508/527 → 526/545 → back), with two rows of overlap.

**The brief's walkthrough, steps 4–6:**
- **Step 4, refresh:** at line 1044 with 17 px above the edge, a reload landed on line 1044 at 17 px, point still in view.
- **Step 4, restart:** in `*scratch*`, 120 typed lines, wheel up 1013 px: row 35 at 3 px, point on row 67. After stopping and restarting Tuna, it was row 35 at 3 px, point on row 67. The saved datum was `(74 230 top 3.)`.
- **Split:** `C-x 2` gave both views 1044 at 17 px.
- **Step 5:** the commands above.
- **Step 6, ten lines inserted above:**
  - Setup: line 360 at the top, 24 px above the edge, with the drawn run starting at line 1. The other view typed `M-<` and `RET` ×10.
  - After: the first view still showed line 360 at 24 px.
  - Before the renderer fix, the view slid up 10 lines (line ids were pinned by line number at line 1).

**`check.js`, re-run after the changes:**

| Buffer | Blank frames | Jumps | First item at top | Idle reports | Reports in run |
|---|---|---|---|---|---|
| `*long*` | 0 | 0 | yes | 0 | 387 |
| `*rows*` | 0 | 0 | yes | 0 | 891 |

Every Tuna process started was stopped by PID: 2793629, 2877205, 2884861, 3054402, 3096992, 3140742 and 3143815. The managed browser was closed.

## Deviations and decisions, with reasons

1. **Point policy: whichever moved last wins.** A command that moves point or edits its text brings the view. Scrolling brings point.
   - Inside a screen, point's item goes to the edge; farther, to the centre. Emacs's default (`scroll-conservatively` 0) recentres even one line off; the task asked for edges.
   - "Moved point" means the selected view's focused node, point or text revision changed during the command. That is how `scroll-moves-point` off gets VS Code's "the next command that uses point" without a list of commands.
2. **What is in view, before the browser has measured the newest placement:**
   - Only the placement's item is known to be in view.
   - Items beyond the edge it was placed at are known to be out of view, so `C-n` held at the bottom places each step.
   - Anything else waits for the confirming report, which then applies the rule for whichever moved last.
   - A placement made for point that the browser measured without showing point is not repeated. This guards against a placement loop; one happened during development when an item token did not match.
3. **Paging scrolls (`C-v`, `M-v`, track clicks) need a measurement.** Run before one, a view owes one scroll (the newest) and runs it when the report comes. A double press is not lost, and a held key overshoots by at most one screen.
4. **`lastVisible` now means the last item wholly in view** (0.5 px tolerance). That matches the task's "last fully visible", and it means point never counts as visible on a line cut off at the bottom. A top item more than 0.5 px above the edge does not count as in view either.
5. **Point keeps its column** when scrolling moves it, as the task asked. Emacs's default moves it to the line's start (`scroll-preserve-screen-position` nil; `src/window.c` at Emacs commit `541f693c`, around lines 6617–6771).
6. **Point moves only within its own text node.** When the items in view hold no line of that text (rows, or a row holding the text), point stays. The next command that moves it brings the view back. The contract has no way for the scrolling plugin to change a view's focused node.
7. **`M->` ends at the bottom, not Emacs's `(recenter -3)`.** The centre placement is clamped by the browser's scroll range. For the same reason, `C-l` near the end can only show the end at the bottom.
8. **`place-view!` draws as many items on each side as the longer side has now.** A far target (for example `M->` from near the top, where the side before was cut short at 0) would otherwise have nothing above it to centre against. `initial-drawn-items` now applies to both sides for the same reason. This is only a fetching step; the next report trims it.
9. **Persistence saves the newest placement, not only `(item, offset)`.** A placement not yet measured (for example a pending centre) is restored as it was. Node ids are not stable across restarts (autosave rebuilds roots), so an id the rebuilt tree lacks resolves to its root, the existing rule for a view's node. The slot versions are bumped; old sessions are skipped, with no migration.
10. **Scroll reports are special events** (the supervisor's decision): `call-special-command` in the commands contract, chosen by event kind in the keys plugin. **The renderer's line-id pin** moved from line start to line end (a stage 1 defect found by step 6).
11. **The Gerbil MCP balance and syntax tools named in `agents/guides/gerbil.md` were not available to this worker.** Each edit was checked by `gerbil build` and the suites instead.

## Open points

- **A restart can leave no view to edit in (bug from before this branch).**
  - Cause: a view showing a plugin-owned buffer that autosave does not keep (for example the demo's `*long*`) is dropped on restore. If it was the only ordinary view, the layout keeps only the bar, and `neutral-data` then fails with `car` of an empty list: "Session slot layout failed to save: … PAIR expected".
  - How it showed: the browser restart check, until I used `*scratch*`.
  - Cause in code: the layout restore code, unchanged here. It is worth a fix, for example showing another buffer instead of dropping the view.
- **A synthetic flood of about 2,700 keydowns in 4.5 s overwhelmed the web transport's input ordering.** The log showed "Skipped missing input" and "Ignored duplicate input", and the page fell out of sync until reloaded. Normal typing rates were fine. The cause is web transport ordering, not scrolling.
- **`last-command` reflected scroll reports before this branch**, which reset the `C-n` goal column. The special-event change fixes it. Other non-user inputs, if any are added, should use special events too.
- **Items taller than the view** scroll by whole items with these commands; Emacs scrolls within a tall line (vscroll).
- **Key cost at 20,000 px drawn each way** (the stage 1 open point) is unchanged.
- **Records** (ADR, overview, `emacs-equivalents.md`) are left for stage 3. Divergences to record: special events; the edge-or-centre point rule versus Emacs's recentring; column kept; `M->` at the bottom; `scroll-moves-point`; one owed scroll.

Screenshots from the session (both from the debugging runs): `/tmp/tuna-s2-shot1.png` (the bar-only layout after the restart bug) and `/tmp/tuna-s2-shot2.png` (the page out of sync after the synthetic flood).
