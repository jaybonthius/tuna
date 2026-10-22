# Research: not re-rendering unchanged lines (prior art for Tuna text items)

Date: 2026-10 (research run). Read-only survey; no repository file changed.
Labels: **Fact** = read in the cited source. **Interp** = my reading of what the source implies. **Inference** = my recommendation for Tuna, not stated by any source.

## Summary

No surveyed editor gives lines a persistent identity inside the text store. They all do the same three things, independent of the store:

1. Each edit produces a **change record**: a replaced range, old to new.
2. The render layer turns the change records accumulated since the last frame into a **line patch**: the old line range that was replaced and the new line range that replaces it. Lines outside the patch keep their cached rendering, and the cached lines below an edit simply shift.
3. Before rebuilding a line, the editor compares a small **per-line render input** with the one it last used: the line's text, its style runs clipped to the line, cursor columns and options. Rendering is skipped when they are equal.

Selections and cursors are usually drawn as a **separate layer**, so moving a cursor does not touch line content. Asynchronous highlight or LSP (Language Server Protocol) results carry the revision they were computed for. They are mapped forward through the edits made since then, and they invalidate only the lines whose styling actually changed.

For Tuna, the change records it already has (`change` = revision, start, removed, inserted; `text-changes-since`; `rebase-spans`) are sufficient and need nothing from the rope or a gap buffer. Two pieces are missing:

- a **line-stamp shadow** per drawn view, as in xi's `LineCacheShadow`;
- a **per-item render key** built from the content stamp, the decoration spans clipped to the item, the cursor and selection columns in the item, and a view-inputs generation.

---

## 1. Emacs redisplay (C) and jit-lock

Pinned to local checkout `/home/jay/Code/emacs` at `541f693ca2e8de166cfe52c39bbfc497142215e9` (2026-07-16). Line numbers refer to that commit. Permalinks use the GitHub mirror and assume the commit has been mirrored; this run did not check the mirror.

- **Fact, two glyph matrices and three steps.** Redisplay builds a *desired* glyph matrix only for changed parts, reusing the *current* matrix where it can. `update_window` then diffs desired against current and draws only the rows that differ. The desired matrix is "sparse": rows that need no update stay disabled. [xdisp.c L20–230](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/xdisp.c#L20-L230).
- **Fact, three tiers of optimisation tried in order:**
  - `try_cursor_movement`: the text did not change and only point moved, so the matrix stays valid and only the cursor moves.
  - `try_window_reusing_current_matrix`: the text is unchanged but the window start moved (scrolling).
  - `try_window_id` ("insert/delete"): reuse the unchanged rows at the top and bottom and regenerate the middle.
  - If none applies, `try_window` does a full rebuild.

  Sources: [xdisp.c L140–172](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/xdisp.c#L140-L172), call sites at L20916, L20951 and L21040.
- **Fact, the change information Emacs keeps.** `struct buffer_text` (buffer.h L253–285) has these fields:
  - `modiff`: increments on every modification.
  - `chars_modiff`: character changes only. Text-property changes bump `modiff` but not `chars_modiff`.
  - `overlay_modiff`: overlay changes.
  - `beg_unchanged` / `end_unchanged`: the number of characters at the start and end of the buffer untouched since the last completed redisplay.
  - `unchanged_modified` / `overlay_unchanged_modified`: the counters as of that redisplay, used to tell whether the two extents mean anything.

  `BUF_COMPUTE_UNCHANGED(buf, start, end)` takes the minimum over all changes since the last redisplay ([buffer.h L1003–1021](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/buffer.h#L1003-L1021)). Insertions and deletions update it (insdel.c L945, L1607), and so do text-property changes (`modify_text_properties`, textprop.c L78–95) and overlay changes (`modify_overlay`, [buffer.c L3688–3702](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/buffer.c#L3688-L3702)).
  - **Interp:** the whole change record Emacs keeps per frame is *one envelope*, the unchanged prefix and suffix. Any number of edits (a keyboard macro, query-replace) collapses into it at O(1) cost, at the price of rebuilding everything between the first and last change.
- **Fact, `try_window_id` gives up easily.** It gives up when `windows_or_buffers_changed` is set (a global "something structural changed" flag), when overlays changed (`w->last_overlay_modified != OVERLAY_MODIFF`), when narrowing changed, or when the window is horizontally scrolled. It finds the last unchanged row at the beginning and the first unchanged row at the end. It then redisplays only the rows between them and *scrolls* the reusable bottom rows by the line delta, adjusting their stored positions with `increment_matrix_positions` ([xdisp.c L22510–22640](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/xdisp.c#L22510-L22640), L22723–22754).
  - **Interp:** row "identity" is positional plus a character-position delta. A row below an insertion is the same row with its positions shifted.
- **Fact, the final output diff is content-hashed.** `row_hash` hashes each glyph's character, face id and type ([xdisp.c L24013–24030](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/xdisp.c#L24013-L24030)). `row_equal_p` compares hashes and then glyphs (dispnew.c L1272). `scrolling_window` uses the hashes to detect moved rows and emit terminal insert/delete-line operations (dispnew.c L5277). So even a full matrix rebuild sends to the screen only the rows that differ.
- **Fact, the region is an overlay that Lisp updates before redisplay.** `redisplay--update-region-highlight` moves one overlay per window ([simple.el L7286–7303](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/simple.el#L7286-L7303)). Moving it bumps `overlay_modiff` with the overlay's old and new bounds, which disables `try_window_id` for that cycle.
  - **Interp:** that is one reason extending the region is not as cheap as moving the cursor in Emacs.
- **Fact, jit-lock: lazy, visible-only fontification.** While building rows, `handle_fontified_prop` checks whether the `fontified` text property is nil and, if so, calls `fontification-functions` on that position ([xdisp.c L4667–4740](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/xdisp.c#L4667-L4740); variable doc L38900). `jit-lock-after-change` puts `fontified nil` on the changed region. It also lowers `jit-lock-context-unfontify-pos`, so text *after* the change is refontified later in a deferred pass, for syntax that spans lines such as an opened string or comment ([jit-lock.el L680–708](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/lisp/jit-lock.el#L680-L708)).
  - **Interp:** highlighting state is stored *in the text* as a property, so the store's own change tracking also invalidates highlighting. Fontification runs synchronously inside redisplay; it is lazy, not concurrent.
- **Fact, huge lines.** With `long-line-threshold` (default 50,000 characters), a buffer is flagged `long_line_optimizations_p` (detected at xdisp.c L20640–20653). Fontification functions then run narrowed to a region around the position (L3640–3673, L4702).

## 2. Zed (Rust, GPU, immediate mode)

Pinned to `574df448ea9cb9c22df1a5e887a4c6755e7e09ce`.

- **Fact, `Edit<D> { old: Range<D>, new: Range<D> }` and `Patch<T>`.** A patch is a sorted list of non-overlapping edits. Patches compose (`Patch::compose`) and invert ([text/src/text.rs L527](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/text/src/text.rs#L527-L531), [patch.rs](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/text/src/patch.rs#L8-L40)). `edits_since(version)` produces edits in any coordinate dimension: offset, `Point` (row and column), and so on. Positions that must survive edits are `Anchor`s, a (timestamp of the inserting operation, offset, bias) triple ([anchor.rs L11–30](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/text/src/anchor.rs#L11-L30)). That is a CRDT (conflict-free replicated data type) identity that Tuna does not need.
- **Fact, DisplayMap is a stack of layers:** Inlay, then Fold, then Tab, then Wrap, then Block. Each layer is a SumTree of `Transform`s with input and output summaries. Each layer's `sync(snapshot, edits_in_lower_coords)` returns a new snapshot and edits in its own coordinates. The module doc calls an `Edit` "a region to invalidate" and notes that one whole-range edit would always be correct but wasteful ([display_map.rs L1–58](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/editor/src/display_map.rs#L1-L58)). `WrapMap` rewraps on a background task. In the meantime it serves an *interpolated* snapshot and accumulates `edits_since_sync` by composition ([wrap_map.rs L215–330](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/editor/src/display_map/wrap_map.rs#L215-L330)).
- **Fact, the per-line cache is content-addressed, not identity-addressed.** Each frame the editor element recomputes highlighted chunks for the visible display rows (`layout_lines`, [element.rs L3181–3260](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/editor/src/element.rs#L3181-L3260)) and asks the text system to shape them. `LineLayoutCache` keys on `(text, font_size, runs, wrap_width, force_width)`; a text-hash variant avoids copying. It keeps two generations, `previous_frame` and `current_frame`: a hit in the previous frame is promoted, and `finish_frame` swaps the two and clears the new current ([line_layout.rs L458–640, L937–960](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/gpui/src/text_system/line_layout.rs#L458-L640)).
  - **Interp:** a line pushed down by an insert above still hits the cache, because its key does not contain a row number. Eviction is "unused for one frame".
- **Fact, selections and highlights are separate paint layers.** `paint_highlights` paints `highlighted_ranges` and per-player `selections` as quads before the text ([element.rs L5972–6000](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/editor/src/element.rs#L5972-L6000)), and cursors are painted separately (L6146). Selection does not enter the shaping key unless it changes text colour.
- **Fact, asynchronous tree-sitter parsing.** `Buffer::reparse` first *interpolates* the syntax map through the edits made since the last parse, then parses incrementally on a background thread. The foreground may block up to a `sync_parse_timeout`, about 1 ms. When the parse returns, the version is compared (`version.changed_since(&parsed_version)`). If the text moved on, the result is still installed and a new parse is scheduled (`parse_again`) ([language/src/buffer.rs L1925–2045](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/language/src/buffer.rs#L1925-L2045); `SyntaxSnapshot::interpolate`, [syntax_map.rs L422](https://github.com/zed-industries/zed/blob/574df448ea9cb9c22df1a5e887a4c6755e7e09ce/crates/language/src/syntax_map.rs#L422)). Highlight captures are queried per visible range at render time, not stored per line.
  - **Interp:** "invalidation" of highlighting is just "repaint, and the content-addressed shaping cache absorbs the unchanged lines."

## 3. VS Code / Monaco

Pinned to `4aa4e293fcf8ba39c5415a79da14c1fb6e6eb6a6`.

- **Fact, line events carry line ranges.** The view receives `onLinesChanged(from, count)`, `onLinesInserted(from, to)`, `onLinesDeleted(from, to)`, `onTokensChanged(ranges)`, `onDecorationsChanged` and `onFlushed`. `RenderedLinesCollection` holds only the rendered (viewport) lines. An insert above the viewport just increments `_rendLineNumberStart`. An insert inside it splices fresh line objects in and pushes lines out at the bottom ([viewLayer.ts L43–250](https://github.com/microsoft/vscode/blob/4aa4e293fcf8ba39c5415a79da14c1fb6e6eb6a6/src/vs/editor/browser/view/viewLayer.ts#L43-L250)).
  - **Interp:** line identity is the JavaScript `ViewLine` object, shifted positionally.
- **Fact, two-stage skip per line.** Each `ViewLine` has `_isMaybeInvalid`, set by content, token, decoration or option events. If the flag is clear, rendering is skipped. If it is set, the line builds a `RenderLineInput` from its content, tokens, inline decorations clipped to the line, tab size, whitespace mode, selections when they affect glyphs, and so on. If that input `equals` the previous one, the DOM is left untouched ([viewLine.ts L82–180](https://github.com/microsoft/vscode/blob/4aa4e293fcf8ba39c5415a79da14c1fb6e6eb6a6/src/vs/editor/browser/viewParts/viewLines/viewLine.ts#L82-L180)). `onDecorationsChanged` marks *every* rendered line maybe-invalid, and the input comparison absorbs it ([viewLines.ts L247–254](https://github.com/microsoft/vscode/blob/4aa4e293fcf8ba39c5415a79da14c1fb6e6eb6a6/src/vs/editor/browser/viewParts/viewLines/viewLines.ts#L238-L254)).
- **Fact, cursor and selection changes do not invalidate lines** unless high-contrast mode or `renderWhitespace: selection` is on (`onSelectionChanged`, viewLine.ts L95–101). Selections are a `DynamicViewOverlay` layer (`SelectionsOverlay`, selections.ts L62).
- **Fact, decorations live in an interval tree** whose nodes store a lazy `delta`, so edits shift many decorations in O(log n) (intervalTree.ts L141–300).
- **Fact, background tokenizer.** `DefaultBackgroundTokenizer` tokenizes in idle callbacks, yielding every 1–2 ms. `TrackingTokenizationStateStore.invalidateEndStateRange` marks lines whose end state must be recomputed, and tokenization proceeds from the first invalid line ([textModelTokens.ts L216–290, L445–560](https://github.com/microsoft/vscode/blob/4aa4e293fcf8ba39c5415a79da14c1fb6e6eb6a6/src/vs/editor/common/model/textModelTokens.ts#L216-L290)).
- **Fact, late LSP semantic tokens are rebased.** While a request is in flight, content changes are recorded in `pendingChanges`. On arrival each token area is adjusted by `applyEdit(range, text)` for every pending change, installed, and a new request is scheduled ([documentSemanticTokens.ts L258–290, L405–425](https://github.com/microsoft/vscode/blob/4aa4e293fcf8ba39c5415a79da14c1fb6e6eb6a6/src/vs/editor/contrib/semanticTokens/browser/documentSemanticTokens.ts#L405-L425)).

## 4. Xi, Neovim, CodeMirror 6, ProseMirror, Helix, Lapce

**Xi editor.** Pinned to `a2dea3059312795c77caadc639df49bf8a7008eb` (archived). It is the closest analogue: a core that owns the text and a front end that holds only a line cache.

- **Fact:** the `update` message carries ops `copy n` (keep n old lines; `ln` gives the new logical number), `skip n` (drop n old lines), `invalidate n` (n unknown lines), `ins lines` (new lines) and `update lines` (change cursor or styles of n existing lines without resending text). Selections and find results travel as **annotations**, separate from lines ([frontend-protocol.md L501–570](https://github.com/xi-editor/xi-editor/blob/a2dea3059312795c77caadc639df49bf8a7008eb/docs/docs/frontend-protocol.md#L501-L570)).
- **Fact:** the core keeps a `LineCacheShadow`, a run-length list of spans `(n, start_line_num_in_old_cache, validity)`. Validity is a bitset of `TEXT_VALID | STYLES_VALID | CURSOR_VALID` ([line_cache_shadow.rs L24–75](https://github.com/xi-editor/xi-editor/blob/a2dea3059312795c77caadc639df49bf8a7008eb/rust/core-lib/src/line_cache_shadow.rs#L24-L75)). Three operations write to it:
  - An edit calls `lc_shadow.edit(start_line, start_line+inval_count, new_count)` from the line-wrap layer's `InvalLines`.
  - A style change clears `STYLES_VALID` on a line range (`invalidate_styles`).
  - A selection change clears `CURSOR_VALID`, plus `STYLES_VALID` for non-caret selections, between the old and new selection lines (`set_selection_raw`).

  If wrap information cannot be computed, the core falls back to `set_dirty` (full) ([view.rs L391–430, L741–800, L972–990](https://github.com/xi-editor/xi-editor/blob/a2dea3059312795c77caadc639df49bf8a7008eb/rust/core-lib/src/view.rs#L972-L990)).
- **Fact:** plugin highlight spans and annotations arrive tagged with `rev`. If the revision is not the head, the core transforms them through `try_delta_rev_head(rev)`, installs them, and invalidates styles only over the transformed interval ([editor.rs L595–630](https://github.com/xi-editor/xi-editor/blob/a2dea3059312795c77caadc639df49bf8a7008eb/rust/core-lib/src/editor.rs#L595-L630)).
- **Fact:** `PRESERVE_EXTENT = 1000` lines; outside it the plan *discards* cache spans to bound memory.

**Neovim.** Pinned to `d714648b8e7c476b7b5c1f661aa192b179bfc1d3`.

- **Fact:** a buffer records `b_mod_top`, `b_mod_bot` and `b_mod_xlines` (the changed line envelope and the line delta) since the last redraw ([buffer_defs.h L428–439](https://github.com/neovim/neovim/blob/d714648b8e7c476b7b5c1f661aa192b179bfc1d3/src/nvim/buffer_defs.h#L428-L439)). This is Emacs's envelope in line units.
- **Fact:** each window keeps `w_lines[]` entries (`wl_lnum`, `wl_size` = screen rows, `wl_valid`, `wl_folded`, `wl_foldend`): one entry per *logical* line or closed fold (L870–886).
- **Fact:** `changed_lines(lnum, col, lnume, xtra)` both marks redraw and fires `nvim_buf_attach` `on_lines(tick, first, last_old, last_new, old_byte_count)` and `on_bytes` (change.c L588–616; api.txt L2386–2440).
- **Fact:** decoration providers (`nvim_set_decoration_provider`) are called *during redraw*, per window and per line or range being redrawn, and typically set **ephemeral** extmarks that last one redraw ([api.txt L3419–3470](https://github.com/neovim/neovim/blob/d714648b8e7c476b7b5c1f661aa192b179bfc1d3/runtime/doc/api.txt#L3419-L3470)).
  - **Interp:** the tree-sitter highlighter computes highlights only for lines being redrawn, like jit-lock.
- **Fact:** the final grid write compares cells (`grid_char_needs_redraw`, grid.c L631–720) and sends only changed cells to the UI.

**CodeMirror 6.** Pinned to view `fbff59ba`, state `9c801279` and language `8e970001`.

- **Fact:** a `ChangeSet` maps positions (`mapPos`) and iterates changed ranges. The view computes `changedRanges` from the changes, then extends them with `findChangedDeco`, which uses `RangeSet.compare(old, new, changes, comparator)` to find *only the ranges where decorations differ after mapping*. If nothing changed, the DOM is untouched ([docview.ts L59–112, L633–650](https://github.com/codemirror/view/blob/fbff59ba004d80d8c914f64c42586387b08706ac/src/docview.ts#L86-L112)).
- **Fact:** `RangeSet.compare` first finds shared chunks between the old and new sets, so unchanged decoration chunks are skipped without iteration ([rangeset.ts L338–350](https://github.com/codemirror/state/blob/9c801279cb83011e6f92af778f4443406e8f1200/src/rangeset.ts#L338-L350)).
- **Fact:** line and leaf tiles outside changed ranges are reused whole, and others reuse old DOM where possible (buildtile.ts L282–300). Only the viewport and visible ranges are drawn.
- **Fact:** `drawSelection` renders cursor and selection in a separate `layer` (draw-selection.ts L70, L102).
- **Fact:** `TreeHighlighter` only *maps* its decorations through changes while the parse tree has not caught up. When the tree object or the viewport changes, it rebuilds decorations for `view.visibleRanges` only ([language/src/highlight.ts, TreeHighlighter](https://github.com/codemirror/language/blob/8e9700018446d46f23267f6e31da56628d5117c0/src/highlight.ts)). The view's decoration diff then limits DOM work to lines whose marks actually changed.

**ProseMirror.** Pinned to `ca4c78e9`.

- **Fact:** the document is an immutable tree. A view node is reused when `matchesNode`: not dirty, `node.eq(this.node)` (identical or structurally equal), and the same outer decorations and inner `DecorationSource` ([viewdesc.ts L754–756](https://github.com/prosemirror/prosemirror-view/blob/ca4c78e9b56f1b164c0b3758b59d8748f11b7534/src/viewdesc.ts#L754-L756)). `DecorationSet.map(mapping, doc)` moves decorations through edits.
  - **Interp:** this works because document nodes *are* the render units. A rope's chunks are not lines, so Tuna cannot borrow store identity this way.

**Helix and Lapce (briefly).**

- **Fact, Helix** (`ba40e547`): it re-renders the view into a cell buffer each frame, and the terminal flushes `previous_buffer.diff(current_buffer)` ([helix-tui buffer.rs L748](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-tui/src/buffer.rs#L748), terminal.rs L155–162).
  - **Interp:** there are no line caches at all; all savings come from the output diff.
- **Fact, Lapce/Floem** (`1351ffb1`): `TextLayoutCache` maps font size, then buffer line number, to a layout. Any change in document `cache_rev` or config clears the whole cache ([visual_line.rs L141–165, L895–913](https://github.com/lapce/floem/blob/1351ffb162faeb8be983f1301d718a0d5fb59c27/src/views/editor/visual_line.rs#L895-L913)).
  - **Interp:** keying by line number forces this all-or-nothing invalidation. It is the anti-pattern to avoid.

---

## 5. Synthesis for Tuna

Context (**Fact**, from the repository):

- `TextStore` exposes `line-at`, `line-start`, `slice` and `replace` (plugins/text-store/contract.ss).
- The buffers contract defines `change (revision start removed inserted)`, `text-changes-since`, `relocate-position`, `position-after-change`, `rebase-spans`, and separate content and decoration revisions.
- The renderer reuses HTML per *node* keyed on node revision and view state, so any edit re-renders every drawn line of the text node. It also filters `text-all-highlights` on each render (plugins/renderer/plugin.ss L54–60, L233–280).
- ADR 15 records about 10 ms of CPU and 25–36 KB per key at two view heights, and names per-item HTML reuse as a follow-up.

### (a) What a store must expose: nothing new (Inference, strongly supported)

Every surveyed system derives line invalidation from a *replaced range* plus counts, never from the data structure: Emacs's envelope, Neovim's `b_mod_*`/`on_lines`, Zed's `Edit{old,new}`, xi's `InvalLines`, CodeMirror's `ChangeSet`.

Tuna's `change` record already contains everything needed:

- **First affected line:** `L0 = line-at(new, start)`. Positions before `start` are unchanged, so the line number is the same in the old and new versions. This needs only the current version, so a gap buffer that copies on snapshot is fine.
- **Line delta:** `Δ = count(#\newline, inserted) − count(#\newline, removed)`.
- **Line patch:** old lines `[L0, L0 + nl(removed)]` are replaced by new lines `[L0, L0 + nl(inserted)]`.
- **Composition:** compose successive line patches as Zed's `Patch::compose` does, or keep Emacs's single envelope if simplicity wins.

Requirements on the buffers layer, not the store:

1. The journal must reach back to the revision the renderer last drew. When it does not (`text-changes-since` returns `#f`), fall back to "everything drawn is invalid", like xi's `set_dirty` and Emacs's `try_window_id` giving up.
2. Every content mutation must go through change records, including text-property changes. Property-only changes need a record with a range but no character change: Emacs routes them through `BUF_COMPUTE_UNCHANGED` and bumps `modiff` without `chars_modiff`.
3. Overlay and highlight changes should report a *range* as well as bumping the decoration revision, as Emacs's `modify_overlay(buf, start, end)` does. A bare counter forces "all drawn lines may be stale", which is VS Code's approach. VS Code survives it only because of its input-equality check.

### (b) A per-item render key (Inference, modelled on VS Code `RenderLineInput.equals`, xi validity bits and the Zed content key)

For a text-line item, the key has four parts:

```
item-key = ( content-stamp,              ; changes only when the line's characters change
             styles-in-line,             ; decoration spans clipped to the line, relative to line start, faces already remapped
             marks-in-line,              ; cursor columns (+ active/inactive) and selection column ranges in this line,
                                         ;   with a flag for "selected through end of line"
             view-generation )           ; face-remapping, keymap generation, kind renderer, settings that change line HTML
```

- **content-stamp.** Keep a per-view **line shadow**, a run-length list of `(count, stamp)` like xi's `LineCacheShadow`, covering only the drawn run plus some slack. Apply each line patch: stamps before `L0` stay, the replaced span gets fresh stamps, and later spans shift by Δ with their stamps intact. This is how "line identity survives inserts above" (VS Code shifts `_rendLineNumberStart`; Emacs `increment_matrix_positions`).
  - **Alternative:** hash the line text, as Zed does. That needs no shadow but costs reading every drawn line each frame. Tuna already reads every drawn line to render, so hashing is cheap, but the stamp avoids it. Tuna's existing per-line DOM ids that "stay with their text" are this same shadow and should become the stamp.
- **styles-in-line and marks-in-line.** Compare these *by value*. They are small lists, and comparing them is far cheaper than producing HTML. Making them relative to the line start keeps a shifted line's key stable.
  - **Multiple cursors:** a cursor move changes the keys of only its old and new lines.
  - **Region:** lines wholly inside a region keep the key "selected through end of line" while its far end moves.
- **Server-rendered HTML.** All surveyed editors except xi draw selection in a separate geometric layer (VS Code, CodeMirror, Zed). Tuna cannot easily do that without browser-side layout of selection rectangles, which ADR 15's "the browser measures" might permit later. Putting marks in the key gives the same locality.
- **Cache.** Map item-key to HTML for the drawn run only, with two-generation eviction ("unused last screen" is dropped, as Zed's `previous_frame` does). The cache holds HTML strings, not store data, so it is store-independent.
- **Transport.** The larger win per ADR 15's numbers is *not sending* unchanged lines. Xi's `copy`/`skip`/`ins`/`update` ops are the protocol shape. In Datastar terms, unchanged line elements keep their ids and are not re-sent. This needs a datastar-guidance check before design and was not researched here.

### (c) Asynchronous highlighting and LSP results (Inference, from xi `update_spans`, VS Code `pendingChanges`, Zed `parse_again`)

1. A highlighter job reads a `snapshot` at revision R and returns spans for a range `[a, b)` at revision R.
2. On arrival, rebase the spans with `rebase-spans (text-changes-since t R)`. Tuna already has this. If the journal does not reach R, drop the result and re-request.
3. Replace the old highlight spans *within the rebased `[a′, b′)`* only, not the whole text.
4. Invalidate items by **diffing** old and new spans per line inside `[a′, b′)`. CodeMirror's `RangeSet.compare` and the by-value `styles-in-line` key do this for free: a line whose clipped spans are unchanged keeps its key, even when the whole visible range was re-highlighted.
5. If the text moved on since R, keep the rebased result for display and schedule another run (Zed `parse_again`). Never block a frame on it, except for a small optional synchronous budget (Zed blocks up to 1 ms).
6. Request highlighting only for drawn items plus a margin, as jit-lock, Neovim's `on_line` and CodeMirror's `visibleRanges` do. Run a deferred "context" pass for lines *after* an edit, because a newly opened string changes their highlighting (jit-lock-context). A text patch alone never marks those lines dirty; only the later highlight diff does.

### (d) Pitfalls

- **Positional keys (Fact, Lapce).** Keying a cache by line number forces clearing it on every edit. Shift stamps through line patches instead.
- **Decoration-counter granularity (Fact, Emacs and VS Code).** A global overlay or decoration counter disables the cheap paths: Emacs gives up `try_window_id` when overlays changed, and VS Code marks every line maybe-invalid. Ranges plus value comparison avoid this.
- **Bulk edits and keyboard macros (Interp).** Thousands of change records between frames should compose into one patch. Use a cap, such as more changed lines than drawn items, past which the renderer just invalidates the run. Emacs's O(1) envelope is the safe default. Exact multi-range patches (Zed) pay off only when edits are scattered across the drawn run, as with multiple cursors.
- **Soft wrap (Inference).** Emacs, xi, Zed and Neovim compute wrapping in the core, which forces a wrap layer that translates patches (Zed's WrapMap, xi's `InvalLines`). Tuna lets the browser wrap, and items are logical lines, so wrapping never affects item keys. It affects only heights, which ADR 15 already measures. Keep it that way; do not introduce screen-row items.
- **Folding (Inference, Zed FoldMap, Neovim `wl_folded`).** A fold makes several lines one item, so line patches must be translated into *item* patches by a layer that owns folds. That layer emits its own patch when a fold opens or closes, like Zed's `FoldEdit`. The render key for a fold item includes the fold's identity and summary, not the hidden lines' stamps.
- **Huge lines (Fact: Emacs `long-line-threshold` 50,000; Zed `MAX_LINE_LEN`; VS Code `stopRenderingLineAfter`).** One logical line as one item means a multi-megabyte item, and one key press re-renders all of it. Tuna needs either truncation with an explicit marker or sub-line items (chunks of N characters as items) for lines over a threshold. Highlighting must also be narrowed around the visible part, as Emacs's long-line narrowing does.
- **Huge files (Fact: xi `PRESERVE_EXTENT`; VS Code renders only the viewport).** The shadow and cache must cover only the drawn run and its slack, never all lines. The renderer's current filter over `text-all-highlights` is O(all highlights) per render. Highlights need an interval index queried by the drawn range (VS Code's interval tree, CodeMirror's chunked `RangeSet`).
- **Multi-line constructs (Fact, jit-lock).** An edit's effect on highlighting extends past its changed lines. Correctness depends on the context pass in (c), not on the text patch.
- **Cursor in point-only commands (Fact, Emacs `try_cursor_movement`).** With marks in the key, moving point re-renders two lines. The node-level revision must not change on point motion, or the item cache is bypassed above it.

## Contradictions

- **Content-hash keys versus identity or stamp keys.** Zed and Emacs `row_hash` compare content; VS Code, xi and Neovim track positional identity plus invalidation flags. Both work. Hashing is robust to missed invalidations but costs reading the text; stamps are O(1) but rely on complete change reporting.
- **Where selection lives.** VS Code, CodeMirror and Zed use a separate layer; xi uses line `cursor` fields plus annotations; Emacs uses overlay faces in the glyph rows. For a server-rendered HTML screen, the in-line approach (Emacs and xi) is the natural fit unless geometry moves to the browser.

## Missing evidence

- No measurements of Tuna per-item reuse yet. The gains are inferred from ADR 15's per-screen numbers.
- Datastar's ability to patch only changed line elements by id within a morphed run, and whether removed or inserted siblings need explicit ops, was not researched. Use the `datastar-guidance` skill.
- Neovim tree-sitter highlighter internals (asynchronous parse and redraw after parse) were not read; only the decoration-provider contract was.
- I did not verify whether Emacs suppresses redisplay during keyboard-macro execution.
- The Emacs permalinks assume that commit `541f693…` is on the GitHub mirror; this run did not check.

## Sources

Kept:

- Emacs `src/xdisp.c`, `src/dispnew.c`, `src/buffer.h`, `src/buffer.c`, `src/insdel.c`, `src/textprop.c`, `lisp/jit-lock.el`, `lisp/simple.el` @541f693: the canonical incremental redisplay, read locally.
- Zed `display_map.rs`, `wrap_map.rs`, `text.rs`, `patch.rs`, `anchor.rs`, `line_layout.rs`, `element.rs`, `language/buffer.rs`, `syntax_map.rs` @574df44: layered patches and the content-addressed cache.
- VS Code `viewLayer.ts`, `viewLine.ts`, `viewLines.ts`, `selections.ts`, `textModelTokens.ts`, `intervalTree.ts`, `documentSemanticTokens.ts` @4aa4e29: render-input equality and late-token rebasing.
- Xi `frontend-protocol.md`, `line_cache_shadow.rs`, `view.rs`, `editor.rs` @a2dea30: the core/front-end line-cache protocol, closest to Tuna.
- Neovim `buffer_defs.h`, `change.c`, `grid.c`, `drawscreen.h`, `api.txt` @d714648: line-envelope redraw, buffer-attach events, decoration providers.
- CodeMirror view @fbff59b, state @9c80127, language @8e97000: decoration diffing through `RangeSet.compare`, tile reuse, visible-range highlighting.
- ProseMirror view @ca4c78e: node and decoration identity reuse.
- Helix @ba40e54, Floem/Lapce @1351ffb: contrasting minimal approaches.

Deprioritised: blog posts and secondary write-ups (Zed's "rope and SumTree" blog and VS Code's text-buffer blog), because the primary code was available and pinned.

## Next steps

1. A Datastar check: can a screen re-send only changed line elements, plus insertions and removals, inside the drawn run? This would adapt xi's `copy`/`ins`/`skip` ops to Datastar element patches.
2. Prototype the line shadow and the item-key cache in the renderer plugin. Measure CPU and bytes per key on `*long*` against ADR 15's 10 ms and 25–36 KB.
3. Give decoration changes a range in the buffers contract, and put an interval index under highlights.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Brief with summary, per-editor findings (Emacs, Zed, VS Code, Xi, Neovim, CodeMirror 6, ProseMirror, Helix, Lapce) citing commit-pinned source lines, Tuna synthesis (a)-(d), contradictions, missing evidence and residual risks"
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "git rev-parse HEAD in /home/jay/Code/emacs and grep/sed over src/xdisp.c, buffer.h, insdel.c, textprop.c, buffer.c, dispnew.c, lisp/jit-lock.el, lisp/simple.el",
      "result": "passed",
      "summary": "Emacs claims verified against local checkout 541f693"
    },
    {
      "command": "shallow/sparse clones into /tmp/pa of xi-editor, zed, vscode, neovim, codemirror view/state, prosemirror-view, helix, floem; grep/sed of cited files",
      "result": "passed",
      "summary": "All non-Emacs code claims read at pinned commits"
    }
  ],
  "validationOutput": [
    "Each code claim was read directly in source at the commit cited; source_check was not used because the claims are code facts verified by reading the files"
  ],
  "residualRisks": [
    "Emacs GitHub-mirror permalinks assume commit 541f693 is mirrored",
    "Benefit sizes for Tuna are inferred, not measured",
    "Datastar partial-patch feasibility not researched",
    "Neovim tree-sitter async internals and Emacs kbd-macro redisplay behaviour unverified"
  ],
  "noStagedFiles": true,
  "diffSummary": "No repository changes; research artifact written only to the configured output path",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "Facts, interpretations and inferences are labelled in the text. The Tuna synthesis relies on the existing change/rebase-spans contract and found no new TextStore requirement."
}
```
