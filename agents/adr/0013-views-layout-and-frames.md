# 13. Buffers as UI, views in a layout, and movable frames

Status: accepted (2026-10-13). Owner-approved brief: [`docs/briefs/2026-10-buffers-views-layout.md`](../../docs/briefs/2026-10-buffers-views-layout.md). Research: [`agents/research/layout-state/`](../research/layout-state/README.md), [`agents/research/window-management/`](../research/window-management/README.md); owner notes `agents/research/owner-notes/window-layout-topology.org`. Amended 2026-10-13 after stage 2 (see "Stage 2 additions") and with pinning (see "Pinning"). Amends [ADR 6](0006-buffers-nodes-and-text-store.md) (views, the buffers contract, files), [ADR 7](0007-rendering-and-transport.md) (what a redraw walks), and [ADR 11](0011-window-management-is-a-plugin.md) (vocabulary, frames, focus memory, container directions).

## Context

The owner wants one tree you can see and move around in: buffers are generic pieces of UI (a file, magit, a VS Code-style sidebar, the minibuffer, the echo area), a layout of containers arranges them, and you may look at any part of that tree, not only its top. ADR 11 had a separate *window* holding a *view* for life, a frame fixed at the top of the layout, focus memory as frame state, and the minibuffer and echo area outside the layout. ADR 6's buffers contract covered only the buffer list (audit P1-1): editing, undo, the change journal, and highlights were concrete procedures no replacement could change.

The layout-state research measured the options in Gerbil: the layout is small (about 50 parts) and benefits from snapshots; a rich buffer can have 100,000 wide, shallow parts, where frozen copying is slow and in-place change with revision stamps is cheap at any size.

## Decision

- **Vocabulary.** *Buffer*: a named piece of UI, a tree of *nodes*. *Text node*: a node holding editable text; other nodes are *rich nodes*. *Text*: characters, properties and undo history, referred to by text nodes; the *file link belongs to the text*. *Layout*: the tree of *containers* and *views*. *View*: one place in the layout showing one buffer, with its own selections, scroll and folding; it **replaces "window"**, which is no longer a Tuna concept. *Selected view*: the one receiving input. *Frame*: a movable pointer into the tree from which a browser tab draws. *Frame mark*: a saved frame location. Point, mark and region keep their Emacs meanings; a frame mark is never called just "mark".
- **One tree presented, two owners.** The layout plugin owns the layout as a frozen value (a change builds a new tree sharing unchanged parts; old values are free snapshots). Buffers plugins own buffers as nodes changed in place; each change stamps the changed node and its ancestors with a new revision number. The renderer presents the two as one tree: inside each view it walks that view's buffer. No shared tree library and nothing in the kernel.
- **Sharing.** Several views may show one buffer; they share everything buffer-level. A node belongs to exactly one buffer (one parent). Content is shared below that: several text nodes, in different buffers, may refer to one text or to a range of it, so a search-results buffer can edit a file's text directly (Emacs's wgrep copies instead).
- **Containers.** Kinds *fit*, *tabbed*, and later *scroll*, each horizontal or vertical (a vertical tabbed container has its tabs down the side). Each child's size lives on its link to the parent. **Each container remembers its last-focused child** in the layout value (supersedes ADR 11's "per-container focus memory is frame view state").
- **Frames.** A frame points at any part of the tree: a container, a view, or a node inside a buffer as shown by one view (a view plus a node, because one buffer can be shown in several views). The renderer starts at the frame's target. Moving the frame changes what you see, never the tree. Pointing it into a buffer is how Tuna narrows to a structural part (Emacs `org-narrow-to-subtree`); narrowing a plain text node to an arbitrary region stays the buffer's narrowing (ADR 6). The frame holds the selected view, which must lie under its target; when an edit removes it, the frame picks another under its target. Frame marks point at part identities, not paths, so they survive rearrangement; a mark whose part is gone reports that and is dropped. Several browser tabs, each with a frame, are allowed by the model and built later with per-tab input.
- **The layout contract** (replacing ADR 11's window contract) covers: the views in order; the selected view and selecting; splitting and deleting views; moving between neighbors; showing a buffer in a view; `display-buffer` with hints such as a side and size, which a layout plugin without sides interprets its own way; the frame's target, moving it, and frame marks; drawing from the frame; and the neutral saved form (*2026-10-14*, replacing the handover description: session slot `layout`, views by buffer name, node id and point, the selected view, frame marks; [ADR 5](0005-persistence.md)). Layout-specific commands belong to the layout plugin.
- **Buffers are truly replaceable.** The buffers contract covers creating nodes and buffers, editing, undo, the change journal, highlights, positions and their relocation, and node identity, kind, children, parent and revision. The default buffers plugin implements them. ~~Replacing the buffers provider hands buffers over instead of starting from a fresh `*scratch*`.~~ *2026-10-14:* replacing the buffers provider restarts it and its dependents, then restores plain-text buffers, their text and points from autosave; plugin-built buffers are rebuilt by their plugins; undo and other in-memory state are lost ([ADR 4](0004-state-ownership.md)).
- **Everything on screen is in the layout.** The minibuffer, echo area and help are buffers shown by ordinary views (a divergence from Emacs's minibuffer window). A view made only for one buffer (dedicated) closes when that buffer goes.
- **Drawing** stays immediate mode (owner decision 2026-10-13): each redraw sends the whole visible screen as one fat morph, never patches of single parts. A part's HTML is reused when its revision, its view state, and the display-wide inputs (faces, settings) are unchanged. So that drawing only what is in view can come later without changing contracts, any tree can hand the renderer a range of children.
- **Persistence.** The layout and frame marks are saved as plain data in a session slot. Buffers are never saved as trees: each plugin saves its own state and rebuilds its buffers on restart; file content belongs to texts and files.

## Pinning (owner decision, 2026-10-13)

Zooming must not hide things like the minibuffer, a VS Code-style button bar, or a persistent terminal. One rule covers them, with no special regions:

- **A pin is a flag on the link between a container and a child,** beside the child's size. It means "do not hide me when the frame zooms past me". It never moves anything: a pinned part stays exactly where it is in the tree, and unpinning just clears the flag. A part's position (move, split) and its pin are independent; the pin travels with the part when it moves, as its size does.
- **Drawing under zoom.** Walk from the frame's target up to the root. Each container on that path is given only the child the path runs through plus its pinned children, and draws them the way its kind always draws children: fit splits the space, tabbed shows a strip of just those tabs with the path child active, scroll (later) lays out a strip. The path child gets all the space the pinned children do not use; pinned children keep their sizes. With no zoom, pins make no difference. The same rule applies when the frame's target lies inside a pinned part.
- **Order** is tree order. Several pinned parts at the bottom are ordered by their position in the tree; rearrange them with the ordinary move commands. No priorities.
- **Locks.** A second flag marks a part owned by a plugin (the minibuffer, an explorer configured to always show): it cannot be unpinned or deleted by the user and goes away when its plugin is turned off. Pin and unpin are ordinary commands.
- **Sizes** on links may also be "as big as the content" (a one-line minibuffer), not only a share of the space.
- **Nearest minibuffer and echo area.** A question appears in the minibuffer view nearest the selected view (walking up from it, the first one reached); messages go to the nearest echo area the same way. One bar at the root serves everything; a pinned minibuffer inside one split serves that split. Several layout trees can show the same minibuffer buffer in their own views.
- **The selected view must be visible:** under the frame's target or in a visible pinned part. View-to-view movement visits only visible views.
- Sticky columns (staying in view while a strip scrolls) are a different feature, not pinning, and are not planned.

## Stage 3 additions (2026-10-13)

- **The minibuffer and echo area are two views** in the locked bar, from two independent plugins: messages stay visible while a question waits; the idle minibuffer takes no space, and the echo area keeps its line. A prompt is a buffer holding its question and answer; its view is selected while it waits and the previous selection returns afterwards. The minibuffer's separate focus views are gone (`current-view` is replaced by `selected-view`).
- **"Nearest"** walks up from the selected view and considers only parts pinned beside the path, never parts inside other branches, so a minibuffer pinned in one split does not catch questions from its sibling split.
- **Buffer settings** `no-other-view` (skipped by `C-x o` and the Shift-arrows) and `show-status-line` (off for bar views).
- **HTML reuse** keys a node's HTML on its revision, the view state, and display-wide settings; the first display-wide setting is `face-remapping` (Emacs `face-remapping-alist`).
- Help is the ordinary `*Help*` buffer from `help-buffer-plugin`, shown with `display-buffer`; `C-h q` closes it.

## Nested containers (2026-10-13)

- `C-x w t`, `C-x w 2` and `C-x w 3` wrap the selected part in a new tabbed, top-to-bottom or left-to-right container that takes the part's size and pin; `C-x w k` and `C-x w d` toggle the selected container's (or a selected view's container's) kind and direction, keeping children, sizes and focus memory. Wrapping and reshaping refuse a locked part, a part inside one, or a part holding one. Nested tabs: wrap in tabs, then `C-x t 2` inside.
- A container collapses into its only child only when a removal leaves it one; a one-child container made on purpose (by wrapping, or by a kind change) stays.
- The active tab always fills its group: its stored share is kept for when the group becomes a split again.

## Stage 2 additions (2026-10-13)

- **`C-x 1` moves the frame onto the selected view** instead of deleting the other views (`delete-other-windows`). Nothing is lost; `C-x n w` returns to the top. Frame marks and tabs keep their parts. Code ported from Emacs that wants one view either moves the frame or deletes views itself.
- **Commands that need only the layout contract** (split, delete, neighbors, frame movement, frame marks) live in the `view-commands` plugin and work under any layout plugin; commands that need the tree (tabs, one-level zoom) belong to the default layout plugin.
- **A side view wraps what the frame currently shows,** so it stays visible while zoomed.

## Consequences

- Porting maps Emacs *window* to Tuna *view* by renaming (`selected-window` → `selected-view`, `window-point` → `view-point`); side windows map to `display-buffer` side hints.
- A VS Code-style screen is assembled from ordinary buffers and containers.
- The renderer, minibuffer, echo area, help, session, and window commands change shape; the kernel does not.
- The old `windows` session slot is not migrated; a session saved before the change restores buffers but not their arrangement.
- Frames shared by several tabs may later disagree about container focus memory; settled with per-tab frames.

## Alternatives considered

- **Literally one stored tree** holding containers and buffer contents. Rejected: a buffer shown twice must be copied or awkwardly shared, hidden buffers have no place, swapping the layout plugin would hand over every buffer, and the two trees need different storage to stay fast.
- **A *pane* holding a view, or keeping *window*.** Rejected: today each window holds one view for life, so they are one concept; "window" is ambiguous in a browser.
- **Patching changed parts by id in the browser.** Rejected by the owner: the browser can drift out of sync with the server.
- **Frames fixed at the top of the layout (Emacs).** Rejected: the owner's design lets you stand at any level of the tree.
