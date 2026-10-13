# How Tuna works

**Status (2026-10-12):** the architecture skeleton is complete. Built: the small kernel (plugins with receipts, services that can be swapped at startup or live, the editor thread with `C-g`, hooks; cut back on 2026-10-12 to the four things described [below](#a-small-kernel-and-a-lot-of-plugins)), the token-protected browser connection, key handling, buffers as node trees with an editable text node, a swappable text store (a rope by default), basic editing with undo, the echo area and minibuffer with `read-string`, temporary settings, timers, background jobs, a swappable renderer (HTML, or plain text as a toy), a swappable window manager (one window, or two side by side as a toy), saving your session and unsaved text across restarts, and starting from and reloading your `init.ss` (stages 1 and 2 of [the configuration plan](../agents/plans/configuration.md): `use-plugin` declarations, `config:` blocks, your own code as a plugin, a start-up report, `tuna init`, `tuna check`, and reloading with `reload-config` or `tuna reload`). Not built yet: plugin options, files, `M-x`, completion, modes, and real window layouts. Sections marked *planned* describe the design for what isn't built. This page is updated as each piece is built, so it always describes what's real. The detailed reasoning lives in the [architecture decision records](../agents/adr/README.md).

## The idea

Tuna is an Emacs-like environment written in Gerbil Scheme. It runs as a server, on your machine or a remote one, and you use it through an ordinary browser tab. The browser acts like a terminal: it sends every key press to Tuna and shows whatever screen Tuna sends back. All the real work, and all the state, lives in Tuna. Only someone holding the secret link Tuna prints at startup can connect, because a connected tab can do anything your shell can.

Tuna is Emacs-inspired, not an Emacs clone. [Tuna and Emacs](emacs-equivalents.md) lists what corresponds to what, and every place Tuna deliberately does something differently.

Almost everything in Tuna is a plugin, including basic editing. You can turn plugins off, reload them, or swap out core parts (even the data structure that holds text) while Tuna is running.

## A small kernel and a lot of plugins

**Status:** built. The kernel was cut back to this shape on 2026-10-12.

![The kernel and the layers on top of it](diagrams/kernel-layers.svg)

Tuna itself is a small, fixed **kernel**. Everything that makes Tuna an editor sits on top of it, in three more layers, and each layer may use only the layers below it:

- **Plugins** (`tuna/plugins/`) do everything you'd recognize as Tuna: keys and commands, buffers and the text store, basic editing, the echo area and minibuffer, windows, drawing the screen, the browser connection, settings, and saving your session. Tuna's own plugins get no special access, so anything they can do, a replacement can do too.
- **Contracts** (`tuna/services/`) say what each slot promises, such as "a text store can insert, delete and read a line", so a different plugin can fill it. A contract also holds the shared types that go with its promise: the buffers contract, for example, defines the record of what an edit changed.
- **Shared libraries** (`tuna/lib/`) are conveniences built only from the kernel's public parts: timers and background jobs. They have no special access; a plugin could write its own. The buffers contract uses the jobs library.
- **The kernel** (`tuna/kernel.ss`, its public face, and `tuna/kernel/`) holds four things and no editor features:
  1. **Plugins:** turn a plugin on and off, undo everything it added, connect it to the services it needs, and swap a service's plugin while Tuna runs. Turning a plugin on or off finishes as a whole: `C-g` waits until it is done (a third `C-g` still forces a stop).
  2. **The editor thread:** one task at a time changes editor state, a task can pause for a question, `C-g` stops it, and input waits in an ordered queue. The kernel never looks inside an **input item**. The browser connection hands items in through a function the kernel gave it when the plugin turned on, and the plugin filling the input slot (the keys plugin) decides what each item means, including which key means "quit".
  3. **Hooks and IDs:** a named list of callbacks, plus unique IDs. The kernel uses hooks to announce its own events: a plugin turned on, a plugin turned off, a service changed hands, a task started, a task finished. Other plugins, such as a future profiler, can watch these without changing the kernel.
  4. **The slots it calls:** input (what an item means), display (bring the screen up to date), and messages (show a short note; the echo area fills this slot). When nothing fills messages, failures are printed to the terminal Tuna was started from.

Where the parts that once crept into the kernel live now:

| Part | Lives in |
|---|---|
| Commands and keymaps | The keys contract (`defcommand`, `keymap-set`); the keys plugin keeps them |
| Session slots | The session contract (`context-add-session-slot!`); the session plugin keeps them |
| Timers | The timers library (`context-run-with-timer!`) |
| Background jobs | The jobs library. A plugin makes a **job group** when it turns on and starts its jobs in it; turning the plugin off cancels them. |
| Records of what an edit changed | The buffers contract |

`make test` checks these boundaries mechanically. Kernel code may import only Gerbil's standard library and other kernel files, and may not use the words the [kernel decision record](../agents/adr/0012-kernel-boundary-and-replaceability.md) forbids (keys, buffers, windows, settings, timers, and so on). Libraries may import only the standard library, the kernel's public face, and other libraries. Everything else imports only the kernel's public face, and only tests may use the test helpers in `tuna/test-support/`.

Some plugins can be swapped while Tuna runs: the text store, the window manager, the renderer, and nearly everything else. A few are chosen at startup and need a restart to change, such as how keys are resolved and how settings are looked up, because swapping them mid-session would pull the rug out from under running commands. If a plugin combination breaks things, Tuna recovers from your own configuration, by skipping what failed or going back to your last working configuration, rather than switching to some built-in default; how exactly is still being designed, and `describe-services` shows which plugin is filling each slot.

## The big parts

![The big parts of Tuna](diagrams/big-picture.svg)

Follow the numbers for the main loop:

1. The **keyboard plugin** in your browser sends each key press to Tuna.
2. The **web server** says "got it" immediately and puts the key in a queue, in order.
3. The **editor thread** takes the next key and asks the keys plugin what it means; the keys plugin finds the command bound to it, and the editor thread runs that command. The command changes the **editor state**: buffers, windows, the minibuffer. The editor thread is the only thing allowed to change editor state, so commands never trip over each other.
4. When there's no more input waiting, the editor thread draws a new **screen**: everything the tab shows, as HTML.
5. The web server sends that screen to every open browser tab.

Around that loop:

- **Plugins** add the commands, key bindings, and hooks the editor uses.
- **Replaceable services** are the swappable parts, such as how text is stored and how screens are drawn.
- **Background jobs** do slow work like syntax highlighting without holding up typing.
- **Disk** stores your files plus Tuna's own backups, explained [below](#where-things-are-saved).

## What happens when you type a letter

**Status:** built.

![Typing a letter](diagrams/typing-a-letter.svg)

The important part is the split between the fast path and the slow path. The letter shows up after one command and one redraw (steps 1–8). Highlighting runs separately and arrives a moment later (steps 9–12).

Every change bumps the buffer's version number. The highlighting job works on version 42. If you've typed more by the time its colors come back, Tuna keeps a short record of every change since version 42 and shifts the colors past what you typed, so they still land on the right characters. In Emacs, slow work like this freezes the whole editor. In Tuna it can't, because it never runs on the editor thread.

And if a command itself gets stuck, say in an endless loop, pressing `C-g` stops it. Tuna watches for `C-g` the moment it arrives, instead of waiting in line behind the stuck command. It first asks the command to stop, which well-behaved code notices right away; if the command doesn't respond quickly, or you press `C-g` again, Tuna stops it forcibly. Emacs can only stop code that remembers to check for `C-g`.

## How a command can ask you a question

**Status:** built.

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

Your own configuration file, `init.ss`, declares which plugins to turn on, and the rest of its code becomes one more plugin, turned on last (built, including reload):

```scheme
#lang :tuna/config
(import :tuna/plugins/keys :tuna/plugins/demo)
(use-plugin keys-plugin)
(use-plugin demo-plugin config: (keymap-set "C-c t" 'describe-services))
(defcommand (say-hello) "Say hello." (message "hello"))
```

Tuna looks for it at `tuna --config PATH`, then `$TUNA_CONFIG`, then `~/.config/tuna/init.ss`. Without one it turns nothing on and says how to get one: `tuna init` copies the starter configuration (`starter/init.ss` in the repository) there. Loading the file runs only its imports and its `use-plugin` declarations, which change nothing; Tuna then turns the declared plugins on one by one, and a plugin that fails is turned off again while the rest come up. Two things do run while the file loads and must not change the editor, because nothing could undo it: the code of the modules it imports (plugin modules only define plugins, so they are safe) and macro code. Definitions in `init.ss` belong to your own plugin, so `config:` blocks cannot see them; helpers both need go in a module that `init.ss` imports by a path such as `(import "my-helpers")`, found next to `init.ss`. Each plugin, and your own code, gets 5 seconds to turn on; one that takes longer is stopped and turned off. What came up, what failed, and what was skipped is printed when Tuna starts and written to `~/.local/state/tuna/startup.log`.

After editing `init.ss`, reload it without restarting: run the `reload-config` command (the starter binds it to `C-c R`), or `tuna reload` in a terminal, which works even when your input plugins are broken and prints the result there. Reloading loads the file again as a trial; if it does not load, nothing changes and you see the error and its line. Otherwise Tuna compares it with what is running and changes only the difference: plugins no longer declared are turned off, new ones turned on, and a plugin, `config:` block, or your own code that changed is replaced. If the new version fails, it is undone and the version that was running is turned back on. That guarantee covers `init.ss` itself, its `config:` blocks, your own code, and plugins from Tuna's or installed packages' compiled modules. A module of your own that `init.ss` imports by a path is the exception: when its file changed, it is loaded again in place, so its new definitions replace the running version's as soon as it loads, even if the reload then fails, and a running version that is turned back on calls the new definitions. A restart starts clean. A plugin that changes how keys or the display work (a startup-tier service) changes at the next start. The reload report, in the start-up report's format, goes to the echo area or the terminal that asked; it is not written to disk.

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
| Settings changed through Tuna's UI | `~/.config/tuna/custom.ss` (planned) | When changed |
| Your configuration code | `~/.config/tuna/init.ss` | You edit it |
| The start-up report | `~/.local/state/tuna/startup.log` | Replaced on every start |

Autosave, the session file, `init.ss`, and the start-up report are built. A settings screen that saves to `custom.ss`, overriding `init.ss`, comes later ([roadmap](roadmap.md)).

The saved files are plain Scheme data, readable in any editor, and Tuna never runs them as code. Only `init.ss` is code. Each plugin decides what of its own state is worth saving, and hands it to the session plugin as a named *session slot*; the kernel knows nothing about saving.

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
- **Job group**: a plugin's set of jobs; turning the plugin off cancels them.
- **Plugin**: a bundle of commands, keys, hooks, and services that can be turned on and off.
- **Receipt**: a plugin's record of everything it added, used to undo it.
- **Service**: a swappable part of Tuna, defined by what it promises to do.
- **Kernel**: the small fixed part of Tuna that is not a plugin: the plugin machinery, the editor thread and its rules, hooks, and the slots it calls.
- **Contract**: what a service slot promises, written down so another plugin can fill it.
- **Shared library**: convenience code, such as timers and jobs, built only from the kernel's public parts.
- **Hook**: a named list of callbacks that run when something happens, such as a buffer changing or a plugin turning on.
- **Input item**: one unit of input from a browser tab, such as a key press; the kernel queues it without looking inside.
- **Session slot**: a named piece of one plugin's state that the session plugin saves while Tuna is idle and on exit, and hands back on the next start.
