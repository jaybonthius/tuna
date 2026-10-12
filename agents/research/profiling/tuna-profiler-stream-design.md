# Minimal Tuna/Datastar development profiler architecture

## Conclusion

**Recommended:** add a private, process-wide profiler coordinator beside `TunaService`, with:

- one latest command profile slot;
- an opaque profile token attached to each decoded POST keydown;
- exact owner-thread publication metadata attached to the runtime’s internal state root/publication—not to `TunaRoot`;
- capacity-one, coalescing profiler subscriptions;
- asynchronous state-delivery spans recorded by existing state subscriber handlers after actual render and `patch-elements` send;
- a dedicated fixed `GET /profile/subscribe`;
- a CSS-only, fixed-position Koyo-like widget patched with Datastar;
- a live `tuna-profiler-enabled` value, sampled per request/page, with reload required only to add or remove the widget and stream.

This preserves Tuna’s serialized command owner and nonblocking state publication. It introduces no sessions, browser/client identifiers, database, route framework, application-state fields, or profiler-driven application revisions.

The critical design requirement is to correlate a command with its installed revision **inside `install-state-root!`**, where the new revision is created and all subscriber invalidations are published. Reading `tuna-service-snapshot` later from the completion observer would race with subsequent commands.

## Current behavior and constraints

### Runtime and publication

- Tuna has one bounded command inbox and one owner thread: `tuna/tuna/lib/runtime.ss:27-42,58-77,211-245`.
- A changed transition installs exactly one new internal `StateRoot`; unchanged or failed transitions retain the old revision: `tuna/tuna/lib/runtime.ss:130-174`.
- Installation updates the root and then nonblockingly attempts one invalidation per active state subscription. Each subscription channel has capacity one, so publication never waits for a slow reader: `tuna/tuna/lib/runtime.ss:130-153,301-317`.
- Completion is posted only after changed-state installation and invalidation: `tuna/tuna/lib/runtime.ss:176-199`.
- Subscriptions are atomically registered with an initial snapshot and are removed idempotently: `tuna/tuna/lib/runtime.ss:301-336`.
- Existing tests prove coherent/coalesced publication, no subscribe/install missed wakeup, and shutdown closure: `tuna/tuna/test/state-runtime-test.ss:196-245,247-292,294-307`.

### HTTP and Datastar delivery

- A valid POST is decoded, submitted, and answered `204` on admission; it does not wait for command completion: `tuna/tuna/private/http.ss:145-169`.
- The page currently starts one long-lived stream using:
  `data-init="@get('/subscribe', {openWhenHidden: true})"`:
  `tuna/tuna/private/http.ss:125-136`.
- Each state subscriber sends an initial `#state` patch, then waits for an invalidation, rereads the latest snapshot, renders, and sends another full outer patch: `tuna/tuna/private/http.ss:186-217`.
- `patch-elements` synchronously constructs and sends a Datastar event: `datastar-gerbil/http/api.ss:132-155`; its core validates the selector/content and delegates to `sse-send!`: `datastar-gerbil/http/private/core.ss:381-423`.
- `sse-send!` writes and flushes before returning, so a send span can represent actual server-side transport completion: `sse-gerbil/sse.ss:40-58`.
- EPIPE and ECONNRESET are treated as ordinary peer disconnects and subscriptions close in `finally`: `tuna/tuna/private/http.ss:176-217`.
- There is no heartbeat. Idle disconnects are discovered only on a later write or shutdown: `datastar-gerbil/README.md:25-32`.

### Configuration and assets

- Listener values are snapshotted after config, while the renderer is resolved live: `tuna/tuna/main.ss:12-31`; `tuna/tuna/private/render.ss:76-86`.
- Live values are backed by Tuna value cells and may be changed after definition without being reset by redefinition: `tuna/tuna/lib/bindings.ss:608-660`; public configuration syntax is in `tuna/tuna/lib/prelude.ss:264-309`.
- Assets are embedded with `:std/source` and declared as build extra inputs: `tuna/tuna/private/web-assets.ss:1-9`; `tuna/tuna/build.ss:8-15`.
- The current gate explicitly requires Node-free tooling and a standalone esbuild only for deterministic keyboard-plugin verification: `tuna/tuna/test/run-server-runtime-validation.sh:1-9,67-118`.
- The committed Datastar release and keyboard plugin provenance are documented at `tuna/tuna/web/README.md:1-34`.

## Recommended architecture

### 1. Private profiler coordinator

Add a private module, conceptually `private/profiler.ss`, owned by `TunaService`. It should contain:

- a mutex;
- the latest profile snapshot;
- a monotonically increasing internal profile number;
- active profiler-stream subscriptions;
- a closed flag;
- an injected clock procedure for deterministic tests.

The profile number is only an internal correlation key. It must not be accepted from or exposed as a browser/client/session identifier.

A profile is an immutable snapshot replaced under the coordinator mutex. Suggested fixed fields:

- internal profile number;
- status: `admitting`, `queued`, `running`, `changed`, `unchanged`, `failed`, or `rejected`;
- admission/start/end monotonic timestamps;
- curated keydown context;
- before revision;
- installed revision, if any;
- fixed synchronous stage spans;
- bounded asynchronous delivery spans;
- delivery-detail overflow count.

Creating a newer decoded keydown immediately replaces the public latest slot. Updates to a superseded profile may finish internally but must not republish it. This gives genuine latest-only behavior rather than a hidden history API.

### 2. One profile per POST keydown

Create the profile after successful JSON/key schema decoding and before service admission.

Consequences:

- Every syntactically valid keydown POST receives one profile.
- `accepted` continues through owner execution.
- `full` and `not-running` finish immediately as `rejected`.
- Requests rejected before keydown decoding—wrong method, missing Datastar marker, unsupported content type, malformed JSON—are HTTP failures, not command profiles.

The curated root description should contain only bounded facts already validated by the endpoint:

- logical `key`;
- physical `code`;
- location/repeat;
- active modifier names;
- final dispatch result;
- resolved transition symbol when the default dispatcher reaches an exact binding;
- sanitized failure summary.

`key` and `code` already have 64-character limits: `tuna/tuna/private/http.ss:88-98`. Do not retain the HTTP request, headers, full JSON, root value, transition arguments, thread object, socket, IP address, database statements, or arbitrary printed Scheme values.

### 3. Exact command-to-revision correlation

Extend the runtime’s **private** command request with an opaque observation/profile token. Do not change public command results or `TunaRoot`.

During owner execution:

1. Record owner start and the current internal revision.
2. Run the transition.
3. For `StateChanged`, pass the token into `install-state-root!`.
4. `install-state-root!` creates the new internal root and records private publication provenance alongside it.
5. It nonblockingly publishes invalidations to all state subscriptions.
6. It returns the newly installed root/publication receipt.
7. Record the installed revision directly from that receipt and end the command root after publication.

This is the only race-free point: the revision is created at `tuna/tuna/lib/runtime.ss:137-143`, subscriber invalidations happen at `:144-152`, and the function returns only afterward.

The internal state wrapper can become conceptually:

```text
StateRoot(revision, value, publication-provenance)
```

Public `command-runtime-snapshot` must continue returning only revision and application value. Profiler metadata must not enter `TunaRoot`, affect equality, increment revisions, or cause state invalidations.

### 4. Synchronous command stages

Use a small fixed vocabulary rather than a generic instrumentation framework:

```text
keydown <key/code>                          root
├─ queue                                   admission → owner dequeue
├─ dispatch                                owner execution
│  ├─ normalize                            default dispatcher only
│  ├─ resolve                              default dispatcher only
│  ├─ acquire arguments                    exact binding only
│  └─ transition <trusted symbol>          exact binding only
└─ publish revision N                      changed only
```

The root ends after publication, not after browser delivery. Raised exceptions close the active span in an unwind/finally path and mark the profile failed.

The current default dispatcher has distinct normalization, resolution, acquisition, and target invocation points suitable for these curated spans: `tuna/tuna/private/application.ss:294-344`. A live user replacement of `tuna-dispatch` still receives queue/dispatch/publication profiling, but cannot promise the default dispatcher’s nested spans.

### 5. Asynchronous delivery children

State delivery remains in each existing subscriber handler. After an invalidation:

1. Read the invalidation’s wake revision.
2. Atomically read the latest state root and its internal publication provenance.
3. Begin an asynchronous delivery child against that provenance.
4. Measure `render-tuna-snapshot`.
5. Measure the actual `patch-elements` call.
6. Complete the child as `sent`, `disconnected`, or `failed`.
7. Publish the revised profile snapshot only if it is still the latest profile.

The shape is:

```text
└─ state delivery                          asynchronous
   ├─ render revision N
   └─ send #state revision N
```

No subscriber/client ID is needed; repeated delivery children represent separate internal state-subscriber executions. Do not retain request/socket details.

Because `patch-elements` returns only after `sse-send!` flushes, the send duration covers the actual server render/write/flush path, not merely enqueueing: `datastar-gerbil/http/private/core.ss:417-423`; `sse-gerbil/sse.ss:40-58`.

The owner never waits for these children. Existing capacity-one state invalidations remain nonblocking.

### 6. Coalescing, unchanged commands, and failures

#### Coalesced state invalidations

The channel may contain an older wake revision while the handler rereads a newer root. Record on the delivery child:

```text
delivered revision 15; wake revision 12; coalesced 3 installed revisions
```

The delivery belongs to the profile provenance on revision 15, because that is what was actually rendered and sent. Intermediate changed profiles have been superseded and are not recreated in the latest-only UI.

A wake whose state revision no longer corresponds to the latest command profile must not be attached to an unrelated unchanged or failed command.

#### Unchanged command

Show:

- before revision N;
- status `unchanged`;
- dispatch/result spans;
- no publication span;
- no state-delivery children.

This matches the runtime rule that `StateUnchanged` does not install or invalidate: `tuna/tuna/lib/runtime.ss:156-174`.

#### Failed command

Show:

- before revision N;
- status `failed`;
- completed/failed synchronous spans;
- sanitized exception summary;
- no installed revision, publication span, or delivery children.

The command owner remains alive because command exceptions are posted to the completion rather than killing the worker: `tuna/tuna/lib/runtime.ss:176-199`. The existing service observer logs such failures asynchronously: `tuna/tuna/private/service.ss:32-57`.

#### Changed command later superseded by unchanged/failed command

A delayed state delivery may finish against the prior changed profile. Since that profile is no longer latest, store the completion only transiently or discard it; do not replace the latest unchanged/failed profile. This is the unavoidable and correct consequence of settled latest-only presentation.

### 7. Separate profiler stream and feedback-loop prevention

Add only the fixed route:

```text
GET /profile/subscribe
```

The handler must:

- reject non-GET with `405` and `Allow: GET`;
- require profiling currently enabled;
- preferably require `Datastar-Request: true`, which official Datastar fetch adds;
- register atomically with the current latest profile snapshot;
- send one initial outer patch;
- loop on capacity-one invalidations and reread latest;
- close its subscription in `finally`;
- apply the same EPIPE/ECONNRESET handling as the state stream.

Send:

```scheme
(patch-elements session fragment
                selector: "#tuna-profiler"
                mode: 'outer)
```

Profiler-stream render/send must never create profile spans. Only POST keydown commands and state-subscriber deliveries are instrumentation entry points. Therefore:

- a profile mutation wakes the profile stream;
- rendering/sending the profiler widget performs no profile mutation;
- no feedback loop occurs;
- profile updates never invalidate application state.

### 8. Publication, backpressure, and bounds

Use the same proven invalidation pattern as state subscriptions:

- one capacity-one channel per profiler stream;
- `channel-try-put`, never `channel-put`, while publishing;
- subscriber rereads latest;
- profile rendering and network sends occur only in that subscriber’s handler;
- shutdown closes all profiler subscription channels;
- peer disconnect removes the subscription in `finally`.

To make the complete profile bounded, not merely latest-only:

- fixed synchronous span vocabulary;
- cap sanitized failure text at 512 characters;
- cap completed delivery details, **recommended initial bound: 64**;
- after the cap, increment an “additional deliveries omitted” counter;
- retain no completed profile history.

A fixed global profiler-stream limit is also advisable to prevent unlimited idle registrations; **64 streams** is a reasonable development default, returning `503` above it. This number is not established by current repository behavior and is the only tuning choice still lacking product evidence. Without such a limit, memory is bounded per connection but not process-wide because Gerbil creates a handler per accepted connection.

No heartbeat is recommended for this minimal design. Active profiling commands create writes that discover dead peers; an entirely idle dead connection can remain registered until shutdown, matching the current state stream’s documented limitation.

### 9. Datastar page initialization

Reuse both Datastar `patch-elements` and the page’s existing `data-init`. When enabled, emit:

```html
<body data-init="@get('/subscribe', {openWhenHidden: true}); @get('/profile/subscribe', {openWhenHidden: true})">
```

When disabled, preserve the current markup exactly:

```html
<body data-init="@get('/subscribe', {openWhenHidden: true})">
```

Datastar v1.0.2 compiles expressions as JavaScript function bodies, so two semicolon-separated action invocations are valid. `data-init` executes its expression immediately when applied:

- official pinned source `library/src/engine/engine.ts:488-537`;
- official pinned source `library/src/plugins/attributes/init.ts:11-33`;
- commit `e24f04d43ca4445d662b4a035e5bfe9ed68de57c`.

Both GET actions use distinct URLs, so Datastar’s method/URL cancellation map does not make them cancel one another: official pinned `library/src/plugins/actions/fetch.ts:16-64`.

No new browser plugin is required.

### 10. Widget HTML, CSS, and assets

Render one stable fragment, for example:

```html
<aside id="tuna-profiler" class="tuna-profiler">
  <!-- CSS-only collapsed label and nested timing tree -->
</aside>
```

Requirements:

- fixed bottom-left placement;
- high but bounded `z-index`;
- monospace/tabular numeric timing values;
- collapsed total/status label;
- CSS-only open/close controls;
- scroll-bounded detail panel;
- namespaced `tuna-profiler__*` classes;
- no inline executable script;
- no database-statement links.

A hand-authored `web/tuna-profiler-v1.css` can be embedded with `this-source-content` and inserted as a `<style>` block only on enabled pages. This:

- adds no public asset route;
- adds no JavaScript or Node dependency;
- follows the existing source-embedding mechanism;
- requires adding the CSS path to `private/web-assets.ss` and the target’s `extra-inputs` in `build.ss`;
- requires deterministic byte/source checks in the existing asset gate.

The alternative—keeping CSS as a Gerbil string literal—is smaller in file count but bypasses the repository’s established source-input tracking. Embedded hand-authored CSS is preferable.

Current embedding evidence: `tuna/tuna/private/web-assets.ss:1-9`; `tuna/tuna/build.ss:8-15`.

### 11. Live toggle behavior

Define and export a live value, default `#f`, for example:

```scheme
tuna-profiler-enabled
```

Semantics:

- Sample it once when rendering a page. That sample controls CSS, widget markup, and the second `data-init` action.
- Sample it once when a decoded keydown reaches profiler admission.
- A command admitted while enabled remains profiled to completion even if the value changes.
- A command admitted while disabled is not retroactively profiled.
- Enabling begins profiling subsequent commands immediately, but an already loaded disabled page needs reload to gain the widget and profiler stream.
- Disabling stops creation of subsequent command profiles immediately. Existing enabled pages retain the last widget until reload; their streams receive no new command updates.
- Reload is therefore required for UI presence, not for changing the live server-side collection flag.
- Do not push a special enable/disable event or revise application state.

This matches Tuna’s live value-cell model while avoiding a second configuration subsystem.

### 12. Security and escaping

Tuna currently validates an IPv4 loopback listener before allocating resources: `tuna/tuna/private/host.ss:100-126`. The profiler should remain explicitly development-only and default disabled.

Nevertheless:

- Treat `Datastar-Request` as a marker, not authentication.
- Do not enable Cross-Origin Resource Sharing.
- Do not expose cookies, headers, IP addresses, state roots, arguments, stack dumps, SQL/database statements, or arbitrary printed objects.
- Render all dynamic profiler values only in text nodes.
- Escape `&`, `<`, and `>` at minimum; escape quotes too if any future dynamic value enters an attribute.
- Generate IDs and `for` values only from validated internal integers.
- Replace carriage return, NUL, and other unsafe controls before rendering. `patch-elements` rejects carriage return and NUL content: `datastar-gerbil/http/private/core-test.ss:346-355`.
- Truncate exception descriptions before escaping.
- Never concatenate the application’s trusted raw renderer output into profiler markup.

The current `escape-tuna-html` is safe for text nodes but not a general attribute escaper: `tuna/tuna/private/render.ss:43-58`.

## Koyo comparison

Authoritative installed Koyo package:

- package `koyo-lib` version `0.48.1`;
- catalog commit/checksum `1a378e46f3938946d8ed1fb4680bbea42e9a6caf`;
- source `https://github.com/Bogdanp/koyo.git?path=koyo-lib`.

### What transfers

Koyo provides useful presentation and span-model precedents:

- a profile contains parent-linked timings: `/home/jay/.local/share/racket/9.2/pkgs/koyo-lib/koyo/profiler.rkt:43-81`;
- timing uses monotonic time and unwind-safe final recording: `.../koyo/profiler.rkt:120-146`;
- disabled instrumentation executes the body directly: `.../koyo/profiler.rkt:148-159`;
- the widget is a nested timing tree with CSS-only checkbox controls: `.../koyo/profiler.rkt:176-244`;
- the widget is fixed at the lower-left and scroll-bounded: `.../blueprints/standard/resources/css/_uprofiler.scss:1-47`;
- documentation explicitly describes a development-only widget shown when profiling is enabled: `/home/jay/.local/share/racket/9.2/pkgs/koyo-doc/scribblings/profiler.scrbl:10-41`.

Transfer:

- parent/child timing tree;
- monotonic durations;
- unwind-safe span closure;
- cheap disabled path;
- fixed collapsible development widget;
- concise labels and descriptions.

### What does not transfer

Koyo is a synchronous request profiler:

- `wrap-profiler` creates a dynamically scoped profile per HTTP request and wraps the handler: `.../koyo/profiler.rkt:256-266`.
- Its template captures that dynamic profile and writes the widget as part of the same response body: `.../blueprints/standard/app-name-here/components/template.rkt:43-51,88-96`.
- Its database integration collects statements for that request/thread: `.../koyo/profiler.rkt:92-118`; `.../koyo/database.rkt:76-113,157-181`.

Tuna differs materially:

- POST returns after admission, before command completion.
- The owner executes on another thread.
- state render/send occurs later in independent long-lived subscriber threads;
- one process-wide latest profile is required;
- no database context is wanted;
- profile updates must stream after the page response.

Therefore Koyo’s request middleware, thread parameter as correlation mechanism, synchronous `profile-write`, database collector, and inline JavaScript statement links do not transfer.

## Architecture options

### Option A — Private runtime provenance plus separate profile coordinator

**Recommended.**

Attach an opaque profile token to the private command request, capture exact install/publication metadata on the owner, retain provenance in the internal state root/publication, and let subscriber handlers add asynchronous delivery children.

Advantages:

- exact accepted-command → installed-revision correlation;
- exact command-through-publication boundary;
- actual render/send timing;
- correct coalescing attribution;
- no owner blocking;
- no application-state coupling;
- no public generic instrumentation API.

Costs:

- bounded internal changes to runtime request/root structures and state subscriber payloads;
- careful synchronized profile snapshot updates.

### Option B — Service completion observer plus before/after snapshots

Create the profile in `tuna-service-submit-keydown!`; let the existing completion observer wait and compare snapshots afterward.

Advantages:

- smallest runtime diff;
- reuses existing observer.

Defects:

- a later command can install before the observer snapshots, so revision attribution is racy;
- unchanged and failed commands may be misclassified;
- it cannot prove the command ended at publication;
- it has no robust provenance for coalesced subscriber delivery.

**Not recommended** for the settled semantics.

### Option C — Generic lifecycle/event instrumentation bus

Add generic command-start, transition, publication, render, and send events, then implement the profiler as a listener.

Advantages:

- reusable for future metrics/tracing;
- separates profiler data structures from runtime.

Costs:

- materially larger abstraction and API surface;
- ordering, listener failure, and blocking policies become new runtime contracts;
- generic events risk retaining unsafe arbitrary context;
- still needs explicit publication provenance for asynchronous delivery.

This is justified only if Tuna wants a general observability subsystem. It is excessive for the settled development widget.

## Deterministic tests

### Focused unit tests

Use an injected clock returning a manually controlled monotonic value. Do not assert elapsed wall time or use “less than N milliseconds” thresholds.

1. **Changed command stages**
   - hold owner execution with existing completion/channel gates;
   - set fake time at admission, dequeue, transition end, publication start/end;
   - assert exact queue, dispatch, publication, and total durations;
   - assert installed revision is the one returned by installation.

2. **Unchanged and failed commands**
   - exact before/after revision;
   - statuses `unchanged` and `failed`;
   - no publication/delivery child;
   - sanitized failure text.

3. **Latency delivery stages**
   - use the existing injectable test `ResponseHandler`/writer seam from `tuna/tuna/test/server-runtime-test.ss:80-123`;
   - gate render and writer progress;
   - set fake clock at render/send boundaries;
   - assert exact values and that delivery may finish after the command root.

4. **Coalescing**
   - leave a subscriber invalidation channel occupied;
   - commit several changed commands;
   - consume one wake and reread latest;
   - assert one delivery against the latest installed revision with the exact wake/latest revision delta.

5. **Latest-only compare-and-update**
   - supersede a changed profile with unchanged/failed work before its delayed delivery finishes;
   - assert the old delivery cannot replace or republish the latest profile.

6. **Profiler backpressure**
   - leave a profiler subscription unread;
   - perform multiple profile mutations;
   - assert one wake, then empty;
   - reread the exact latest snapshot.

7. **No feedback**
   - subscribe to profiler updates;
   - complete a state delivery and observe one profiler wake;
   - render/send that profiler patch;
   - assert no additional profiler wake.

8. **Escaping and bounds**
   - malicious key/error text containing markup, quotes, newline, carriage return, and NUL;
   - assert exact safe HTML;
   - assert delivery-detail and exception caps.

9. **Live toggle/page markup**
   - save/restore the live value;
   - disabled page has neither CSS, widget, nor profile GET;
   - enabled page has all three and preserves the state GET;
   - changing the value does not mutate an already rendered page string.

10. **Disconnect and shutdown**
    - mirror existing EPIPE/ECONNRESET/non-peer error cases at `tuna/tuna/test/server-runtime-test.ss:397-540`;
    - assert profile subscription cleanup and service shutdown closure.

### Protocol tests

Extend the existing raw HTTP test to cover:

- enabled and disabled `GET /`;
- `GET /profile/subscribe` headers and initial widget frame;
- wrong method and disabled behavior;
- a valid keydown POST followed by a profile patch;
- state stream still receives its normal revision;
- profile send does not create another profile frame;
- terminal chunks and listener rebinding remain correct.

Current protocol seam: `tuna/tuna/test/server-protocol-test.ss:20-124`.

## Evidence-backed validation commands

No build, server, or test was run during this research.

After implementation, focused tests should use Gerbil’s documented exact-file form (`gerbil/doc/reference/dev/test.md:1-32`):

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna

gerbil test -v 0 \
  ./test/profiler-test.ss \
  ./test/state-runtime-test.ss \
  ./test/server-runtime-test.ss \
  ./test/server-protocol-test.ss
```

Compiler-mode coverage:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
timeout --signal=TERM --kill-after=10s 30m \
  test/run-command-runtime-matrix.sh
```

Full repository-established Tuna gate:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
ESBUILD=/home/jay/.nix-profile/bin/esbuild \
  test/run-server-runtime-validation.sh
```

The full gate currently performs the ordinary build, recursive tests, source/normal/optimized matrix, deterministic esbuild comparison, embedded-asset checks, Node-free inventory, and whitespace validation: `tuna/tuna/test/run-server-runtime-validation.sh:11-127`.

## Risks and unresolved gaps

1. **Bound tuning:** the proposed limits of 64 profiler streams and 64 detailed delivery children are not established by current product evidence. Some fixed bound is needed for strict process-wide memory bounds.
2. **Open widget state:** repeated outer morphs may reset CSS checkbox expansion state. This is presentation-only; native `<details>` is a viable alternative if preserving expansion through morphs matters.
3. **Live redefinition:** a user-replaced `tuna-dispatch` cannot automatically provide the default dispatcher’s nested normalize/resolve/acquire spans. Owner-level queue/dispatch/publication spans remain valid.
4. **Idle disconnects:** without heartbeat, an idle disconnected profile stream can remain registered until a later update or shutdown, matching current SSE behavior.
5. **Profiler overhead:** enabled mode adds monotonic clock reads, short mutex operations, immutable snapshot replacement, and nonblocking fanout. Disabled mode should branch before profile allocation.
6. **No network-ack meaning:** a successful `BufferedWriter-flush` means bytes reached the server’s output stack, not that the browser applied the DOM patch.
7. **Current Git context:** the Tuna repository is clean at `3b6b95a`; the outer workbench contains pre-existing modified/untracked material. This research made no changes.

**Confidence:** high for runtime/publication and Datastar/SSE mechanics; high for why completion-observer correlation is insufficient; high for Koyo transfer/non-transfer; medium-high for the recommended module boundaries; medium for the proposed fixed numeric bounds and widget interaction details.