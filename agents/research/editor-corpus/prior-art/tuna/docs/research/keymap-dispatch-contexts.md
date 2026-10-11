# Keymap dispatch contexts

## Question

How should Tuna select keymaps once buffers, modes, prompts, and multiple leaves
exist?

## Findings

Focus selects a dispatch context; it does not itself define a mode. Keep these
as distinct state:

- the selected leaf, the visible focus anchor;
- the input target, such as a leaf or a prompt;
- the buffer/view presented by the selected leaf; and
- an active prompt's origin leaf.

A prompt is a nested input context. Activating one must not erase the selected
leaf. Its origin is needed so accepting it resumes the command against the
right editor context.

Resolve keymaps from an explicit stack determined by the dispatch context:

```text
leaf input:   transient maps → minor-mode maps → major-mode map → global map
prompt input: transient maps → prompt map → optional global fallback
```

Do not let a displayed buffer's mode maps leak into prompt input. Keep the
ordering data-driven so future text/overlay or emulation layers can be added
without a special-case dispatcher.

## Tuna implications

Tuna already owns key dispatch and interaction state in the backend. Browser DOM
focus may be an accessibility aid or an untrusted hint, never the source of
truth. When mode and prompt APIs arrive, add an explicit dispatch-context value
rather than branching on individual widgets.

This is a shape, not an implementation order or a commitment to all Emacs
keymap layers.

## Sources

- [Emacs: Active Keymaps](https://www.gnu.org/software/emacs/manual/html_node/elisp/Active-Keymaps.html)
- [Emacs: Searching Keymaps](https://www.gnu.org/software/emacs/manual/html_node/elisp/Searching-Keymaps.html)
- [Emacs: Minibuffer Windows](https://www.gnu.org/software/emacs/manual/html_node/elisp/Minibuffer-Windows.html)
- [Emacs: Recursive Editing](https://www.gnu.org/software/emacs/manual/html_node/elisp/Recursive-Editing.html)
- [Tuna command-loop research](emacs-command-loop.md)
