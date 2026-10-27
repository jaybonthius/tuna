# Plan: profiler

Brief: [`docs/briefs/2026-10-profiler.md`](../../docs/briefs/2026-10-profiler.md) (decided 2026-10-12; resumed 2026-10-27 because the editor lags). Research: [`agents/research/profiling/`](../research/profiling/), especially `01`–`03` (2026-10-27) and `racket-profiler-extraction-research.md`. ADRs 1, 2, 3, 7, 12, 17.

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
4. **Find the lag.** Profile typing, scrolling a large file, terminal output and several tabs, and report where the time goes.
5. **Fix it.** One fix at a time, each in the plugin that owns the slow part.

**Not now:** profiling views inside Tuna, and tracking performance across builds.
