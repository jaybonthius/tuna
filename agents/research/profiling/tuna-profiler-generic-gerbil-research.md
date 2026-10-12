# Generic nested Tuna profiler: Gerbil/Gambit research

## Conclusion

**Recommended:** keep Tuna’s profiler an exact, explicitly instrumented command profiler—not a universal function profiler.

Generalize the existing fixed stage mechanism into a bounded nested span tree, while retaining:

- the approved private monotonic clock adapter;
- explicit observation propagation through command requests and state provenance;
- dynamic parameters only for synchronous nesting on the command-owner thread;
- explicit provenance for asynchronous delivery;
- strict fail-open behavior;
- latest-command-only publication.

Automatically create named spans only at Tuna’s canonical command/transition invocation points, and allow explicit private spans around important subsystems. Do not instrument every Gerbil procedure, alter `defun`/`deftransition`, embed `gxprof`, or use compiler tracing in this change.

Use `gxprof` later, from a finite benchmark harness, for statistical CPU-hotspot discovery. Exact monotonic spans and statistical continuation samples answer different questions.

## Current behavior and requirement gaps

### What already works well

- The command runtime transports one opaque observation in `CommandRequest`, installs provenance atomically with state, and keeps public runtime values unchanged: `tuna/tuna/private/runtime.ss:39-57,168-193`.
- The owner installs the observation dynamically only around synchronous transition execution: `tuna/tuna/private/runtime.ss:195-234`.
- State snapshot, render, and send are explicitly correlated asynchronous work: `tuna/tuna/private/http.ss:250-280`.
- The observation verifies the current thread is the command owner, so inherited child threads cannot record synchronous stages: `tuna/tuna/private/observation.ss:158-177,198-233`; test coverage at `tuna/tuna/test/profiler-test.ss:426-447`.
- Fake-clock tests already establish exact elapsed durations without scheduler thresholds: `tuna/tuna/test/profiler-test.ss:98-157`.
- Profile storage remains latest-only and detached: `tuna/tuna/private/profiler.ss:80-111,250-260`.

These are the correct foundations for a generic command profiler.

### Material genericity gaps

1. **High — fixed flat vocabulary.**  
   `+stage-labels+` accepts only `normalize`, `resolve`, `acquire-arguments`, and `transition`; parentage is stored as a label rather than a unique span identity: `tuna/tuna/private/observation.ss:91-93,198-206`. Repeated or recursive labels cannot form an unambiguous tree.

2. **High — keydown-specific root model.**  
   `ProfileBuilder` and `ProfileSnapshot` embed HTTP method/path and keyboard fields, while `profiler-begin-command!` accepts only keydown metadata: `tuna/tuna/private/profiler.ss:84-110,380-408`. This cannot describe a future non-keyboard command without another redesign.

3. **Medium — current widget is not a nested tree.**  
   It renders a flat stage list with “under LABEL”: `tuna/tuna/private/profiler-render.ss:50-58,99-104`.

4. **Medium — direct callable wrappers bypass registry invocation.**  
   `invoke-action` and `invoke-state-transition` are excellent name-aware seams: `tuna/tuna/lib/bindings.ss:441-452,471-475`. However, generated `deftransition` procedures call their cached function cells directly: `tuna/tuna/lib/prelude.ss:205-260`. Instrumenting only `invoke-state-transition` therefore captures command dispatch through that seam, not every direct call to a transition variable.

That limitation is desirable if the profiler’s unit is an Emacs-like command invocation rather than every Scheme call.

## Recommended architecture

### 1. General nested span representation

Replace the fixed `RuntimeStage` concept with a private bounded span record containing approximately:

- unique span ID;
- parent span ID or root marker;
- category, such as `command`, `transition`, or `stage`;
- trusted interned name or fixed internal label;
- monotonic start/end ticks;
- status: running, succeeded, or failed.

Use a dynamic `current-span-id` only after the explicitly transported observation is installed on the owner. Child span creation then naturally records the current ID as its parent.

A unique ID is necessary: a parent label is insufficient for recursion or repeated stages.

Keep arguments, results, state roots, arbitrary printed values, and procedures out of spans. Existing trusted interned command names provide readable, Emacsy labels without a metadata registry.

Add a hard per-command span bound and an omitted-span count. **A 64-span initial bound is the simplest alignment with the existing profiler’s bounded design**, but the exact product limit remains an owner-visible tuning choice.

### 2. One private span primitive

Generalize `call-with-runtime-observation-stage` into a private primitive such as:

```scheme
(call-with-runtime-observation-span category name thunk)
```

Its contract should be:

1. If there is no current owner observation, run `thunk` directly.
2. If span allocation, clock read, or recording fails, run `thunk` exactly once without a span.
3. Parameterize the current parent only for synchronous nesting.
4. Finalize through `try`/`finally`.
5. Preserve the successful result or re-raise the identical application exception.
6. If the span bound is reached, increment omission best-effort and run the body directly.

This is the idiomatic continuation of the current implementation at `tuna/tuna/private/observation.ss:198-233`; it does not require a callback registry, event bus, profiler worker, or compiler plugin.

### 3. Instrument Tuna invocation seams, not definitions

Wrap these private call sites:

- the top-level named command invocation in `complete-state-transition!`: `tuna/tuna/private/runtime.ss:195-208`;
- the selected nested transition invocation in `dispatch-keydown`: `tuna/tuna/private/application.ss:346-356`;
- future command dispatchers where they deliberately invoke another command by trusted name.

The resulting tree for today’s keydown path would be conceptually:

```text
command tuna-dispatch
├─ stage normalize
├─ stage resolve
├─ stage acquire-arguments
└─ transition tuna-increment
```

The generic `transition` label should be replaced by the actual transition symbol; the current code already obtains it before invocation: `tuna/tuna/private/application.ss:346-355`.

Do **not** wrap definitions in `define-function!`, `define-action!`, or `define-state-transition!`. Those live cells are a hot shared substrate: `tuna/tuna/lib/bindings.ss:366-410`. Definition-time wrapping would affect direct calls, procedure identity/arity, tail behavior, all disabled workloads, and redefinition semantics.

Do not change the generated direct wrappers in `deftransition`; calls intended as profiled command composition should deliberately use the name-aware invocation seam.

### 4. Separate generic command identity from host presentation

The profiler core should retain a small generic descriptor:

- command kind;
- trusted command name;
- optional fixed host description.

The HTTP/keyboarding layer may attach its existing bounded key/code/location facts, but those should be presentation details rather than fields required by every profile. This permits future command hosts without introducing an arbitrary metadata map.

The existing private observed submission and public façade should remain private/public exactly as today. Action profiling can be added later when a real Tuna host admits profiled actions; no speculative public observed-action API is needed now.

### 5. Preserve asynchronous delivery architecture

Keep delivery snapshot/render/send outside the synchronous span stack and correlate it through explicit provenance. Dynamic parameters cannot propagate reliably to Tuna’s pre-existing owner, observer, and Server-Sent Events threads.

Current implementation evidence:

- explicit provenance is part of `StateRoot`: `tuna/tuna/private/runtime.ss:51-57`;
- installation and invalidation are atomic: `tuna/tuna/private/runtime.ss:168-193`;
- delivery uses the provenance returned by the coherent latest snapshot: `tuna/tuna/private/http.ss:250-280`;
- child-thread recording is rejected by owner identity: `tuna/tuna/test/profiler-test.ss:426-447`.

Gambit threads inherit a dynamic environment only when created, and later dynamic extensions in another thread do not propagate: `gerbil/src/gambit/doc/gambit.txi:11105-11116`.

## Exact wall-clock spans versus statistical CPU sampling

### Tuna spans

Tuna’s monotonic spans measure exact elapsed time between two explicit boundaries. They include:

- CPU execution;
- blocking or sleeping inside the span;
- garbage collection and scheduler descheduling;
- any other elapsed delay between the boundaries.

They do **not** measure thread CPU time or explain which internal function consumed the interval.

Internally, ticks remain exact integers; display conversion truncates to integer microseconds: `tuna/tuna/private/clock.ss:35-50`.

### `gxprof`

Gerbil’s documented profiler samples the current continuation at each scheduler heartbeat: `gerbil/doc/reference/dev/profiler.md:1-10`. Its default period is 1 ms: `gerbil/doc/reference/dev/profiler.md:18-27`.

Gambit invokes the heartbeat on each non-waiting processor: `gerbil/src/gambit/lib/_thread.scm:2647-2652`. Consequently, samples approximate where processors spend execution time. A blocked command span may have a long wall duration but receive no samples while its thread is not running.

Use cases:

- **Tuna spans:** “This command took 18 ms, of which 12 ms was queueing and 4 ms was rendering.”
- **Sampling:** “Across many representative commands, JSON encoding or keymap lookup dominates processor execution.”

Neither substitutes for the other.

## Existing Gerbil/Gambit visibility facilities

### Gambit `trace` / `untrace`

Gambit can trace selected procedures, printing arguments, results, and continuation nesting. It specially preserves proper tail-call space behavior: `gerbil/src/gambit/doc/gambit.txi:3014-3033`.

Limitations:

- a compiled procedure must be bound to a global variable: `gerbil/src/gambit/doc/gambit.txi:3035-3042`;
- Tuna’s live action/transition implementations are stored inside atom-backed definition records, not directly in global variables: `tuna/tuna/lib/bindings.ss:191-225,395-409`;
- tracing a generated global wrapper does not guarantee seeing calls made directly to the stored implementation through `invoke-state-transition`;
- it prints arguments/results, which may expose application state;
- it emits diagnostic text, not structured timings or Tuna provenance.

**Assessment:** useful interactively for a narrowly selected global procedure, but unsuitable as Tuna’s profiler engine.

### Compiler tracing and generated-code diagnostics

Gerbil exposes:

- `-v` compiler activity;
- `-g` C debug symbols;
- pass-through Gambit flags/options.

See `gerbil/doc/reference/dev/bach.md:90-116`.

Gambit provides:

- `-verbose`: compiler activity;
- `-report`: global binding usage;
- `-expansion`: expanded/inlined source;
- `-gvm`: Gambit Virtual Machine listing;
- `-cfg`: control-flow graph.

See `gerbil/src/gambit/doc/gambit.txi:1115-1143`.

These facilities help inspect what the compiler generated, but they do not observe runtime calls or provide command-correlated timing. `-track-scheme` can improve native debugger/profiler source attribution: `gerbil/src/gambit/doc/gambit.txi:1184-1189`.

### Continuation sampling and `gxprof`

`gxprof`:

- dynamically imports an executable module and invokes `main`: `gerbil/src/tools/gxprof.ss:37-45`;
- globally replaces heartbeat interval and interrupt handler: `gerbil/src/tools/gxprof.ss:83-89`;
- captures and walks the current continuation: `gerbil/src/tools/gxprof.ss:91-103`;
- stores every sample in a process-global list and writes only when `main` returns: `gerbil/src/tools/gxprof.ss:72-81,105-119`.

Primary references:

- [Gerbil profiler manual](https://github.com/mighty-gerbils/gerbil/blob/master/doc/reference/dev/profiler.md)
- [Gerbil `gxprof` source](https://github.com/mighty-gerbils/gerbil/blob/master/src/tools/gxprof.ss)
- [Gambit manual/source](https://github.com/gambit/gambit)

#### Long-lived and threaded-process risks

- **High:** Tuna’s server `main` is long-lived, so ordinary output appears only after shutdown.
- **High:** samples grow without a bound for the process lifetime.
- **High:** heartbeat handler and interval are process-global. `gxprof` restores hardcoded defaults rather than the prior handler/interval: `gerbil/src/tools/gxprof.ss:83-89`.
- **High:** every non-waiting processor may enter the heartbeat, while `samples` is updated by unsynchronized `set!`: `gerbil/src/gambit/lib/_thread.scm:2647-2652`; `gerbil/src/tools/gxprof.ss:81,91-95`.
- **Medium:** short individual commands may receive too few 1 ms samples; representative repeated workloads are required.
- **Medium:** optimized/inlined procedures may not have distinct continuation frames.

`gxprof` is therefore suitable later in a finite, controlled benchmark process, not embedded into the live Tuna profiler unchanged.

## Tail calls, continuations, and optimization

### Tail calls

Gambit enables proper tail calls by default. Disabling them creates frames for tail calls but can cause stack overflow in long iterations: `gerbil/src/gambit/doc/gambit.txi:5059-5072`. Full-program Gerbil compilation also explicitly enables proper tail calls and inlining: `gerbil/src/gerbil/compiler/driver.ss:345-366`.

An exact span wrapper must finalize after the wrapped call returns. Therefore an invocation wrapped as a nested span should not be treated as a transparent tail call. This is acceptable for shallow command composition, but not for every recursive helper call.

**Constraint:** internal iteration and recursion should remain ordinary direct Scheme calls. Instrument logical command/subsystem boundaries only.

### Continuations

Gerbil `try`/`finally` uses `with-unwind-protect`, which is implemented with `dynamic-wind` and explicitly rejects re-entry: `gerbil/src/gerbil/runtime/control.ss:40-47`.

Gambit continuations preserve dynamic environments and dynamic-wind stacks and invoke before/after thunks on crossing boundaries: `gerbil/src/gambit/doc/gambit.txi:11118-11133`.

Consequences:

- escaping a span via a continuation runs its finalizer;
- attempting to re-enter that protected dynamic extent raises “Cannot re-enter unwind protected block”;
- a close-once exact span cannot transparently model arbitrary multi-shot continuation re-entry.

This is already true of Tuna’s current stage wrapper. Before broadening instrumentation beyond command boundaries, Tuna should either retain synchronous, non-reentrant command semantics or explicitly design multi-interval continuation spans. The latter does not belong in this change.

### Inlining and missing frames

Gambit may inline user procedures; its default inlining limit is nonzero: `gerbil/src/gambit/doc/gambit.txi:4912-4939,5145-5169`. Full-program Gerbil compilation uses block compilation, inlining, lambda lifting, and dead-definition elimination: `gerbil/src/gerbil/compiler/driver.ss:345-366`.

Therefore continuation stacks cannot be treated as a complete logical function-call log. Explicit source spans remain visible because they are behavior, even if the compiler inlines the span helper.

## Is profiling every function call feasible or advisable?

**No, not for Tuna.**

There is no inspected supported Gerbil facility that transparently emits a structured event for every runtime function call. Achieving it would require compiler transformation or definition wrapping and would encounter:

- inlining and eliminated call boundaries;
- proper tail calls and missing caller frames;
- continuation/dynamic-wind semantics;
- direct calls, closures, methods, primitives, and foreign calls;
- two clock reads per call;
- current adapter allocation of a fresh `u64vector` per tick: `tuna/tuna/private/clock.ss:12-15`;
- span allocation, parameterization, observation mutex updates, and unwind protection;
- unbounded recursion/retention unless calls are dropped;
- changed performance and possibly changed tail/continuation behavior.

Fully instrumenting every call would substantially perturb the workload being measured. Statistical sampling is the appropriate later tool for function-level CPU hotspots.

## What belongs in this change

1. Preserve the private monotonic adapter unchanged.
2. Generalize fixed stages into bounded span nodes with unique IDs and parent IDs.
3. Add one private, fail-open nested span primitive.
4. Wrap the top-level command and selected nested transition invocation points.
5. Retain explicit subsystem spans for normalize, resolve, and argument acquisition.
6. Separate generic command identity from optional keydown presentation.
7. Render a real nested tree and label durations as monotonic elapsed/wall time.
8. Add deterministic tests for nesting, repeated labels, failure, omission, child-thread rejection, and identical exception propagation.
9. Validate source, normal compiled, and `gxc -O` modes.

## What belongs later

- a finite benchmark executable run under stock `gxprof`;
- a redesigned bounded/SMP-safe sampler if in-process statistical profiles become a real requirement;
- flamegraphs, self-time, per-thread CPU time, or allocation profiling;
- multi-shot continuation-aware spans;
- public user instrumentation APIs;
- compiler transformation or universal function instrumentation;
- replacement or upstreaming of the private clock adapter.

## Monotonic adapter decision

There is no evidence requiring replacement.

The adapter isolates `##get-monotonic-time!` and its frequency primitive: `tuna/tuna/private/clock.ss:10-33`. Gambit implements them as unsigned 64-bit counters: `gerbil/src/gambit/lib/_kernel.scm:4093-4121`.

On this checkout, `HAVE_CLOCK_GETTIME` is enabled: `gerbil/src/gambit/include/config.h:212-215`; that selects `CLOCK_MONOTONIC`: `gerbil/src/gambit/lib/os.h:518-530`; Linux reads are implemented at `gerbil/src/gambit/lib/os_time.c:345-357`.

Residual caveat: Gambit falls back to current time on platforms lacking Mach absolute time, QueryPerformanceCounter, and `clock_gettime`: `gerbil/src/gambit/lib/os_time.c:301-326`. That portability caveat supports keeping the adapter extraction-ready, not replacing it in this change.

## Materially different options

| Option | Assessment |
|---|---|
| Private explicit nested spans plus selected invocation wrappers | **Recommended.** Exact, bounded, readable, testable, and preserves Tuna layering. |
| Instrument `invoke-action`/`invoke-state-transition` globally | Broader automatic coverage, but adds profiler behavior to a public low-level substrate; direct macro-generated calls still bypass it. |
| Wrap definitions or change `defun`/`deftransition` | Reject. Affects all direct calls, arity/procedure identity, disabled overhead, tail calls, and continuation behavior. |
| Gambit `trace` | Interactive diagnostics only; prints values, global-binding restriction, no durations/provenance. |
| Embed stock `gxprof` | Reject for the live service due global heartbeat, unbounded samples, shutdown-only output, and SMP concerns. |
| Compiler-instrument every call | Reject for this product; invasive, optimization-sensitive, and high observer effect. |

## Validation commands for an implementation

Focused behavior:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna

gerbil test -v 0 \
  ./test/profiler-test.ss \
  ./test/command-runtime-test.ss \
  ./test/state-runtime-test.ss \
  ./test/input-dispatch-test.ss \
  ./test/server-runtime-test.ss \
  ./test/server-protocol-test.ss
```

Compiler parity:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
timeout --signal=TERM --kill-after=10s 30m \
  test/run-command-runtime-matrix.sh
```

The matrix explicitly runs source, normal `gxc`, and `gxc -O`: `tuna/tuna/test/run-command-runtime-matrix.sh:55-61,72-139`.

Authoritative full gate:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
ESBUILD=/home/jay/.nix-profile/bin/esbuild \
  test/run-server-runtime-validation.sh
```

The gate performs build, recursive tests, and the compiler-isolation matrix: `tuna/tuna/test/run-server-runtime-validation.sh:12-23`.

Finish with:

```sh
git -C /home/jay/Code/workbench-gerbil/tuna diff --check
git -C /home/jay/Code/workbench-gerbil/tuna diff --cached --check
git -C /home/jay/Code/workbench-gerbil/tuna status --short
```

## Residual risks and confidence

- **High:** stock `gxprof` is not safe to embed unchanged in a long-lived SMP server.
- **Medium:** generic exact spans need a hard span-count bound once the fixed four-stage vocabulary is removed.
- **Medium:** span wrappers intentionally affect tail-call and continuation behavior at instrumented boundaries.
- **Medium:** direct generated transition/function calls remain outside automatic command profiling.
- **Low:** each current native tick allocates a one-element vector; acceptable for curated spans but another reason not to instrument every call.
- **Low:** the monotonic primitive remains private Gambit API, contained by the existing adapter.
- **Confidence:** high for the explicit-span recommendation, facility limitations, invocation seams, and `gxprof` lifecycle; medium for future continuation behavior because Tuna does not currently state a command-level multi-shot continuation contract.