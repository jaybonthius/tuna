# Provisional generic state-tree model

Status: research lens, not an architecture decision or public API.

## Product direction

Tuna is intended to remain a small, unopinionated, extensible Lisp runtime that:

1. receives commands from the browser;
2. applies configured behavior to authoritative server state;
3. renders that state back to the browser; and
4. permits live redefinition through installed packages and trusted user
   configuration.

Core should treat application state as an opaque Racket value. It should not
know whether that value represents an editor, layout, document, text store,
terminal, Git interface, sidebar, or another application.

## State as a tree

The current product idea represents the entire editor state as a literal tree of
composable values. The tree itself is the state; there is no generic catch-all
`state` field layered beside it.

One illustrative shape is:

```racket
(editor
  (layout
    (layout-node
      #:direction 'horizontal
      #:tiling 'fit
      (layout-child
        #:measure 1/4
        (document
          (sidebar
            #:selected "main.rkt"
            (file-entry #:path "main.rkt")
            (file-entry #:path "test.rkt"))))
      (layout-child
        #:measure 3/4
        (document
          (git-status
            #:branch "main"
            (diff
              #:old-text "old"
              #:new-text "new")))))))
  (layout
    (document
      (terminal
        #:history '("$ raco test" "2 tests passed")
        #:input ""))))
```

This is a shape example, not proposed constructor syntax.

The distinctions currently useful for exploration are:

- **Editor state**: the complete authoritative tree.
- **Layout tree**: package-defined structure arranging documents.
- **Document tree**: package-defined composable content.
- **Node**: a concrete extensible Racket value whose fields and children express
  its state directly.
- **Text store**: an optional package-defined implementation detail used by a
  text-capable node; gap buffers and ropes are replaceable candidates, not core
  concepts.

Intrinsic inputs belong in node fields. Independently meaningful nested
components belong in child positions. For example, old and new text are inputs
to a diff node, not artificial child node types.

## Extensibility boundary

Installed Racket packages are the plugin system. Packages may define node types,
commands, renderers, input behavior, transformations, and storage strategies.
Trusted configuration imports those packages and selects or replaces behavior
through Tuna's live functions and values.

Racket structs and generics are one possible way to dispatch operations over
concrete node values without a central type switch. Any generic bridge must
still preserve Tuna's live-redefinition semantics. This is a candidate
mechanism, not a settled node protocol.

Core may define the mechanical contracts needed to run safely—command
serialization, state publication, revisions, failure behavior, transport,
redefinition, and lifecycle—but not the domain shape or meaning of state.

## Explicit non-goals for this phase

- defining modes, cursors, points, buffers, views, panes, or text-editing rules;
- choosing a gap buffer, rope, or other text representation;
- freezing node identity, inheritance, persistence, or mutation semantics;
- defining a complete node protocol;
- implementing layout or document packages;
- treating browser DOM state as authoritative.

## Questions for later architecture work

- What is the smallest operation set shared by genuinely different tree nodes?
- Which operations are generic tree interpretations, and which belong only to
  particular packages?
- How do browser commands address parts of opaque package-defined state without
  making core understand those parts?
- How do renderers compose across independently installed node packages?
- Which state changes require revisions or incremental browser updates?
- How does configuration select an implementation such as a gap buffer or rope,
  and what happens to existing state when that selection changes?
- Which generic hooks are required to extract the currently integrated profiler
  into an optional package?

These questions should be tested against several example trees before an API is
designed.
