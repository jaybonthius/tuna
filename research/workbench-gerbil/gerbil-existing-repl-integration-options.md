# Gerbil v19 REPL integration options for Tuna

## Answer

Gerbil v19 provides one public in-process foreground entry point, `replx`, and inherits several supported Gambit runtime REPL channels, including a TCP listener. These reuse Gambit’s complete reader/evaluator/printer and debugger.

However:

- **`replx` is suitable only with careful lifecycle handling.**
- **Gambit’s built-in inbound TCP REPL is unsafe for a long-lived Tuna process because leaving a session terminates the whole process.**
- **The documented `:std/net/repl` API is not present in the current v19 source/build.** Its documentation is stale relative to v19.
- The exact entry point used by `gxi`, `##repl-debug`, and the port/channel hooks are internal Gambit mechanisms, not supported Gerbil APIs.

## Option summary

| Option | API status | Suitable for long-lived Tuna? |
|---|---|---|
| `replx` on foreground/dedicated thread | Public Gerbil runtime binding, lightly documented in source | Possible, but process-exit, EOF, port, and stop semantics require care |
| Gambit `-:debug=$INTF:PORT` inbound TCP server | Supported Gambit runtime option | **No, not without internal adaptation:** ending the session exits Tuna |
| Gambit `-:debug=@HOST:PORT` reverse connection | Supported Gambit runtime option | Possible for controlled debugging; it changes the channel but does not itself start a REPL |
| Gambit error/interrupt REPL via `debug=r/R` | Supported Gambit runtime option | Debugging only, not a persistent application console |
| `:std/net/repl` | Documented historical public API | **Unavailable in current v19** |
| `##repl`, `##repl-debug`, channel hooks | Internal Gambit API | Technically usable, unsupported and version-fragile |
| Run Tuna under `gxi` and use `-` | Supported `gxi` behavior, not embedding | Does not provide a concurrent post-startup REPL for Tuna’s blocking `main` |

---

## 1. Public local entry point: `replx`

### Evidence and semantics

`replx` is deliberately included in the Gerbil runtime “so that it is available to all binaries.” It invokes Gambit’s existing `##repl` and catches REPL evaluation exceptions by nesting another REPL:

- `gerbil/src/gerbil/runtime/repl.ss:10-26`
- Exported through Gerbil’s public runtime bindings at `gerbil/src/gerbil/core/runtime.ss:1861-1876`
- Present in bootstrap output at `gerbil/src/bootstrap/gerbil/runtime/repl.ssi:1-6` and `gerbil/src/bootstrap/gerbil/runtime/repl~0.scm:4-44`

A compiled Tuna process can therefore invoke:

```scheme
(replx)
```

No parser, evaluator, result printer, or debugger command implementation is needed. Gambit reads one expression, pretty-prints every non-void result, and maintains result history:

- `gerbil/src/gambit/lib/_repl.scm:2991-3020`
- Evaluation dispatch: `gerbil/src/gambit/lib/_repl.scm:3427-3447`

### Foreground and lifecycle behavior

`replx` blocks its calling thread. For Tuna to remain operational while the REPL is active, either:

- start Tuna’s command runtime before entering it on the main thread; or
- run `replx` in a dedicated thread.

Tuna currently starts its worker and then blocks waiting for it at `tuna/tuna/main.ss:17-29`.

Important exit semantics:

- `,q` calls `##exit` and terminates the **whole process**: `gerbil/src/gambit/lib/_repl.scm:3489-3494`; manual confirmation at `gerbil/src/gambit/doc/gambit.txi:2565-2568`.
- `,qt` terminates the current thread; if that is primordial, it terminates the process: source `gerbil/src/gambit/lib/_repl.scm:3496-3501`, manual `gerbil/src/gambit/doc/gambit.txi:2570-2573`.
- `,d` does nothing at top level: `gerbil/src/gambit/lib/_repl.scm:3478-3481`.
- A `replx` call can return through `,(c value)`. This was attested with `,(c 42)`, which returned `42` to its caller.
- Hard end-of-file reaches the default “EOF again to exit” path and ultimately `,q`, so loss of stdin can terminate Tuna: `gerbil/src/gambit/lib/_repl.scm:3059-3067,3289-3296`.

There is no public `stop-replx!` or cancellation handle.

### Port behavior

The REPL does **not** simply use dynamically parameterized `current-input-port` and `current-output-port`. It obtains a cached per-thread REPL channel:

- Channel creation/cache: `gerbil/src/gambit/lib/_repl.scm:2631-2640`
- Standard input/console channel selection: `gerbil/src/gambit/lib/_repl.scm:2682-2703`
- Public REPL port getters: `gerbil/src/gambit/lib/_repl.scm:2705-2727`

An attested test parameterized current ports around `replx`; the REPL still read and wrote standard I/O, while the supplied output string remained empty. Runtime debug options select standard I/O, standard error, or controlling console:

- `debug=c`, `debug=-`, `debug=+`: `gerbil/src/gambit/doc/gambit.txi:2263-2277`

Arbitrary application-owned ports require internal channel creation/hooks such as `##make-repl-channel-ports` and `##thread-make-repl-channel-set!`; these are `##` internals, not supported Gerbil API.

---

## 2. Expander and evaluation environment

### Primitive Gambit mode

Without loading the Gerbil expander, the REPL evaluates primitive Gambit syntax. The historical network REPL documentation explicitly describes this behavior:

- `gerbil/doc/reference/std/net/repl.md:48-58`

This still describes the underlying `replx`/Gambit behavior even though that network module itself is absent in v19.

### Full Gerbil mode

A compiled binary must link `:gerbil/expander` and call:

```scheme
(gerbil-load-expander!)
```

Authoritative evidence:

- Compiled-binary guidance and example: `gerbil/doc/guide/eval.md:19-44,62-93`
- Loader requires initialized runtime and is intended to be idempotent: `gerbil/src/gerbil/runtime/init.ss:248-258`
- It installs Gerbil’s source-expansion and macro hooks and Gerbil readtables: `gerbil/src/gerbil/runtime/init.ss:14-42`

Tuna already links `:gerbil/expander` through `tuna/tuna/lib/config.ss:1-5`. It activates the expander only when `load-config!` runs, at `tuna/tuna/lib/config.ss:29-41`. Because `main` calls that only when a configuration path is selected (`tuna/tuna/main.ss:14-19`), a `--no-config` run does not proactively call `gerbil-load-expander!`.

### Namespace and import semantics

REPL/eval code executes in the global interaction environment, not Tuna’s module namespace:

- Gambit interaction environment: `gerbil/src/gambit/doc/gambit.txi:345-357`
- Gerbil compiled-module namespace distinction: `gerbil/doc/guide/eval.md:19-72`

Consequences:

- Tuna module-private names are not lexically in scope.
- Full Gerbil mode allows ordinary `(import :tuna/...)` for exported bindings, assuming Tuna’s compiled modules are on the Gerbil load path.
- Private/global module bindings require qualified names such as `tuna/module#name` or a Gerbil `extern` declaration.
- Loading the expander does not expose already-compiled lexical locals or retroactively alter compiled expansions.

### Lexical/debug context

For nested debugger REPLs:

- Interpreted frames expose lexical and dynamic context.
- Compiled frames evaluate expressions in the global interaction environment.

This is stated at `gerbil/src/gambit/doc/gambit.txi:2529-2537`. The implementation also explicitly rejects direct access to a compiled procedure’s environment at `gerbil/src/gambit/lib/_repl.scm:3784-3808`.

Compiled environment display is additionally limited by compiler declarations and optimization:

- Source/location data requires `debug-location`/`debug-source`: `gerbil/src/gambit/doc/gambit.txi:2670-2682`
- Environment display requires interpreted code or `debug-environments`, and optimized bindings may be absent: `gerbil/src/gambit/doc/gambit.txi:2727-2747`

---

## 3. Supported Gambit network mechanisms

### Inbound server: `-:debug=$INTF:PORT`

Gambit documents a runtime option that opens a TCP listener, defaulting to `127.0.0.1:44555`:

- `gerbil/src/gambit/doc/gambit.txi:2287-2293`

Runtime options can be supplied through `GAMBOPT` or as the first argument of a compiled program:

- `gerbil/src/gambit/doc/gambit.txi:2424-2438`

The server is started automatically during Gambit runtime initialization:

- `gerbil/src/gambit/lib/_repl.scm:5413-5445`

It creates a REPL channel from the accepted connection and calls `##repl-debug-main`:

- `gerbil/src/gambit/lib/_repl.scm:5416-5433`

A compiled Tuna run was attested with:

```sh
gerbil env tuna '-:debug=$127.0.0.1:47125' --no-config
```

The TCP client received a Gambit prompt, evaluated `(gerbil-system-version-string)`, and Tuna’s command runtime was concurrently running.

#### Blocking limitation: session exit terminates Tuna

`##repl-debug-main` unconditionally calls `##exit` after the REPL returns:

- `gerbil/src/gambit/lib/_repl.scm:3150-3182`

This was attested in both `gsi` and compiled Tuna: sending `,c` closed the socket and exited the process with status 0. A hard socket EOF also reaches the process-exit path.

**Severity: blocker for direct use as Tuna’s durable network console.**

There is also no documented public stop-server handle; the listener is runtime-global.

### Reverse connection: `-:debug=@HOST:PORT`

Gambit can connect outward when a thread starts a REPL:

- Documentation and defaults: `gerbil/src/gambit/doc/gambit.txi:2279-2285`
- Connection retry behavior and approximately 100-second failure window: `gerbil/src/gambit/lib/_repl.scm:2637-2675`

This changes the interaction channel but does not itself initiate a REPL. It must be combined with:

- explicit `replx`;
- an internal `##repl` call; or
- error/interrupt settings that trigger a nested REPL.

It can avoid opening an inbound port, but still grants unrestricted code execution to the peer.

### Error/interrupt debugger REPL

Supported debug settings can enter a nested REPL on uncaught errors or user interrupts:

- Primordial/all-thread selection and error behavior: `gerbil/src/gambit/doc/gambit.txi:2177-2203`
- User interrupt behavior: `gerbil/src/gambit/doc/gambit.txi:2205-2226`
- Defaults: `gerbil/src/gambit/doc/gambit.txi:2297-2305`

This is suitable for emergency debugging, not a continuously available application console. Changing to all-thread REPL behavior can suspend arbitrary worker threads and redirect their interaction to whatever channel the runtime selected.

---

## 4. `:std/net/repl`: documented but unavailable in v19

**Severity: blocker/documentation mismatch.**

The current reference still advertises:

```scheme
(import :std/net/repl)
(start-repl-server! ...)
(stop-repl-server! ...)
```

at `gerbil/doc/reference/std/net/repl.md:1-26`.

But current v19 source has no `gerbil/src/std/net/repl.ss`. The implementation and test have been moved to:

- `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss`
- `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl-test.ss`

An actual `(import :std/net/repl)` failed with “cannot find library module.” Therefore it is not a supported current v19 integration option.

### Historical semantics, if restored upstream or vendored

The quarantined implementation shows why it was materially safer than Gambit’s built-in listener:

- Public exports and loopback default `127.0.0.1:7000`: lines 5-34
- Explicit stop closes listener, wakes/joins server, then kills its thread group: lines 36-47
- One client thread group/session per accepted connection: lines 49-77
- Optional plaintext password loop with unlimited retries: lines 79-86
- Client ports are parameterized and `replx` handles errors: lines 88-97
- Telnet control handling maps C-c to a REPL-thread interrupt: lines 99-144
- Custom hard/soft EOF behavior returns from the REPL instead of exiting the process: lines 159-185
- It globally replaces Gambit’s REPL channel factory: lines 187-195
- `taint!` installs the current client’s REPL state on an application thread group; `untaint!` restores prior state: lines 197-233

Taint is needed when a debugger REPL must run in an application thread’s continuation rather than merely in the network service thread. It mutates thread-group-specific state and is explicitly described as interactive-use functionality. Failing to restore the old state can leave application-thread debugger ports attached to a dead or wrong client.

Because this code globally overrides Gambit REPL hooks and relies on internal macros and `##` procedures, simply copying it into Tuna would assume ownership of compatibility with future Gambit/Gerbil changes.

---

## 5. Internal exact-`gxi` mechanisms

`gxi` enters its foreground REPL with:

```scheme
(##repl-debug #f #f #t)
```

at `gerbil/src/gerbil/gxi-main.ss:23-35`.

`##repl-debug` changes global error and interrupt debug settings before calling `##repl`:

- `gerbil/src/gambit/lib/_repl.scm:3137-3148`

This is the closest direct reuse of the normal `gxi` top-level behavior and permits `,c` to return to its caller. It is nevertheless an internal Gambit API because of its `##` name and is not exported/documented as a Gerbil embedding contract.

`gxi-main` itself is included in Gerbil’s universal executable and not exposed as a public embedding API. The universal executable initializes the runtime and expander before dispatch:

- `gerbil/src/gerbil/main.ss:117-124,241-256`

### Source `gxi` command-line behavior

- Explicit `-` enters the blocking REPL: `gerbil/src/gerbil/gxi-main.ss:85-92`.
- With no arguments, `gxi` loads interactive initialization and enters the REPL: lines 106-109.
- A module/file exporting `main` receives all remaining arguments: lines 30-35,95-105.

Therefore:

- `gxi - :tuna/main` gives a REPL **before** Tuna starts.
- `gxi :tuna/main -` passes `-` to Tuna’s `main`; it is not processed later as a `gxi` REPL request.
- Since Tuna’s `main` waits indefinitely on its runtime, source `gxi` does not itself provide a concurrent post-startup REPL.

Running a separate `gxi` subprocess also cannot inspect the existing Tuna process state.

---

## Security and operational risks

1. **Critical — unrestricted remote code execution.** Every option exposes full evaluator, filesystem, process, module-loading, and shutdown capabilities. There is no sandbox or capability boundary.
2. **Critical — no authentication in Gambit’s `$` listener.** Bind loopback only and protect access externally if used for debugging.
3. **High — historical `:std/net/repl` password is plaintext, has unlimited retries, and has no Transport Layer Security (TLS):** `v0.19-TODO-std/net/repl.ss:79-86`.
4. **High — `,q`, hard EOF, or normal completion of `##repl-debug-main` exits Tuna.**
5. **High — no public stop operation for `replx` or Gambit’s runtime listener.**
6. **Medium — foreground REPL and application stdin/stdout contend for the same channel.**
7. **Medium — compiled Tuna locals are not a stable evaluation context; module imports/qualified globals are required.**
8. **Medium — concurrent expander use across multiple network sessions is not documented as safe. `gerbil-load-expander!` uses a global idempotence flag but configures parameterized expander state and global hooks; no multi-client guarantee was found.**
9. **Medium — internal channel and debugger hooks are runtime-global, so custom overrides have process-wide blast radius.**

## Confidence and unresolved gaps

**Confidence: high** for API availability, evaluation context, port behavior, v19 module absence, and fatal inbound-server shutdown. These are supported by current source and direct compiled-Tuna attestation.

Unresolved:

- No authoritative guarantee was found for concurrent full-Gerbil expansion from multiple REPL client threads.
- No public v19 replacement for the quarantined `:std/net/repl` module was found.
- The checkout is `v0.19-staging` commit `4531c21b...`; the runnable adjacent Gerbil installation reports `v0.19-dev-31`, while source describes `v0.19-dev-32`. The missing module is definitive in the current source tree, but a later v19 revision could restore it.
- The Gerbil subrepository contains pre-existing modifications to generated Gambit C files; this research did not modify them.

## Focused validation commands

```sh
# Confirms current v19 cannot import the documented network module.
./gerbil/run.sh gxi -e '(import :std/net/repl)'

# Confirms public local REPL evaluation and controlled return.
printf '(+ 1 2)\n,(c 42)\n' |
  ./gerbil/run.sh gxi -e \
    '(begin (displayln "before")
            (let ((x (replx))) (displayln "after:" x)))'

# Verify repository state and absence of staged changes.
git -C gerbil status --short
git -C gerbil diff --cached --quiet
```

For a future implementation, Tuna’s evidence-backed full validation remains:

```sh
(cd tuna/tuna && gerbil build)
(cd tuna/tuna && test/run-command-runtime-matrix.sh)
```