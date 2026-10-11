---
name: emacs-reference
description: Investigate how GNU Emacs behaves or implements an editor feature, using the local Emacs checkout, primary manuals, and commit-pinned citations. Use when a Tuna design or port depends on Emacs behavior.
---

# Emacs reference research

Tuna is Emacs-inspired, not an Emacs clone. Establish what Emacs does and why, then state where Tuna deliberately differs.

1. Search `agents/research/` (start at `agents/research/README.md`) and `agents/adr/` for an answer already recorded.
2. Resolve `/home/jay/Code/emacs` and record `git rev-parse HEAD`. Installed Emacs may differ from that checkout; say which one the claim targets.
3. Classify the question: documented API, Elisp implementation, C primitive, command/UI behavior, or package convention.
4. Read the GNU Emacs Lisp Reference Manual section first (`doc/lispref/` in the checkout or <https://www.gnu.org/software/emacs/manual/html_node/elisp/>).
5. Use codebase-memory project `home-jay-Code-emacs` to find candidates under `lisp/`, `src/`, and `doc/`. Verify every candidate in the source: dynamic calls, advice, macros, and autoloads hide edges from the graph.
6. Cite the commit, local file and line ranges, and an immutable upstream permalink.

Useful starting points: Command Loop, Recursive Editing, Active Keymaps, Buffers, Markers, Text Properties, Overlays, Undo, Hooks, Advising Functions, Minibuffers, Processes, Threads, and `src/keyboard.c`, `src/xdisp.c`, `src/buffer.c`, `src/insdel.c`, `lisp/subr.el`, `lisp/simple.el`, `lisp/emacs-lisp/nadvice.el`.

For behavior reference in Gerbil, `/home/jay/Code/workbench-gerbil/gerbil-emacs` (codebase-memory project `home-jay-Code-workbench-gerbil-gerbil-emacs`) reimplements many Emacs commands; treat it as a behavior sketch, not as authority.

Answer standalone questions without editing files. Write a research note under `agents/research/` only when the conclusion shapes a Tuna decision or will recur.
