# Research: how interactive apps measure input-to-screen latency and find what is slow

Date: 2026-10-27 (researcher subagent, read-only). Complements, without repeating, the other files in this folder and `docs/briefs/2026-10-profiler.md`; read `agents/plans/profiler.md` for the current plan.

Labels: **Fact** = stated by the cited primary source. **Interpretation** = my reading of a source. **Inference** = my own reasoning, not stated by any source.

Acronyms: **SSE** Server-Sent Events (one long HTTP response that streams events). **INP** Interaction to Next Paint (web metric: input to the next frame). **LoAF** Long Animation Frames (browser API). **RUM** Real-User Monitoring (measuring in users' browsers). **EDT** Event Dispatch Thread (Java's UI thread). **TSC** Time Stamp Counter (CPU cycle clock). **NTP** Network Time Protocol. **p75/p98** 75th/98th percentile. **GC** garbage collection.

## Summary

Every mature tool splits the problem in two. **End-to-end** measurement says *whether* input is slow and how often: typometer, VS Code's input-latency sampler, INP, JetBrains' freeze watchdog. **Per-stage** measurement says *where* the time went: span or zone trees (Tracy, puffin, Zed tracing, elp, Neovim `:profile`), plus sampling for code nobody instrumented (profiler.el, Chrome's flame chart). Nobody correlates clocks across machines by trusting timestamps. Each process measures **durations on its own monotonic clock**, and the parts are joined by an **ID**. Where one timeline is needed, tools record explicit clock-pair snapshots (Perfetto, Tracy for GPU clocks) or estimate an offset from round trips (NTP).

For Tuna: tag every key with `(tab, sequence)` and every screen with `(stream, count)`. Have each side report durations only. Compute "network plus queueing" as the browser's round trip minus the server's time holding the key. Keep the worst N keys in full, and percentiles for all of them.

## Findings

### A. Editors

1. **Claim:** Emacs offers three separate tools.
   - `profiler.el` samples call stacks (default interval 1,000,000 ns, so 1 ms; SIGPROF timers in `src/profiler.c`). It can save a profile and diff two (`profiler-write-profile`, `profiler-find-profile`, `profiler-report-compare-profile`).
   - `elp` instruments named functions or a whole package prefix through advice. It reports call count, total time and average time, sortable by each, with no percentiles and no maximum.
   - `benchmark-run`, `benchmark-call` and `benchmark-progn` time a form and report elapsed time, GC count and GC time.

   Redisplay has only debug tracing: `trace-redisplay` works only in `GLYPH_DEBUG` builds, and `dump-redisplay-history` prints a ring buffer to stderr. **Sources:** local Emacs checkout `541f693c` (`lisp/profiler.el:39,178,786,880`; `lisp/emacs-lisp/elp.el:146-170`; `lisp/emacs-lisp/benchmark.el:46-60,152-165`; `src/xdisp.c:930-945,23747`; `src/dispnew.c:214`). **Support:** direct. **Confidence:** high.
   - **Inference:** Emacs has no built-in "key to redisplay" end-to-end timer. Its tools are per-function and statistical only, which is the gap Tuna's plan already targets.

2. **Claim:** Neovim's `--startuptime` "write[s] timing messages" for startup. `:profile` records, per function and per line, a count, a **total** and a **self** time, and writes them to a file on exit or on `:profile dump`. The documentation warns that "Real elapsed time is measured… run the profiling several times and use the lowest results", that line times add up to less than the function time ("some overhead in between"), and that self time is wrong for recursive functions. **Sources:** Neovim 0.9.5 runtime docs, `/usr/share/nvim/runtime/doc/starting.txt:106-110` and `repeat.txt:935-1035`. **Support:** direct. **Confidence:** high.

3. **Claim:** VS Code measures per-stage input latency in the renderer. It sets `performance.mark` at keydown start and end, at `beforeinput`/`input` start and end, and at render start and end (the first animation frame after input). It closes a sample with a `setTimeout` task and direct checks in the next keydown, keyup and `selectionchange`, so that the sample includes the browser's layout and paint. Each stage keeps **average/min/max**. The results are flushed at most once per 60 s to `performance.inputLatency` telemetry, gated by a per-session sampling probability. For deeper work, the wiki points to DevTools Performance recordings of the renderer, extension-host CPU profiles (via "Developer: Show Running Extensions"), `code --prof-startup`, and the "Startup Performance" report. **Sources:** [base/browser/performance.ts](https://github.com/microsoft/vscode/blob/main/src/vs/base/browser/performance.ts), [inputLatencyContrib.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/performance/browser/inputLatencyContrib.ts), [Performance Issues wiki](https://github.com/microsoft/vscode/wiki/Performance-Issues). **Support:** direct. **Confidence:** high.
   - **Inference:** this is the closest prior art to Tuna's browser side. It shows how to approximate "after paint" from JavaScript: mark at the start of the animation frame, then close on the first task after that frame.

4. **Claim:** Zed uses three tools:
   - `samply`, a sampling profiler that opens in the Firefox Profiler, for quick flame charts;
   - `tracing` spans exported to **Tracy** (`ZTRACING=1 … --features tracy`), with a workflow of "filter… to the slower calls" in a histogram, then "zoom to zone" in the timeline;
   - an always-on task profiler for foreground and background executors, saved as `.miniprof.json`.

   Zed also uses `zlog::time!(…).warn_if_gt(100ms)` to log slow functions. **Sources:** [zed docs/src/performance.md](https://github.com/zed-industries/zed/blob/main/docs/src/performance.md). **Support:** direct. **Confidence:** high. No Zed source on frame-timing overlays was verified.

5. **Claim:** JetBrains' `PerformanceWatcherImpl` regularly posts a probe onto the EDT and times how long it waits. It records Apdex (a satisfaction score from response times) against `TOLERABLE_LATENCY = 100` ms. When the EDT is unresponsive past a registry interval, it writes `threadDumps-…` folders with a `.duration` marker, which it reports on the next start. A process-stall watcher reports stalls over 1000 ms by default. **Sources:** [PerformanceWatcherImpl.kt](https://github.com/JetBrains/intellij-community/blob/master/platform/platform-impl/src/com/intellij/diagnostic/PerformanceWatcherImpl.kt). **Support:** direct. **Confidence:** high. The user-facing "Reporting performance problems" page returned HTTP 403, so it was not read.

6. **Claim:** Sublime Text runs plugins in a separate `plugin_host` process, and `cProfile` is excluded on Linux in some builds. No Sublime latency profiler was found. **Sources:** [Sublime API environments](https://www.sublimetext.com/docs/api_environments.html). **Support:** direct for the process model. **Confidence:** low for "no profiler".

7. **Claim:** In its retrospective, Xi concludes that "Async is a complexity multiplier" and "the process separation between front-end and core was not a good idea". `xi-trace` records instant and duration samples, is "disabled initially", and saves in "Trace Viewer format" for `about:tracing`. Raph Levien's later work defines the target as "input-to-photon latency". He warns that "it's easy to get misled by looking only at software traces; the only way to *really* get to the source of truth is measurement on a real, physical system". **Sources:** [xi retrospective](https://raphlinus.github.io/xi/2020/06/27/xi-retrospective.html), [xi_trace docs](https://docs.rs/xi-trace/latest/xi_trace/), [Swapchains and frame pacing](https://raphlinus.github.io/ui/graphics/gpu/2021/10/22/swapchain-frame-pacing.html). **Support:** direct. **Confidence:** high.
   - **Inference:** Tuna has the same front-end/core split, so Xi's lesson applies: measure the seam, and expect the trouble to be ordering and queueing rather than pure CPU time.

### B. Browser and server-driven UI

8. **Claim:** The Event Timing API gives each discrete input event its own breakdown:
   - `startTime` is the event's `timeStamp`, used as the hardware input time;
   - `processingStart` and `processingEnd` bracket the handlers;
   - `duration` runs to the next rendering update, rounded to 8 ms;
   - `interactionId` groups a key's keydown and keyup.

   Entries are buffered only at 104 ms or more by default; `durationThreshold` has a 16 ms minimum. INP splits each interaction into input delay, processing duration and presentation delay. Its rating is ≤200 ms "good" at p75, computed per page as about p98 by ignoring one worst interaction per 50. INP covers only the *next* paint, not "eventual effects… such as network fetches". **Sources:** [Event Timing spec](https://w3c.github.io/event-timing/), [web.dev INP](https://web.dev/articles/inp). **Support:** direct. **Confidence:** high.
   - **Inference:** for Tuna, the keydown's INP measures only the browser's key handler and the `fetch` send. The screen arrives later over SSE, so INP cannot see the round trip. It is a health check for the input plugin, not the end-to-end number.

9. **Claim:** Long Animation Frames reports frames over 50 ms, with:
   - `startTime`, `renderStart` and `styleAndLayoutStart`;
   - `blockingDuration`;
   - `firstUIEventTimestamp`;
   - a `scripts[]` array for scripts over 5 ms, with `invoker`, `sourceURL`, `forcedStyleAndLayoutDuration` and other fields.

   `duration` excludes presentation. There is "no direct API to link an INP entry with its related LoAF entry". Its buffer holds 200 entries, so the guide recommends a `PerformanceObserver` and keeping only the worst 10. **Sources:** [Chrome LoAF guide](https://developer.chrome.com/docs/web-platform/long-animation-frames). **Support:** direct. **Confidence:** high.
   - **Inference:** for a slow morph, LoAF is the in-page way to split "our script" from "style and layout". That split matters for Datastar's fat morphs.

10. **Claim:** User Timing `performance.mark` and `performance.measure` accept `detail`. If `detail.devtools` has a `track` (with optional `trackGroup`, `color` and `properties`), Chrome DevTools draws a custom track. `console.timeStamp(label, start, end, track, group, color)` shows only in the Performance panel and is "designed for minimal runtime overhead". The Performance panel shows an Interactions track with input-delay and presentation whiskers, red triangles for INP over 200 ms and for long tasks over 50 ms, CPU throttling, and traces that can be saved and reloaded with annotations. **Sources:** [DevTools extensibility API](https://developer.chrome.com/docs/devtools/performance/extension), [User Timing](https://w3c.github.io/user-timing/), [Performance reference](https://developer.chrome.com/docs/devtools/performance/reference), [Save trace](https://developer.chrome.com/docs/devtools/performance/save-trace). **Support:** direct. **Confidence:** high.

11. **Claim:** The browser's `performance.now()` is monotonic and relative to `timeOrigin`. Its resolution is coarsened to 100 µs, or 5 µs when cross-origin isolated. The High Resolution Time spec advises: "Avoid sending similar representations between computers… send… a duration between two moments." Server-Timing (`metric;dur=…;desc=…`) deliberately omits `startTime` because "there can be no guarantee of clock synchronization between client, server, and intermediaries". **Sources:** [High Resolution Time](https://w3c.github.io/hr-time/), [Server Timing](https://w3c.github.io/server-timing/). **Support:** direct. **Confidence:** high.

12. **Claim:** React's `<Profiler onRender>` reports `actualDuration` and `baseDuration` (the estimated cost without memoization), plus `startTime` and `commitTime`. It is disabled in production builds because of overhead. **Sources:** [react.dev Profiler](https://react.dev/reference/react/Profiler). **Support:** direct. **Confidence:** high.
    - **Inference:** "actual versus base" is the same comparison as Tuna's "pieces rebuilt versus reused" (ADR 17).

13. **Claim:** Phoenix LiveView provides:
    - server-side `:telemetry` start and stop events for `mount`, `handle_event`, `render` and component `update`, with `duration` in native time units;
    - client-side `liveSocket.enableProfiling()`, which wraps phases in `console.time`;
    - `enableDebug()`, which logs payloads;
    - `enableLatencySim(ms)`, which delays channel messages;
    - `dom.onPatchStart` and `dom.onPatchEnd` hooks.

    Hotwire Turbo exposes `turbo:before-stream-render`, `turbo:before-morph-element`, `turbo:morph` and `turbo:submit-start`/`turbo:submit-end`. Only `turbo:load` carries timing fields (`visitStart`, `requestStart`, `requestEnd`, `visitEnd`). Datastar's vendored docs list `datastar-fetch` events (`started`, `finished`, `error`, …) but no timing API. **Sources:** [LiveView telemetry](https://hexdocs.pm/phoenix_live_view/telemetry.html), [LiveView JS interop](https://hexdocs.pm/phoenix_live_view/js-interop.html), [live_socket.ts](https://github.com/phoenixframework/phoenix_live_view/blob/main/assets/js/phoenix_live_view/live_socket.ts), [Turbo events](https://turbo.hotwired.dev/reference/events), `agents/reference/datastar/docs.md:2793-2799`. **Support:** direct. **Confidence:** high.
    - **Inference:** no server-driven framework found correlates one input end to end. Each times its server and client halves separately. A latency simulator is a cheap, useful addition.

### C. Games and real-time tools

14. **Claim:** Tracy is a "hybrid frame and sampling profiler". You mark frames with `FrameMark`, or with `FrameMarkStart`/`FrameMarkEnd` for discontinuous frames. Zones nest. Its timer is the TSC at "single-digit nanosecond" resolution. Its benchmark measured an overhead of 2.25 ns per zone. Outliers are found through:
    - a frame-time graph against a target FPS;
    - a "Find zone" histogram per zone, where you select the tail;
    - "Compare traces" between two saved captures.

    GPU timestamps sit in a separate clock domain that Tracy corrects with optional periodic CPU/GPU calibration. Statistical sampling "cannot accurately pinpoint the underlying cause for semi-random frame stutter". **Sources:** [Tracy manual (tracy.tex)](https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex), [README](https://github.com/wolfpld/tracy). **Support:** direct. **Confidence:** high.

15. **Claim:** puffin's scopes cost "around 50-200 ns" when on and about 1 ns when off. It needs `new_frame()` once per frame, and `puffin_http` streams to a remote viewer. Optick covers instrumentation, context switches, sampling and GPU per frame (`OPTICK_FRAME`), but gives no overhead figures. Unreal Trace streams events by channel (Frame, Cpu, Gpu, Bookmark, …) over TCP port 1981 to a trace server, which stores files. It offers tail tracing (a 4 MB ring by default), late connect, bookmarks and snapshots. **Sources:** [puffin README](https://github.com/EmbarkStudios/puffin), [Optick README](https://github.com/bombomby/optick), [Unreal Trace docs](https://dev.epicgames.com/documentation/en-us/unreal-engine/trace-in-unreal-engine-5). **Support:** direct. **Confidence:** high, but medium for Unreal session comparison, which was not found.

16. **Claim:** Perfetto aligns clock domains with ClockSnapshot packets ("at this point in time, … X,Y,Z was 1000, 2000, 3000") and converts by nearest earlier snapshot plus delta. It treats each machine's clock as a separate node, joined only by explicit edges. NTP estimates offset from four timestamps: θ = ½[(T2−T1)+(T3−T4)], with delay δ = (T4−T1)−(T3−T2). **Sources:** [Perfetto clock sync](https://perfetto.dev/docs/concepts/clock-sync), [RFC 5905 §8](https://www.rfc-editor.org/rfc/rfc5905.txt). **Support:** direct. **Confidence:** high.
    - **Interpretation:** the NTP formula assumes symmetric paths. The asymmetric part of the delay shows up as offset error, bounded by δ/2.

### D. Typing-latency research

17. **Claim:** Pavel Fatin splits typing latency into input (keyboard), processing (software) and output (monitor). Typometer measures processing latency end to end, "by generating OS input events and using screen capture". It samples one pixel per character and has a synchronous mode (the most accurate) and an asynchronous mode (rapid typing). It reports min, max, average, standard deviation (as "jitter") and distribution charts, and exports CSV to merge and compare runs. Fatin argues "average values are better measure of latency than median values and why maximum values are very important". He notes that compositors add a frame (Aero ~17 ms; Compiz ~8–10 ms). **Sources:** [Typing with pleasure](https://pavelfatin.com/typing-with-pleasure/), [typometer README](https://github.com/pavelfatin/typometer). **Support:** direct. **Confidence:** high.

### Cross-cutting comparison

| Tool | End-to-end or per stage | Correlation across processes | How outliers are shown | Overhead (stated) | Kept and compared over time |
|---|---|---|---|---|---|
| profiler.el / elp / benchmark | per function / statistical | single process | elp: totals and averages only | sampling 1 ms; elp is advice | profiler: write and compare |
| Neovim `:profile` | per line and per function | single process | none; rerun and take the lowest | "overhead in between" lines | file per run |
| VS Code inputLatency | per stage plus total, in the renderer | renderer only | min/avg/max per batch | sampled per session | telemetry, every 60 s |
| JetBrains watcher | EDT probe latency, freezes | thread dumps | freeze dumps, Apdex | periodic probe | dump folders, reported next start |
| Zed / Tracy | zone tree per frame | client streams to viewer; GPU calibrated | histogram, then tail, then zone | 2.25 ns per zone | saved traces, Compare traces |
| Event Timing / INP / LoAF | per stage inside the browser | none (one page) | ≥104 ms buffer; p98 per page, p75 across pages; worst-N | done by the user agent | RUM beacons |
| Server-Timing | server durations only | ID or description, no start time | n/a | header bytes | per response |
| Perfetto / NTP | timeline across domains | clock snapshots / 4-timestamp offset | n/a | n/a | trace files |
| typometer | true end to end | external (screen) | SD, max, distributions | none in the app | CSV merge and compare |

## Contradictions

- **Which statistic?** Fatin favours *average plus maximum* over median. The web uses percentiles: p98 within a page, p75 across pages. VS Code reports min/avg/max. Tracy relies on histograms. The positions are not reconciled. **Inference:** keep the raw samples (or a histogram), the max, and the worst-N trees; a single summary number hides the tail.
- **Software traces versus physical measurement.** Levien says software traces can mislead and photons are "the source of truth". Browser APIs end at "next paint", and LoAF `duration` excludes presentation. Neither sees the compositor or monitor delay (≈1 frame or more).
- **Sampling versus instrumentation.** Tracy says sampling cannot explain sporadic stutter. Zed and Emacs still use sampling first, for hot spots. These answer different questions; both are needed.

## Missing evidence

- JetBrains' user-facing freeze-report documentation (HTTP 403), and whether a built-in typing-latency report exists today.
- Zed frame-time overlays or GPUI (Zed's UI framework) frame statistics: not found.
- Sublime Text latency tooling: none found.
- Datastar or community practice for timing a morph or an SSE round trip: none found in the vendored docs; no web search was possible (no search provider was configured).
- Whether Datastar's `data-init` runs before or after paint. **Inference:** it runs during DOM patching, before the frame paints, so Tuna's current `/applied` post marks "morph done", not "painted". This needs checking against Datastar's source.
- Whether Perfetto UI loads Chrome JSON trace files directly. I believe so, but it is unverified here.

## Recommendation for Tuna (plain language)

**Facts this relies on:** VS Code, INP and LoAF split browser time into "waiting, handling, drawing". Server-Timing and the High Resolution Time spec say not to compare timestamps across machines, only durations. Tracy and Perfetto join domains through explicit IDs or clock pairs. The rest is my inference.

**What to measure.** Number every key; Tuna already sends `(tab, sequence)`. Record these stages:

1. **Browser, key to send** (from `event.timeStamp` to just before the `/commands` `fetch`). Stays small unless the browser is busy; Event Timing's input delay confirms it.
2. **Server, arrival to command start.** This is queueing: the serialized command owner, plus earlier keys.
3. **Server, command, hooks, services** (the existing span tree).
4. **Server, redraw**: pieces rebuilt versus reused, and HTML size.
5. **Server, ready to written.** Time waiting because the tab has not yet applied the previous screen. The flow control in `plugins/web/plugin.ss` sends a new screen only after `/applied` for the last one. A slow browser therefore shows up here as *server-side waiting*, and it must be its own stage or it will be misread as editor slowness.
6. **Browser, SSE event received to morph start, then morph** (Datastar patch duration). For a long frame, add LoAF's script versus style-and-layout split.
7. **Browser, morph done to next paint.** Approximate this like VS Code: mark in the next `requestAnimationFrame`, then close in the first task after that frame. Add the LoAF frame when it is long.

End to end = from `event.timeStamp` of key N to the paint of the first screen that includes key N. For that, the server must put "includes keys up to sequence S" on each screen. Without this, many keys collapse into one screen and the browser cannot say which key a paint answers.

**How to correlate the two clocks.**

- Join records by ID, not by time: `(tab, sequence)` for keys and `(tab, stream, count)` for screens. The browser sends **durations measured on its own `performance.now()`**, attached to `/applied` (or the next `/commands`). The server measures durations on its monotonic clock.
- Network plus OS time per key, with no clock agreement needed:
  > browser (sent → screen received) − server (key arrived → screen written)

  That uses four timestamps, two on each clock, as in NTP.
- Only to *draw* both sides on one timeline (optional), estimate the offset with the NTP formula from those same four timestamps per key. Use the key with the smallest round trip, and show ±δ/2 as the uncertainty. Never feed browser timestamps into editor logic.
- Do not use `Date.now()` or wall-clock time on either side.

**Outliers and storage.**

- Keep a bounded ring with the full tree for the worst N keys (N≈10, as LoAF and web.dev do) and the most recent M keys.
- For every key, keep only per-stage numbers in a histogram. Report max, p50, p95, p99 and average; average and max follow Fatin.
- Make "show me the slow ones" one click from a histogram, as in Tracy and Zed.
- Allow saving a run to a file and diffing two runs (Emacs `profiler-report-compare-profile`, Tracy Compare traces, typometer CSV).
- Optionally export in Chrome Trace format, with the browser marks exported as User Timing measures carrying `detail.devtools.track`. Server and browser stages would then sit next to Chrome's own rendering tracks. Whether this is worth doing is untested.

**Physical truth, occasionally.** Once the stages look fine but typing still feels laggy, run typometer-style screen-capture tests (or a hardware photon tester). The compositor and monitor add at least one frame that no software trace sees.

**Placement** (per ADR 12, restated): every timer above lives in the profiler plugin and observes the web plugin through hooks. The only transport changes are general facts: the sequence a screen covers, and an opaque measurements field on `/applied`.

## Sources

- Kept: Emacs source (local, commit 541f693c): profiler.el, elp.el, benchmark.el, xdisp.c, dispnew.c. Primary source for Emacs tools.
- Kept: Neovim 0.9.5 runtime docs (local). `:profile` semantics and caveats.
- Kept: VS Code `performance.ts`, `inputLatencyContrib.ts`, Performance Issues wiki. Best per-stage browser prior art.
- Kept: Zed `docs/src/performance.md`. Tracy and samply workflow.
- Kept: JetBrains `PerformanceWatcherImpl.kt`. Freeze watchdog design.
- Kept: W3C Event Timing, User Timing, High Resolution Time, Server Timing. Normative definitions and the clock-sync stance.
- Kept: web.dev INP; Chrome LoAF, DevTools extensibility, Performance reference, Save trace.
- Kept: react.dev Profiler; LiveView telemetry, JS interop and `live_socket.ts`; Turbo events; vendored Datastar docs.
- Kept: Tracy manual and README; puffin README; Optick README; Unreal Trace docs.
- Kept: Perfetto clock sync; RFC 5905. Clock-domain correlation.
- Kept: Fatin, "Typing with pleasure"; typometer README; Levien, xi retrospective and "Swapchains and frame pacing"; `xi_trace` docs.
- Rejected/unavailable: JetBrains support article (HTTP 403). Neovim HTML docs (not extractable; the local docs were used instead). Web search (no provider was configured; known primary URLs were fetched directly).

## Next steps

- Read Datastar's source for when `data-init` runs relative to the patch and paint, and whether the patch can be bracketed with marks.
- Prototype only the browser half (stages 1, 6, 7 and LoAF) in a scratch page, to see the browser's share before building server stages. This step is for whoever implements it; it is not research.
