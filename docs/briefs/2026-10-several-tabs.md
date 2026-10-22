# Brief: several tabs on one editor

**Date:** 2026-10-21. **Status:** approved 2026-10-21 (owner chose mirroring). ADR 16; plan [`agents/plans/several-tabs.md`](../../agents/plans/several-tabs.md). Changes ADR 7 and ADR 10 ("one tab is assumed"), ADR 8 (input sessions become real) and ADR 15 (scroll state). Evidence: [`agents/research/per-tab/`](../../agents/research/per-tab/) (Datastar docs and Hyperlith, the Datastar Discord and Northstar, Emacs and other multi-client editors, an inventory of Tuna's state, Gerbil mechanics).

## What we're building and why

Open Tuna in a second tab, or on your phone while the laptop is open, and things break today:
- **Keys get lost.** Loading a page tells the server to start counting that page's keys from 1, so the first tab's keys arrive with numbers the server no longer expects and are held back or dropped.
- **Scrolling fights.** Each view has one scroll state; both tabs report what they see, the last report wins, and the other tab is never told to move, so it ends up looking at an empty spacer.

Both come from one assumption, made on purpose on 2026-10-14: there is only one tab. This brief replaces it with a clear rule:

> **Everything is editor state, on the server, shared by every tab and saved with your session, except a short list of per-tab things. Those also live on the server, keyed by the tab, are never saved, and are forgotten soon after the tab goes away. The browser holds nothing but its tab id.**

The per-tab list has three entries:

1. **Who the tab is, and its connection** (web transport plugin): its tab id, the numbering of its keys and clicks, and which screen it was last sent and confirmed.
2. **Keys in progress** (keys and commands plugins): a key sequence half typed (`C-x` waiting for its next key) and the last command with the key that ran it, which `C-l`, repeated undo and the goal column look at. Emacs keeps exactly these per terminal (its `kboard`).
3. **What its browser measured** (scrolling plugin): view sizes, which items are drawn, the average item height, the last visible item, and which placement it has carried out. A phone and a laptop measure different things for the same view.

Everything else is shared: buffers, text and undo, the kill ring, settings and theme, the layout and which part of it is shown, the selected view, each view's point and scroll position (the item at its top), questions being asked in the minibuffer, messages and completion.

**This is "mirror" mode, like attaching to one tmux session.** Every tab shows the same part of the layout at the same place, each laid out for its own screen. The alternative, where each tab gets its own layout and views as with `emacsclient -c`, is the one decision below.

## The picture

**Status:** planned; today there is one tab.

![What is shared, and what each tab keeps](../diagrams/tabs-shared-and-per-tab.svg)

![Two tabs scrolling and typing](../diagrams/two-tabs-scrolling.svg)

## A walkthrough: laptop, then phone

1. **You open Tuna on the laptop.** The page makes itself a random tab id, `L`, and every request it sends carries it. The server starts a per-tab record for `L`.
2. **You open the same address on your phone.** It becomes tab `P`. It shows the same views at the same items as the laptop, laid out for the phone's width. The laptop's keys keep working, because each tab's keys are numbered on their own.
3. **You scroll the laptop to section 900.** The laptop reports it; the view's scroll position becomes section 900, and the laptop's measurements are stored under `L`. The phone's next screen carries one placement, "section 900 at the top", and it jumps there. If the phone is asleep in your pocket, its stream is closed (Datastar does that for hidden tabs), and when you wake it, it reconnects and gets the newest screen, already at section 900.
4. **You press `C-x` on the phone and `b` on the laptop.** They don't combine into `C-x b`: the phone's `C-x` waits for the phone's next key, and the laptop's `b` types a `b`. Both screens show it.
5. **You type on the phone near the bottom of its screen.** The phone keeps point in view using the phone's own measurements, so the scroll position moves, and the laptop follows. Rule: **the tab you are using drives the scroll position.**
6. **You scroll both at the same moment.** The last report wins and the other tab jumps. That is the price of mirroring, the same as in tmux.
7. **You reload the laptop.** It gets a new tab id. Nothing is lost, because nothing that matters is per tab; the new page measures again.
8. **You restart Tuna.** The shared state comes back as today. There is no per-tab state to restore.

## How it fits Datastar, Tuna and Gerbil

- **Datastar.** The tab id is a plain signal in the page shell, made when the page loads, outside the part that morphs. That is the pattern of Anders Murphy (Hyperlith) and what Delaney Gillilan prescribes when per-tab state is needed: "send down a uuid signal on the page load, use that as per tab". Datastar sends it with the screen stream and `/applied` automatically; Tuna's key sender adds it to its own posts. Per-tab state is kept on the server and looked up by that id ("put your tab state in your db and look up with tab id"), not in signals. You guessed that local state lives in signals; for anything that matters, Datastar's authors say the opposite, and signals only carry the id and measured facts up, as Tuna already does. Each tab's stream draws its own screen from shared state plus its tab ("broadcast that a connection should re-render and let it generate the html from its context"; Delaney: "this is accurate"). The id is not kept in `sessionStorage`, which a duplicated browser tab copies.
- **Tuna.** The kernel does not change. A small new contract, `clients`, names the idea transport-neutrally: a **client** is one browser tab today, and could be a terminal or a desktop window later. It provides a `current-client` value, which the keys plugin binds around each command just as it already binds the key that ran it, and a hook for when a client goes away. Each per-tab entry lives in the plugin whose concept it is: the web transport, the keys and commands plugins, and the scrolling plugin. The renderer draws a screen for a given client.
- **Gerbil.** `current-client` is a parameter bound inside each command's task, so it survives a command waiting on a prompt; the research tested this. Commands keep calling `(current-buffer)` and `(point)` as today.

## A code sample (package author's view)

```scheme
;; Commands never ask which tab they came from: buffers, point and the
;; selected view are the editor's, the same in every tab.
(defcommand (upcase-region)
  "Upcase the text between mark and point."
  (upcase-text! (current-text) (region-start) (region-end)))

;; The rare plugin that keeps something per tab, as the scrolling plugin
;; does for what each browser measured, keys it by the client and drops
;; it when the client goes.
(def measured (make-hash-table-eq))                 ; client -> measurements
(add-hook! client-gone-hook (lambda (client) (hash-remove! measured client)))
(def (remember! report)
  (hash-put! measured (current-client) (report-measurements report)))
```

Names are illustrative.

## Decision for the owner

**Mirror every tab (recommended), or give each tab its own layout?**

- **Context.** ADR 13 and roadmap item 6 imagined "per-tab frames": each tab showing its own part of the layout, Emacs's `emacsclient -c` model. Your earlier attempt's rule was the opposite: "all browser tabs mirror … like attaching to one tmux session". Your first idea today was also mirroring ("send down the scroll state … so tabs stay in sync").
- **Mirror.** The per-tab list is the three entries above. One person moving between laptop and phone sees the same thing everywhere. Two people, or two visible tabs, fight over the scroll position and the selected view.
- **Own layout per tab.** The list grows by four entries:
  - the part of the layout the tab shows, and its selected view;
  - each view's scroll position;
  - the questions it asked (a prompt belongs to the tab that asked);
  - where its messages go.

  It also has a problem Emacs avoids: two tabs showing the same view share its point but not its scroll position. That needs rules of its own, and it is much more work.
- **Recommendation: mirror, now.** It matches "the vast majority is shared", fixes today's breakage with the smallest list, and keeps the door open: per-tab layouts later only move entries from the shared list to the per-tab list.

Settled without asking, because the evidence decides them:
- A reload is a new tab, as in Hyperlith.
- `C-g` stops a running command whichever tab sends it, since all tabs share one editor thread, as in Emacs.
- Per-tab state is dropped a little while after its tab's stream closes; hidden tabs close their stream, and a returning tab simply measures again.

## Limits

- **Connections:** browsers allow about six HTTP/1.1 connections to one server, so a single browser can keep about five visible Tuna tabs live. Hidden tabs don't count. HTTP/2 would remove the limit; Tuna doesn't speak it.
- **Server work:** each change is drawn once per visible tab; a tab whose screen didn't change still gets nothing.
- **Datastar bug #900:** a retried stream resends its first signals. That is harmless here, because the only signal the stream carries is the tab id, which never changes.

## New terms

- **Client:** one place a person is looking at Tuna from. Today a browser tab.
- **Tab id:** the random name a page gives itself when it loads.
- **Per-tab state:** the three entries above.
- **Mirror:** every tab shows the same part of the layout at the same place.
