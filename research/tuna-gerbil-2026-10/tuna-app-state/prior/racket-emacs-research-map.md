# Emacs research sources

Use primary sources first when investigating a Tuna design question.

## Core editor behavior

- [Command Loop](https://www.gnu.org/software/emacs/manual/html_node/elisp/Command-Loop.html)
- [Recursive Editing](https://www.gnu.org/software/emacs/manual/html_node/elisp/Recursive-Editing.html)
- [Active Keymaps](https://www.gnu.org/software/emacs/manual/html_node/elisp/Active-Keymaps.html)
- [Current Buffer](https://www.gnu.org/software/emacs/manual/html_node/elisp/Current-Buffer.html)
- [Selecting Windows](https://www.gnu.org/software/emacs/manual/html_node/elisp/Selecting-Windows.html)
- [Minibuffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Minibuffers.html)

## Text, display, and extension internals

- [GNU Emacs Internals](https://www.gnu.org/software/emacs/manual/html_node/elisp/GNU-Emacs-Internals.html)
- [Buffer Internals](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Internals.html)
- [Redisplay source commentary](https://github.com/emacs-mirror/emacs/blob/master/src/xdisp.c)
- [The Craft of Text Editing](http://www.finseth.com/craft/)
- [Emacs source tree](https://github.com/emacs-mirror/emacs)

## File and project behavior

- [Visiting Files](https://www.gnu.org/software/emacs/manual/html_node/elisp/Visiting-Files.html)
- [Saving Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Saving-Buffers.html)
- [File Name Expansion](https://www.gnu.org/software/emacs/manual/html_node/elisp/File-Name-Expansion.html)
- [Emacs Projects](https://www.gnu.org/software/emacs/manual/html_node/emacs/Projects.html)
- [`project.el`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/project.el)

When a claim depends on a particular Emacs version, cite that manual or a pinned
source revision. A generated API catalog is a version-specific, heuristic
snapshot and should not be vendored without a scoped use for it.

## Local source and graph

The reference checkout is `/home/jay/Code/emacs`. Resolve and report its current
commit for every investigation. The initial full index was built at
`541f693ca2e8de166cfe52c39bbfc497142215e9` as codebase-memory project
`home-jay-Code-emacs`.

The checkout tracks current `master`; installed Emacs is 30.2. State which one
the question targets. Use a release tag or commit-specific source when current
and installed behavior may differ.

## Investigation workflow

1. Search existing Tuna research, plans, and ADRs first.
2. Classify the question as documented API, Elisp implementation, C runtime,
   command/UI behavior, or compatibility.
3. Read the matching manual or Texinfo contract.
4. Use codebase-memory for focused structural discovery under `lisp/`, `src/`,
   and `doc/`.
5. Verify candidates in direct source, callers, tests, and documentation.
6. Cite the checkout commit, exact local line ranges, and immutable upstream
   permalinks.

Ignore mirrored Emacs source fixtures under tests when primary source exists.
Codebase-memory is a candidate finder: dynamic Elisp calls, advice, macros,
autoloads, and graph misses need direct verification. Say “not found in the
searched scope” rather than claiming nonexistence.

Standalone questions do not create files. Add a research note only when a
conclusion affects Tuna design or will likely be reused.
