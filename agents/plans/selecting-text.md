# Plan: clicking and selecting text

Owner-approved brief: [`docs/briefs/2026-10-selecting-text.md`](../../docs/briefs/2026-10-selecting-text.md) (2026-10-23). Spike pages: `/home/jay/Code/workbench-gerbil/scratch/selecting-text/` (`click.html` holds the point-to-line-and-column function). Builds on [`mouse-input.md`](mouse-input.md) (pointer events, `posn`, node keymaps) and ADR 17 (`memo`).

## Invariants

- The server processes everything; the browser only reports which line and column was pointed at, and carries out "copy this" for its own tab. The browser never names a command.
- Owner decisions (2026-10-23): the server draws the selection while dragging; Emacs region rules (transient mark: an edit or `C-g` deactivates; typing does not replace the selection) with a `delete-selection` setting, off by default, that makes typing, `DEL` and yank replace it; the clipboard uses `navigator.clipboard.writeText` only, plus the browser's `paste` event.
- The mark belongs to the view, beside the cursor (`view-point`), and stays on its character when text is inserted or deleted elsewhere, as the cursor does. Every tab shows the same selection (ADR 16).
- Clicks name a line by its item token and a column in code points; the server shifts the position to now (`relocated-position`), clamps a column past the line's end, and reports a click on a line that has gone (`report-stale-click`).
- Drawing: the region is a per-line input to the line's `memo`, like the cursor; moving the selection redraws only lines whose selected part changed. Test mode (draw twice, compare) stays green.
- Placement: the kernel is unchanged.
  - **Mark and active flag:** on the view, in the buffers contract.
  - **Drawing the region:** the renderer, with the `region` face in its `tokens.css` and `rules.css`.
  - **Region commands, shift-select and `delete-selection`:** a new `region` plugin.
  - **Kill ring and clipboard commands:** a new `kill-ring` plugin with its own contract.
  - **Shift translation (`S-<right>` falling back to `<right>`, with a flag, as Emacs does):** the keys plugin.
  - **Press, drag and release events, and `posn-point`:** the keys contract.
  - **Click and drag commands:** a new `text-mouse` plugin.
  - **Browser code:** the web plugin's `frontend/`.
- `make test` green under the memory cap; each stage checked in a real browser, with screenshots.

## Stages

1. **The selection from the keyboard.**
   - **Mark commands:** `C-SPC` (`set-mark-command`, "Mark set"), `C-x C-x` (`exchange-point-and-mark`), and `C-g` deactivates.
   - **Shift-select:** shifted movement keys (arrows, `C-S-f`, …) activate a temporary region, and unshifted movement ends it, as in Emacs.
   - **The region** is drawn in the `region` face.
   - **The kill ring:** `C-w` (`kill-region`), `M-w` (`kill-ring-save`), `C-y` (`yank`), `M-y` (`yank-pop`, only right after a yank).
   - **The `delete-selection` setting.**
   - **Package API:** `region-active?`, `region-beginning`, `region-end`.
   - **Tests:** two views on one buffer keep separate marks, and moving a selection redraws only the affected lines.
2. **Click to move the cursor.**
   - **Browser:** the `tunaPointer` action sends the line token and column for clicks inside text, using `caretPositionFromPoint` with `caretRangeFromPoint` as a fallback.
   - **Server:** `posn-point` gives the clicked position, and `<view> <mouse-1>` on text runs `mouse-set-point`, which also selects the view. A click below the last line goes to the end.
   - **Browsers:** check `click.html` in Firefox, and in Safari if available.
3. **Drag and multiple clicks.**
   - **Drag:** `down-mouse-1` sets the cursor and mark (`mouse-drag-region`). Drag reports move the cursor, one in flight at a time, each waiting for its screen as scroll reports do. `drag-mouse-1` ends the drag (`mouse-set-region`).
   - **Multiple clicks:** `double-mouse-1` selects a word, `triple-mouse-1` a line, and `S-mouse-1` extends the selection.
   - **Browser:** its own text selection is suppressed inside text.
4. **The clipboard.**
   - **Copy:** `kill-region` and `kill-ring-save` ask the tab that sent the key to copy, through a one-time instruction on that tab's next screen. Where `navigator.clipboard` is missing (plain HTTP) or refuses, the echo area says so.
   - **Paste:** the page's `paste` event sends its text, which is inserted and pushed onto the kill ring. The keydown handler stops cancelling the paste chords: Cmd+V, Ctrl+Shift+V and Shift+Insert. Ctrl+V stays `C-v`.
5. **Records,** done by the primary agent: the overview, the Emacs table rows and the two divergences (the mark belongs to the view; shift-click extends), an ADR 13 amendment for the mark, and the roadmap.

## Not in this plan

- auto-scrolling while dragging past a view's edge;
- touch drag-selection;
- rectangles;
- several cursors;
- middle-click paste;
- dragging text to move it;
- Firefox paste (it needs the hidden text field planned for phones);
- clipboard over plain HTTP.
