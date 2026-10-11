# Final recommendation: Tuna attached REPL

## Direct correction

**Correct the prior recommendation as follows:** Tuna should implement a **daemon-side Gerbil source evaluator**, not typed Tuna command remote procedure call (RPC), and not expose Gambit’s raw `-:debug=$...` listener as the product endpoint.

The Emacs client sends complete Gerbil forms. A dedicated evaluation thread in the already-running Tuna daemon reads, expands, compiles, and evaluates those forms. Consequently:

```scheme
(defun attached-proof () 'v1)
```

executes inside the daemon and updates Tuna’s live function cell. Reconnecting and redefining it to `v2` changes what existing Tuna live-call wrappers observe.

The Tuna command runtime is involved **only when evaluated code deliberately submits an action or state transition**. It must not be the evaluator itself and must not receive source as typed command RPC.

## Ranked options

| Rank | Option | Same-process forms and live `defun` | Complete native REPL/debugger | API status | Recommendation |
|---:|---|---|---|---|---|
| **1** | Dedicated daemon-side `read-syntax`/`eval-syntax` lane over a local Unix socket | **Yes** | No continuation debugger initially | Predominantly active, public Gerbil APIs | **Production direction** |
| **2** | Reduced compatibility adapter around `replx` | **Yes** | **Yes** | Public `replx`, but private Gambit channel and EOF hooks | Optional development-only debugger |
| **3** | Documented `-:debug=$127.0.0.1:PORT` | **Yes** | **Yes** | Supported Gambit runtime option | Mechanism proof only; unsafe daemon lifecycle |
| **4** | Wholesale resurrection of quarantined `:std/net/repl` | **Yes** | **Yes** | Absent from v19; several obsolete dependencies and private hooks | Reject |
| **5** | Approved-operation/typed command RPC | **No** | No | Could use public APIs | Disqualified by the stated requirement |

### Why rank 1 wins

It satisfies the exact attached-REPL requirement while giving Tuna explicit connection framing, persistent session context, exception recovery, output bounds, and safe socket disconnects. It avoids the native REPL’s process-killing EOF behavior and most Gambit-private integration.

It is still unrestricted daemon-side evaluation—not a sandbox or command façade.

## Strongest option: exact mechanics

### 1. Startup and capability ownership

After Tuna constructs and starts its authoritative `CommandRuntime`, start an administration adapter and give it only:

- the authoritative runtime or a closure that submits through it;
- a dedicated evaluator queue;
- the selected private Unix-socket path.

The current `main` keeps the runtime lexical at `tuna/tuna/main.ss:11-29`. The adapter must receive that instance; creating another runtime would mutate a different state root.

Call `gerbil-load-expander!` even with `--no-config`. It installs Gerbil’s compiler, expander, and readtable hooks and is process-global and idempotent:

- `gerbil/src/gerbil/runtime/init.ss:14-42`
- `gerbil/src/gerbil/runtime/init.ss:248-258`

### 2. Persistent evaluation lane

Create one long-lived evaluator thread, separate from Tuna’s command-owner thread. On that thread:

1. Establish a Gerbil prelude using the same active pattern as Tuna’s config loader.
2. Import `:tuna/lib/prelude`.
3. Retain the expansion parameters and context around the evaluator’s entire request loop.
4. Serialize every form through that loop.
5. Keep the thread and context alive when a client disconnects.

Tuna’s existing pattern is:

- load the expander;
- create a `:gerbil/core` prelude;
- evaluate syntax one form at a time.

Evidence: `tuna/tuna/lib/config.ss:29-41`.

This persistence matters because expander contexts contain mutable binding tables:

- `gerbil/src/gerbil/expander/core.ss:13-64`

Imports bind into the current context:

- `gerbil/src/gerbil/expander/module.ss:840-872`

Therefore imports, ordinary top-level definitions, and macros remain available across requests and reconnects because the daemon retains the evaluator thread and context, not because the socket remains open. A daemon restart clears that interactive context.

Use only one evaluation lane initially; concurrent mutation of a shared expansion context is not documented as safe.

### 3. Transport and source evaluation

Use an owner-private Unix-domain socket. Current Gerbil publicly exports `unix-listen` and `unix-connect`:

- `gerbil/src/std/io/socket/api.ss:22-32,58-72`
- `gerbil/src/std/net/address/types.ss:52-58,83-108`

Use bounded length-prefixed frames. An evaluation request should contain:

- request ID;
- UTF-8 Gerbil source;
- source name/path;
- initial line and column.

The framing is transport metadata; the payload remains arbitrary Gerbil source, not a Tuna operation name.

For each request:

1. Convert the source payload into a character input port.
2. Repeatedly call `read-syntax` until end-of-file.
3. Evaluate each form sequentially with `eval-syntax`.
4. Use `call-with-values` and Gerbil/Gambit’s ordinary printers for returned values.
5. Stream bounded standard-output, standard-error, value, exception, and completion frames carrying the request ID.
6. After an exception, report it and continue with the next request rather than entering a nested debugger.

`read-syntax` uses Gerbil’s current readtable and creates located abstract syntax trees:

- `gerbil/src/gerbil/runtime/syntax.ss:255-280`

`eval-syntax` performs expansion, compilation, and evaluation:

- `gerbil/src/gerbil/expander/core.ss:168-190`

The active runtime exports `read-syntax`, `replx`, and `gerbil-load-expander!`:

- `gerbil/src/gerbil/core/runtime.ss:1848-1877`

Synthetic unsaved-buffer path/line assignment remains a spike question. The core reader obtains location from its port read environment, but a fully supported setter seam has not been established. Do not introduce broad Gambit internals solely for presentation metadata without a stop-gate review.

### 4. Daemon-side live mutation

`defun` expands to a normal Gerbil definition whose body calls `define-function!` and whose wrapper dereferences a stable function cell:

- `tuna/tuna/lib/prelude.ss:61-111`

Redefinition atomically resets the existing cell:

- `tuna/tuna/lib/bindings.ss:345-367`

Live lookup obtains the current implementation:

- `tuna/tuna/lib/bindings.ss:417-422`

Thus a form evaluated on the administration lane mutates the same daemon heap and cell registry used by compiled Tuna callers. Existing wrappers follow the replacement. A procedure previously saved from `function-ref` remains an old snapshot:

- `tuna/tuna/README.md:272-290`

This behavior was re-attested against the installed toolchain:

```text
#t v1
v2
```

A definition created on a spawned evaluation thread was also visible from its parent:

```text
daemon
daemon
```

Multiple forms are sequential but not transactional. If a later form fails, definitions and side effects from earlier forms remain.

## Reader, evaluator, printer, and debugger reuse

| Facility | Reused? | Exact qualification |
|---|---|---|
| Gerbil reader/readtable | **Yes** | `read-syntax`; no client-side parsing of Gerbil forms |
| Gerbil expander/compiler/evaluator | **Yes** | `gerbil-load-expander!` plus `eval-syntax` |
| Gerbil/Gambit value printing | **Yes** | Built-in printers, but Tuna supplies response framing and multiple-value collection |
| Native prompt/result-history loop | No | Tuna supplies the request loop |
| Nested continuation debugger | **No initially** | Exceptions become finite structured responses |
| Full `replx` debugger | Optional separate endpoint | Requires quarantined/internal compatibility work |

This should be described as a **true attached evaluator**, but not as reuse of the complete Gambit REPL.

By contrast, `replx` invokes Gambit’s full REPL and nested exception debugger:

- `gerbil/src/gerbil/runtime/repl.ss:10-26`

The native REPL evaluates within a captured continuation and prints through its channel:

- `gerbil/src/gambit/lib/_repl.scm:3427-3447`
- `gerbil/src/gambit/lib/_repl.scm:3810-3835`

## Tuna command and state ownership

The administration evaluator must never run on Tuna’s command-owner thread. State installation explicitly rejects every other thread:

- `tuna/tuna/lib/runtime.ss:114-135`

The owner consumes requests sequentially:

- `tuna/tuna/lib/runtime.ss:211-219`

Evaluated code that needs to commit application state must call an adapter that submits to the captured authoritative runtime through:

- `command-runtime-submit-transition!`: `tuna/tuna/lib/runtime.ss:281-292`

The owner then evaluates and installs the transition result:

- `tuna/tuna/lib/runtime.ss:137-178`

Rules:

1. The eval lane may submit a transition and wait for completion.
2. The command owner must never synchronously call or wait for the eval lane.
3. Never execute the evaluator while holding runtime or session mutexes.
4. Do not expose `install-state-root!` as the normal administration API.
5. Direct transition invocation remains diagnostic and non-committing.
6. Do not create a second `CommandRuntime`.

Existing tests establish that direct invocation does not commit and queued transitions resolve the live definition at dequeue:

- `tuna/tuna/test/state-runtime-test.ss:75-115`
- `tuna/tuna/test/state-runtime-test.ss:117-141`

Because arbitrary evaluation is trusted process administration, these boundaries prevent accidental misuse; they are not a security sandbox against malicious forms.

## Supported, quarantined, and internal interfaces

### Active/public interfaces suitable for rank 1

- `gerbil-load-expander!`
- `read-syntax`
- `eval-syntax`
- ordinary `write`, pretty-printing, and exception display
- current `unix-listen`/`unix-connect`
- Tuna `defun`, live bindings, and command-submission APIs

### Documented/supported but unsuitable as the endpoint

Gambit documents `-:debug=$[INTF][:PORT]` for compiled executables:

- `gerbil/src/gambit/doc/gambit.txi:2066-2072`
- `gerbil/src/gambit/doc/gambit.txi:2287-2293`

Each accepted connection creates a daemon-side native REPL channel and calls `##repl-debug-main`:

- `gerbil/src/gambit/lib/_repl.scm:5411-5434`

It proves true same-process attachment, but top-level EOF reaches process exit, `,q` exits, and only `,qt` safely terminates the listener’s handler thread:

- `gerbil/src/gambit/lib/_repl.scm:3059-3067`
- `gerbil/src/gambit/lib/_repl.scm:3289-3296`
- `gerbil/src/gambit/lib/_repl.scm:3489-3501`
- `gerbil/src/gambit/doc/gambit.txi:2565-2573`

An ordinary Emacs process disconnect must not be able to terminate Tuna, so this is not an acceptable product endpoint.

### Quarantined/unavailable

The documentation advertises `:std/net/repl`:

- `gerbil/doc/reference/std/net/repl.md:1-26`

But current v19 has no active `gerbil/src/std/net/repl.ss`. Its source is quarantined at:

- `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:1-233`

A current import returns `cannot find library module`. Its only test covers one arithmetic exchange:

- `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl-test.ss:18-25`

### Private/internal compatibility surface

A full remote `replx` requires private Gambit facilities, notably:

- `##make-repl-channel-ports`: `gerbil/src/gambit/lib/_repl.scm:2902-2921`
- `##thread-make-repl-channel-set!`: `gerbil/src/gambit/lib/_repl.scm:2677-2680`
- process-global EOF command hook: `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:159-185`
- process-global channel hook: `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:187-195`
- Telnet interrupt and reader plumbing: `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:99-157`

These are not stable supported Gerbil APIs.

## Is a compatibility port justified?

**Not for the required first attached evaluator.** Rank 1 already satisfies same-process evaluation and live `defun` using active APIs.

A **small, reduced compatibility experiment is justified only as a separately enabled development debugger** if interactive continuation/frame navigation becomes an explicit requirement. Such a port should:

- retain `replx`, channel construction, safe EOF, and interrupt handling;
- omit primordial-group `taint!` by default;
- avoid wholesale copying of obsolete logging, address, and thread-group code;
- allow only one local client;
- be isolated in a Tuna daemon adapter;
- pin and test the exact Gerbil/Gambit revision;
- never be enabled by default.

Do not revive `:std/net/repl` as though it were a supported v19 standard module.

## Security and shutdown constraints

### Security

**High severity:** attached evaluation is unrestricted code execution in Tuna’s process. It can read files, spawn processes, corrupt state, deadlock, or call `exit`.

Minimum controls:

- explicit opt-in;
- Unix socket only by default;
- user-private runtime directory mode `0700`;
- owner-only socket permissions;
- refuse unexpected pre-existing socket paths;
- one active client initially;
- frame and source-size limits;
- no plaintext TCP password scheme;
- audit connection metadata without logging source by default;
- document possession of the socket as full daemon authority.

The quarantined password loop is plaintext, unlimited, and ordinary `equal?` comparison:

- `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:79-86`

### Shutdown

Required order:

1. Mark the admin service stopping.
2. Close the listener and reject new requests.
3. Allow the active evaluation a bounded grace period.
4. Close client transport.
5. Stop and join the evaluator lane.
6. Then stop and drain Tuna’s command runtime.
7. Stop logging last.

A client disconnect must end only transport ownership; it must not exit Tuna or discard the retained expansion context.

There is no safe general forced cancellation of arbitrary evaluated code. Forced thread interruption may leave locks and external effects inconsistent. Tuna currently promises no cancellation or operating-system signal integration:

- `tuna/tuna/README.md:164-171`

## Bounded executable spike and stop gates

### Scope

Implement only:

- one opt-in Unix listener;
- one retained evaluator context and lane;
- one active client;
- bounded source and output frames;
- structured success/exception completion;
- one helper that submits transitions through the captured runtime.

Do **not** add cancellation, completion, multiple logical sessions, TCP, `replx`, tainting, or nested debugging.

### Required executable checks

1. Client A imports Tuna and defines `attached-proof` as `v1`.
2. Disconnect A; Client B evaluates it and receives `v1`.
3. B redefines it as `v2`; both `function-ref` and a compiled Tuna live wrapper observe `v2`.
4. An import and macro from A remain usable after reconnect.
5. Multiple values and output are correlated to the request ID.
6. A failed form reports an exception; the next request succeeds.
7. A redefined `deftransition` is used by a queued owner submission.
8. Direct transition invocation does not change revision; submitted invocation does.
9. Disconnect never terminates Tuna.
10. Idle and connected shutdown terminate cleanly.
11. An oversized frame is rejected before evaluation.
12. Socket directory and endpoint permissions are owner-only.

### Stop gates

- **Gate 1 — expander:** stop if the actual normal-built Tuna artifact cannot load the expander under `--no-config`.
- **Gate 2 — persistence:** stop if imports or ordinary definitions cannot survive reconnect on the retained lane.
- **Gate 3 — live mutation:** stop if compiled Tuna wrappers do not observe the redefined `defun`.
- **Gate 4 — ownership:** stop if committing state requires direct installation, a second runtime, or evaluation on the command-owner thread.
- **Gate 5 — lifecycle:** stop if disconnect, malformed input, or an evaluation exception can terminate the daemon or evaluator lane.
- **Gate 6 — compatibility:** stop and review if core evaluation needs Gambit-private APIs beyond a narrowly isolated source-location seam.
- **Gate 7 — security:** stop if the service cannot guarantee private local reachability and bounded frames.

## Validation commands

### Focused live-definition proof

```sh
cd /home/jay/Code/workbench-gerbil
env GERBIL_LOADPATH="$PWD/tuna/tuna" /opt/gerbil/bin/gxi -e \
'(import :gerbil/expander :tuna/lib/bindings)
 (gerbil-load-expander!)
 (eval-syntax (quote (import :tuna/lib/prelude)))
 (eval-syntax (quote (defun tuna-attached-final-proof () (quote v1))))
 (displayln (function-bound? (quote tuna-attached-final-proof))
            " "
            ((function-ref (quote tuna-attached-final-proof))))
 (eval-syntax (quote (defun tuna-attached-final-proof () (quote v2))))
 (displayln ((function-ref (quote tuna-attached-final-proof))))'
```

Attested output:

```text
#t v1
v2
```

### Availability check

```sh
cd /home/jay/Code/workbench-gerbil
test ! -e gerbil/src/std/net/repl.ss
test -e gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss
/opt/gerbil/bin/gxi -e \
  '(with-catch
     (lambda (e) (displayln (error-message e)))
     (lambda ()
       (eval (quote (import :std/net/repl)))
       (displayln "imported")))'
```

Current expected output:

```text
cannot find library module
```

### Focused and full validation after a Tuna adapter exists

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil build
test/run-command-runtime-matrix.sh
```

The matrix is the repository-authoritative source, normal-compiled, and optimized validation and checks worktree stability:

- `tuna/tuna/test/run-command-runtime-matrix.sh:1-101`

If a compatibility port modifies active Gerbil code, additionally run:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
make stdlib
./build.sh env gxtest src/std/net/repl-test.ss
make check
```

`make check` is defined at `gerbil/Makefile:46-47`.

## Review findings

- **blocker:** `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:1-233` — `:std/net/repl` is not an active/importable v19 module.
- **high:** `gerbil/src/gambit/lib/_repl.scm:3289-3296,3489-3501` — native network REPL EOF or `,q` can terminate Tuna.
- **high:** `tuna/tuna/lib/runtime.ss:114-135,211-219` — evaluation on the command owner would violate ownership and can deadlock on submission.
- **high:** arbitrary attached evaluation has full daemon authority and cannot be sandboxed by socket framing.
- **medium:** `gerbil/src/gerbil/expander/core.ss:13-64` — shared mutable expansion context should remain serialized.
- **medium:** exact unsaved-buffer source-path/line setup may require one isolated Gambit-internal seam.
- **medium:** installed Gerbil is `v0.19-dev-31-g4a4d1a30`, while the source checkout is `4531c21b90fa6ee04f374af905ae3ddb9d89d590`; repeat the spike against the exact production build.

**Confidence:** high for same-process live mutation, Tuna ownership, native REPL lifecycle hazards, and current module availability; medium-high for the recommended adapter until exercised in the actual compiled daemon.