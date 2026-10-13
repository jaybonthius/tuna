# Brief: buffers, views and layout

**Date:** 2026-10-13. **Status:** proposed; waiting for your approval. Research: `agents/research/layout-state/` (how to store the trees, with Gerbil measurements) and `agents/research/window-management/`. Your vision: `docs/ideas/window-management.md`, "One tree all the way down".

## What this is and why

Everything on Tuna's screen should be one tree you can see and move around in. Buffers are pieces of UI. A file being edited is a buffer, and so are a magit status page, a sidebar of buttons pinned to the left as in VS Code, the minibuffer and the echo area. A layout of containers arranges them on screen: splits, tabs and, later, scrolling strips.

Today Tuna has one window filling the screen, and the minibuffer, echo area and help panel are drawn as special cases. The buffers plugin is also replaceable only on paper. A different buffers plugin could change where the list of buffers is kept, but editing, undo and the record of changes are fixed code that every plugin calls directly (audit finding P1-1).

This work does three things:
- settles the names;
- makes buffers truly replaceable;
- builds the layout, so a VS Code-style screen can be assembled from ordinary buffers.

## The picture

![Who owns what you see](../diagrams/screen-owners.svg)

You see one tree, but two plugins own the pieces in memory:
- **The layout plugin owns the layout.** That's the containers and the views in them. The layout is small, about 50 parts, so it's a frozen value: each change makes a new one that shares the unchanged parts. Snapshots are free, which later gives you saved arrangements and an Emacs `winner-mode`-style "undo my last layout change".
- **Buffers plugins own buffers.** A rich buffer can have 100,000 parts, so buffers are changed in place. Each change stamps the changed part, and the parts above it, with a new revision number.
- **The renderer stitches the two together.** It walks the layout, and inside each view it walks that view's buffer. Every redraw sends the whole visible screen, which is your immediate-mode rule. A part whose revision hasn't changed reuses the HTML it produced last time instead of computing it again.

Two owners keep things replaceable. One buffer can appear in several views, a buffer exists when it isn't shown, and either plugin can be swapped without disturbing the other.

## A walkthrough

![The layout in this walkthrough](../diagrams/layout-example.svg)

1. **You turn on a "buffer list" plugin.** It makes a buffer, `*buffers*`, holding one button per buffer. It asks the layout to show that buffer on the left side. The layout plugin builds a new layout in which a left-to-right container holds the new view (20% wide) and your existing tabs.
2. **The next redraw** walks the layout from the top. At the `*buffers*` view, it walks that buffer's buttons. Nothing in `notes.txt` changed, so its HTML is reused, and the whole screen is sent to the browser.
3. **You switch to the sidebar and back.** The left-to-right container remembered that you were last in the tabs, and the tabs container remembered `notes.txt`. Focus returns to the right place because focus is stored in the layout.
4. **You open a new buffer.** The buffer-list plugin's hook adds a button. That stamps a new revision on `*buffers*`, so only the sidebar's HTML is recomputed. The whole screen is still sent.
5. **A command asks a question.** The minibuffer view appears at the bottom of the tree. It's an ordinary view of the minibuffer's buffer, not a special case, and it goes away when you answer.
6. **You turn the buffer-list plugin off.** Its buffer is removed, and its view closes because it was made only for that buffer. The layout goes back to the tabs alone.

## A code sample (package author's view)

The buffer-list sidebar from the walkthrough:

```scheme
(defplugin (buffer-list-sidebar ctx)
  "Lists buffers in a view pinned to the left."
  requires: [buffers-service layout-service]
  (let (sidebar (new-buffer "*buffers*" (new-node 'button-list)))
    (def (refresh!) (set-node-children! (buffer-root sidebar)
                                        (map buffer-button (buffer-list))))
    (refresh!)
    (context-add-buffer! ctx sidebar)                       ; removed when the plugin turns off
    (context-add-hook! ctx buffer-list-update-hook 'sidebar refresh!)
    (display-buffer sidebar side: 'left size: 1/5)))        ; a hint the layout plugin interprets
```

The Emacs version is `(display-buffer buf '(display-buffer-in-side-window (side . left) (window-width . 0.2)))`. Treemacs and speedbar draw their sidebars this way, so a port changes names, not structure. A layout plugin with no idea of sides puts the view wherever it chooses, so the hint never breaks. Names are illustrative.

## How it gets built

Each stage runs in the browser:
1. **Names and the buffers contract.** The renames happen first. Then editing, undo, the record of changes, highlights and node creation go through the buffers contract, instead of being fixed code. Swapping buffers plugins carries your buffers over instead of starting from a fresh `*scratch*`. A small second buffers plugin, used only in tests, proves the contract. The screen looks the same as today.
2. **The layout plugin.** It replaces the one-window plugin:
   - "fit" and "tabbed" containers, with focus remembered in each container;
   - split, close, and move between views (`C-x 2`, `C-x 3`, `C-x 0`, `C-x o`);
   - `display-buffer` with side hints;
   - the layout is saved across restarts as plain data, and each plugin rebuilds its own buffers from its own state.
3. **Everything on screen is the layout.** The minibuffer, echo area and help become views. The renderer draws only the layout tree, and it reuses the HTML of unchanged parts.

**Not in this work:**
- scrolling containers, and drawing only what's in view (their own brief, with the research on how the browser reports what's visible);
- clicking buttons;
- files;
- several browser tabs showing different parts of the layout.

So that drawing only what's in view can come later without changing the contract, any tree can hand the renderer just children 200 to 260.

The kernel gains nothing. There's no shared tree library yet, because the two trees want different storage. After approval, the names and the divergences from Emacs go into an ADR, `docs/emacs-equivalents.md` and the overview's glossary.

## Already settled by you

- Rendering is immediate mode: whole screen, every redraw, never patches of single parts.
- A buffer is generically a piece of UI. Saving to a file belongs to text linked to a file, not to buffers.
- Each container remembers its last-focused child.
- After a restart, each plugin's state is saved and the UI is rebuilt from it, never the UI itself.
- The minibuffer and echo area are ordinary parts of the tree.

## Decisions for you

**1. What do we call the places that show buffers?**
- **Context:** today Tuna has both a *window* (a slot in the layout) and a *view* (a buffer as one place shows it, with its own cursor and scroll position). Each window holds exactly one view for life, so they are really one thing. In a browser app, "window" also means the browser window.
- **Options:**
  - (a) **one concept, called a *view*;** "window" goes away;
  - (b) a *pane* that holds a view (two concepts);
  - (c) keep *window*, as Emacs does.
- **Recommendation: (a).** An Emacs window is exactly "a buffer shown in one place, with its own cursor, scroll position and history of buffers shown there". A view would be the same thing, so porting is a mechanical rename (`selected-window` → `selected-view`, `window-point` → `view-point`). VS Code uses the same word: its sidebar parts are "views" inside "view containers".
- **The other names:**
  - **Keep *buffer*.** Emacs buffers were never only files: dired, magit and `*Messages*` are buffers. Alternatives like *surface* or *panel* would cost every porter a translation and gain little.
  - **Keep *frame* for what one browser tab shows.** *Tab* is already taken by tabbed containers.

**2. One tree on screen, two owners in memory?**
- **Options:**
  - (a) the layout plugin and buffers plugins each own their part, and the renderer presents them as one tree;
  - (b) literally one stored tree, holding containers and buffer contents together.
- **Recommendation: (a).** With (b), a buffer shown twice would have to be copied or shared awkwardly, a hidden buffer would have no place in the tree, and swapping the layout plugin would mean handing over every buffer's contents. The research also found the two trees need different storage to stay fast: frozen for the layout, changed in place for buffers. You still see, draw and navigate one tree.

## New terms

- **Layout:** the tree of containers and views that arranges the screen; owned by a replaceable layout plugin.
- **Container:** a part of the layout that arranges its children. *Fit* splits the space between them. *Tabbed* shows one at a time. *Scroll*, a strip wider than the screen, comes later.
- **View:** one place in the layout showing one buffer, with its own cursor and scroll position. It replaces "window".
- **Frame:** what one browser tab shows, a part of the layout. Today there is one.
- **Revision number:** a counter stamped on a part of a buffer, and on the parts above it, whenever it changes. Unchanged revision means unchanged HTML.
