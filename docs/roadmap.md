# Roadmap

Each milestone is a working program that can be shown in the browser. Write a short plan (one page or less) when a milestone starts; record hard-to-reverse choices as ADRs.

## Done: architecture skeleton (2026-10-12)

Brief: [briefs/2026-10-architecture-skeleton.md](briefs/2026-10-architecture-skeleton.md). Goal: prove every seam in [the ADRs](../agents/adr/README.md) with the least feature code:

- the editor loop accepts browser keys, runs commands under the baton, and redisplays to every connected tab;
- the browser opens a plain loopback URL, protected by Host/Origin checks; input is sent immediately and ordered by page-load numbers on the server;
- a scratch buffer is one text node backed by the default persistent `TextStore`, shown through a view; positions are 1-based; typing, deleting, and basic motion work;
- basic editing is a plugin: deactivating it removes its commands and keys, and reactivating restores them; two plugins binding the same key survive either deactivation order;
- `C-g` interrupts a deliberately endless command;
- a `with-settings` binding is visible only to the command that made it, even while another command waits at a prompt;
- the kernel (plugin runtime, execution rules, shared vocabulary) is separate from every default plugin, and defaults use only public contracts;
- a second `TextStore` implementation, a second renderer, and a second (single-window) window manager can each replace the default; `describe-services` shows who fills each slot;
- a command prompts in direct style through a minimal minibuffer and resumes with the answer;
- a deliberately slow fake highlighter runs as a job: edits render first, and its decorations arrive later, shifted past any typing that happened meanwhile;
- a session slot and autosave survive a restart;
- keydown-to-patched-screen latency is measured (about 3–4 ms; the in-app instrumentation was later removed because it leaked into the kernel, and measurement moves to a separate profiler plugin).

Out of scope: windows and splits, files, modes, completion UI, real highlighting.

## Done: configuration (2026-10-13)

Brief: [briefs/2026-10-configuration.md](briefs/2026-10-configuration.md). Tuna starts from your own `init.ss`, which declares the plugins to turn on (`use-plugin`) with their options; `tuna init` copies the starter configuration, `tuna check` validates a configuration, and `reload-config` (`C-c R` in the starter) or `tuna reload` reloads it while Tuna runs, changing only what changed.

## Done: getting the core back to its intended shape (2026-10-16)

The skeleton let pieces of features creep into the kernel. The approved plan ([kernel contract](briefs/2026-10-kernel-contract.md)) fixes that first, in this order:

1. *Done (2026-10-12).* Clean up the kernel to match the contract (no new features). See [how Tuna works](overview.md#a-small-kernel-and-a-lot-of-plugins).
2. *Done (2026-10-13).* Buffers, views and layout: buffers really replaceable, views in a layout with splits and tabs, movable frames and frame marks, and the minibuffer and echo area as ordinary views ([brief](briefs/2026-10-buffers-views-layout.md), approved 2026-10-13). This brings forward the window part of the "Windows" item under "Later", except scrolling strips.
3. *Done (2026-10-13).* Take the demo out of the default startup: the starter configuration declares only real plugins, and the demo runs with `--config demo/init.ss`.
4. General-purpose hooks and advice, including redefining functions while Tuna runs (a brief first). *Partly done (2026-10-14, kernel cleanup with Cordis):* hooks with ownership and depth, and live redefinition; advice is not built. *Done (2026-10-16):* [brief](briefs/2026-10-hooks-and-advice.md): open package functions, `redefine`, function and command advice, `describe-advice`, the hook fixes, and the hungry-delete demo. Service-operation advice moves to the profiler ("Later").

## Done: HTML and stylesheets (2026-10-17)

Brief: [briefs/2026-10-stylesheets.md](briefs/2026-10-stylesheets.md). HTML is Tuna's only presentation language. Each plugin styles its own HTML with its own stylesheets on top of shipped design tokens; themes and `init.ss` replace any of them, and turning a plugin off takes its styles away. `describe-stylesheets` and `reload-stylesheets` inspect and reread them. The default look works on phones (dynamic viewport, safe areas, touch-sized targets) and in forced-colours mode. See [how Tuna works](overview.md#how-it-looks-html-and-stylesheets).

## Done: drawing only what changed (2026-10-23)

Brief: [briefs/2026-10-drawing-only-what-changed.md](briefs/2026-10-drawing-only-what-changed.md), [ADR 17](../agents/adr/0017-memo-and-sources.md). Every piece of the screen records what it read and is reused while nothing changed; a key redraws one line; an idle editor does nothing; screens are written into the stream as bytes. Work off the editor thread ([brief](briefs/2026-10-background-work.md)): `off-thread`, `sleep-for` and sources, proved by the `proced` demo. See [how Tuna works](overview.md#drawing-only-what-changed).

## Done: selecting text (2026-10-23)

Brief: [briefs/2026-10-selecting-text.md](briefs/2026-10-selecting-text.md). The mark, the region and the kill ring from the keyboard, with shift-selection and a `delete-selection` setting; clicking to move the cursor into any text of a buffer; dragging, double-click, triple-click and shift-click; copying to and pasting from the system clipboard. See [how Tuna works](overview.md#selecting-text-and-the-clipboard).

## Done: voice dictation (2026-10-24)

Brief: [briefs/2026-10-voice-dictation.md](briefs/2026-10-voice-dictation.md). `C-c v` in the demo inserts what you say at the cursor as you say it, through a separate speech worker (parakeet, nemotron model); the web plugin's page machinery, a microphone plugin and a voice plugin. See [how Tuna works](overview.md#voice-dictation).

## Done: spoken commands (2026-10-24)

Brief: [briefs/2026-10-voice-commands.md](briefs/2026-10-voice-commands.md). `C-c c` in the demo: say a command's name and it runs. The speech worker listens with a grammar of every visible command's spoken name (a fast English model, `realtime_eou`); listening ends by itself; a confidence from the grammar's score against the score without the grammar decides between running the command, offering the `M-x` list, and "Didn't catch a command", every threshold a setting. Needed a parakeet.cpp patch reporting those scores (`0005-grammar-scores`, carried by `gerbil-parakeet`). See [how Tuna works](overview.md#spoken-commands).

## Research before windows and scrolling

How the server learns layout facts from the browser (event-attached facts, measurement requests, Rocket components for local-only behavior). See [the capability-audit brief](briefs/2026-10-capability-audit.md).

## What's next, in tiers (owner, 2026-10-24)

Tiers are ordered by what blocks daily use, then by what each piece builds on. Within a tier the order is a suggestion. A plugin is a coherent feature you would turn on, off or swap as a whole, roughly the size of an Emacs package; single functions are commands inside one, and any command can still be advised or redefined by another plugin. Names: Emacs built-in names are fine (ours may be an enhanced version of the built-in); third-party package names are not used, and each plugin inspired by one credits it in an Acknowledgements section of its README.

### Tier 0: before daily use

1. *Done (2026-10-24, merged `1d285c1`).* **Restructure the existing plugins** to that size and naming: `basic-editing`, `region`, `kill-ring` and `text-mouse` become `editing`; `hungry-delete` moves to `demo/`; `orderless`, `command-annotations` and `M-x` (`extended-command`) become part of `completion` (M-x goes there, not into `commands`, because completion already imports the commands contract); `completion-vertical` becomes `completion-list`; `advice-help` and `stylesheets-help` become part of `help`; `design-tokens` becomes part of `stylesheets`; `reload-config` becomes `configuration`. `view-commands` stays separate so it keeps working under any layout plugin.
2. **Error recovery**, built into the kernel, the layout and the session, not a plugin: one bad command, swap, reload or plugin must never leave the editor unusable or need a restart (`TODO.md`, "Error recovery").
3. **`files`:** buffers visiting files; open, save, revert, external changes, recent files, cursor positions remembered, the file picker; large files. *Stage 1 of 4 done (2026-10-26, branch `files-1`):* the file service with the local disk, texts visiting files, the file picker (`C-x C-f`), `C-x C-s`, `C-x s`, `C-x C-w`, encodings and line endings kept byte for byte, read-only non-UTF-8 files, the unsaved marker, asking before `C-x k` kills an unsaved file ([plan](../agents/plans/files.md)). *Stage 2 done (2026-10-26, branch `files-2`):* recent files (in the picker and `recent-file`) and remembered cursor places, in session slots.
4. **Buffer switching** (`C-x b`) and killing (`C-x k`) live in **`view-commands`**, not `buffers`: the keys, completion and minibuffer contracts all import the buffers contract, so the buffers package cannot use them without a cycle; `view-commands` already holds the `C-x` commands that work under any layout. **`completion`** gains sources and preview for pickers. *Sources done (2026-10-26, branch `files-2`):* `completing-read` takes a list of tables shown as titled groups; preview is still to come.
5. **A process library** (shared code like the jobs library, not a plugin): running programs and reading their output; needed by search, git, language servers, formatters and the terminal. The voice plugin's private process code becomes its first user.

### Tier 1: daily editing

1. **`modes`:** major and minor modes, attached to a node or to a region of text, so one file can hold several (JavaScript and CSS inside HTML): the mode at the cursor decides keys, settings and commands; each region is highlighted by its own grammar (tree-sitter injections can report the regions); each region goes to its own language server as a separate virtual document with positions mapped. A brief first, and an [idea page](ideas/modes.md).
2. **`project`:** project root, project files, search with ripgrep, compile and jump to errors.
3. **`editing`** grows: motions (words, expressions, paragraphs), search and replace, undo and redo, indentation, comments, rectangles. Words are built (2026-10-26): `M-f`, `M-b`, `M-d`, `M-DEL`, `M-@`, `M-t`, `M-u`, `M-l`, `M-c`, with consecutive kills appending; prefix arguments wait for a numeric-argument command.
4. **`modal-editing`** (Helix-like, inspired by Hel), as a plugin.
5. **`which-key`:** prefix-key help.
6. **In-buffer completion** (Corfu-like) as part of `completion`, or `completion-popup` beside `completion-list` if it must be swappable on its own.

### Tier 2: IDE

1. **`tree-sitter`:** parsing, highlighting, folding, structural navigation; tree-sitter is the default (owner, 2026-10-22). Notes from 2026-10-22, not decisions: highlight what is drawn, as jit-lock, Neovim, Zed, VS Code and CodeMirror do, with a background job keeping the tree current and posting ranged highlights; missing pieces are a way to ask which ranges are drawn and a "buffer shown or hidden" hook.
2. **`lsp`:** language servers, whole-file synchronisation with incremental changes, semantic tokens for the drawn range.
3. **`diagnostics`:** underlines, margin marks, next and previous error; fed by `lsp` and linters.
4. **`formatting`:** formatters and editorconfig.

### Tier 3: big tools

1. **`git`** (Magit-like): sections are nodes, which Tuna's buffers already are.
2. **`terminal`:** Ghostty-based (the owner's libghostty web spike is in `~/Code/shux/spikes/libghostty-terminal/`).
3. **`actions`** (Embark-like): act on the candidate or the thing at the cursor.
4. **`workspaces`.**

### Tier 4: later

`llm` (chat and agents), `notes` (Denote/Org-like; to confirm), language modes (`markdown-mode`, `typst-mode`, …), `structural-editing` (Symex-like), `jump` (flash-like).

### Also planned, not yet placed

- First rich (non-text) buffer kind and keyboard navigation across nodes.
- Attached REPL; reloading package code.
- Per-tab frames (each tab its own part of the layout), if wanted; client-side reactivity where it pays off.
- A settings screen like `M-x customize`, in `configuration`: changes saved as plain data in `custom.ss`, overriding `init.ss`.
- Compressed screen stream (Brotli or Zstandard streaming compression; needs Gerbil packages the owner builds).
- The optional [profiler plugin](briefs/2026-10-profiler.md), with service-operation advice.
- Advice targets that declare their dependency (`TODO.md`).
- `completing-read` moves into the minibuffer contract, completion becomes the engine plugged into it, and M-x moves to `commands` (`TODO.md`).
