# Plan: profiler

Brief: [`docs/briefs/2026-10-profiler.md`](../../docs/briefs/2026-10-profiler.md) (decided 2026-10-12; resumed 2026-10-27 because the editor lags). Research: [`agents/research/profiling/`](../research/profiling/), especially `01`–`03` (2026-10-27) and `racket-profiler-extraction-research.md`. ADRs 1, 2, 3, 7, 12, 17.

**Approved 2026-10-27 (owner): build stages 1–3.** Stages 1–3 built 2026-10-27 on branch `profiler-1` (as-built notes at the end), except advice on service operations (open question).

**Purpose now:** let the agents find what makes Tuna lag. Profiling views inside Tuna (Koyo-style) come later and will read the same records.

## Design

- **Two tools, as every runtime has.**
  - **Spans:** a timed tree per input item.
  - **Sampler:** call stacks on a timer, which finds slow code that no span names.
- **Emitters never know the profiler.** Places that own a moment announce it through a general hook ("started" / "finished", with plain details such as the item number, command or job). They cost one check when nobody listens. The `profiler` plugin is one listener; nothing else imports it, and turning it off removes everything.
- **The record is Tuna's own data:** a tree of spans. Each span has a name, start, duration, bytes allocated, GC time, details, and child spans. A tree is held only while its input item is in flight, then written out and dropped. Keeping recent trees in memory waits for the in-editor views that would read them.
- **Files:** each finished tree is written as one JSON object per line, in a profile folder under Tuna's state folder. The sampler writes text lines, `stack;of;frames count`.
  - Every input item is recorded in full by default.
  - Options: the folder, starting a new file past a size, and a minimum duration below which items are skipped (default 0).
- **One input item's tree** follows it from key to paint:
  - browser key to send;
  - network;
  - waiting in Tuna's queue;
  - the command, its hooks, service calls and the jobs it started;
  - the redraw (pieces rebuilt and reused, HTML size);
  - waiting for the tab to apply the previous screen;
  - the browser's morph;
  - the paint.

  There is one branch per tab.
- **Browser and server are joined by IDs, never clocks.** Keys are numbered per tab, and each screen states the last key it includes. The page measures its own durations and sends them with the existing `/applied` post. Network time is the browser's round trip minus the server's time.

## Stages

1. **Hooks:**
   - web plugin: input item arrived, screen sent, screen applied with the browser's timings;
   - jobs library: job started and finished;
   - renderer: redraw started and finished;
   - advice on service operations.

   The kernel does not grow.
2. **The `profiler` plugin.** Span trees, the JSON-lines file, and `M-x profiler-mode`.
3. **The sampler.** `M-x profiler-start` / `profiler-stop`, copied from Gerbil's `gxprof`. Each sample is tagged with the current input item, so the two tools line up. A test fails loudly if the Gambit internals it uses change.
4. **Find the lag, together with the owner** (owner, 2026-10-27: build the profiling first; no lag analysis or fixes by the implementer).

**Not now:** profiling views inside Tuna, and tracking performance across builds.

## As built: stages 1–3 (2026-10-27, branch `profiler-1`)

Report: `/home/jay/Code/workbench-gerbil/scratch/profiler/stage1-report.md`. The kernel did not change.

**General hooks** (each runs with no listener at the cost of an empty hook run; none mentions profiling):

| Hook | Owner | Runs on | Arguments | Other users |
|---|---|---|---|---|
| `input-arrived-hook` | web contract | request thread | client, sequence, item | input logging and replay, a sync indicator |
| `input-resolved-hook` | keys contract (keys plugin) | baton | client, sequence, item, task name or `#f` | the web plugin (which input a screen includes), lossage (`C-h l`), keyboard macros |
| `screen-ready-hook` | web contract | baton, after each redisplay | client, revision or `#f` (unchanged), last input included | a sync indicator, tests |
| `screen-sent-hook` | web contract | stream thread | client, stream, count, revision, last input included, bytes | bandwidth meter, a sync indicator |
| `screen-applied-hook` | web contract | request thread | client, stream, count, the page's measurements (alist) | a latency indicator, a slow-tab warning |
| `job-started-hook`, `job-finished-hook` | jobs library | baton | job id, key (and how it ended) | a busy indicator, a job log |
| `redraw-started-hook`, `redraw-finished-hook` | renderer contract (HTML renderer) | baton | client (and pieces drawn, reused, the screen's HTML) | a redraw counter, tests (replacing `current-memo-draw-observer` counting) |

Also: `memo-cache-last-drawn` / `-last-reused` (memo library), `html-size` (renderer contract), `job-id` (jobs library). Existing hooks used: `task-started-hook`, `task-finished-hook` (kernel), `pre-command-hook`, `post-command-hook` (commands; the profiler brackets them with callbacks at depths ±1,000,000).

**The page** (`plugins/web/frontend/tuna-applied.ts`): each screen's `data-init` calls `tunaApplied` instead of `@post('/applied…')`; it posts the same `/applied` with `{tab, applied: {revision, through, morph, settle, keys: [[seq, keyToSend, sendToReceived]…], painted: [stream, count, ms]}}`. `morph` is from the screen's event arriving (a capturing `datastar-fetch` listener) to Datastar having applied it; `settle` from then to `data-init`; `paint` from `data-init` to the first task after the next animation frame (VS Code's method). A paint goes with the next confirmation, or alone after 200 ms, so pacing is unchanged and no extra request is made while typing. Each screen carries `data-through`, the last input sequence of its tab the input service had taken when it was drawn.

**Placement:** `plugins/profiler/` holds two plugins in one module: `profiler` (the recorder: listeners, a writer thread; on when the plugin is on) and `profiler-commands` (`profiler-mode`, which turns `profiler` off and on through `deactivate-plugin!` and the configuration contract's `activate-plugin!`; `profiler-start`, `profiler-stop`). Private modules: `clock.ss` (monotonic clock and `##process-statistics` readings), `spans.ss` (the recorder; no hook knowledge, so tests drive it), `sampler.ss` (gxprof's heartbeat sampler and folded output). Contracts imported: commands, keys, clients, renderer, web, Tuna's configuration contract; libraries: jobs, plugin-options. Services: both declare `commands-service`, `renderer-service`, `page-service`, `configuration-service` (optional; `profiler-commands` requires `commands-service`). No default plugin imports the profiler; the demo declares both, the starter neither.

**Records:** a tree is held only while its item is in flight and is finished when its task has ended and every tab's branch is painted or unchanged, or after 10 s with nothing happening (written with `"complete": false`). Times are ms from the item's arrival on the server's monotonic clock; page-measured spans have `"start": null`. Allocation and GC are whole-process deltas while a span was open (other threads included). `network` = the page's round trip (sent to screen received) minus the server's time from arrival to writing that screen. Root details carry `key-to-screen` and `key-to-paint` (page clock) for the item's own tab.

**Not built: advice on service operations.** Callers reach a provider three ways: contract dispatchers through the kernel's `with-service-provider` (about 130 call sites); direct casts such as `(TextStore store)` or `(Renderer-render-screen …)`; and the kernel itself, calling the Display, Input and Messages services. Two designs were weighed (supervisor, 2026-10-27, chose neither for now; the hooks and the sampler cover the lag search):
- *A, opt-in at contract dispatchers (no kernel change):* the advice library keeps an advice target per (service, operation), and a contract routes chosen dispatchers through it, composing over the current provider as command advice composes over the current definition. One null check when unadvised. Misses direct casts and the kernel's own calls, and changes contract dispatchers for one consumer.
- *B, wrap the provider in the kernel:* `service-provider` returns an advised wrapper, covering every caller. Grows the kernel (an ADR 12 amendment and an owner decision).
Recorded in `TODO.md` as an open design question for the owner.

`profiler-stop` stops the heartbeat sampler on the editor thread (quick) and names, folds and writes the samples off it (`off-thread`), so a long run never stalls the editor; frame names are cached per procedure, as gxprof does.

**Limits:** the off-baton hooks (arrival, sent, applied) run on transport threads; a callback that raised there would be removed and reported through Messages off the baton, so the profiler's callbacks never raise. The sampler takes over Gambit's heartbeat interrupt (it chains to `##thread-heartbeat!`, so threads are still preempted); samples are taken only while a thread runs, and labels name the last input item taken.
