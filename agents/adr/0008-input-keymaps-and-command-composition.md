# 8. Input sessions, layered keymaps, and composable commands

Status: accepted (2026-10-11), from the [capability audit](../research/capability-audit/README.md) (lanes 1 and 4); amended 2026-10-13 with clicks (see "Clicks"; brief [`docs/briefs/2026-10-mouse-input.md`](../../docs/briefs/2026-10-mouse-input.md)).

## Context

Emacs commands compose through shared command-loop state: `this-command` and `last-command` (consecutive kills append), prefix arguments (`C-u`), `repeat`, keyboard macros, transient keymaps (hydra, transient, repeat-mode), emulation keymaps (Evil, Meow), per-text keymaps (yasnippet, Magit), pre- and post-command hooks (Vertico redraws from `post-command-hook`), `read-key` and `unread-command-events`, and programmatic invocation with supplied arguments (Embark). In Emacs most of this state is per terminal (`KBOARD`), and keymap precedence is a fixed list computed by `current-active-maps`. ADR 3 originally gave none of this a home.

## Decision

- **Input session.** Each client's input feeds an input session holding: the pending key prefix, the prefix argument, `last-command`, `real-last-command`, `last-repeatable-command`, keyboard-macro recording and replay state, the active transient keymap, and the input-target stack ([ADR 3](0003-command-loop-and-jobs.md)). Initially all clients share one session; because events carry client ids ([ADR 10](0010-security-clients-and-trust.md)), sessions can later become per client.
- **Activation context.** Each running command has a thread-scoped activation context: the command, the keys that invoked it, its prefix argument, and whether it is being replayed. `this-command` reads it; `last-command` is updated when the activation completes, so prompts inside a command do not clobber it.
- **Keymap stack.** Key lookup consults layers in this order, highest first: transient keymap; overriding-terminal and overriding-local maps; emulation layers (modal editing); keymaps of the focused node and its ancestors, and `keymap` properties at point; minor-mode maps in mode order; the buffer's local (major-mode) map; the global map. Keymaps have parents. Bindings are owner-tagged entries ([ADR 2](0002-plugins-contexts-and-services.md)). Command remapping applies after lookup.
- **Translation stage.** Before lookup, key sequences pass through translation maps (Emacs `input-decode-map`, `local-function-key-map`, `key-translation-map`), which also let users remap keys a client cannot deliver.
- **Key syntax.** Keys are written in Emacs's `keymap-set` syntax (`"C-x C-f"`), and the function is named `keymap-set`, avoiding the old `define-key` string ambiguity.
- **Pending prefix is observable.** The loop exposes the pending prefix and the bindings under it, so which-key-style help, `C-h` after a prefix, and echoing keystrokes are built in.
- **Command-loop hooks.** `pre-command`, `post-command`, `post-self-insert`, `before-change`, `after-change`, `minibuffer-setup`, `minibuffer-exit`, and window, buffer, and selection change hooks run for every dispatched command, including keys typed into the minibuffer.
- **Interactive specifications.** `defcommand` declares how each argument is obtained (prefix argument, region, prompt with completion, event), so commands can be called with explicit arguments from code, macros, `M-x`, or action menus. Emacs interactive code strings translate mechanically; inline `read-string` inside a body remains allowed. Prompts go through a replaceable prompt service, so a caller can supply answers programmatically.
- **Composition features** built on the above: prefix arguments, `repeat` and repeat-mode, transient keymaps, keyboard macros (key replay by default; an optional command-level track), `read-key`/`read-event`, and pushing events back into the session (`unread-command-events`).

## Consequences

- Modal editing, completion UIs, hydra/transient-style menus, and action menus have the hooks they need without core changes.
- Emacs code that destructures keymap lists or rebinds `this-command` with `setq` needs small changes; documented in [`docs/emacs-equivalents.md`](../../docs/emacs-equivalents.md).

## Alternatives considered

- **Mutable global `this-command` (Emacs).** Rejected: prompts and suspended commands clobber it.
- **A single flat keymap per buffer.** Rejected: cannot express modal editing, transient menus, or node-local bindings.

## Clicks (amendment, 2026-10-13)

- A click is an input item in the same ordered queue as keys, sent on release, naming the clicked part by stable id (`KIND:ID`) and the node under the pointer, plus the screen revision. The browser never names a command.
- Event names follow Emacs (`mouse-1`, modifiers, `double-`/`triple-` falling back to the single click). The part kind is a prefix key, using Emacs's area name where one exists (`<tab-line>`, not `<tab>`, which is the Tab key). Lookup tries the prefixed name, then, unlike Emacs, the unprefixed one, so one global `<mouse-1>` can serve every part.
- A posn names the part and node, not pixels or positions: layout belongs to the browser (ADR 7). A click on a part that is gone when handled reports it in the echo area and does nothing.
- A click does not clear the echo area, so clicking to read a message keeps it.
- Divergences are listed in `docs/emacs-equivalents.md`.

## Node keymaps (amendment, 2026-10-13)

- A buffer node may carry a keymap; the root node's keymap is the buffer's own (there is no separate buffer keymap). Lookup for keys starts at the focused node (the selected view's text node, or its buffer's root) and walks up to the root, then the innermost input target, then the global keymap. Clicks start at the clicked node (or the clicked view's buffer root). View and container keymaps are not built (TODO).
- For clicks, each keymap is searched under every name of the click (part-kind prefix first, double before single) before the next keymap, so a node's `<mouse-1>` shadows the global `<view> <mouse-1>`; Emacs tries each name in every keymap first.
- The minibuffer's `RET` and `C-g` are bound on its prompt buffer's root, so they apply only in the minibuffer. `C-g` elsewhere runs `keyboard-quit` and the question keeps waiting, as in Emacs; `C-g` in an outer prompt abandons it and the prompts inside without asking.
- Buttons (`button.el`): a node with a label and an action, drawn as a real `<button>`; one shared keymap owned by the buttons plugin. Only a click pushes a button until keyboard focus can rest on rich nodes.
- `data-clickable` follows real node bindings; a keymap generation number joins the HTML-reuse key.

