# Brief: clicking and selecting text

**Date:** 2026-10-23. **Status:** proposed, awaiting the owner's approval. Builds on [mouse input](2026-10-mouse-input.md) (clicks as keys; its "clicking and selecting inside text comes later" is this). Evidence: a Chrome 146 spike (below), Weevil's paste work (`~/Code/weevil/plans/archive/clipboard-paste-plan.md`), the `shux` terminal spike's clipboard element (`~/Code/shux/spikes/libghostty-terminal/web.go:806`), and Emacs's `lisp/mouse.el` (commit `541f693ca2e`).

## What we're building and why

Standard editor mouse and selection behavior, run by the server like everything else:

- **Click** in text and the cursor moves there.
- **Drag** to select; double-click selects a word, triple-click a line, shift-click extends the selection.
- **Select from the keyboard** the Emacs way (`C-SPC`, `C-x C-x`, `C-g`), plus shift with the arrow keys.
- **Cut, copy and paste:** `C-w`, `M-w`, `C-y` and `M-y` with a kill ring, and your computer's clipboard on both sides.
- **A `delete-selection` setting** (off by default, as in Emacs): typing replaces the selection, as in other editors.

The browser only finds out which character you pointed at. Everything else happens on the server, and only the lines that changed are drawn again.

**No id on every character.** Every line on screen already carries an id (`data-item`, as scrolling uses). The browser can ask which character sits under the pointer (`caretPositionFromPoint`), so a click becomes "line `7.120.42`, column 15", counted from the line's start. The line id records where the line started and at which revision, and Tuna can already shift a position from an older revision to now. So a click made on a screen that has since changed still lands on the character you clicked.

**The spike** (Chrome 146; pages kept in `scratch/selecting-text/`) used a page shaped like Tuna's lines: colored runs, the cursor element, a line wrapping over three rows, tabs, emoji, Chinese, an accented letter built from two characters, and a proportional font. It clicked the left and right halves of every character, plus past each line's end: 453 of 457 checks landed exactly. The four misses are not errors:
- **The two-character accented letter:** the browser won't put the caret between a letter and its accent.
- **The cursor drawn after a line's end:** a click there reports one column too many, which the server clamps.

The check gave the same result with the browser's own selection turned off. Firefox and Safari still need the same check (stage 2).

## The picture

**Status:** both diagrams are planned; nothing here is built.

![Pressing on a word and dragging](../diagrams/selecting-text-mouse.svg)

![Copy and paste](../diagrams/selecting-text-clipboard.svg)

**The clipboard, checked:** browsers let a page write to the clipboard directly (`navigator.clipboard`) only on HTTPS or `localhost`. On `127.0.0.1` it exists. On `http://100.111.127.122` it doesn't, which I checked in Chrome. That's why the earlier "patch in an element that copies" approach worked locally.

The older copy command, `document.execCommand('copy')`, works on any address, as long as it runs within about 5 seconds of a key press. On the Tailscale address in Chrome it copied 30 ms after a key press, and refused 7 seconds after one and with no key press. So the "copy this" instruction uses `navigator.clipboard` where it exists and `execCommand` otherwise. **No HTTPS is needed.**

## A walkthrough

1. **Press on "hello".** You press the mouse on "hello" in `main.ss`, line 7, while a slow command is still running. The browser sends "press, line `7.120.42`, column 15, screen 812".
2. **The cursor moves there.** By the time the editor gets to the press, a key you typed just before has added a character earlier on that line. The editor shifts the spot by one and puts the cursor and the mark on "h" of "hello". It also selects that view, as a click does today.
3. **Drag down.** You drag to line 9. Each move report waits for the previous screen, as scroll reports do, so the selection never falls behind by more than one screen. Lines 7–9 show the selection.
4. **Copy.** You let go and press `M-w`. The text goes on the kill ring, and the next screen tells this tab, and only this tab, to copy it. It's now on your computer's clipboard.
5. **Paste elsewhere.** In another app you press Cmd+V, and the text is there. Back in Tuna, Cmd+V inserts whatever is on the clipboard and adds it to the kill ring; `C-y` would yank Tuna's own last kill.

## A code sample (package author's view)

A command that uses the selection, and a package making clicks in its own buffer jump somewhere:

```scheme
(define-command ctx (upcase-region) "Upcase the selected text."
  (when (region-active?)
    (upcase-text! (region-beginning) (region-end))))

(keymap-set-in ctx occur-line-keymap "<mouse-1>" 'occur-click)
(define-command ctx (occur-click) "Jump to the match whose line was clicked."
  (let (p (event-start (last-command-event)))
    (goto-occurrence (posn-point p))))   ; a buffer position, already shifted to now
```

In Emacs these are `use-region-p`, `region-beginning` and `(posn-point (event-start e))`: ported code changes names, not structure. Names are illustrative.

## How it gets built

Each stage runs in the browser. Nothing goes into the kernel: clicks already arrive as events, and every piece below is a plugin or a contract.

1. **The selection from the keyboard.**
   - The mark and region, with the mark kept beside the cursor on the view.
   - `C-SPC`, `C-x C-x`, `C-g`, and shift with movement keys.
   - The region drawn in the `region` face; only lines whose selected part changed are redrawn.
   - The kill ring: `C-w`, `M-w`, `C-y`, `M-y`.
   - The `delete-selection` setting.
2. **Click to move the cursor.** The browser finds the line and column. `mouse-1` on text runs `mouse-set-point`, and `posn-point` gives any command the clicked position. Clicks below the last line go to the end. A click on a line that no longer exists is reported as stale, as buttons are today. Also check the spike page in Firefox and Safari.
3. **Drag and multiple clicks.** These follow Emacs: `down-mouse-1` sets the cursor and mark (Emacs `mouse-drag-region`), drag reports move the cursor one at a time, and `drag-mouse-1` finishes (`mouse-set-region`). Also double-click for a word, triple-click for a line, and shift-click to extend.
4. **The clipboard.** Copying commands also copy to the clipboard of the tab you pressed the key in; if the copy is refused, the echo area says so. The browser's paste key inserts the clipboard's text: Cmd+V on a Mac. On Linux and Windows, Ctrl+V stays Emacs's `C-v` (scroll), so the paste keys there are Ctrl+Shift+V and Shift+Insert, to be checked.

   **Known limit, from Weevil:** Firefox sends no paste to a page with no text field focused, so Firefox paste waits for the hidden text field planned for typing on phones.

**Not in this work:**
- scrolling by dragging past a view's edge;
- touch drag-selection (a tap still moves the cursor);
- rectangle selection;
- several cursors;
- middle-click paste;
- dragging text to move it.

**Differences from Emacs,** to record in the Emacs table and an ADR:
- **The mark belongs to the view, like the cursor.** In Emacs it belongs to the buffer, while each window has its own cursor.
- **Shift-click extends the selection.** In Emacs it opens a font menu, and `mouse-3` extends.

## Decisions for you

None left. You decided that the server draws the selection while you drag, and that Emacs's rules apply, with `delete-selection` as a setting. The clipboard question is answered above: no HTTPS needed.

## New terms

- **Mark:** the other end of the selection; the cursor is one end and the mark the other.
- **Region:** the text between the mark and the cursor; Emacs's name for the selection. It is *active* while it is shown and commands act on it.
- **Kill ring:** Tuna's own list of recently cut or copied texts; `C-y` inserts the latest and `M-y` steps back through older ones.
