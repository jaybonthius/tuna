# Buffer and Pane Model Plan

Status: implemented for core model; switcher/popup work removed and superseded  
Scope: internal buffer/pane/session model only  
Date: 2026-06-11

## Purpose

Weevil needs Emacs-like editor state layering, but Weevil uses **pane**
for the view concept that Emacs calls a window.

This plan covers only the core state model foundation:

- buffers own content
- panes own view state such as point/mark/scroll
- frames contain panes
- sessions own buffers, frame state, selected pane, and revision

The previously planned server-rendered buffer switcher popup is removed.
Transient UI should not grow as bespoke popup state. Switchers, prompts,
completion, and command-palette flows should be built on the future
minibuffer/minipane model described in `plans/minibuffer-minipane-plan.md`.

## Naming decision

Use this vocabulary in public APIs, private modules, DOM attributes, CSS,
tests, and docs:

- **Buffer** — owns text/content and buffer-local state. May or may not be visible.
- **Pane** — a view onto a buffer. Owns point, mark, selection state, and eventually scroll.
- **Frame** — layout containing one or more panes.
- **Session** — buffers, frame layout, selected pane, durable editor state, and revision.

Avoid adding new `window` terminology. `weevil/window.rkt` remains only a deprecated empty shim until it can be removed.

## Implemented model direction

Initial private structs stay simple and immutable.

```racket
buffer-state
  id
  name
  model
  default-point-byte
  default-mark-byte
  default-mark-active?
  modified?
  path

pane-state
  id
  buffer-id
  point-byte
  mark-byte
  mark-active?
  scroll-top-line

frame-state
  root
  selected-pane-id

session-state
  buffers
  buffer-order
  panes
  frame
  rev
  next-buffer-id
  next-pane-id
```

Important ownership rules:

1. Buffer content lives in `buffer-state`.
2. Visible point/mark live in `pane-state`, not in the buffer.
3. A buffer stores default point/mark for restoration when no pane is displaying it.
4. Multiple panes may later show the same buffer; each pane has independent point/mark/scroll.
5. Switching a pane away from a buffer saves that pane's point/mark into old buffer defaults.
6. Switching a pane to a buffer restores the pane point/mark from new buffer defaults.

## Module shape

Private core modules:

```text
weevil/private/core/buffer-model.rkt     ; private string storage for now
weevil/private/core/buffer-state.rkt     ; buffer identity + content + defaults
weevil/private/core/pane-state.rkt       ; pane view state
weevil/private/core/frame-state.rkt      ; one-pane frame now, split tree later
weevil/private/core/session-state.rkt    ; top-level editor/session state
```

Public module shape:

```text
weevil/pane.rkt                          ; canonical public pane module, placeholder for now
weevil/window.rkt                        ; deprecated empty compatibility shim
weevil/frame.rkt                         ; frame API placeholder, speaks panes
weevil/config.rkt                        ; require/provide pane.rkt
```

## Explicit non-goal: popup/switcher state

Do not implement buffer/pane switching as a one-off popup state machine.
The project needs a general minibuffer/minipane state model first.

Removed/deferred concepts:

- `popup-state`
- `buffer-switcher-state`
- `session-state-open-buffer-switcher`
- `session-state-handle-popup-key`
- server-rendered `.buffer-switcher` popup
- `C-b` binding to a bespoke switcher command

The next phase should introduce minibuffer/minipane state and then rebuild
buffer/pane switching on that foundation.

## Tests covered by this plan

Core/session tests should cover:

- initial session has one frame, one selected pane, and multiple scratch buffers.
- selected pane displays `*scratch*` initially.
- editing mutates only the buffer displayed by selected pane.
- switching buffers preserves independent buffer contents.
- switching away saves point/mark defaults.
- switching back restores point/mark defaults.
- editing after switching back does not validate stale hidden-buffer defaults.

Render tests should cover:

- rendered app includes `data-pane-id` and `data-buffer-id`.
- buffer label/name reflects displayed buffer.
- no new `data-window-id` attributes are introduced.

Regression tests should cover:

- current insert/newline/backspace/navigation behavior still works through command dispatch.
- `/events` still sends full rendered app fragments.
- no direct HTTP route mutates state outside the event loop.

## Next plan

See `plans/minibuffer-minipane-plan.md` for the state-backed transient UI
model needed before implementing buffer switchers, pane switchers, command
palette, or file prompts.
