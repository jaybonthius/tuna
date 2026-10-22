# Per-tab state: Gerbil and Tuna mechanics

Research only. Tuna `main` at `33b2163`; Gerbil `v0.19-dev-63-g1cfb032c` on Gambit `v4.9.8-19` (`/opt/gerbil`); Emacs checkout `541f693ca2e`; Cordis `a71c658`; Koishi `97d5c39`. Labels: **F** = fact with a citation, **E** = checked by experiment, **I** = inference, **P** = proposal.

## Summary

- **Today a command gets its context from service state, not from arguments.** `current-buffer` is `(view-showing (selected-view))`, and `selected-view` is a field of the one frame in the layout plugin. The buffers provider holds that frame's value. Gerbil parameters (dynamic variables) carry only per-task extras: the task, the plugin context, the activation, the key event, and `with-settings` bindings. Each task runs in its own Gambit thread, and a suspended task simply blocks in that thread, so a parameter bound inside the task survives suspension. But tasks are spawned by the **loop thread**. They therefore inherit the loop's dynamic environment, not the environment of whoever submitted the input or called `spawn-task!` (E).
- **Recommendation: a hybrid that needs no kernel change.** A small new contract owns a transport-neutral **client** (a tab, a terminal, a desktop window) and a `current-client` parameter. The input plugin binds the parameter inside the task thunk it returns, exactly as it already binds `activation-event`. Render paths take the client or frame as an explicit argument. Per-client data (frame, input session, measurements, prompt stack) lives in records owned by the plugins whose concept it is. The kernel's `Input` and `Display` seams already allow all of this, and ADR 12 forbids "clients", "frames", "screens" and "browsers" in the kernel anyway.
- **The hard problems are not mechanical.** The hard problems are deciding:
  1. whether two tabs may show the same view (scroll facts, placement and point live on the view today);
  2. whether prompts follow the tab that asked;
  3. that `C-g` stays global for a *running* task (the kernel quits whatever holds the baton) but becomes per-client for prompts and prefixes.

## 1. How a command learns its context today

**F: the context is held in service state.**

- `current-buffer` reads the selected view (`plugins/buffers/contract.ss:1149-1159`): `(selected-view)` dispatches to the buffers provider's `Buffers-selected-view`. That view is "the layout's, set by the layout" (`contract.ss:358-361`).
- The layout plugin stores it in its single frame: `(selected-view (lambda (self) (frame-state-selected self.frame)))` (`plugins/layout/plugin.ss:829`). It pushes the value with `set-selected-view!` (`layout/plugin.ss:185`).
- The layout contract says outright: "The frame (there is one)" (`plugins/layout/contract.ss:7`).
- `point`, `goto-char` and the text node all go through `(selected-view)` (`buffers/contract.ss:1164-1204`).
- The renderer draws from the layout's single frame target through `render-layout` (`plugins/renderer/plugin.ss:484-486`). `Renderer.render-screen` takes no argument (`plugins/renderer/contract.ss`).

**F: Gerbil parameters carry the per-task extras.**

| Parameter | Where | Bound by |
|---|---|---|
| `current-task` | `tuna/kernel/tasks.ss:47` | `baton-task-thread`, `loop.ss:445-449` |
| `current-context` (plugin owner) | `tuna/kernel/plugins.ss:75` | `call-with-context` |
| `current-activation` (command nesting, `last-command`) | `plugins/commands/plugin.ss:43,57` | `invoke!` |
| `activation-event` (the key or click that ran the command) | `plugins/keys/plugin.ss:202-210` | **inside the thunk that `resolve!` returns** |
| `current-setting-bindings` (`with-settings`) | `plugins/settings/contract.ss:34-37` | `call-with-settings` |
| `reading-buffer` (`buffer-local-value`) | `buffers/contract.ss:898-910` | `buffer-local-value` |

The keys-plugin comment explains the pattern: "Capture the event in the resolved task, so another command at a prompt cannot overwrite the suspended command's event" (`keys/plugin.ss:200-201`). This is the existing precedent for per-input context.

**F: tasks and suspension.**

- `start-task!` runs on the loop thread and calls `spawn-thread` for each task (`loop.ss:438-443`). `spawn-thread` is `(thread-start! (make-thread (cut thread-main thunk) …))` (`gerbil/src/gerbil/runtime/thread.ss:56-58`).
- Gambit's `make-thread` gives the new thread a dynamic environment inherited from the current thread (`gambit.txi:10169`). Parameters are bound to the *same cells* as the parent's, so a later assignment (not a `parameterize`) is visible to both threads (`gambit.txi:11126-11133`).
- `suspend` sends `[suspended: s]` to the loop, then blocks the task's own thread in `completion-wait!` (`loop.ss:291-306`). No continuation is captured or moved between threads. The task's thread, with its dynamic environment, simply waits.

**E: experiment (`/tmp/ptest.ss`, gxi).**

- A "submitter" thread bound `p` to `'submitter` and sent a thunk to a "loop" thread that had bound `p` to `'loop`. The loop spawned the thunk, and the thunk saw `p` = `loop`.
- The thunk then did `parameterize` and blocked on a completion that another thread posted. After the wait it still saw its own binding.

So:

- A parameter bound **inside the task's thunk** survives every suspension of that task.
- A parameter bound in the web request thread or the submitter **never reaches the task**.
- A parameter bound by a task that calls `spawn-task!` does not reach the spawned task either, because the loop thread starts it (`loop.ss:241-245`).

**I: a gap in the ADRs.** ADR 9 says "Tasks inherit the dynamic layer of the code that started them" (`0009:17`), and ADR 4/9 say `current-buffer` is a dynamic-layer value (`0004:16`, `0009:16`). Neither holds in the code:

- `current-buffer` is service state.
- `spawn-task!` and `tuna/lib/timers.ss:49` do not capture the caller's settings bindings.

Any per-tab design that leans on "inheritance" must capture values explicitly in the thunk.

## 2. Three ways to give a command "the tab its input came from"

All three need **no kernel change** (I, from `loop.ss`):

- Input items are opaque to the kernel (`Input` interface, `loop.ss:47-54`), so the web plugin can tag each item with its tab.
- `Input.resolve!` returns a `(name . thunk)` pair built by the input plugin (`loop.ss:411-436`), so the plugin can wrap the thunk.
- `Display.redisplay!` takes no argument and is implemented by the transport (`loop.ss:56-59`; the web plugin's `{redisplay! web-server}`, `plugins/web/plugin.ss:146-162`), so the transport can render once per client inside its own `redisplay!`.

### (a) A dynamic parameter, bound around each task (Emacs `selected-frame`)

**Mechanism (P).** A contract defines `current-client`. The keys plugin's `command-task` (and `resolve-scroll!`) already wraps the thunk in `(parameterize ((activation-event event)) …)`; it adds `(current-client (event-client event))`. Dispatchers such as `selected-view` default to the current client's frame.

**Fit.**

- ADR 12: good. The kernel does not change, and nothing kernel-side is shaped around one consumer.
- ADR 4: matches "command context is thread-scoped, so suspended commands never see each other's context" (`0004:16`).
- Proven pattern: `activation-event` and `current-activation` already work this way.

**Risks.**

- It is ambient state. The AGENTS.md rule ("use what you were handed instead of reaching for another service's global current state") is satisfied only if the task counts as "handed" its client. That is a reasonable reading, because the binding is per task, not service-global.
- Work not started by input has no client and must handle `#f`:
  - timers (`timers.ss:49`);
  - job results (`result-poster`);
  - `call-on-editor-loop`;
  - config blocks (`tuna/config-blocks.ss:39`).

**Cost.** One more binding per task; negligible.

### (b) An explicit handle passed to commands

**Mechanism (P).** Commands receive a client argument, or interfaces take `(client : client)`.

**Fit.**

- Most explicit, and best for contract methods that clearly act on one client: `Layout.current-frame-target`, `move-frame!`, `render-layout`, `Renderer.render-screen`.
- Poor for command bodies: Emacs-ported code calls `(current-buffer)` and `(point)` with no arguments. ADR 1/4 want "package code reads like Emacs code" (`0004:24`). Threading a handle through every editing primitive would change every command signature.

**Cost.**

- For commands: a large signature change.
- For the render path: small. The renderer already threads a `render-view` procedure and has a `rendering-view` parameter (`renderer/plugin.ss:121,455`).

### (c) A per-client record owned by a plugin and looked up

**Mechanism (P).**

- Layout keeps a table `client → frame-state` instead of one `frame`.
- Keys keeps `client → input session` (pending prefix, `command-event`; today these are single fields of `global-keys`, `keys/plugin.ss:212-215`).
- Scrolling keeps `(view, client) → facts`.
- Minibuffer keeps `client → prompt stack`.

**Fit.** Required in any case: (a) and (b) only say *which* record to use. Each record belongs to the plugin whose concept it is, which satisfies the AGENTS.md rule "each hook, record and operation in the contract whose concept it is". Lookup still needs a key, supplied by (a) or (b).

**Cost.**

- One hash lookup per access.
- Records must be dropped when a client detaches, which needs a detach hook.

**P: recommendation.**

- Use **(c) for storage**.
- Use **(a) for command context**: the parameter is bound by the input plugin in the task thunk and defaults the existing zero-argument dispatchers.
- Use **(b) for the render path and for contract methods that change one client's state**.

This mirrors Emacs, where `selected-frame` is ambient but most frame functions take an optional `frame` argument that defaults to it.

### How redisplay would produce one screen per client

- **F.** Today the web plugin renders once (`render-screen`, `web/plugin.ss:113-118`), stores one `screen`/`rendered`/`revision`, and every SSE stream sends that same screen (`await-screen`, `stream-screens`, `web/plugin.ss:181-203, 425-447`). Two tabs today mirror one screen.
- **P.** Change only the transport and the renderer contract: `{redisplay! web-server}` loops over attached clients and calls `(Renderer-render-screen r client)` for each. Each client keeps its own `rendered`, `revision`, `owed` and applied-count, and keeps its unchanged-screen skip (`web/plugin.ss:152-162`). The kernel's single `redisplay` call stays.
- **I: cost.** Rendering is about N × one render per redisplay (STATUS.md measures ~11 ms and 36 KB per key at two drawn screens). The planned per-node HTML reuse by revision would make the second tab's render of the same views mostly cache hits. A tab whose screen string is unchanged sends nothing, as today.

## 3. Where the "tab" concept belongs

**F: it cannot be kernel vocabulary.**

- ADR 12: "The kernel must never know about: … browsers, HTTP, clients, … frames, screens, rendering …" (`0012`, Kernel contract).
- The kernel queues opaque items and calls one `redisplay!`. Nothing in per-tab work needs more.

**F: what the existing ADRs say.**

- ADR 13: "Frame: a movable pointer into the tree from which a browser tab draws … Several browser tabs, each with a frame, are allowed by the model and built later with per-tab input" (`0013:13,17`). It also expects that "frames shared by several tabs may later disagree about container focus memory; settled with per-tab frames" (`0013:63`).
- ADR 8: an input session holds the pending prefix, prefix argument, `last-command`, keyboard-macro state, transient map and **the input-target stack**. "Initially all clients share one session; … sessions can later become per client" (`0008:11`).
- ADR 10 (amended 2026-10-14) **removed client identity**: "One tab is assumed" (`0010:3,14`). Per-tab work must amend ADR 10 and ADR 7 (`0007:16,29`).
- Roadmap item 6: "Per-tab frames and input sessions" (`docs/roadmap.md:52`).

**F: Emacs.**

- Emacs separates a **terminal**, with one KBOARD per input stream, from **frames**.
- The KBOARD holds per-input-stream state "so that definition of keyboard macros, and reading of prefix arguments, can happen in parallel on various KBOARDs at once" (`src/keyboard.h:40-52`). Per-KBOARD variables include `last-command`, `prefix-arg`, `input-decode-map` and `overriding-terminal-local-map` (`keyboard.c:13781ff`, `DEFVAR_KBOARD`).
- One global event queue feeds all KBOARDs. While a command runs for one KBOARD, Emacs is in "single-kboard" state and sets other KBOARDs' events aside (`keyboard.h:59-79`). A recursive edit on a locked terminal errors (`keyboard.c:907-930`).
- `quit-flag` is one global (`src/eval.c:4440`).
- Input from another frame produces a `switch-frame` event that changes `selected-frame` (`lispref/commands.texi:2374`).

**F: Cordis and Koishi.**

- Cordis core has no per-request or per-client concept. Its context scoping is per plugin: `extend`, `isolate`, and an event `filter` evaluated against the emitter's `thisArg` (`packages/core/src/context.ts:65-69`, `events.ts:82-84`).
- Koishi, built on Cordis, models the per-message origin as an explicit **`Session` object**:
  - Command actions receive it as `argv.session`, and events are emitted with it (`koishi/packages/core/src/command/command.ts:59,316`).
  - Context filters (`ctx.platform(…)`, `ctx.channel(…)`) are evaluated against the session (`koishi/packages/core/src/context.ts:56-59,128`).
- That is option (b) plus filtering by origin. Tuna's agents/research/cordis-alignment/README.md covers only core lifecycle, not clients.

**I: what other transports imply.**

- A terminal UI has one client per terminal: no SSE, no page-load numbering, its own measured size.
- An Electron or desktop shell probably reuses the web transport, with one client per BrowserWindow.
- So *tab* is the web transport's word, and the editor-wide concept is a **client** (Emacs: terminal plus its frame). Transport details (streams, sequence numbers, Datastar) stay in the transport plugin. Everything other plugins key state by is in a neutral contract.

**P: ownership.**

| Piece | Owner |
|---|---|
| `client` record (id, kind, lifecycle), `current-client` parameter, `client-attached`/`client-detached` hooks | New `plugins/clients/contract.ss` (vocabulary plus hooks; it imports only the kernel; a provider may not even be needed, as the jobs library defines hooks with `new-hook`) |
| Creating and removing clients; tagging input items; per-tab numbering, streams, `/applied`; rendering per client | Web transport (and each future transport) |
| Client → frame (target, selected view, focus memory when it diverges) | Layout contract and plugin |
| Client → input session (prefix, `command-event`, last command) | Keys plugin (ADR 8) |
| Client → prompt stack, which view shows a prompt | Minibuffer |
| Measured facts per (view, client) | Scrolling, and the buffers view record where facts live today |

Contracts that would depend on `clients` (layout, keys, minibuffer, renderer) point one way, so there is no cycle. A contract for one consumer would break ADR 12; this one has at least five. *Name caution:* "display" collides with the kernel's `Display` service, so "client" is the clearer name.

**F: per-view state that two tabs would collide over.** The `view` class holds point (`position`), `top-item`, `scroll-offset`, `last-placement`, `facts`, `average-item-height` and `drawn-before`/`drawn-after` (`buffers/contract.ss:259-272`). Scrolling decides by `view-facts` and the placement number (`plugins/scrolling/plugin.ss:226-232`).

**I: the consequence.** If two tabs' frames both include view V and the tabs are different sizes, their scroll reports overwrite each other's measurements and placement on V. In Emacs this cannot happen, because a window belongs to exactly one frame. In Tuna a frame is a pointer into one shared tree, so it can.

**Owner decision needed.** Choose one:

1. Keep scroll and measurement state per (view, client). Point stays per view, as `window-point`.
2. Allow a view to be drawn by only one client at a time. Other clients see a "shown elsewhere" placeholder or a copied view.
3. Give each client its own layout tree (closest to Emacs frames).

## 4. Concurrency: two tabs, one queue

**F: what holds today.**

- One kernel queue; items run strictly in arrival order (`dispatch!`, `loop.ss:411-436`).
- The web plugin orders by *one* page-load sequence. `GET /` resets it (`restart-numbering!`, `web/plugin.ss:413-420`, "One tab only"), and admission holds early items under one mutex (`admit-event!`, `web/plugin.ss:505-529`). A second tab loading today resets the first tab's numbering. Two tabs' sequence numbers then collide as duplicates or gaps, so input is dropped or stalls until the 64-item skip.
- `C-g` is classified on the arriving thread as `'interrupt` (`keys/plugin.ss`, `{arrival global-keys}`). The kernel's `on-interrupt!` quits **whatever task is running**. With no task running, it queues the item as ordinary input "which a waiting prompt may bind" (`loop.ss:553-566`).
- Prompts: `ask!` shows the prompt in the view nearest the *selected view*, selects it, pushes onto one `prompts` list, and suspends (`plugins/minibuffer/plugin.ss:140-171`). ADR 3: only the innermost waiting prompt receives input (`0003`, Input-target stack).

**P/I: per-tab behaviour.**

- **Ordering per tab.** Numbering and pending maps become per client, keyed by a client id. The server can mint the id when it serves `GET /` and embed it in the page, which needs no `sessionStorage`. That matters because duplicating a browser tab copies `sessionStorage`, so an id kept there would no longer be unique. Each tab stays FIFO; between tabs, order is arrival order at submission. No cross-tab ordering is promised, or needed.
- **Prefix keys.** Prefix state moves into the per-client input session, as with Emacs KBOARD. Then tab A's `C-x` followed by tab B's `b` no longer forms `C-x b` (the capability audit's scenario, `capability-audit/05…:165`). Scroll reports already change no key state (`keys/plugin.ss:283-286`).
- **`C-g` while a task runs.** Keep it global. One baton means tab A's runaway command freezes tab B too, so either tab must be able to stop it. This matches Emacs's global `quit-flag`. Per-tab interrupt would need the kernel to know a task's client, a change ADR 12 forbids, or an `arrival` check reading editor state from a request thread, which `Input.arrival` forbids (`loop.ss:49-51`).
- **`C-g` with nothing running** goes through the queue, so it resolves in the sending client's session. It cancels that client's prefix or prompt only. No kernel change.
- **Prompts.** Record the asking client (from `current-client`) on the prompt, and keep one prompt stack per client. Keys from tab B resolve against B's session and never answer A's prompt. That is Emacs's `minibuffer-follows-selected-frame` set to nil (`doc/emacs/mini.texi:70-80`).
  - **Owner decision:** "follow" (the prompt moves to whichever tab types) is the Emacs default (`t`). It is simpler for one user with two tabs, but confusing on two devices.
  - Because tasks suspend without the baton, A's suspended command can coexist with B's commands editing the same buffer. ADR 3 already requires code to re-read state after a yield. The pending test for "text changes between yield points" becomes more urgent.
- **Global, shared state that stays shared** (I): buffers, texts, undo (grouped by `current-task-id`, so interleaving tabs give separate groups), the echo area, the kill ring and settings. Per-client echo messages are optional later work.
- **Work with no client** (timers, job results, config blocks): `current-client` is `#f`. Such code acts on shared state only; if it must pick a frame, a policy chooses one, such as the most recently active client. Emacs uses `selected-frame` here.

## Missing evidence and residual risks

- I did not measure render cost with N clients. HTML reuse by node revision is a planned optimization (STATUS), not built.
- I did not read the old multi-tab investigation (`agents/research/workbench-gerbil/tuna-firefox-multitab-subscription-investigation.md`); it may record browser connection limits for several SSE streams. HTTP/1.1 allows roughly six connections per origin, which matters with many tabs. This is unverified here.
- The `current-client`-in-thunk pattern is proven for parameters (E) and by `activation-event`, but untested with `call-with-task-owner` and command advice in the same task. Low risk (I).
- The ADR 4/9 mismatch over "current-buffer is dynamic" and "tasks inherit the dynamic layer" should be reconciled in whichever brief introduces clients; I did not file an ADR change.
- Cordis and Koishi evidence is limited to the cited files.
