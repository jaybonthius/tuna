# Gerbil `std/net/repl` viability for an attached Tuna REPL

## Executive finding

**Verdict:** the quarantined implementation is a useful spike reference, but it is not an adoptable v19 API.

- **It cannot compile unchanged on current v19.** Four imported modules are absent, the logging and address APIs changed incompatibly, and its thread lifecycle helpers are themselves quarantined.
- **A small compatibility port would probably restore the original behavior.** The essential Gerbil runtime `replx` implementation is unchanged from v18, and the Gambit private REPL hooks used by the source still exist with the expected three-port channel signature.
- **That port would still depend on unsupported Gambit internals.** Production-quality shutdown, authentication, Tuna state safety, and editor integration require additional design rather than merely reviving the file.
- For an ordinary same-process debug REPL, roughly **60–75% of the 233-line implementation could be reused conceptually or directly**. For a production attached Emacs service, expect to retain the Gambit REPL/channel core but newly build lifecycle tracking, access control, Tuna-safe operations, editor integration, and substantially broader tests.

The installed toolchain is Gerbil `v0.19-dev-31-g4a4d1a30`; the source checkout is `v0.19-dev-32-g4531c21b`. Neither provides `:std/net/repl`. An installed v18.2 copy does provide it and was used for behavioral checks.

## Source and history status

- The public documentation still instructs users to import `:std/net/repl` and describes the server, tainting, and expander loading:
  - `gerbil/doc/reference/std/net/repl.md:1-58`.
- The implementation and its only test are quarantined:
  - `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:1-233`.
  - `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl-test.ss:1-25`.
- Git commit `79725228` (“v0.19 development staging”) moved the source and test out of active `src/std` as 100% renames during a broad standard-library reorganization. It also quarantined `std/misc/threads`, replaced logging, and replaced the address API. There is no evidence of a targeted rejection of the REPL algorithm, but there is also no subsequent v19 port.
- The quarantined implementation has the same SHA-256 hash as its pre-staging active source.
- The last targeted fix was `33c84ae0` in February 2025, changing `##make-repl-channel-ports` from two to three arguments and adding the arithmetic connection test. The current source uses the corrected three-argument call at `repl.ss:146-154`.
- The test covers only one unauthenticated arithmetic expression:
  - `repl-test.ss:18-25`.
  - It does not cover authentication, multiple clients, interrupts, tainting, disconnects, nested debugging, expander loading, or shutdown.

## Exact execution model

### Startup and host-process evaluation

`start-repl-server!`:

1. Starts the old global logger.
2. Opens a TCP listener, defaulting to `127.0.0.1:7000`, with CR-LF end-of-line handling and address reuse.
3. Spawns the listener in a new child thread group.
4. Stores the listening socket in the server thread’s `thread-specific` slot and returns that thread.

Evidence: `repl.ss:26-34`.

For every connection, the listener creates a fresh child thread group, a REPL thread, a reader thread, and a monitor, then immediately resumes accepting connections:

- `repl.ss:49-69`.
- `make-thread-group` without an explicit parent attaches the new group to the current thread group: `gerbil/src/gambit/lib/_thread.scm:4264-4284`.
- `spawn/group` similarly creates a group under the caller: `gerbil/src/gerbil/runtime/thread.ss:37-54`.

Evaluation is **not performed by a separate interpreter process or RPC worker**. The client thread calls the runtime procedure `replx` inside the daemon:

- Client port parameterization and `replx` call: `repl.ss:88-97`.
- `replx` invokes Gambit `##repl` and converts evaluation exceptions into nested debugger REPLs: `gerbil/src/gerbil/runtime/repl.ss:10-26`.
- The generated bootstrap body performs the same operation: `gerbil/src/bootstrap/gerbil/runtime/repl~0.scm:4-44`.

Gambit reads a source expression, calls `##eval-within` using the captured REPL continuation, and writes returned values to the same channel:

- Prompt/read: `gerbil/src/gambit/lib/_repl.scm:2991-3020`.
- Eval/print: `_repl.scm:3427-3447`.
- Continuation-relative compilation and execution: `_repl.scm:3810-3835`.

Consequences:

- Evaluated code shares the daemon’s heap, global module bindings, file descriptors, threads, parameters, and side effects.
- Ordinary connection evaluation runs in its dedicated REPL client thread, not Tuna’s command-owner thread.
- It can reference loaded runtime globals, including namespace-qualified compiled identifiers.
- It does not automatically expose useful lexical locals from Tuna’s worker thread. Continuation-local inspection becomes relevant only when debugging a particular tainted thread.
- Multiple clients evaluate concurrently without isolation or serialization.

This is materially risky for Tuna. Tuna explicitly requires state installation to occur on its command-owner thread at `tuna/tuna/lib/runtime.ss:114-124`; arbitrary same-process REPL evaluation can bypass higher-level admission and ownership rules.

### Client protocol and connection method

The service is a raw character-oriented TCP REPL, not a structured editor protocol.

- Connect with `open-tcp-client`, `telnet`, or an Emacs network process.
- Send Scheme forms terminated by a line ending; the tracked test sends a single carriage return: `repl-test.ss:21-25`.
- Prompt is Gambit’s `"> "` and values are pretty-printed without framing:
  - `_repl.scm:2991-3020`.
- A v18 behavioral check returned exactly `"> 42\r"` for `(+ 20 22)`.
- There is no request identifier, response length, capability negotiation, completion API, source-location envelope, or output/event separation. An Emacs client would need `comint`-style prompt parsing and asynchronous debugger/output handling.

The reader implements only a subset of Telnet control handling:

- `0xff` starts an Interpret As Command sequence.
- WILL, WONT, and DONT options are discarded.
- DO timing-mark (`0x06`) receives WILL timing-mark.
- Telnet INTERRUPT (`IAC 0xf4`) asynchronously raises a user interrupt in the REPL client thread.
- Raw `0x04` acts as soft EOF.

Evidence: `repl.ss:99-137`.

This interrupt targets the network REPL thread, **not Tuna’s command runtime thread**.

### Expander loading

The network module does not load the Gerbil expander. The documentation is accurate on this point:

- `gerbil/doc/reference/std/net/repl.md:48-58`.

Without the expander, Gambit’s primitive evaluator handles the REPL. Basic Scheme, loaded globals, debugger commands, and namespace-qualified bindings remain available, but Gerbil module syntax and convenient imports are not generally available.

`gerbil-load-expander!` is part of the runtime and:

1. Requires the Gerbil runtime to have been initialized.
2. Installs the Gerbil compiler and expander hooks.
3. Imports `:gerbil/core`.
4. Replaces Gambit expansion/readtable hooks.
5. Is idempotent but process-global and has no unload operation.

Evidence:

- Loader setup: `gerbil/src/gerbil/runtime/init.ss:14-42`.
- Guard and idempotence: `gerbil/src/gerbil/runtime/init.ss:248-258`.
- Runtime evaluator begins with no current expander/compiler: `gerbil/src/gerbil/runtime/eval.ss:19-25`.

Important constraints:

- `gxi` already loads the expander during its own initialization, so testing the server inside `gxi` does not reproduce a minimal compiled daemon.
- A dynamically linked development Tuna executable may be able to load the installed expander modules on demand. A static/minimal artifact must explicitly include the necessary environment; the documentation only promises loading “if you have the expander environment.”
- Loading is process-wide and concurrent calls are not visibly synchronized.
- Tuna’s build deliberately avoids unsupported full-program optimization because it cannot initialize runtime source expansion: `tuna/tuna/README.md:61-67`. The expander must therefore be spiked in the actual normal-built Tuna executable, not inferred from `gxi`.

### Tainting and debugger routing

Importing the module immediately installs two global Gambit hooks:

- A custom EOF command handler: `repl.ss:159-185`.
- A custom thread-to-REPL-channel resolver: `repl.ss:187-195`.

These hooks are never restored when the server stops.

Each client’s `repl-state` is stored in its thread group’s single generic `thread-group-specific` slot. `repl-client-state` searches upward through group parents:

- `repl.ss:197-208`.

`taint!` copies the current network client’s state into a target group, defaulting to the primordial thread group, and returns the prior specific value for later restoration:

- `repl.ss:210-227`.

`untaint!` restores a supplied prior state or clears the slot:

- `repl.ss:229-233`.

What tainting does and does not do:

- It does **not** suspend, interrupt, or move execution to another thread.
- It makes a future Gambit debugger REPL opened in the target group or descendants use this client’s network channel. That permits continuation/frame inspection when a target thread enters the debugger.
- Defaulting to the primordial group potentially redirects debugger channels for nearly the entire process.
- It overwrites a generic thread-group-specific slot that another subsystem may already use; callers must retain and restore the state returned by `taint!`.
- Two clients tainting the same group race; the last write wins.
- Disconnect does not automatically untaint external groups, leaving stale state that refers to a closed client.
- Gambit caches a REPL channel on each thread after its first resolution (`_repl.scm:2631-2635`), so tainting may not redirect a thread that already acquired a channel.

Threads sharing a tainted client channel are serialized by Gambit’s channel ownership mutex, but their application operations are not serialized:

- Channel mutex construction: `_repl.scm:2902-2910`.
- Ownership behavior: `_repl.scm:2729-2748`.

### Authentication

Authentication is an optional plaintext password:

- Default `#f` means no authentication.
- Any non-`#f` value, including an empty string, enables it.
- The server prints `"Password: "` and compares each `read-line` result using ordinary `equal?`.
- Wrong passwords loop forever with no delay, attempt limit, close, audit event, or constant-time comparison.
- The reader thread starts only after successful authentication, so Telnet interrupt handling is unavailable during the password loop.

Evidence: `repl.ss:79-90`.

Observed v18 transcript for wrong then correct password and evaluation:

```text
Password: Password: > 2\r
```

There is no TLS, transport confidentiality, peer credential check, origin binding beyond the default loopback address, or separate authorization. Exposing a non-loopback address would expose a remote-code-execution interface protected only by this reusable plaintext string.

### Concurrency

- The accept loop creates independent REPL threads and continues accepting immediately: `repl.ss:49-69`.
- Two simultaneous v18 clients independently returned `"> 11\r"` and `"> 22\r"`.
- Evaluations can race each other and daemon threads over shared process state.
- Evaluation exceptions are caught by `replx` and open a nested debugger rather than ending the session: `gerbil/runtime/repl.ss:15-26`.
- A per-client monitor joins its REPL thread and then kills the client thread group: `repl.ss:71-77`.
- Tainting, expander loading, and global hook installation are not scoped per server.

### Disconnect and shutdown

Network EOF handling:

1. Reader sets `state.eof`.
2. It closes the write side of the string pipe.
3. The custom EOF handler returns from the REPL invocation rather than taking Gambit’s default process-exit path.
4. The client socket closes.
5. The REPL client joins its reader.
6. Its monitor kills the client group.

Evidence: `repl.ss:99-106`, `139-144`, `162-183`, and `88-97`.

Raw Control-D is treated as soft EOF without setting `state.eof`; nested REPLs close one level and a top-level network REPL returns from its invocation: `repl.ss:112-114`, `167-180`.

`stop-repl-server!`:

1. Retrieves the listener socket and server thread group.
2. Closes the listening socket.
3. Asynchronously wakes the listener.
4. Joins it.
5. Suppresses only an operating-system exception wrapped as an uncaught thread exception.
6. Finally kills the entire server group recursively.

Evidence: `repl.ss:36-47`.

The required helpers come from quarantined `std/misc/threads`:

- `thread-async!` uses Gambit interrupt internals: `v0.19-TODO-std/misc/threads.ss:135-169`.
- `thread-group-kill!` exists because Gambit group termination was noted as unimplemented: `misc/threads.ss:35-71`.
- Group detachment edits private structure fields and includes a comment that the ordinary deque operation is broken: `misc/threads.ss:94-118`.

Observed v18 shutdown returned successfully but emitted an unhandled `"Device is closed"` exception from the listener thread. Thus shutdown is functional but noisy and not fully graceful. It also does not restore global hooks or clear external taints.

## Current v19 compatibility audit

### Blockers to unchanged compilation

**Blocker — missing imports:** `repl.ss:5-10` imports:

| Import | Current v19 |
|---|---|
| `:gerbil/gambit` | absent; active replacement is `:gerbil/runtime/gambit` |
| `:std/error` | available |
| `:std/sugar` | absent; most syntax is now in the core prelude |
| `:std/logger` | absent; old module is quarantined and active API is `:std/log` |
| `:std/net/address` | available but incompatible for this usage |
| `:std/misc/threads` | absent and quarantined |

The test also imports missing `:std/sugar`: `repl-test.ss:3-5`.

**High — logging API mismatch:** the old code uses `start-logger!`, `debugf`, and `errorf` at `repl.ss:21`, `28`, `54`, `75`, and `142`. Current `:std/log` uses named logger objects and generated methods such as `log.debugf`; see:

- `gerbil/src/std/log/user.ss:11-46`.
- `gerbil/src/std/log/macros.ss:11-59`.
- Tuna’s current integration: `tuna/tuna/lib/log.ss:3-24`.

There is no active `start-logger!`.

**Medium — address API mismatch:** the old call builds a pair from Gambit socket information and passes it to `inet-address->string`: `repl.ss:53-58`. Current `:std/net/address` exports typed `Address` structures and does not export `inet-address->string` through its public API:

- `gerbil/src/std/net/address/api.ss:4-25`.
- The internal current function expects a typed `InetAddress`: `gerbil/src/std/net/address/stringer.ss:67-72`.

Gambit currently returns an address bytevector and port from `tcp-client-peer-socket-info`, so peer logging needs a new formatter.

**High — lifecycle dependency absent:** `thread-group-kill!`, `thread-async!`, and `primordial-thread-group` are not active v19 bindings. Carrying their old implementation forward would preserve private Gambit structure/interrupt dependencies.

### Runtime compatibility evidence

The core substrate is favorable for a spike:

- `gerbil/runtime/repl.ss` is byte-for-byte identical in the installed v18.2, installed v19-dev-31, and current v19 checkout.
- Current v19 installs `gerbil/runtime/repl` but not `std/net/repl`.
- Current Gambit still defines:
  - `##make-repl-channel-ports` with three ports: `_repl.scm:2902-2921`.
  - `##repl-context-command-set!`: `_repl.scm:3362-3365`.
  - `##thread-make-repl-channel-set!`: `_repl.scm:2677-2680`.
  - The referenced Gambit macros remain in current source.
- Runtime probes found `replx`, the channel constructor, and both setter hooks bound.

Therefore:

- **Original source unchanged:** no.
- **Original behavior after a compatibility port:** likely yes.
- **Supported/public v19 solution:** no; the defining channel, continuation, hook, interrupt, and thread-group operations remain private `##` or `macro-` interfaces.

## Material implementation options

### Option 1: Minimal compatibility resurrection

Update imports, logging, peer formatting, and supply replacement lifecycle helpers while retaining the reader, channel hooks, EOF override, and taint behavior.

- Likely reuse: about 160–180 of 233 source lines.
- New/changed code: approximately 40–100 lines plus tests.
- Advantage: quickest route to a faithful attached Gambit debugger.
- Risk: retains all global hook, taint, stale-channel, authentication, and private-internal risks. This should remain a development-only spike.

### Option 2: Reduced attached REPL without cross-thread tainting

Reuse `replx`, the TCP reader/channel adapter, and per-client sessions, but omit `taint!`, primordial-group routing, and recursive private group-kill logic. Track listener/client sockets and threads explicitly.

- Likely reuse: around 120–160 lines.
- New code: explicit server state, client registry, graceful close/join, tests, and v19 logging.
- Advantage: smaller blast radius and fewer dangerous process-wide debugging effects.
- Limitation: same-process evaluation remains arbitrary and concurrent; continuation debugging of Tuna threads is lost. Some private Gambit channel hooks are still needed.

### Option 3: Tuna-owned attached control/evaluation service

Build a purpose-specific local socket protocol that submits approved operations through Tuna’s command runtime. Optionally provide a separate explicitly enabled raw Gambit debugger for emergencies.

- Reuse from `std/net/repl`: mostly the protocol lessons and possibly the Telnet reader; likely less than 25%.
- New code: framing, request correlation, structured results/errors, authentication or Unix peer controls, lifecycle, Tuna command-lane adapters, Emacs client, and tests.
- Advantage: aligns with Tuna’s single command owner and supports robust Emacs integration.
- Limitation: not a full Scheme continuation debugger unless the unsupported Gambit path is retained separately.

## Severity-ranked findings

1. **Blocker:** `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:5-10` — absent and incompatible dependencies prevent unchanged v19 compilation.
2. **High:** `repl.ss:15-19, 146-195` — essential routing relies on private Gambit macros and global hook setters; no supported stability guarantee or restoration path exists.
3. **High:** `repl.ss:79-86` — authentication is optional, plaintext, brute-forceable, and unsuitable beyond a tightly controlled local development endpoint.
4. **High:** `repl.ss:49-69, 88-95` and `tuna/tuna/lib/runtime.ss:114-124` — arbitrary evaluations execute concurrently in the Tuna process outside its command-owner lane.
5. **High:** `repl.ss:210-233` — tainting the primordial group is process-wide, races between clients, overwrites generic group-specific state, and can leave stale closed-client state.
6. **Medium:** `repl.ss:36-47` — shutdown depends on quarantined raw thread internals and was observed to emit an unhandled closed-device exception.
7. **Medium:** `repl-test.ss:18-25` — coverage is far too narrow to attest authentication, debugger, interrupt, taint, disconnect, concurrency, or shutdown behavior.
8. **Medium:** `gerbil/doc/reference/std/net/repl.md:5-58` — documentation advertises an import that current v19 does not install.

## Concrete spike and validation commands

### Availability and preserved v18 behavior

```sh
gxi -v
gxi -e '(import :std/net/repl)'
find /opt/gerbil/v0.19-dev-31-g4a4d1a30/lib -path '*std/net/repl*' -print

/opt/gerbil/v18.2-20260722T1909420700/bin/gxi \
  -e '(import :std/net/repl)' \
  -e '(let* ((srv (start-repl-server! address: "127.0.0.1:17092"))
             (client (open-tcp-client "127.0.0.1:17092")))
        (display "(+ 20 22)\r" client)
        (force-output client)
        (write (read-line client))
        (newline)
        (close-port client)
        (thread-sleep! .1)
        (stop-repl-server! srv))'
```

### Focused compatibility spike

Work only in an isolated temporary copy; do not move the WIP file into the active tree merely to test it:

```sh
mkdir -p /tmp/gerbil-repl-spike/lib
cp gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss \
   /tmp/gerbil-repl-spike/repl.ss

# After applying spike-only compatibility edits:
gxc -V -S -d /tmp/gerbil-repl-spike/lib \
  /tmp/gerbil-repl-spike/repl.ss
gxc -O -g -d /tmp/gerbil-repl-spike/lib \
  /tmp/gerbil-repl-spike/repl.ss
GERBIL_LOADPATH=/tmp/gerbil-repl-spike/lib \
  gxtest /tmp/gerbil-repl-spike/repl-test.ss
```

Focused tests should cover at least:

- default loopback binding;
- correct, incorrect, empty, and absent password behavior;
- two concurrent clients;
- evaluation error followed by continued use;
- hard disconnect and Control-D;
- Telnet interrupt;
- stop with idle, authenticating, evaluating, and disconnected clients;
- expander absent/present;
- taint/untaint restoration and stale-state cleanup;
- no remaining listener, client, reader, or monitor threads.

### Full Gerbil validation if an active port is proposed

Repository commands are evidenced by `gerbil/Makefile:1-26` and `gxc`/`gxtest --help`:

```sh
cd gerbil
make stdlib
./build.sh env gxtest src/std/net/repl-test.ss
make check
```

### Tuna artifact validation

Use the project’s documented normal build, not unsupported full-program optimization:

```sh
cd tuna/tuna
gerbil build
test/run-command-runtime-matrix.sh
gerbil env tuna --no-config
```

The final manual spike should connect from a second shell or Emacs network process, verify the actual built Tuna artifact can call `gerbil-load-expander!`, import `:tuna/lib/prelude`, and confirm all state-changing work is routed through Tuna’s public command APIs rather than direct state mutation.

## Residual gaps and confidence

- **High confidence:** installed module absence, dependency incompatibilities, protocol, evaluation mechanics, authentication, concurrency, EOF handling, and current private-hook availability.
- **Medium confidence:** exact port size and built-Tuna expander availability, because no compatibility source was edited or compiled and the actual Tuna executable has not yet embedded the server.
- A current Gambit update can silently invalidate the private macros or raw thread-group field offsets even if the spike works today.
- No authoritative indication was found that the v19 maintainers intend to restore `std/net/repl`.
- The documentation’s continued presence should not be treated as API support.