# Current Weevil architecture

## One-sentence model

Weevil is a Racket-owned, browser-rendered editor: the browser sends input intents up, one Racket event loop mutates immutable editor state, and `/events` sends server-rendered Datastar patches back down.

## Primary runtime loop

```text
Browser key/scroll/paste/resize
  -> HTTP POST handlers in weevil/pages/editor.rkt
  -> async event-channel in private/core/event-loop.rkt
  -> command-loop/keymap resolver/public command API
  -> pure session-state transition
  -> optional file/terminal async events folded back through same channel
  -> render full #weevil-root app
  -> Datastar patch-elements over /events SSE
```

The CQRS split is real:

- writes go up through POST routes and return empty responses;
- state comes down through `/events` as a whole-app fat morph;
- file and terminal worker results are serialized through the same event channel as keys.

See `diagrams/weevil-input-render-flow.drawio`.

## Load-bearing invariants

| Invariant | Current shape | Why it matters |
|---|---|---|
| Single writer | module-level event loop thread owns mutation | preserves Emacs-like command-loop semantics |
| Immutable state | transitions return new `session-state` values | easy tests, snapshots, render consistency |
| Public/private boundary | `weevil/config` facade over `weevil/private/*` | stable extension surface can grow safely |
| Byte-canonical text | internal point/mark are UTF-8 byte offsets | robust browser/Racket conversion boundary |
| Buffer storage seam | `buffer-model.rkt` contract over rope/string backends | rope can evolve without API churn |
| Render is projection | `display-projection` feeds text and terminal paths | terminal reuses editor rendering machinery |
| Side effects are routed | file jobs and terminal owners post events back | avoids direct off-thread state mutation |
| Error isolation | command failures become echo messages | loop survives extension/command exceptions |

## Module map

| Area | Important files | Responsibility |
|---|---|---|
| Server/bootstrap | `weevil/dynamic.rkt`, `weevil/cli.rkt`, `weevil/components/*` | system lifecycle, routes, static files, watch runner |
| HTTP boundary | `weevil/pages/editor.rkt` | `/`, `/events`, `/key`, `/scroll`, `/resize` handlers |
| Event loop | `weevil/private/core/event-loop.rkt` | serialized event channel, state cell, subscribers, async result folding |
| Command dispatch | `command-loop.rkt`, `command-context.rkt`, `keymap-resolver.rkt` | key sequence resolution, hooks, command dynamic context |
| Core state | `session-*.rkt`, `buffer-state.rkt`, `pane-state.rkt`, `frame-state.rkt` | immutable editor/session model |
| Buffer storage | `buffer-model*.rkt`, `rope.rkt`, `position.rkt` | edit, slice, line/char/byte conversions |
| Public API | `weevil/config.rkt`, `commands.rkt`, `keymap.rkt`, `hooks.rkt`, `modes.rkt`, `options.rkt`, etc. | extension vocabulary used by defaults and user config |
| Rendering | `private/web/render.rkt`, `projection.rkt`, `text-projection.rkt`, `terminal-projection.rkt` | xexpr app render, virtual scroll, cursor/minibuffer/mode-line |
| Client actions | `client-action.rkt`, `client-action-script.rkt` | typed server action vocabulary lowered to browser JS |
| File I/O | `file-io.rkt`, `file-path.rkt` | off-thread load/save/dir listing with stale-result checks |
| Terminal | `weevil/terminal.rkt`, `private/term/*`, `native/weevil_term_shim.c` | PTY, libghostty/fake engine, owner thread, snapshot side table |

## State object model

```text
session-state
  buffers: id -> buffer-state
    buffer-text-state -> buffer-model -> rope
    modes/default view/file/terminal snapshot metadata
  panes: id -> pane-state
    buffer-id + point marker + mark marker + scroll/view geometry
  frame-state
    currently a single pane leaf; split tree is future work
  minibuffer stack
    minibuffer contexts; actual minibuffer text is a normal buffer+pane
  histories/message/rev/id counters
```

The buffer/pane split is Emacs-shaped: a buffer owns content and metadata; panes own view-local point, mark, and scroll. The model is ready for multiple panes conceptually, but live marker adjustment and a real frame tree need to land first.

See `diagrams/weevil-state-object-model.drawio`.

## Extensibility model

`weevil/config.rkt` re-exports the intended extension vocabulary: commands, keymaps, hooks, modes, options, buffer/file operations, completion, minibuffer, mode-line, cursor, panes, and UI refresh. Built-in defaults are registered through the same public API, which is the right Emacs-like shape.

Strong parts:

- keymap inheritance, prefix maps, command remapping, printable self-insert fallback;
- `completing-read` and completion-table protocol;
- minibuffer-as-buffer;
- mode-line interpreter;
- option contracts;
- unsafe page-template override kept out of normal `config`.

Gaps are mostly missing surfaces, not broken design: command metadata/interactive args, buffer-local variables, mode lifecycle hooks, faces/themes, mark/region/kill-ring, and a public API compatibility policy.

## Terminal architecture

The terminal subsystem is cleanly separated:

- pure session state holds only an immutable terminal snapshot on a terminal buffer;
- a lock-guarded registry maps buffer-id to live terminal controller;
- each terminal has an owner thread, PTY, engine instance, coalesced snapshot flush, and per-terminal custodian;
- terminal output/exit events are folded through the same event loop as editor input;
- terminal rendering uses `display-projection`, not a special renderer path.

This is well-designed. The remaining risks are operational: no user-facing kill-buffer/delete-pane cleanup path yet, per-feed pinned allocation, macOS process-group teardown parity, and potentially blocking PTY writes.

See `diagrams/weevil-terminal-subsystem.drawio`.

## Current scalability seams

- process-global singleton event loop/state/subscribers: fine for one session, not for multi-session;
- unbounded event/subscriber queues and full-app render per subscriber per revision;
- `render.rkt` is a large mixed module with Datastar JS expression strings, xexpr render, windowing, and cursor injection;
- terminal control calls run synchronously on the writer thread;
- request payload shape is conventionally shared between render JS strings and Racket readers, not one typed schema.
