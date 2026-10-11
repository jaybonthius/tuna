# GNU Emacs state management: host-neutral lessons

## Concise answer

GNU Emacs has no central application-state store. Its authoritative state is a distributed mutable object graph:

- interned symbols own global function, value, and property cells;
- buffers own mutable text, metadata, undo logs, local-variable overlays, and revision counters;
- the current buffer and dynamic bindings select which contextual values are visible;
- the command loop usually serializes user-level operations, while one process-wide lock permits only one active Emacs Lisp executor;
- mutations publish coarse revision tokens, dirty flags, undo entries, and synchronous hooks;
- redisplay reads the authoritative objects directly and uses cached revisions to decide what can be reused.

The transferable model is **stable identities, explicit state scopes, serialized mutation ownership, per-resource revisions, optional inverse logs, and deferred/coalesced observers**. It is not Emacs’s ambient current buffer, global symbol namespace, global interpreter lock, mutable hook lists, or buffer-text-specific undo machinery.

A host-neutral extensible Lisp program should keep three concepts distinct:

1. **Definition/configuration state** — live named functions and values.
2. **Durable application state** — domain resources owned by commands or contexts.
3. **Dynamic execution context** — temporary call-chain bindings that unwind automatically.

Emacs often blurs these categories for historical convenience. Copying that blur would make concurrency, rollback, and observation harder to specify.

## Evidence baseline

Authoritative GNU Emacs source was inspected in `/home/jay/Code/emacs` through tag `emacs-30.2`, dereferenced release commit:

```text
636f166cfc86aa90d63f592fd99f3fdd9ef95ebd
```

The checkout itself is currently on a later `master`; all Emacs line numbers below refer to `git show emacs-30.2:PATH`, not current-master line numbers.

Existing repository research incorporated:

- `research/emacs-command-loop-runtime-architecture.md`
- `research/emacs-runtime-extensibility-primitives.md`
- `research/emacs-runtime-roadmap-audit.md`
- `research/emacsy-runtime-customization-design.md`

## 1. Authoritative mutable state

### What Emacs actually does

There is no canonical immutable snapshot or reducer-owned store.

The authoritative text of a buffer resides in `struct buffer_text`, shared by a base buffer and its indirect buffers:

- `/home/jay/Code/emacs/src/buffer.h:221-251`

The corresponding `struct buffer` directly owns identity, visited-file state, read-only state, marks, local variables, modes, maps, tables, display configuration, undo state, and caches:

- `src/buffer.h:303-385`
- `src/buffer.h:385-480`
- `src/buffer.h:630-684`

Live buffers are indexed by a mutable process-wide alist. The source explicitly made that registry non-Lisp-visible to prevent callers from destructively corrupting it:

- `src/buffer.c:118-121`

Global Lisp definitions and values are similarly authoritative mutable cells. Value lookup follows aliases, plain cells, localized cells, or forwarded C storage:

- `src/data.c:1575-1611`
- separate symbol value/function/property access: `src/data.c:714-818`

Thus Emacs’s state is **identity-oriented and in-place**, not reconstructed from a journal.

### Transferable lesson

Use stable resource identities and encapsulate mutation behind resource APIs. A central registry can locate resources without itself becoming the entire state.

### Emacs-specific accident or anti-pattern

- Process-wide unqualified symbol identity and package-prefix conventions.
- Directly exposed mutable cells and object interiors.
- Numerous subsystem-specific dirty flags rather than a coherent publication protocol.
- Ambient selection of “the current” resource instead of explicit capabilities.

The private buffer registry is evidence that even Emacs eventually had to protect authoritative indexes from unrestricted mutation.

## 2. Global, default, and buffer/context-local values

Emacs distinguishes:

- a global/default binding;
- an optional binding associated with the current buffer;
- variables that automatically become local on assignment.

`default-value` and `set-default` explicitly address the fallback binding:

- `src/data.c:1986-2105`

`make-variable-buffer-local` makes assignment create a buffer-local value while reads fall back to the default:

- `src/data.c:2145-2209`

`make-local-variable` installs a value for only the current buffer:

- `src/data.c:2212-2315`

`kill-local-variable` removes the overlay and restores fallback:

- `src/data.c:2317-2379`

The buffer stores local values in an association list keyed by symbol:

- `src/buffer.h:345-348`

### Transferable lesson

A generic context-local value can be modeled as:

```text
qualified value identity
  → context-local override, if present
  → otherwise shared default
```

The useful semantics are fallback, explicit localization, automatic-local-on-set where justified, and removal restoring fallback.

### Constraints

- Context identity, lifetime, ownership, inheritance, and cleanup must be defined by the host.
- A context overlay is not a lexical namespace.
- Shared mutable defaults and context-local overrides need separate mutation operations.
- Context-local lookup should not require a process-global ambient selector in concurrent hosts.

### Emacs-specific accident

Buffer locality is built deeply into symbol lookup and sometimes implemented by eagerly swapping forwarded C storage when the current buffer changes:

- `src/data.c:1560-1571`
- `src/data.c:2293-2311`

That implementation is optimized for an editor’s ubiquitous current buffer. A neutral runtime should use an explicit context token or task-local context reference instead.

## 3. Dynamic bindings are execution context, not durable state

With lexical binding enabled, `setq` mutates a lexical binding when one is present; otherwise it mutates the current dynamic binding:

- `src/eval.c:465-499`

`defvar` declares a value special and initializes only an absent default:

- `src/eval.c:828-918`

Dynamic bindings and cleanup records live on each thread’s binding/unwind stack. Unwinding restores plain, default, or buffer-local values according to the recorded binding kind:

- `src/eval.c:3550-3592`
- `src/eval.c:3594-3669`
- `src/eval.c:3682-3761`
- `src/eval.c:3813-3835`

Emacs documents that global values are shared, while dynamic `let` bindings are thread-local; each thread also owns its current buffer:

- `doc/lispref/threads.texi:28-38`

The C representation confirms that the binding stack and current buffer belong to `thread_state`:

- `src/thread.h:125-144`

### Transferable lesson

Dynamic bindings are appropriate for temporary policy such as:

- current request or trace identity;
- temporary logging level;
- capability restrictions;
- locale or formatting policy.

They should restore on return, error, and nonlocal exit.

### Anti-pattern to avoid

Do not use dynamically scoped values as the authoritative durable application store. Their meaning depends on the current execution chain and thread, making persistence, publication, and cross-task transfer implicit.

## 4. Command-loop serialization

The outer command loop is a non-returning recovery loop with catches around command processing:

- `src/keyboard.c:1113-1171`

For each command, Emacs:

1. reads and maps input;
2. runs the pre-command hook;
3. establishes undo accounting;
4. executes one named command;
5. runs post-command processing.

Implementation:

- input and mapping: `src/keyboard.c:1426-1500`
- pre-hook and undo boundary: `src/keyboard.c:1511-1550`
- post-hook and finalization: `src/keyboard.c:1568-1692`

The manual presents the same sequence:

- `doc/lispref/commands.texi:36-71`

Errors are caught and the loop is re-entered:

- `src/keyboard.c:1155-1171`

### Important qualification

This is a strong ordering convention, not exclusive mutation ownership.

While input is being read, a process filter can already have run:

- `src/keyboard.c:1432-1435`

Timers execute at waiting-capable safe points, not arbitrary instructions:

- `doc/lispref/os.texi:2210-2215`

A timer or callback that performs another wait can become reentrant:

- `doc/lispref/os.texi:2229-2240`

Process output and sentinels similarly run while Emacs waits:

- `doc/lispref/processes.texi:1978-1987`
- `doc/lispref/processes.texi:2163-2171`

### Transferable lesson

Use a serialized command boundary:

```text
admit → resolve name/context → invoke → commit or fail → publish outcome
```

Timer, process, and worker completions should normally submit commands to this lane rather than directly mutate domain state.

### Anti-pattern to avoid

Do not equate “only one command handler dequeued at a time” with:

- rollback;
- isolation;
- non-reentrancy;
- ownership of every mutation API;
- atomicity across several resources.

## 5. Revision and change tracking

### Revision tokens

Each buffer text owns several counters:

- `modiff`: all buffer modification events;
- `chars_modiff`: character insertions/deletions;
- `save_modiff`: baseline at last visit/save;
- `overlay_modiff`: overlay changes.

Representation and semantics:

- `src/buffer.h:95-132`
- `src/buffer.h:239-269`

Insertion records undo, increments `MODIFF`, and updates `CHARS_MODIFF` before changing the gap-buffer contents:

- `src/insdel.c:894-927`

The public APIs expose coarse modification tokens:

- `src/buffer.c:1621-1657`
- `doc/lispref/buffers.texi:590-605`

`save_modiff < modiff` encodes the dirty/saved relationship. The source acknowledges that overloading this comparison with auto-save state creates awkward coupling:

- `src/buffer.c:1595-1617`

These counters are invalidation generations, not sequential event identifiers or a change log.

### Synchronous change notifications

Text primitives run before- and after-change functions:

- `src/insdel.c:2187-2255`
- `src/insdel.c:2257-2351`

Hooks are inhibited while those callbacks run to limit recursion:

- `src/buffer.c:5662-5694`
- `doc/lispref/text.texi:6394-6409`

The manual warns that before/after calls are not always balanced and callbacks should avoid mutation, blocking, and expensive work:

- `doc/lispref/text.texi:6286-6341`
- `doc/lispref/text.texi:6428-6437`

Emacs’s newer Track-Changes layer coalesces changes and decouples immediate signaling from later retrieval:

- `doc/lispref/text.texi:6439-6473`
- deferred signal behavior: `doc/lispref/text.texi:6487-6497`
- coalesced fetch: `doc/lispref/text.texi:6525-6544`

### Transferable lesson

Use both:

1. **Cheap generation tokens** for “has this resource changed?” checks.
2. **Structured/coalesced change descriptions** only for consumers that need deltas.

Prefer one application revision plus optional domain-specific generations when consumers genuinely need to distinguish categories.

### Anti-pattern to avoid

- Treating a revision as an event stream.
- Requiring every mutation to synchronously call arbitrary observers.
- Assuming before/after callbacks are transaction boundaries.
- Overloading one counter comparison with saved, dirty, auto-saved, and rendering semantics.

## 6. Undo and transactions

Most text primitives automatically prepend inverse information to the buffer-local `buffer-undo-list`:

- `doc/lispref/text.texi:1365-1377`
- insertion/deletion recording: `src/undo.c:81-118,159-203`

Undo entries cover inserted/deleted text, properties, markers, point, modified state, and extensible `(apply ...)` operations:

- `doc/lispref/text.texi:1379-1447`
- buffer variable representation: `src/buffer.c:5701-5745`

Nil entries delimit undo groups, usually corresponding to commands:

- `doc/lispref/text.texi:1442-1460`

The command loop adds boundaries, including to every affected buffer:

- `doc/lispref/text.texi:1463-1478`
- `lisp/simple.el:4046-4101`

### Atomic change groups

`atomic-change-group` wraps a body in `unwind-protect`; success accepts the changes and abnormal exit cancels them:

- `lisp/subr.el:3985-4018`

Cancellation replays undo records and restores the old undo-list tail:

- `lisp/subr.el:4110-4145`

The manual describes single- and multi-buffer groups:

- `doc/lispref/text.texi:6167-6226`
- `doc/lispref/text.texi:6252-6268`

But handles rely on the old undo-list cons remaining reachable. Editing the undo list can make cancellation fail:

- `doc/lispref/text.texi:6270-6279`
- `lisp/subr.el:4043-4079`

### Transferable lesson

Undo and transactions are different facilities:

- **Undo** is a retained inverse-operation history exposed to users.
- **Rollback** is a temporary guarantee around one operation.
- **Transaction isolation** additionally requires preventing readers from seeing intermediate state.
- **External side-effect safety** requires staging or compensating I/O.

An inverse log can provide rollback when every authoritative mutation participates and inverses are reliable.

### Emacs-specific limitation

Emacs atomic groups cover recorded buffer changes. They do not automatically revert arbitrary global cells, hook side effects, files, subprocess operations, messages, or network effects. Even the single-buffer convenience form explicitly leaves changes to other buffers intact:

- `doc/lispref/text.texi:6188-6196`

Calling Emacs command execution “transactional” without this qualification is a high-severity semantic error.

## 7. Hooks

Hooks are mutable variables containing a function or ordered list of functions.

`add-hook` supports depth ordering and optional buffer-local composition. A local hook includes `t` to splice in the global/default hook:

- `lisp/subr.el:2094-2127`
- `lisp/subr.el:2128-2184`

The runner executes local entries sequentially and expands `t` into the default value:

- `src/eval.c:2890-2958`

Named symbols remain late-bound; captured lambdas remain captured.

Failure policy is not uniform. Command hooks run through a protected wrapper that reports and removes the failing callback:

- `src/keyboard.c:1878-1963`
- documented behavior: `doc/lispref/commands.texi:80-100`

Ordinary hooks can instead abort later entries unless their caller adds containment.

### Transferable lesson

Expose named lifecycle phases with:

- stable callback identity;
- documented ordering;
- explicit context and arguments;
- explicit failure policy;
- mutation-during-dispatch semantics;
- optional coalescing.

### Anti-pattern to avoid

- Raw mutable callback lists as the public representation.
- Silent removal as the default failure policy.
- Different containment behavior depending on which subsystem happened to run the hook.
- Using hooks as a complete audit log.

## 8. Redisplay and read-side observation

Redisplay does not consume a committed immutable application snapshot. It reads live buffer/window objects and uses generation caches to determine whether old rendering can be reused.

Each window remembers the displayed buffer’s last completed text and overlay revisions:

- `src/window.h:280-290`

After an accurate display, Emacs snapshots current revisions and unchanged regions into the window/buffer caches:

- `src/xdisp.c:17779-17817`

Redisplay rejects incremental reuse when overlay generations differ or previous display state is invalid:

- `src/xdisp.c:22069-22115`

Dirty/saved state is also compared against what the window last rendered:

- `src/xdisp.c:13490-13509`

Redisplay is deferred and preemptible:

- user input takes priority: `doc/lispref/display.texi:63-66`
- normal redisplay occurs while waiting for input: `doc/lispref/display.texi:86-100`
- invalidation can merely schedule future work: `doc/lispref/display.texi:102-117`

### Transferable lesson

A read-side projection can use:

```text
read authoritative resource at revision R
→ derive/cache projection
→ publish projection tagged R
→ invalidate or retry if the relevant revision changed
```

Deferred and coalesced refresh is usually preferable to rendering or serializing from every setter.

### Constraints

Emacs gets away with direct reads partly because only one Lisp thread executes at once. A genuinely concurrent host needs either:

- immutable snapshots;
- a read lock;
- generation validation and retry;
- or projections built on the owning mutation lane.

### Emacs-specific accident

Redisplay contains many subsystem-specific flags and cache-validity rules. Those are consequences of editor rendering performance, not a generic application-state API.

## 9. Thread and concurrency semantics

Emacs Lisp threads share memory but are “mostly cooperative.” Switching occurs at yields, input/process waits, mutex operations, and joins:

- `doc/lispref/threads.texi:10-31`

A process-wide `global_lock` permits only one active Emacs Lisp executor:

- declaration and switching: `src/thread.c:64-162`
- yield releases and reacquires it: `src/thread.c:721-737`
- a new Lisp thread acquires it before invoking Lisp: `src/thread.c:757-815`
- main-thread initialization locks it: `src/thread.c:1162-1175`

Each thread has its own binding stack and current buffer:

- `src/thread.h:125-144`
- new threads inherit the parent’s current buffer but not dynamic bindings: `src/thread.c:895-907`
- manual: `doc/lispref/threads.texi:58-69`

### Transferable lesson

Define separately:

- who owns each mutable resource;
- which state is shared;
- which execution context is task-local;
- where scheduling/yield points exist;
- whether callbacks may re-enter;
- how cross-thread completion becomes an ordered mutation.

### Anti-pattern to avoid

A global interpreter lock is not a host-neutral state model. It suppresses simultaneous Lisp heap mutation but sacrifices parallelism and does not provide rollback, isolation, fairness, or protection from logical races across yield points.

## 10. Transferability matrix

| Emacs evidence | Host-neutral disposition |
|---|---|
| Stable mutable identity for named definitions/resources | **Transfer** |
| Separate default and context-local values | **Transfer**, with host-defined context |
| Dynamic extent with guaranteed unwind | **Transfer** for temporary execution policy |
| Serialized command boundary and error recovery | **Transfer** |
| One global Lisp lock | **Reject as an architectural requirement** |
| Per-resource revision generations | **Transfer** |
| Domain-specific dirty generations | **Adapt only when demonstrated** |
| Automatic inverse recording by mutation primitives | **Transfer conceptually** for selected resources |
| Buffer undo list as generic transaction log | **Reject** |
| Atomic change group built on inverse operations | **Adapt**, with explicit coverage limits |
| Named ordered lifecycle callbacks | **Transfer** |
| Mutable hook variables and silent callback removal | **Reject by default** |
| Deferred/coalesced observation | **Transfer** |
| Redisplay’s editor-specific cache and dirty-flag graph | **Reject from neutral core** |
| Ambient current buffer | **Replace with explicit/task-local context** |
| Global unqualified symbol namespace | **Replace with qualified identities** |
| Nested waits and recursive callback execution | **Reject initially or specify explicitly** |

## 11. Plausible generic state approaches

### Approach A — Distributed mutable resources with one mutation lane

Each domain resource owns mutable fields, a revision, and optional undo/change metadata. Commands on one lane mutate resources in place. Context-local values remain overlays.

**Emacs evidence:** buffer objects, command-loop serialization, revision counters, undo lists, and deferred redisplay.

**Strengths**

- Natural fit for extensible object-oriented or Lisp systems.
- Cheap local mutation and per-resource observation.
- Context-local state remains independent.
- Incremental adoption is possible.

**Costs and risks**

- Multi-resource consistency needs explicit transactions.
- Every mutation path must honor lane ownership and revision updates.
- Readers need locking, snapshots, or revision validation.
- Direct extension code can bypass invariants unless capabilities are constrained.

### Approach B — Immutable aggregate snapshots with command reducers

A command reads an immutable application snapshot and produces a replacement snapshot plus effects. One atomic reference publishes the new revision.

**Emacs evidence:** this is not how Emacs is implemented, but its fragmented dirty flags, partial rollback, and read-side cache complexity show the problems this approach can avoid.

**Strengths**

- Atomic publication and consistent read snapshots.
- Straightforward global revisioning and optimistic concurrency.
- Failed commands can discard an unpublished candidate state.
- Deterministic testing and time-travel tooling are easier.

**Costs and risks**

- Large or independently changing resources require persistent data structures and sharding.
- Extensions need stable schemas or typed extension slots.
- External effects still require staging.
- Definition/runtime registries should remain separate from domain snapshots.

### Approach C — One actor/mailbox per context or resource

Each application context owns mutable state and processes one message at a time. Independent contexts execute concurrently. Shared definitions are immutable snapshots or separately synchronized cells.

**Emacs evidence:** adapt its single execution lane and thread-local current-buffer semantics into explicit ownership rather than one process-wide lock.

**Strengths**

- Clear ownership and natural context locality.
- Concurrency across independent sessions/resources.
- Timer and I/O completions become ordinary messages.
- Revisions and notifications can be scoped per actor.

**Costs and risks**

- Cross-context operations require coordination protocols.
- Deadlocks and mailbox backpressure need explicit policy.
- Global configuration replacement remains a separate consistency domain.
- Blocking handlers stall their actor.

### Approach D — Append-only event journal with projections

Commands append validated domain events. Projections derive current state; undo appends compensating events rather than mutating history.

**Emacs evidence:** its inverse undo log and Track-Changes coalescing demonstrate the value of explicit change records, while also demonstrating that an incomplete log cannot be authoritative.

**Strengths**

- Auditability, replay, subscriber catch-up, and provenance.
- Natural revision identities.
- Durable cross-process publication.

**Costs and risks**

- Event schema evolution and projection recovery are substantial commitments.
- Arbitrary Lisp mutation cannot bypass event production.
- User undo, transactional rollback, and compensating business events are distinct.
- External effects need idempotency and an outbox-like protocol.

### Comparison

| Property | Mutable resources | Immutable snapshot | Actors | Event journal |
|---|---:|---:|---:|---:|
| Local mutation cost | Low | Medium | Low | Medium |
| Whole-state consistent reads | Weak without extra mechanism | Strong | Per actor | Projection-dependent |
| Multi-resource atomicity | Explicit transaction | Natural within snapshot | Coordination required | Append transaction dependent |
| Context concurrency | Limited by lane design | Possible with sharding | Strong | Strong projections |
| Live Lisp extensibility | Natural but risky | Requires extension schema | Natural through messages | Requires event discipline |
| Audit/replay | Optional | Snapshot history optional | Optional | Strong |
| Implementation complexity | Moderate | Moderate | Moderate-high | High |

No one option follows automatically from Emacs. The decisive questions are state size, cross-resource invariants, required auditability, and whether hosts need concurrent independent contexts.

## 12. Current Workbench Gerbil/Tuna behavior and gaps

Current Tuna already implements part of the transferable execution model:

- a bounded command channel and lifecycle state: `tuna/lib/runtime.ss:21-63`
- one worker dequeues and completes commands serially: `tuna/lib/runtime.ss:65-117`
- command failures are returned through completions: `tuna/lib/runtime.ss:65-85`
- admission is linearized under a mutex and reports `accepted`, `full`, or `not-running`: `tuna/lib/runtime.ss:141-172`
- stop rejects later work and drains accepted work: `tuna/lib/runtime.ss:178-210`
- concurrent-producer non-overlap is tested: `tuna/test/command-runtime-test.ss:195-216`

Live function, action, and value identities use stable atoms and a protected append-only registry:

- `tuna/lib/bindings.ss:31-131`
- coherent action definition snapshots: `tuna/lib/bindings.ss:202-258`

Dynamic values and provisional context-local overlays are distinct:

- context creation/selection: `tuna/lib/bindings.ss:301-326`
- fallback and dynamic lookup: `tuna/lib/bindings.ss:332-361`
- automatic localization and atomic cell replacement: `tuna/lib/bindings.ss:371-420`
- explicit local removal and dynamic unwind: `tuna/lib/bindings.ss:457-494`

Current documented constraints:

- single-cell replacement is atomic, but multiple binding changes are not transactional: `tuna/README.md:240-246`
- context identity, ownership, lifetime, and inheritance remain provisional: `tuna/README.md:248-264`
- configuration evaluation is sequential and partially applied: `tuna/lib/config.ss:29-41`
- the command runtime has no application-state store, publication channel, cancellation, or rollback: `tuna/README.md:115-124`

### Material gaps

- **High — mutation ownership is unenforced:** exported action and value APIs remain callable from arbitrary threads, so the command worker does not own all future application mutation.
- **High — no generic application state exists yet:** live definition cells are configuration/extensibility state, not a domain-state model.
- **High — no revision/publication contract:** consumers cannot ask for a committed application revision or structured changed-resource set.
- **High — no rollback boundary:** command errors preserve arbitrary mutations made before failure.
- **Medium — submitted payloads are shared by reference:** callers must not mutate them after admission; this is documented at `tuna/lib/runtime.ss:141-152`.
- **Medium — blocking handlers delay draining and shutdown:** the worker has no cancellation or command deadline.
- **Medium — two concurrency domains remain:** command serialization and atom-based live definition replacement have separate ordering.
- **Medium — context inheritance is provisional:** it should not become a public host contract accidentally.

## 13. Review findings

- **High:** Treating Emacs’s command loop or Tuna’s worker as a transaction would be incorrect; both permit partial state mutation unless an explicit rollback mechanism covers that state.
- **High:** Treating modification ticks or hooks as a complete change journal would lose information.
- **High:** Copying ambient current-buffer semantics into a host-neutral runtime would create hidden dependencies and task-transfer ambiguity.
- **High:** A serialized queue provides ordering only for mutations forced through it.
- **Medium:** Emacs’s inverse-log atomic groups are useful evidence but depend on fragile, resource-specific undo participation.
- **Medium:** Direct read-side observation is safe only with a documented concurrency/snapshot protocol.
- **Medium:** Hook failure and recursion policy must be explicit rather than inherited from Emacs conventions.
- **Low:** Exact Emacs buffer, window, redisplay, and gap-buffer structures are irrelevant to the neutral state abstraction.

## 14. Validation

### Commands executed

The installed GNU Emacs 30.2 passed a focused probe covering:

- global and dynamic restoration;
- buffer-local fallback;
- modification-tick advancement;
- atomic change rollback;
- thread-local dynamic bindings;
- inherited current buffer.

Result:

```text
GNU Emacs 30.2
Emacs state probe passed
```

The Emacs release commit and absence of staged Workbench changes were also verified.

### Focused authoritative Emacs probe

```sh
emacs -Q --batch --eval '
(progn
  (defvar wbg-state :global)

  (unless (eq (let ((wbg-state :dynamic)) wbg-state) :dynamic)
    (error "dynamic binding failed"))
  (unless (eq wbg-state :global)
    (error "dynamic restore failed"))

  (with-temp-buffer
    (make-local-variable (quote wbg-state))
    (setq wbg-state :local)
    (unless (and (eq wbg-state :local)
                 (eq (default-value (quote wbg-state)) :global))
      (error "buffer local failed")))

  (with-temp-buffer
    (setq buffer-undo-list nil)
    (let ((tick (buffer-modified-tick)))
      (insert "a")
      (unless (> (buffer-modified-tick) tick)
        (error "revision tick failed")))
    (let ((before (buffer-string)))
      (condition-case nil
          (atomic-change-group
            (insert "b")
            (error "rollback"))
        (error nil))
      (unless (equal (buffer-string) before)
        (error "atomic rollback failed"))))

  (let ((inherited-buffer (generate-new-buffer " *wbg-thread*")))
    (unwind-protect
        (with-current-buffer inherited-buffer
          (let ((wbg-state :parent))
            (unless
                (equal
                 (thread-join
                  (make-thread
                   (lambda ()
                     (list wbg-state
                           (eq (current-buffer) inherited-buffer)))))
                 (quote (:global t)))
              (error "thread state semantics failed"))))
      (kill-buffer inherited-buffer)))

  (princ "Emacs state probe passed\n"))'
```

### Current Tuna runtime validation

The repository-backed source, normal-compiled, and optimized command-runtime matrix is:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test/run-command-runtime-matrix.sh
```

Evidence:

- command implementation and hermetic temporary builds: `tuna/test/run-command-runtime-matrix.sh:1-76`
- source, normal `gxc`, and `gxc -O` execution: `tuna/test/run-command-runtime-matrix.sh:78-83`
- before/after worktree comparison: `tuna/test/run-command-runtime-matrix.sh:85-91`
- documented invocation: `tuna/README.md:120-128`

This matrix validates serialization, admission, live dispatch, recovery, and draining shutdown. It does **not** validate application revisions, state publication, rollback, or domain-state ownership because those facilities do not exist.

### Future full state-model validation requirements

Once a state approach exists, the full matrix should additionally assert:

1. every authoritative mutation is rejected or redirected outside its owner lane;
2. successful commands publish exactly one committed revision;
3. failed commands either preserve documented partial state or fully roll back covered resources;
4. observers never receive a “committed” event for rolled-back work;
5. context-local fallback and removal behave under concurrent contexts;
6. dynamic bindings restore across return, exception, continuation escape, and worker handoff;
7. read projections detect or prevent mixed revisions;
8. multi-resource operations meet their stated atomicity level;
9. live definition replacement during queued execution has a documented ordering;
10. shutdown handles queued, running, and externally completing work deterministically.

## Residual risks and confidence

- **High:** Emacs source establishes semantics for an editor-centric mutable object graph, not which generic approach Workbench Gerbil should select.
- **High:** No current Tuna test can attest application-state ownership or rollback.
- **Medium:** Emacs hooks and undo contain historical edge cases not exhaustively enumerated here.
- **Medium:** A future Gerbil implementation must validate memory visibility and optimizer behavior for revisions and snapshot publication.
- **Medium:** Cross-context transactions and external effects remain unresolved under every compared approach.
- **Low:** Line citations are pinned to Emacs 30.2 and can drift on current `master`.

**Confidence:** High for GNU Emacs 30.2 state scopes, command ordering, revisions, undo, hooks, redisplay observation, and thread-lock behavior; high for current Tuna source behavior; medium-high for the generic mapping because final suitability depends on host invariants not yet selected.