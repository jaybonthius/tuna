# Tuna web-terminal runtime integration research

## Conclusion

The smallest correct vertical slice is an **independent application/example host package** around Tuna, not an extension of Tuna’s existing executable or core libraries.

It should own:

- one `make-state-command-runtime`;
- one immutable application root `(counter ordered-maps pending-sequence)`;
- browser-event validation and `KeyStroke` construction;
- the application dispatcher transition;
- HTTP routes and Datastar rendering;
- one runtime state subscription per `/subscribe` connection;
- server/runtime startup and shutdown.

No additional Tuna public API is required for this fixed one-key example. The main missing seams are intentionally application-level: production dispatcher, event normalizer, root type, renderer, server lifecycle, and HTTP error policy.

## Repository state finding

**Note — stale artifact wording:** `/home/jay/Code/workbench-gerbil/tuna` is clean at `46783db feat(keymap): add pure resolver and outcome observers`. There is no current uncommitted Tuna change. The reports still describe the implementation as “uncommitted” at:

- `research/tuna-input-keymaps-implementation-report.md:5,49-68`
- `research/tuna-input-keymaps-acceptance-review.md:5`

The outer workbench sees `tuna/` as an untracked nested repository, but Tuna’s own index and worktree are clean. Neither Tuna, Job Getter, nor the outer checkout has staged files.

## Current Tuna implementation versus the contract

The implementation matches the approved boundary:

- The contract makes the resolver pure and keeps dispatcher/root/event mapping in applications: `plans/tuna-input-keymaps/spec.md:7-25,34-45`.
- Browser events are normalized host data, not transition names: `spec.md:47-58`.
- External tokens must be whitelisted rather than interned: `spec.md:102-114`.
- Dispatch must use the dequeue-time root and directly invoke the live transition in the same owner call stack: `spec.md:129-163`.
- One root owns application, keymap policy, and prefix state; one input produces at most one installation: `spec.md:167-180`.

Concrete implementation:

- Public keymap API: `tuna/tuna/lib/keymap.ss:3-26`.
- Canonical modifier validation and `KeyStroke` construction: `keymap.ss:51-123`.
- Immutable sequence append and checked inspection: `keymap.ss:125-157`.
- Transition-only bindings: `keymap.ss:159-175`.
- Defensive keymap construction: `keymap.ss:265-303`.
- Ordered exact/undefined/continuation/absent resolution: `keymap.ss:307-371`.
- Runtime outcome observers: `tuna/tuna/lib/runtime.ss:95-107`.
- The complete application-shaped dispatch algorithm exists only as a test fixture: `tuna/tuna/test/input-dispatch-test.ss:12-102`.
- Dequeue-time maps, live replacement, independent runtimes, rollback, and recovery are tested at `input-dispatch-test.ss:197-462`.
- Build and three-mode matrix include the new modules/tests: `tuna/tuna/build.ss:4-14`; `tuna/tuna/test/run-command-runtime-matrix.sh:29-105`.

The README correctly says Tuna supplies neither browser capture nor runtime input mapping: `tuna/tuna/README.md:180-187,216-230`.

## Smallest authoritative root

Use one application-defined opaque root:

```scheme
(defstruct TerminalRoot
  (counter ordered-maps pending-sequence)
  final: #t
  equal: #t)
```

Initial semantic contents:

```scheme
(counter 0)
(ordered-maps (list global-map))
(pending-sequence (empty-key-sequence))
```

The fixed global map contains one sequence:

```scheme
(make-key-stroke 'logical #\i '())
  -> (make-transition-key-binding 'terminal-increment '())
```

The trivial target increments `counter`, preserves `ordered-maps`, receives an already-cleared prefix, and returns `state-changed`.

This is the test fixture’s `TestInputRoot (value maps pending feedback)` reduced by removing feedback, which the one-command slice does not need: `input-dispatch-test.ss:12-15,28-39,154-155`.

For browser display, project the whole snapshot to one explicit datum, for example:

```scheme
(terminal
  (revision 1)
  (counter 1)
  (active-maps (global))
  (pending ()))
```

Then HTML-escape its printed form and render exactly:

```html
<pre id="state">(terminal ...)</pre>
```

Because `Keymap` is opaque and has no enumeration API, a general renderer cannot recover map entries. For this fixed host, the application already knows the canonical `global` declaration and can render that semantic label. Dynamic map serialization would require retaining application-owned declarations alongside the opaque resolver value; Tuna intentionally omitted enumeration (`spec.md:38-45`).

## POST event to atomic live transition

### 1. Browser payload

The stable host page captures `keydown` and posts an immutable normalized payload such as:

```json
{
  "domain": "logical",
  "code": "i",
  "modifiers": []
}
```

The host, not Tuna core, owns `preventDefault`, repeat, Input Method Editor (IME), editable-control, and accessibility policy. Server-side resolution is too late for synchronous cancellation: `spec.md:224-233`.

For rapid terminal input, Datastar’s `requestCancellation` must be disabled for the key POST. Its default can cancel an in-flight request with the same method and URL: `job-getter/docs/datastar/docs.md:2754-2771`. A canceled HTTP request can still have admitted Tuna work, producing confusing client/server divergence.

### 2. Host validation and `KeyStroke`

The handler uses Gerbil Datastar’s `read-signals`, which accepts POST JSON and bounds bodies to 1 MiB: `datastar-gerbil/http/api.ss:18-73`.

It must:

1. require an object/hash with exactly supported fields;
2. map `"logical"` to the pre-existing symbol `'logical`;
3. map `"i"` to the controlled character `#\i`;
4. map modifier strings through a closed table to canonical symbols;
5. reject unknown, duplicate, improper, or mistyped values;
6. call `(make-key-stroke 'logical #\i modifiers)`.

It must never call `string->symbol` on request data. The constructor accepts only a symbol domain, controlled symbol/character/integer code, and canonical modifiers: `keymap.ss:57-96`; `spec.md:104-108`.

The resulting host request can be only:

```scheme
(defstruct TerminalInput (stroke) final: #t equal: #t)
```

### 3. Runtime admission

The HTTP handler submits:

```scheme
(command-runtime-submit-transition!
 runtime
 'terminal-dispatch
 (list terminal-input))
```

Admission is nonblocking and returns `accepted`, `full`, or `not-running`: `runtime.ss:265-306`; `README.md:115-121`.

For `accepted`, wait for completion before returning HTTP 204. Installation and invalidation occur before completion: `runtime.ss:155-196`.

The host must define responses for `full`, `not-running`, malformed events, and transition exceptions; Tuna does not prescribe HTTP status policy.

### 4. Dispatcher

On dequeue, `terminal-dispatch` receives the current root and:

1. appends the request stroke to `root.pending-sequence`;
2. resolves the complete sequence against `root.ordered-maps`;
3. on exact resolution, synchronously obtains the binding’s argument list (`'()` here);
4. constructs `base` with an empty pending sequence;
5. directly calls:
   ```scheme
   (apply invoke-state-transition binding-name base arguments)
   ```
6. propagates the target outcome using `state-changed?`, `state-unchanged?`, `state-changed-value`, and `state-outcome-result`.

The reference implementation is exact at `input-dispatch-test.ss:59-102`. Its single-install behavior is asserted at `input-dispatch-test.ss:197-240`.

The dispatcher must not submit nested runtime work. The runtime invokes the dispatcher once and privately installs only its final changed candidate, yielding one revision: `runtime.ss:155-171`; `spec.md:155-180`.

## `/subscribe`, revision wakeups, and fat morphing

Each `/subscribe` request should:

1. call `command-runtime-subscribe-state!`;
2. receive the initial `(revision, root, subscription)` atomically;
3. open `call-with-datastar-sse`;
4. immediately render that snapshot as the complete `<pre id="state">…</pre>`;
5. wait on `state-subscription-wait!`;
6. after every wake, ignore the notification as data and call `command-runtime-snapshot`;
7. render the latest complete semantic snapshot and:
   ```scheme
   (patch-elements session html selector: "#state" mode: 'outer)
   ```
8. exit on end-of-file;
9. always call `state-subscription-close!` in `finally`.

Registration and the initial snapshot share the runtime lock, so no commit can fall into a subscribe/read gap: `runtime.ss:312-328`. Every changed installation increments revision and tries to put the revision into each capacity-one subscription channel without blocking the owner: `runtime.ss:132-153`.

Notifications are deliberately coalesced. A slow tab can skip intermediate revisions but, after waking, must render the latest snapshot. This is documented at `README.md:164-169` and tested at `state-runtime-test.ss:196-248,250-292`.

Datastar’s default `outer` mode morphs the selected element; the Gerbil SDK defaults to `outer`: `datastar-gerbil/http/private/core.ss:13,284-287`. This is the desired “fat morph”: one authoritative semantic region, not granular UI patch commands.

Keep the node owning `data-init="@get('/subscribe', …)"` outside `<pre id="state">`, so the stream never replaces its own owner. This matches Job Getter’s stable body/live-main split:

- subscription on stable body: `job-getter/app/features/admin/views.py:43-75`;
- broad outer patch: `job-getter/app/features/admin/handlers.py:144-162`;
- Datastar morph behavior: `job-getter/docs/datastar/docs.md:54-87`.

## Multiple tabs

With one runtime:

- every tab has its own Tuna state subscription and SSE connection;
- a POST from any tab enters the same bounded command lane;
- a changed revision wakes every active tab;
- each tab rereads and morphs the same latest root;
- slow tabs may coalesce revisions but converge on the newest state.

Job Getter verifies the corresponding global-fanout behavior with two streams at `job-getter/tests/test_admin_http.py:158-203`.

A consequential constraint is that `pending-sequence` is also shared. For multi-key bindings, one tab can start a prefix and another tab can complete or clear it. That is correct for the requested single shared session but must not be mistaken for per-tab input state. Per-tab prefixes would require page/session identity inside the one root and an explicit application policy.

Using `openWhenHidden: true` keeps background tabs current. Datastar otherwise closes hidden-tab GET streams and reconnects when visible: `job-getter/docs/datastar/docs.md:2689-2697,2764-2766`.

Concurrent requests are ordered by runtime admission, not necessarily original browser event time. The one-key increment is commutative; future prefix-sensitive input may need a host sequence-number or client-side serialization contract.

## Lifecycle ownership

### Current Tuna executable

Current `tuna/main.ss`:

1. initializes logging;
2. selects config;
3. constructs a **stateless** command runtime;
4. evaluates config;
5. starts the runtime;
6. waits on it;
7. stops and joins it;
8. shuts logging down.

Evidence: `tuna/tuna/main.ss:11-31`.

Config is ordinary Gerbil evaluated form-by-form: `tuna/tuna/lib/config.ss:29-41`. CLI selection only supports `--config` and `--no-config`: `tuna/tuna/lib/startup.ss:6-31`. Tuna explicitly has no HTTP, operating-system signal, or input lifecycle: `README.md:171-178`.

### Recommended host lifecycle

The new host executable should own every resource:

**Startup**

1. initialize Tuna logging;
2. select and load config, preserving current “config before live runtime” behavior;
3. construct the fixed keymap and initial root;
4. construct `make-state-command-runtime`;
5. construct mux and HTTP server, closing over the runtime;
6. start the runtime;
7. start the server;
8. wait in the host main thread.

The runtime must start before the server accepts handlers because subscribing requires an active runtime: `runtime.ss:312-317`.

**Shutdown**

1. call `command-runtime-stop!` to reject new work and drain accepted work;
2. join the runtime; runtime completion closes all remaining state subscriptions, waking SSE loops with end-of-file;
3. stop the HTTP server;
4. shut down logging.

Runtime drain-and-close behavior is at `runtime.ss:216-241,350-372` and is tested at `state-runtime-test.ss:294-307`.

During the brief runtime-drain interval, HTTP requests must translate `not-running` rather than block or silently drop. If eliminating that interval becomes necessary, the host needs an ingress-shutdown gate; Tuna does not currently provide one.

Gerbil’s server owns listener and handler threads; `server.stop!` closes listener and connection sockets and has a three-second termination fallback: `/opt/gerbil/current/src/std/net/http/server/server.ss:25-60,114-138`.

Every handler owns exactly one subscription and closes it in `finally`. Runtime shutdown is the backstop, not a substitute for handler cleanup.

## Host placement options

| Shape | Advantages | Costs |
|---|---|---|
| Extend `tuna/main.ss` | One executable and existing config flags | Converts a host-neutral stateless runtime executable into a browser application; adds HTTP/Datastar dependencies and application root policy to Tuna itself |
| Add a second web executable inside package `:tuna` | Small source footprint; can reuse existing build | Browser code and dependencies still live in Tuna’s package/distribution; normal Tuna build becomes coupled to web tooling unless a second build path is created |
| **Independent application/example package** | Preserves Tuna’s boundary; owns root, parser, renderer, routes, dependencies, and lifecycle; follows existing package precedent | One small package/build script and executable |

**Recommendation:** create an independent example/application package, analogous to `tuna/packages/dummy`, with its own `gerbil.pkg`, build script, executable, and dependencies on Tuna and `gerbil-datastar`. Tuna’s build already deliberately builds only Tuna while the dummy package builds independently: `tuna/tuna/build.ss:4-14`; `tuna/tuna/README.md:45-54`.

This is the smallest placement that exercises the public runtime and resolver without introducing browser or user-interface abstractions into Tuna core.

## Python-specific versus transferable Job Getter behavior

### Transferable

- Command/query responsibility separation (CQRS): command request mutates and returns 204; a separate GET stream renders authoritative state (`handlers.py:194-244`).
- Subscribe before initial authoritative read to close the race (`handlers.py:80-94`).
- Stable stream owner outside a broadly morphed semantic region (`views.py:43-75`; `handlers.py:144-162`).
- Every tab has an independent stream but receives shared-state changes (`tests/test_admin_http.py:158-203`).
- Validate untrusted Datastar payloads into typed host values before mutation (`signals.py:36-85`).
- Reconnects begin with a complete current-state patch.

### Python/Stario-specific — do not copy literally

- `asyncio.timeout`, async generators, and `context.alive()`.
- Stario `App`, `Context`, `Writer`, `SSE`, and `read_signals`.
- Python dataclasses.
- `RelayNotificationBus` and async context-manager subscriptions (`app/bus.py:1-42`).
- SQLite re-query, authentication, Cross-Site Request Forgery (CSRF), and page-specific feedback topics.

Tuna state subscriptions replace the Python notification bus for this slice. Adding another bus would create needless dual publication and risk missed or reordered state notifications.

## Missing seams and residual risks

- **No blocker:** existing public Tuna runtime, resolver, snapshots, subscriptions, and outcome observers are sufficient for the fixed vertical slice.
- **Important:** production dispatcher, root/request types, browser token whitelist, renderer, and lifecycle host do not exist; this is intentional contract scope, not an incomplete Tuna implementation (`spec.md:34-45`).
- **Important:** `Keymap` cannot be enumerated or serialized. A dynamic “entire root” renderer needs application-owned map declarations.
- **Important:** Datastar Gerbil currently discovers SSE disconnects only on a later write or server shutdown. A long-idle dead client can retain a blocked handler/subscription until the next state change. Periodic heartbeat support is recommended for anything beyond the minimal demonstration: `datastar-gerbil/README.md:31`.
- **Important:** default Datastar request cancellation is unsafe for terminal event streams; use `requestCancellation: 'disabled'`.
- **Important:** browser key capture, IME, layout, repeat, accessibility, editable controls, and reserved shortcuts remain host product decisions.
- **Important:** `full`, `not-running`, malformed request, and transition-failure HTTP responses remain undefined.
- Bind only to loopback for the minimal local host. Nonlocal deployment requires explicit origin, CSRF, authentication, and transport-security policy.
- Roots, requests, argument specifications, and descendants remain immutable by contract rather than runtime enforcement.
- External effects cannot be rolled back if a transition fails.

## Validation commands

No build or test command was run during this read-only research task. Evidence-backed commands for the current foundations are:

**Focused Tuna resolver/dispatcher/outcome suites**

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
GERBIL_LOADPATH="$PWD" gxi -e '
(import :std/test
        :std/test/base
        :tuna/test/keymap-test
        :tuna/test/state-outcome-test
        :tuna/test/input-dispatch-test)
(for-each
 (lambda (suite)
   (unless (test-result-ok? (test-suite! suite))
     (error "focused suite failed")))
 (list keymap-test state-outcome-test input-dispatch-test))
'
```

**Full Tuna build and three-mode matrix**

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil build
test/run-command-runtime-matrix.sh
```

These are derived from `spec.md:209-222` and the tracked matrix harness at `tuna/tuna/test/run-command-runtime-matrix.sh:29-105`.

**Datastar/SSE foundation**

```sh
cd /home/jay/Code/workbench-gerbil/datastar-gerbil
gerbil build
gerbil test -v 0 ./...
```

Documented at `datastar-gerbil/README.md:15-29`.

The existing implementation report records previous successful Tuna build, source `gxi`, normal `gxc`, and `gxc -O` runs at `research/tuna-input-keymaps-implementation-report.md:108-123`; those results were inspected but not independently rerun here.