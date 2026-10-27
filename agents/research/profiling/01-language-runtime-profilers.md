# Research: how mature language runtimes profile, and what Tuna should copy

Intended home: `agents/research/profiling/01-language-runtime-profilers.md`. Read-only research; no Tuna code changed. Researched 2026-10-27.

## Summary

Every mature runtime ships **two kinds of tool, and keeps them separate**. (1) A **sampling profiler**: a timer interrupts the program about every 1–10 ms and records the call stack. It is cheap enough to leave on and needs no code changes; it answers "which code is hot". Examples: Go pprof, async-profiler, py-spy, V8's CPU profiler, Racket `profile`, Gerbil `gxprof`. (2) A **span/event channel**: the code being measured only *emits* named start/stop events, and separately installed *subscribers* (also called handlers or listeners) decide whether to record, aggregate or discard them. It costs about one check when nobody listens. It answers "how long did this key press take, and in which step". Examples: Erlang `:telemetry`, Rust `tracing`, Node `diagnostics_channel`, Java Flight Recorder events, Go `runtime/trace` regions and tasks. Both work best with a **flight recorder**: a bounded in-memory ring of recent data that is written out only when something is slow.

For Tuna: copy `:telemetry`/`tracing`'s rule that emitters never know about consumers. Tuna's general hooks and advice already have that shape. Build the profiler plugin as one subscriber with a ring buffer, plus a heartbeat sampler copied from `gxprof`. Tag each sample with the current input item, as Go's pprof labels do, so that the two halves can be joined. Skip always-on HTTP endpoints, profile-guided optimisation (PGO), and per-function call tracing.

Acronyms: **CPU**, central processing unit. **GC**, garbage collection. **JVM**, Java Virtual Machine. **JFR**, JDK (Java Development Kit) Flight Recorder. **JIT**, just-in-time compiler. **PGO**, profile-guided optimisation. **BEAM**, the Erlang virtual machine. **BIF**, built-in function (Erlang). **eBPF**, extended Berkeley Packet Filter, a Linux kernel tracing facility. **CDP**, Chrome DevTools Protocol. **gRPC**, a remote-procedure-call protocol. **JMX**, Java Management Extensions. **GIL**, Python's global interpreter lock. **UI**, user interface.

Labels used below: **[fact]** means a source states it directly. **[interp]** means my reading of a source. **[inference]** means my own judgement, not stated by any source.

---

## Findings by runtime

### 1. Go

**pprof (`runtime/pprof`, `net/http/pprof`)**
- **Kind:** sampling for CPU and heap. Block and mutex profiles are event-sampled, the goroutine profile is a snapshot of all stacks, and threadcreate records stacks. **[fact]** The diagnostics page lists the profiles cpu, heap, threadcreate, goroutine, block and mutex. Block and mutex are "not enabled by default"; you switch them on with `runtime.SetBlockProfileRate` / `runtime.SetMutexProfileFraction` ([Go diagnostics](https://go.dev/doc/diagnostics)).
- **Sample rate:** **[fact]** the CPU rate is hard-coded at 100 Hz. The source comment says: "100 Hz is a reasonable choice: it is frequent enough to produce useful data, rare enough not to bog down the system" (`src/runtime/pprof/pprof.go:898`, Go 1.26.1). **[fact]** The heap is sampled about once per 512 KiB allocated (`var MemProfileRate int = 512 * 1024`, `src/runtime/mprof.go:880`, Go 1.26.1).
- **Data model:** **[fact]** "A Profile is a collection of stack traces showing the call sequences that led to instances of a particular event". Packages can define their own profiles with `NewProfile` ([runtime/pprof](https://pkg.go.dev/runtime/pprof)). **Labels:** `pprof.Do(ctx, labels, f)` attaches key/value labels to the goroutine, and goroutines it spawns inherit them. "Currently only the CPU and goroutine profiles utilize any labels information" ([runtime/pprof](https://pkg.go.dev/runtime/pprof)).
- **Switching it on:** through the API (`StartCPUProfile`/`StopCPUProfile`, `Lookup(name).WriteTo`) or through HTTP. **[fact]** "import _ \"net/http/pprof\"" registers handlers under `/debug/pprof/`. `?seconds=N` profiles the CPU (or traces) for N seconds; for the other profiles it returns a delta; `debug=N` switches between binary and text output ([net/http/pprof](https://pkg.go.dev/net/http/pprof)).
- **Overhead / always on:** **[fact]** "It is safe to profile programs in production, but enabling some profiles (e.g. the CPU profile) adds cost." The Go docs recommend profiling periodically, "profile it for X seconds for every Y seconds". They also warn that tools interfere with each other: "precise memory profiling skews CPU profiles" ([Go diagnostics](https://go.dev/doc/diagnostics)).
- **Viewing:** `go tool pprof` (top, call graph, flame graph, web UI). The protobuf pprof format has become a common interchange format.
- **Separation:** built into the runtime. The HTTP endpoint is an opt-in package that one import line registers.

**`runtime/trace` (the execution tracer)**
- **Kind:** event tracing. **[fact]** It records scheduling, syscalls, GC, heap size and similar runtime events. It is "not great for identifying hot spots" ([Go diagnostics](https://go.dev/doc/diagnostics)).
- **User annotations:** **[fact]** there are three: `Log` (a timestamped message), regions (`WithRegion`/`StartRegion`; these "must nest" within one goroutine), and tasks (`NewTask`, carried in a `context.Context` across goroutines). "The trace tool computes the latency of a task … and provides latency distributions for each task type" ([runtime/trace](https://pkg.go.dev/runtime/trace)).
- **Overhead:** **[fact]** "Prior to Go 1.21, the run-time overhead of tracing was somewhere between 10–20% CPU … cut dramatically, down to 1–2% for many applications", mainly by making stack tracebacks cheaper ([Go blog, 2024](https://go.dev/blog/execution-traces-2024)).
- **Flight recorder:** **[fact]** `trace.FlightRecorder` (Go 1.25) "tracks a moving window over the execution trace … always containing the most recent trace data"; `WriteTo` snapshots it. It is configured by `MinAge` (keep data for about twice the window of the event you are hunting) and `MaxBytes`. The documented pattern is to snapshot once when a request exceeds a latency threshold ([runtime/trace](https://pkg.go.dev/runtime/trace); [Go blog, flight recorder](https://go.dev/blog/flight-recorder)).
- **Viewing:** `go tool trace` shows timelines, goroutine analysis and task latency histograms.

**PGO** **[fact]**: the compiler reads a production CPU pprof profile (`default.pgo` in the main package, or `-pgo=path`); Go reports "around 2-14%" gains ([Go PGO](https://go.dev/doc/pgo)). **[inference]** This is irrelevant to Tuna: Gambit has no profile-guided compiler input that I know of. I did not verify that.

**Continuous profiling** **[fact]**: Parca (and Grafana Pyroscope) collect sampling profiles from fleets all the time. Parca says sampling "can be done with very little overhead, and therefore can always be on", and that "Go has popularized having HTTP endpoints to request profiles" ([Parca overview](https://www.parca.dev/docs/overview/)). **[inference]** That is a fleet concern. Tuna's equivalent is a local ring buffer, not a server.

### 2. JVM and Clojure

**JFR (JDK Flight Recorder)**
- **Kind:** event recording. Method sampling is one of its built-in events.
- **Data model:** **[fact]** typed events with a timestamp, a duration, a thread, a stack trace ID and payload fields. Users define events by subclassing `jdk.jfr.Event` and calling `commit()`. Per-event settings are `enabled`, `threshold` ("the duration below which an event is not recorded"), `stackTrace` and `period` ([JEP 328](https://openjdk.org/jeps/328)).
- **Storage:** **[fact]** "Threads write events, lock-free, to thread-local buffers … promoted to a global in-memory circular buffer … the oldest data is either discarded or written to disk". Recordings are `.jfr` files with a retention policy ([JEP 328](https://openjdk.org/jeps/328)).
- **Overhead:** **[fact]** the success metrics were "At most 1% performance overhead out-of-the-box on SPECjbb2015" and "No measurable performance overhead when not enabled". Enabling data collection by default was a non-goal ([JEP 328](https://openjdk.org/jeps/328)).
- **Switching it on:** `-XX:StartFlightRecording`, or `jcmd <pid> JFR.start / JFR.dump / JFR.stop`, or JMX ([JEP 328](https://openjdk.org/jeps/328)).
- **Consumers:** **[fact]** JEP 349 added `RecordingStream`/`EventStream.onEvent(name, handler)` for continuous in-process or out-of-process consumption. Synchronous callbacks are explicitly a non-goal ([JEP 349](https://openjdk.org/jeps/349)). **[fact]** JFR "maintains a typed event model where consumers are decoupled from internals by using an API" ([JEP 328](https://openjdk.org/jeps/328)).
- **Viewing:** JDK Mission Control, the `jfr` tool, async-profiler's converters.

**async-profiler**
- **[fact]** It is a "low overhead sampling profiler for Java that does not suffer from the Safepoint bias problem". It also tracks allocations and sees non-Java threads (GC, JIT). You start it with `asprof -d 30 -f flamegraph.html <PID>`, which attaches to a running JVM as an agent and writes an interactive HTML flame graph ([async-profiler README](https://github.com/async-profiler/async-profiler)). It can also output JFR, pprof and other formats (its `src/converter` tree).
- **[interp]** "Safepoint bias" means older JVM profilers could only sample at safepoints, which skews results. The lesson: a sampler must be able to interrupt at arbitrary points. Gambit's heartbeat interrupt has a related limit, because interrupts are polled at safe points in compiled code; see Gerbil below.

**clj-async-profiler**
- **[fact]** It is an "embedded" wrapper around async-profiler: `(prof/profile expr)` or `prof/start`/`prof/stop`. Results go to `/tmp/clj-async-profiler/results/` and are viewed as flame graphs, including through `(prof/serve-ui 8080)`. JDK 11+ needs `-Djdk.attach.allowAttachSelf`. "The profiling overhead is very low, so it can be used even in highly loaded production scenarios" ([README @441f525](https://github.com/clojure-goes-fast/clj-async-profiler/tree/441f525721453249c47e96353d4fc9e93d08976b)).
- **[inference]** This is the closest JVM analogue to a profiler that runs *inside* the editor and shows its report in the editor's own UI.

**tufte**
- **Kind:** instrumentation. You wrap forms in `(p :id …)`, and `profile`/`profiled` collect "pstats" (profiling statistics: per-id call count, min, percentiles, max, mean, accounted versus clock time).
- **[fact]** "`p` will ALWAYS execute its body and return the body's result, even when profiling isn't active" (`resources/docs/p.txt`). Results are "Metrics as Clojure maps". Signals are routed to handlers registered with `add-handler!`, with filtering by namespace, id and level, and sampling and rate limiting ([tufte README @edf5eb7](https://github.com/taoensso/tufte/tree/edf5eb7618c3bdc8da417cba80171899526f60d0)). Profiling is thread-local by default, with an opt-in `:dynamic?` mode for multithreaded profiling (wiki FAQ).
- **[fact]** The tufte FAQ itself places it next to sampling profilers rather than replacing them: "Tufte doesn't offer memory profiling … and it's not well suited to forensic or very low-level profiling".

**criterium**
- **[fact]** A benchmarking harness for a single expression: JIT warm-up, GC purge before and after, statistical processing, and blackholing results so the JIT cannot eliminate them; it estimates its own measurement overhead ([criterium README](https://github.com/hugoduncan/criterium)).
- **[inference]** It is not a profiler. Tuna needs it only for micro-benchmarks of fixes, and should use Gerbil's `time`/`##process-statistics` for that.

### 3. Erlang and Elixir

**[fact]** The OTP efficiency guide's tool summary ([Erlang profiling](https://www.erlang.org/doc/system/profiling.html)):
- **fprof:** call tracing written to a file. It records own and accumulated time, callers and GC. "Significant slowdown", large output.
- **eprof:** based on the `trace_info` BIFs. Per process and function, total time only. "Small slowdown".
- **cprof:** call counts per module, "low performance degradation", no recompilation needed.
- **tprof** (OTP 27+, experimental) "aims to replace `eprof` and `cprof`". It has three modes: `call_count` (cheapest), `call_time` and `call_memory`. It runs either ad hoc or in a server-aided mode "for deeper introspection of the code running in production", and patterns limit tracing to chosen functions. Caveats: "Expect a slowdown", and hot code reloading discards statistics ([tprof](https://www.erlang.org/doc/apps/tools/tprof.html)).
- **observer / etop / msacc:** observer is a GUI that you should "Run … from a standalone node to minimize the impact"; only the active view refreshes ([observer guide](https://www.erlang.org/doc/apps/observer/observer_ug.html)). msacc (microstate accounting) has "very low overhead" and shows where the runtime spends time ([Erlang profiling](https://www.erlang.org/doc/system/profiling.html)).
- **perf:** with the JIT, `+JPperf true` lets Linux `perf` sample Erlang code "with much lower overhead" than fprof.

**`:telemetry`** (the most relevant item in this report)
- **Kind:** an event dispatcher, not a profiler. **[fact]** "Any Erlang or Elixir library can use `telemetry` to emit events. Application code and other libraries can then hook into those events and run custom handlers." An event is a name (a list of atoms), measurements (a map) and metadata (a map) ([telemetry README](https://hexdocs.pm/telemetry/readme.html)).
- **Spans:** **[fact]** `telemetry:span/3` emits `prefix ++ [start]`, then `[stop]` or `[exception]`. The stop event carries `duration` from monotonic time, and every event carries `monotonic_time`.
- **Attaching:** **[fact]** `attach(HandlerId, EventName, Fun, Config)` / `attach_many`. Handlers "are invoked synchronously on each `telemetry:execute` call. Therefore, it is extremely important to avoid blocking operations … consider offloading the work to a separate process".
- **Separation:** **[fact]** "each Elixir library would publish its own set of events … Telemetry aims to provide a single interface". The emitter does not know who listens. Metrics, logging, profiling and OpenTelemetry are all separate handlers.

### 4. Python

- **cProfile (now `profiling.tracing`) and `profile`:** **[fact]** "deterministic" profiling, meaning "all function call, function return, and exception events are monitored", using a hook the interpreter provides. The pure-Python `profile` is deprecated in 3.15 and `cProfile` is now an alias for `profiling.tracing`. Results are `pstats.Stats`, sortable by self or cumulative time ([profile docs](https://docs.python.org/3/library/profile.html)). **[fact]** The same page warns that per-event timer overhead accumulates, and that the old module needs calibration.
- **`sys.monitoring` (3.12, PEP 669):** **[fact]** "Tool identifiers are used to discourage tools from interfering with each other and to allow multiple tools to operate at the same time" (ids 0–5). Callbacks are registered per event, and returning `DISABLE` turns an event off at one code location; "Disabling events for specific locations is very important for high performance monitoring" ([sys.monitoring](https://docs.python.org/3/library/sys.monitoring.html)). **[interp]** This is the runtime-level version of "general hooks that several tools share", with per-site switch-off as the answer to overhead.
- **py-spy:** **[fact]** a sampling profiler that runs out of process and reads interpreter memory with `process_vm_readv`. "extremely low overhead … safe to use against production". Subcommands are `record` (flame graph or speedscope output), `top` (live view) and `dump` (current stacks, optionally with locals) ([py-spy README](https://github.com/benfred/py-spy)).
- **`profiling.sampling` ("Tachyon", 3.15):** **[fact]** a standard-library sampling profiler that can `run`, `attach <pid>`, `dump` or show a `--live` view. "Because sampling occurs externally to the target process, overhead is virtually zero". It outputs pstats, flame graphs, Gecko (Firefox Profiler) format and heatmaps, and saved binary profiles can be replayed ([profiling.sampling](https://docs.python.org/3.15/library/profiling.sampling.html)).
- **Scalene:** **[fact]** a CPU, GPU and memory profiler with line-level results, a browser-based viewer (`scalene view`), and a configurable `cpu-sampling-rate` and `malloc-threshold` ([Scalene README](https://github.com/plasma-umass/scalene)). It splits Python time from native time. I have not verified its overhead claims.
- **3.12 perf integration:** **[fact]** `-X perf`, `PYTHONPERFSUPPORT`, or `sys.activate_stack_trampoline("perf")` at run time make Python functions visible to Linux `perf` through perf map files. The run-time switch lets a program profile just one region. Frame pointers give the best results ([perf profiling howto](https://docs.python.org/3/howto/perf_profiling.html)).

### 5. Rust

- **`tracing`:** **[fact]** "spans, events and subscribers". A span "represents a period of time with a beginning and an end", can be entered and exited, and nests into a tree. Subscribers filter with `enabled(metadata)`, and "if no currently active subscribers express interest … the corresponding Span or Event will never be constructed" ([tracing docs](https://docs.rs/tracing/latest/tracing/)). `tracing-subscriber` composes subscribers from `Layer`s.
- **tokio-console:** **[fact]** has three parts: a gRPC/protobuf wire protocol; `console-subscriber`, "an implementation of the instrumentation-side API as a `tracing-subscriber` `Layer`"; and a terminal UI client ("top for tasks"). It needs `--cfg tokio_unstable` ([tokio-console README](https://github.com/tokio-rs/console)). **[interp]** This is a whole diagnostic tool built purely as a subscriber to spans the runtime already emits, without changing the runtime.
- **puffin:** **[fact]** an instrumentation profiler for frame-based programs. `profile_function!` / `profile_scope!` write to a thread-local stream, which is flushed to a global collector when the outermost scope closes. Scopes cost "around 50-200 ns", and "When the profiler is off the profiler scope macros only has an overhead of 1 ns". You must call `GlobalProfiler::lock().new_frame()` once per frame. Data is viewed in the app through `puffin_egui` or remotely through `puffin_http` to `puffin_viewer` ([puffin README](https://github.com/EmbarkStudios/puffin)).
- **Tracy:** **[fact]** "A real time, nanosecond resolution, remote telemetry, hybrid frame and sampling profiler". It combines instrumented zones with sampling, and the program streams to a separate viewer ([Tracy README](https://github.com/wolfpld/tracy)). I did not verify finer details from the Tracy manual.

### 6. Node and V8

- **`--cpu-prof`:** **[fact]** "Starts the V8 CPU profiler on start up, and writes the CPU profile to disk before exit" as a `.cpuprofile` file. `--cpu-prof-interval` sets the sampling interval and defaults to "1000 microseconds". `--heap-prof` does the same for sampled allocations, by default one sample per 512 KiB ([Node CLI](https://nodejs.org/api/cli.html)). The files open in Chrome DevTools.
- **Inspector protocol:** **[fact]** `node:inspector` `Session.post('Profiler.start')` … `post('Profiler.stop')` returns the profile from inside the process; `HeapProfiler.takeHeapSnapshot` streams chunks ([Node inspector](https://nodejs.org/api/inspector.html)). The same Chrome DevTools Protocol (CDP) works over WebSocket with `--inspect`.
- **`diagnostics_channel`:** **[fact]** named channels with `subscribe`/`unsubscribe`, plus `channel.hasSubscribers` so publishers can skip building messages. `tracingChannel` adds start, end, asyncStart, asyncEnd and error sub-channels ([diagnostics_channel](https://nodejs.org/api/diagnostics_channel.html)). **[interp]** This is Node's version of `:telemetry`.
- **[inference]** Tuna's browser half can use the browser's own Performance APIs and DevTools profiler. That belongs to research note 02/03, not here.

### 7. Racket

- **`profile` library:** **[fact]** a statistical profiler. A background "sampler" thread sleeps `delay` seconds and snapshots stacks with `continuation-mark-set->context`. It can track one thread, a custodian, or a list of either; `custom-keys` also snapshots chosen continuation marks; the controller accepts `'pause`, `'resume`, `'stop` and `'set-tracked!`. The analysis is a call graph of nodes with self and total time and caller/callee edges, rendered as text, Graphviz or JSON. Errortrace mode is more precise but costs more and needs recompilation ([profile docs](https://docs.racket-lang.org/profile/index.html); local `profile-lib/sampler.rkt`).
- **[interp]** `custom-keys` is the important idea for Tuna: a sample records the current values of selected dynamic marks, such as "current input item", next to the stack. That is the Racket equivalent of Go's pprof labels.
- **Koyo:** already covered in `README.md` here. Extra detail: `profiler-enabled?` is a parameter whose default is `#f` (`koyo-lib/koyo/profiler.rkt:40`, commit `f3796d0bc924f73427ae9b777519ffcfc129e24c`), and the per-timing database statements come from a log receiver. That is attachment through an existing general channel.

### 8. Gambit and Gerbil (Gerbil `1c6c15385979f0092574fbc2b828f3fb656319b3`, Gambit submodule `ea114fc3d2f120abbe20393c1f9aeafdd3f8c89f`)

- **gxprof:** **[fact]** `profile-start!` calls `(##set-heartbeat-interval! heartbeat)` and `(##interrupt-vector-set! 2 profile-heartbeat!)`. On each heartbeat the handler captures the continuation, walks `##continuation-next-frame`, records `##continuation-creator` names, and then calls the normal `##thread-heartbeat!`. `profile-end!` restores a 1/100 s interval and the default handler (`src/tools/gxprof.ss:83-101`). The default sampling interval is `.001` s, and the output file is a list of frame-name lists (`doc/reference/dev/profiler.md`). The analysis filters out a list of kernel frames (`gxprof.ss:149-167`).
- **Heartbeat:** **[fact]** "The procedure ##thread-heartbeat! is called periodically, by each non-waiting processor, to perform periodic tasks such as waking up threads … preempting the currently running thread" (`lib/_thread.scm:2647-2652`). **[inference]** So replacing interrupt vector 2 takes over the scheduler's preemption tick. A sampler must chain to `##thread-heartbeat!` exactly as gxprof does, or threads stop being preempted. **[inference]** Gambit polls interrupts at safe points in generated code, so samples have a bias similar to the JVM's safepoint bias, though probably milder. I have not measured this.
- **`##process-statistics`:** **[fact]** returns a 20-element f64vector: user, system and real time (0–2); GC user, system and real time (3–5); GC count (6); bytes allocated (7); minor and major page faults (10, 11); and the latest GC's times, heap size, allocation, live, movable and still bytes (12–19) (`lib/_kernel.scm:3999-4043`). It allocates its own result vector, and field 9 records how many bytes that allocation took, so readings can be corrected for it.
- **GC hook:** **[fact]** "(##add-gc-interrupt-job! thunk) can be called to add another job to do after a GC" (`lib/_kernel.scm:2073-2077`). **[inference]** This gives a profiler GC events without touching any Tuna code.

---

## Comparison table

| Tool | Kind | Data model | Overhead / always on? | Switched on by | Stored where | Viewed with | Separation from measured code |
|---|---|---|---|---|---|---|---|
| Go pprof CPU/heap | sampling (100 Hz; 512 KiB alloc) | stacks + values, labels | low; periodic in production | API, `net/http/pprof` endpoint | in memory → protobuf file | `go tool pprof`, flame graph | built into runtime; labels via `pprof.Do` |
| Go block/mutex/goroutine | event-sampled / snapshot | stacks | off by default (rate setters) | rate setters, endpoint | same | same | built in |
| Go `runtime/trace` | event tracing + user regions/tasks/logs | timestamped events | 1–2% since Go 1.21; flight recorder ring | `trace.Start`, endpoint, `FlightRecorder` | buffer → file / ring | `go tool trace` | runtime emits; user annotates |
| JFR | events (incl. method sampling) | typed events: time, duration, thread, stack | ≤1% target; none when off | `-XX:StartFlightRecording`, `jcmd`, JMX | thread-local → circular buffer → `.jfr` | Mission Control, `jfr` | typed event API; `onEvent` stream consumers |
| async-profiler / clj-async-profiler | sampling (no safepoint bias) | stacks | low; "production" | attach agent / `prof/start` | file / results dir | HTML flame graph, `serve-ui` | external agent |
| tufte | instrumentation | per-id stats (pstats) as maps | cheap; `p` always runs body | `profile` / handlers | in memory → handlers | console, maps | handlers via `add-handler!` |
| criterium | benchmark harness | timing statistics | n/a | call `bench` | returned | printed | n/a |
| fprof / eprof / cprof / tprof | call tracing (count/time/memory) | per-function counters | significant → small slowdown | API calls, trace patterns | file / server | text tables | BEAM trace BIFs, opt-in |
| observer / msacc | live metrics | counters, gauges | low; run from separate node | GUI, API | none (live) | GUI | external node |
| `:telemetry` | event dispatch (spans = start/stop events) | name, measurements, metadata | one handler lookup; sync handlers | `attach/4` | wherever handler puts it | handler's choice | **attachable handlers; emitter unaware** |
| cProfile | deterministic tracing | per-function calls, self/cum time | moderate | `-m cProfile`, `Profile.enable()` | pstats file | `pstats`, viewers | interpreter hook |
| `sys.monitoring` | event callbacks | per-event callbacks | per-site `DISABLE` | `register_callback` | tool's choice | tool's choice | **tool IDs; several tools at once** |
| py-spy / Tachyon | out-of-process sampling | stacks | "virtually zero" | CLI, attach PID | file / live | flame graph, speedscope, Firefox | separate process |
| Scalene | sampling CPU + memory | per-line stats | not verified | `scalene run` | JSON | browser UI | wrapper |
| Python `-X perf` | enables external sampler | perf map | depends on perf | flag / env / `sys` call | perf.data | `perf report` | external tool |
| Rust `tracing` | instrumentation spans/events | span tree, fields | not constructed if no subscriber interested | `set_global_default(subscriber)` | subscriber's choice | subscriber's choice | **subscribers and layers** |
| tokio-console | subscriber over runtime spans | tasks, resources | needs `tokio_unstable` | `console_subscriber::init()` | streamed (gRPC) | terminal UI | a `Layer` |
| puffin | instrumentation scopes per frame | scope tree per frame | 50–200 ns on; ~1 ns off | `set_scopes_on(true)` | global collector, frames | egui, remote viewer | macros + global collector |
| Tracy | hybrid zones + sampling | zones, frames, samples | low (vendor claim) | client library | streamed to viewer | Tracy viewer | client/server |
| Node `--cpu-prof` / inspector | sampling (1 ms) | V8 cpuprofile nodes + samples | low | flag, `Session.post` | `.cpuprofile` | DevTools | protocol |
| Node `diagnostics_channel` | event dispatch | named messages; tracing channels | `hasSubscribers` check | `subscribe` | subscriber's choice | subscriber's choice | **attachable subscribers** |
| Racket `profile` | sampling thread | call graph (self/total, edges); custom keys | low | `profile-thunk`, `raco profile` | in memory | text, Graphviz, JSON | library |
| Koyo profiler | instrumentation | timing tree per request | one parameter check off | `profiler-enabled?` | per request | HTML widget | `with-timing` + log receiver |
| gxprof | sampling via heartbeat | frame-name lists | interval 1 ms default | `gxprof` CLI / start! end! | `gxprof.out` | text analysis | takes over interrupt vector 2 |
| `##process-statistics` | counters | time, GC, allocated bytes | one small allocation | call | returned vector | — | primitive |

---

## Recommendation for Tuna (all of this is **[inference]**)

Tuna's rule is that the profiler is a plugin and that the core and default plugins offer only general hooks and advice. The prior art supports that rule: the systems that scale are the ones that separate *emitting* from *consuming*. That means `:telemetry`, `tracing`, `diagnostics_channel`, JFR streaming and `sys.monitoring`.

**Copy:**
1. **The `:telemetry` / `tracing` contract for hooks.** Tuna's existing hooks (`tuna/kernel/hooks.ss`) and owned advice (`tuna/lib/advice.ss`) already have this shape: named, attachable, and removable through receipts. Where a step needs timing, emit a *pair* of general hooks (started/finished, like `telemetry:span`) that carry plain metadata (item id, command name, job id), with no timings or profiler types. Keep the "nobody listening" path to one empty-list check, as Node's `hasSubscribers` and `tracing`'s interest filter do. Like `:telemetry`, document that callbacks run synchronously and must not block; the profiler does only an append, as JFR's thread-local buffers do.
2. **A JFR / Go-style flight recorder in the profiler plugin.** Keep a bounded ring of the last N input-item span trees, and write one out only when an item exceeds a threshold. That is JFR's `threshold` setting and the Go flight recorder's "snapshot when request > 300 ms". This matches the plan's "results go to files" and "bounded memory when on".
3. **A gxprof-style heartbeat sampler with labels.** Reuse gxprof's mechanism: take over interrupt vector 2 and chain to `##thread-heartbeat!`. Add Go pprof labels / Racket `custom-keys`: tag each sample with the current input item id and span name, which the plugin keeps in its own state from the hooks. Then "where did the time go for slow key press 7" can draw on both exact spans and statistical samples. Keep it opt-in (`profiler-start`/`stop`), as Go, Node and Racket do. Do not run it always on: it replaces the scheduler's preemption tick, and every runtime that runs a sampler continuously in production reports some cost.
4. **Allocation and GC per span from `##process-statistics`**, plus `##add-gc-interrupt-job!` for GC events. This matches what tprof's `call_memory` and Go's heap profile provide, but per span and cheaply.
5. **Viewing:** write a standard format so existing viewers work. Candidates are the pprof protobuf, Chrome trace/`.cpuprofile` JSON, speedscope, and Firefox Profiler/Gecko. Choosing among them is note 03's job. Tracy, puffin and Koyo all show that an in-app view (a later `*profile*` buffer) is valuable, but it can come after the files.

**Do not copy:**
- **Always-on HTTP profiling endpoints** (`/debug/pprof`). Tuna is local and single-user; an M-x command and files are enough, and an endpoint is a security surface.
- **Per-function call tracing** (fprof, cProfile, Errortrace) across the whole program. Every source reports a large slowdown, and core modules compiled with `block` cannot be advised. Copy `elp`/tprof's *patterned* form instead (`profile-function`, `profile-plugin` through advice) for chosen targets.
- **PGO, continuous fleet profiling, criterium-style harnesses.** None of them applies to an interactive single-process editor.

**One-line design implied by the prior art:** emitters (kernel loop, jobs library, web plugin, renderer) publish general start/finish hooks; the `profiler` plugin is one subscriber that builds span trees into a ring buffer, optionally adds labelled heartbeat samples, and writes slow items to files.

## Contradictions

- **"Zero" versus "measurable" overhead for out-of-process samplers.** Python's Tachyon says "virtually zero"/"no measurable overhead", while Go warns that the CPU profile "adds cost" and that tools interfere. The two are compatible: out-of-process sampling (py-spy, Tachyon) has no in-process cost, and in-process signal sampling (Go, gxprof) does. Gambit has no out-of-process sampler, so Tuna is in Go's position.
- **Always-on versus opt-in JFR.** JEP 328 targets ≤1% overhead yet lists "Enable data collection by default" as a non-goal. "Low enough to leave on" is still something users switch on.

## Missing evidence

- I did not measure the sampling bias or overhead of Gambit's heartbeat sampler at 1 ms in Tuna's multithreaded server. The earlier note `tuna-profiler-generic-gerbil-research.md` raises the long-lived-process risks.
- I did not verify the Tracy manual's details (on-demand mode, frame marks) or Scalene's overhead figures.
- I did not verify whether `##add-gc-interrupt-job!` runs on the thread that triggered GC, or the cost of a job.
- The Chrome DevTools Protocol `Profiler` domain page did not render; I cited the Node inspector docs instead.
- The `:telemetry` handler-lookup cost is not quantified in its README.

## Sources

**Kept:**
- Go: [diagnostics](https://go.dev/doc/diagnostics), [runtime/pprof](https://pkg.go.dev/runtime/pprof), [net/http/pprof](https://pkg.go.dev/net/http/pprof), [runtime/trace](https://pkg.go.dev/runtime/trace), [execution traces 2024](https://go.dev/blog/execution-traces-2024), [flight recorder](https://go.dev/blog/flight-recorder), [PGO](https://go.dev/doc/pgo); Go 1.26.1 source `runtime/pprof/pprof.go:898`, `runtime/mprof.go:880`.
- JVM: [JEP 328](https://openjdk.org/jeps/328), [JEP 349](https://openjdk.org/jeps/349), [async-profiler](https://github.com/async-profiler/async-profiler), [clj-async-profiler @441f525](https://github.com/clojure-goes-fast/clj-async-profiler/tree/441f525721453249c47e96353d4fc9e93d08976b), [tufte @edf5eb7](https://github.com/taoensso/tufte/tree/edf5eb7618c3bdc8da417cba80171899526f60d0), [criterium](https://github.com/hugoduncan/criterium).
- Erlang: [efficiency guide: profiling](https://www.erlang.org/doc/system/profiling.html), [tprof](https://www.erlang.org/doc/apps/tools/tprof.html), [observer](https://www.erlang.org/doc/apps/observer/observer_ug.html), [telemetry](https://hexdocs.pm/telemetry/readme.html).
- Python: [profile/cProfile](https://docs.python.org/3/library/profile.html), [sys.monitoring](https://docs.python.org/3/library/sys.monitoring.html), [profiling.sampling](https://docs.python.org/3.15/library/profiling.sampling.html), [perf howto](https://docs.python.org/3/howto/perf_profiling.html), [py-spy](https://github.com/benfred/py-spy), [Scalene](https://github.com/plasma-umass/scalene).
- Rust: [tracing](https://docs.rs/tracing/latest/tracing/), [tokio-console](https://github.com/tokio-rs/console), [puffin](https://github.com/EmbarkStudios/puffin), [Tracy](https://github.com/wolfpld/tracy).
- Node: [CLI](https://nodejs.org/api/cli.html), [inspector](https://nodejs.org/api/inspector.html), [diagnostics_channel](https://nodejs.org/api/diagnostics_channel.html).
- Racket: [profile docs](https://docs.racket-lang.org/profile/index.html); local `profile-lib/sampler.rkt`; Koyo `koyo-lib/koyo/profiler.rkt` @ `f3796d0`.
- Gerbil/Gambit: `src/tools/gxprof.ss`, `doc/reference/dev/profiler.md` @ `1c6c153`; Gambit `lib/_kernel.scm`, `lib/_thread.scm` @ `ea114fc`.
- Continuous profiling: [Parca overview](https://www.parca.dev/docs/overview/).

**Deprioritised:** blog tutorials and SEO comparison posts (not fetched; primary docs were enough); the Grafana Pyroscope intro (fetched, redundant with Parca).

## Next steps

- Note 02 (interactive latency): how browsers, game engines (frame markers) and editors (VS Code, Zed, Emacs) attribute one input's latency end to end.
- Note 03 (formats and viewers): pick between the pprof protobuf, Chrome trace JSON, speedscope and the Firefox Profiler format.
- A small spike: a gxprof-style sampler in a running Tuna, chained to `##thread-heartbeat!`, measuring overhead at 1 ms and 10 ms with several HTTP threads.
