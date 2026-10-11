# Window management research

Collected 2026-10-11 from earlier efforts. Decision: [ADR 11](../../adr/0011-window-management-is-a-plugin.md). Owner-facing description: [`docs/ideas/window-management.md`](../../../docs/ideas/window-management.md).

## The owner's design (start here)

The owner's own model is a recursive **layout tree**: containers arrange ordered children along a direction and either *fit* them (sibling measures are weights) or *scroll* them (measures are fractions of the container, overflow scrolls); leaves are windows; a measure belongs to the parent–child edge so it travels with a moved subtree; a frame points at a node and renders that subtree; focus belongs to the frame, not the tree.

| Document | What it is |
|---|---|
| [`../owner-notes/layout.org`](../owner-notes/layout.org) | The owner's first notes: goals (tabs, tiling, Niri-style scrolling, or a mixture), the layout tree, `fit` vs `scroll`, frames as pointers into trees. |
| [`../owner-notes/window-layout-topology.org`](../owner-notes/window-layout-topology.org) | The owner's cleaned-up topology spec: structs, invariants, measure semantics, rendering, examples (fitted, scrolling, mixed), shared frames, zero measures. |
| [`../editor-corpus/prior-art/tuna/docs/plans/window-layout-topology.org`](../editor-corpus/prior-art/tuna/docs/plans/window-layout-topology.org) | The version **implemented** in Racket Tuna (July 2026): adds declarative scroll anchors (a scroll node stores which child is anchored; the renderer derives the translation), validation invariants, and the full set of topology commands (insert, wrap, move, remove, unwrap). |
| [`code/racket-tuna-layout.rkt`](code/racket-tuna-layout.rkt) | That implementation (600 lines, Racket; `~/Code/tuna` at `a32f46f`). A reference for operations and invariants, not code to port line by line. |

## Niri (scrollable tiling)

Researched against Niri's source for Weevil in June 2026, then implemented in Weevil's `niri-layout` worktree. Niri's own source is at `/home/jay/Code/niri` (the briefs cite a since-deleted `/tmp` clone; paths inside `src/layout/` are unchanged in spirit but re-verify line numbers).

| Document | What it is |
|---|---|
| [`niri/01-scrolling-strip-model.md`](niri/01-scrolling-strip-model.md) | The strip of columns, columns of tiles, view offset, centering and "least motion" camera rules, column widths and presets. The most useful brief. |
| [`niri/02-workspaces-monitor-focus-movement.md`](niri/02-workspaces-monitor-focus-movement.md) | Workspaces as a vertical stack, focus model (active column, active tile per column), movement between columns, workspaces and monitors. |
| [`niri/03-resize-tabs-keybindings.md`](niri/03-resize-tabs-keybindings.md) | Resizing, tabbed columns, default key bindings. |
| [`niri/04-datastar-cqrs-multipane.md`](niri/04-datastar-cqrs-multipane.md) | Rendering many panes over Datastar. **Written without web access; its own `[VERIFY]` tags apply.** Superseded where it conflicts with the vendored docs in [`../../reference/datastar/`](../../reference/datastar/). |
| [`niri/05-datastar-verification.md`](niri/05-datastar-verification.md) | Facts verified against the Racket Datastar SDK. Tuna uses the Gerbil SDK; re-verify there. |
| [`niri/weevil-niri-design.md`](niri/weevil-niri-design.md) | Weevil's design: session → frame (strip) → column → pane, Super-key layer, server-computed scrolling. |
| [`niri/weevil-niri-implementation-status.md`](niri/weevil-niri-implementation-status.md) | What Weevil actually built, deviations, and the open browser check on preserving scroll position across morphs. |
| [`code/weevil-niri-layout-geometry.rkt`](code/weevil-niri-layout-geometry.rkt) | Weevil's pure geometry kernel: width resolution with gaps, least-motion view offset, weighted heights, preset cycling. |

## Emacs-style splits

| Document | What it is |
|---|---|
| [`emacs-style/weevil-pane-layouts-plan.md`](emacs-style/weevil-pane-layouts-plan.md) | A plan (unbuilt, superseded by the Niri design) mirroring Emacs's window tree: `split-window`, `delete-window`, `other-window`, window-point semantics, with Emacs anchors. |
| [`../capability-audit/02-buffers-text-and-display.md`](../capability-audit/02-buffers-text-and-display.md) | Inventory rows for windows and frames: `window-point`, `display-buffer` and `display-buffer-alist`, side and dedicated windows, window parameters, window configurations, `quit-restore`. |

## Reading notes and conflicts

- **Weevil hard-codes Niri's three levels** (frame → column → pane). The owner's tree generalizes them: a Niri workspace is a horizontal *scroll* node whose children are vertical *fit* nodes (columns); workspaces are a vertical scroll node whose children each measure 1. Tabbed columns become a separate container kind.
- **Weevil computes pixel geometry on the server** (view offset, widths). Tuna's [ADR 7](../../adr/0007-rendering-and-transport.md) gives layout to the browser. Keep the *declarative* parts (which child is anchored or focused, measures, presets) on the server and let CSS and the browser do geometry; the least-motion and centering rules become rules for choosing the anchor, not pixel math. This interacts with the open layout-facts research.
- **Racket Tuna used `overflow: hidden` plus transforms** for scroll nodes. Native browser scrolling with scroll snapping, or a Rocket component, may be better; part of the layout research.
- **Focus memory.** Niri remembers the active tile per column and the active column per workspace, so moving back into a container restores where you were. The owner's topology keeps focus only on the frame. Something must remember per-container focus; it belongs with the frame's view state, not in the shared topology.
- **"Frame" terminology** matches: in the owner's design a frame points at a subtree, which is compatible with Tuna's Emacs meaning of frame (a top-level window shown in a client).
