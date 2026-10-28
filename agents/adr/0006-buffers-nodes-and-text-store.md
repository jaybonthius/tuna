# 6. Texts, buffers, and views; buffers are node trees; 1-based positions

Status: accepted (2026-10-11); amended after the [capability audit](../research/capability-audit/README.md) (text/buffer/view split, per-view point, selections, styled text, positions, overlays); amended 2026-10-13 by [ADR 13](0013-views-layout-and-frames.md): a view is a place in the layout (no separate window), the buffers contract covers editing, undo, the journal, highlights and node revisions, and the file link belongs to the text.

## Context

Tuna buffers must express rich UI (columns, lists, collapsible sections, search results) rather than only lines of text, while text editing keeps Emacs's keyboard-driven feel. Earlier attempts repeatedly mixed four concerns: the editor buffer, the private text data structure, per-view point and scrolling, and the rendered projection ([audit](../research/editor-corpus/prior-attempts-audit.md)). The last attempt specified a unified logical text view across many text sources in full detail before any of it ran, and did not finish.

Emacs separates more than it appears to: buffer text is shared by indirect buffers; point is per window for displayed buffers (`window-point`); strings carry text properties, so `buffer-substring`, the kill ring, completion candidates, and the mode line all exchange styled text. Real packages (Magit, Dired, Org, Vertico, Embark, flymake, avy) rely on all of this ([lanes 2 and 4](../research/capability-audit/README.md)).

Evidence on text storage is split: a mutable gap buffer had excellent local-edit latency but O(n) snapshots; Weevil's persistent rope had flat edit scaling and free snapshots at higher implementation complexity; a generic persistent SumTree was about 680× slower than the gap buffer on local edits. These numbers are from Racket.

## Decision

- **Three layers.**
  - A **text** holds content: a `TextStore` version, text properties, the change journal ([ADR 4](0004-state-ownership.md)), and undo history. One text can be shared by several buffers (Emacs indirect buffers).
  - A **buffer** is a named object owning a tree of nodes, buffer-local values, active modes, markers, overlays, narrowing, the mark, and a default point used when it is current but not displayed.
  - A **view** is a buffer as shown in one window: its selections, scroll position, per-node folding and focus state, and window-specific decorations. Point and scroll position of a displayed buffer belong to its view, as Emacs's `window-point` does. In the common case text, buffer, and view are one-to-one-to-one.
- **Node.** A node has a stable identity, a kind, attributes, and children. Node kinds are defined by plugins and rendered through the renderer service ([ADR 7](0007-rendering-and-transport.md)). Text that users edit, search, copy, or parse lives in **text nodes**; structure, chrome, tables, and widgets are **rich nodes**, which may provide a text projection so search and copy work across them. Most buffers (files, scratch, minibuffer) are a single text node and behave exactly like Emacs buffers.
- **Positions.** Buffer positions are **1-based**, counting characters, as in Emacs: positions are human-facing, and counting from 1 is the better design for them. The primitive position is a text node plus a position within it; a buffer defines a linear order over its text-bearing nodes so Emacs-style integer positions address the whole buffer. For single-text-node buffers the two coincide. Implementing the linear order across many nodes is deferred until the first multi-node buffer, but no API may assume a single node. `TextStore` implementations may index internally however they like; their indexing is never visible to package code.
- **Selections.** A view holds an ordered, non-empty list of selections (point plus optional mark), one primary. `point` and `mark` refer to the primary selection. Only the primary is used until multiple cursors are built.
- **Styled text.** A string with property intervals is the value exchanged by `buffer-substring`, `insert`, the kill ring, completion candidates, messages, and mode lines; plain-string variants exist.
- **Properties and overlays.** Text properties are stored with the text version (so snapshots include them) and follow stickiness rules. Overlays are mutable, buffer-owned, marker-bounded ranges with a priority and an optional view scope; they change the decoration revision, not the content revision. Rendering consumes *effective properties*: text properties merged with overlays, face remapping, and selection and cursor decorations.
- **`TextStore` service.** A `std/interface` covering length, slicing, line conversion, chunk iteration, and edit-returning-new-version. Implementations must be persistent (old versions stay valid). The default implementation is a persistent rope ported from Weevil's design; a gap buffer may be provided as an alternative that copies on snapshot. A text node's content provider may later be a range view onto another text (narrowed excerpts, editable search results).
- **Editor policy stays above the store.** Words, lines-as-commands, markers, undo, modes, and syntax live in the buffer layer, not in `TextStore`.
- **Markers** are buffer-owned positions with an insertion type, relocated by change records.

## Consequences

- Plain text editing can be built and used before any rich node kinds exist, without painting rich buffers into a corner.
- Two windows on one buffer have independent cursors; indirect buffers and multiple cursors need no redesign.
- Ported Emacs code keeps its position arithmetic.
- A persistent default makes job snapshots free ([ADR 3](0003-command-loop-and-jobs.md)) and makes a native undo tree possible later.
- Performance must be measured in Gerbil on the real edit-render path before the rope is considered final.

*Status note (2026-10-28, agent chat stage 2):* read-only text is a node attribute, not a text property: a node whose `read-only` attribute is true makes the text nodes under it read-only to editing commands (the buffers contract's `check-writable`, which `insert`, `delete-region` and undo call), as Emacs's `read-only` property does for characters. The plugin that owns the buffer still writes with `text-replace!`, as it does in a `buffer-read-only` buffer. Read-only character ranges inside one text are not supported; such text becomes its own text node.

## Alternatives considered

- **Everything is one text buffer with properties and overlays (Emacs).** Rejected: rich UI is the point of browser rendering.
- **Point on the buffer (first version of this ADR).** Rejected: no per-window cursors.
- **0-based positions (first version of this ADR).** Rejected by the owner.
- **Positions only as `(node, offset)` pairs.** Rejected: ports and users need plain integer positions across a buffer.
- **Gap buffer as the default.** Rejected as default because snapshots cost O(n) under the job model; kept as an allowed implementation.
