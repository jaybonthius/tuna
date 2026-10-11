# Editor-buffer research gaps

Status: prioritized research backlog, not an implementation roadmap.

Severity describes the risk of freezing the wrong ownership or semantic boundary.
It does not mean every topic must be completed before a private text-store
prototype.

## Current coverage

The collected work already provides strong evidence for:

- Racket/server authority and a serialized state owner;
- editor buffer versus view separation;
- mutable gap-buffer and persistent-rope implementations in Racket;
- UTF-8, character, UTF-16, line, and newline semantics;
- file identity/conflict basics;
- revision tokens, change hooks, undo-versus-rollback distinctions;
- server-rendered projection and visible-line slicing;
- buffer-local fallback and basic major/minor mode ideas.

It does not yet provide a coherent model for an editor buffer containing a
structural UI tree with several editable text leaves.

## P0: establish ownership and edit semantics

### 1. Buffer, shared text, view, leaf, and subtree scope matrix

**Risk: blocker for public vocabulary and persistent identities.**

Compare these cases explicitly:

- one ordinary buffer shown by several views;
- separate buffers sharing one text identity, as GNU Emacs indirect buffers do;
- one rich editor buffer owning several text leaves;
- a view displaying all or only a subtree of a rich buffer;
- a narrowed/restricted view of shared text;
- a structural subtree carrying inherited modes or metadata.

For each state category, record whether it belongs to shared text, editor-buffer
identity, structural subtree, text leaf, view, pane, session, or dynamic command
context:

- text and text properties;
- file identity and dirty/save baseline;
- point, mark, selection, and viewport;
- markers and overlays;
- major/minor modes, locals, syntax, and keymaps;
- undo history;
- render/projection caches;
- persistence and lifecycle.

GNU Emacs research needed:

- [Buffer Internals](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Internals.html)
- [Indirect Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Indirect-Buffers.html)
- [Current Buffer](https://www.gnu.org/software/emacs/manual/html_node/elisp/Current-Buffer.html)

Important distinction: indirect buffers share text and text properties, but
retain separate point, narrowing, overlays, modes, and local variables. Multiple
views of one buffer are not the same feature.

Research gate: model two buffer identities sharing text while independently
changing mode, restriction, overlays, and locals; model two views of one buffer
with independent visible point/selection/scroll.

### 2. Buffer identity and lifecycle

**Risk: high; identity APIs can accidentally freeze ownership.**

Research ordinary GNU Emacs buffer lifecycle separately from file visiting:

- creation, initial state, and default naming;
- lookup by name versus stable identity;
- naming conflicts and rename behavior;
- liveness and buffer enumeration/order;
- selecting a current buffer dynamically and restoring it after return or
  nonlocal exit;
- kill queries, kill hooks, cleanup ordering, and failed/vetoed kills;
- what happens to views, processes, markers, overlays, jobs, and extension-owned
  state when a buffer dies;
- base/indirect-buffer kill relationships and shared-text lifetime;
- generated/internal buffers versus user buffers;
- persistence or restoration of dead buffer identities.

GNU Emacs sources:

- [Creating Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Creating-Buffers.html)
- [Buffer Names](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Names.html)
- [Current Buffer](https://www.gnu.org/software/emacs/manual/html_node/elisp/Current-Buffer.html)
- [Buffer List](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-List.html)
- [Killing Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Killing-Buffers.html)

Research gate: create and rename colliding buffers; dynamically switch the
current buffer and unwind through failure; kill a visible buffer, an indirect
buffer, and a base buffer with live dependents; verify deterministic cleanup and
view fallback without reusing dead identity accidentally.

### 3. Authoritative structural content tree

**Risk: blocker and security-critical.**

Distinguish three trees:

1. the editor's outer pane/layout tree;
2. one editor buffer's authoritative semantic content tree;
3. the rendered HTML/DOM projection.

Research questions:

- What is the minimal structural node grammar?
- Which nodes have stable identities, and what invariants survive movement or
  replacement?
- Do text leaves own stores, reference stores, or project ranges from stores?
- Are positions represented by stable leaf ID plus offset, by a node path, or by
  another anchor?
- Which HTML tags, attributes, CSS classes/styles, and event descriptions may
  trusted extensions request?
- How is user/file text prevented from becoming trusted markup?
- What is authoritative semantic state versus derived presentation?
- What happens to views and anchors when a subtree moves or is deleted?

Do not reuse old Tuna's layout tree as the content tree. That tree arranges panes
and frames; the requested content tree lives inside one pane.

Research gate: examples for a plain file, a two-column Git view, nested sections,
a moved text leaf, and deletion of a subtree currently selected in two views.

### 4. Focus and command-target ownership

**Risk: high; a multi-leaf buffer needs a server-owned dispatch target.**

Research:

- whether active/focused content belongs to the view, editor buffer, pane,
  connection, or command context;
- the distinction among selected pane, selected view, current editor buffer,
  focused structural node, and active text leaf;
- how the focused leaf selects point, modes, local keymaps, and command targets;
- focus behavior for non-text controls and nested editable regions;
- deterministic fallback when a focused node moves, becomes hidden, or is
  deleted;
- whether two views of one buffer may focus different leaves independently;
- reconciliation of browser focus events with server node/view/revision state;
- stale focus events, tab order, screen-reader focus, and keyboard accessibility;
- temporary command context that operates on a nonfocused buffer or leaf without
  changing visible focus.

Useful GNU Emacs comparisons include selected window versus current buffer,
minibuffer focus, active keymap selection, and temporary buffer switching. Tuna
should compare those capabilities without assuming that a structural child is
an Emacs window.

Research gate: two views focus different leaves of one buffer; commands resolve
against each view's target; deletion and movement repair focus predictably; a
stale browser event cannot retarget a newer render; keyboard and accessibility
focus remain explainable.

### 5. Point, mark, markers, regions, and narrowing

**Risk: high cross-cutting rework if deferred too far.**

Existing work defines point mapping but not a full anchor model. Research:

- buffer point versus view point;
- mark activation and mark rings;
- marker lifetime and detachment;
- insertion affinity at both endpoints;
- replacement/deletion collapse rules;
- mapping all affected views and annotations through one edit;
- positions across structural moves and leaf deletion;
- narrowing/restriction semantics and unwind-safe temporary widening;
- whether saving ignores narrowing, as Emacs does;
- how restrictions interact with shared text and subtree scope.

GNU Emacs sources:

- [Point](https://www.gnu.org/software/emacs/manual/html_node/elisp/Point.html)
- [The Mark](https://www.gnu.org/software/emacs/manual/html_node/elisp/The-Mark.html)
- [Overview of Markers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overview-of-Markers.html)
- [Narrowing](https://www.gnu.org/software/emacs/manual/html_node/elisp/Narrowing.html)

Research gate: exhaustive insertion/deletion/replacement tables at anchor
boundaries; edits from one view remap every affected anchor; restrictions restore
on normal return, exception, and nonlocal exit.

### 6. Change generations and structured deltas

**Risk: high; required by anchors, undo, parsing, and incremental rendering.**

The Gerbil research correctly distinguishes cheap generation tokens from
structured/coalesced changes. Tuna still needs buffer-facing semantics:

- which generations change for characters, text properties, overlays, modes,
  file baselines, structural nodes, and projections;
- whether one command publishes one outer revision plus resource generations;
- how old-text ranges and final ranges are represented;
- synchronous versus deferred/coalesced observers;
- visibility of failed or canceled updates;
- stale background parser/fontification/render results;
- no-op calls versus actual byte/property changes.

GNU Emacs sources:

- [Buffer Modification](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Modification.html)
- [Change Hooks](https://www.gnu.org/software/emacs/manual/html_node/elisp/Change-Hooks.html)

Research gate: character-only, property-only, overlay-only, structural, batched,
aborted, and multi-leaf edits; stale consumers reject results using the relevant
generation.

### 7. Text properties, overlays, and subtree metadata

**Risk: high; this is the core Emacs capability currently missing.**

Research text-attached and buffer/view-attached metadata separately:

- property copy/yank behavior;
- front/rear stickiness and endpoint affinity;
- modification hooks;
- property lookup, interval operations, and undo;
- overlay priority, evaporation, categories, window/view specificity, keymaps,
  invisibility, and display replacement;
- sharing through indirect buffers;
- deterministic precedence among text properties, overlays, subtree metadata,
  modes, and view-local decorations;
- movement when text or structural nodes move.

GNU Emacs sources:

- [Text Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Text-Properties.html)
- [Overlays](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlays.html)

The old Weevil `decoration` range is only a rendering hook; it is not an editor
metadata model.

Research gate: copied text retains chosen properties; overlays do not leak
between buffers sharing text; overlapping sources produce deterministic
projection data.

### 8. Undo, redo, rollback, and cross-leaf transactions

**Risk: blocker before choosing mutable aliases or persistent-root retention.**

Keep four facilities distinct:

- command failure/cancellation;
- user undo/redo;
- persistence/recovery;
- compensation for external effects.

Research:

- command grouping and typing amalgamation;
- Input Method Editor (IME) composition as one user action;
- multi-leaf plus structural edits in one command;
- restoration of point, mark, properties, modes, dirty state, and save baseline;
- multi-buffer commands;
- redo representation;
- generated/read-only buffer policy;
- history retention and memory budgets;
- interaction with asynchronous file/process/parser effects;
- mutable store reversal versus persistent root retention.

GNU Emacs source:

- [Undo](https://www.gnu.org/software/emacs/manual/html_node/elisp/Undo.html)

Research gate: grouped typing, replacement, cross-leaf edit, structural move,
multi-buffer command, save→edit→undo, property edit, failed command, and external
effect examples.

### 9. Browser text acquisition under server authority

**Risk: blocker for real editing, especially IME and accessibility.**

A keydown-only protocol cannot carry composed text. Research official Input
Events, UI Events, Selection, HTML editing, and EditContext behavior, then run
real-browser experiments.

Compare:

- hidden textarea acquisition;
- constrained `contenteditable` acquisition;
- EditContext where available;
- browser-local provisional composition with server-owned committed state.

Cover:

- `beforeinput`, `input`, composition start/update/end;
- dead keys, non-US layouts, CJK input, paste, deletion, clipboard, and selection;
- focus and pointer events carrying stable node/view/revision identity;
- morphs arriving during composition;
- acknowledgements, retry, duplicate suppression, stale selection, disconnect,
  and recovery;
- browser/OS reserved shortcuts and accessibility.

Research gate: Chromium, Firefox, and WebKit matrix for composition, selection,
paste, rapid input, morph-during-composition, disconnect, and reconnect.

## P1: modes, syntax, and display projection

### 10. Major/minor mode and local-state lifecycle

**Risk: high if buffer-wide mode assumptions become public too early.**

Research Emacs behavior and Tuna alternatives for:

- default/local fallback and automatic localization;
- major-mode reset and permanent locals;
- derived modes;
- minor-mode enable/disable ordering;
- mode hooks and failure policy;
- local keymaps, syntax tables, fontification, and cleanup;
- extension-owned metadata lifetime;
- mode resolution at outer buffer, subtree, leaf, range, or caret context;
- inheritance and boundary transitions between differently scoped modes.

GNU Emacs sources:

- [Buffer-Local Variables](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer_002dLocal-Variables.html)
- [Major Modes](https://www.gnu.org/software/emacs/manual/html_node/elisp/Major-Modes.html)
- [Minor Modes](https://www.gnu.org/software/emacs/manual/html_node/elisp/Minor-Modes.html)

Research gate: changing a major mode removes non-permanent state, preserves
declared permanent state, recomputes active maps/syntax/fontification, and does
not alter sibling subtrees or unrelated buffers.

### 11. Syntax, parsing, and fontification

**Risk: high; existing word predicates are not a syntax system.**

Research:

- character syntax tables and occurrence-specific syntax properties;
- mode-sensitive word and delimiter behavior;
- parser state and incremental invalidation;
- tree-sitter or other background parsing with immutable/stable snapshots;
- syntactic versus parser/search-driven fontification;
- visible-range demand and caches;
- mixed-language regions and structural subtrees;
- stale result rejection.

GNU Emacs sources:

- [Syntax Tables](https://www.gnu.org/software/emacs/manual/html_node/elisp/Syntax-Tables.html)
- [Syntax Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Syntax-Properties.html)
- [Font Lock Mode](https://www.gnu.org/software/emacs/manual/html_node/elisp/Font-Lock-Mode.html)

Research gate: editing before a cached parse invalidates only required state;
mixed-language leaves use distinct syntax/mode metadata; stale results cannot
replace newer Racket state.

### 12. Semantic display-to-HTML/CSS projection

**Risk: high; a line provider alone would flatten the new content model.**

Treat Emacs display properties as capability families rather than a compatibility
target. Research:

- source text versus replacement structural nodes;
- invisible text and motion/cursor behavior;
- faces/classes and semantic properties;
- overlays/decorations and precedence;
- model-to-display and display-to-model mapping;
- folds, synthesized content, gutters, columns, and embedded controls;
- hit testing and selection;
- view/subtree-specific presentation;
- stable HTML identity and Datastar morph behavior;
- cache ownership and invalidation granularity.

GNU Emacs sources:

- [Invisible Text](https://www.gnu.org/software/emacs/manual/html_node/elisp/Invisible-Text.html)
- [Display Property](https://www.gnu.org/software/emacs/manual/html_node/elisp/Display-Property.html)
- [Forcing Redisplay](https://www.gnu.org/software/emacs/manual/html_node/elisp/Forcing-Redisplay.html)
- pinned [`xdisp.c`](https://git.savannah.gnu.org/cgit/emacs.git/tree/src/xdisp.c?id=541f693ca2e8de166cfe52c39bbfc497142215e9)

Research gate: hidden/replaced text retains stable source positions; pointer
mapping returns source positions; full rendering and dirty-subtree rendering are
semantically equivalent.

## P2: file round trips and API inventory

### 13. Encoding-aware file lifecycle

**Risk: medium-high; conflict handling exists but byte round trips are shallow.**

Extend prior visiting/saving research with:

- coding-system detection and explicit override;
- UTF-8 byte-order mark (BOM);
- CRLF and mixed-end-of-line preservation;
- legacy encodings;
- invalid byte sequences and literal/binary visiting;
- unrepresentable characters at save time;
- save/revert coding changes;
- original bytes versus decoded text in conflict detection;
- backups, auto-save, recovery, and lock policy.

GNU Emacs sources:

- [Visiting Files](https://www.gnu.org/software/emacs/manual/html_node/elisp/Visiting-Files.html)
- [Coding Systems](https://www.gnu.org/software/emacs/manual/html_node/elisp/Coding-Systems.html)
- [Encoding and I/O](https://www.gnu.org/software/emacs/manual/html_node/elisp/Encoding-and-I_002fO.html)

Research corpus: UTF-8 with/without BOM, CRLF, mixed EOL, one legacy encoding,
invalid UTF-8, and text not representable by the selected output coding.

### 14. Buffer-facing capability inventory

**Risk: medium; useful after semantics, dangerous as an API-generation exercise.**

Use the preserved Emacs API catalog to check breadth, but classify interactions
rather than cloning names. For each family above, identify:

- minimum public Racket seam;
- private mechanisms;
- extension scenarios enabled;
- compatibility behavior intentionally omitted;
- validation through ordinary editor commands.

Representative scenarios should include selection, diagnostics, syntax modes,
completion annotations, file save/revert, generated or terminal buffers, shared
text, and structural subtree editing.

## Storage-specific research still required

Prior data-structure research is broad enough that another folklore survey is
not useful. The missing evidence is Tuna-specific:

- mutable text outside the revision root versus persistent leaf roots inside it;
- cost of mapping all anchors/views/metadata per edit;
- undo retention under realistic command grouping;
- parser snapshot and visible projection costs;
- complete-text versus range rendering;
- very long lines;
- multiple text leaves and multi-leaf transactions;
- memory after long editing sessions.

Any future benchmark should compare a narrow common private seam using the same
reference oracle and actual Tuna consumers. It should not generalize the old
SumTree failure, Tuna gap-buffer win, or Weevil rope win beyond their measured
architectures.

## Evidence dependencies and parallel work

This audit does not mandate a project sequence. It identifies evidence needed
before particular hard-to-reverse decisions:

- **Before durable identity or public naming:** resolve the scope matrix, buffer
  lifecycle, structural-tree identity, and focus/command-target ownership.
- **Before marker, property, overlay, mode, or undo APIs:** establish anchor,
  change-delta, transaction, and sharing semantics.
- **Before claiming a usable editing baseline:** complete real-browser text and
  IME acquisition experiments; keydown-only behavior is insufficient evidence.
- **Before selecting a long-lived storage representation:** benchmark candidates
  through Tuna's actual update, anchor mapping, undo retention, parser snapshot,
  and projection consumers.
- **Before freezing a display protocol:** demonstrate bidirectional mapping and
  semantic equivalence for plain text and structural content without treating
  line layout or DOM shape as authoritative.

Browser experiments, Emacs lifecycle research, encoding/file round trips, and
capability-inventory work can proceed independently where they do not assume the
unsettled object model. A private prototype is relevant evidence only to the
extent that it avoids silently fixing editor-level ownership, lifecycle, undo,
mode, persistence, or UI-tree policy.
