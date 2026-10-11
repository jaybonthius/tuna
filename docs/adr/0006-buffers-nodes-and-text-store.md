# 6. Buffers are node trees; text lives behind a replaceable `TextStore`

Status: accepted (2026-10-11)

## Context

Tuna buffers must express rich UI (columns, lists, collapsible sections, search results) rather than only lines of text, while text editing keeps Emacs's keyboard-driven feel. Earlier attempts repeatedly mixed four concerns: the editor buffer, the private text data structure, per-view point and scrolling, and the rendered projection ([audit](../../research/editor-corpus/prior-attempts-audit.md)). The last attempt specified a unified logical text view across many text sources in full detail before any of it ran, and did not finish.

Evidence on text storage is split: a mutable gap buffer had excellent local-edit latency but O(n) snapshots; Weevil's persistent rope had flat edit scaling and free snapshots at higher implementation complexity; a generic persistent SumTree was about 680× slower than the gap buffer on local edits. These numbers are from Racket.

## Decision

- **Buffer.** A buffer is a named object owning a tree of nodes, a revision ([ADR 4](0004-state-ownership.md)), undo history, buffer-local values, and the active modes.
- **Node.** A node has a stable identity, a kind, attributes, and children. Node kinds are defined by plugins. The renderer for a kind is looked up through the active renderer service ([ADR 7](0007-rendering-and-transport.md)).
- **Text node.** A text node holds a `TextStore` value plus text properties. Most buffers (files, scratch, minibuffer) are a single text node, so they behave like Emacs buffers.
- **Focus.** A buffer's focus is a node plus, for a text node, a point. Motion and editing commands dispatch on the focused node's kind. Moving past the end of one text node into the next focusable node is a later, separate feature, designed once a second buffer kind needs it.
- **`TextStore` service.** A `std/interface` covering length, slicing, code-point/line conversion, chunk iteration, and edit-returning-new-version. Implementations must be persistent (old versions stay valid). The default implementation is a persistent rope ported from Weevil's design. A gap buffer may be provided as an alternative implementation that copies on snapshot.
- **Coordinates.** Public positions are zero-based Unicode code-point offsets. Byte offsets and internal chunking never leave the store.
- **Editor policy stays above the store.** Words, lines-as-commands, markers, undo, modes, and syntax live in the buffer layer, not in `TextStore`.
- **Markers** are buffer-owned positions relocated by each edit's change record.

## Consequences

- Plain text editing can be built and used before any rich node kinds exist, without painting rich buffers into a corner.
- Any text structure that satisfies the interface can replace the default, including ones written by users.
- A persistent default makes job snapshots free ([ADR 3](0003-command-loop-and-jobs.md)) and makes undo cheap to implement by retaining old versions where useful.
- Performance must be measured in Gerbil on the real edit-render path before the rope is considered final.

## Alternatives considered

- **Everything is one text buffer with properties and overlays (Emacs).** Rejected: rich UI is the point of browser rendering.
- **Gap buffer as the default.** Rejected as default because snapshots cost O(n) under the job model; kept as an allowed implementation.
- **Specifying a unified text view across all text nodes first (previous attempt).** Deferred until a concrete multi-node buffer exists.
