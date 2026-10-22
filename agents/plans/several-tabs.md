# Plan: several tabs mirror one editor

**Status:** approved 2026-10-21 (brief `docs/briefs/2026-10-several-tabs.md`, ADR 16). Not started.

## Invariants

- The kernel does not change.
- Per-tab state is exactly ADR 16's three entries, all on the server and keyed by client. Nothing new is kept in the browser beyond the tab-id signal. Nothing per tab is saved.
- Everything else stays shared and saved as today.
- Commands keep calling `(current-buffer)`, `(point)` and `(selected-view)` unchanged. No command signature changes.
- Each per-tab entry lives in the plugin whose concept it is. The `clients` contract is vocabulary only, imports only the kernel facade, and serves at least the web, keys, commands, scrolling and renderer plugins.
- No backward compatibility: the single-tab paths (`restart-numbering!`, the global `owed`, one global `rendered`) are deleted, not kept beside the new ones.

## Placement

| Piece | Owner |
|---|---|
| `client` record, `current-client` parameter (default `#f`), client-gone hook | new `plugins/clients/contract.ss` |
| Tab-id signal in the page shell; the input sender adds it to `/commands` posts; parsing it on `/screen`, `/applied` and `/commands` | web plugin and `plugins/web/frontend/` |
| Clients by tab id; per-client input numbering; per-client streams, pacing, `rendered` and `owed`; one screen per connected client; dropping a client a grace period after its last stream closes, then running the hook on the editor loop | web plugin |
| A client field on key, pointer and scroll events | keys contract |
| Per-client pending keys and `command-event`; binding `current-client` in the task thunk beside `activation-event` | keys plugin |
| Per-client `last-command` | commands plugin |
| Per-(client, view) measurements: facts, average item height, drawn counts, total height, newest placement sent; shared position with a counter that says which tab moved it | scrolling plugin and the buffers contract `view` (move the measured fields off the shared view into per-client storage) |
| `render-screen` for a client: draws spacers and drawn runs from that client's measurements, and emits a placement when the client is behind the shared position | renderer contract and plugin |

## Stages

1. **Tabs and transport.**
   - Add the `clients` contract.
   - Make the tab id: a signal set in the page shell, sent automatically on `@get('/screen')` and `@post('/applied')`, and added by the input sender to `/commands`.
   - Key clients by tab id in the web plugin, with per-client numbering, pacing and screens. Delete `restart-numbering!`.
   - Give events their client, and bind `current-client` in the keys plugin.
   - Make pending keys, `command-event` and `last-command` per client.
   - Add a client-gone hook with a grace period.
   - Tests: a web integration test with two streams and two tab ids. Each tab's keys are admitted in order. `C-x` from A followed by `b` from B inserts `b`. A tab that disconnects is dropped after the grace period.
2. **Measurements per tab.**
   - Store the measured fields per (client, view).
   - Accept a report against the newest placement sent to its tab.
   - When the shared position moves, give every other tab one placement.
   - Render per client.
   - Point-follows-view and the scroll commands use the commanding client's measurements; work with no client places for every tab.
   - Tests:
     - Tab A's report moves tab B with one placement, and A gets none.
     - Two tabs with different heights each draw their own runs and spacers.
     - A reload is a new tab and lands at the shared position.
   - Then check by hand in two real browser windows of different sizes: scroll each, fling each, and type in each. Report what was checked.
3. **Records.**
   - Amend ADRs 7, 8, 10, 13 and 15 to point at ADR 16, and add ADR 16 to the ADR index.
   - Update `docs/overview.md` (the "One tab is assumed" text, the glossary's client and tab id) and add the brief's diagrams.
   - Add a client row (Emacs terminal and `kboard`; mirror versus `emacsclient` frames) to `docs/emacs-equivalents.md`.
   - Update `agents/STATUS.md` and roadmap item 6, which becomes "per-tab frames, if wanted".

## Not in this plan

Per-tab frames or layouts, per-tab prompts and messages, per-device settings (`mac-option-modifier`) or themes, HTTP/2, presence indicators (showing where other tabs are), and upgrading the bundled Datastar (only needed if the stream comes to carry changing signals).
