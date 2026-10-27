# Plan: profiler

**Decided 2026-10-27 after the prior-art research** (`agents/research/profiling/01`–`03`): results are Chrome Trace Event JSON files (spans) and folded stacks (samples), opened in Perfetto, speedscope or the Firefox Profiler; every key press's full span tree is recorded by default, with options for what to keep; the sampler is part of the profiler (opt-in start and stop, as everywhere); no in-editor report buffer and no cross-build benchmark tracking for now.

Brief (decided 2026-10-12; deferred by the owner 2026-10-16; resumed 2026-10-27 because the editor lags): [`docs/briefs/2026-10-profiler.md`](../../docs/briefs/2026-10-profiler.md). Research: [`agents/research/profiling/`](../research/profiling/), above all `racket-profiler-extraction-research.md` (how the Racket profiler leaked into the core; never again). ADRs 1 (advice), 2 (receipts), 3 (jobs), 7 (screens and `/applied`), 12 (small kernel), 17 (memo and sources).

## Invariants

- **Outside the core.** Tuna's kernel and default plugins never mention profiling. They gain only general-purpose hooks, each cheap with no listener and useful to others (macro recording, logging, busy and sync indicators). Turning the profiler off, or never installing it, leaves nothing behind (receipts).
- **Results go to files** in standard formats: Chrome Trace Event JSON for spans (one trace file per profiling session, under `$XDG_STATE_HOME/tuna/profile/` by default; path, rotation and a minimum-duration filter are options, default keep everything) and folded stacks for samples. A `*profile*` report buffer is later, not now.
- **Emitters never know consumers** (`:telemetry`, `tracing`, JFR): general started/finished hooks carry plain metadata (item id, command, job id); the profiler is one subscriber.
- **Browser and server are joined by IDs and durations, never clocks** (research 02): keys by `(tab, sequence)`, screens by `(tab, stream, count)`; each screen states the last key sequence it includes; the browser reports durations on its own clock with `/applied`; waiting for the browser's `/applied` is its own stage.
- **End to end.** An input item's tree runs from the browser's key event to the browser having applied the resulting screen, so it shows whether lag is in the browser, the network, the editor or a job. Times are monotonic; browser times are reported relative to the browser's own event so clocks never need to agree.
- **Cheap when off;** bounded memory when on (ring of the last N trees, configurable).
- Updates to the brief's facts (2026-10-27): job started and finished come from hooks in `tuna/lib/jobs.ss` (the kernel only sees the `job-result` task); redraw is memoized pieces (ADR 17), so the tree shows pieces rebuilt versus reused; several tabs each have their own screen and `/applied`.
- Docs as each stage merges (overview, Emacs table: `profiler.el`, `elp`, `benchmark-run`; roadmap; this plan; the brief's status and diagram).

## Stages

1. **Where the time goes for one key press.** General hooks where missing:
   - web plugin: input item arrived; screen sent to a tab; screen applied by a tab, carrying the browser's own measurements (key event to send, morph duration, time to next paint);
   - jobs library: job started and finished;
   - redraw started and finished, with pieces rebuilt and reused, if the renderer does not already say;
   - advice on service operations (ADR 1, planned, not built).

   Then `profiler` builds a span tree per input item, recording allocation and GC time per span (Gambit process statistics), and appends it to the profile files; `M-x profiler-mode` toggles it; a summary script prints the slowest items and totals per span.
2. **Sampling.** `M-x profiler-start` / `profiler-stop` / `profiler-report`: statistical call-stack sampling on Gambit's heartbeat, as `gxprof` does, with a test that fails loudly if the `##` primitives change. Results go to the profile files as a call tree of the hottest code, Tuna's own core included.
3. **By name and by hand.** `M-x profile-function` and `profile-plugin` through advice, undone by receipts. A `with-span` form for detail inside one function: a single check when no profiler listens.
4. **Find the lag.** Use stages 1–3 on the owner's real workloads (typing, scrolling, the terminal, several tabs) and fix what they show, each fix in its proper owner.
