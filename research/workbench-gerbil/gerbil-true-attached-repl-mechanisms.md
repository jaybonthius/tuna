# Gerbil/Gambit v19: true attached REPL mechanisms

## Concise answer

**Yes.** The checked Gambit runtime has a genuine same-process network REPL, exposed through the documented runtime option:

```sh
daemon '-:debug=$127.0.0.1:44555'
```

The daemon listens for inbound TCP connections. Each connection creates a handler thread **inside the existing process**, installs the socket as that thread’s REPL channel, and runs Gambit’s normal evaluator. A spike defined `attached-proof` on one connection, exited only the handler with `,qt`, reconnected, and evaluated `(+ attached-proof 1)` as `42`. This is an attached evaluator, not typed remote procedure call (RPC).

However:

- Ordinary EOF/disconnect and `,q` can terminate the whole daemon.
- `,qt` is the safe disconnect command for the inbound `$` service thread.
- The server has no authentication or transport security.
- Plain `Ctrl-C` over the socket is not translated into a remote interrupt.
- Gerbil’s documented `:std/net/repl` is **not active in the checked v19 tree**; its implementation and test were moved under `src/v0.19-WIP/v0.19-TODO-std/`, and a nearby installed v19 build reports `cannot find library module`.
- `replx` is public and available in binaries, but it does not itself establish or select a network channel.
- Parameterizing `current-input-port` and `current-output-port` alone does not redirect the native REPL. Native REPL I/O is selected through a per-thread REPL channel.

Checked source: Gerbil `4531c21b90fa6ee04f374af905ae3ddb9d89d590` (`v0.19-dev-32-g4531c21b`, worktree dirty only in generated Gambit C files unrelated to the inspected Scheme sources). Runtime spikes used `/opt/gerbil` v0.19-dev-31 on Gambit v4.9.7-6, one Gerbil commit behind the checked tree.

## Supported versus internal mechanisms

| Mechanism | Status | Direction | True attached evaluator? | Important constraint |
|---|---|---:|---:|---|
| `-:debug=$[INTF][:PORT]` | **Documented/supported Gambit runtime option** | Client → daemon | **Yes** | EOF and `,q` can kill daemon; no auth |
| `-:debug=@[HOST][:PORT]` | **Documented/supported Gambit runtime option** | Daemon → external listener | **Yes, once a REPL is triggered** | Not an inbound attach; retries then exits on connection failure |
| Gerbil `replx` | **Public runtime binding** | Uses current thread’s REPL channel | Yes, if a channel already exists | Not a listener or channel setter |
| `repl-input-port`, `repl-output-port`, `repl-error-port` | **Documented public Gambit accessors** | N/A | No, access only | They are not parameters |
| `current-input-port` parameterization | **Public** | N/A | Only for a custom read/eval loop | Does not choose the native REPL channel |
| `##make-repl-channel-ports`, `##thread-make-repl-channel-set!`, `##repl-debug-main` | **Internal `##` APIs** | Custom | Yes | Global hooks/internal ABI |
| `:std/net/repl` | **Documented, but unavailable in checked v19 staging** | Client → daemon | Design is yes | Source is parked in `v0.19-TODO`; import fails |
| Gambit web/contrib REPL servers | **Examples/contrib, internal hooks** | Client → daemon | Yes | Historical reference, not a stable Gerbil API |

## Exact mechanics

### 1. Supported inbound server: `-:debug=$...`

The Gambit manual states that `$` opens a listener, defaulting to loopback port 44555:

- `gerbil/src/gambit/doc/gambit.txi:2287-2293`
- Runtime options apply to compiled executables as well as `gsi`/`gsc`: `gerbil/src/gambit/doc/gambit.txi:2066-2072`

The runtime parser stores `$` as `repl_server_addr`:

- `gerbil/src/gambit/lib/main.c:981-1024`
- Address parsing accepts host characters and an optional numeric port: `gerbil/src/gambit/lib/main.c:173-215`
- Settings enter the runtime setup structure at `gerbil/src/gambit/lib/main.c:1316-1339`

During runtime startup, Gambit registers the REPL TCP service:

- `gerbil/src/gambit/lib/_repl.scm:5411-5434`
- Startup invokes it before normal application activity continues: `gerbil/src/gambit/lib/_repl.scm:5438-5445`

For every accepted connection, `tcp-service-register!` creates a handler thread whose current input and output are the TCP client port:

- Public behavior: `gerbil/src/gambit/doc/gambit.txi:16290-16305`
- Runtime implementation: `gerbil/src/gambit/lib/_thread.scm:5178-5195`

The REPL service then:

1. Makes a REPL channel from the handler’s socket ports.
2. Stores it directly in that thread.
3. Calls `##repl-debug-main`.

Evidence: `gerbil/src/gambit/lib/_repl.scm:5423-5432`.

This is why evaluation happens in the daemon process. Native expression handling calls `##eval-within`:

- Dispatch from REPL: `gerbil/src/gambit/lib/_repl.scm:3427-3447`
- Evaluation against the continuation/global interaction compile-time environment: `gerbil/src/gambit/lib/_repl.scm:3810-3835`

The manual confirms that top-level REPL definitions enter the global interaction environment:

- `gerbil/src/gambit/doc/gambit.txi:345-357`

### 2. Supported reverse channel: `-:debug=@...`

The manual explicitly says a thread starting a REPL connects outward to the configured host and port:

- `gerbil/src/gambit/doc/gambit.txi:2279-2285`

When a thread first needs a channel, Gambit checks `##repl-client-addr`. If set, it opens an outbound TCP client, retrying up to 25 times with exponential delay—approximately 100 seconds—and exits with the connection error if unsuccessful:

- `gerbil/src/gambit/lib/_repl.scm:2631-2675`

This is not an inbound attach server. An external terminal must already be listening, and some event must start a REPL: explicit `replx`, an appropriately configured error, or a user interrupt. The documented default ports also differ: `$` defaults to 44555, while `@` defaults to 44556.

An executed spike confirmed the external Python listener accepted an outbound connection from the Gerbil process and received `42` from `(+ 20 22)`.

### 3. `replx`

Gerbil describes `replx` as an introspection REPL available to all binaries. It wraps `##repl` with an exception handler that starts another nested REPL when introspection itself fails:

- Active source: `gerbil/src/gerbil/runtime/repl.ss:10-26`
- Bootstrap-equivalent implementation: `gerbil/src/bootstrap/gerbil/runtime/repl~0.scm:4-44`
- Bootstrap loader: `gerbil/src/bootstrap/gerbil/runtime/repl.scm:1-4`
- Public runtime binding: `gerbil/doc/reference/gerbil/prelude/runtime-bindings.md:1784-1788`

It is **not** a network server. `##repl` acquires the current thread’s REPL channel, which is lazily created by the thread-channel hook:

- `gerbil/src/gambit/lib/_repl.scm:2631-2641`
- Channel ownership is acquired when the nested REPL starts: `gerbil/src/gambit/lib/_repl.scm:3193-3207`

Thus `replx` works with `$`, `@`, console/stdio, or a custom internal channel, but does not create any of them itself.

### 4. Thread REPL channels and port parameterization

Every Gambit thread has a separate `repl-channel` slot:

- `gerbil/src/gambit/lib/_thread#.scm:1203-1215`

The public `repl-input-port`/output/error accessors return ports from that thread’s channel:

- Implementation: `gerbil/src/gambit/lib/_repl.scm:2705-2727`
- Public binding/documentation: `gerbil/doc/reference/gerbil/prelude/runtime-bindings.md:987-993` and `gerbil/src/gambit/doc/gambit.txi:5499-5503`

A native port-backed channel is constructed internally by `##make-repl-channel-ports`:

- `gerbil/src/gambit/lib/_repl.scm:2896-2921`

Consequently:

- Parameterizing `current-input-port` and `current-output-port` does **not** redirect `replx`.
- `##repl-debug-main` does the reverse: after a REPL channel is selected, it assigns the channel’s ports as current ports: `gerbil/src/gambit/lib/_repl.scm:3150-3156`.
- A custom native REPL must install a channel via internal hooks/fields.
- A fully public alternative is a custom socket handler that performs `read` → `eval` → print using its current ports. That remains a true attached evaluator but lacks native debugger/nested-REPL behavior unless reimplemented.

The historical web REPL demonstrates the internal approach: pump Telnet data through string pipes, override the thread channel factory, create `##make-repl-channel-ports`, then invoke `##repl-debug-main`:

- `gerbil/src/gambit/examples/web-repl/web-repl.scm:7-71`
- `gerbil/src/gambit/examples/web-repl/web-repl.scm:73-99`
- `gerbil/src/gambit/examples/web-repl/web-repl.scm:101-123`

## Connect, disconnect, EOF, commands, and interrupts

### Built-in `$` and `@` channels

| Event | Behavior |
|---|---|
| Connect to `$` | New daemon-side handler thread, native banner/prompt, global interaction environment |
| Trigger REPL with `@` | Daemon opens outbound TCP connection, then uses it as that thread’s channel |
| Top-level clean EOF/half-close | Prints `*** EOF again to exit`, then invokes `,q`; daemon exits |
| Abrupt full disconnect | Output to the closed channel may fail first and terminate with an error; observed exit status 70 |
| Nested EOF | Performs `,d`, returning one nested REPL level |
| `,q` | Calls `exit`; terminates the process |
| `,qt` | Terminates the current thread; safe for a `$` connection handler, but fatal if it is the primordial thread |
| Plain network `Ctrl-C` | No protocol translation; not a reliable remote interrupt |
| OS user interrupt | Controlled by `debug=R/D/Q`; may start a nested REPL, defer, or terminate |

Exact source:

- EOF handling: `gerbil/src/gambit/lib/_repl.scm:3289-3296`
- “EOF again” and second peek: `gerbil/src/gambit/lib/_repl.scm:3059-3067`
- `,q` exits and `,qt` terminates the current thread: `gerbil/src/gambit/lib/_repl.scm:3489-3501`
- Manual command semantics: `gerbil/src/gambit/doc/gambit.txi:2506-2511` and `2565-2573`
- Interrupt runtime options: `gerbil/src/gambit/doc/gambit.txi:2205-2226`
- Runtime handlers: `gerbil/src/gambit/lib/_repl.scm:3839-3888`

### Parked `:std/net/repl`

The design specifically repairs native EOF behavior:

- Hard network EOF sets state and closes the pipe: `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:99-106`
- Telnet `Ctrl-D` creates soft EOF: lines `108-118`
- Telnet Interrupt Process (`IAC F4`) asynchronously interrupts the REPL thread: lines `127-135`
- Its global command hook returns from the `replx` invocation instead of exiting the process on hard EOF: lines `159-185`

But `,q` still falls through to Gambit’s default command handler and kills the daemon. `,qt` terminates only its dedicated client thread.

## Gerbil expander and compiled-module constraints

A compiled binary’s attached REPL initially uses primitive Gambit evaluation unless the Gerbil expander is linked and loaded. The parked network-REPL documentation says this explicitly:

- `gerbil/doc/reference/std/net/repl.md:48-58`

Gerbil’s compiled-eval guide adds two constraints:

1. `eval` operates in the top-level namespace, not an implicit module namespace.
2. Module bindings must be referenced by qualified names or exposed through `extern`.
3. `extern`, imports, and Gerbil syntax require importing `:gerbil/expander` and calling `gerbil-load-expander!`.

Evidence: `gerbil/doc/guide/eval.md:19-45` and `62-92`.

Runtime initialization installs the Gerbil compiler/expander hooks when requested:

- `gerbil/src/gerbil/runtime/init.ss:14-42`
- `gerbil/src/gerbil/runtime/init.ss:248-258`
- Bootstrap equivalent: `gerbil/src/bootstrap/gerbil/runtime/init~0.scm:462-471`

Therefore same-process evaluation is certain, but redefining a top-level interaction binding is not automatically equivalent to hot-patching every optimized/direct compiled call site.

## Status of `:std/net/repl` in checked v19

**Severity: blocker for using the documented Gerbil module as-is.**

The documentation still advertises:

- `start-repl-server!`, `stop-repl-server!`: `gerbil/doc/reference/std/net/repl.md:1-26`
- Thread-group tainting: lines `28-46`

But there is no `gerbil/src/std/net/repl.ss`. Git history shows it was renamed into the v0.19 TODO area by v19 staging. The parked source is:

- `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:1-13`
- Server and client lifecycle: lines `26-97`
- Channel construction/hooks: lines `146-208`
- Taint/untaint: lines `210-233`

Its only test checks a single `(+ 1 2)` exchange and does not cover EOF, disconnect, `,q`, `,qt`, interrupts, authentication, or persistence:

- `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl-test.ss:18-25`

The installed v0.19-dev-31 build returned `cannot find library module` for `(import :std/net/repl)`.

## Materially different implementation options

1. **Documented `$` runtime server** — smallest supported solution; configure at process startup and require `,qt` for disconnect.
2. **Documented reverse `@` channel** — useful behind inbound firewalls; needs an external listener and a deliberate REPL trigger.
3. **Public custom TCP `read`/`eval` loop** — avoids internal `##` hooks and can define safe EOF/lifecycle semantics, but is not the native Gambit debugger.
4. **Internal native channel injection** — use `##make-repl-channel-ports` and `##thread-make-repl-channel-set!`, modeled on the parked Gerbil module/web example. This preserves the full debugger but depends on internals.
5. **Restore/port `:std/net/repl`** — closest existing Gerbil design for safe disconnect and Telnet interrupts, but it is not currently active or supported in this v19 checkout.

## Review findings and residual risks

- **blocker:** `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:1-233` — documented `:std/net/repl` is not importable from active v19.
- **high:** `gerbil/src/gambit/lib/_repl.scm:3289-3296,3489-3494` — EOF or `,q` can terminate the daemon.
- **high:** `gerbil/src/gambit/lib/_repl.scm:5416-5434` — the supported `$` listener exposes unauthenticated arbitrary evaluation; restrict it to loopback or a protected transport.
- **medium:** `gerbil/src/gambit/lib/_repl.scm:5423-5432` — built-in network handling has no Telnet interrupt pump; remote `Ctrl-C` is unsupported.
- **medium:** `gerbil/doc/guide/eval.md:19-92` — primitive top-level evaluation does not automatically resolve Gerbil module bindings or provide Gerbil syntax.
- **medium:** `gerbil/src/gambit/lib/_repl.scm:3143-3148` — entering `##repl-debug-main` changes global error/user-interrupt debug settings to start REPLs.
- **low:** runtime-option address parsing at `gerbil/src/gambit/lib/main.c:173-215` is limited and does not support general IPv6 literal syntax.

Confidence: **high** for source mechanics and connection direction; **high** for `$` persistence/exit behavior due executed spikes; **medium-high** for an arbitrary freshly compiled Gerbil daemon until the same spike is run against a binary built from exact checked HEAD.

## Executable spikes

### Compiled daemon, supported inbound `$`

```sh
cat >/tmp/attached-daemon.ss <<'EOF'
(export main)
(def (main . args)
  (thread-sleep! +inf.0))
EOF

cd /tmp
gxc -exe attached-daemon.ss
./attached-daemon '-:debug=$127.0.0.1:44555'
```

From another terminal:

```sh
nc 127.0.0.1 44555
```

At the prompt:

```scheme
(define attached-proof 41)
,qt
```

Reconnect:

```sh
nc 127.0.0.1 44555
```

Then:

```scheme
(+ attached-proof 1)
;; => 42
,qt
```

Do **not** use `,q` or EOF unless daemon termination is intended.

### Reverse `@`

Have a listener ready:

```sh
nc -l 44556
```

Then start a process that deliberately invokes `replx`:

```sh
gxi '-:debug=@127.0.0.1:44556' -e '(replx)'
```

### Focused validation

```sh
/opt/gerbil/bin/gxi -e \
  '(with-catch (lambda (e) (displayln (error-message e)))
     (lambda () (eval (quote (import :std/net/repl))) (displayln "imported"))'
```

Expected in current staging: `cannot find library module`.

After any future reactivation of the module:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
./build.sh env gxtest src/std/net/repl-test.ss
```

Full Gerbil validation, derived from `gerbil/Makefile:46-47`:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
make check
```

The focused and full test commands were not run because this assignment was read-only and the active module is absent.