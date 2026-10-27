# Research: profiling data formats, viewers, and tracking performance over time (for Tuna)

Read-only research, 2026-10-27. Scope: which on-disk formats let Tuna's profiler reuse existing viewers, and how projects track performance across builds. Labels used below: **[fact]** means the cited source states it directly; **[interp]** means my reading of a source; **[inference]** means my own judgement for Tuna, not stated by any source.

## Summary

Write two files and keep one history. **(1)** Write the span tree for each key press as a **Chrome Trace Event Format** JSON file. This is plain JSON that Gerbil's `:std/text/json` can write. The Perfetto UI (as a timeline, with SQL queries), the Firefox Profiler (as markers) and speedscope (as a flame chart) all open it, and all three run in the local browser without uploading the trace. **(2)** Write sampling results as **collapsed ("folded") stacks**: one text line per stack. speedscope, Perfetto, the Firefox Profiler, `flamegraph.pl` and Pyroscope all read it. **(3)** To track results across builds, append the summary of each benchmark run to a text file in **Go's benchmark format**, with percentiles as separate units. `benchstat` (Go is installed on this machine) then gives medians, confidence intervals and significance tests for A/B (before-and-after) comparisons. Keep the summaries permanently and raw traces only briefly.

Two corrections to the task's premises:
- The Gerbil toolchain on this machine **does** ship protobuf (`:std/protobuf`) and gzip (`:std/encoding/zlib`). pprof output is therefore possible later without new dependencies.
- `chrome://tracing` is deprecated and redirects to Perfetto.

## Findings

### A. Formats

1. **Chrome Trace Event Format (TEF; JSON).** **Claim:** It records *events and spans*:
   - complete spans `X` (with `ts` and `dur` in microseconds), and begin/end pairs `B`/`E`;
   - instants `i`/`I`, counters `C`, async spans `b`/`n`/`e` and flow arrows `s`/`t`/`f`;
   - metadata `M` events, which name processes and threads.

   The file can be a bare array, or an object with `traceEvents`, an optional `displayTimeUnit`, `stackFrames`/`samples`, and arbitrary extra metadata keys. Events need not be sorted. A missing final `]` is tolerated "to support tracing systems that can not cleanly finish writing the trace". Duration events on one thread must nest; non-nesting work should use async events. **Sources:** [Trace Event Format spec (Google Doc)](https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview), fetched as a text export; [Perfetto: other formats](https://perfetto.dev/docs/getting-started/other-formats). **Support:** direct. **Confidence:** high.
   - **Writability:** trivial with any JSON writer [fact: Perfetto calls it chosen "for its ease of generation"].
   - **Viewers:**
     - Perfetto UI renders B/E/X as slices, I as instants, C as counter tracks, M as names and s/t/f as flow arrows, and Trace Processor loads them into SQL tables [fact, Perfetto other-formats].
     - speedscope imports the B, E, X and M events [fact, [speedscope wiki](https://github.com/jlfwong/speedscope/wiki/Importing-from-custom-sources)].
     - The Firefox Profiler's Chrome importer turns X, B/E, b/e, instant and other events into markers [fact: `src/profile-logic/import/chrome.ts`, firefox-devtools/profiler at commit de9b76a, lines ~1036–1160].
     - `chrome://tracing` "is deprecated, and by default will redirect to https://ui.perfetto.dev" (July 2022) [fact, [Catapult perfetto.md](https://chromium.googlesource.com/catapult/+/refs/heads/main/tracing/docs/perfetto.md)].
   - **Caveat:** Perfetto calls JSON "a legacy trace format … supported on a best-effort basis" and recommends its native TrackEvent protobuf for anything unusual [fact, [Perfetto FAQ](https://perfetto.dev/docs/faq)]. Overlapping, non-nested slices go to an overflow track [fact, other-formats].

2. **Perfetto native protobuf (TrackEvent, `.pftrace`).** **Claim:** It records spans, counters and flows on explicit tracks, inside `TracePacket` messages. Perfetto documents "synthetic" generation with any protobuf library, and recommends it over JSON for power and flexibility. **Sources:** [Perfetto synthetic TrackEvent](https://perfetto.dev/docs/reference/synthetic-track-event), [Perfetto FAQ](https://perfetto.dev/docs/faq). **Support:** direct. **Confidence:** high.
   - **Writability for Tuna:** Gerbil has `:std/protobuf`, which compiles `.proto` files with `#lang :std/protobuf/proto`, supports packed encoding and `oneof`, and is installed in `/opt/gerbil/v0.19-dev-63…/lib/std/encoding/protobuf/` [fact: local toolchain inspection; `gerbil/doc/reference/std/protobuf.md`]. Whether it handles every proto3 feature in Perfetto's large `.proto` tree is **unverified**.
   - **[inference]** This route costs more than JSON and gains little at Tuna's scale.

3. **pprof (`profile.proto`).** **Claim:** It records *aggregated samples*: each `Sample` has a stack of `location_id`s, a vector of `value`s typed by `sample_type` (for example cpu/nanoseconds or alloc/bytes), and optional labels. A string table, function and location tables are included, and there is no per-sample timestamp field. "On-disk, the serialized proto must be gzip-compressed." **Source:** [profile.proto](https://github.com/google/pprof/blob/main/proto/profile.proto). **Support:** direct. **Confidence:** high.
   - **Writability:** this needs protobuf plus gzip. Both exist in Gerbil (`:std/protobuf`; `:std/encoding/zlib` with `gzip: #t`) [fact: local source]. Correct proto3 packed encoding of `repeated uint64` is unverified.
   - **Viewers:**
     - `pprof -http=host:port` serves a local web UI with graph, flame graph, top and source views, and `-diff_base` compares two profiles [fact, [pprof doc](https://github.com/google/pprof/blob/main/doc/README.md)]. This needs Go, which is installed (`go`; [inference] `go tool pprof` is bundled).
     - The Perfetto UI shows pprof as flame graphs, one per metric [fact, other-formats].
     - speedscope lists a pprof importer [fact, speedscope README].
     - Pyroscope ingests pprof [fact, [Pyroscope API](https://grafana.com/docs/pyroscope/latest/reference-server-api/)].

4. **Collapsed / folded stacks (Brendan Gregg).** **Claim:** It records *aggregated samples* as text: `frame1;frame2;leaf COUNT` per line, root first. **Sources:** [speedscope wiki](https://github.com/jlfwong/speedscope/wiki/Importing-from-custom-sources), [Perfetto other-formats](https://perfetto.dev/docs/getting-started/other-formats), [FlameGraph](https://github.com/brendangregg/FlameGraph). **Support:** direct. **Confidence:** high.
   - **Writability:** the simplest possible format; it loses timestamps and units ("don't care about the units").
   - **Viewers:**
     - `flamegraph.pl` turns it into an SVG offline (Perl, with options such as `--countname`), and `difffolded.pl` diffs two files [fact, FlameGraph repo].
     - speedscope [fact].
     - The Perfetto UI shows it as an interactive flame graph [fact].
     - The Firefox Profiler has a `flame-graph.ts` importer that detects the format [fact: local clone].
     - Pyroscope's `/ingest` endpoint defaults to `format=folded` [fact, Pyroscope API].

5. **speedscope file format (JSON).** **Claim:** A file holds `shared.frames` and `profiles[]`, each either:
   - `evented`: balanced `O` (open) and `C` (close) frame events with non-decreasing `at` values; or
   - `sampled`: `samples` (stacks given as frame indices) plus `weights`.

   Units are `none`, `nanoseconds`, `microseconds`, `milliseconds`, `seconds` or `bytes`. **Source:** [file-format-spec.ts](https://github.com/jlfwong/speedscope/blob/main/src/lib/file-format-spec.ts). **Support:** direct. **Confidence:** high.
   - **Viewers:** speedscope only, as far as I found. It is fully in-browser ("profiles are not uploaded anywhere"), can be installed offline with `npm install -g speedscope` (then `speedscope file`), and also ships as a self-contained zip of `index.html` [fact, [speedscope README](https://github.com/jlfwong/speedscope)].
   - **[inference]** TEF reaches speedscope as well as Perfetto and Firefox, so speedscope's own format adds little except weighted samples with units.

6. **Firefox Profiler formats.** **Claim:** There are two formats:
   - the Gecko profile format, which Firefox emits;
   - the *processed* profile format: column-oriented tables (`stackTable`, `frameTable`, `funcTable`, string table, samples, markers), optimised for JavaScript.

   Importers convert external formats into one of these. The importers present at commit de9b76a are art-trace, chrome, dhat, flame-graph, linux-perf, proto and simpleperf. Old versions are upgraded automatically, but the samples table assumes a fixed sampling interval, and threads should have at least one sample. **Sources:** [custom-importer.md](https://github.com/firefox-devtools/profiler/blob/main/docs-developer/custom-importer.md), [processed-profile-format.md](https://github.com/firefox-devtools/profiler/blob/main/docs-developer/processed-profile-format.md), and a local clone listing of `src/profile-logic/import`. **Support:** direct. **Confidence:** high.
   - **Writability:** possible in JSON but intricate (index tables and versioning).
   - **Local use:** the UI "is cached locally the first time you access it", and "the data stays local to your computer until you upload it" [fact, [getting-started guide](https://github.com/firefox-devtools/profiler/blob/main/docs-user/guide-getting-started.md)].
   - **[inference]** Do not write this format; feed the Firefox Profiler TEF or folded stacks.

7. **OpenTelemetry (OTel) traces / OpenTelemetry Protocol (OTLP).** **Claim:** It records distributed *spans*: trace ID, span ID, parent, start and end times, attributes. OTLP is a transport protocol over gRPC or HTTP, with binary protobuf or JSON encodings. Its JSON form uses hex trace and span IDs, integer enums and lowerCamelCase keys. Traces are stable; the profiles signal is "Development". **Source:** [OTLP spec 1.11.1](https://opentelemetry.io/docs/specs/otlp/). **Support:** direct. **Confidence:** high.
   - **Viewers:**
     - Jaeger UI can import OTLP JSON and JSON-lines files, but importing OTLP/JSON "silently requires a live Jaeger backend" (`POST /api/transform`) [fact, [jaeger-ui #4197](https://github.com/jaegertracing/jaeger-ui/issues/4197), [#2380](https://github.com/jaegertracing/jaeger-ui/pull/2380)].
     - Grafana can import a single JSON trace file in Explore [fact, [Grafana docs](https://grafana.com/docs/grafana/v12.0/datasources/tempo/traces-in-grafana/json-trace-file/)].
     - Tempo runs as a single local binary that receives OTLP [fact, Tempo docs].
   - **[inference]** OTLP is built for services sending data to a collector. For one editor process it adds servers and ceremony, and its viewers show request waterfalls, not CPU flame graphs.

8. **Java Flight Recorder (JFR).** **Claim:** JFR files are binary, created by the Java virtual machine (JVM). The `jfr` tool prints them as `--json`/`--xml`, summarises and scrubs them. **Source:** [jfr man page (JDK 21)](https://docs.oracle.com/en/java/javase/21/docs/specs/man/jfr.html). **Support:** direct. **Confidence:** high. Pyroscope ingests JFR [fact], and speedscope has a JFR import guide [fact, README].
   - **[inference]** Not a candidate: the format is JVM-specific and no simple writer exists.

9. **Go `runtime/trace`.** **Claim:** It records timestamped *runtime events* (goroutines, system calls, garbage collection) plus user *tasks*, *regions* (which must nest per goroutine) and *logs*. It is viewed with `go tool trace`, which computes latency distributions per task type. A `FlightRecorder` keeps a moving window of recent trace data. **Source:** [runtime/trace](https://pkg.go.dev/runtime/trace). **Support:** direct. **Confidence:** high.
   - **[inference]** Not writable outside Go. But its *model* is worth copying: task = key press; region = command, redraw and other steps; flight recorder = keep the last N key presses.

### B. Viewers: local or offline?

10. **Perfetto UI.** **Claim:** It "runs fully locally, in-browser using JavaScript + WebAssembly. The trace file is not uploaded anywhere by default". It opens files by drag-and-drop, and merges several files or a ZIP/TAR archive onto one timeline. For large traces, `trace_processor server http` runs natively on port 9001 and the UI connects to it. Browsers typically cap memory around 2 GB. **Sources:** [Perfetto system-tracing](https://perfetto.dev/docs/getting-started/system-tracing) (checked with `source_check`; the passage was found verbatim), [Perfetto UI](https://perfetto.dev/docs/visualization/perfetto-ui), [Large traces](https://perfetto.dev/docs/visualization/large-traces). **Support:** direct. **Confidence:** high.
    - The app itself is loaded from `ui.perfetto.dev`. Fully offline use (after a first load, or self-hosted) is **unverified** in this pass.
    - A local page can open a trace in the UI by `postMessage`; `localhost` origins are trusted without a prompt [fact, [embedding docs](https://perfetto.dev/docs/visualization/embedding-the-ui)].
    - **[inference]** Tuna already serves HTTP, so a "open in Perfetto" link is cheap.

11. **Trace Processor (the Perfetto command-line tool).** **Claim:** `trace_processor query trace.json "SELECT … FROM slice"` prints CSV. It can export to SQLite or Arrow and convert to JSON or pprof. **Sources:** [command-line cookbook](https://perfetto.dev/docs/getting-started/command-line-analysis), other-formats. **Support:** direct. **Confidence:** high.
    - Separately, Perfetto's trace summarisation (`TraceSummarySpec` → a stable `TraceSummary` proto) exists "to track performance metrics over time … and automatically detect regressions" [fact, [Trace summarization](https://perfetto.dev/docs/analysis/trace-summary)].
    - Not installed here; it is downloadable as a single binary.

12. **Summary of the remaining viewers.**
    - speedscope: offline via npm or the zip [fact].
    - Firefox Profiler: cached locally; data stays local until uploaded [fact].
    - `pprof -http`: a local server [fact].
    - `flamegraph.pl`: offline Perl, outputs SVG [fact].
    - Jaeger and Tempo/Grafana: local servers, which you must run [fact].
    - On this machine: `node`/`npx`, `go`, `python3`, `docker`, `perf`, `jq`, `sqlite3` are present; speedscope, pprof, trace_processor and flamegraph.pl are not [fact: `command -v`].

### C. Tracking over time

13. **Continuous profiling.** **Claim:** These systems store *sampled stack profiles* as time series that you can query by label:
    - Pyroscope: multi-tenant, object storage; ingests folded, "lines", pprof and JFR.
    - Parca: eBPF agent (eBPF = extended Berkeley Packet Filter, kernel-level instrumentation), label selectors, built-in storage.
    - Datadog: software as a service (SaaS). "flame graphs, call graphs, and thread timelines are retained for eight days, and profile metrics are retained for one month".

    **Sources:** [Pyroscope intro](https://grafana.com/docs/pyroscope/latest/introduction/), [Pyroscope API](https://grafana.com/docs/pyroscope/latest/reference-server-api/), [Parca overview](https://www.parca.dev/docs/overview), [Datadog profiler](https://docs.datadoghq.com/profiler/). **Support:** direct. **Confidence:** high. **[interp]** The commercial pattern keeps raw profiles briefly and derived metrics longer.

14. **Benchmark result formats.**
    - Go's benchmark format is a *defined, stable* text format. Each line is `BenchmarkName iterations value unit [value unit …]`; `key: value` configuration lines (commit, CPU and so on) apply to the lines after them; `Unit <unit> better=lower assume=nothing` metadata lines are allowed. Custom units are explicitly allowed (for example `L1-miss-ns/op`) [fact, [Go proposal 14313](https://go.googlesource.com/proposal/+/master/design/14313-benchmark-format.md)].
    - `benchstat` computes "the median and the confidence interval for the median" and a significance test ("p=…"), recommends ≥10 runs per benchmark, and prints `~` when a change is not significant [fact, [benchstat](https://pkg.go.dev/golang.org/x/perf/cmd/benchstat)].
    - criterion.rs (Rust): its JSON files are "private implementation details"; only `raw.csv` (one row per sample) is stable, and `cargo-criterion --message-format=json` is recommended [fact, [criterion CSV](https://bheisler.github.io/criterion.rs/book/user_guide/csv_output.html)].
    - JMH (Java Microbenchmark Harness) outputs TEXT, CSV, SCSV, JSON or LaTeX [fact, ResultFormatType.java].
    - github-action-benchmark: `customSmallerIsBetter` JSON entries need only `name`, `unit` and `value` (optionally `range` and `extra`). It stores history in a JSON file or a gh-pages branch, charts it, and alerts when a threshold is exceeded [fact, [README](https://github.com/benchmark-action/github-action-benchmark)].
    - CodSpeed is a hosted service connected through a GitHub App [fact, [CodSpeed quickstart](https://codspeed.io/docs)].

    **Support:** direct. **Confidence:** high.

15. **Browsers and editors.**
    - **Chromium's performance dashboard** takes HistogramSet JSON (preferred) or the older Chart JSON. Histograms carry a unit and an improvement direction, bins, diagnostics, and a Mann-Whitney U significance test. By default their summaries upload avg, std, count, sum, min and max; percentiles are opt-in (`percentile: [0.5]`). Running the dashboard locally "is no longer supported" [fact, [How to write metrics](https://chromium.googlesource.com/catapult/+/HEAD/docs/how-to-write-metrics.md), [dashboard README](https://chromium.googlesource.com/catapult/+/HEAD/dashboard/README.md)].
    - **Firefox's Perfherder** raises an alert when a framework threshold is exceeded (Talos/Browsertime ≥2%, AWSY ≥0.25%; the default is 2%, 5% for Dromaeo). It needs a sustained change over "12 future data points", because a single data point cannot be trusted under noise. Culprits are found by bisection [fact, [Performance Sheriffing](https://firefox-source-docs.mozilla.org/testing/perfdocs/perf-sheriffing.html)].
    - **VS Code's `vscode-perf`** runs 10 sessions by default (`PERFORMANCE_RUNS = 10`) between named duration markers, and reports fastest, slowest and median [fact: `microsoft/vscode-perf` `src/constants.ts`, `src/perf.ts`, at a June 2026 commit]. I did not find public documentation of VS Code's internal performance bots; **unverified**.

    **Support:** direct. **Confidence:** high, except the VS Code bots.

16. **Which data to keep.**
    - **[interp]** Every system above stores *repeated measurements*, not a single run, and reports a robust centre (median) with spread or a significance test. benchstat, VS Code and Chromium's Mann-Whitney test are all non-parametric or median-based.
    - Chromium's defaults still include the mean. **[inference]** For editor latency, the tail (p95/p99/max per key press) is what users feel, so record percentiles explicitly.
    - Raw data is kept briefly (Datadog: 8 days) or only as needed to diagnose, while summaries are kept long-term.
    - Perfherder and Chromium attach "diagnostics" or links to a raw run to explain a regression.

## Contradictions

- **Whether JSON is a good primary format.** Perfetto calls Chrome JSON "legacy … best-effort" and pushes TrackEvent protobuf. In the same docs it says JSON is widely chosen "for its ease of generation and established 'stability'". **[inference]** For Tuna's simple nested spans, JSON is inside the well-supported core (X, B/E, M, C and flows are listed as supported), so the warning applies to obscure features, not to this use.
- **The task's premise that "Gerbil has no protobuf"** is contradicted by the installed toolchain: `:std/protobuf` and `:std/encoding/zlib` are present in v0.19-dev-63.
- **Means versus medians.** Chromium's summary defaults upload mean and std and leave percentiles off, while benchstat and vscode-perf use medians. Both are cited above; I did not resolve the difference.

## Missing evidence

- Whether the Perfetto UI works fully offline (service worker or self-hosting), and whether it opens gzip-compressed JSON directly.
- Whether TEF timestamps with fractional microseconds are honoured by all three viewers. The spec says "microsecond granularity", and `displayTimeUnit: "ns"` affects only display.
- Whether Perfetto, speedscope and Firefox read TEF's `stackFrames`/`samples` (sampled stacks *inside* a JSON trace). If so, one file could carry both spans and samples. Not checked.
- Whether `:std/protobuf` round-trips `profile.proto` (proto3 implicit packing). Not tested.
- How VS Code's internal performance bots work: no primary source found.
- How the Firefox Profiler's Chrome importer handles flow (`s`/`f`) events was not examined.

## Sources

- Kept:
  - Trace Event Format spec (Google Doc, fetched as a text export): the event types, file shapes and nesting rules.
  - Perfetto docs: [other formats](https://perfetto.dev/docs/getting-started/other-formats), [FAQ](https://perfetto.dev/docs/faq), [UI](https://perfetto.dev/docs/visualization/perfetto-ui), [large traces](https://perfetto.dev/docs/visualization/large-traces), [command line](https://perfetto.dev/docs/getting-started/command-line-analysis), [trace summary](https://perfetto.dev/docs/analysis/trace-summary), [synthetic TrackEvent](https://perfetto.dev/docs/reference/synthetic-track-event): viewer support, local-only processing, SQL analysis.
  - [Catapult perfetto.md](https://chromium.googlesource.com/catapult/+/refs/heads/main/tracing/docs/perfetto.md): `chrome://tracing` is deprecated.
  - [pprof profile.proto](https://github.com/google/pprof/blob/main/proto/profile.proto) and [pprof README](https://github.com/google/pprof/blob/main/doc/README.md): the sample model, the gzip rule, the web UI and diffing.
  - [speedscope README](https://github.com/jlfwong/speedscope), [file-format-spec.ts](https://github.com/jlfwong/speedscope/blob/main/src/lib/file-format-spec.ts), [custom import wiki](https://github.com/jlfwong/speedscope/wiki/Importing-from-custom-sources).
  - Firefox Profiler docs ([custom importer](https://github.com/firefox-devtools/profiler/blob/main/docs-developer/custom-importer.md), [getting started](https://github.com/firefox-devtools/profiler/blob/main/docs-user/guide-getting-started.md)) and source (importer list, Chrome importer).
  - [FlameGraph](https://github.com/brendangregg/FlameGraph): the folded format, `flamegraph.pl` and `difffolded.pl`.
  - [OTLP spec](https://opentelemetry.io/docs/specs/otlp/); Jaeger UI issues and PRs; Grafana and Tempo docs.
  - [jfr man page](https://docs.oracle.com/en/java/javase/21/docs/specs/man/jfr.html); [runtime/trace](https://pkg.go.dev/runtime/trace).
  - [Go benchmark format proposal](https://go.googlesource.com/proposal/+/master/design/14313-benchmark-format.md); [benchstat](https://pkg.go.dev/golang.org/x/perf/cmd/benchstat).
  - [criterion CSV](https://bheisler.github.io/criterion.rs/book/user_guide/csv_output.html); JMH `ResultFormatType`; [github-action-benchmark](https://github.com/benchmark-action/github-action-benchmark); [CodSpeed](https://codspeed.io/docs).
  - Catapult [metrics](https://chromium.googlesource.com/catapult/+/HEAD/docs/how-to-write-metrics.md) and [dashboard](https://chromium.googlesource.com/catapult/+/HEAD/dashboard/README.md) docs; [Firefox perf sheriffing](https://firefox-source-docs.mozilla.org/testing/perfdocs/perf-sheriffing.html); `microsoft/vscode-perf` source.
  - [Pyroscope](https://grafana.com/docs/pyroscope/latest/reference-server-api/), [Parca](https://www.parca.dev/docs/overview), [Datadog](https://docs.datadoghq.com/profiler/).
  - Local: Gerbil `src/std/encoding/{protobuf,zlib.ss,json}`, `doc/reference/std/protobuf.md`, and the installed `/opt/gerbil/v0.19-dev-63…` libraries.
- Rejected or deprioritised:
  - A Perfetto GitHub discussion (#4821): redundant with the official docs.
  - Third-party Perfetto-from-Python demo repositories: not primary.
  - A Mozilla wiki sheriffing page: older than firefox-source-docs.
  - The CodSpeed "how it works" internals: hosted service, out of scope for one machine.

## Recommendation for Tuna (ranked) [inference, built on the facts above]

1. **Spans: write Chrome Trace Event JSON (object form).** One file per capture, for example the last N key presses or a `profiler-start`/`stop` window, under a git-ignored directory such as `.tuna/profiles/<date>-<commit>-<label>.trace.json`.
   - Each key press is a tree of `X` events on the track (`tid`) of the thread that ran it, with `args` carrying the key, command name, bytes allocated and garbage-collection (GC) time.
   - Use `M` events to name threads; `C` events for heap and GC counters; and async (`b`/`e`, keyed by key-press id) or flow (`s`/`f`) events for background jobs and "screen delivered to tab N", which cross threads.
   - Put the commit, Gerbil version and machine in top-level metadata keys.
   - Browser-side timings could go under a separate `pid`, with care to align the two clocks.
   - Open the files in **Perfetto UI** (timeline plus SQL), **speedscope** (`npx speedscope file`, offline), or the **Firefox Profiler**.
   - Because a missing trailing `]` is tolerated, a crashing session still leaves a readable file.
2. **Samples: write folded stacks** (`*.folded`) from the gxprof-style sampler. One line per distinct stack with its count, with the sample unit stated in the file name.
   - View in speedscope, Perfetto, the Firefox Profiler, or `flamegraph.pl` (SVG, offline).
   - Diff two runs with `difffolded.pl`.
   - Pyroscope can ingest the same files later if continuous profiling is ever wanted.
3. **Later, if needed: pprof** (gzip-compressed protobuf), written with `:std/protobuf` and `:std/encoding/zlib`. It is worth adding only for multi-valued samples (CPU plus allocations per stack) and `pprof -http … -diff_base` comparisons. Do not write the speedscope, Firefox-processed, OTLP, JFR or Perfetto-protobuf formats.
4. **Tracking across builds:**
   - Add a repeatable scenario runner, for example "type 500 characters into a 10k-line buffer with plugin X on".
   - Run each scenario ≥10 times. Each run appends one Go-benchmark-format line, such as `BenchmarkTypeChar/buffer=10k 500 0.41 p50-ms/key 2.9 p99-ms/key 7.1 max-ms/key 1200 B/key`, after `commit:`, `gerbil:` and `machine:` configuration lines and `Unit … better=lower` lines.
   - Store these small text files in the repository (for example `bench/results/<date>-<commit>.txt`) and keep them permanently.
   - Compare with `go run golang.org/x/perf/cmd/benchstat@latest old.txt new.txt`, which gives medians, confidence intervals and p-values. Treat changes under about 2–5% as noise unless confirmed, following Perfherder's thresholds.
   - Keep raw traces only for the latest few runs, plus any run that showed a regression, linked from the result line's config (for example `trace: path`).
   - Record percentiles (p50/p95/p99/max), not just means.
   - If a chart is wanted, convert the same records to github-action-benchmark's `customSmallerIsBetter` JSON or a small local HTML page. No external service is needed.

## Next steps

- Test the formats: hand-write a 20-event TEF file with nested `X`, a `C` counter, async `b`/`e` and an `M` thread name, and open it in Perfetto UI, `npx speedscope` and profiler.firefox.com to confirm which features each shows (especially async and flow events, and fractional microseconds).
- Check whether TEF's `stackFrames`/`samples` load in Perfetto and speedscope; if so, one file could carry spans and samples together.
- Confirm that the Perfetto UI works offline, or else choose speedscope as the guaranteed-offline viewer.
