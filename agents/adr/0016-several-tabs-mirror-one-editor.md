# 16. Several tabs mirror one editor; a short, explicit list of per-tab state

Status: accepted (2026-10-21). Owner-approved brief: [`docs/briefs/2026-10-several-tabs.md`](../../docs/briefs/2026-10-several-tabs.md). Research: [`agents/research/per-tab/`](../research/per-tab/). Amends ADR 7 and ADR 10 (one tab assumed; no client identity), ADR 8 (input sessions become per client), ADR 13 (per-tab frames deferred) and ADR 15 (measurements per tab).

## Context

Since 2026-10-14 Tuna assumed one browser tab. A second tab on the same server breaks it. Serving a page resets the server's input numbering, so the first tab's input is held or dropped. Each view has one scroll state and one set of measured facts, so both tabs' reports overwrite each other, and a tab is never told to move when the other moves the view. The owner wants several tabs and devices (laptop and phone) attached to one editor, idiomatic in Datastar, with the vast majority of state on the server and shared, and an explicit list of what is per tab.

There are two coherent models in prior art (`emacs-and-prior-art.md`):
- **Mirror:** tmux clients on one session and Neovim's attached UIs share one current window.
- **Independent frames:** `emacsclient -c` gives each client a frame with its own window tree and selected window.

Both models keep input-sequence state and measured geometry per client. Datastar's authors keep per-tab state on the server, keyed by a tab-id signal made at page load. Each tab's stream renders its own view from shared state plus its tab (`datastar.md`, `discord-and-northstar.md`).

## Decision

- **Mirror.** Every tab shows the same part of the layout, the same selected view and the same scroll position (the item at each view's top), each laid out by its own browser.
- **Per-tab state is exactly three things, held on the server, keyed by the tab, never saved, and dropped a while after the tab's stream closes:**
  1. **Identity and connection** (web transport): tab id, input numbering, the last screen sent and confirmed.
  2. **Keys in progress** (keys and commands plugins): the pending key sequence, the event that ran the last command, and `last-command`. This is ADR 8's input session and Emacs's `kboard`.
  3. **What the tab's browser measured** (scrolling, on behalf of the view): view facts and size, the average item height, the drawn before/after counts, the total scroll height, and the newest placement sent to the tab.

  Everything else is shared editor state.
- **Tab identity is a Datastar signal** in the page shell, outside the morph target. It is made with `crypto.randomUUID()` at each page load and sent with every request. A reload or a duplicated tab is a new tab. It is not kept in `sessionStorage` (duplicated tabs copy it) or in a cookie (cookies are per browser).
- **A client is the transport-neutral word**: a browser tab today, and a terminal or desktop window later. A small `clients` contract provides the vocabulary: the `current-client` parameter, which the input plugin binds inside each command's task, and a hook run when a client goes away. The kernel does not change and never names clients (ADR 12).
- **One screen per client.** Each redisplay renders a screen for each connected client from shared state plus that client's measurements. A client whose screen did not change is sent nothing.
- **The tab you use drives the scroll position.**
  - A report from tab T moves the shared scroll position. Every other tab then gets exactly one placement to that position; T gets none.
  - A report from T is accepted when it acknowledges the newest placement sent to T.
  - A report that only confirms the placement T was just sent (the first report after T applied it) updates T's measurements but never moves the shared position, so tabs of different sizes cannot bounce each other.
  - Point-follows-view, `C-v`, `M-v` and `C-l` use the measurements of the client that ran the command.
  - Work with no client (timers, restore) places for every tab.
- **Quit.** `C-g` stops a running command whichever tab sends it, because all clients share one editor thread, as with Emacs's global `quit-flag`. With nothing running, `C-g` resolves in the sending tab's keys in progress.
- **Shared:** buffers, texts, undo, kill ring, settings, theme, the layout and frame, the selected view, point, scroll position, prompts, messages and completion.

## Consequences

- One person moving between devices sees the same editor everywhere, and today's breakage is fixed with the smallest per-tab list.
- Two people, or two visible tabs used at once, fight over the scroll position and the selected view. That is the mirror trade-off, as in tmux.
- Each change is rendered once per connected tab.
- One browser keeps about five Tuna tabs live over HTTP/1.1, because of the connection limit. Hidden tabs close their streams (Datastar's default).
- Datastar bug #900 (a retried stream resends its first signals) is harmless, because the stream carries only the constant tab id.

## Alternatives

- **Independent frames per tab** (`emacsclient -c`; ADR 13's "per-tab frames", roadmap item 6). Deferred, not rejected. It moves the frame, the selected view, scroll positions, prompts and message routing into the per-tab list, and it needs rules for one view shown in two tabs, which would share point but not scroll. It can be added later by moving entries between the lists.
- **Tab id in `sessionStorage` to survive reloads.** Rejected: under mirroring nothing worth keeping is per tab, and duplicated tabs would share the id.
- **Per-tab state in signals.** Rejected: Datastar's authors keep it on the server. Signals carry only the id and measured facts up.

## Divergence from Emacs

Emacs gives each client its own frame. Tuna mirrors one frame to every client. Record this in `docs/emacs-equivalents.md`, where a client corresponds to a terminal and its `kboard`.
