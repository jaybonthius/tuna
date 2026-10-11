# GNU Emacs command-loop and long-lived runtime architecture

## Conclusion

Emacs stays alive because startup enters an editor command loop that is documented and implemented as non-returning. That loop repeatedly waits for external activity, maps input to a named command, executes one Lisp command at a time, runs lifecycle callbacks, attempts redisplay, and catches ordinary command errors so the next command can proceed.

Its most transferable invariant is **not** keyboard handling or redisplay. It is a **serialized mutation lane with a recovery boundary**:

```text
wait/receive
  → normalize and map to a named operation
  → acquire host-derived arguments
  → execute one operation
  → publish lifecycle/effects
  → recover or shut down
```

Emacs implements serialization with a process-wide lock permitting only one active Emacs Lisp thread. This prevents simultaneous Lisp heap mutation, but it does **not** mean all mutation passes through the command loop: timers, process filters, sentinels, recursive edits, and other Lisp threads can mutate shared state at defined yield/wait points, sometimes reentrantly. Single active execution is therefore not transactionality or logical isolation.

**Recommendation for Tuna:** if Tuna is intended to become a long-lived application runtime rather than remain only an embeddable extension library, introduce a minimal host-neutral **serialized command processor/pump** before hooks, documentation, and provenance. It should process opaque envelopes through existing named actions and expose lifecycle/effect results, while leaving keyboard decoding, keymaps, rendering, buffers, and the host’s actual I/O wait mechanism outside the runtime.

This recommendation conflicts with the current roadmap’s blanket exclusion of event loops at `plans/emacsen-runtime/checklist.md:346-357`. The useful distinction is between:

- a host-specific input/render event loop, which should remain excluded; and
- a host-neutral serialized action processor, which establishes ordering, error, effect, and shutdown semantics required by a real long-lived runtime.

## Evidence baseline

- GNU Emacs source: local clone `/home/jay/Code/emacs`, annotated tag `emacs-30.2`.
- The tag object is `29f3f150af5c5b065c3a9f39969429e5bb3285da`; it dereferences to release commit `636f166cfc86aa90d63f592fd99f3fdd9ef95ebd`. Existing research calling `29f3…` the “tag commit” is bibliographically imprecise but does not invalidate its line citations.
- Primary manual: GNU Emacs Lisp Reference Manual 30.2.
- Existing repository research incorporated:
  - `research/emacs-runtime-extensibility-primitives.md`
  - `research/emacs-runtime-roadmap-audit.md`
  - `research/emacs-definition-redefinition-model.md`
  - `research/emacs-runtime-redefinition-semantics.md`
  - `plans/emacsen-runtime/checklist.md`

Authoritative source links below use the dereferenced release commit. Example:

- [GNU Emacs `src/keyboard.c`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/keyboard.c?id=636f166cfc86aa90d63f592fd99f3fdd9ef95ebd)

## 1. How Emacs remains alive

After initialization, `main` sets the initial minibuffer mode and enters `recursive-edit`; the source states that this never returns:

- `/home/jay/Code/emacs/src/emacs.c:2644-2647`
- [source](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/emacs.c?id=636f166cfc86aa90d63f592fd99f3fdd9ef95ebd#n2644)

`recursive-edit` enters `command_loop` with unwind protection:

- `src/keyboard.c:713-765,786-849`

At the outer level, `command_loop` is an infinite loop with catches for top-level exits and command execution:

- `src/keyboard.c:1113-1152`

The inner recovery wrapper repeatedly invokes `command_loop_1` under `internal_condition_case`:

- `src/keyboard.c:1155-1171`

Thus process longevity is explicit control flow, not merely “threads still exist.”

### Transferable invariant

A long-lived runtime needs one clearly owned top-level lifetime boundary. Returning from an ordinary demonstration `main` is not equivalent.

### Current Tuna gap

`tuna/main.ss:8-66` initializes logging, demonstrates bindings/actions/configuration, shuts logging down in `finally`, and returns. It has no wait/dispatch/recovery loop. `tuna/lib/log.ss:23-30` correctly stops and joins the asynchronous logger, but this is cleanup for a terminating example, not a runtime lifetime manager.

## 2. Input receipt, mapping, and command execution

The Emacs manual describes the command path directly:

1. read a key sequence;
2. map it through active keymaps;
3. create an undo boundary;
4. obtain interactive arguments;
5. execute the command.

Evidence:

- `doc/lispref/commands.texi:36-71`
- [Command Loop Overview](https://www.gnu.org/software/emacs/manual/html_node/elisp/Command-Overview.html)

The implementation follows that path:

- `command_loop_1` reads a complete key sequence: `src/keyboard.c:1426-1435`
- captures the command and applies command remapping: `1469-1500`
- runs the pre-command hook: `1511-1515`
- establishes undo/redisplay accounting and calls `command-execute`: `1522-1551`
- runs post-command processing: `1563-1692`

`command-execute` follows symbol indirection and autoloads, then either executes a keyboard macro or calls the command interactively:

- `lisp/simple.el:2753-2813`

`call-interactively` obtains arguments separately from the command body and finally invokes through `funcall-interactively`:

- `src/callint.c:253-430,743-790`
- [Interactive Call](https://www.gnu.org/software/emacs/manual/html_node/elisp/Interactive-Call.html)

### Core semantic invariant

Separate:

- external stimulus receipt;
- stimulus-to-action mapping;
- host-context argument acquisition;
- name-backed action invocation.

Tuna already has the last two pieces:

- `ActionDefinition` combines implementation, host descriptor, and argument acquirer: `tuna/lib/bindings.ss:31-40`
- `invoke-action-with-context` snapshots one action definition, derives arguments from an opaque context, and invokes that same generation: `tuna/lib/bindings.ss:236-258`
- `defaction` exposes the host-neutral form: `tuna/lib/prelude.ss:55-84`

A future command processor should map envelopes through `invoke-action-with-context`, not through editor keymaps or a direct extracted procedure.

### Editor-specific details to reject from the neutral layer

- keyboard and pointer event representation;
- active keymap precedence and command remapping;
- prefix arguments;
- minibuffer prompting;
- keyboard macros;
- selected buffer/window and point;
- undo boundaries and mark adjustment.

These are host policies, not command-loop invariants.

## 3. Serialization of state mutation

Emacs threads are operating-system threads, but only one executes Emacs Lisp at a time. `thread.c` defines a process-wide `global_lock`; acquiring it switches the current thread’s dynamic bindings and current buffer:

- `src/thread.c:48-68,80-162`
- thread yield releases and reacquires that lock: `src/thread.c:721-737`
- every newly created Lisp thread acquires it before invoking Lisp: `src/thread.c:757-858`
- initialization locks it for the main thread: `src/thread.c:1162-1174`

The manual consequently calls threading “mostly cooperative.” Switching occurs at explicit yield, keyboard/process waits, mutex operations, and thread joins:

- `doc/lispref/threads.texi:10-31`
- [Threads](https://www.gnu.org/software/emacs/manual/html_node/elisp/Threads.html)

### Important qualification

Emacs has a **single active Lisp executor**, not a strict “all editor mutation occurs only between top-level commands” rule.

Mutation can happen:

- from timer callbacks while the command loop or a command waits;
- from process filters and sentinels;
- from a secondary Lisp thread after the current thread yields;
- inside a recursive command loop;
- recursively when a filter or timer itself calls a waiting primitive.

A global lock removes simultaneous Lisp heap races, but it does not provide:

- rollback;
- atomicity across multiple mutations;
- non-reentrancy;
- isolation of command state from callbacks;
- deterministic ordering beyond defined scheduling points.

### Tuna adaptation

Tuna should not copy Emacs’s global interpreter lock. It should use a narrower rule:

> Mutable host/application state has one owning command lane. Other threads perform isolated I/O or computation and submit completion envelopes to that lane.

Tuna’s live registries should remain independently thread-safe:

- append-only cell publication and per-thread caches: `tuna/lib/bindings.ss:54-131`
- atomic cell/action definitions: `tuna/lib/bindings.ss:188-217`
- current documented limitation—single-cell atomicity, no multi-binding transaction: `tuna/README.md:208-214`

This separates globally useful live-definition concurrency from host-state ownership.

## 4. Observable effects: lifecycle hooks and redisplay

Emacs runs `pre-command-hook` before each command and `post-command-hook` afterward, including commands terminated by an error or quit:

- `doc/lispref/commands.texi:73-100`
- source normal path: `src/keyboard.c:1511-1515,1568-1587`
- source error re-entry path: `src/keyboard.c:1337-1359`

Hook execution is deliberately protected. A failing function is reported and removed from the hook rather than aborting the loop:

- `src/keyboard.c:1878-1985`

Redisplay is deferred. Emacs normally attempts it while waiting for input; input can preempt it, and explicit invalidation merely schedules later work:

- `doc/lispref/display.texi:63-66,82-130`
- [Forcing Redisplay](https://www.gnu.org/software/emacs/manual/html_node/elisp/Forcing-Redisplay.html)

### Core invariant

Every attempted command has a stable observable boundary:

```text
before → invoke → success/error → after → publish/flush
```

Publishing need not mean rendering. It can produce:

- state version or changed-resource identifiers;
- structured effects;
- notifications;
- diagnostics;
- deferred host refresh requests.

### Tuna adaptation

Prefer explicit typed command outcomes/effects over Emacs’s mixture of mutable dirty flags and implicit redisplay. Hooks can later observe stable phases of that processor.

Do not copy Emacs’s silent removal of a failing hook as the default. Explicit failure policies—continue, quarantine with an observable diagnostic, stop, or escalate—are easier to audit.

## 5. Timers, process I/O, and server requests

Waiting for command input calls the shared process-output wait machinery:

- `src/keyboard.c:4015-4099`

`wait_reading_process_output` integrates keyboard readiness, process I/O, timer deadlines, pending signals, and optional redisplay:

- `src/process.c:5250-5453`
- timer checks while waiting: `5423-5443`

Timers do not run at arbitrary instruction boundaries. They run only where Emacs can accept subprocess output—primarily while waiting or in primitives that can wait—so busy Lisp delays them:

- `doc/lispref/os.texi:2196-2227`
- [Timers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Timers.html)

Timer callbacks:

- run with quitting inhibited;
- are rescheduled before invocation where appropriate;
- catch ordinary callback errors;
- can nevertheless become reentrant if they call waiting primitives.

Evidence:

- `src/keyboard.c:4666-4870`
- `lisp/emacs-lisp/timer.el:283-347`
- timer mutation/reentrancy cautions: `doc/lispref/os.texi:2229-2240`

Asynchronous subprocess output normally arrives while Emacs waits and is passed to process filters:

- `doc/lispref/processes.texi:1760-1798,1974-2017`
- [Filter Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Filter-Functions.html)

Filters can run recursively if they invoke another waiting operation. Sentinels are similarly restricted to waiting points and catch their errors:

- `doc/lispref/processes.texi:2163-2209`
- [Sentinels](https://www.gnu.org/software/emacs/manual/html_node/elisp/Sentinels.html)

The Emacs server demonstrates that non-keyboard requests use this same runtime. Its process filter parses requests and invokes server operations; complex continuation work can be deferred through a zero-delay timer:

- `lisp/server.el:1020-1056,1425-1495`
- notably `server-execute` is documented as running from timers and process filters: `1476-1484`

### Tuna adaptation

- Timer and I/O producers should enqueue envelopes; they should not run arbitrary host-state callbacks on worker threads.
- Deadlines should determine wake-up time, but a due timer need not interrupt an executing command.
- Long actions should be split or offloaded, with completion delivered as another envelope.
- Queue ordering, cancellation, backpressure, and shutdown disposition must be explicit.
- Avoid Emacs-style nested waits from inside callbacks unless reentrancy is a deliberate supported contract.

## 6. Error recovery

At command level, unhandled errors are printed and control returns to the loop:

- `src/keyboard.c:964-1023`
- the recovery condition wrapper retries `command_loop_1`: `1113-1171`

In a normal interactive session, `command-error-function` reports the error and the process remains alive. Before display initialization or in noninteractive operation, the default can terminate Emacs:

- `src/keyboard.c:1026-1108`

After an errored command, re-entering `command_loop_1` runs `post-command-hook` before reading another command:

- `src/keyboard.c:1337-1345`

Timer, filter, sentinel, and hook errors have their own containment policies. An uncaught error in a secondary Lisp thread terminates that thread rather than the process:

- `doc/lispref/threads.texi:139-149`
- `src/thread.c:739-858`

### What recovery does not provide

Emacs does not roll back ordinary mutations made before an error. `unwind-protect` restores registered dynamic state/resources, not arbitrary editor state. Existing repository research establishes this at:

- `research/emacs-runtime-extensibility-primitives.md:569-597`
- `research/emacs-runtime-roadmap-audit.md:830-848`

### Tuna adaptation

Catch errors at the envelope/command boundary and produce a structured failed outcome. Run guaranteed cleanup and the after-phase exactly once, then continue unless the error is explicitly fatal.

Do not imply transactional commands unless Tuna adopts staging, immutable snapshots, or an undo protocol. Existing runtime source configuration intentionally remains sequential and partially applied:

- `tuna/lib/config.ss:29-41`
- `plans/emacsen-runtime/checklist.md:227-237`

## 7. Shutdown

`kill-emacs` runs its shutdown hook, then performs orderly low-level shutdown:

- `src/emacs.c:2944-3016`

Low-level shutdown:

- disables further hooks and redisplay;
- resets terminal modes;
- inhibits process sentinels;
- kills subprocesses;
- auto-saves;
- unlocks files;
- releases subsystem resources.

Evidence:

- `src/emacs.c:3080-3176`

The manual distinguishes:

- higher-level interactive query/confirmation;
- `kill-emacs-hook`;
- final process termination.

See `doc/lispref/os.texi:680-763` and [Killing Emacs](https://www.gnu.org/software/emacs/manual/html_node/elisp/Killing-Emacs.html).

### Core invariant

Shutdown is a runtime state transition, not merely falling out of `main`:

```text
running
  → stop accepting new work
  → optional query/veto
  → drain, cancel, or abandon queued work by policy
  → run bounded cleanup
  → flush observability
  → release resources
  → exit
```

Autosave, terminal reset, and killing editor subprocesses are host-specific. The phased transition and no-new-work rule are reusable.

## 8. Copy, adapt, or reject

| Emacs behavior | Tuna disposition |
|---|---|
| Non-returning top-level lifetime boundary | **Copy** |
| Per-command error containment and continued operation | **Copy** |
| Name-backed late command/action dispatch | **Copy**; existing `defaction` is the seam |
| Separate host-context argument acquisition | **Copy**; already present |
| One authoritative state-mutation lane | **Adapt** to mailbox/actor ownership |
| Process-wide lock around all Lisp execution | **Reject** as an implementation requirement |
| Timer/process callbacks only at safe points | **Adapt** to queued envelopes |
| Deferred/coalesced visible effects | **Adapt** to explicit effect publication |
| Sequential pre/post lifecycle | **Copy concept**, use typed phases rather than hook variables |
| Silent removal of failing hook callbacks | **Reject by default** |
| Recursive command loops and nested callback waits | **Reject initially** |
| Flat keymaps, prefix arguments, minibuffer, keyboard macros | **Reject from neutral runtime** |
| Frames/windows/redisplay machinery | **Reject from neutral runtime** |
| Partial mutation after command failure | **Do not copy as a goal**; document until transactions exist |
| Higher-level query plus lower-level forced shutdown | **Copy concept**, keep host-specific policy outside kernel |

## 9. Material implementation options

### Option A — Runtime-owned serialized mailbox

One Tuna thread waits on a mailbox and executes one mapped action at a time. Timer, process, signal, and host adapters submit envelopes.

**Advantages:** clear ownership, deterministic ordering, strong recovery/shutdown seam.

**Costs:** blocking actions stall all work; embedding in graphical or foreign event loops may require bridging.

### Option B — Host-owned wait loop with a Tuna `dispatch-one` processor

The host owns polling, sockets, graphical integration, and wake-ups. Tuna exposes a serialized processor for one opaque envelope plus an optional queue runner.

**Advantages:** most host-neutral; avoids competing event loops; still establishes action/error/effect semantics.

**Costs:** hosts must honor non-overlap and shutdown contracts.

**Recommendation:** this is the best default interpretation of “host-neutral command loop.”

### Option C — One serial lane per independent context

Each session/workspace/request context owns a queue; commands serialize within a context but can execute concurrently across contexts.

**Advantages:** higher throughput and natural isolation.

**Costs:** requires a settled context identity and ownership model, which the roadmap explicitly defers at `plans/emacsen-runtime/checklist.md:308-316`; cross-context operations become difficult.

### Option D — Fully concurrent direct action invocation

Continue relying on Tuna atoms and locks while allowing arbitrary threads to invoke actions and mutate host state.

**Advantages:** minimal machinery and potential throughput.

**Costs:** no simple command ordering, hook phase, effect publication, shutdown drain, or multi-object state invariant. This rejects the most valuable Emacs evidence and is not recommended for mutable application state.

## 10. Ordering recommendation

The present roadmap schedules:

- hooks/events at `plans/emacsen-runtime/checklist.md:260-270`;
- documentation at `272-282`;
- provenance at `284-294`;
- while excluding event loops at `346-357`.

For a long-lived Tuna runtime, a minimal serialized command processor should precede all three:

1. **Hooks/events** need concrete lifecycle points, mutation-during-dispatch rules, and error policy. Building generic listeners first risks inventing semantics the command processor later contradicts.
2. **Documentation** is not technically dependent on a loop, but it carries less architectural risk and can follow.
3. **Provenance** becomes more useful when it can attach command/envelope identity, origin, outcome, and definition generation to an actual dispatch boundary.

This should not reopen editor scope. The precursor should prove only:

- runtime remains alive until a stop request;
- multiple producers feed opaque envelopes;
- mapping uses current named action definitions;
- no two host-state commands overlap;
- success and failure both publish one final outcome;
- a failed command does not kill the loop;
- timer/process completions are queued rather than reentrant;
- shutdown has explicit acceptance/drain/cancel/flush behavior.

If Tuna is intentionally only an embeddable extension library, the opposite conclusion applies: the host should own all command-loop behavior, and the current exclusion should remain. The current `main` and roadmap language are closer to that library interpretation, while this task’s “long-lived runtime” objective favors the serialized processor.

## 11. Risks and unresolved gaps

- **High — ownership not enforced:** Tuna’s public action/value APIs remain callable from arbitrary threads. A command lane cannot guarantee host-state serialization unless host state is capability-owned or mutation APIs enforce lane ownership.
- **High — long action starvation:** as in Emacs, one non-yielding command can delay input, timers, effects, and shutdown indefinitely. Tuna needs an offload/cooperative-cancellation policy.
- **High — true multicore unmeasured:** `plans/emacsen-runtime/checklist.md:223` records symmetric multiprocessing as disabled in the tested runtime.
- **Medium — two publication domains:** `define-action!` resets the function cell and action cell separately at `tuna/lib/bindings.ss:202-217`. `invoke-action-with-context` is generation-coherent, but direct function dispatch can observe a body transition independently of action metadata. Command mapping should use the action definition path.
- **Medium — redefinition scheduling:** current configuration can mutate live definitions from whichever thread calls `load-config!`. Whether reload is allowed only as a serialized command remains unresolved.
- **Medium — backpressure and fairness:** Emacs’s selector and input-priority policy should not be copied accidentally; Tuna needs explicit queue limits and source fairness.
- **Medium — effect model:** no host-neutral representation yet distinguishes state changes, notifications, refresh requests, and asynchronous work.
- **Medium — shutdown semantics:** current Tuna only joins its logger; worker/process ownership and queued command disposition are undefined.
- **Low — Emacs source identity wording:** existing reports call annotated tag object `29f3…` a commit; the release commit is `636f…`.

**Confidence:** high for GNU Emacs 30.2 command-loop, error, timer/process, thread-lock, redisplay, and shutdown behavior; high for current Tuna source behavior; medium-high for the ordering recommendation because it depends on whether Tuna is a standalone long-lived runtime or an embeddable library.

## 12. Validation guidance

No implementation or tests were changed or executed during this read-only investigation.

### Current documented smoke validation

These commands are repository-backed by `tuna/README.md:42-52`:

```sh
set -eu
cd /home/jay/Code/workbench-gerbil

(cd tuna && gerbil build)

(cd packages/dummy && \
  GERBIL_PATH="$PWD/../../tuna/.gerbil" \
  GERBIL_LOADPATH= \
  gerbil build)

(cd tuna && gerbil env tuna --config config.ss)
```

They validate the existing finite action/configuration demonstration, not a long-lived command loop.

### Focused future command-processor validation

A tracked independent fixture should submit, in order:

```text
successful command
failing command
successful command
stop
```

and assert:

- both successful effects appear in order;
- the failed command yields one structured error;
- after/finalization runs once for every attempted command;
- the second successful command proves the process survived;
- no command begins before the previous final outcome;
- the stop request prevents later acceptance.

### Full future validation

Use the exact hermetic `gxi`, normal `gxc`, `gxc -O`, and characterization-only full-program matrix established at `plans/emacsen-runtime/checklist.md:377-389` and its subsequent command template. Add concurrent producers, timer deadlines, process completion, redefinition between queued commands, action-definition snapshots, backpressure, cancellation, and shutdown drain/flush cases. Full-program optimization must remain characterization-only because runtime expansion is currently unsupported.