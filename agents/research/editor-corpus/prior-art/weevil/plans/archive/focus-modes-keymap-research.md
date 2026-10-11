# Focus, Modes, and Keymap Research

Status: research brief from subagents  
Date: 2026-06-11

## Question

Weevil's current minibuffer is intentionally small, but key behavior is too
naive if all keys are resolved against one global keymap except for a hardcoded
minibuffer branch. We need to understand how focus, modes, and keymaps should
interact before adding richer minibuffer behavior, pane switching, or multiple
panes.

## Short answer

The user intuition is right, with one correction:

- **Focus chooses the active dispatch context.**
- **The active dispatch context determines which keymaps are active.**
- **Modes belong mostly to buffers, not to focus itself.**
- **The minibuffer can become the focused input target and has its own keymap.**

So it is not quite "the focused buffer defines the mode". More precisely:

```text
if selected input target is minibuffer:
  active context = minibuffer context
  active keymaps = transient overrides + minibuffer keymap + chosen global fallback policy
  selected buffer major/minor mode maps do not participate
else if selected input target is pane:
  active context = selected pane -> displayed buffer
  active keymaps = transient overrides + buffer minor modes + buffer major mode + global map
```

The selected pane should remain meaningful even while the minibuffer is active.
The minibuffer should record an origin pane so accepting a prompt acts on the
right editor context. Active minibuffer state and selected input target must be
separate.

## What Weevil has today

Relevant files:

- `weevil/private/core/frame-state.rkt`
  - frame has `selected-pane-id` and `minipane-id`.
- `weevil/private/core/session-state.rkt`
  - session owns buffers, panes, frame, selected input target, minibuffer stack, revision.
  - editing uses `session-selected-pane`.
  - minibuffer context records `origin-pane-id`.
- `weevil/private/core/command-loop.rkt`
  - dispatch derives context from session state, then resolves through keymap layers.
- `weevil/keymap.rkt`
  - one `global-keymap`, printable fallback, remapping support.
- `weevil/modes.rkt`
  - minimal major/minor mode registry.
- `weevil/private/web/render.rkt`
  - browser keydown posts key metadata to `/key` with no pane/focus target.

Current model has explicit focus-related state:

```text
selected pane = frame.selected-pane-id
selected input target = session-state.selected-input-target
active minibuffer = top of minibuffer stack, when present
origin pane = minibuffer-context.origin-pane-id
```

Missing pieces:

- no full pane selection mutator for multi-pane layouts yet
- no transient override maps yet
- no rich mode lifecycle/hooks yet
- browser key payload has no pane/rev hint, which is acceptable for one pane but weak for future stale/race detection

## Emacs model worth adapting

Subagent research used the GNU Emacs manuals as the primary behavioral source.
Important concepts:

### Selected window vs current buffer

Emacs has a selected window and a current buffer. They are related but not the
same. The selected window is the user-visible focus anchor; Lisp can temporarily
switch current buffer internally. When command-loop control returns, Emacs
re-anchors current buffer to the selected window's buffer.

Weevil equivalent:

```text
selected pane = visible editor focus anchor
current buffer = buffer displayed by selected pane, unless command code explicitly enters another context
```

### Minibuffer as nested focused context

Emacs tracks active minibuffer window and the window that invoked it. Minibuffer
input is essentially a nested command-loop context.

Weevil equivalent:

```text
minibuffer stack entry:
  kind
  origin-pane-id
  prompt
  input state
  candidates later
```

When the minibuffer is the selected input target, minibuffer keymaps should
outrank normal buffer mode keymaps. But activating the minibuffer should not
erase the selected pane or its buffer mode, and an active minibuffer can remain
pending while input is routed back to a normal pane.

### Keymap precedence is layered

Emacs does not dispatch everything through one global map. It searches active
keymaps in deterministic order, roughly:

```text
overriding/transient maps
text/overlay maps
emulation maps
minor-mode override maps
minor-mode maps
major-mode local map
global map
```

Weevil should start simpler but preserve the same shape, with distinct stacks for
normal editing and minibuffer input:

```text
normal editing:
  transient override maps
  ordered minor-mode maps
  major-mode map
  global map

selected input target = minibuffer:
  transient override maps
  minibuffer map
  global map, if Weevil chooses to allow global fallback
```

Selected-buffer major/minor maps should not leak into minibuffer input.

### Modes are buffer-local behavior

Each Emacs buffer has one major mode and any number of minor modes. Mode keymaps
are active when that buffer is in the current selected window/context.

Weevil should model:

```text
buffer-state.major-mode-id
buffer-state.minor-mode-ids
```

The selected pane chooses which buffer's modes participate in dispatch.

## Server-owned browser editor constraints

Weevil's architecture is server-owned:

```text
/key     input intents up
/events  full rendered state down
```

Focus, minibuffer, selected pane, modes, and transient state must live in server
session state. A page refresh should reproduce the active focus context because
`/events` renders from session state.

Datastar is transport glue, not a frontend app. Current `keydown__window`
posting can stay for now. Later, multi-pane mouse/click focus may need pane/rev
hints in payloads, but those should be treated as untrusted hints validated
against server state.

## Design lessons

1. Add an explicit **dispatch context** abstraction.
2. Keep selected pane and active minibuffer separate.
3. Treat minibuffer as a focused nested context with an origin pane.
4. Add buffer mode metadata before mode-dependent dispatch.
5. Replace hardcoded minibuffer dispatch with keymap-layer resolution that uses selected-input-target-specific stacks.
6. Keep route/read-model constraints: no widget-specific handlers; render via `/events`.
7. Do not make DOM focus the source of truth. Browser focus can be a hint or accessibility aid; server state is canonical.

## Sources consulted by subagents

Primary Emacs sources:

- GNU Emacs Lisp Reference Manual: Command Loop Overview
- GNU Emacs Lisp Reference Manual: Information from the Command Loop
- GNU Emacs Lisp Reference Manual: Current Buffer
- GNU Emacs Lisp Reference Manual: Selecting Windows
- GNU Emacs Lisp Reference Manual: Minibuffer Windows
- GNU Emacs Lisp Reference Manual: Minibuffer Miscellany
- GNU Emacs Lisp Reference Manual: Recursive Editing
- GNU Emacs Lisp Reference Manual: Recursive Minibuffers
- GNU Emacs Lisp Reference Manual: Active Keymaps
- GNU Emacs Lisp Reference Manual: Searching the Active Keymaps
- GNU Emacs Lisp Reference Manual: Controlling the Active Keymaps
- GNU Emacs Manual: Major Modes, Minor Modes, Local Keymaps

Additional architecture references used for comparison:

- Martin Fowler, CQRS
- Azure Architecture Center, CQRS Pattern
- CodeMirror system guide and precedence/config docs
- ProseMirror command API docs
- VS Code keybinding and when-clause context docs
- Neovim map documentation
- W3C Input Events Level 2
- Datastar docs in `DATASTAR_DOCS.md`
