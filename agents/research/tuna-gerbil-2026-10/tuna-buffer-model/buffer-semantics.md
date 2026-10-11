# Research: Emacs semantics and structured-buffer minimum

## Summary
Emacs is useful here as a demonstrated ownership split, not a blueprint to clone: its indirect buffers share text and text properties while retaining per-buffer navigation, overlays, modes and locals; windows add view-local state on top. For Tuna, define the editor-facing identity/anchor/edit/history contract now, keep a mutable gap store opaque, and treat multi-leaf edits as one logical transaction. Defer Emacs-scale modes, display properties, indirect-buffer aliases and rich overlay behavior until a concrete command needs them.

## Findings

1. **Ownership matrix (recommendation informed by direct Emacs evidence).**

| State | Recommended Tuna owner | Emacs evidence / rationale |
|---|---|---|
| Structured nodes and child order | logical editor buffer; stable node identity | Inference for Tuna; Emacs has no equivalent content tree. |
| Text and text-attached properties | editable leaf’s opaque text resource; plain file = one leaf | `buffer_text` owns gap, properties and markers; indirect buffers point to same `buffer_text` (`buffer.h:237-304, 603-630`). Text properties are copied with text and shared by indirect buffers. |
| Position/anchors | leaf-scoped anchor; owner (buffer/view) determines lifetime | Emacs point and narrowing are per buffer, markers track edits, text storage is shared (`buffer.h:611-630`; manual [Indirect Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Indirect-Buffers.html)). |
| Overlays/decorations | buffer/view scope, not text; view-specific rendering may be derived | Emacs stores overlay tree on `struct buffer` (`buffer.h:718-719`); overlay mutation separate from text modification. |
| File path, encoding, saved baseline | logical buffer/file association, not leaf | `filename_`, `modtime`, `save_modiff`; indirect buffers do not independently visit/save shared text in same way (`buffer.h:329-350, 648-661`). |
| Modes, hooks, locals, syntax | initially buffer scope; extension point can later scope to subtree/leaf | Emacs has these on `struct buffer` (`buffer.h:359-390`); no need to reproduce now. |
| Undo history | logical command/history owner spanning touched leaves and structure | Emacs undo is text-oriented; Tuna must encompass structural edits too. |
| Point/selection/scroll/focus | view; command target is view’s active leaf | Emacs windows independently display buffers; current buffer is command context, not view identity ([Windows](https://www.gnu.org/software/emacs/manual/html_node/elisp/Windows.html), [Current Buffer](https://www.gnu.org/software/emacs/manual/html_node/elisp/Current-Buffer.html)). |

Several editable leaves mean buffer-wide offsets are inadequate: position = stable leaf identity + logical text offset. Structural position (node path) is not durable under move. Each view can focus a different leaf; command dispatch resolves against that view’s target, while explicit commands may target another leaf. Removing a leaf invalidates its anchors deterministically; fallback focus is nearest surviving editable leaf in document order (recommendation, owner choice).

2. **Text properties versus overlays (direct Emacs evidence; recommendation).** Text properties travel with/copy alongside character ranges and modifications participate in buffer modified/undo semantics; endpoint insertion inheritance is configurable. Emacs defaults to rear-sticky, not front-sticky; property changes can use `front-sticky`/`rear-nonsticky` ([Text Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Text-Properties.html), [Sticky Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Sticky-Properties.html)). Overlays are separate ranges, not copied with text; typically do not mark text dirty and are not undo-recorded, with priority resolving conflicts ([Overlays](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlays.html)). Recommend two distinct APIs/data categories: persistent text annotations travel with edited/copied text and enter undo; transient decorations/diagnostics are range anchors outside file content, do not dirty it, and may be discarded/recomputed. Do not import full Emacs priority/category surface initially.

3. **Exact recommended edit/anchor semantics (proposal, not Emacs compatibility).** Use logical Unicode scalar offsets, half-open ranges `[start,end)`, with newline policy fixed independently of store representation; UTF-8 byte offsets remain private. An edit replaces range with inserted text and emits a delta sufficient to map all anchors, properties, overlays, views and undo atomically. Anchor has explicit insertion affinity: `before` stays immediately before inserted text; `after` moves after it. At insertion exactly at anchor, this rule decides. For deletion/replacement, anchors strictly inside removed range collapse to replacement start (before affinity) or replacement end (after affinity); anchor at old end maps to new end; anchor at old start follows affinity. Thus zero-width insertion maps an anchor to either side, and replacing `[p,p)` is insertion. Point/mark are view-owned anchors; selection is derived from point+mark/activation. Narrowing is a view/buffer restriction, not truncation of text or save range. Boundary test table must cover both affinities at start/end, adjacent edits, deletion to empty, multi-leaf move/delete, and Unicode scalar boundaries. Emacs markers provide precedent for automatic relocation, but do not specify all these proposed rules ([Markers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overview-of-Markers.html)).

4. **History and file-state rules (recommendation).** Distinguish rollback (failed operation publishes nothing), user undo/redo (reversible logical command), and disk save baseline. One user command touching text, properties, structure and several leaves is one undo group; typing coalescing/IME grouping policy can be staged but group boundaries must exist now. Undo restores content/structure and relevant anchor state, not external side effects; redo reapplies. Save writes the buffer’s defined serialized content, then records a baseline; dirty means serialized content differs from that baseline, not “undo stack nonempty.” Save then edit then undo to baseline becomes clean; undo across save does not imply disk restoration. External file-change conflict check precedes overwrite. Emacs supports modified state relative to visit/save and file mtime checks ([Modification](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Modification.html), [Saving](https://www.gnu.org/software/emacs/manual/html_node/elisp/Saving-Buffers.html), [Undo](https://www.gnu.org/software/emacs/manual/html_node/elisp/Undo.html)).

## Capability inventory and behavioral tests

**Contract now:** opaque mutable text store (read range, splice, length/coordinate validation; no gaps/revisions exposed); leaf/node identity and lifecycle; atomic edit delta; anchor affinity/collapse; text-property versus overlay ownership; per-view point/focus; transaction/undo boundary; buffer serialized-save baseline; neutral node rendering contract (nodes render through contract; HTML implementation semantic elements, text escaped; sparse styling hooks/tokens). Minimal vocabulary: container, text leaf, semantic/control node only if needed. Plain file is a container with one text leaf. Avoid generic sequence framework and DOM-authoritative model.

**Tests:** (a) every anchor boundary rule including zero-width and Unicode; all views remap after edit; (b) copied/moved text properties travel, overlays do not; decorations never change dirty flag; (c) two views share one buffer text but retain point/scroll/focus; different focused leaves dispatch independently; (d) multi-leaf replacement + structural move is one undo/redo, failed transaction leaves no visible change; (e) save→edit→undo clean baseline, save→edit→undo-to-save then redo, external modification conflict; (f) deleting focused leaf repairs focus, deleting last leaf/container follows explicit policy; (g) renderer contract yields equivalent semantics for HTML now and permits non-HTML implementation; raw user text cannot become markup.

**Stage later:** full marker API/rings, narrowing UX, indirect buffers sharing text across identities, elaborate overlays/priority, mode inheritance/hooks/syntax/fontification, kill hooks/process lifecycle, file coding/recovery, redo retention budgets, terminal renderer implementation. Identity and anchor relocation must remain extensible for these.

## Material owner decisions (maximum four)
1. Whether multiple logical buffer identities may alias one text leaf (Emacs indirect-buffer semantics) or sharing is view-only initially.
2. Position unit/newline representation and anchor behavior; recommendation above is scalar + affinity table.
3. Dirty/save semantics for structured buffers: which leaves serialize, and whether transient/nonserializable nodes are excluded.
4. Deleting the last editable leaf / focused leaf fallback policy and whether an empty editable leaf is guaranteed.

## Contradictions
None found in checked Emacs sources. Emacs conventions are not automatically Tuna requirements; structural leaves have no direct Emacs analogue.

## Missing evidence
No performance/runtime evidence was gathered for several mutable leaf stores, cross-leaf anchor remapping, or terminal rendering. The supplied prior audit explicitly warns that prior benchmarks are architecture-specific; test Tuna’s full edit+history+projection path before representation conclusions. Current task does not establish persistence/recovery or browser composition behavior.

## Sources
- Kept: [Emacs Text Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Text-Properties.html) — copying, mutation, attachment.
- Kept: [Sticky Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Sticky-Properties.html) — insertion endpoints.
- Kept: [Overlays](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlays.html) — range metadata distinction.
- Kept: [Indirect Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Indirect-Buffers.html) — shared text/per-buffer state.
- Kept: [Markers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overview-of-Markers.html), [Narrowing](https://www.gnu.org/software/emacs/manual/html_node/elisp/Narrowing.html) — navigation/restriction.
- Kept: [Undo](https://www.gnu.org/software/emacs/manual/html_node/elisp/Undo.html), [Modification](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Modification.html), [Saving](https://www.gnu.org/software/emacs/manual/html_node/elisp/Saving-Buffers.html) — history and baseline.
- Kept: `/home/jay/Code/emacs/src/buffer.h` at requested checkout; directly read comments/fields `237-304`, `329-390`, `603-661`, `718-745`. Pinned online counterpart: https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/buffer.h
- Historical, not normative: `/home/jay/Code/workbench-racket/docs/tuna/research/prior-attempts-audit.md`; `research-gaps.md`.
- Deprioritized: broad Emacs API catalog and full display-property compatibility; beyond assigned seam and no need to freeze now.

## Next steps
Before public APIs, run the boundary/history tests above against a small reference model; benchmark multiple editable leaves only after semantics are fixed.

## Supervisor coordination
No decision needed; this is a proposal for the parent/owner.
