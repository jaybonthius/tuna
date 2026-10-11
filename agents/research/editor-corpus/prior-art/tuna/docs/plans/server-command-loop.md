# Server command loop

## Status

Approved implementation plan.

## Decision

Tuna owns input interpretation. The browser sends every `keydown` as five raw
facts and renders server output. It does not know bindings, commands, prefixes,
normalization, cancellation, prompt state, or editor behavior.

Commands belong to the shared command registry and shared keymaps. A command
loop owns only an input stream, its unfinished sequence, dynamic context,
recursive-loop state, interaction state, and lifecycle.

There are two input contexts:

- `POST /input` feeds the editor loop used by `/`.
- `POST /session/<id>/input` feeds that session's loop, used by both the session
  and debug pages.

A session loop establishes the current session dynamic context. The editor loop
does not choose or infer a session. A session-specific command called from the
editor context follows its ordinary no-session failure path; no hidden active
session exists.

Persistent editor changes remain short editor updates. No command loop or input
wait holds the editor lock.

## Browser transport

Every rendered HTML page body installs native Datastar transport:

```html
<body
  data-on:keydown__window="
    @post('/input', {
      payload: {
        key: evt.key,
        ctrl: evt.ctrlKey,
        alt: evt.altKey,
        meta: evt.metaKey,
        shift: evt.shiftKey
      },
      requestCancellation: 'disabled'
    })
  "
>
```

Session and debug pages substitute `/session/<id>/input` for `/input`.

`requestCancellation: 'disabled'` only prevents Datastar from aborting an
earlier same-URL key request. Tuna adds no browser queue, retry, filtering,
focus handling, default prevention, plugin, or custom JavaScript. The browser
sends every keydown.

A raw request body is exactly:

```json
{
  "key": "x",
  "ctrl": true,
  "alt": false,
  "meta": false,
  "shift": false
}
```

`key` is a bounded nonempty string. Each modifier is a boolean.

The server processes accepted events in server arrival order. There is no
browser capture-order guarantee and no cross-page ordering guarantee.

## Server flow

```text
browser keydown
  -> native Datastar @post
  -> validate five raw fields
  -> enqueue in editor or session input stream
  -> 204 No Content

input loop
  -> normalize raw event
  -> retain, clear, or extend the server key sequence
  -> resolve the shared server keymap
  -> invoke a shared command procedure
  -> command performs short editor update(s)
  -> interaction or editor update invalidates SSE rendering
```

The HTTP handler validates and enqueues only. It never resolves a key or runs a
command.

Malformed or incomplete input returns `400`. A missing or stopped session
returns `404`. A valid event is never rejected because of an arbitrary inbox
capacity: runner inboxes are unbounded asynchronous channels and there is no
`429` input protocol.

## Command loops

Each running editor has one lazy editor input runner and a table of lazy session
input runners. A runner contains:

- its input context, with a session ID only for session runners;
- an asynchronous input channel;
- interaction state and its lock;
- a custodian, thread, and stopped state.

Runner creation, lookup, removal, editor shutdown, and session deletion remain
synchronized independently of the editor-state lock. A session deletion cannot
recreate a runner racing its removal. Stopping an editor stops both editor and
session runners.

The top-level and recursive loops use the same runner input stream. A recursive
loop suspends the outer command on the ordinary Racket stack. `C-g` clears an
unfinished sequence or exits only the innermost active recursive loop.

## Input normalization

The server ignores unsupported raw key values such as bare modifier presses.
For a usable key it derives the canonical keymap spelling from `key` and the
four modifiers. It lowercases a modified ASCII letter and orders modifiers as
`C-`, `M-`, `s-`, `S-`.

The initial bindings remain:

- `C-x 2` — split below;
- `C-x 3` — split right;
- `C-x o` — select next leaf;
- `C-x 0` — remove active leaf;
- `C-g` — cancel unfinished input or quit the innermost recursive loop.

## Rendering

Interaction state remains live, nonpersistent runner state. It records the
unfinished key sequence, recursive depth, transient message, and render
generation. Interaction changes invalidate SSE rendering without requesting a
persistence snapshot.

The page body owns the Datastar event action. SSE continues to patch the page's
`main` element. Rendered layout elements carry only semantic layout attributes;
they do not carry input URLs, focus attributes, or inert interaction-state
transport attributes.

## Implementation stages

1. **Separate commands from updates** — preserve the completed split between
   interactive commands and short editor updates.
2. **Server loop and bindings** — preserve the completed keymap, recursive-loop,
   lifecycle, lock-release, interaction, and layout-command work.
3. **Generalize input contexts** — add the editor runner alongside session
   runners without changing command ownership or inventing an active session.
4. **Simplify the protocol** — reduce raw input to five fields and remove the
   capacity semaphore, full result, and `429` response.
5. **Replace browser transport** — delete `tuna-input.js`; render native
   Datastar `data-on:keydown__window` and `@post` on index, session, and debug
   page bodies.
6. **Update tests and documentation** — remove script/backpressure expectations;
   prove the editor/session routes, raw validation, no-capacity enqueue,
   server-side commands, and rendered Datastar actions.

## Required tests

- A five-field event reaches a session loop and `C-x 3` changes that session.
- A five-field event reaches the editor loop without a session context.
- Incomplete or malformed bodies return `400`.
- A missing session endpoint returns `404`.
- More than 64 events enqueue while a command is blocked.
- Bare modifier events reach the server and are ignored there.
- Recursive loops resume their suspended commands; nested exits are innermost
  first; `C-g` affects only the innermost loop.
- Command errors leave a runner alive.
- A waiting command does not hold the editor lock.
- Interaction invalidation never requests persistence.
- Concurrent runner creation, deletion races, and editor shutdown remain safe.
- Index, session, and debug HTML render the correct native Datastar action.
- No custom input asset is served or referenced.

Use synchronization primitives rather than sleeps in runner tests.

## Deferred

- minibuffer and prompt rendering;
- completion, history, interactive argument specifications, and command
  metadata;
- modes and contextual keymap precedence;
- text input, paste, `beforeinput`, and IME composition;
- configurable keymaps, prefix arguments, macros, and undo grouping;
- cross-page ordering guarantees;
- inbox resource policy beyond the deliberately removed `429` protocol.
