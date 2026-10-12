# Profiling research

Owner-facing proposal: [`docs/briefs/2026-10-profiler.md`](../../../docs/briefs/2026-10-profiler.md).

## Sources

| Source | What it shows |
|---|---|
| Koyo: `/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt`, `/home/jay/Code/koyo/koyo-doc/scribblings/profiler.scrbl` | Instrumenting profiler: `with-timing label description body` builds a parent/child timing tree per request through parameters (`current-profile`, `current-timing-id`); disabled cost is one parameter check; captures database statements per timing by listening to a logger topic; renders a collapsible widget. Lesson: correlate extra data (queries, allocations) through existing general channels (a logger), not by changing the code being measured. |
| Gerbil `gxprof`: `/home/jay/Code/workbench-gerbil/gerbil/src/tools/gxprof.ss`, `doc/reference/dev/profiler.md` | Statistical profiler: `##set-heartbeat-interval!` plus `##interrupt-vector-set! 2` installs a handler that captures the continuation on each heartbeat and records frame creators. Can be started and stopped in process. Internal primitives. |
| Gambit `##process-statistics` | 20-element f64vector including user/system/real time, GC time, and bytes allocated (checked on v0.19-dev-63); cheap per-span allocation and GC accounting. |
| Emacs `elp.el`, `profiler.el` (`/home/jay/Code/emacs/lisp/emacs-lisp/`) | `elp` instruments named functions or whole packages by advice at runtime; `profiler.el` samples CPU and memory and reports a call tree. |
| [`racket-profiler-extraction-research.md`](racket-profiler-extraction-research.md) | The Racket Tuna's profiler was entangled in host construction, command admission, runtime, publication, HTTP routing and rendering; extracting it required generic observation seams. The exact mistake repeated in this attempt's stage 4 and reverted in `380fdc0`. |
| **Warning** | `tuna-profiler-stream-design.md` recommends threading a private profile token through the runtime's command request and state root (its "Option A"). That is exactly the core entanglement Tuna forbids; do not port it. The kernel audit (`../kernel-audit-2026-10-12.md`) also notes that kernel hooks are baton-confined, so arrival and delivery observation on HTTP threads needs the transport plugin's own thread-safe observers. |
| [`tuna-profiler-generic-gerbil-research.md`](tuna-profiler-generic-gerbil-research.md), [`tuna-profiler-stream-design.md`](tuna-profiler-stream-design.md), [`tuna-profiler-gerbil-idioms.md`](tuna-profiler-gerbil-idioms.md) | The August Gerbil attempt's span-tree profiler research: exact monotonic spans versus statistical samples answer different questions; fake-clock tests; latest-only publication. |

## Constraints for any design

- No profiler vocabulary in the kernel, service contracts, or default plugins (ADR 12, AGENTS.md "Keep the kernel small"). Only general-purpose hooks, lifecycle events, and advice.
- Core modules compile with `block` and cannot be advised (ADR 1); they are covered by lifecycle events and sampling.
- Spans are thread-scoped (parameters); background jobs start with a cleared dynamic environment (ADR 3), so job spans are correlated through the job lifecycle events, not inherited parameters.
