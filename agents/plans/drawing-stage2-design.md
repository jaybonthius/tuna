# Design: drawing stage 2, `memo` and sources

**Status:** design for review (2026-10-22). Stage 2 of `agents/plans/drawing-only-what-changed.md`, under ADR 17. Nothing here is built yet. Line numbers are at `16f0891`.

## 1. `tuna/lib/memo.ss`

```scheme
(defstruct source ((revision    : :fixnum)    ; from next-id!, so never repeated
                   (per-client? : :boolean)   ; reading it makes a piece one client's
                   (noted-in    : :fixnum))   ; the last frame that recorded it (dedupe)
  final: #t)
(def (new-source per-client?: (per-client? : :boolean := #f)) => source)
(def (record-read! (s : source)) => :void)   ; no-op outside a frame
(def (source-changed! (s : source)) => :void) ; new revision; test mode: error while drawing
(def (memo-drawing?) => :boolean)
(def (check-not-drawing! (what : :symbol)) => :void) ; test mode: error while drawing

(defclass memo-cache ((pieces  : HashTable)   ; key (equal?) -> [piece ...], its variants
                      (clients : HashTable))  ; client (#f: none) -> eq table of the pieces its last pass used
  final: #t)
(def (new-memo-cache) => memo-cache)
(def (call-with-memo-pass (cache : memo-cache) (client : :t) (draw : :procedure)) => :t)
(def (memo (key : :t) (inputs : :t) (draw : :procedure)) => :t)  ; (draw inputs) => value
(def (memo-forget-client! (cache : memo-cache) (client : :t)) => :void)
(def (set-memo-checking! (on? : :boolean)) => :void)
```

- **Revisions.** One monotonic space: `source-changed!` takes `next-id!` (kernel, `tuna/kernel/ids.ss:11`), as node revisions and layout generations already do. Writes happen on the baton; `next-id!` also keeps sources made on other threads unique.
- **Tracking frame: a parameter**, `current-memo-frame`, 29 ns per recorded read against 11 ns for a global (`gerbil-mechanics.md`). A parameter is chosen because jobs start with an empty dynamic environment (ADR 3), so a job reading a text snapshot while the baton draws never records into the drawing's frame. A frame is `{id, reads, per-client?, pass}`. `record-read!` pushes `(s . revision)` unless `s.noted-in` is this frame's id (one record per source per frame, so 226 line reads of one text cost one pair).
- **`memo`.** It looks up the variants of `key` and reuses one when all of these hold: it is shared or this client's; its `inputs` are `equal?`; and it is current. Otherwise it runs `(draw inputs)` in a new frame and makes a new variant `{key, inputs, per-client?, client, reads, value, checked, current?, users}`. In both cases it adds the variant to the parent frame's reads, and per-client-ness propagates to the parent.
  - A piece's reads are `(source . revision)` pairs and child pieces. *Current* means every pair's revision is unchanged and every child piece is current, checked recursively. The result is cached per pass in `checked`/`current?`. Variants are never mutated after they are made, so a parent records a child variant itself.
  - **Inputs** must be plain data: numbers, symbols, strings, booleans, and lists or vectors of them, never node or view objects. Gerbil's `equal?` compares class instances field by field (checked with `gxi`), so an object in `inputs` would walk the tree, and an object mutated in place would compare equal to its old self.
  - **The closure rule, made precise:** `draw` may close over the objects its key identifies (the node with that id, the view with that id) and nothing else. This is sound because ids are never reused. ADR 17's rule is "closes over nothing else". This refinement is needed because SXML renderers take the node object.
  - **Keys** are explicit identity, chosen by the drawer: `'(screen)`, `(view V)`, `(node V N)`; stage 3 adds `(line V N ID)`. They are unique within a pass, which is stronger than ADR 17's "under one parent" and simpler, because the table is flat. A node renderer that memoizes its own parts puts its node id in the key.
- **No `source-set!` in stage 2.** Equality cutoff lives in each owner's setter, which compares and calls `source-changed!` only on a difference (§2). A value-holding helper waits for the outside sources of stage 5 (ADR 17: "only then").
- **Cache:** one `memo-cache` per renderer instance, keyed by `equal?` on the key. Variants let two tabs with different drawn runs keep their own node pieces without overwriting each other. Nothing is weak-keyed: pieces hold nodes through their closures, and Gambit weak tables keep entries whose values reach their keys (`gerbil-mechanics.md`).
- **Mark and sweep, per client.** A pass marks every variant it reuses or makes; reusing a variant also marks all of its child pieces, recursively, stopping at marked ones.
  - At the end of the pass, the client's marked set replaces its last one. A variant's `users` rises for each client that newly marks it and falls for each that dropped it; at 0 it leaves `pieces`.
  - New variants enter `pieces` only when the pass completes, so a pass that raises leaves nothing behind.
  - `memo-forget-client!` releases a client's set; the renderer calls it from `client-gone-hook`.
- **Test mode** (`set-memo-checking! #t`):
  1. **Double render.** `call-with-memo-pass` draws once through the cache, then again from scratch (every `memo` runs `draw` in a throwaway frame and touches no cache, marks or users). It fails with the key path and the first differing offset when the two differ.
  2. **No writes while drawing.** `source-changed!` and `check-not-drawing!` fail inside a frame.
  3. **Duplicate keys.** A second use of a key in one pass is an error.
  4. **Plain inputs.** Inputs that are not plain data are an error.
- **A piece's value in stage 2** is its HTML string; parents embed it as `(*unencoded* html)`, as today. Stage 4 changes values to UTF-8 bytes.

## 2. Sources, by owner (the audit's §3 table)

Readers in the contracts record; owners bump. Classes that providers extend gain a `(source : source)` field in the contract (`buffers/contract.ss:191-193`), which providers fill with `(new-source)`.

| Audit input | Source | Owner (contract, writer) | Recorded by |
|---|---|---|---|
| Node kind, attributes, children, keymap object | The node's source **is** its revision: providers' `revision` fields and the `node-revision` interface method go; `stamp!`/`stamp-nodes!` (`buffers/plugin.ss:217-233`, toy `:178-187`) call `source-changed!` on the node and its ancestors | buffers | `node-attributes`, `node-attribute`, `node-children`, `node-child-count`, `node-keymap`, `node-parent`, `node-revision` (so `children-items-of` and `node-item-count`) |
| Text characters; whole node in stage 2 | The text's source. Bumped by `replace!` (undo too) and `set-layer!` (`buffers/plugin.ss:70-85, 160-168`). Edits still stamp the text's nodes | buffers | `text-snapshot` (so every character, line and token reader) |
| Highlights (decorations) | The text's source (above). Per-layer ranges come in stage 3 | buffers | `text-highlights`, `text-all-highlights` |
| Point; other selections (none drawn yet) | The view's source (field on `view`, `contract.ss:281`). Bumped by `set-view-point!` (only when the position differs), `set-view-showing!`, `reset-view!`, `place-view!`, `set-view-scroll!` | buffers | `view-showing`, `view-node`, `view-point`, `view-placement`. The `showing` field is renamed so that `view-showing` can record; `view-position` and `view-revision` are no longer exported (no users) |
| Selected view (cursor class) | A contract-level `selected-view` source, bumped by `set-selected-view!` when the view differs | buffers | `selected-view`, and so `current-buffer` |
| Drawn run, scroll item, facts, average item height, placement | The client-view's source, made `per-client?: #t`. Reached only through `view-client`, which records it. Its fields are not recorded one by one | buffers; scrolling writes | `view-client` |
| Measurement cutoff | `set-client-view-scroll!`: no bump when the item is `item=?` and the offset is the same to the whole px. `set-client-view-facts!`: no bump for equal facts (fixnums, `eq?` root, `item=?` item). `set-client-view-average-item-height!`: stored rounded to 1/100 px, bumps only when that differs. Whole px would put up to (items ÷ 2) px of error into spacers and the sizer (`renderer/plugin.ss:409-462`). `set-client-view-drawn-items!`: only when the counts differ. `place-client-view!` always bumps (a new placement) | buffers | — |
| Buffer name, buffer-local settings | The buffer's source. Bumped by rename and `set-buffer-setting!` | buffers | `buffer-name`, `buffer-root`, `buffer-setting` (so the buffers scope) |
| Node kinds and renderers (H3) | A contract-level `node-kinds` source, bumped on define and on removal (`context-defer!`, as `buffers-changed!` is today at `contract.ss:637-662`) | buffers | `node-kind-ref`, `node-renderer`, `node-opening` |
| Settings (global values) | A source per setting: `setting` gains `(source : source)`, made by `defsetting` (`settings/contract.ss:22-32`). `context-set-setting!` bumps it now and again after removal | settings | `setting-value` (so `buffer-local-value`) |
| Setting scopes | A contract-level `scopes` source, bumped on `context-add-setting-scope!` and on removal. A scope's lookup records its own sources (the buffers scope through `buffer-setting`) | settings | `setting-value` |
| `with-settings` bindings | **Recommended:** drawing does not see the dynamic layer; `setting-value` resolves with `[]` while `(memo-drawing?)`. Nothing draws inside `with-settings` today (grep). A screen shows editor state, and the layer is one command's thread-local value (ADR 9). **Alternative:** a hit marks the piece always stale. But a piece made without the binding would still be reused under it, so this is not correct | settings | — |
| Keymap bindings on nodes (`data-clickable`) | A source per keymap, in a keys-contract table `keymap → source`. It is weak-keyed, which is safe here: a source does not reach its keymap. `bind!` (`keys/plugin.ss:383-389`) calls the contract's `keymap-changed!` now and after removal. **This fixes `TODO.md:31`:** a rebind redraws only the nodes whose keymap changed | keys | `keymap-clickable?` |
| Global click bindings (`part-clickable?`: status line, tabs) | A contract-level `global-bindings` source, bumped by bindings in the global keymap and by provider activation and deactivation. This covers the optional input service appearing or going, which does not restart the renderer: restarts follow `requires` only (`service-dependents`, `tuna/kernel/plugins.ss:433-438`) | keys | `part-clickable?` |
| Layout tree, frame, selected part, marks, locked requests | A contract-level `layout` source. The `generation` interface method goes, and providers call `layout-changed!`. The layout plugin routes its 22 `set!` sites (`layout/plugin.ss:183-777`) through one `set-state!`, which keeps today's identity comparison (`generation-now!`, `:504-517`) as the cutoff. The two-views double bumps where it now takes `next-id!` | layout | `render-layout` |
| Status line: running task name | Not a source. It is the screen piece's input (§4) | kernel | — |
| Line-id pins | Not a source (§3) | renderer | — |
| Stylesheets | Not part of the screen (unchanged) | stylesheets | — |

**Stage 1's generations:**
- `buffers-generation` and `buffers-changed!` are deleted; the finer sources above replace them.
- `settings-generation` and `keymap-generation` (the export and the `Keys` method) are deleted.
- `layout-generation` becomes the coarse `layout` source.
- The renderer's `client-screen` idle check (`renderer/plugin.ss:111-118, 534-561`) is deleted. A current screen piece returns the same string object, so the web transport's `eq?` skip (`web/plugin.ss:224-225`) keeps working.
- `restart-timer`, change-armed saving, and the equal-attribute cutoff stay.

Contract-level sources (`selected-view`, `node-kinds`, `scopes`, `global-bindings`, `layout`) live in contracts, not providers. A provider swap therefore cannot strand a recorded source, which is the reason stage 1 put generations there.

## 3. Side effects of drawing (H7, pins)

| Effect today | Stage 2 |
|---|---|
| `view-point` relocates and stores point (`contract.ss:1083-1092`) | Kept as an **explicit derived cache**: it rewrites the representation of an unchanged value, bumps nothing, and records the view and the text it relocated through. Moving it eagerly would need a views-of-a-text index that no owner has |
| `client-view-scroll-item` rewrites `top-item` (`:1209-1215`) | The same: a derived cache, recorded through `view-client` and the text |
| `view-client` creates a client view (`:1166-1174`) | Moved to a **pre-draw step** in `render-screen!`: `(render-layout 'views (lambda (v selected? start) (view-client v c)))`, outside the pass. The contract already defines unknown targets as "the views it shows" (`layout/contract.ss:199-205`). Creating one inside a frame calls `check-not-drawing!` |
| `children-items-kept` fills (`:714-745`) | Kept: a derived cache keyed by node revision, read through the recorded `node-revision`. Its values hold no node |
| Pins written while drawing (`pin-line-run!`, `renderer/plugin.ss:233-246`; the keep loop, `:503-519`) | **A renderer table per view**, `view id → text node id → line-ids`. Drawing only reads it. After a pass whose screen is not `eq?` to the client's last one, a **post-draw step** re-anchors each drawn text node's pin at its first drawn line. It recomputes runs with the same `view-run` and `drawn-children` the pieces use. Pins of views that no client's last pass drew are dropped |

**Why pins need no source.** Re-anchoring sets the pin to `(end of line FIRST, current revision, FIRST + offset)`, which yields the same offset at the current revision. So it changes no output. The offset changes only through text edits, which drawing already records. The post-draw step asserts this in test mode.

**This differs from the plan's wording** ("a view-owned source"). The pins are per view as the plan says, but kept by the renderer, because line ids are its DOM vocabulary. They are also shared by all tabs rather than per tab, as they are today. The consequence: an edit between two tabs' anchors leaves the drawn lines on one side of the edit with new ids, a morph cost and not wrong content. Per-tab pins would make every line-drawn text piece per-client. **The primary agent should confirm this choice.**

Neither step touches the kernel. Both are renderer-plugin work around the pass.

## 4. Dynamic parameters read while drawing

| Parameter | Stage 2 |
|---|---|
| `rendering-view` (`renderer/plugin.ss:143`) | Set inside each node piece from its key's view, not across pieces by the view piece (`:485`) |
| `rendering-lines` (`:147`) | Computed inside the text node's piece from its input run and the pins. Already bound inside the piece (`:220`) |
| `current-task-name` (kernel `loop.ss:278`, read by `status-line-text`, `renderer/contract.ss:47-60`) | **Input:** `render-screen!` reads it outside the pass. It is the screen's input and goes to the selected view's input. `status-line-text` becomes `(status-line-text (v : view) (command :? :symbol)) => :string`. The bare renderer double changes with it |
| `current-setting-bindings` (`settings/contract.ss:35`) | Not seen while drawing (§2, recommended) |
| `reading-buffer` (`buffers/contract.ss:941`) | Set and read inside one `buffer-local-value` call; not ambient across pieces. Unchanged |
| `current-client` (`clients/contract.ss:28`) | Drawing receives the client explicitly and must not read it; no drawing code does (grep) |
| The service registry (providers) | Required services restart the renderer on a swap. The optional input service is covered by `global-bindings` (§2) |

## 5. The renderer through `memo`

```scheme
(defclass html-rendering ((pieces  : memo-cache)
                          (pins    : HashTable)   ; view id -> text node id -> line-ids
                          (screens : HashTable))  ; client -> (last screen . drawn view ids), for the post-draw step
  final: #t)
(def (render-screen! (self : html-rendering) (c :? client)) => :string)        ; pre step, pass, post step
(def (render-view (self : html-rendering) (v : view) (selected? : :boolean) (start : node) (command :? :symbol)) => :list)
(def (render-node (self : html-rendering) (v : view) (n : node) (run : :t)) => :list)
```

| Piece | Key | Inputs | Per-client? |
|---|---|---|---|
| Screen: `(main …)` around `render-layout 'html` | `(screen)` | `[command]` | Yes, through its views |
| View: section, scroller, marker, spacers, sizer, status line | `(view V)` | `[selected? start-id command-if-selected]` | Yes: it reads `view-client` |
| Node: kind renderer or projection, with `with-node-id` | `(node V N)` | `run` (`#f`, `item`, or `(first . last)`) | No, unless a renderer reads a per-client source |

- The view piece computes the run from the client view and passes it down as plain data. So node pieces, text nodes included, are shared by every tab drawing the same run of the same view. Two tabs with different runs keep one variant each.
- The focus-path view state (`(point . selected?)`), `face-remapping`, the keymap generation and `how` leave the key. The reads they stood for are recorded: `view-point`, `selected-view`, `buffer-local-value`, `keymap-clickable?`, `node-renderer`.
- Ancestors of a changed node redraw because their child pieces are no longer current, as they do today. Lines by value are stage 3.
- **Deleted:** `kept-html` (`renderer/plugin.ss:85-91`), `view-html`, `drawing`, `client-screen`, `pin-line-run!`, `view-html-for`, `node-ancestors`, the keep loop, and the header's "HTML reuse" and "Idle" paragraphs, which a `memo` paragraph replaces.

## 6. Kernel, contracts, risks, order

**The kernel is unchanged.** `memo.ss` uses only `next-id!` and parameters. It is added to `build.ss` after `lib/advice`.

**Contracts changed:**
- buffers: source fields, recording readers, cutoffs, contract-level sources; generation deleted; `view-client` guard.
- settings: setting source, scopes source, dynamic-layer rule; generation deleted.
- keys: `keymap-changed!`, per-keymap and global-bindings sources; generation deleted.
- layout: `generation` method becomes `layout-changed!` plus the recorded read.
- renderer: `status-line-text` takes the command.

The text-store, clients and web contracts are untouched. **No contract serves a single consumer:**
- the recording readers serve every drawer: the renderer, plugins' node renderers, the layout's HTML, and later `proced`;
- `layout-changed!` and `keymap-changed!` serve every provider of those contracts;
- `status-line-text` serves both renderers.

**Risks:**
1. A drawer reading state behind the accessors is caught only by the double render, and only on tested paths.
2. A thunk capturing a computed value: the same limit.
3. Validating a reused screen walks every recorded read: O(drawn pieces), estimated in microseconds and not yet measured.
4. Equal-attribute cutoff (stage 1) runs `equal?` on attribute values that are objects, such as completion's `session`: a field-by-field walk, cyclic in the worst case. This predates stage 2; flagged only.
5. Redefining a renderer's helper with `redefine` is not tracked (H3 remainder).
6. Shared per-view pins (§3).
7. Rounding the average to 1/100 px rather than ADR 17's whole px (§2).
8. The dynamic-layer rule (§2).

**Order** (each step leaves `make test` green; run under the memory cap):
1. **`memo.ss` and `tuna/tests/unit/memo-test.ss`.** Tests: reuse while sources are unchanged; redraw on a bump; `equal?` inputs; a child's change invalidates its parent; a reused parent keeps its children live through a sweep; shared and per-client variants; `memo-forget-client!`; and the four test-mode errors.
2. **Sources in the contracts and providers (default and toy buffers, settings, keys, layout, two-views),** with generations still present.
   - Contract tests in `buffers-contract-test`, `settings-test`, `keys-test` and `layout-test` check: writes bump; equal writes and reads do not; a rebind bumps only its keymap; rounded measurements settle.
   - Stage 1's `buffers-generation` checks become source checks.
3. **The renderer through `memo`:** pre-draw and post-draw steps, `status-line-text`. Delete the old key, `client-screen`, and every stage 1 generation.
   - The `html-renderer-test` cases that inspect kept tables become call-count tests.
   - The three pin tests (`:593-650`) must pass unchanged.
4. **Test mode on** in `html-renderer-test`, `web-test`, `idle-test` and `renderer-swap-test` (or in `call-with-fresh-kernel` for every test, if the run time allows). New tests in `html-renderer-test`:
   - a renderer reading a global setting, and one reading a buffer-local setting, is redrawn when it changes;
   - a rebind redraws only nodes whose keymap changed (count renderer calls per kind);
   - a row-kind node is drawn once for two clients with the same run, and twice with different runs;
   - a renderer reading a global variable behind the accessors makes the double render fail.

   `idle-test` passes unchanged: views are counted through its `show-status-line` scope, which a reused view never reads.
5. **Bench.** Build `scratch/rendering-audit/bench` with `GERBIL_PATH` pointing at this worktree's `.gerbil`, at `16f0891` and after stage 2, and compare `*long*` and `*mixed*` (idle, `C-f`, key; one and two tabs) with `run4.txt`.
   - Expected: key and `C-f` about the same in both, because the text node is still one piece.
   - Expected: a redisplay after a task that changed nothing is one validation.
   - Expected: the second tab costs only its screen and view pieces.
6. Update `docs/emacs-equivalents.md` only if a divergence lands (the dynamic-layer rule).

## As built (2026-10-22)

Stage 2 is implemented, in commits `ea2626e` through the docs commit after `a951978`. It departs from the design above as follows:

- **Field names.** The source fields are named `changes`: `text`, `node`, `buffer`, `view` and `client-view` each have `(changes : source)`. A field named `source` of type `source` breaks Gerbil's keyword constructors, because the parameter shadows the type.
- **Settings.** A setting's source is kept in a weak `eq?` table beside it (`setting-sources`), not in a field. Settings are hash keys in `equal?` entry tables, so a mutable field would change their hash. Settings made without `defsetting` record `unlisted-settings-source`. Keymaps work the same way: `unbound-keymaps-source` covers a keymap until it is first bound.
- **Point.** A view has a second source, `point-changes`, read only by `view-point`. With a single view source, every text node in `*mixed*` read its view to learn whether it held the focus, and `C-f` drew them all again; the audit bench caught this.
- **Node revisions.** Each changed node and each of its ancestors gets its own new revision, not one revision shared by all of them. Tests check "a new, larger revision".
- **Views.** A view's `section` element is drawn on every screen and is not part of the piece, because the layout adds its own attributes (sizes) to it. The view piece's inputs are `[start-id command-if-selected]`.
- **Test mode.** It is on in every test kernel (`call-with-fresh-kernel`), not just in four tests; `make test` takes the same time. Tests that count draws leave out the scratch drawing with `memo-from-scratch?`.
- **Pins.** A pin also records its line. Re-pinning is skipped when a text node's first drawn line and character revision are unchanged.
- **Layout.** The tree layout calls `note-state!` (the identity comparison, then `layout-changed!`) at the end of every operation that sets its state, and at activation and deactivation.
