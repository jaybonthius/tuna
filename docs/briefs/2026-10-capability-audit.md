# Brief: checking the architecture against everything Emacs can do

**Date:** 2026-10-11. **Status:** done; one research item remains open (layout, below).

## What we did and why

Before building anything, we checked that our seven architecture decisions don't block something you'll want later. Five research agents went through Emacs in parallel: the command loop and keymaps; buffers and display; the Lisp runtime (variables, advice, loading, files, processes); real packages as stress tests (Org, Magit, Dired, Evil/Meow, Vertico/Consult/Embark, Eglot, terminals, and more); and things beyond Emacs (browser limits, security, multiple clients, prior art such as VS Code, Zed, Lem, Nyxt, Acme). They rated several hundred capabilities. Most already fit. About twenty didn't, and those are now fixed in the decisions.

## What we found, and what changed

The ones that would have hurt most:

1. **`C-g` couldn't stop a stuck command.** Keys waited in line behind the running command, including `C-g`. Now Tuna checks for `C-g` the moment it arrives and interrupts whatever is running, even code that never checks for it. That's better than Emacs.
2. **Two windows on one file would have shared one cursor.** The cursor belonged to the buffer. Now it belongs to a **view**: the buffer as shown in one window (diagram below).
3. **No way to change a setting temporarily.** Emacs code does `(let ((case-fold-search nil)) …)` everywhere. Tuna now has `with-settings`, which does the same thing but only for the command that uses it, so two commands paused at prompts can't see each other's temporary settings.
4. **Copy and paste would have lost colors, links and keymaps.** Text properties only existed inside buffers. Now "styled text" (a string with properties) is what copying, pasting, completion lists, messages and the mode line pass around, as in Emacs.
5. **Anyone could have sent commands to Tuna.** Any web page you visit could have reached it and run shell commands as you. Now every connection needs a secret token from the link Tuna prints at startup.
6. **Command composition had no home.** "What was the last command", `C-u`, keyboard macros, modal editing, which-key, transient menus, and pre/post-command hooks now have a defined place: an **input session** and a layered keymap stack.
7. **Turning off one plugin could break another's key binding.** Bindings and settings are now labeled with the plugin that made them; turning a plugin off removes only its own.
8. **Highlighting could flicker forever while you type.** Results computed for an old version were thrown away. Now they're shifted past what you typed and applied.
9. **Plus:** remote files (TRAMP-style) have a seam; files that aren't valid UTF-8 survive a save byte-for-byte; plugin state survives a reload; inactive plugins still show up in `M-x` and help; packages can advise each other's functions.

Everything is recorded in the decision records, and every place Tuna deliberately differs from Emacs is in [Tuna and Emacs](../emacs-equivalents.md).

## The picture

**Status:** planned.

![Two windows on one file](../diagrams/who-owns-what.svg)

## Walkthrough

You split the window (`C-x 3`) on `main.ss`. In the left window you edit line 10; in the right you're reading line 400.

- Each window has its own **view**, with its own cursor and scroll position.
- Both views point at the same **buffer** (one name, one mode, one set of local settings) and the same **text** (one copy of the characters and one undo history).
- When you type on line 10, the right window's cursor shifts down with the text, just as in Emacs.
- Later, an "indirect buffer" (Org's edit-subtree, for example) is simply a second buffer pointing at the same text.

## What it looks like to write code

Illustrative; names may change when built.

```scheme
#lang :tuna

(defcommand (search-exact (word : :string))
  "Search forward for WORD, ignoring case-folding for this search only."
  (interactive (list (read-string "Word: ")))
  (with-settings ((case-fold-search #f))   ; only this command sees the change
    (search-forward word)))

(keymap-set global-map "C-c s" search-exact)
```

## Decisions you made

- **Positions count from 1**, because positions are human-facing and that's the better design, not just for compatibility.
- **Ordinary browser tabs are first-class**, for remote development. Keys the browser keeps for itself (`C-w`, `C-n`, `C-t`) just aren't available there; you rebind them.
- **No fixed-width grid.** Buffers can mix monospace and proportional text, even in one buffer, so the browser owns layout.

## Still open: how the server learns about layout

Because the browser lays out text, the server doesn't know where lines wrap or how much fits in a window. Commands like "next line" on a wrapped line, "scroll a page", or placing a popup need that. Before we build windows and scrolling, we'll research three options, possibly combined:

- the browser attaches layout facts (visible range, wrap points near the cursor) to each event it sends;
- a command pauses and asks the browser to measure, like asking a question;
- Datastar Rocket components handle purely local behavior (scrolling, wrapping, maybe some cursor motion) from data the server sends, and report back.

The Datastar docs, including Rocket's, are now vendored in the repo for this.

## New terms

- **View**: a buffer as shown in one window, with its own cursor and scroll position.
- **Text**: the characters, their properties, and undo history; can be shared by several buffers.
- **Screen**: one complete drawing of a browser tab, sent as HTML. (We renamed this from "frame", which now means what it means in Emacs.)
- **Task**: anything running on the editor thread that may pause, such as a command waiting at a prompt or a timer.
- **Input session**: where Tuna keeps "the last command", the pending prefix keys, `C-u`, and keyboard-macro state.
- **Styled text**: a string carrying properties such as colors, links and keymaps.
