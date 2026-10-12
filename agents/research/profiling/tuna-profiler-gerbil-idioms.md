# Tuna profiler: idiomatic Gerbil v19 primitives and API shape

## Conclusion

Use a small, private instrumenting-profiler module built around:

1. a process-wide live boolean stored in an atom or Tuna live-value cell;
2. integer monotonic ticks behind a private clock adapter;
3. explicit opaque trace-context propagation through queued command and state-publication infrastructure;
4. mutex-owned trace/profile state;
5. capacity-one channels used only as nonblocking invalidations, followed by a mutex-protected latest snapshot read;
6. final, typed Gerbil structs exposed only through read-only accessors;
7. a hygienic `with-profile-span` macro whose disabled branch evaluates the body directly;
8. `try`/`finally` for exception-safe span closure.

Do **not** rely on dynamic parameters to cross Tuna’s existing HTTP, command-owner, completion-observer, and subscriber threads. Parameters are useful only for synchronous nesting after an explicitly propagated context has been installed in the receiving thread.

Do not put trace data into `TunaRoot`, `TunaKeydownRequest`, rendered HTML, Datastar signals, or browser requests. Put an opaque observation context into runtime command/publication envelopes.

## Recommended topology

### Command path

1. After a valid keydown is decoded, the HTTP handler checks the live enable flag.
2. If enabled, it creates a command trace with copied curated context and monotonic start ticks.
3. The trace is passed explicitly through:
   - HTTP handler;
   - `tuna-service-submit-keydown!`;
   - command request;
   - command-owner execution;
   - state publication metadata;
   - completion-observer entry.
4. The command owner installs the trace context dynamically only while invoking the transition, enabling cheap synchronous nested spans.
5. The core command root ends in the completion observer, after success or failure has been observed. State installation and subscriber invalidation already precede command completion.
6. Each subscriber that actually snapshots/renders/sends a revision creates a separate asynchronous delivery child attached to that revision’s publication context.

Current ordering supports this boundary: a changed transition installs and invalidates before posting completion (`tuna/tuna/lib/runtime.ss:155-196`), while the service separately queues accepted completions for its observer (`tuna/tuna/private/service.ss:85-102`).

### State delivery path

Store opaque publication context alongside the runtime-owned `StateRoot` revision and value. The publication must be atomically visible with the revision/value before subscriber invalidation.

On wakeup, a subscriber reads the current latest publication and attaches:

- `state-delivery` child;
- `snapshot` child around the actual latest snapshot acquisition;
- `render` child around `render-tuna-snapshot`;
- `patch-send` child around `patch-elements`.

The present implementation provides the exact instrumentation locations: invalidation, latest snapshot, rendering, and send occur at `tuna/tuna/lib/runtime.ss:132-153` and `tuna/tuna/private/http.ss:186-217`.

A capacity-one notification can represent an older revision. That is harmless only because the subscriber rereads the latest snapshot. Therefore the trace must come from the snapshot actually rendered, not from the queued invalidation value.

If multiple revisions coalesce, skipped commands correctly receive no delivery child: no render or patch send actually occurred for them. Multiple subscribers produce one delivery child per actual subscriber delivery.

Initial page/subscription snapshots have no command context and should not be attached to an arbitrary prior command.

## Smallest seams

### Public/product seam

Expose only:

- one validated boolean Tuna live configuration value, such as `tuna-profile-enabled`;
- the settled profiler HTTP/UI route;
- opaque, read-only profile snapshot data required by the renderer.

Existing Tuna configuration already uses live value cells and atom-backed definitions (`tuna/tuna/lib/bindings.ss:18-35,44-73`), while startup snapshots only listener settings (`tuna/tuna/main.ss:13-25`). The profile enable value should remain live rather than be snapshotted.

The normal page should include profiler initialization only when enabled at page-render time. Existing pages are static HTML assembled at GET (`tuna/tuna/private/http.ss:125-143`); consequently, requiring open pages to reload after a toggle is natural and requires no browser-side toggle propagation.

### Reusable runtime seam

The minimal generic runtime extension is an optional opaque observation context on transition submission and state publication:

- add an optional `context:` argument to `command-runtime-submit-transition!`, or add one explicit context-aware variant;
- retain context in private `CommandRequest` and `StateRoot`;
- add a detailed snapshot/subscription operation returning revision, value, and context without changing existing two-value `command-runtime-snapshot`.

Keep the ordinary application state value unchanged. `StateRoot` is already runtime infrastructure wrapping revision and application value (`tuna/tuna/lib/runtime.ss:47-49,124-153`).

A dedicated context-aware operation is clearer than reusing `command-runtime-submit-with-context!`: that existing “context” selects host argument acquisition and has unrelated semantics (`tuna/tuna/lib/runtime.ss:173-192,296-308`).

### Private profiler seam

A private `:tuna/private/profiler` should own approximately:

- `profile-enabled?`;
- clock adapter;
- opaque `TraceContext`, `Span`, and immutable snapshot records;
- `with-profile-span`;
- command-trace creation/finalization;
- child-context creation;
- latest-profile publication/subscription;
- subscriber close and store shutdown.

Do not add profiling macros to `:tuna/lib/prelude`; that prelude is the application/config authoring surface and currently exports application bindings and event/runtime conveniences (`tuna/tuna/lib/prelude.ss:1-59`). Instrument only the small set of private runtime/service/HTTP boundaries.

## Primitive choices

### Monotonic timing

Gerbil’s high-level time APIs are not suitable for elapsed profiling:

- `current-time-inexact` uses `##current-time-point` (`gerbil/src/std/time/time.ss:6-20`);
- coarse and precise system time use `gettimeofday` and `clock_gettime(CLOCK_REALTIME)` (`gerbil/src/std/os/time.ss:8-16,48-70`);
- therefore neither source establishes monotonic elapsed-time behavior.

The bundled Gambit runtime does have a true monotonic primitive:

- `##get-monotonic-time!` and its frequency primitive write unsigned 64-bit values (`gerbil/src/gambit/lib/_kernel.scm:4093-4117`);
- Linux uses `clock_gettime(CLOCK_MONOTONIC, ...)` (`gerbil/src/gambit/lib/os_time.c:301-358`);
- the corresponding frequency is supplied separately (`gerbil/src/gambit/lib/os_time.c:361-406`).

**Recommendation:** wrap these low-level primitives in one private Tuna clock adapter. Cache the frequency and use a per-thread one-element `u64vector` to avoid allocating at each span boundary. Retain integer ticks internally and convert only while building display snapshots.

This is the strongest available implementation, but it is an internal Gambit API, not a documented stable Gerbil API. Test its presence, positivity, nondecreasing values, and conversion independently. Keep the adapter private so it can later be replaced.

### Parameters and explicit propagation

Gambit threads inherit the parent’s dynamic environment (`gerbil/src/gambit/doc/gambit.txi:10135-10168`). More subtly, inherited parameter bindings initially share cells, so parameter assignment can be visible in another thread (`gerbil/src/gambit/doc/gambit.txi:11088-11116`).

That does not solve Tuna propagation:

- command-owner and completion-observer threads are created at service startup (`tuna/tuna/private/service.ss:67-83`);
- the command owner receives later work through a channel (`tuna/tuna/lib/runtime.ss:229-260`);
- SSE handlers wake from state-subscription channels (`tuna/tuna/private/http.ss:197-210`).

Those threads do not inherit the dynamic environment of a later HTTP request. Actor messages and channels carry values, not caller parameterizations.

Use explicit context in envelopes. Once received, parameterize `current-trace-context` and `current-span-id` around synchronous nested work. Never depend on implicit inheritance for asynchronous children.

### Atom, mutex, channel, or actor

**Enable flag:** atom/live-value cell.

Gerbil atoms provide atomic serialized updates, but the implementation’s dereference is a direct field accessor while updates take the atom mutex (`gerbil/src/std/sync/atom.ss:21-41,46-90`). This gives the desired cheap read path. Validate boolean writes at the public setter boundary.

**Trace/profile store:** mutex ownership.

A single mutex can protect:

- mutable in-progress trace builders;
- latest immutable snapshot and revision;
- subscriber registry;
- atomic subscribe-plus-snapshot;
- close state.

`with-lock` releases on normal return or exception (`gerbil/doc/reference/gerbil/runtime/thread-primitives.md:117-133`; implementation `gerbil/src/gerbil/runtime/thread.ss:125-150`).

A dedicated actor would add another mailbox, owner thread, shutdown protocol, and asynchronous failure surface without improving the settled latest-only model. Atom watches are also a poor fan-out mechanism: watches run while the atom lock is held and may be concurrent in future implementations (`gerbil/doc/reference/std/misc/atom.md:214-252`).

**Subscriber wakeup:** capacity-one channel plus latest snapshot.

Gerbil channels support fixed capacity, nonblocking `channel-try-put`, EOF after close, and idempotent close (`gerbil/doc/reference/std/misc/channel.md:5-22,112-139,239-291`). The current Tuna runtime already implements this exact coalescing model (`tuna/tuna/lib/runtime.ss:141-153,314-336`), and tests verify coherent/coalesced publication (`tuna/tuna/test/state-runtime-test.ss:185-239`).

Do not put complete profile snapshots in the channel. A stale queued value cannot itself implement “latest-only.” Store the latest under the mutex and treat the channel as invalidation only.

### Thread cleanup

Use `spawn/name`, close owner-produced channels, and join owned long-lived threads. Actor threads install an abortive exception handler that ensures unwind finalizers run on unhandled exceptions (`gerbil/doc/reference/gerbil/runtime/thread-primitives.md:1-29`; `gerbil/src/gerbil/runtime/thread.ss:31-67`).

Tuna already has a strong cleanup sequence:

1. close ingress/stop runtime;
2. join runtime;
3. stop server;
4. close and join completion observer

at `tuna/tuna/private/host.ss:124-157`, with service observer close/join at `tuna/tuna/private/service.ss:115-132`.

Prefer no profiler worker thread. If one is introduced later, it must be stopped and joined in this sequence. Subscriber channels must be removed/closed in `finally`, following existing SSE cleanup (`tuna/tuna/private/http.ss:197-217`).

### Typed records and immutability

Use typed final structs, for example typed fixnum/integer IDs and ticks, boolean status, symbols, and copied strings. Gerbil supports slot annotations such as `(field :- :fixnum)` throughout the standard library; its struct options include `final:`, `transparent:`, and `equal:` (`gerbil/doc/reference/gerbil/prelude/macros.md:431-450`).

However:

- `final:` prevents subtype extension; it does not make fields immutable;
- Gerbil structs have generated setters and generic slot mutation;
- `transparent:` affects equality/printing, not mutation.

Therefore “immutable profile snapshots” must be enforced by API shape:

- do not export setters or raw mutable builders;
- copy curated strings and collection inputs;
- freeze builder state into fresh records/lists before publication;
- never expose mutable hash tables;
- keep trace builders private and publish only detached snapshots.

True runtime-enforced immutable records are unsupported by the inspected Gerbil API.

### Disabled-mode macro

Use a macro expansion shaped like:

```scheme
(if (profile-enabled?)
    (call-with-profile-span context label details
      (lambda () body ...))
    (begin body ...))
```

This gives disabled mode one enable read and branch, with no timestamp, ID, mutex, context, record, channel, list, or thunk work on the false branch. A build feature can additionally use `cond-expand` to erase instrumentation completely; Gerbil permits it in expression position (`gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:101-128`). That compile-time mode is optional and cannot replace the settled live toggle.

Koyo is useful comparative evidence but should not be copied literally. It uses a process parameter, dynamic-wind nesting and monotonic milliseconds, but its macro binds a thunk before checking enablement (`/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:40-46,72-160`), potentially allocating in disabled mode. Its profiler is request-scoped middleware (`/home/jay/Code/koyo/koyo-lib/koyo/profiler.rkt:257-265`), unlike Tuna’s asynchronous command lifecycle.

### Exception-safe nested spans

Use `try`/`finally`; Gerbil documents it as an exception catcher plus unwind finalizer (`gerbil/doc/reference/std/sugar.md:33-70`). The span-finalizer should:

1. read end ticks;
2. restore/pop nesting context;
3. record normal/error/cancelled status;
4. publish a detached snapshot if appropriate.

If error metadata is needed, catch the exception, record only a curated exception category/message, and re-raise the identical object; finalization must not replace the application failure. Profiler-internal recording failures should be contained and logged rather than altering command behavior.

## Focused tests

Add tests for:

1. disabled branch evaluates body once and creates no trace/ticks/publication;
2. toggling is process-wide and immediately affects new commands;
3. toggling during a command does not split that command’s trace—capture enablement at admission;
4. nested normal and exceptional spans preserve parentage and close exactly once;
5. monotonic adapter produces nondecreasing ticks and sane durations;
6. valid HTTP keydown context reaches command owner and completion observer explicitly;
7. context never appears in `TunaRoot`, HTML, Datastar payload, or keydown JSON;
8. changed command publishes context before subscriber wakeup;
9. unchanged/failed commands have no delivery child;
10. two subscribers generate two delivery children;
11. coalescing attributes delivery only to the snapshot actually rendered;
12. render failure and peer disconnect close both span and subscription;
13. latest-profile subscribe-plus-snapshot has no missed-wakeup gap;
14. capacity-one profiler notifications never block command execution;
15. stop closes subscriptions and leaves no owned profiler thread;
16. source, normal compiled, and `-O` compiled behavior agree.

Existing tests already supply patterns for coalescing/race/shutdown (`tuna/tuna/test/state-runtime-test.ss:185-291`) and SSE failure/disconnect cleanup (`tuna/tuna/test/server-runtime-test.ss:368-500`).

## Validation commands

No commands were run during this research.

After implementation, update `test/command-runtime-suite-main.ss` and the source list in `test/run-command-runtime-matrix.sh`, then use:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
test/run-command-runtime-matrix.sh
```

This repository script runs source, normal compiled, and optimized `gxc -O` suites in isolated dependency stages (`tuna/tuna/test/run-command-runtime-matrix.sh:25-118`).

Full established gate:

```sh
cd /home/jay/Code/workbench-gerbil
GERBIL_BINDIR=/opt/gerbil/bin \
GO_BINDIR=/usr/local/go/bin \
ESBUILD=/home/jay/.nix-profile/bin/esbuild \
tuna/tuna/test/run-server-runtime-validation.sh
```

The gate performs the Tuna build, recursive tests, compiler-isolation matrix, executable/asset checks, and worktree validation (`tuna/tuna/test/run-server-runtime-validation.sh:1-107`).

## Risks and unsupported assumptions

- **High:** no documented stable high-level monotonic Gerbil API was found. The recommended Gambit primitive is internal.
- **Medium:** Gerbil structs are not truly immutable; immutability is by module/API discipline.
- **Medium:** atom dereference is implemented as a direct slot read. Cross-processor visibility is assumed by the atom abstraction but not explicitly documented at the raw accessor level.
- **Medium:** asynchronous children may arrive after the command root closes. The trace store must explicitly support attaching children to a closed root and republishing the updated latest snapshot.
- **Medium:** the exact profiler SSE/UI serialization contract was outside this bounded primitive review.
- **Low:** HTTP server thread creation details need not be assumed because context propagation is explicit.
- **Low:** coalesced commands may have no delivery children; this is intentional “actual work” semantics and should be documented.
- **Low:** enabling profiling does not retrofit already-open pages; this matches the settled reload requirement.

**Confidence:** high for runtime propagation points, mutex/channel/cleanup choices, parameter limitations, and disabled-path shape; medium for the private monotonic-clock adapter because it relies on an undocumented Gambit primitive.