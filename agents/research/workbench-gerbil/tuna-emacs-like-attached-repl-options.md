# Attached Emacs-like Tuna REPL architecture research

## Conclusion

Use a **thin, daemon-side attached evaluation service over a local Unix-domain socket** as the first implementation.

The editor should send Gerbil source text and source metadata; the existing daemon process should use Gerbil’s `read-syntax` and `eval-syntax`, then built-in printing and exception display. This is not reuse of the complete interactive REPL, but it does reuse the reader, expander, evaluator, and printer rather than recreating them.

Keep a full `replx` terminal as a possible later, separate operator/debug facility. Do not port the quarantined `:std/net/repl` wholesale into Tuna now.

This design satisfies the non-negotiables:

- Evaluation occurs in the daemon process.
- `(defun ...)` executes daemon-side and updates Tuna’s live function cells.
- Gerbil supplies reading, expansion, evaluation, and printing.
- State changes still enter through `command-runtime-submit-transition!` and the serialized owner.
- Arbitrary local administrative evaluation is acknowledged as trusted, unsandboxed access.
- Networking remains in a daemon adapter, not `lib/bindings.ss`, `lib/runtime.ss`, or `lib/prelude.ss`.

## Critical findings

1. **Blocker — current `:std/net/repl` cannot be imported.**  
   The v0.18.2 implementation is byte-for-byte present only at the quarantined path `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss`; `gerbil/src/std/net/repl.ss` is absent, and an import fails. Its documentation is therefore stale for this checkout.  
   Evidence: `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:1-19`; `gerbil/doc/reference/std/net/repl.md:1-19,48-58`.

2. **High — never run attached evaluation on Tuna’s command-owner thread.**  
   State installation explicitly requires that owner at `tuna/tuna/lib/runtime.ss:114-125`; the owner executes requests sequentially at `:211-219`. An evaluator running there that submits a transition and waits at `:281-292` deadlocks waiting for itself.

3. **High — the current daemon does not expose its runtime instance to administration.**  
   `main` creates a lexical, stateless `make-command-runtime` and only starts/waits/stops it (`tuna/tuna/main.ss:11-31`). An admin adapter must receive the authoritative application runtime as a capability. Creating another state runtime from the REPL would mutate the wrong root.

4. **High — an attached evaluator is unrestricted process administration, not a sandbox.**  
   Gerbil code can access files, processes, modules, and internal APIs and can terminate or corrupt the daemon. A loopback address or Unix socket limits reachability but does not reduce authority after connection.

5. **High — the full Gambit REPL has daemon-hostile EOF and global-hook concerns.**  
   The quarantined implementation overrides EOF handling specifically because built-in top-level EOF can exit the process (`gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:159-185`). It also installs process-global REPL hooks at `:185-195`.

6. **Medium — shared Gerbil expansion context should be serialized.**  
   Expander contexts contain mutable binding tables (`gerbil/src/gerbil/expander/core.ss:13-64`), and imports bind into the current context (`gerbil/src/gerbil/expander/module.ss:840-872`). There is no evidence that concurrent mutation by independent REPL threads is supported.

7. **Medium — state/action output is not automatically attached-session output.**  
   Dynamic output redirection applies to the evaluator thread. Actions and transitions execute on `tuna-command-runtime` (`tuna/tuna/lib/runtime.ss:155-178,225-238`), while Tuna logging uses an asynchronous standard-error sink (`tuna/tuna/lib/log.ss:21-30`). Their output should remain daemon output unless an explicit structured context/output capability is supplied.

## Existing semantics that make attachment viable

### Tuna live definitions

`defun` expands to a normal Gerbil top-level definition that calls `define-function!` and retains a stable function cell:

- `tuna/tuna/lib/prelude.ss:61-111`
- `tuna/tuna/lib/bindings.ss:345-367`

Replacement atomically resets the cell, and existing wrappers resolve through it:

- `tuna/tuna/lib/bindings.ss:347-364,417-422`

An empirical source-mode check evaluated two daemon-side `defun` forms and observed `v1`, then `v2`, through `function-ref`. A spawned evaluation thread also defined a function visible from its parent thread. This confirms the required process-level effect; no client evaluator is needed.

Definition changes are individually coherent but not transactional across multiple forms. If form three fails, changes made by forms one and two remain. That matches current configuration’s sequential partial-application behavior at `tuna/tuna/lib/config.ss:29-41`.

### Authoritative application transitions

Only the command owner can install a new root:

- `tuna/tuna/lib/runtime.ss:114-135`

The owner computes and installs transition results:

- `tuna/tuna/lib/runtime.ss:137-178,211-219`

Direct invocation computes only a candidate and cannot commit:

- `tuna/tuna/README.md:128-155`
- `tuna/tuna/test/state-runtime-test.ss:75-115`

Queued transitions resolve the current live definition on dequeue:

- `tuna/tuna/test/state-runtime-test.ss:117-141`

Therefore attached evaluation may redefine a `deftransition`, but committing it must use the authoritative runtime’s `command-runtime-submit-transition!`.

### Existing Gerbil evaluation machinery

Gerbil already exposes:

- `gerbil-load-expander!`
- `read-syntax`
- `eval-syntax`
- `replx`

See `gerbil/src/gerbil/core/runtime.ss:1850-1876`.

`read-syntax` uses Gerbil’s current readtable and constructs located abstract syntax trees:

- `gerbil/src/gerbil/runtime/syntax.ss:255-280`

`eval-syntax` performs top-level expansion, compilation, and evaluation:

- `gerbil/src/gerbil/expander/core.ss:168-190`

Tuna’s config loader already demonstrates the correct pattern: load the expander, establish a Gerbil prelude, read syntax, and call `eval-syntax` one form at a time:

- `tuna/tuna/lib/config.ss:29-41`

The attached service should reuse or extract this seam rather than invent a second evaluator.

## What qualifies as REPL reuse?

| Approach | Honest description |
|---|---|
| Call `replx` with a Gambit REPL channel | Reuses the complete REPL: reader loop, prompts, evaluation, multiple-value printing, result history, debugger commands, nested exception REPL, and continuation inspection. |
| Port `std/net/repl` | Reuses the complete REPL plus an existing remote-terminal adapter, but in this checkout it is effectively maintaining a private compatibility fork. |
| `read-syntax` + `eval-syntax` + built-in pretty printing | Reuses Gerbil’s language implementation, but implements a remote evaluation/session protocol. It should not be described as reusing the complete REPL. It still complies with “do not build a reader/evaluator/printer from scratch.” |

Gambit’s full REPL supplies prompt reading and pretty-prints non-void multiple values at `gerbil/src/gambit/lib/_repl.scm:2991-3020`. It also owns result history at `:2814-2894`, evaluates within the captured continuation at `:3427-3447,3810-3835`, and exposes nested debugger behavior at `:3193-3240`.

## Architecture options

### Option A — Minimal embedded `replx` with a remote channel adapter

**Shape**

- A daemon adapter accepts a local connection.
- It creates a dedicated REPL thread and a Gambit REPL channel backed by the accepted character ports.
- That thread runs `replx`.
- Use one active client initially and a retained Gerbil top-level expansion context.

**Strengths**

- Most faithful Gerbil experience.
- Existing reader, printer, result history, interrupts, continuation debugger, and nested exception REPL.
- Daemon-side `defun` naturally updates Tuna cells.
- Minimal editor intelligence if Emacs behaves as a terminal.

**Weaknesses**

- Creating and assigning a REPL channel requires Gambit internals such as `##make-repl-channel-ports`; see `gerbil/src/gambit/lib/_repl.scm:2902-2924`.
- Channel assignment relies on process-global thread/channel hooks in the existing remote implementation.
- Raw prompt streams are difficult for Emacs to correlate with requests, stdout, errors, and completion.
- Exceptions enter a nested interactive debugger instead of producing a finite structured response. `replx` deliberately catches and starts `##repl-within`: `gerbil/src/gerbil/runtime/repl.ss:10-26`.
- C-d, nested debugger exits, and shutdown require the special handling found in the quarantined implementation.
- Current `std/io` Unix sockets expose reader/writer interfaces, whereas Gambit’s channel constructor expects character ports. A bridging decision is required.

**Session semantics**

A REPL thread retains its parameterized expansion context during the connection. Imports and macro definitions persist while that context remains retained. To preserve them across reconnects, the daemon must retain and reuse the context separately from the socket and channel. REPL result history belongs to the channel and normally resets on reconnect.

**Use when**

An operator terminal and full debugger are more important than Emacs request/response behavior.

### Option B — Reuse or port quarantined `std/net/repl`

**Current behavior**

The old implementation provides:

- Loopback TCP listener and optional password:  
  `gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss:26-34,79-97`
- Per-client thread group and cleanup: `:49-77`
- Telnet C-d and C-c handling: `:99-144`
- Gambit REPL-channel construction: `:146-157`
- Safe remote EOF handling: `:159-185`
- Thread-group channel propagation and debugger “taint”: `:187-230`
- Explicit server stop and group kill: `:36-47`

**Strengths**

- Most complete known remote full-REPL implementation.
- Already addresses hard EOF, interrupt, debugger-port, and thread-group details.
- Its v0.18.2 content exactly matches the quarantined copy, giving a stable historical reference.

**Weaknesses**

- It is not buildable/importable as a current standard module.
- Imports and APIs such as `:std/logger`, `:std/misc/threads`, and the old port-oriented network interface belong to the prior standard library layout.
- It installs global Gambit hooks, creating process-wide compatibility risk.
- Password comparison is plaintext over TCP and repeats indefinitely (`:79-86`); it is reachability protection, not secure authentication.
- Porting the whole module commits Tuna to maintaining implementation-sensitive Gambit debugging integration.
- It remains a raw terminal protocol, not an Emacs-oriented structured evaluation protocol.

**Assessment**

Useful as reference code and potentially as a later upstream Gerbil port, but not the smallest Tuna solution.

### Option C — Thin source transport to Gerbil’s daemon-side evaluator

**Shape**

Three layers:

1. **Tuna host-neutral core** — unchanged bindings/runtime/event modules.
2. **Daemon admin-eval adapter** — owns a retained expansion context, a dedicated serialized evaluation lane, and the authoritative runtime capability.
3. **Local transport adapter** — Unix-domain socket framing and lifecycle; the editor client only sends source and receives presentation frames.

Current Gerbil has public Unix socket constructors:

- `unix-connect` and `unix-listen`: `gerbil/src/std/io/socket/api.ss:22-72`
- `UnixAddress`: `gerbil/src/std/net/address/types.ss:52-58,83-108`

**Minimal request**

- request ID
- operation `eval`
- UTF-8 source text
- source identity/path and initial line/column
- optional logical session ID

**Minimal response**

- zero or more standard-output/standard-error presentation frames
- printed values, preserving multiple-value order
- structured success or exception completion
- matching request ID

Use `read-syntax` repeatedly until end-of-input and `eval-syntax` once per form. Use `call-with-values`, built-in `pretty-print`/`write`, and `display-exception`; do not serialize arbitrary result objects as protocol data.

**Strengths**

- Best fit for Emacs region/form evaluation.
- No client-side evaluation.
- Public current Gerbil evaluator APIs.
- Easy request correlation, source metadata, and explicit completion.
- Clean exception recovery: a failed request need not trap the client in a nested debugger.
- Network concerns remain outside host-neutral Tuna.
- Simpler listener and shutdown lifecycle.
- A single eval lane avoids unproven concurrent expander mutation.

**Weaknesses**

- It is not the full Gambit REPL.
- No continuation-navigation debugger without a later explicit debug operation.
- Interrupting arbitrary compiled code safely remains unresolved.
- Capturing output from child threads that outlive a request is inherently ambiguous.
- Gerbil’s public `read-syntax` accepts a port, but assigning an unsaved editor buffer’s synthetic path/line/column appears to require lower-level Gambit support. Gambit has an internal source-string reader accepting name/line/column at `gerbil/src/gambit/lib/_eval.scm:1263-1291`; stabilizing this seam is part of the spike.

**Assessment**

Recommended.

## Process, session, and environment semantics

### Recommended initial contract

- One evaluator process: the Tuna daemon.
- One daemon-global trusted admin session.
- One active client connection initially.
- One retained Gerbil expansion context, reused across reconnects.
- One serialized evaluator lane separate from Tuna’s command owner.
- Multiple forms are applied sequentially; no rollback on later failure.
- Disconnect ends transport ownership, not the evaluation environment.
- Daemon restart clears interactive definitions/imports unless persisted in config/source.

### Definitions

- Existing Tuna `defun`, `defaction`, and `deftransition` names update process-global live cells and are immediately visible to compiled callers that use Tuna’s wrappers.
- New live names remain discoverable through `function-ref`/transition lookup.
- Ordinary Gerbil top-level definitions additionally depend on retaining the expansion context so later source can resolve their syntax binding.
- Captured procedures remain old snapshots; `function-ref` returns the current body. See `tuna/tuna/README.md:272-290`.

### Imports and macros

Imports bind into the current expansion context (`gerbil/src/gerbil/expander/module.ss:840-872`). Therefore:

- retained global context: imports survive forms and reconnects;
- fresh context per connection: imports are connection-local and disappear on disconnect;
- logical session contexts: imports persist only when the same session context is resumed.

A reset cannot undo already executed module initialization or live cell mutation. Tuna explicitly has no unload semantics (`tuna/tuna/README.md:328-334`).

### Value contexts

Tuna’s ordinary live values are process-global. A `ValueContext` is dynamically selected and may localize values (`tuna/tuna/lib/bindings.ss:529-599`). The admin session must not accidentally inherit a user/editor value context. Initially it should run with no application-local value context unless a future explicit “evaluate in host context” operation is designed.

## Command-runtime and deadlock boundaries

Required dependency direction:

```text
admin evaluator -> submit command/transition -> command owner
command owner   -X-> synchronously call evaluator
```

Rules:

1. The eval thread may submit to the authoritative runtime and wait for completion.
2. The command owner must never synchronously request evaluation or wait for the eval lane.
3. Do not hold the runtime mutex or an eval-session mutex while executing user code.
4. Do not expose `install-state-root!`; expose only an adapter that submits to the captured runtime.
5. Ordinary `invoke-state-transition` from a REPL is diagnostic only and must be documented as non-committing.
6. Transport backpressure must not block the command owner. Action output should remain daemon output or use an explicit bounded structured output context.
7. An eval that waits for a command is safe only if that command cannot call back synchronously into eval.

Tuna already makes command admission nonblocking and bounded (`tuna/tuna/lib/runtime.ss:247-292`) and drains accepted commands during stop (`:332-354`).

## Output and debugger behavior

| Behavior | Full `replx` options | Thin evaluator |
|---|---|---|
| Form parsing | Gambit/Gerbil REPL | Gerbil `read-syntax` |
| Values | Built-in pretty-print, void suppressed, history retained | Built-in printer into explicit response frames |
| Multiple values | Built in | Must collect with `call-with-values` |
| Eval-thread stdout/stderr | Routed to REPL channel | Captured/streamed per request |
| Owner-thread action output | Not automatically session output | Not automatically session output |
| Exceptions | Nested interactive debugger with continuation commands | Structured exception text; no continuation debugger initially |
| C-c | Existing remote code maps telnet interrupt to REPL thread | Requires explicit cancel protocol and carefully scoped thread interrupt |
| Emacs correlation | Prompt/stream parsing | Request IDs and completion frames |
| Long-lived child output | May retain closed REPL ports | Needs explicit policy; do not promise capture after request completion |

A bounded production implementation should stream or cap output. Capturing unlimited output in strings is acceptable only for the spike.

## Security

Initial local-trusted controls should still include:

- Unix socket in a user-private runtime directory, with owner-only permissions.
- Refuse to overwrite an unexpected existing socket path.
- One active client initially.
- Frame and source-size limits.
- Explicit opt-in startup flag or configuration.
- No TCP listener by default.
- No claim of sandboxing or privilege separation.
- Audit log for connect/disconnect and evaluation origin, but do not log source containing secrets by default.
- Close the socket before shutting down the runtime.
- Treat client possession of the socket as full daemon authority.

If TCP is ever added, the old plaintext password loop is insufficient.

## Shutdown

Recommended order:

1. Mark admin service stopping and close the listener.
2. Reject new requests.
3. Let the current request finish for a bounded grace period.
4. Close client transport and stop/join the evaluator lane.
5. Only then stop the command runtime, allowing any transition already submitted by evaluation to drain.
6. Join the command owner.
7. Flush/stop logging last.

Arbitrary Gerbil evaluation may ignore cooperative shutdown. Forced thread interruption can leave locks or external effects inconsistent, so the spike should expose this limitation rather than pretend cancellation is safe. Tuna currently has no operating-system signal or cancellation integration (`tuna/tuna/README.md:164-171`).

## Decision matrix

Ratings: 5 = strongest.

| Criterion | Minimal `replx` channel | Port `std/net/repl` | Thin evaluator |
|---|---:|---:|---:|
| Same-process evaluation | 5 | 5 | 5 |
| Daemon-side live `defun` | 5 | 5 | 5 |
| Reuses complete REPL | 5 | 5 | 1 |
| Reuses existing reader/evaluator/printer | 5 | 5 | 5 |
| Current supported Gerbil APIs | 2 | 1 | 4 |
| Emacs request/response fit | 2 | 2 | 5 |
| Full debugger | 5 | 5 | 1 |
| Explicit session semantics | 3 | 2 | 5 |
| Output correlation | 2 | 2 | 5 |
| Interrupt behavior | 4 | 5 | 2 |
| Clean daemon shutdown | 2 | 3 | 4 |
| Minimal compatibility surface | 2 | 1 | 4 |
| Keeps Tuna core host-neutral | 4 | 3 | 5 |
| Smallest maintainable first step | 3 | 1 | 5 |

**Decision:** thin evaluator first. Consider a separate, opt-in full `replx` operator endpoint only after the attached evaluation path and lifecycle are established.

## Smallest honest spike

Build one read-only-capable prototype integration around a real Tuna daemon process:

1. Add no APIs to `lib/bindings.ss`, `lib/runtime.ss`, or `lib/prelude.ss`.
2. Start one Unix-domain listener in a daemon adapter.
3. Capture the current expansion context after config loading and call `gerbil-load-expander!` even under `--no-config`.
4. Start one dedicated evaluator lane.
5. Accept one client and one length-delimited `eval` request at a time.
6. Read all forms daemon-side with `read-syntax`; evaluate sequentially with `eval-syntax`.
7. Return bounded stdout, stderr, printed values, exception text, and completion ID.
8. Give the adapter the authoritative runtime as a constructor capability and expose one helper that submits transitions and waits.
9. On disconnect, retain the expansion context; on daemon shutdown, stop the evaluator before the command runtime.

### Spike acceptance checks

- Connection A imports Tuna and defines `(defun attached-proof () 'v1)`.
- Connection B reconnects and evaluates the function successfully.
- B redefines it to `v2`; compiled/live lookup observes `v2`.
- An import made on A remains usable after reconnect.
- Output and two returned values are separated and correlated.
- A failed form reports an exception; the next request succeeds.
- A daemon-side `deftransition` replacement is used by a queued owner submission.
- Direct transition invocation does not change revision; submitted transition does.
- Closing the client does not exit the daemon.
- Idle and connected shutdown both terminate cleanly.
- Syntax errors identify the supplied buffer path and line; if that requires an internal source-location API, record it as the only Gambit-internal dependency.
- An oversized frame is rejected before reading/evaluating it.

Do not add cancellation or nested debugger support to this spike.

## Validation commands

### Focused live-definition evidence

Already passed:

```sh
env GERBIL_LOADPATH="$PWD/tuna/tuna" gxi -e \
'(import :gerbil/expander :tuna/lib/bindings)
 (gerbil-load-expander!)
 (eval-syntax (quote (import :tuna/lib/prelude)))
 (eval-syntax (quote (defun tuna-attached-spike () (quote v1))))
 (displayln (function-bound? (quote tuna-attached-spike))
            " "
            ((function-ref (quote tuna-attached-spike))))
 (eval-syntax (quote (defun tuna-attached-spike () (quote v2))))
 (displayln ((function-ref (quote tuna-attached-spike))))'
```

Observed:

```text
#t v1
v2
```

Spawned-thread visibility also passed:

```sh
env GERBIL_LOADPATH="$PWD/tuna/tuna" gxi -e \
'(import :gerbil/expander :tuna/lib/bindings :gerbil/runtime/thread)
 (gerbil-load-expander!)
 (eval-syntax (quote (import :tuna/lib/prelude)))
 (thread-join!
  (spawn
   (lambda ()
     (eval-syntax
      (quote (defun attached-thread-definition () (quote daemon)))))))
 (displayln (eval-syntax (quote (attached-thread-definition))))
 (displayln ((function-ref (quote attached-thread-definition))))'
```

Observed:

```text
daemon
daemon
```

### Quarantined module evidence

Already passed:

```sh
git -C gerbil show v0.18.2:src/std/net/repl.ss | sha256sum
sha256sum gerbil/src/v0.19-WIP/v0.19-TODO-std/net/repl.ss
test ! -e gerbil/src/std/net/repl.ss
```

Both hashes were:

```text
4c51e24f074450b2bfb15a283bd6ae6e9aa3afeceb4351436b949b293df34964
```

A direct `:std/net/repl` import failed with “cannot find library module”.

### Full Tuna regression matrix after implementation

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
test/run-command-runtime-matrix.sh
```

This is the repository-authoritative source, normal-compiled, and `-O` matrix and verifies worktree status remains unchanged: `tuna/tuna/test/run-command-runtime-matrix.sh:1-101`.

Also build the daemon after adding the integration:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil build
```

## Residual risks and confidence

- **High:** safe interruption of arbitrary evaluation remains unsolved.
- **High:** unrestricted evaluation can terminate or corrupt the process.
- **Medium:** synthetic source-name/line support may require one Gambit-internal API.
- **Medium:** output from command-owner or long-lived spawned threads cannot be automatically attributed to the initiating eval request.
- **Medium:** there is no documented guarantee that mutable expansion contexts are concurrency-safe; the recommendation relies on serialization.
- **Medium:** the checked-out Gerbil tree has unrelated modified generated C files, and the installed `gerbil` reports one nearby but not identical development revision. Rebuild and rerun all spikes against the exact production toolchain.
- **Low:** Tuna itself was clean at commit `5a481b1216236c64701cf950c3a8dcf529aba183`; Gerbil checkout was `4531c21b90fa6ee04f374af905ae3ddb9d89d590`.

**Confidence:** high on Tuna live-definition and owner semantics; high that current `std/net/repl` is unavailable; medium-high on the thin-evaluator recommendation; medium on full-REPL integration details because they rely on internal Gambit channel hooks.