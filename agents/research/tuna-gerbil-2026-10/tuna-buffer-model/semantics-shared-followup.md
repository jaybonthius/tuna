# Shared editor semantics: follow-up

## Recommendation
Model one shared editor/workspace state, mirrored literally by every browser tab. Do not introduce view, session, indirect-buffer, or per-tab state identities. Keep only the identities needed to distinguish **logical structure** (stable node IDs, parent/child order) from **text resources** (opaque mutable storage) and **positions** (code-point offsets anchored to a text leaf). A node address is not a storage offset; a storage implementation must not escape the text-store seam.

### Ownership

| State | Minimal owner |
|---|---|
| Structured content tree and node IDs | Workspace/editor state |
| Text (opaque gap store), text properties | Editable text resource attached to text leaf; plain file = one leaf |
| Point, mark/selection, active leaf, narrowing/restriction | One shared editor navigation state; synchronized to every browser |
| Focus/command target | Shared editor state: active text leaf (or explicit non-text node); never browser-local |
| Overlays/decorations | Shared editor state, anchored to text positions or nodes; not serialized as file text |
| Undo/redo | Shared logical edit history, including structural and text/property changes |
| File association and saved baseline | Workspace/file state, computed from the chosen serialized representation |

This is intentionally simpler than Emacs. Emacs’s `buffer_text` groups text, text properties, markers and modification counters, while each `struct buffer` has point, narrowing, mark, modes/locals and overlays (`/home/jay/Code/emacs/src/buffer.h:237-304, 355-390, 603-630, 718-745`). Its indirect buffers share text but differ in navigation/local state ([manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Indirect-Buffers.html)); Tuna has no requirement to expose that model. Here every tab observes the same point/mark/focus/restriction. This is a product trade-off: one user’s movement/focus is immediately everyone’s, like one attached terminal session.

## Position and property behavior

Public positions are zero-based Unicode code points, represented as `(text-leaf-id, offset)`; ranges are half-open. Byte offsets/gap coordinates remain private. Structural moves preserve a leaf’s text anchors; deleting a leaf invalidates its positions and its associated transient decorations. A future richer model may add node-anchored positions, but does not need a generic sequence or public revision API now.

**Recommended text-property rules:** properties are attached to characters, not offsets or DOM nodes; copied/moved text carries its properties; properties are undoable and revisioned, but arbitrary properties do not by themselves make a plain-text file dirty. On insertion at a run boundary, default to **no inherited property**; allow explicit insertion-with-inheritance by the editing operation. This gives deterministic behavior without silently spreading styling/metadata. Emacs’s defaults are rear-sticky/not front-sticky, with `front-sticky`/`rear-nonsticky` controls; text-property changes are undoable ([Text Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Text-Properties.html), [Sticky Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Sticky-Properties.html)). Tuna may later add per-property stickiness without changing the base model.

**Recommended overlay rules:** overlays/decorations are separate shared ranges, not copied when text is copied; they relocate through edits by the same anchor mapping as positions. Each endpoint has explicit `before`/`after` insertion affinity; choose defaults by overlay class (diagnostic range: start-after/end-before to exclude boundary typing; active selection/caret: defined by editor command). Overlapping overlays resolve by explicit integer priority, then stable creation/order tie-break; do not depend on hash/map iteration. Overlays are revisioned and undoable only if a user command explicitly changes them; transient diagnostics may instead be recomputed. They never affect plain-file dirty state. Emacs similarly separates overlays from text properties; overlays are not text-copied and have priority ([Overlays](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlays.html)).

**Dirty vs undo:** history records logical edits (text, properties, overlay changes, and structural edits as applicable). “Dirty” means the file’s serialized bytes/content differ from its last successful save baseline—not merely that history has entries or a property changed. Thus property edits can be undoable/revisioned without dirtying plain text. If a future file format serializes selected metadata, those metadata become part of that serializer’s baseline. Autosave/recovery can be added later without requiring whole-workspace serialization now; per-resource or command-journal recovery remains possible.

## Contracts and behavior tests

**Define now:** leaf/node identity and deletion behavior; code-point position unit; anchor endpoint affinity and relocation; property-vs-overlay ownership; shared navigation/focus; atomic multi-leaf/structural command boundaries; renderer-neutral node contract; serialization boundary for dirty state. Keep HTML semantic and text escaped, with sparse style hooks/tokens. Rich properties/overlays are required for first usable editor, not a later phase.

**Test now:** (1) all tabs receive same point, mark, active leaf, narrowing and rendered state after any key/edit/focus event; (2) insertions at both ends of property runs, explicit inherit/non-inherit, copy/move and undo preserve expected properties; (3) overlay endpoint affinity at insertion, replacement/deletion collapse, overlap priority/tie determinism, property/overlay precedence; (4) a command spanning several leaves and structure is one undo/redo; failed commands publish nothing; (5) property-only or transient-overlay-only changes revise editor state but leave plain-file dirty false; text edit then undo to saved serialization becomes clean; (6) moving a leaf preserves its anchors; deleting it invalidates them and selects a deterministic surviving editable leaf; (7) renderer output from semantic nodes cannot treat user text as trusted markup.

Stage later: richer modes/hooks/syntax, narrowing command UX, per-property custom stickiness, diagnostic recomputation policy, recovery, indirect/shared-text buffer identities, multi-view state, alternative terminal renderer implementation. Preserve extension seams, but do not expose these hypothetical identities now.

## Consequential owner choices still open
1. Which semantic content is serialized by a save, and whether any initial structured node/property types serialize beyond text leaves.
2. Default insertion inheritance policy for each initial property class; recommendation is none unless command explicitly requests inheritance.
3. Exact shared-focus fallback when the active leaf/node is deleted or becomes noneditable, and whether the editor guarantees at least one editable leaf.
4. Overlay classes and their endpoint affinities/precedence against text properties; use explicit per-class policy rather than one universal rule.

## Sources / basis
- `/home/jay/Code/emacs/src/buffer.h` (pinned requested checkout): `buffer_text` ownership and `struct buffer` fields at ranges above.
- [GNU Emacs Text Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Text-Properties.html); [Sticky Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Sticky-Properties.html); [Overlays](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlays.html); [Indirect Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Indirect-Buffers.html).
- Historical context only: `/home/jay/Code/workbench-racket/docs/tuna/research/prior-attempts-audit.md` and `research-gaps.md`; neither overrides the owner decisions above.
- Fact/recommendation distinction: Emacs statements above are source-backed; proposed Tuna ownership and policies are recommendations, not requirements beyond owner decisions in the task. Performance of multiple leaves and richer precedence remains experiment-dependent.
