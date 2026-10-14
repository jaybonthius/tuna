# Layout outline: the screen's tree as a sidebar you can rearrange

**Status:** desired (owner idea, 2026-10-13), not scheduled. Needs mouse input and node keymaps first ([mouse input brief](../briefs/2026-10-mouse-input.md)).

A buffer that shows the layout itself as an outline: every container (with its kind and direction), every view (with its buffer), pins and locks, and where the frame points. It is an ordinary buffer in an ordinary view, usually pinned at a side, so it stays while you zoom; it toggles open and closed like any sidebar.

You rearrange the screen by rearranging the outline: drag a line onto another line, or before or after it, and the part moves there; the screen follows on the next redraw. Containers have no visible handle on screen (a split has nothing to grab), so the outline is where you grab them. The same lines answer keys too: move, wrap in tabs or a split, pin, zoom the frame onto a part, set a frame mark.

Why it fits Tuna: the layout is already one tree with stable part ids, every move is already a tree operation, and a drop in the outline is the same drop item as a drop on screen ("move part P to before/after/into part T"). The outline is just another view of state the server owns, so it can never disagree with the screen.
