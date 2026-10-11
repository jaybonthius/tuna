# Tuna structured buffer model

Status: structured-buffer proposal for owner review; this document does not authorize its M0–M4 implementation. The owner separately authorized the [application-state plan](../tuna-app-state/spec.md)'s S0–S2 pipeline; S3 real-buffer participation remains conditional on genuine storage/model work. Research and clarification completed 2026-10-03. Current implementation reference: Tuna commit `bf7860533738e6c1e162c9ae019b53f5654287da`. This revision includes the complete proposed public operation inventory and the unified logical text-view model, with exactly one displayed structured buffer and no Tuna custom macros/live bindings in new buffer code. [Research findings](../../research/tuna-buffer-model-findings.md) and archived reports record the earlier investigation; broader orchestration/customization recommendations there are not requirements of this plan.

## 1. Goal and scope

Build the structured buffer that forms Tuna's content and interaction core. It owns semantic nodes, editable/read-only text contributions, navigation, annotations and compound history. A plain file is the one-editable-source case; richer content can include several text contributions and non-text semantic state. A derived logical text view gives the whole buffer coherent reading order, lines, search, movement, selection and copying without making one flat string authoritative or reconstructing content from HTML.

The completed implementation displays exactly one structured buffer in the existing page. Several text leaves or content groups inside that buffer are not separate views, windows or frames. Establish the application-state plan's S0–S2 pipeline first, then build the buffer with only enough hosting to display it and deliver input; integrate its real codec at S3 before claiming editing recovery. Do not build a generic UI shell, workspace, buffer manager, buffer list/switching commands, frames, windows, panes, splits or layout orchestration.

This plan covers the core's public API, behavior, private implementation, minimal integration and validation. It does not build application-specific screens or a widget catalog, a full mode/customization framework, Emacs compatibility or a terminal renderer. Milestones M0–M4 end at the single-buffer baseline; later facilities require separate scope.

### Owner-set constraints

- Implement and view one structured buffer only. No buffer orchestration, frames, windows, panes or generic UI shell.
- All browser tabs mirror that same buffer, including navigation and focus, like attaching to one tmux session. No independent per-tab state or browser-tab identity.
- Use ordinary native Gerbil for new buffer code, with `prelude: :gerbil/core`. Do not use Tuna's custom defining macros, macro replacement/advice/snapshots, live bindings/references or runtime advice. Leave existing customization machinery intact; it is not a prerequisite or work item.
- Start editable text storage with an opaque mutable gap buffer. Public operations expose no gap, capacity, byte coordinates or backing arrays; a rope or piece-tree replacement must preserve callers.
- Public text coordinates count Unicode code points from zero.
- Input follows Command Query Responsibility Segregation (CQRS): the browser sends intent, the server commits state, and the query stream carries server-rendered HTML. The first usable editor renders rich properties and overlays.
- No input or textarea elements and no browser-owned contenteditable document. Visible application text and selection are projections of server state.
- Ordinary printable keyboard input comes first. Full Input Method Editor (IME), dead-key and mobile-keyboard acquisition is deferred. The model must nevertheless accept arbitrary valid Unicode text through its text operations and a future committed-text input.
- Rendering is target-neutral at the model interface. The application selects HTML for now. Semantic HTML, a small token system and minimal styling hooks are required; Stellar is not.
- Existing source, toolchain and unrelated customization issues are not part of this proposal's mutation scope.

### Proposed choices, not additional owner decisions

Use one logical `buffer` owning semantic nodes, text sources, a derived logical text view, navigation and compound history. A `text-buffer` is an editable text-source implementation, not a miniature user-facing buffer; a read-only label needs neither its own gap nor its own point/history/file state. The existing runtime owns the one buffer reference and serializes commands. File association belongs to the editable source whose characters are saved, not a container or its text projection. One edit spanning several sources is one user action. Do not introduce indirect buffers, independent views, a generic sequence framework or a UI component catalog.

These names and module paths are recommendations. The owner has not accepted a final vocabulary or public interface yet.

## 2. Vocabulary and representation

| Proposed term | Meaning | What it is not |
|---|---|---|
| `buffer` | The single logical editing context owning a content-tree root, navigation, locals, revision and compound history. | Necessarily one file or one flat string; a workspace or buffer manager. |
| `node` | An identified value in the buffer's ordered content tree, with intrinsic fields, children and rendering behavior. | A DOM element or a storage chunk. |
| `group-node` | Ordered composition of children, optionally with target-neutral stack/row and semantic-section hints. | A window manager or an arbitrary CSS declaration. |
| `text-node` | A text-bearing node with a semantic role and an editable or read-only text source. | Necessarily an independent editing context or gap store. |
| `text-source` | An identified character contribution with properties and generations, backed by editable storage or a lightweight owned read-only value. | A user-facing buffer, independent point/history, or rendered DOM string. |
| `text-buffer` | An editable text source with opaque storage and optional file/coding state. | A mandatory allocation for every visible label or semantic node. |
| `text-view` | A derived, revision-bound sequence of source spans and declared logical boundaries, supporting whole-buffer text operations. | Another editable document, physical layout, or mandatory whole-buffer string copy. |
| `position` | A source identity/code-point offset or a declared structural-boundary location. | A durable flat view offset, child-index path, screen coordinate or byte address. |
| `anchor` | A live position with explicit relocation and insertion affinity. | A revision-bound numeric offset that remains correct without relocation. |
| `overlay` | Separately owned decoration of a text range or structural node. | Text, file bytes or trusted HTML. |
| `render-context` | Target-specific interpretation of node meaning. HTML is the first implementation. | Authoritative state or a second canonical UI tree. |

The initial concrete node kinds are group and text. Declared intrinsic fields include semantic `role`, owned `data`, text content/editability for text nodes, and `flow` for groups. `flow` is `inline`, `line` or `block` and defines logical text composition; stack/row is a separate optional rendering hint. Arbitrary HTML/CSS is not node data. Non-text values and ordinary behavior callbacks need not be disguised as text. No application-specific node kinds are required by this plan.

Meaningful text exposed for reading, navigation, search and copy must have a model-owned text contribution and source mapping. That contribution may be a lightweight read-only value or a read-only projection of semantic data, not a full text-buffer. Purely decorative output is not automatically searchable text. Rendering must not invent an independent text truth; accessible labels derive from the same content/semantic values.

Node and text-source identities are distinct. Moving a node preserves its sources and anchors; replacing a source updates its generation and maps anchors or explicitly detaches them. Each source has one declared owning contribution in this buffer. Point, mark and history belong to the buffer, not to every source. Multiple independently navigating buffers/views and shared-source aliases are outside this implementation.

## 3. Ownership and invariants

| State | Owner in the initial model |
|---|---|
| One buffer reference and serialized command execution | Existing runtime/application root; no buffer manager or second command lane |
| Root, child order, node identity and local structural generations | Logical buffer |
| Committed publication revision across attached models | Application update host; buffer does not maintain a competing commit clock |
| Editable characters, scalar length and private store/index | Editable text source |
| Read-only contributions, character properties and source generations | Owning source/node; no independent editing context |
| Logical flow, lines, source/boundary mapping and derived view indexes | Buffer text-view machinery; always derived |
| Point/mark, text/non-text focus, restrictions and logical scroll/projection range | Buffer navigation, shared by all browsers |
| Other markers/anchors | Buffer-owned collection keyed by source/boundary, with explicit lifetime |
| Range/node overlays | Logical buffer; endpoints refer to positions or node identity |
| Compound undo/redo groups | Logical buffer |
| File association, coding policy, disk fingerprint and saved-content checkpoint | Associated text-buffer; alias checks are local to the one buffer |
| Buffer locals and defaults | Logical buffer |
| Subtree overrides and text-specific syntax/settings | Node/text metadata interpreted through command context |
| HTML, source maps and rendered-output caches | Renderer/publication machinery; always derived |
| Transport queues and connection state | Runtime; not buffer state |

Required invariants:

1. Exactly one serialized owner mutates the one buffer. HTTP/stream threads never mutate its live state or text stores.
2. Its content tree is acyclic, ordered, and has unique live node identities and one parent per non-root node. No cross-buffer operations exist in this scope.
3. Text-bearing nodes expose live model-owned sources. Editable text mutations and read-only contribution refreshes use buffer operations, never borrowed arrays or an editable text-view/DOM copy.
4. Public strings, annotation reads and snapshots are detached from mutable implementation storage. No caller can alter live text or annotations by mutating a returned value.
5. Text offsets count Unicode code points; all text is valid Unicode scalar data. No normalization, newline conversion or storage encoding leaks implicitly through an edit.
6. One successful compound command publishes one coherent application revision; attached buffer/model candidates share the same private update kernel. Failure before commit publishes no text, structure, navigation, history or change notification.
7. Undo is not rollback. File saving is not undo. Coherent application checkpoints are not visited-file saves or runtime/workspace object dumps; initial per-buffer history is memory-only and restores empty.
8. Declared logical flow defines reading order and boundaries. Splitting/merging internal text pieces without changing that flow cannot change lines, movement, search or copied text. HTML layout cannot redefine them.
9. All browsers receive the same committed model revision, caret, selection and selected target. Physical OS focus and connection state remain local transport facts, not independent editor navigation.
10. Plain-file saving writes the associated text-buffer's characters according to its coding policy. It never flattens a rich content tree into a file accidentally.

An empty buffer tree is valid, as is a read-only tree. They have no editable point until an editable text target is created/selected. Do not manufacture an unnamed text-buffer solely to satisfy a hidden invariant.

## 4. Public seams and Gerbil conventions

New buffer, storage, history, file and rendering modules use `prelude: :gerbil/core`, normal imports, native definitions/structs/classes/methods and typed procedures. Do not import `:tuna/prelude`, `:tuna/macros`, `:tuna/macro-forms`, `:tuna/macro-registry` or `:tuna/bindings` into these modules, or depend on Tuna's hook system. Native Gerbil macro facilities remain available; do not invent another customization language.

Keep mutable representation records, constructors and setters private. All new procedures get the most specific parameter/result types the compiler can verify. Validate nonnegative bounds and identity/liveness at runtime where the type system cannot express them. Use `(:- expression Type)` for isolated assertions; use typed bindings when reused.

Public operations are behavior-facing procedures over opaque handles, not a collection of raw field accessors. Returning a detached read model is acceptable; returning internal mutable records is not. Private-module naming is an interface convention, not a security sandbox against trusted Gerbil extensions.

### 4.1 Public values, execution and results

The tables below are the complete proposed public operation inventory, including editing/file/HTML adapters and the node/rendering protocol. Names and behavioral signatures are proposed, not implemented bindings or accepted final exports. No operation is implied merely by an Emacs analogy. `call-with-*` names denote ordinary procedures, not custom macros. The pre-implementation audit in section 26 must settle the remaining contract decisions before these become fixed interfaces.

Notation: `b` is the one buffer; `n` is a node; `t` is a text source; `r` is a readable source, snapshot or logical text view; `p` is a position; `[s,e)` is a half-open code-point range; `fn` is an ordinary procedure. Mutations enter/join an atomic buffer update unless explicitly filesystem/lifetime operations. Mutating primitives return void unless a result is listed; creators return opaque handles. All live operations execute on the existing serialized owner; wrong-owner calls fail rather than secretly creating another scheduler. Detached values/snapshots may be consumed outside that owner.

Info/context/fragment/result values are detached owned data with documented fields, not exported mutable implementation records. Opaque handles and trusted procedure/extension references are not arbitrary object graphs promised to be frozen. Invalid bounds, kinds, liveness, ownership, read-only targets and stale mappings are explicit errors, not silent clamping. Expected file conflicts/refusals are structured outcomes. An error after commit identifies that state has committed; it is not a failed atomic update.

| Public value | Required fields/meaning |
|---|---|
| Buffer info | ID, label, liveness, revision/generation summary and logical modification state. |
| Node info | ID, parent, kind, role, flow/layout hints, owned semantic data, declared text-source IDs and liveness. |
| Text info | Source ID, owning node/contribution, source kind, editability/protection, code-point length, character/property generations and optional file association. |
| Position/anchor info | Source ID + code-point offset, or structural boundary ID/location; anchors additionally have affinity, lifetime and attached/detached state. |
| Context | Focused semantic node, active source, point, mark, selection direction/activation, effective restriction and shared projection range. No selected-buffer/workspace layer. |
| Node description | Group/text kind, role, owned data, declared flow/hints, text payload/editability where applicable, and child descriptions. Creation/replacement validates the whole description. |
| Edit | Target source, old `[start,end)`, replacement string/fragment, and explicit inheritance/trusted-protection policy. No physical splice coordinates. |
| Text fragment/copied selection | Characters, property runs, ordered source/boundary segments and source mapping. Ordinary clipboard output is its plain text. |
| View/line/match | Buffer identity/revision, logical offsets and mapped positions/spans; a line also names its semantic owner and terminator, a match its scope and source generations. No screen coordinates. |
| Change/update result | Host committed revision, affected source/node IDs, old/final ranges, structural/navigation changes and invalidations. Outer update status is committed/no-op with callback value; nested status is joined with base revision but no final revision/change claim, as in app-state section 6.4. |
| Overlay info | ID, source-range or node target, mapped endpoints, priority/order, metadata, point/expansion/evaporation and history policy. |
| History info | Undo/redo availability, group counts, retained payload/budget and over-budget status; no private inverse/journal records. |
| File/disposal result | Outcome, associated identities/path, conflict/refusal/error details and cleanup reports; never an implied multi-file atomic commit. |
| Rendered fragment | Target output plus source/boundary map and generation/revision tags. HTML output is escaped by its adapter. |

### 4.2 Lifetime, metadata and structure

| Public operations | Inputs/result and contract | Emacs analogy |
|---|---|---|
| `buffer-create` | `(label, initial: description?) -> buffer`; default empty group root. Initial content is construction state, not a user undo group. | Buffer creation, without buffer management. |
| `buffer-dispose!` | `(b, confirm: fn?) -> disposal result`; checks dirty file sources, detaches/releases owned resources; no next-buffer selection. | `kill-buffer`, lifetime only. |
| `buffer-info`, `node-info`, `text-info` | Handle -> corresponding detached info described above. | Partly buffer metadata/liveness/modification ticks. |
| `buffer-root` | `(b) -> root node`; an empty group is valid. | None. |
| `buffer-node`, `buffer-text` | `(b, ID) -> live node/source or #f`; content-local lookup, not a global registry. | None. |
| `node-children`, `node-text` | `(n) -> ordered children` / primary source or `#f`; node protocol, with no assumed text for a purely semantic node. | None. |
| `buffer-insert-group!` | `(b, parent, index, role:, flow:, data:, layout:) -> node`; flow defaults to block; fields are validated semantic values. | None. |
| `buffer-insert-text!` | `(b, parent, index, text, editable:, role:, properties:, data:) -> node`; editable sources use the private store, read-only sources may use lightweight values. | None. |
| `node-update!` | `(n, declared-field changes)`; includes role/flow/data/text/editability where valid. Preserves identity only for compatible updates; refreshes derived text atomically. | None. |
| `node-remove!`, `node-move!`, `node-copy!`, `node-replace!` | Remove; move/copy to `(parent,index)`; replace using a node description, including root replacement. Copy gets fresh identities and no live file association/overlays. | None. |

### 4.3 Source reads, editing, coordinates and anchors

| Public operations | Inputs/result and contract | Emacs analogy |
|---|---|---|
| `text-length`, `text-ref`, `text-slice` | `(r)` / `(r,offset)` / `(r,s,e)` -> code-point length, character, property-free string. View offsets address logical text; source offsets address source text. | `buffer-size`, `char-after`, `buffer-substring-no-properties`. |
| `text-fragment` | `(r,s,e) -> fragment`; properties and segmentation/source map accompany characters. | `buffer-substring`. |
| `text-snapshot` | `(r) -> stable detached readable snapshot`; creating it may require copying. | No exact counterpart. |
| `text-for-each-chunk` | `(r,s,e,fn)`; visits ordered detached character chunks with logical/source range information, never arrays/capacity. | No exact counterpart. |
| `text-insert!`, `text-delete!`, `text-replace!` | `(t,offset,text-or-fragment)` / `(t,s,e)` / `(t,s,e,replacement)`, with explicit inheritance/protection options. Only writable source storage is spliceable; no edits to a view/snapshot. | `insert`, `insert-and-inherit`, `delete-region`, replacement. |
| `buffer-edit!` | `(b, edits)`; old source coordinates, multi-source validation and one compound update. | Several edits in an atomic change group. |
| `text-offset->line-column`, `text-line-column->offset` | `(r,offset,unit:)` / `(r,line,column,unit:)`; unit is code point or UTF-16, defaults to code point. Reject invalid scalar boundaries. | Partial line-position analogy; not display columns. |
| `anchor-create`, `anchor-info` | `(b,p,affinity:,lifetime:) -> anchor` / anchor -> detached info. Default affinity is before; creation validates the position. | Marker creation/read operations. |
| `anchor-move!`, `anchor-detach!` | Move to a validated position, optionally updating affinity; detach explicitly. Detachment never redirects into unrelated content. | `set-marker`, marker insertion-type operations. |

### 4.4 Unified text view, navigation and editing helpers

These buffer-level operations are the normal interaction interface. Callers do not loop over text-buffers or guess separators. Source-local operations remain available for explicit programmatic editing/storage consumers.

| Public operations | Inputs/result and contract | Emacs analogy |
|---|---|---|
| `buffer-text-view` | `(b, scope:, restriction:) -> revision-bound logical text view`; a sequence/map, not another editable document or mandatory concatenated string. | The whole current buffer's textual surface. |
| `buffer-lines` | `(b or view, scope:) -> line iterator`; logical lines with semantic owner and mapped source spans, not separate source-local line lists. | Line-oriented buffer traversal. |
| `text-view-position`, `text-view-offset` | `(view,offset,affinity:) -> position` / `(view,p) -> logical offset`; validate revision and mapping. Flat offsets cannot become durable markers. | Position arithmetic, with structured source mapping. |
| `buffer-context` | `(b) -> detached context`; reads point/mark/selection/restriction/projection and semantic focus. | Collectively point, mark and region/bounds information. |
| `buffer-focus!`, `buffer-point!`, `buffer-mark!` | `(b,node)` / `(b,p)` / `(b,p or #f)`; validates navigation ownership; focus need not be a text node. | Partly `goto-char`, `set-mark`; node focus is new. |
| `buffer-selection!`, `buffer-deactivate-selection!` | `(b,start,end,direction:,active:)` / `(b)`; activation/direction distinct from normalized range. | Mark/region activation. |
| `call-with-buffer-context` | `(b,context-overrides,fn)`; temporary command target without changing canonical shared focus; unwind-safe restoration. | Partial `save-excursion` analogy. |
| `buffer-restrict!`, `buffer-widen!`, `call-with-buffer-restriction` | `(b,range-or-subtree)` / `(b)` / `(b,restriction,fn)`; anchored restriction and unwind-safe temporary restoration. | `narrow-to-region`, `widen`, `save-restriction`. |
| `buffer-projection-range!` | `(b,logical range)`; shared rendering range only, never a window/pane object or change to search scope. | No exact counterpart. |
| `buffer-move!`, `buffer-line-start!`, `buffer-line-end!` | `(b,count,unit:)` / `(b)` / `(b)`; units include grapheme, word, logical line and text-bearing leaf. Follow declared logical flow across source boundaries. | Motion commands, with different grapheme/leaf semantics. |
| `buffer-type!` | `(b,string)`; inserts at writable point/replaces active selection with typing inheritance/grouping. Named key strings are not text payloads. | Self-insertion/insertion commands. |
| `buffer-delete-forward!`, `buffer-delete-backward!`, `buffer-delete-selection!` | `(b,count:,unit:)` / same / `(b)`; map logical selection/motion to source edits, validate all protection first, retain structural nodes. | Character/backward/region deletion. |
| `buffer-copy`, `buffer-cut!`, `buffer-paste!` | `(b) -> copied selection` / `(b,expected-selection:) -> copied selection` / `(b,plain-string)`; copy follows logical flow, cut checks committed selection, paste is one operation. | Copy/kill/yank analogies; no kill ring. |
| `buffer-search` | `(b,query,scope:,direction:,start:) -> match iterator`; literal matching initially, spans may cross inline source pieces. Uses current restriction unless explicitly widened. | Buffer search; whole logical buffer, not per-source dispatch. |
| `buffer-replace-all!` | `(b,query,replacement,scope:) -> replacement report`; one group, protected matches skipped/reported; mapped matches may span compatible editable sources. | Replacement commands. |

### 4.5 Properties, overlays, local values and observation

| Public operations | Inputs/result and contract | Emacs analogy |
|---|---|---|
| `text-property`, `text-properties`, `text-property-boundary` | `(r,offset,key)` / `(r,offset)` / `(r,offset,direction:,key:,limit:)`; owned value/map or next boundary. | Text-property query/change-boundary functions. |
| `text-set-properties!`, `text-add-properties!`, `text-remove-properties!` | `(t,s,e,map)` / same / `(t,s,e,keys)`; replace/merge/remove source properties through an update. No view-local independent property truth. | Corresponding text-property mutations. |
| `overlay-create!`, `overlay-info`, `overlay-update!`, `overlay-delete!` | `(b,source-range-or-node,metadata,policies) -> overlay`; read/update/remove with explicit priority, point/expansion/evaporation/history policy. | Overlay operations; node decorations are new. |
| `buffer-overlays`, `buffer-decorations` | `(b,target-or-range) -> owned overlay infos/effective decoration spans`; includes mapped text properties and derived caret/selection. | `overlays-at`, `overlays-in`, `get-char-property`, partly. |
| `local-ref`, `local-set!`, `local-remove!`, `context-ref` | Read/set/remove `(buffer,node or source,key)` local values; `(context,key)` resolves ancestor/buffer defaults. Values are ordinary owned data/references, not live bindings. | Buffer-local values, extended with node ancestry. |
| `buffer-on-before-change!`, `buffer-off-before-change!` | `(b,fn) -> registration token` / `(b,token)`; ordinary candidate preparation callbacks, with documented veto/extension behavior. | `before-change-functions`, partly. |
| `buffer-on-change!`, `buffer-off-change!` | `(b,fn) -> token` / `(b,token)`; detached committed changes only; callback failure cannot undo commit. | `after-change-functions`, with structured changes. |

### 4.6 Updates, history and file adapters

| Public operations | Inputs/result and contract | Emacs analogy |
|---|---|---|
| `call-with-buffer-update` | `(b,fn) -> update result`; nested operations share candidate state, one commit/history group or complete precommit rollback. No filesystem rollback promise. | `atomic-change-group`, extended to structure. |
| `buffer-undo!`, `buffer-redo!`, `buffer-undo-boundary!` | `(b) -> whether a group ran` / same / `(b)`; semantic inverse/forward operations and explicit typing boundary. | Undo/redo/undo-boundary. |
| `buffer-history-info`, `buffer-history-limit!` | `(b) -> history info` / `(b,payload-bytes)`; trim complete oldest groups under the documented soft budget. | Undo information/limits, not exposed inverse storage. |
| `buffer-visit-file!` | `(b,path,target:,confirm:) -> file result`; install a prepared editable source in a designated node, no new logical buffer/switching. | File visiting/loading, partially. |
| `text-file-info`, `text-file-modified?` | Editable source -> owned association/coding/fingerprint/checkpoint info or tracked modified flag; no association is explicit. | File metadata and `buffer-modified-p`, scoped to source. |
| `text-save!`, `text-save-as!`, `text-revert!` | Source / `(source,path)` / `(source,confirm:) -> file result`; safe-write/conflict handling, whole source regardless of narrowing. | Save/write/revert operations. |
| `text-set-coding!`, `text-verify-saved!` | `(source,coding-policy)` / source -> clean comparison result; supported coding changes are undoable, explicit comparison may be linear. | Coding control; no exact saved-content verification counterpart. |

### 4.7 Rendering and protocol seams

| Public operations | Inputs/result and contract | Emacs analogy |
|---|---|---|
| `buffer-render`, `node-render` | `(b,context)` / `(node,context) -> rendered fragment`; read-only model interpretation, source mapping from the same logical text contract. | No public equivalent. |
| `make-html-render-context` | Theme/options -> HTML context; app selects this target initially. | None. |
| `render-context-text`, `render-context-group` | Context + semantic text/contribution or group role/flow/data/ordered fragments -> target fragment. No raw HTML model field or widget framework. | None. |
| `node-text-flow` | `(node) -> declared source/child/boundary contributions`; the buffer consumes this alongside `node-children` and `node-render`. Default group/text implementations suffice initially. | None. |

A semantic node may carry ordinary data or behavior while exposing only its meaningful text through the node protocol. Key resolution/activation uses those declared semantics and ordinary procedures; the core does not supply an application-specific action registry. Input POST/stream protocols, browser clipboard permissions, DOM hit-testing, subscriber queues and admission epochs remain adapter/runtime machinery, not extra buffer APIs. There are no public raw mutable record setters, physical-storage controls, buffer-list/switch commands, frame/window objects, custom-macro operations or live-binding operations.

Do not expose physical gaps, capacities, low-level reversal handles, normalized storage splices, allocation strategies or private annotation containers. Snapshot stability is guaranteed, but its creation cost is not a public constant-time promise. Adding a second production backend is not required to make the initial interface private.

Keep editing and rendering behavior behind small ordinary procedure interfaces rather than embedding it all in representation methods. Use ordinary procedure values for needed callbacks; they are captures, not live references. No live replacement, macro advice, transformer snapshots or hot class/schema migration is promised or tested by this plan. A future customization integration would require recompilation and explicit callback/reference review, not merely changing a prelude.

Existing input/runtime modules may retain their current Tuna prelude and live resolver machinery. Integrate through a narrow bridge that invokes ordinary buffer procedures; do not retrofit customization into the buffer or remove the existing machinery. The current worker invokes a callable returned by its resolver, so new buffer commands need not become live references.

## 5. Identity, lifecycle and structure

The buffer owns opaque node, text-source, structural-boundary and anchor identities. Its own identity and the runtime-instance discriminator distinguish stale transport input from current state. Identities are stable for their live lifetime, not derived from text content, child index, filename or DOM position; never reuse one for another resource within that lifetime. Application checkpoints retain durable model/kind/ID identities while allocating fresh live handles/run identity; the real buffer's allocator/reference codec must satisfy app-state sections 4/6.3/9 at S3. No cross-restart identity claim is made before that codec/recovery proof exists.

A buffer label is metadata, not identity. There is no global name namespace, collision allocator, buffer-name lookup or buffer switching. Navigation selects content within the one buffer; all browsers mirror that selection.

Structural operations validate the complete proposed tree before publication: ownership, unique parents/IDs, no cycle, valid text references, ordered children and intrinsic field constraints. A move preserves node/text identities and anchors. A copy allocates new identities and copies text/properties according to the text-fragment contract, but does not copy a live file association, disk fingerprint or saved checkpoint: the new text is an unassociated draft until explicit save-as. Replacing a node with a different semantic value creates a new identity unless the operation is an explicit compatible field update.

Removing a text-bearing node/subtree detaches anchors for its removed sources/boundaries and removes its transient overlays. It does not silently map them into unrelated text. Repair active focus by choosing the next eligible surviving text-node in the old logical order, otherwise the preceding one, otherwise the buffer root with no text point. If an active node becomes read-only, it may remain a navigation/search target; insertion is rejected rather than focus moving unexpectedly.

Undoable structural deletion retains the removed nodes/resources in its history record. Undo resurrects the same identities and captured anchor/navigation state, not new lookalikes. Dropping the retaining history group permits resource disposal. Disposing the whole buffer is a lifetime operation, not content undo.

Explicit disposal checks file-relevant modified resources and requires caller confirmation before discarding them; refusal leaves the buffer unchanged. Successful disposal detaches anchors, releases file associations and owned callbacks, and invalidates jobs/caches. Cleanup failures cannot resurrect half a buffer. It does not choose another buffer or build a close/switch UI; shutdown ends the single-buffer host.

## 6. Opaque text storage

The first editable-source implementation uses a mutable byte gap for encoded UTF-8 and a separate LF line-start index. Lightweight read-only contributions may retain owned strings/values behind the same read interface; they do not require independent gap storage or navigation/history/file state. The editable store also maintains total code-point length and enough private byte/code-point line information to convert public positions without decoding the whole file into an intermediate string. A decoder walks within the selected line; long-line checkpoints are private optional optimization, not an interface commitment.

Input strings are validated and copied into owned storage. Reject invalid scalar data; never repair it silently. Public length/ref/slice/edit operations use code-point offsets, and private translation resolves those to exact UTF-8 scalar boundaries. Browser UTF-16 offsets are handled only by explicit conversion/source-mapping procedures. User cursor motion uses Unicode grapheme boundaries; a code-point coordinate may legally identify a boundary inside a grapheme when a program explicitly requests it.

No implicit Unicode normalization. LF starts a new logical line; CRLF contains two code points in storage and is preserved. Lines/columns start at zero. A non-final line's logical length excludes LF; a column equal to that length names the boundary at its LF. A final line's equal-length column names EOF. CR contributes an ordinary code-point column, so `a\r\n` has line-0 columns 0/a, 1/CR, 2/LF, then line-1 column 0/EOF. Explicit UTF-16 conversion uses the same lines and rejects offsets inside a surrogate pair. User line-end/motion treats CRLF as one newline cluster. The HTML renderer may project it as one visual line break, but its source map must preserve the original source positions. Test CR alone, CRLF, LF, mixed endings, trailing newline and empty text.

Detached snapshots retain characters and property data after subsequent edits. Initially they are copied read models, not persistent roots. A range read copies only its range. Source/view chunk traversal supports rendering and reads without materializing a whole-buffer string; file serialization streams only the associated source. A revision-bound logical view is not a stable snapshot: use `text-snapshot` when retention across changes is needed. No stable snapshot retains mutable storage aliases.

The gap implementation prepares capacity, replacement bytes, inverse bytes, coordinate/index changes and result records before its irreversible mutation extent. It does not call configuration, renderers, callbacks or allocators while modifying live spans. Its failure atomicity is necessary but insufficient: the buffer owns multi-leaf rollback and user history above it.

Correctness is established against a small flat-string reference model and randomized edits. Do not port the old generic SumTree subsystem or claim old Racket benchmark results are Gerbil results.

## 7. Edit ranges, batches and no-ops

Ranges are half-open `[start,end)` against the pre-edit text. Validate `0 <= start <= end <= length`. Insert is replacement of an empty range; delete supplies empty replacement. Returned change information distinguishes old ranges, final ranges and inserted/deleted characters/properties without exposing byte storage.

A compound batch can name several text-buffers within one logical buffer. Every edit's coordinates address that text-buffer's old snapshot. Reject overlapping consumed ranges and insertions strictly inside a consumed range. Equal-position insertions preserve caller order. At a shared old boundary, final order is: a replacement ending there, insertions there in caller order, then a replacement beginning there. Prepare the normalized batch before applying private splices.

An operation whose final characters, properties, structure and other owned state are unchanged is a no-op: no history group or publication revision. Replacing characters with equal characters can still change properties, so byte equality alone is not a no-op test. A purely navigational change publishes navigation but does not create content undo.

Validate every target, restriction and read-only policy before applying any part. An invalid edit in leaf three must not leave edits in leaves one and two committed. Explicit commands may bypass user read-only restrictions only through a trusted operation policy; browser input can never supply that permission.

## 8. Positions, anchors and restrictions

A source position is `(source-id, code-point-offset)`. A structural text boundary has an identity/location in the owning node's declared flow, not a fabricated editable text-buffer. Point/mark and mapped matches may name either kind; revision-bound view offsets are converted through the view's mapping. A live anchor adds before/after affinity, owner/lifetime and liveness. Moving a node preserves its source anchors; deleting a source/boundary detaches its anchors rather than redirecting them into unrelated content.

For one replacement of `[s,e)` with `k` code points:

| Old anchor position | New position |
|---|---|
| `p < s` | `p` |
| Empty-range insertion, `p == s`, before affinity | `s` |
| Empty-range insertion, `p == s`, after affinity | `s + k` |
| Nonempty replacement, `p == s` or `s < p < e` | `s` for before affinity; `s + k` for after affinity |
| Nonempty replacement, `p == e` | `s + k` |
| `p > e` | `p + k - (e - s)` |

For simultaneous batches, compute one old-to-new map rather than repeatedly interpreting old offsets against mutated text. At a shared boundary, a before-affinity anchor sits after a replacement ending there but before boundary insertions and a replacement beginning there; after affinity sits after those insertions and that replacement. Example: replacing `[0,2)` with `X`, inserting `Y` at 2, and replacing `[2,4)` with `Z` maps an anchor at 2 to 1/before or 3/after in `XYZ`.

The relocation table above applies to source replacements, including refreshed read-only contributions. Structural-boundary anchors follow their identified flow location through compatible structural updates and detach when that location is removed. A pure structural boundary is not itself a writable character location; typing there needs an explicitly resolved writable source or fails without manufacturing text storage.

Point defaults to after affinity for typing; insertion commands put it after inserted text. Mark/annotation endpoints choose their own affinities. Keep one canonical buffer point/mark/selection, not an independent editing world or remembered point for every fragment. Semantic focus may be a group/non-text node while point names its text contribution. Selection direction/activation is separate from its normalized logical range.

Restrictions are anchored ranges and/or an explicitly selected subtree, not text truncation. Ordinary navigation/edit commands obey them; trusted commands can temporarily widen with unwind-safe restoration. File saving always serializes the whole associated text, not the restricted portion. Moving/deleting restriction endpoints follows anchor/lifetime rules. Narrowing and widening end typing amalgamation.

## 9. Logical text flow, lines, navigation, search and copy

`node-text-flow` supplies ordered source spans, child contributions and declared logical boundaries. Group/text implementations follow child order. A source span may be backed by an editable store, an owned read-only value or a declared read-only semantic projection; each has identity/generation and a mapping. Non-text semantic data is not automatically serialized into text. HTML, physical rows/columns and CSS cannot define canonical reading order.

| Group flow | Logical meaning |
|---|---|
| `inline` | Concatenate child text contributions with no inserted separator. Source segmentation adds no boundary. |
| `line` | Compose inline children and terminate their logical line. Supply a structural LF boundary only when the contribution does not already end in LF. |
| `block` | Separate child contributions with a structural LF boundary when the preceding child does not already end in LF. Preserve all source characters/newlines; do not trim deliberate empty lines. |

Structural LF boundaries are mapped model structure, not bytes stored in a hidden text-buffer. Logical line iteration follows the same LF semantics as source reads, including empty/trailing lines. A line record names its text spans, boundary/terminator and semantic owner. Editing a file's real newline is an ordinary source edit; deleting a structural separator cannot implicitly remove/join nodes. Navigation/copy can cross it, while explicit structural commands change the flow itself.

The text view is a derived revision-bound sequence and mapping, not a second authoritative string or editable document. Index/stream it without requiring whole-buffer concatenation. Its logical offsets are useful only with that revision; persistent anchors use source/boundary identities. Reads through an outdated view fail explicitly, while a detached snapshot remains readable. Identical logical content/properties/protection/flow must give identical ordinary text interaction regardless of internal text segmentation. Explicit leaf movement is structural navigation among declared text-bearing nodes, not movement among private storage chunks.

Whole-buffer search and movement consume this interface, not a loop whose semantics reset at each text source. Literal matches may cross adjacent inline source pieces; declared line/block boundaries prevent a query without a newline from accidentally joining unrelated logical lines. Explicit multiline queries follow the declared separators. Search includes meaningful read-only/folded text within the requested scope/restriction; exposing a hidden match is a separate navigation change. Matching returns mapped positions/spans and generation tags. Additional matcher kinds remain behind the same seam.

Grapheme/word/line movement follows logical text, including across inline source boundaries. Line-start/end use logical lines, not DOM wrapping or leaf endpoints. Focus identifies the semantic interaction target; editing still validates the mapped source(s). No source owns an independent point/mark/history. The exact word classifier and preferred-column behavior must be fixed in the section-26 audit, not left to storage/backend choices.

A selection is a directed logical range expanded to source and structural-boundary segments. Copy preserves that logical sequence and its declared separators, not a newline per leaf; internal fragments retain source/property segmentation, while OS clipboard output is plain text. Cut validates the copied committed selection before modifying anything. Paste inserts plain text into the resolved writable source as one operation; no structural paste is inferred from clipboard HTML.

Selection deletion edits mapped source characters only and retains nodes and their declared boundaries. Reject the whole direct edit if any selected source character is protected/read-only; purely structural boundary segments are preserved rather than treated as editable bytes. A character-deletion command at a structural-only boundary cannot remove/join structure. Tree-wide replacement similarly maps matches back to compatible writable sources and commits one compound group, reporting protected/noneditable-boundary matches as skipped. Ordinary text operations never invoke a semantic action or external process merely because a label changed.

## 10. Character properties

Keep a private sorted, nonoverlapping run collection per text source. Each run covers a code-point interval and maps property keys to values. Split/merge adjacent runs as needed; do not allocate a record per character. A simple run vector is the initial implementation; an interval tree remains private if measurements justify it.

Values are owned read data: scalar values, symbols, copied strings and recursively owned collections, plus explicitly registered immutable extension handles. Mutable application objects/callbacks use declared handles/policies rather than an untracked borrowed reference. Reads/copy return detached data. Do not promise arbitrary object graph freezing or recovery serialization.

Specify an initial property catalogue, with arbitrary extension keys retained without automatic rendering meaning:

- `face`: target-neutral named appearance, resolved by the renderer/theme; not CSS text.
- `read-only`: editing protection interpreted by buffer operations.
- `invisible`: source text remains present/searchable/copyable but has a declared hidden projection.
- `keymap` and `syntax`: ordinary local behavior values/procedures interpreted by command context, not Tuna live references or a new global registry.
- `field`: logical editing/navigation field metadata.
- Help/annotation references: handles to model text/semantic data, never raw HTML.

Set/remove properties over a range; query one key or effective property map; find run boundaries; copy a text fragment with properties. Property changes are undoable and advance property generation. They do not, by themselves, change a plain file's bytes or file-save baseline. Render/cache invalidation must still occur.

Typing resolves inheritance from neighboring logical characters across inline source pieces before preparing its source edit; physical segmentation must not reset that policy. Declared structural boundaries may establish an explicit field/inheritance boundary. Ordinary programmatic insertion/replacement of a plain string defaults to no inheritance; an explicitly source-local inheritance request uses that source's neighbors. Property-bearing fragments carry their explicit properties. For inherited insertion, interior-run values come from the preceding character, subject to declared stickiness. At a boundary, use explicit per-property front/rear stickiness: default rear-sticky and not front-sticky, with declared overrides. If both sides offer different sticky values, the preceding character's eligible rear-sticky value wins; otherwise use the following character's eligible front-sticky value. This follows the documented Emacs inheritance precedence without claiming complete compatibility. Protection at an insertion boundary is evaluated from the prospective inherited read-only value before mutation.

Deleting removes properties with their characters. Replacing with a plain string applies the specified insertion policy; it does not accidentally preserve deleted properties. Copy/move/yank retain chosen property data. A character-only slice and a property-bearing fragment are distinct reads. Plain OS clipboard excludes properties.

Full Emacs `display` substitutions, categories and arbitrary property-specific hooks are not initial compatibility promises. Semantic replacement content should ordinarily be an explicit structured node; any future property-driven replacement must define source/display mapping and copying behavior before admission.

## 11. Overlays and structural decorations

Overlays are separate buffer-owned objects with an identity, target, endpoint anchors (for ranges), priority, creation order, appearance/behavior metadata and an evaporation policy. Structural decorations target node identity. They never contain trusted HTML or hidden editable character storage.

Default diagnostic range endpoints are start-after/end-before, excluding text inserted exactly outside its boundaries. An expanding annotation can explicitly select start-before/end-after. Remove an evaporating overlay when all its covered source disappears; removing its target node always removes it.

Overlay relocation layers a range policy above independent anchor mapping. For a nonempty, non-evaporating overlay, map endpoints first; if they cross, collapse both to the smaller mapped position, never swap them into a fabricated range covering replacement text. For example, `[1,2)` with start-after/end-before, after replacing `[0,3)` with two code points, maps to `(2,0)` and therefore collapses to `[0,0)`. If the mapped endpoints are equal, the result is likewise a zero-width overlay.

A zero-width overlay uses one point anchor with an explicit affinity (default before), so both endpoints move together on subsequent edits regardless of their old range affinities. Its class may instead declare expansion on insertion; that policy maps the coincident start-before/end-after endpoints into the inserted range. Opposed affinities never make a point overlay negative-width. Record the class's point/expansion policy with the overlay and test transitions from nonempty to empty and back.

Priority is an explicit integer; higher wins for conflicting values. Equal priorities use stable creation order, not hash iteration. Effective display combines character properties with overlays; overlays override conflicting display keys, with per-face attributes merged by the same priority rule. Editing protection is evaluated from model policy/properties, not a cosmetic overlay or HTML attribute.

Caret and active selection are derived navigation decorations, not character properties. Parser diagnostics/search highlights are transient overlays and normally excluded from history. A user-created persistent annotation may participate in history if the creating command declares that policy. Overlay changes advance decoration generation and render revision but never dirty a plain file merely because they are displayed.

Copied text does not copy overlays. A meaningful overlay label uses a mapped read-only text contribution or derived accessible description, not a mandatory full text-buffer or parallel authoritative UI string store. Window-specific overlays and independent-view decorations are later facilities.

## 12. Locals, syntax and command context

Commands receive the buffer and the relevant focused node, text target, point/selection and restriction. Temporary operations on another leaf do not implicitly move visible focus; restore temporary context on exceptions/nonlocal exits. There is no selected-buffer or workspace context layer.

Resolve text/node overrides through ancestors to buffer defaults using plain maps and procedures. Text-specific syntax/coding belongs on the text-buffer; structural behavior belongs on the node. Do not depend on `defsetting`, `defhook`, `defcommand`, contextual specialization or the broader customization roadmap.

Implement standard text commands and read-only/generated-text behavior over the buffer's logical text interface. A small ordinary binding map is sufficient; semantic focus/data can select ordinary actions without encoding every interaction in text properties. Command discovery, a generic extensible keymap framework and major/minor-mode lifecycle are later work. Word/grapheme motion and syntax-sensitive operations consume the logical view/source read interfaces, not gap pointers. Future parser/diagnostic results must name their source generation and be rejected when stale; language packages are not part of this baseline.

Where callbacks are needed, use plain procedure arguments or buffer-owned collections, not Tuna hooks/live references. Before-change callbacks run against a prepared candidate and may veto/extend it without observing half-mutated text. After-change callbacks receive committed detached changes; failures cannot undo a commit. Reentrant edits enqueue a later command rather than recursively mutating published state. Do not build a general callback/customization framework.

## 13. Transactions and publication

The [application-state host](../tuna-app-state/spec.md#7-update-composition-with-the-buffer) supplies the common private update kernel. An attached buffer operation joins/opens that host while limiting semantic scope to this buffer; standalone buffer tests use the same kernel with one participant, not a parallel transaction engine. Nested operations see candidate state and return joined results without a final-revision claim; nested failure poisons the outer update even if caught. One undoable update may touch every leaf/structure; a common application update may also change another registered model atomically. No workspace framework, application-global undo or cross-buffer commands are introduced.

The update state machine is `preparing -> applying -> committed` or `cancelled`. Prepare and validate all new text, property runs, node changes, navigation/anchor mappings, inverse records, capacity and journal slots first. Configuration callbacks execute only in safe preparation/observation phases, not during low-level mutation or rollback.

During apply, publish each successfully applied private reversal into a preallocated journal slot. A precommit exception, cooperative cancellation, continuation escape or failed validation reverses populated slots newest-first and discards candidate metadata/history. Rollback uses prepared inverses without fresh coordinate validation/capacity allocation and invokes no extension callbacks. Continuation re-entry into committed/cancelled updates is rejected.

Prove the installed Gerbil mechanism for continuation-safe unwind cleanup and cooperative cancellation in focused tests before exposing updates; use native errors, not asynchronous interrupt injection/recovery machinery. The behavioral contract is mandatory; do not guess that `try/finally` alone handles every continuation/break case. Orderly shutdown stops admission and cancels/drains at command boundaries; do not terminate the mutating worker midway through a transaction as the normal shutdown path.

The shared host commit installs candidate metadata, completes live-store state, records this buffer's history and advances affected local generations plus one application revision in a callback-free extent. Buffer publication follows that commit; do not wrap an independently committed buffer update in an app transaction. Durable generation advances only for changed exported meaning, not transient overlays or render/checkpoint status. Reads requiring live resources execute on the owner; stream threads receive rendered output/detached data only. A failure after commit, including a render/send/after-change callback failure, cannot reverse the command. Mark the renderer stale/report the failure and permit a fresh full projection.

User code remains trusted; an external filesystem/process effect cannot be rolled back by the buffer journal. Such effects belong to explicit file/domain commands with their own success/conflict reporting.

## 14. Revisions and change data

Use the application's one monotonic publication revision when attached, with local resource generations for character, property, structure, decoration and navigation changes; standalone tests use the same single-participant host clock. Undo commits a new application revision; it does not reset revision numbers to an old value. Generations distinguish stale parser/render/position-sensitive results without requiring every public text read to carry a storage-specific revision object.

A committed change records affected logical buffer/text/node identities, old/final text ranges, character/property changes, structure changes, navigation repair, and invalidation categories. Observers receive detached data. Pure no-ops produce no change. Character-identical property updates still publish property/render changes. Failed updates never leak candidate changes.

The existing keydown input envelope stays key intent: ordinary key commands operate on the current shared target at execution time, like terminal input. Do not reject rapid typing merely because several queued keys were captured before a newer HTML revision reached the browser. Pointer/selection/range commands, by contrast, name the rendered node/text generation used to calculate their positions; reject/resynchronize stale mappings rather than editing the wrong text. Cut validates the exact committed selection it copied.

## 15. Undo, redo and modification state

A history group captures semantic forward/inverse text fragments, property changes, structural changes and the navigation state needed to make undo comprehensible. It never stores HTML or physical gap addresses. One tree-wide replace, paste, structural move/delete or explicitly grouped command is one group. Undo/redo operate on the one buffer's shared history.

Consecutive ordinary insertions, or consecutive backward deletions, in the same text target with compatible context may amalgamate until a non-typing command. Navigation, selection changes, leaf changes, paste, save, property/structural commands and explicit boundaries close the group. Start without timing heuristics. A future IME commit is one explicit group. New content editing after undo discards the redo branch; read-only navigation does not.

Undo restores the changed content/properties/structure and captured relevant navigation, then maps unrelated current anchors through the inverse edit. Redo performs the forward semantic operation without replaying filesystem/process effects or arbitrary extension callbacks. The last observed disk fingerprint and saved checkpoint do not rewind with content undo: undoing a revert restores old text against the current disk baseline and may therefore make the resource file-modified. Transient diagnostics are invalidated/recomputed rather than blindly restored as user content. History retention keeps deleted resources alive only while needed.

Distinguish logical modification from file-save modification. Text/properties/structure can be logically modified and undoable while a plain file's character bytes remain unchanged. A file-relevant edit marks its associated text-buffer potentially modified; successful save establishes a content/coding checkpoint, and undo to that checkpoint clears the file-modified state. Unrelated properties/overlays cannot make it file-modified.

Like conventional editor modification tracking, the initial file-modified flag may be conservative when a sequence of manually typed edits happens to reproduce the saved bytes. An explicit streaming equality check can prove it clean; do not scan/serialize every file after every keystroke merely to detect that case. Exact content comparison and cheap modification tracking are different operations. An identical final edit is already a no-op under section 7.

Retention uses a configurable per-buffer payload budget and trims oldest complete groups, never half a compound command. A proposed initial soft budget is 64 MiB of retained text/owned annotation/node payload per buffer, measured with a documented estimator; validate it against actual Gerbil memory before selecting a release default. Preserve the newest group even if it alone exceeds the soft budget and report that condition. Per-buffer history persistence is excluded initially. Application recovery at S3 restores declared durable content/navigation into fresh resources with empty undo/redo histories.

## 16. File identity, visit, save and revert

Associate a file with the text-buffer whose characters represent it. A plain-file buffer contains exactly that leaf. The one structured buffer may also contain generated text, drafts or several file-backed leaves; there is no generic rich-tree serializer. Save the active association; an explicit operation on several contained associations reports per-file outcomes. Never concatenate UI labels into a file or pretend several file replacements are one atomic disk transaction.

Canonical file identity is separate from display path and logical identities. Resolve aliases among this buffer's file-backed leaves and reuse an existing text resource rather than create competing editable copies. Track canonical path plus observed filesystem identity and refresh those local associations after saves/reverts. No global file/buffer registry or cache of other logical buffers is needed. Generated/draft text has no file association until explicit save-as.

The initial coding implementation is valid UTF-8 with optional byte-order mark (BOM); preserve BOM choice and LF/CRLF/CR/mixed bytes rather than normalize silently. Reject unsupported/invalid encodings without creating a partially decoded buffer or overwriting the original. Additional codecs and binary/literal visiting use an explicit file-adapter seam; they are not falsely advertised as implemented. Encoding changes are file-relevant, undoable metadata; plain text properties are not.

Visit reads and validates into a prepared store, captures file metadata/fingerprint, and installs it at an explicitly designated node in the one buffer. Replacing modified text requires explicit confirmation. It does not create/switch another logical buffer or build a file-picker/workspace UI. Synchronous owner-thread file operations are acceptable initially; they may delay commands. A later background loader must publish only if the requested identity/generation still matches.

Save performs any explicitly supplied before-save transformation callback as an ordinary reversible buffer edit, serializes all associated source text regardless of narrowing, and prepares a same-directory temporary file. Check the observed disk fingerprint before replacement; on mismatch return an explicit conflict and do not overwrite automatically. Use size/mtime plus a content fingerprint when necessary; document that an external process can still race a check because ordinary filesystems do not provide a general compare-and-swap save.

Preserve permissions and the intended symlink target. Atomic replacement may change inode and break hard-link relationships; detect a multiply linked target and reject the default replacement strategy with an explicit explanation until a deliberate preserving/overwrite strategy is chosen. Do not silently change that filesystem behavior. Validate cleanup/error behavior for write, flush, replacement and permission failures.

Only successful file replacement records the saved checkpoint/fingerprint and clears file-modified state. Save errors leave content/history intact and expose an actionable result. Saving/undo never claims to undo disk writes. Revert loads a prepared replacement, remaps/repairs anchors and refreshes baseline; refuse to discard modified content without explicit confirmation. Initially make an explicit revert undoable in the logical-buffer history, but do not claim undo restores disk state.

Text-resource disposal and save-as update this buffer's file associations consistently. Backups, lockfiles, externally visible file renames and multiple-process coordination are separate facilities, not side effects of changing a filename string in a text leaf.

## 17. Coherent application checkpoints and buffer recovery

The separately authorized [application-state plan](../tuna-app-state/spec.md) supersedes the earlier assumption that recovery must wait until after this baseline or use independent per-source autosaves. S0–S2 proves the application/checkpoint mechanism with test-only concrete models before genuine buffer implementation. Once storage/model milestones exist, S3 attaches the real buffer/codec to the common host and captures unsaved authored content with durable navigation, annotations, mode choices and file/coding/saved-baseline metadata in one coherent checkpoint. Do not claim content recovery from identities/file references alone or ship a fake buffer to pass S3.

Valid compatible checkpoints auto-restore before input admission. Invalid/incompatible data is preserved and blocks replacement; no implicit empty-buffer fallback. Restoring never writes visited files, marks unsaved text file-clean or restores undo history. Allocate fresh live resources/run identity, preserve durable identities/references, recreate caches and start per-buffer undo/redo empty. File conflicts/unavailable behavior definitions follow the explicit codec policy, not silent clamping or executable file-supplied code. The real buffer codec must pass its complete durable-field audit and app-state acceptance matrix; while that integration is absent, advertise the missing editing recovery honestly. File saving and per-buffer memory history remain separate; no session/windows/layout or object-dump framework is added.

## 18. Target-neutral rendering

Nodes expose `node-children`, `node-text-flow` and `node-render`. The text-flow declaration feeds whole-buffer interaction; rendering interprets the same semantic roles/data/contributions rather than defining a separate textual document. Each initial rendering method asks the context to emit semantic text/composition rather than building HTML. The app constructs an HTML context unconditionally for now; no user-facing target switch or terminal implementation is needed.

The context provides only the semantic operations required by the initial nodes. It owns element selection, escaping, source mapping, theme lookup and output construction. Do not create a generic browser widget interface in anticipation of every UI. An extension node implements the same traversal/rendering contracts; target-specific extensions register with the target adapter rather than inserting HTML fields into model values.

Use one authoritative content tree. A transient renderer output tree/string is an interpretation, not a second editable UI model. Rendering is read-only and must not mutate buffer state, lazily create live text resources, run untracked filesystem effects or invoke writable callbacks. Cache by relevant generations and renderer/theme version; cache invalidation never changes source text.

A test-only non-HTML recording context must render the same ordering, text and structural meanings without receiving HTML tags/classes. This proves the seam; it is not a production second renderer. Unknown node/target combinations return an explicit unsupported-rendering result, not unsafe raw markup.

## 19. HTML, source maps and design tokens

Choose elements for meaning: headings with coherent levels, sections only for genuinely sectioned content, lists for lists, preformatted text for indentation-sensitive files/output, and `code` only when the text is code. Links navigate; buttons perform actions if/when such nodes are introduced. Groups with only layout meaning need not masquerade as semantic sections.

The interactive HTML-only text surface is focusable and named. Because native inputs are ruled out, minimal ARIA may be necessary to describe its actual editor behavior; do not assume adding a textbox role alone establishes accessibility. Validate keyboard operation, selection announcements and screen-reader behavior. Render caret/selection from committed state, avoid announcing every full buffer as a live region, and use a small semantic status region for outcomes.

Assign stable DOM IDs from opaque node identities, not text content or offsets. IDs are morph/source-map identities, not CSS hooks. Each meaningful displayed text run has an explicit mapping from its DOM range/UTF-16 positions to source or structural-boundary positions in the logical text view. Properties/overlays split runs only where necessary; avoid a span per character. Hidden text, CRLF normalization, grapheme clusters, control-character visualization and decorations cannot be handled by blindly counting `textContent`.

Escape user/file/clipboard text and attribute values through the HTML adapter. Valid source characters that HTML cannot represent faithfully, such as NUL, get an explicit visual representation with correct source mapping. Trusted extensions may register an HTML renderer, but ordinary property values and buffer text never become markup. Do not add a generic raw-HTML buffer constructor.

Use semantic selectors, native states and narrowly named data attributes first. A CSS-only custom layout tag is permissible only where it earns a clearer styling contract; it must contain native semantic children and provide no claimed intrinsic role. No shadow DOM, slot convention or custom-element JavaScript is needed for the initial groups. Do not replace every node with a new HTML tag just to eliminate classes. A small necessary grouping wrapper is better than false semantics.

Centralize raw design values in a small theme/token definition: surface/foreground/muted/selection/focus/diagnostic colors; font families/sizes/line heights; spacing steps; borders; reading measure and control targets when controls exist. Component rules reference these named CSS custom properties, not scattered colors/pixel values. Structural constants such as `0`, `auto`, `1fr` or full width are not design-token proliferation opportunities. No Stellar dependency or token-generation framework.

Keep selector specificity low, nesting shallow and source order meaningful. Use logical CSS properties and intrinsic Grid/Flex layout; do not CSS-reorder interactive content away from traversal order. Preserve focus visibility, readable contrast, zoom/reflow and reduced-motion preferences. Native emphasis/mark semantics apply only when meaningful; purely visual faces use minimal token-backed styling hooks, not misleading semantic tags.

## 20. Input, clipboard and stale interactions

Extend the existing TypeScript transport rather than introduce a second queue/framework. Every delivered key still reaches the server; key events never mutate authoritative text or construct application HTML locally. Resolve bindings first, then use a standard-text-mode fallback for verified ordinary printable key values. Never insert named control keys, `Dead`, `Process`, `Unidentified` or composing events as strings. Include modifier/AltGraph distinctions needed by tested layouts. Reserved OS/browser shortcuts that never reach the page remain outside Tuna's capture guarantee.

Provide explicit plain-text paste/insert payloads in addition to key intent. Preserve the model's arbitrary-Unicode committed-text interface for a later composition bridge, but do not infer IME text from `keydown.isComposing`. The first usable release explicitly excludes full IME, dead-key and mobile text acquisition.

Clipboard copy/cut uses the latest committed server selection, including offscreen source ranges, not a browser-created editable document. The browser may hold a detached clipboard projection/source map from a published revision; it is not application-authoritative state. Validate selection identity/revision before cut deletes anything. Plain-text paste ingests clipboard text in a real user-gesture event and sends it to the server; never ingest clipboard HTML as trusted structure.

The current blanket noncomposing `preventDefault` must be refined so clipboard gestures can produce their required events without enabling native DOM editing or duplicate insertion. Prove keyboard and context-menu clipboard paths on the actual noneditable surface. If an event path is unavailable, report the limitation; do not smuggle in a hidden textarea as a fallback.

Pointer selection maps browser hit-testing through the server-generated source/boundary map. Send node/source or structural-boundary identity, relevant generation/revision, offsets and selection intent; the server validates and publishes shared navigation. Browser-native ranges may be transient hit-testing/output machinery, but cannot become the canonical selection. No optimistic local application text/caret is required; server latency is observable and must be measured rather than hidden with a second editor state.

Initially preserve admission-only 204 semantics and no automatic retries. A network failure can have an unknown command outcome; pause input rather than blindly replay possibly executed keystrokes. A current HTML revision alone is not proof that a delayed request has finished or cannot execute later.

Use a minimal shared admission epoch and owner-ordered resynchronization fence, not independent tab sessions:

1. Normal input envelopes name the runtime instance and current admission epoch. Under the existing admission mutex, validate that epoch/readiness and enqueue atomically with respect to resynchronization. Preserve acknowledgement-before-enqueue ordering within that mutex.
2. On uncertainty, the browser pauses its input queue and requests resynchronization. Under the admission mutex, disable normal admission, advance the global epoch, and enqueue a fence after every already-admitted intent. Requests arriving late with the old epoch are rejected and cannot mutate state.
3. The single owner finishes/cancels all earlier admitted intents, then processes the fence. While it is pending, repeated resynchronization requests share that fence rather than creating independent client state.
4. Publish a fresh projection carrying the new epoch and explicit completed-fence marker; retain that marker in later projections of the epoch so coalescing cannot hide it. Re-enable normal admission only when the fence is complete and its projection is available. A failed fence/render leaves input paused until a successful completion projection is available.
5. Browsers discard unsent old-epoch intent rather than automatically replay it, report that loss/uncertainty, and resume only after receiving the completed-fence projection. The fence establishes that all old-epoch input either ran before it or can no longer be admitted afterward.

The epoch is transient shared transport state, not a browser identity or persistent command journal. This does not promise exactly-once reconnect/replay or persistent deduplication; those remain later protocol work.

## 21. Stream integration and runtime boundaries

Keep command POST responses bodyless. After commit, render a coherent shared projection and notify the GET stream subscribers. An initial/reconnected subscriber receives the current projection, not just an empty body and not a replayed input queue.

Use per-subscriber bounded/latest-publication notification, never one competing-consumer state channel. Streams can skip superseded full projections and must converge on the newest revision. Do not drop typed input as a rendering-coalescing shortcut. Subscriber failure removes that subscription without stopping the buffer's command owner; rendering failure preserves committed state and allows a fresh attempt.

Start with one broad stable buffer-region patch. Keep the existing page wrapper and input transport attachment, adding only the host wiring needed for the one buffer; do not build a generic UI shell, frames or windows. Verify actual Datastar 1.0.2 behavior for node identity, focus, source-map replacement and event bindings. Use no newer attribute behavior without checking the embedded asset. Incremental patches/visible-range projection are optimizations behind the same model/render interface, not a second canonical DOM state.

Initially full projection of small buffers is acceptable; do not claim large-file interactivity from gap-edit timings alone. If complete edit-to-render measurements show whole-buffer serialization dominating, implement server-owned visible-range projection using text range traversal before claiming the corresponding performance. That optimization must preserve global source positions, search scope, copy and shared logical viewport semantics.

REPL/configuration/model commands also marshal mutation to the same owner. Read APIs requiring live resources execute there; HTTP threads only handle transport/detached results. Admission and render notifications need bounded policies before production hardening; the initial queue's lack of bounds is a known input-slice limitation, not permission to rewrite unrelated runtime code during research.

## 22. Proposed implementation files

Only introduce a file when its milestone has behavior/tests. Paths below are proposed boundaries, not instructions to create empty placeholders.

| Path relative to the Tuna repository | Responsibility |
|---|---|
| `tuna/buffer.ss` | The one buffer, node values, structure/lifetime, navigation, updates and revision. |
| `tuna/text-buffer.ss` | Opaque text-source read interface, editable storage, lightweight read-only sources and source annotations. |
| `tuna/text-view.ss` | Derived logical flow, line iteration, source/boundary mapping and whole-buffer text consumers; no second document. |
| `tuna/private/gap-buffer.ss` | Private UTF-8 gap/index implementation and prepared reversals. |
| `tuna/private/annotations.ss` | Property runs/overlay collections and deterministic relocation/precedence. |
| `tuna/history.ss` | This buffer's semantic groups, undo/redo and retention. |
| `tuna/files.ss` | Local file associations, coding and safe visit/save/revert. |
| `tuna/render.ss` | Target-neutral node/context rendering seam. |
| `tuna/render/html.ss` | Semantic HTML, escaping, source maps and token-backed faces. |
| `frontend/tuna-keyboard.ts` | Existing queue extended to key/text/clipboard/pointer intent. |
| `web/tuna.css` | Small handwritten theme/token stylesheet for the buffer surface. |
| `tuna/{input,server,main}.ss` | Minimal bridge from existing dispatch/streams/lifetime to one buffer. |
| `{build.ss,manifest.ss}` | Actual new modules/assets in the established build layout. |
| `tests/` | Focused proof using the existing isolated Gerbil harness. |

There is no new `editor.ss`, buffer-manager, frame/window or generic UI-shell module. New buffer modules use native Gerbil and normal imports, not Tuna's custom prelude; export only the necessary public procedures. Existing macros/hooks/bindings/registries, Gerbil sources and shared installations are not refactoring targets.

## 23. Implementation milestones and stop conditions

### M0: prove the risky mechanisms

Build an isolated HTML-only fixture for one buffer using the existing transport/embedded Datastar version: ordinary typing, modifiers, plain-text clipboard, pointer/source mapping, rich runs, caret/selection and two browser mirrors of that same buffer. This proves the editing surface, not a generic UI shell. No input/textarea/contenteditable workaround. Separately prove Gerbil cancellation/unwind behavior and typed private-store construction with the native prelude. Record browser/OS/runtime versions and failures. Stop and return to the owner if this surface cannot meet the accepted ordinary-input baseline; do not substitute a different editing product silently.

### M1: text, positions and the flat reference oracle

Implement opaque gap storage, scalar positions/conversions, detached snapshots/range streaming, batch validation and anchor mapping. Differential-test random Unicode/line-ending edits against the flat oracle; prove snapshot isolation, no-op behavior and failure atomicity. No public storage fields or generic sequence framework. Stop when the private seam and its tests are correct; no UI library work.

### M2: structured buffer and compound history

Implement the one buffer's identity, minimal group/text nodes with role/data/flow, lightweight read-only contributions, logical text view/lines/mapping, shared navigation, structure edits, lifetime, candidate updates/rollback, generations and semantic undo/redo using native Gerbil. Verify segmentation-independent lines/movement/search/copy, multi-source edits and structural moves/deletions as one group, navigation repair, redo branching and history retention. All mutation runs through the existing owner thread. No buffer manager, switching, frames/windows or customization machinery.

### M3: properties, overlays and usable rich-buffer editing

Implement property runs/inheritance/copy/protection, overlays/priority/affinity, ordinary text-command procedures over the unified view and buffer-local semantic context. Wire target-neutral rendering, semantic HTML/source/boundary maps/tokens, ordinary printable keys, clipboard/pointer selection and per-subscriber projection delivery into the existing page. The exit condition includes visible properties and overlays while editing the one buffer—not a plain textarea, command-only demonstration or generic UI shell. Prove no optimistic text state and all tabs sharing selection/focus.

### M4: ordinary file editing

Implement valid-UTF-8 visit/save/save-as/revert within the one buffer, BOM/endings, local canonical identity, conservative file-modified/checkpoint tracking, external conflicts and safe-write errors. A plain-file root uses the same nodes/text/commands as richer content. Validate special filesystem cases instead of silently changing symlink/hard-link behavior. Provide outcomes through this buffer's generated text/semantic content. Stop here: the complete baseline still displays exactly one buffer and uses no Tuna custom macros/live bindings.

### After this plan: separately scoped work

Real-buffer recovery follows the conditional S3 scope of the application-state plan, not a fabricated fixture or separate autosave engine. IME/EditContext, additional file codecs, language packages, a kill ring, richer nodes or another renderer need their own scope. Buffer orchestration, frames/windows and any future customization integration likewise remain separate projects; no abstractions or placeholder modules for them belong in this implementation.

## 24. Acceptance matrix

| Family | Required proof |
|---|---|
| Scope | Exactly one displayed structured buffer; content groups/leaves are not windows/panes; no buffer manager, switching, frames or generic UI shell. |
| Public API | Every operation in section 4 has behavior-facing coverage for inputs/results, ownership/liveness, no-op/failure and relevant history/publication effects; audit decisions resolved before implementation. |
| Text-view coherence | Inline/line/block composition, actual versus structural LF, empty/trailing lines, cross-piece graphemes/matches/copy, source mapping and stale-view rejection; identical flow under different segmentation behaves identically. |
| Storage isolation | Stable snapshots survive edits, stale live views fail explicitly, and returned data cannot mutate storage; replacement backend satisfies the same reference tests. |
| Unicode/newlines | Empty/trailing-newline text, multibyte scalars, combining sequences, emoji, CRLF/mixed endings, invalid bounds, UTF-16 conversions and control-character projections. |
| Batches/anchors | Both affinities at every boundary, adjacent/coincident edits, deletion to empty, equal-position ordering and the `XYZ` example. |
| Properties | Interior/boundary inheritance, explicit no-inheritance, conflicting stickiness, read-only checks, copy/yank and property-only undo. |
| Overlays | Relocation, expansion/exclusion, zero-width/evaporation, the crossed `(2,0)` replacement case and subsequent point insertion, stable priority ties, property precedence and no accidental file modification/copy. |
| Structure/identity | Acyclic ownership, unique identities, move/copy/delete, copied file text becoming an unassociated draft, empty/read-only buffers, anchor detachment/resurrection and focus repair. |
| Transactions/history | Failure at each preparation/apply/commit boundary; exceptions/cancellation/nonlocal exits; one compound group; redo branching; saved checkpoint; retention. |
| Navigation/search | Shared point/mark/semantic focus/restrictions; two browser mirrors; logical order independent of layout; inline cross-source matches and declared row boundaries; protected replacement reporting; copy separators from flow; source-only selection deletion. |
| Files | UTF-8/BOM/ending round trips; duplicate aliases; save failure; external changes; permissions/symlinks/hard links; undo after save/revert; narrowing ignored by save. |
| Rendering | HTML-free model/recording renderer; escaped adversarial text; semantic headings/lists/pre; stable IDs; exact source maps for split/hidden/control runs. |
| Input | Ordinary typing/repeat/modifiers, no named-key insertion, clipboard gesture delivery/cut safety, pointer generation rejection, rapid queued typing and uncertain-outcome recovery. |
| Runtime | POST acknowledgement versus completion; delayed uncertain intents before/after epoch fencing, old-epoch rejection and retained fence markers under coalescing; current state on reconnect; subscriber fan-out/coalescing; failed stream isolation; render failure after commit; orderly shutdown. |
| Accessibility/style | Focus, keyboard operation, screen-reader behavior on the custom editing surface, logical source order, contrast, zoom/reflow and token consistency. |
| Native Gerbil | New buffer modules compile/test with `:gerbil/core` without Tuna custom-prelude, macro-registry, live-binding or hook dependencies; ordinary procedures integrate with the existing runtime; no live-replacement acceptance gate. |

Use public/buffer operations as the principal tests, with private invariant tests only for mechanisms that cannot be observed fully otherwise. Seed randomized tests and retain reproducible failure traces. File tests use temporary directories; failure/cancellation tests use bounded deterministic injection points. No destructive user-file tests.

The existing evidenced validation command is `cd /home/jay/Code/workbench-gerbil/tuna && PYTHONDONTWRITEBYTECODE=1 python3 tests/run.py`; it uses the installed Gerbil toolchain and an isolated scratch sandbox. Extend that established harness deliberately as modules are added. The current app build is `make all`/`gerbil build` according to its Makefile. Derive any new formatter/linter/browser commands from the actual toolchain and repository at implementation time; this proposal does not invent them or claim they ran.

Browser acceptance begins on the locally available desktop browser, with precise version/OS recorded. Investigate other desktop engines without making untested compatibility claims or adding an unsupported browser-specific requirement. Full IME, dead keys and mobile input are explicitly not first-baseline gates. Accessibility claims require actual testing, not a semantic-tag inspection alone.

## 25. Performance and memory evidence

Measure private store operations and the full consumer path separately: localized typing/deletion, far/scattered edits, paste, ordinary/high-line-count/very-long-line coordinate conversion, property/overlay/anchor counts, tree-wide replace, undo retention, range rendering, complete projection and save. Include 1/10/100 MiB corpora as characterizations, not inherited latency promises.

Track wall time, allocation and retained memory for edit plus logical-view indexing/mapping, annotation remapping, history and projection. Re-run after long edit sessions and many small editable/read-only contributions; distinguish source-count overhead from total-character work and test segmentation-independent behavior. Whole snapshots/serialization are expected linear work with a gap store; they must not be confused with cheap local splices. A node/property/overlay sidecar that introduces linear work per key must show its measured scaling; optimize only the demonstrated responsible mechanism.

Set release thresholds from actual target hardware, data sizes and rendering strategy before claiming interactive large-file support. Never use a passing storage microbenchmark as proof that server HTML updates, Unicode motion or compound history are responsive.

## 26. Compatibility limits and approval boundary

This implements Tuna's structured buffer, not a full editor UI or an Emacs Lisp compatibility layer. Deliberate initial differences include code-point offsets starting at zero; explicit structural identity; compound history spanning one tree; separate logical/file modification state; one displayed buffer with mirrored navigation; native Gerbil without Tuna's custom macros/live bindings; UTF-8-only coding; and deferred composition acquisition. Existing Emacs packages cannot run unchanged merely because ordinary text operations exist.

The proposal preserves the reusable principles: powerful text operations everywhere, properties distinct from overlays, opaque storage, stable anchors, coherent user history, explicit file identity and server-owned projections. Its first implementation is intentionally smaller than Emacs, but no required family is hidden inside HTML or hand-waved as part of the gap buffer.

### Required public-API audit before implementation

Audit the inventory in section 4 against every behavioral section and a small neutral core fixture, not application-specific screens. Record each operation's complete argument/result/error schema, valid option defaults, owner-thread entry, callback ordering, no-op behavior, and history/generation/publication effects. Remove redundant convenience exports only through an explicit API revision; do not silently omit operations while claiming this inventory is implemented.

The following public-API audit items remain open from the earlier candidate list and the revised text-view model: exact node/edit/fragment/line/match/result schemas and defaults; root/source initialization versus undoable updates and any need for explicit history clearing; logical-modification checkpoint/reset policy separate from file saves; generated/read-only semantic refresh history policy; word classification and preferred-column movement across sources/boundaries; boundary-position and protected-edit behavior in empty/non-text content; and which convenience operations should remain public versus private compositions. The flow/source/view model and all proposed operation names are now recorded, but this is not a claim that those decisions or runtime/browser proofs are already settled. Resolve these in the audit before authorizing implementation.

Before buffer implementation, the owner reviews/accepts this proposal and its recorded buffer-specific API audit, including any adjustments to vocabulary, source/file ownership and scope. The application-state plan's approved S0–S2 contracts/host/defaults are prerequisites, not blanket approval of M0–M4 or a claim S3 is proved. Implementation permission must name the approved milestone/scope; no permission to modify Gerbil/shared installations, deploy, push or read/write user checkpoint files follows from a research document.
