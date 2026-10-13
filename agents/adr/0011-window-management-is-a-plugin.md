# 11. Window management is a replaceable plugin built on a small window contract

Status: accepted as direction (2026-10-11); amended 2026-10-13 by [ADR 13](0013-views-layout-and-frames.md), which replaces "window" with *view*, the window contract with the layout contract, makes frames movable pointers into the tree with frame marks, keeps per-container focus memory in the layout (not frame state), gives every container kind a horizontal and vertical form, and puts the minibuffer and echo area in the layout. Where they differ, ADR 13 wins. Research: [`agents/research/window-management/`](../research/window-management/README.md).

## Context

Emacs's window system is a fixed binary-split tree implemented in C: internal "combination" windows split horizontally or vertically, leaves are live windows, and Lisp customizes only policy (`display-buffer-alist`, window parameters, side and dedicated windows, `window-configuration`). Packages such as golden-ratio, edwina, popper, and tab-bar layer behavior on top but cannot change the model.

The owner wants something more flexible: i3-style splits, Niri-style scrolling strips, tabs, and any nesting of them, in one recursive model; and, unlike Emacs, the window manager itself must be replaceable. The owner's layout tree ([notes](../research/owner-notes/window-layout-topology.org)) already describes the recursive model, and Racket Tuna implemented it with declarative scroll anchors.

Making a whole subsystem replaceable is not something Emacs's paradigm does well even in Lisp: redefining functions replaces behavior but not the state other code depends on, and nothing tells dependents that the subsystem changed. Tuna's plugin model ([ADR 2](0002-plugins-contexts-and-services.md)) already has the three pieces this needs, taken from Cordis: services defined by interfaces, receipts that undo a plugin's commands and keys, and dependents that deactivate and reactivate when a provider changes. One piece is missing: moving existing state from one provider to another.

## Decision

- **Three layers.**
  1. **Window contract (core).** A window is a place that shows one view ([ADR 6](0006-buffers-nodes-and-text-store.md)). It has identity, parameters, and a dedicated flag. Each frame has a selected window. The `WindowManager` service interface covers what the rest of Tuna needs regardless of layout: list a frame's windows; select a window; split a window (with a direction hint); delete a window; delete other windows; find the neighbor in a direction; swap two windows; **display a buffer** (choose or create a window for it according to display rules, the `display-buffer` equivalent); capture and restore a window configuration as an opaque value; and render a frame's window area. Emacs-standard commands such as `C-x 2`, `C-x 0`, `C-x o`, and `windmove` call this interface, so they work under any window manager.
  2. **Default window manager (plugin).** Implements the owner's recursive layout tree: containers with a direction and a kind arrange ordered children; each parent–child edge carries a measure; leaves are windows; frames point at a container and render that subtree; focus belongs to the frame. Per-container focus memory (Niri's active column and active tile) is frame view state, not shared topology.
  3. **Container kinds (pluggable).** The default window manager accepts container kinds registered by plugins. Each kind defines how it sizes children (as CSS layout, since the browser owns geometry; [ADR 7](0007-rendering-and-transport.md)), which child directional navigation reaches, how it renders, and what scroll or anchor state it keeps. Initial kinds: `fit` (i3 and Emacs splits), `scroll` (Niri strips; scroll position is a declarative anchor child, not pixels), and `tabbed` (i3 tabs and stacks, Niri tabbed columns). Niri's model is then `scroll` (workspaces, vertical) of `scroll` (columns, horizontal) of `fit` (tiles, vertical).
- **Replacement.** `WindowManager` is an ordinary service. To replace it, the old provider exports a neutral description (each frame's windows in order, their views, the selected window, and window parameters) and the new provider imports it into its own arrangement. Window-manager-specific commands and keys (for example Niri's consume and expel) belong to the provider's plugin and disappear with it. Plugins that depend on particular capabilities (for example resizable splits) declare them and are deactivated when the provider lacks them.
- **Persistence.** Each provider saves its layout through a session slot ([ADR 5](0005-persistence.md)); a restored session whose provider is missing falls back to importing the neutral description.

## Consequences

- Users can choose i3-style, Niri-style, Emacs-style, or mixed layouts, or install a completely different window manager, without breaking commands that only need the contract.
- The contract must stay small and layout-agnostic; anything that only makes sense for trees belongs to the default provider.
- Geometry-dependent behavior (resizing by pixels, centering a column) waits on the layout-facts research in ADR 7.

## Alternatives considered

- **Emacs's fixed split tree.** Rejected: cannot express scrolling strips or tabs, and is not replaceable.
- **Niri's fixed three levels (Weevil).** Rejected: a special case of the recursive tree.
- **No contract; every window manager defines its own commands.** Rejected: `display-buffer`, help buffers, completion popups, and every package that opens a window would have to know each window manager.
