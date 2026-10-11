# Weevil Emacs-like Object Model v1

This is the target internal model for the core editor state before SQLite persistence.

## Principles

- Model editor objects, not UI accidents.
- Keep public `pane` APIs as compatibility shims for now; internally move toward Emacs-style `window` vocabulary.
- A minibuffer is a special buffer displayed in a special window, not a separate text stack.
- Persistence should eventually mirror this object graph in one global SQLite database.

## Core graph

```text
workspace/root
  selected-frame -> frame
  selected-window -> window
  current-buffer -> buffer

frame
  root-window -> recursive window tree
  selected-window -> window
  minibuffer-window -> window(kind=minibuffer)

window
  kind = internal | leaf | minibuffer
  internal: children + split axis
  leaf/minibuffer: buffer + point marker + start marker

buffer
  kind = normal | minibuffer | internal
  text-id -> buffer-text
  mark marker
  major/minor modes
  buffer-local values

buffer-text
  current text model
  modification counters / invalidation metadata later

marker
  buffer id
  byte offset
  insertion bias
```

## Minibuffer

Emacs treats minibuffers as mostly normal buffers:

- minibuffer names are like ` *Minibuf-1*`;
- minibuffer text begins with the prompt;
- the prompt is protected metadata/text;
- recursive minibuffers are nested activations using additional minibuffer buffers;
- minibuffer histories are separate state, not the active minibuffer text itself.

Weevil should follow that shape:

- active minibuffer input lives in a `buffer-state` with `kind = 'minibuffer`;
- `minibuffer-context` / invocation metadata stores prompt, prompt boundary, origin window/pane, history key, default/candidates;
- histories are stored separately by key.

## Persistence implication

Do not design tables like `workspace_minibuffer_stack` that store minibuffer input as a special side channel. Future SQLite should persist normal object tables: workspaces, frames, windows, buffers, buffer_texts, markers, buffer locals, histories, commits/ops.
