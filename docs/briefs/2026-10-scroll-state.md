# Brief: scroll state

**Date:** 2026-10-17. **Status:** approved 2026-10-17 (the owner delegated the details: "keep this philosophically beautiful"). Supersedes the spacer and height-guessing parts of [scrolling a view](2026-10-scrolling.md); the browser still scrolls natively. Plan: [`agents/plans/scrolling.md`](../../agents/plans/scrolling.md). Evidence: [`agents/research/scrolling/`](../../agents/research/scrolling/README.md).

## What this is and why

A buffer can be gigantic, and Tuna must not choke on it: it draws only what is near what you are looking at. The first version did that by putting empty blocks where the undrawn content would be, so the browser's scrollbar covered the whole buffer. Those blocks needed heights nobody knew, so the server guessed, and every scrolling bug since came from the guesses.

This version guesses nothing. Three ideas:

- **A scroller holds only what is drawn.** As you near either end, the server draws more ahead of you and drops what is far behind. The browser keeps what you are looking at still while that happens. This is how every phone app's endless feed works, so native scrolling, flinging and momentum all just work.
- **Positions are measured, never computed.** Only the browser knows how big things are. It reports what it measured; the server never stores or estimates a size.
- **Scroll state is about content, not pixels.** It is "this item is at the top, 8 px of it above the edge". The scrollbar shows your position in the content (item 25,000 of 50,000), as Emacs's scroll bar shows your position in the buffer.

## The words

- A **scroller** is any part of the screen whose content can outgrow its box. Today: each view. Later: a node that scrolls in its own box (a long sidebar list) and the layout's scroll containers (strips of views). Each scroller scrolls on its own; one can sit inside another.
- Its **items** are what it lays out one after another. A kind of node says what its items are: a text node's are its lines, a list's are its rows, a container's are its children's items in turn; any other node is one item. Every item has an identity that survives edits around it: a node, or a place in a text that moves with edits as point does. The scroller itself knows nothing about lines, rows or nodes.
- **Scroll state**, for each scroller, is the item at its top edge and how many pixels of it are above that edge, as the browser measured. The server owns it, commands change it, and it is saved with your session.

## The picture

**Status:** planned; replaces the drawing in Tuna today.

![What a scroller holds](../diagrams/scroller-items.svg)

![How scroll state moves](../diagrams/scroll-report-and-placement.svg)

Two flows, and only two:
- **You scroll** (steps 1–6). The browser moves the pixels. When fewer than half of `drawn-above` or `drawn-below` pixels remain drawn ahead of you, or far more than that are drawn behind, it reports what it measured: the item at the top and its offset, the last visible item, and the pixels drawn above and below. The server updates scroll state and draws more or fewer items. How many items to add is only a fetching step, worked out from what the last report measured; where anything goes is always what the browser measured.
- **Tuna moves the view** (steps 7–10): a refresh, a restart, `C-v`, going to point, dragging the scrollbar. The server draws around the target and asks the browser once to put that item at the top (or centre, or bottom). The browser finds the item, measures it, and moves it there; its next report confirms. Reports sent before that placement are ignored.

## A walkthrough

1. **You open a 50,000-line log.** Scroll state: line 1, 0 px. Tuna draws lines until the browser reports about 20,000 px drawn below; the scrollbar's thumb is a sliver at the top.
2. **You fling down.** The browser scrolls with native momentum. Each report moves scroll state to the line now at the top; Tuna draws ahead and drops behind, and the line you are reading never moves. A very hard fling could reach the end of what is drawn and stop there until more arrives, about a network round trip; with 20,000 px drawn ahead that is rare.
3. **You drag the scrollbar's thumb to the middle.** Tuna places line 25,000 at the top. Nothing is drawn there yet, so for one round trip you see the old lines, then the new ones.
4. **You refresh the page.** The new page arrives already drawn around line 25,000, with one placement: line 25,000, 8 px above the top. You are where you were. The same after restarting Tuna.
5. **You press `C-v`.** The last line the browser reported visible is placed at the top. `M->` places the last line at the bottom; `C-l` places point's line at the centre.
6. **Someone inserts ten lines above you.** Scroll state names a place in the text, which moves with the edit, so you keep seeing the same text.
7. **A sidebar shows 10,000 search results in its own scrolling box.** It is a second scroller: its items are the result rows, its scroll state is a row, and scrolling it never touches the log's view.

## A code sample (package author's view)

```scheme
;; Search results scroll in their own box; each result is one item.
(context-define-node-kind! ctx 'search-results
  "Matches for a search, one row each."
  items: node-children        ; what this kind's items are
  scrolls?: #t)               ; a scroller of its own

;; C-v, in the scrolling plugin.
(defcommand (scroll-up-command)
  "Scroll forward by nearly a screen."
  (let (v (selected-view))
    (place! v (view-last-visible-item v) 'top)))
```

Emacs's `C-v` is `(set-window-start (selected-window) (window-end))`. The difference: `view-last-visible-item` is what the browser measured, not something the server computed. Names are illustrative.

## What goes away and what stays

Gone: the empty blocks standing in for undrawn content, every height guess, the measured average line height. Kept: native scrolling, drawing only near the view, one report in flight at a time, a screen sent only once the page applied the last, and the `drawn-above` and `drawn-below` settings, now in pixels the browser measures.

## Decisions

None open. Two trade-offs, accepted: the scrollbar is Tuna's own, not the browser's (as in the prototype the owner liked); and a fling can stop briefly at the end of what is drawn. Two divergences from Emacs, to record in an ADR and the equivalents table: the browser moves the pixels, and the scrollbar counts items, where Emacs counts characters.

## New terms

**Scroller**, **item**, **scroll state**, as above. **Placement**: the server asking the browser, once, to put an item at the top, centre or bottom of a scroller.
