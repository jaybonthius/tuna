# Tuna and Emacs: equivalents and divergences

Tuna is Emacs-inspired, not an Emacs clone. This page maps Tuna's concepts to Emacs's and lists every place Tuna deliberately does something differently, with the reason. It is kept current: any new divergence must be added here and in a decision record. Status: everything below is planned unless marked built.

## Equivalents

| Tuna | Emacs | Same or different? |
|---|---|---|
| Buffer | Buffer | Same idea, but a Tuna buffer is a generic piece of UI holding a tree of nodes (a file, magit, a sidebar, the minibuffer); a one-text-node buffer behaves like an Emacs buffer. Saving to a file belongs to the text, not the buffer. |
| Text | Buffer text (shared by indirect buffers) | Same, and linked to its file. Text nodes in different buffers can show the same text or a range of it, so a search-results buffer edits the file directly (Emacs's wgrep copies and writes back). |
| Text store | The gap buffer inside Emacs's C code | Tuna's is a replaceable service; the default is a persistent rope, so old versions stay valid. Built. |
| Undo by command, undo chains | `undo`, `undo-boundary`, `pending-undo-list` | Same: one group per command, consecutive self-inserts grouped up to 20, point restored to where the command left it; undoing after another command redoes. Built. |
| View | Live window (a leaf of the window tree), with its `window-point` and `window-start` | Same thing, renamed (see divergences). Planned ([ADR 13](../agents/adr/0013-views-layout-and-frames.md)). Built today as two objects: a *window* holding a *view* for life; two windows on one buffer have independent points. |
| Selected view | Selected window | Same. Planned name. |
| Layout plugin (built today as the window manager) | Emacs's built-in C window tree plus `display-buffer` | Tuna's is a replaceable plugin behind a small contract (the layout contract, planned): the windows in order, the selected window, selecting, the next window, showing a buffer in a window, and rendering the window area. Swapping it while Tuna runs hands the windows over as a neutral description (like `window-state-get`). Built (one-window default, two-window toy; no splits yet). |
| `other-window` (`C-x o`) | `other-window` | Same; it uses only the window contract, so it works under any window manager. Built. |
| Container (fit, tabbed, scroll; each horizontal or vertical) | Internal "combination" window (horizontal or vertical split only) | Tuna adds tabs (a vertical tabbed container has side tabs), scrolling strips, and plugin-defined kinds; each container remembers its last-focused child. |
| `display-buffer` side hints | Side windows (`display-buffer-in-side-window`), as used by treemacs and speedbar | Same role; a layout plugin without sides places the view its own way. A view dedicated to one buffer closes with it. |
| `display-buffer` and display rules | `display-buffer`, `display-buffer-alist` | Same role, part of the window contract. |
| Window configuration | `window-configuration`, `window-state` | Same role. |
| Frame | Frame (a top-level window holding the whole window tree), plus narrowing | Different: a movable pointer to any part of the tree (see divergences). Initially every browser tab shows the same frame. |
| Frame mark | A window configuration saved to a register (`C-x r w`) | Different: jumping to a frame mark only moves the frame, so later changes to the layout are kept; a register restores a copy. Never called just "mark", which keeps its Emacs meaning. |
| Screen | What redisplay draws | Tuna sends each screen to the browser as HTML. |
| Client (a browser tab) | A terminal connected with `emacsclient` | Similar. |
| Text node | The buffer's text with its properties | Same. |
| Rich node | Nothing; Emacs fakes structure with text, properties and overlays (Magit sections, Dired lines, widgets) | New in Tuna. |
| Point, mark, region | Point, mark, region | Same. Positions count from 1. |
| Selections | Point and mark, plus packages such as multiple-cursors | A view can hold several selections, one primary. |
| Styled text | Propertized string | Same. |
| Text property, overlay | Text property, overlay | Same; Tuna overlays can be limited to one view. |
| Highlight layer (`set-highlights!`) | Overlays or `font-lock-face` properties set by a highlighter | A text holds named layers of ranges with faces; changing one bumps the decoration revision, not the content revision, and ranges move with edits. Built (minimal). |
| Marker | Marker | Same. |
| Character and content revisions | `buffer-chars-modified-tick`, `buffer-modified-tick` | Same, plus a separate revision for decorations. |
| Command (`defcommand`) | `defun` with `(interactive …)` | Same; Tuna commands will declare how each argument is obtained. Commands belong to the keys contract and are kept by the keys plugin, not the kernel. Built (without argument declarations). |
| Input session | Per-terminal command-loop state (`last-command`, prefix argument, keyboard macro) | Same idea, named. |
| Keymap stack | `current-active-maps` precedence | Same order, made explicit; adds keymaps on nodes. Keymaps belong to the keys contract and are kept by the keys plugin. |
| `keymap-set` | `keymap-set` | Same syntax (`"C-x C-f"`). Part of the keys contract. Built. |
| The `<printing-char>` binding | Printing characters bound to `self-insert-command` in `global-map` | Same effect through one pseudo-key. Built. |
| `last-command`, `last-command-event` | Same names | Same. Built. |
| Input item and the input service | Input events and `read-key-sequence` | The kernel queues each item without looking inside it; the plugin filling the input service (the keys plugin) decides whether it means "quit" and which command it runs, much as Emacs looks events up in keymaps. Built. |
| `input-pending?`, `discard-input` | `input-pending-p`, `discard-input` | Same; part of the kernel. Built. |
| Echo area | Echo area | Same; it is a plugin. Built. Planned: a buffer shown in an ordinary view (see divergences). |
| Hook (`new-hook`, `context-add-hook!`, `run-hook`) | Hook | Same; callbacks are named, ordered by depth, and a failing one is removed with a notice. The one hook mechanism is part of the kernel; each hook keeps its own callbacks. Built. |
| `kill-buffer-hook` | `kill-buffer-hook`, `replace-buffer-in-windows` | Same hook; window managers use it to show another buffer in the windows that showed the killed one, which Emacs does inside `kill-buffer`. Built. |
| `after-change-hook` | `after-change-functions` | Same role; callbacks receive the text and its change record. Built. |
| `plugin-activated-hook`, `plugin-deactivated-hook`, `service-changed-hook`, `task-started-hook`, `task-finished-hook` | `after-load-functions`, for activation only | The engine announces its own events. Emacs has no general hook for unloading, services, or tasks; `pre-command-hook` and `post-command-hook` are per command and will belong to the input plugin ([ADR 8](../agents/adr/0008-input-keymaps-and-command-composition.md)). Built. |
| Advice | `advice-add` (nadvice) | Same combinators. See divergences for what can be advised. |
| Setting (`defsetting`) | `defcustom` / variable | Same idea, with a typed schema. Built with a default and documentation; schemas come later. |
| `with-settings` | `let` on a special variable | Same effect, but per running command (see divergences). Built. |
| Buffer-, mode-, project-, connection-local values | Buffer-local, directory-local, connection-local variables | Same idea, one extensible chain. The buffer scope is built. |
| Plugin | Package, feature, minor mode | A plugin can be turned off and undone completely. |
| Receipt | `unload-feature` (best-effort) | Tuna's is exact. |
| Manifest and stub commands | Autoloads (`;;;###autoload`, `loaddefs`) | Same purpose. |
| Service | Nothing direct; closest are generic functions and backend lists (`xref`, `project`) | New in Tuna. |
| Editor loop, baton | Command loop, global Lisp lock | Same role. |
| Task | Command, timer, or process callback | Same, except a task may wait in the middle (see divergences). Tasks are part of the kernel. Built for commands and timers. |
| `context-run-with-timer!` | `run-with-timer` | Same; the timer and its callbacks stop when its plugin is turned off. A shared library (`tuna/lib/timers.ss`), not part of the kernel. Built. |
| Job (`job-group-start!`) | Async subprocess or thread | New: works on a snapshot and never touches live buffers; a plugin starts jobs in a job group it owns (`new-job-group`), and a newer job of the same group with the same key replaces the waiting one. A shared library (`tuna/lib/jobs.ss`), not part of the kernel; the kernel only posts each result back to the editor thread. Built (threads). |
| Prompt (`read-string`, `completing-read`) | Same names, via recursive minibuffer | Same style. `read-string` is built. |
| Minibuffer | Minibuffer, recursive minibuffers | Same: each waiting prompt has its own internal buffer; only the innermost receives keys. `RET` runs `exit-minibuffer`, `C-g` runs `abort-minibuffers`. Built. |
| `quit` and the quit key | `quit` signal, `C-g`, `inhibit-quit` | Same names; stronger guarantee (see divergences). |
| Session slots (`context-add-session-slot!`) | `savehist`, `desktop`, `saveplace` | Same purpose, defined by the session contract (not the kernel), kept by the session plugin and stored as plain data in `$XDG_STATE_HOME/tuna/session.ss`, saved while idle and on exit, restored on start. Built: buffers (names, points) and windows. |
| Autosave | `auto-save-mode`, `recover-session` | Same purpose: unsaved buffer text goes to `$XDG_STATE_HOME/tuna/autosave/`. Unlike Emacs, it comes back by itself on start, with the session, for buffers that visit no file (Emacs's `desktop` does not keep their text). Built. |
| `init.ss`, `custom.ss` | `init.el`, `custom-file` | Same roles; `custom.ss` is data, not code, and comes later with a settings screen; what it saves overrides `init.ss`. `init.ss` is found through `--config`, `$TUNA_CONFIG`, or `~/.config/tuna/init.ss`; its code other than `import` and `use-plugin` becomes the plugin `init`, turned on last. Built. |
| `use-plugin` | `use-package`, Doom's `doom!` | Declares a plugin; loading `init.ss` turns nothing on. A `config:` block (like `:config`) is its own small plugin, on while its plugin is on. Built. |
| Plugin options (`use-plugin p key: value`, `defplugin-options`) | `use-package` `:custom`, `defcustom` | A plugin declares each option with a type, default, and documentation, like `defcustom`; `init.ss` gives values as data, like `:custom`. Unlike Emacs, every option is checked against its type when `init.ss` loads, all problems are reported with their lines, and a file with a bad option changes nothing; a changed option replaces only that plugin on reload. Built. |
| Start-up report, `tuna check` | `*Warnings*`, `--debug-init` | One line per plugin: on, failed (and why), or skipped (and what it needs); also in `$XDG_STATE_HOME/tuna/startup.log`, and summarized in the echo area when something failed; `show-config-report` shows the last start-up or reload report. Unlike an error in `init.el`, a failure skips only that plugin. Built. |
| `reload-config`, `tuna reload` | `load-file` on `init.el`, restarting Emacs | Loads `init.ss` again as a trial and turns off, on, or replaces only what changed; a failing new part is undone and the running one turned back on, except that a changed module of your own imported by path has its definitions replaced as soon as it loads. `tuna reload` works from a terminal even when your input plugins are broken. Built. |
| File-system service providers | `file-name-handler-alist` (TRAMP, compressed files) | Same purpose. |

## Divergences

| What Emacs does | What Tuna does | Why | Cost when porting | Decision |
|---|---|---|---|---|
| `defcustom` serves both package options in `use-package :custom` and values changed later through customize or `setq` | Two concepts: plugin options (`use-plugin p key: value`), parameters of one declaration checked when `init.ss` loads, a change replacing the plugin; and settings, scoped runtime values. Settings will use the options' types when they get schemas; the settings screen edits settings, options are edited in `init.ss` | Options must be checked before anything runs, and a changed option must be undoable by replacing one plugin | A ported `defcustom` read only at load becomes an option; one read while running becomes a setting | [ADR 9](../agents/adr/0009-settings-and-scoped-values.md) (amendment 2026-10-13) |
| Renders in its own window or terminal | Renders HTML in a browser tab | Rich UI, remote use | Display code is rewritten | [ADR 7](../agents/adr/0007-rendering-and-transport.md) |
| Buffers are flat text | Buffers are node trees | Real structure instead of text hacks | Magit-, Dired-, agenda-style buffers are rewritten as rich nodes | [ADR 6](../agents/adr/0006-buffers-nodes-and-text-store.md) |
| Keys the window system delivers | Keys the browser delivers; some (`C-w`, `C-n`, `C-t`) never arrive in an ordinary tab | Ordinary tabs must work for remote development | Users rebind those keys | [ADR 7](../agents/adr/0007-rendering-and-transport.md) |
| Fixed C layout engine | Layout belongs to the browser; monospace and proportional text can mix | Anything should be possible visually | Screen-based commands need layout facts from the browser (still being designed) | [ADR 7](../agents/adr/0007-rendering-and-transport.md) |
| Display, windows, buffers, and the command loop are C code that Lisp can only customize | A small fixed engine; everything that makes Tuna an editor is a plugin with no special access | Anything Tuna does, a replacement can do | None for ordinary packages | [ADR 12](../agents/adr/0012-kernel-boundary-and-replaceability.md) |
| *Window* names a leaf of the window tree, which holds a buffer, point and scroll | The same thing is called a *view*; there is no separate window | A window held exactly one view for life, so they were one concept; "window" is ambiguous in a browser | Mechanical renames (`selected-window` → `selected-view`, `window-point` → `view-point`) | [ADR 13](../agents/adr/0013-views-layout-and-frames.md) |
| A frame always shows its whole window tree; narrowing is a separate buffer feature | A frame points at any part of the tree: a container, a view, or a node inside a buffer; the screen shows that part. Frame marks save locations | Look at any level of the arrangement without closing anything; structural narrowing (`org-narrow-to-subtree`) becomes moving the frame | Code that narrows to a structural part moves the frame instead; `narrow-to-region` on text stays | [ADR 13](../agents/adr/0013-views-layout-and-frames.md) |
| The minibuffer and echo area live in a special minibuffer window | They are buffers shown by ordinary views in the layout | One mechanism for everything on screen; layout plugins can place them | Code that finds the minibuffer window uses the minibuffer contract instead | [ADR 13](../agents/adr/0013-views-layout-and-frames.md) |
| Windows are a fixed tree of splits built into C | Window management is a replaceable plugin; the default is a recursive tree of splits, scrolling strips (Niri), and tabs (i3) | Far more flexible layouts; users can swap the whole manager | Packages that walk the window tree with `window-tree` or `window-child` need the window contract instead | [ADR 11](../agents/adr/0011-window-management-is-a-plugin.md) |
| `unload-feature` is best-effort | Turning a plugin off undoes everything it added, in any order | Reliable reload and disable | Packages must register through their context | [ADR 2](../agents/adr/0002-plugins-contexts-and-services.md) |
| `define-key` overwrites one shared keymap | Bindings are entries tagged with their owner | Exact undo; help shows who bound a key | Code that treats keymaps as raw lists changes | [ADR 2](../agents/adr/0002-plugins-contexts-and-services.md), [ADR 8](../agents/adr/0008-input-keymaps-and-command-composition.md) |
| Any function can be advised | Package functions can be advised; Tuna's core cannot, only its services and hooks | Core stays fully optimized | Advice on primitives like `insert` becomes a hook or service | [ADR 1](../agents/adr/0001-language-and-extension-surface.md) |
| `init.el` runs top to bottom, each form taking effect at once | `init.ss` is loaded first, collecting `use-plugin` declarations; the plugins and your own code are turned on afterwards | A file that fails to load changes nothing; every effect has an owner and can be undone | Code that relies on running at load time moves into a plugin or into your own code | [ADR 2](../agents/adr/0002-plugins-contexts-and-services.md) |
| An error in `init.el` aborts the rest of the file | Each plugin, `config:` block, and your own code turns on separately; a failure is undone and reported, plugins that need it are skipped, and the rest come up | One mistake does not take down the whole configuration | None | [ADR 2](../agents/adr/0002-plugins-contexts-and-services.md) |
| Definitions in `init.el` are global | Definitions in `init.ss` are local to your own plugin (`init`); helpers shared with `config:` blocks go in a module imported by a path relative to `init.ss` | Turning your code off removes its definitions too | Helper functions move to a small module | [ADR 2](../agents/adr/0002-plugins-contexts-and-services.md) |
| Re-loading `init.el` re-runs every form over the running state; removed settings stay, and an error leaves the file half applied | Reload compares the new `init.ss` with what runs and changes only the difference; a file that fails to load changes nothing, and a part that fails is undone with the running version turned back on (a changed module of your own imported by path is the exception: its definitions are replaced when it loads) | Reload is safe to try; the running editor is the last good version | Settings must belong to a plugin or your own code to be removed on reload | [ADR 2](../agents/adr/0002-plugins-contexts-and-services.md) |
| `with-eval-after-load` runs once and stays | Configuration attaches to a plugin and is undone with it | Correct under reload | Bodies may run more than once | [ADR 2](../agents/adr/0002-plugins-contexts-and-services.md) |
| An erroring hook function can disable the whole hook | Only the failing callback is disabled, with a notice | One broken plugin doesn't break editing | None | [ADR 2](../agents/adr/0002-plugins-contexts-and-services.md) |
| `C-g` works only when Lisp checks for it | `C-g` asks politely first, then forcibly interrupts code that doesn't respond | No more frozen editor | None | [ADR 3](../agents/adr/0003-command-loop-and-jobs.md) |
| Long computations freeze the editor | Slow work runs as jobs on snapshots | Typing never waits | Async code is restructured | [ADR 3](../agents/adr/0003-command-loop-and-jobs.md) |
| `call-process` blocks everything | Blocking calls let other work run while they wait | Responsive during `git status` | Rare code that assumes nothing changes during a call uses `with-baton-held` | [ADR 3](../agents/adr/0003-command-loop-and-jobs.md) |
| `this-command` is a global that prompts can clobber | Each running command has its own context | Correct composition | `(setq this-command …)` becomes a setter | [ADR 8](../agents/adr/0008-input-keymaps-and-command-composition.md) |
| which-key polls on a timer | The pending prefix is built-in, observable state | Simpler, instant | None | [ADR 8](../agents/adr/0008-input-keymaps-and-command-composition.md) |
| `let` binds globally for the one Lisp thread | `with-settings` binds per running command | Commands waiting at prompts can't see each other's bindings | `let` on special variables becomes `with-settings` | [ADR 9](../agents/adr/0009-settings-and-scoped-values.md) |
| `safe-local-variable` predicates per variable | Typed schemas decide what file and directory values are safe | Uniform safety, fewer prompts | Settings need schemas | [ADR 9](../agents/adr/0009-settings-and-scoped-values.md) |
| Saved session (`desktop`) is Lisp code | Saved state is plain data, never executed | Safety | None | [ADR 5](../agents/adr/0005-persistence.md) |
| Plain `emacs --daemon` socket with optional server key | Every client needs a per-launch token | The server can run any command | Launch through the `tuna` command or its URL | [ADR 10](../agents/adr/0010-security-clients-and-trust.md) |

### Under consideration

Not decided; recorded so they are not forgotten.

- **Undo tree built in**, from persistent text versions (Emacs needs undo-tree or vundo).
- **Highlighting kept as a cache** that survives edits instead of being written into buffer text properties.
- **Folding as per-view state**, so the same file can be folded differently in two windows.
- **Mode line, header line and tab bar as rich nodes** instead of the `mode-line-format` mini-language.
- **Typed completion candidates** instead of strings carrying hidden properties, and completion filtering as jobs.
- **Resumable debugger**: a failing command waits so you can fix it and continue.
- **Action resolver** in the style of Plan 9's plumber, unifying `ffap`, `browse-url`, buttons, and Embark actions.
- **Several views per node kind** that you can switch between (summary, table, raw), as in Glamorous Toolkit.
