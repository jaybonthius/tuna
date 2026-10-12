# How Tuna works

**Status (2026-10-11):** stages 1 and 2 of the architecture skeleton are built: the small engine (plugins with receipts, services, the editor thread with `C-g`), the token-protected browser connection, key handling, the HTML renderer, buffers as node trees with an editable text node, a swappable text store (a rope by default), basic editing with undo, and the echo area. There is one window, no prompts, no files, and no saving yet. Sections marked *planned* describe the design for what isn't built. This page is updated as each piece is built, so it always describes what's real. The detailed reasoning lives in the [architecture decision records](../agents/adr/README.md).

## The idea

Tuna is an Emacs-like environment written in Gerbil Scheme. It runs as a server, on your machine or a remote one, and you use it through an ordinary browser tab. The browser acts like a terminal: it sends every key press to Tuna and shows whatever screen Tuna sends back. All the real work, and all the state, lives in Tuna. Only someone holding the secret link Tuna prints at startup can connect, because a connected tab can do anything your shell can.

Tuna is Emacs-inspired, not an Emacs clone. [Tuna and Emacs](emacs-equivalents.md) lists what corresponds to what, and every place Tuna deliberately does something differently.

Almost everything in Tuna is a plugin, including basic editing. You can turn plugins off, reload them, or swap out core parts (even the data structure that holds text) while Tuna is running.

## A small engine and a lot of plugins

Tuna itself is a small, fixed engine. It loads plugins, keeps track of what each one added so it can be undone, connects plugins to the services they need, and enforces the rules for who may change editor state and when. Everything that makes Tuna an editor (buffers, the text store, key handling, the minibuffer, windows, how screens are drawn, saving your session) is a plugin. Tuna's own versions of those get no special treatment, so anything they can do, a replacement can do too.

Some plugins can be swapped while Tuna runs: the text store, the window manager, the renderer, and nearly everything else. A few are chosen at startup and need a restart to change, such as how keys are resolved and how settings are looked up, because swapping them mid-session would pull the rug out from under running commands. If a plugin combination breaks things, a safe mode starts Tuna with only its standard plugins, and `describe-services` shows which plugin is filling each slot.

## The big parts

![The big parts of Tuna](diagrams/big-picture.svg)

Follow the numbers for the main loop:

1. The **keyboard plugin** in your browser sends each key press to Tuna.
2. The **web server** says "got it" immediately and puts the key in a queue, in order.
3. The **editor thread** takes the next key, finds the command bound to it, and runs that command. The command changes the **editor state**: buffers, windows, the minibuffer. The editor thread is the only thing allowed to change editor state, so commands never trip over each other.
4. When there's no more input waiting, the editor thread draws a new **screen**: everything the tab shows, as HTML.
5. The web server sends that screen to every open browser tab.

Around that loop:

- **Plugins** add the commands, key bindings, and hooks the editor uses.
- **Replaceable services** are the swappable parts, such as how text is stored and how screens are drawn.
- **Background jobs** do slow work like syntax highlighting without holding up typing.
- **Disk** stores your files plus Tuna's own backups, explained [below](#where-things-are-saved).

## What happens when you type a letter

**Status:** planned.

![Typing a letter](diagrams/typing-a-letter.svg)

The important part is the split between the fast path and the slow path. The letter shows up after one command and one redraw (steps 1–8). Highlighting runs separately and arrives a moment later (steps 9–12).

Every change bumps the buffer's version number. The highlighting job works on version 42. If you've typed more by the time its colors come back, Tuna keeps a short record of every change since version 42 and shifts the colors past what you typed, so they still land on the right characters. In Emacs, slow work like this freezes the whole editor. In Tuna it can't, because it never runs on the editor thread.

And if a command itself gets stuck, say in an endless loop, pressing `C-g` stops it. Tuna watches for `C-g` the moment it arrives, instead of waiting in line behind the stuck command. It first asks the command to stop, which well-behaved code notices right away; if the command doesn't respond quickly, or you press `C-g` again, Tuna stops it forcibly. Emacs can only stop code that remembers to check for `C-g`.

## How a command can ask you a question

**Status:** planned.

![A command asking a question](diagrams/asking-a-question.svg)

A command can stop in the middle and wait for an answer, just like in Emacs. While it waits, the editor keeps handling your keys and sends them to the minibuffer. When you press Enter, the command continues where it left off. For the person writing the command, it reads top to bottom:

```scheme
(defcommand (rename-buffer)
  "Give the current buffer a new name."
  (let (name (read-string "New name: "))   ; waits here; the editor keeps running
    (set-buffer-name! (current-buffer) name)))
```

Names in code samples are illustrative; the exact API will be settled when it's built.

## Plugins: how things get added and removed

![How a plugin adds and removes things](diagrams/plugins.svg)

When a plugin is turned on, everything it adds goes through its **receipt**: a running list of what it added and how to undo each item. Turning the plugin off walks the receipt backwards and removes everything. Each key binding or setting a plugin makes is labeled with that plugin, so turning one plugin off never erases a binding another plugin made for the same key. Reloading a plugin is just "save its state, off, load the new code, on, restore its state". That means you can fix a plugin and reload it without restarting, and you never end up with leftover keys or hooks from an old version. Emacs has no equivalent; its `unload-feature` is best-effort.

A plugin file looks like ordinary Emacs-style code. Everything at the top level belongs to that file's plugin:

```scheme
#lang :tuna

(defcommand (forward-char (count 1))
  "Move the cursor COUNT characters forward."
  (goto-char (+ (point) count)))

(keymap-set global-map "C-f" forward-char)

(add-hook after-save-hook 'announce
  (lambda () (message "Saved")))
```

Your own configuration file, `init.ss`, is also a plugin, so re-running it cleanly replaces what it did last time.

## Swapping out a part

![Swapping a service](diagrams/services.svg)

Some parts of Tuna are **services**: a named slot plus a promise of what fills it. For example, the "text store" slot promises operations like *insert*, *delete*, and *read a line*. Buffers only ever talk to the slot, so any implementation that keeps the promise can fill it. Tuna ships a rope (a tree of text chunks that makes copies of old versions free, which background jobs rely on), but a plugin can fill the slot with something else:

```scheme
#lang :tuna

(provide-service text-store (make-gap-buffer-store))
```

The renderer is a service too, which is how a terminal version of Tuna could exist later.

## Buffers are trees

In Emacs a buffer is always a flat piece of text with decorations. In Tuna a buffer holds a small tree of **nodes**, like HTML. A file you're editing is a buffer with a single text node, so it behaves just like Emacs. A richer screen, such as project-wide search results or a Git status view, can use columns, lists, and collapsible sections, with text nodes inside them that you still navigate with ordinary editing keys. Monospace and proportional text can sit in the same buffer; the browser does the layout. Rich buffers come later; plain text comes first.

Positions in a buffer count characters from 1, as in Emacs, because they are something people read.

![Two windows on one file](diagrams/who-owns-what.svg)

What you see in a window is a **view** of a buffer. Two windows can show the same file, each with its own cursor and scroll position, while sharing the buffer and its text. Emacs works the same way; Tuna just names the view. A view can also hold several cursors, which is how multiple-cursor editing will work later.

## Where things are saved

| What | Where | When |
|---|---|---|
| Your files | Wherever they live | When you save |
| Unsaved changes | `~/.local/state/tuna/autosave/` | Every so often, and when idle |
| Open buffers, cursor positions, window layout, history | `~/.local/state/tuna/session.ss` | When idle, and on exit |
| Settings changed through Tuna's UI | `~/.config/tuna/custom.ss` | When changed |
| Your configuration code | `~/.config/tuna/init.ss` | You edit it |

The saved files are plain Scheme data, readable in any editor, and Tuna never runs them as code. Only `init.ss` is code. Each plugin decides what of its own state is worth saving.

## How this differs from Emacs

See [Tuna and Emacs](emacs-equivalents.md): a table of what corresponds to what, and every deliberate difference with its reason.

## Words used here

- **Buffer**: something you look at and edit, such as a file or the minibuffer.
- **Node**: one piece of a buffer's tree; a text node holds editable text.
- **Command**: a named action, such as `forward-char`, usually bound to a key.
- **Editor thread**: the single worker that runs commands and is the only thing allowed to change editor state.
- **Screen**: one complete drawing of what a browser tab shows, sent as HTML.
- **Frame**: as in Emacs, a top-level window holding other windows. At first every browser tab shows the same frame.
- **Window**: one area of a frame showing a buffer. How windows are arranged is up to a replaceable window-manager plugin; see [window management](ideas/window-management.md).
- **View**: a buffer as shown in one window, with its own cursor and scroll position.
- **Task**: anything that runs on the editor thread, such as a command or a timer; it may pause to wait for an answer.
- **Client**: one connected browser tab.
- **Version** (or revision): a number that goes up every time a buffer changes.
- **Snapshot**: a frozen copy of a buffer's text at one version, cheap to make.
- **Job**: slow work done off the editor thread using a snapshot.
- **Plugin**: a bundle of commands, keys, hooks, and services that can be turned on and off.
- **Receipt**: a plugin's record of everything it added, used to undo it.
- **Service**: a swappable part of Tuna, defined by what it promises to do.
