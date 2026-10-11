# Tuna host-neutral state architecture

## Decision

Adopt **runtime-instance-owned, owner-confined mutable state with coherent revisioned snapshots** as Tuna’s default architectural direction.

This is a protocol, not an application model:

- Tuna does not define the state’s fields, resources, identity scheme, persistence, or host meaning.
- One existing command lane owns all authoritative mutation for one state instance.
- The mutable state is private and opaque outside that lane.
- Readers receive only detached, immutable-by-contract `(revision, snapshot)` roots.
- Publication installs the root before issuing nonblocking, capacity-one invalidations.
- Live definition/configuration state, durable application state, and dynamic execution context remain separate.

This architecture best preserves Gerbil/Lisp extensibility without committing Tuna to reducers, persistent collections, event sourcing, actors per resource, or host concepts. It can later migrate internally to immutable reducers without changing the snapshot/read-side contract.

**Do not implement M9 yet.** The current roadmap explicitly gates M9 on an approved state contract. The ownership and publication invariants below can define that contract, but the unresolved action-to-state bridge and failure publication behavior must first pass disposable experiments. See `plans/emacsen-runtime/checklist.md:276-286,387-400` and `research/tuna-current-state-boundary.md:87-98`.

## Evidence baseline

The three primary artifacts agree on the following foundation:

1. Emacs demonstrates that an extensible Lisp can succeed with distributed mutable resources, serialized user operations, revision generations, and deferred observation—but its command loop is not a transaction or exclusive mutation boundary.  
   `research/emacs-host-neutral-state-model.md:5-22,177-244,246-314`

2. Gerbil v19 supplies the required owner-thread, bounded-channel, completion, and mutex mechanisms, but does not enforce immutable data and lacks a supported persistent map library.  
   `research/gerbil-host-neutral-state-mechanisms.md:3-15,28-76,168-219`

3. Tuna already has an instance-owned bounded command lane with dequeue-time live action resolution, failure containment, and drain-on-stop, but no application state, revision, publication seam, rollback, or enforceable mutation ownership.  
   `research/tuna-current-state-boundary.md:3-9,13-42,55-74`

Current Tuna is clean at commit `806ece2dfd58c1ddd121e19f5b359f27a40a0e73`. Its worker invokes actions serially at `tuna/lib/runtime.ss:65-117`; admission and shutdown linearize under one mutex at `tuna/lib/runtime.ss:154-190`.

## Lessons to transfer from Emacs

### Transfer

- **Stable resource identity and encapsulated mutation.** Emacs stores authoritative state in mutable objects but made its buffer registry private after Lisp code could corrupt it.  
  Primary synthesis: `research/emacs-host-neutral-state-model.md:41-79`  
  Underlying GNU Emacs 30.2 source: `/home/jay/Code/emacs/src/buffer.c:118-121`, release commit `636f166cfc86aa90d63f592fd99f3fdd9ef95ebd`.

- **One ordered mutation boundary.** Emacs’s command loop establishes a useful `admit → invoke → finalize → publish` sequence. Timer and process completions should re-enter that sequence rather than mutate state from arbitrary threads.  
  Primary synthesis: `research/emacs-host-neutral-state-model.md:177-234`  
  Underlying source/manual: `src/keyboard.c:1113-1171,1426-1692`; `doc/lispref/commands.texi:36-71`.

- **Revision generations are invalidation tokens, not events.** Emacs modification ticks answer whether something changed; they do not reconstruct changes. Track-Changes separately coalesces detailed notifications.  
  Primary synthesis: `research/emacs-host-neutral-state-model.md:246-314`  
  Underlying source/manual: `src/buffer.c:1621-1657`; `doc/lispref/buffers.texi:590-605`; `doc/lispref/text.texi:6439-6544`.

- **Deferred/coalesced observation.** Redisplay reads authoritative state at a revision, caches a projection, and invalidates or retries when generations change.  
  Primary synthesis: `research/emacs-host-neutral-state-model.md:416-462`  
  Underlying source/manual: `src/xdisp.c:17779-17817,22069-22115`; `doc/lispref/display.texi:63-117`.

- **Separate durable state from execution context and definitions.** Dynamic values are temporary policy; live named definitions are configuration; neither is the application store.  
  `research/emacs-host-neutral-state-model.md:16-22,137-175`

### Reject

- A process-wide global interpreter lock as the state model. Emacs’s `global_lock` permits only one active Lisp executor but supplies neither rollback nor logical isolation.  
  `research/emacs-host-neutral-state-model.md:468-500`; underlying `src/thread.c:64-162,721-737`.

- Ambient “current resource” state, mutable public registries, raw hook lists, editor-specific dirty flags, or buffer undo machinery.  
  `research/emacs-host-neutral-state-model.md:502-522`

- Calling serialized commands transactional. Emacs atomic change groups roll back only participating buffer operations, not arbitrary cells, files, processes, hooks, or network effects.  
  `research/emacs-host-neutral-state-model.md:316-374`; underlying `doc/lispref/text.texi:6167-6279`.

## Exact Gerbil v19 mechanisms and constraints

The installed runtime is Gerbil `v0.19-dev-31-g4a4d1a30` on Gambit `v4.9.7-6-g64f4d369`, with Symmetric Multiprocessing (SMP) disabled. This does not excuse unsynchronized shared mutation: Gambit declares concurrent read/write or write/write access to one location erroneous.  
`research/gerbil-host-neutral-state-mechanisms.md:9-24`; underlying `gerbil-dev/src/gambit/doc/gambit.txi:10045-10053`.

Use:

- `spawn/name` for the retained owner thread: `gerbil-dev/src/gerbil/runtime/thread.ss:27-54`.
- A positive-capacity `:std/sync/channel`: queue, mutex, condition variable, bound, and close flag at `gerbil-dev/src/std/sync/channel.ss:15-28`.
- `channel-try-put` for immediate bounded admission: `channel.ss:49-63`.
- FIFO draining and EOF shutdown: `channel.ss:77-127`.
- One-shot completions for accepted commands: `gerbil-dev/src/std/sync/completion.ss:33-64`.
- A small mutex-protected snapshot cell for coherent reads.

Avoid:

- `channel-sync`, which bypasses the configured bound: `channel.ss:65-75`.
- Atom watches for publication. Watches execute synchronously under the mutation lock, after assignment, and failures can suppress later watches: `gerbil-dev/src/std/sync/atom.ss:40-54,97-105`.
- Unsynchronized `atom-deref`, which is only a generated field accessor: `atom.ss:16-18,38`.  
  Risk synthesis: `research/gerbil-host-neutral-state-mechanisms.md:92-116`.
- `AtomicCounter` for a revision separate from state. It is a fixnum, returns the old value, and cannot atomically commit another location: `atom.ss:110-125`.
- Assuming a final struct is immutable. Gerbil’s structures and nested containers remain mutable: `research/gerbil-host-neutral-state-mechanisms.md:168-190`.
- Shallow copies as snapshot isolation. `vector-copy`, `struct-copy`, and `hash-copy` retain nested aliases. Deep serialization costs O(reachable graph size) and cannot serialize every object: `research/gerbil-host-neutral-state-mechanisms.md:192-219`.
- The unavailable v0.18 actor/supervisor API or current distributed ensemble actors, whose handlers may overlap: `research/gerbil-host-neutral-state-mechanisms.md:293-311`.

## Architecture comparison

| Concern | Mutable owner-confined state + snapshots | Immutable reducer-style root | Unrestricted process-global mutation |
|---|---|---|---|
| **Ownership** | One runtime instance and command lane own an opaque mutable graph. | One owner installs replacement roots produced by reducers. | Any code retaining a reference may mutate. |
| **Extensibility** | Strong. Packages can define private mutable resources without a universal Tuna schema. | Moderate. Extensions need stable root schemas, extension slots, or persistent structures. | Superficially easy, but every extension can violate another’s invariants. |
| **Live action integration** | Preserves dequeue-time live resolution. Requires an explicit state-capable action bridge; ordinary actions stay unchanged. | Requires a new reducer contract such as `old-root → new-root + result/effects`. | Existing direct invocation works immediately but bypasses command ordering and instance ownership. |
| **Failure semantics** | An exception may leave partial mutation. Publication must expose the resulting state or fail the owner; rollback is not implied. | A reducer exception can discard an unpublished candidate root. External effects still require staging or compensation. | Partial mutation, races, and inconsistent observers; no single recovery boundary. |
| **Consistency** | Strong for published snapshots if constructed on the owner lane and installed as one `(revision, snapshot)` root. Authoritative state itself is not safe for external reads. | Strong whole-root consistency and atomic replacement. | At best per-cell atomicity; multi-cell reads can mix generations. |
| **Snapshot cost** | Host-dependent. It may be O(n) copying, a smaller projection, or O(1) handoff if the host already maintains immutable read data. | O(1) root handoff; updates allocate changed paths. | A safe snapshot requires global locking/copying and complete knowledge of aliases. |
| **Concurrency** | One writer; concurrent readers use detached snapshots. Independent I/O may run elsewhere and enqueue completions. | Same ownership, with easier old-root retention by readers. | Requires every extension to obey locking; otherwise Gambit defines races as errors. |
| **Migration flexibility** | Highest. Mutable internals can later become reducers, sharded owners, or persistent structures while preserving snapshot/subscription APIs. | Good read-side stability, but reducer and schema commitments can be expensive to undo. | Lowest. Locating leaked references and retrofitting ownership is difficult. |
| **Implementation cost now** | Smallest compatible with M8, provided snapshot boundaries and the action bridge are explicit. | Moderate and likely premature without supported persistent collections or known state shape. | Tiny initially, highest downstream correctness cost. |

### Mutable owner-confined state: selected

This follows the transferable part of Emacs: stable mutable resources, one ordered mutation lane, revisions, and deferred projections. It avoids copying Emacs’s global lock and ambient current-resource model. See `research/emacs-host-neutral-state-model.md:524-545`.

Its material limitation is failure behavior. Mutable commands are not automatically rolled back. Tuna must say so plainly rather than add an inverse log or transaction abstraction without an application need.

### Immutable reducers: retain as a migration option

Reducers provide the cleanest command-failure and snapshot semantics. Gerbil can implement them by convention, but v19 supplies no supported persistent Hash Array Mapped Trie (HAMT), and all ordinary Gerbil aggregates remain mutable. Large state could therefore force expensive copies or premature dependencies.  
`research/gerbil-host-neutral-state-mechanisms.md:13-15,168-198,315-366`

Adopting reducers now would impose state representation and extension-schema policy before Tuna has an application state.

### Unrestricted process-global mutation: reject

Tuna’s live values already illustrate the limitation: each stable cell is independently replaceable, process-wide, callable from arbitrary threads, and non-transactional across cells. They are appropriate for live definitions/configuration, not authoritative application state.  
`tuna/lib/bindings.ss:54-131,385-446`; `tuna/README.md:240-246`; `research/tuna-current-state-boundary.md:13-21,116-123`

A global store would also defeat M8’s deliberate support for multiple runtime instances and owner-confined opaque state: `plans/emacsen-runtime/checklist.md:260-270`.

## Required invariants

1. **Instance ownership:** one authoritative state instance belongs to exactly one command runtime/owner lane. It is never a process-global singleton by default.

2. **Single writer:** all authoritative mutations execute on that owner lane. I/O workers, timers, and other threads submit commands or completion commands.

3. **No public mutable reference:** public APIs never return the authoritative mutable state or a transitively mutable alias into it.

4. **Separate scopes:** process-wide live definitions, runtime-instance application state, and temporary dynamic/context values are distinct facilities.

5. **Explicit state bridge:** state-capable actions must be distinguishable from existing ordinary actions. Existing M6 action arity, generation coherence, direct invocation, and dequeue-time lookup cannot silently change.  
   `tuna/lib/bindings.ss:202-258`; `research/tuna-current-state-boundary.md:34-42`

6. **Coherent publication root:** revision and snapshot are installed together under one synchronization boundary. Use an unbounded exact integer unless a host selects another revision domain.

7. **Snapshot isolation:** every published snapshot is detached from later authoritative mutation or consists entirely of immutable-by-contract reachable data.

8. **Install before notify:** install `(revision, snapshot)`, then issue invalidations, then resolve the command completion. A completion therefore never claims finalization before the corresponding snapshot is readable.

9. **Nonblocking coalescing:** each subscriber has a capacity-one channel. `channel-try-put` failure due to fullness means “already notified,” not command failure. Notifications are wakeups, not events; consumers reread the latest root.

10. **Race-free subscription:** registration returns the current root and the subscriber handle as one linearized operation, preventing a gap between initial read and registration.

11. **Contained observers:** Tuna invokes no arbitrary subscriber callback on the owner lane or while holding the snapshot-cell/subscriber lock.

12. **Explicit failure publication:** after a state-capable operation that may have mutated state, Tuna must either publish a coherent post-attempt snapshot—including after ordinary action failure—or move the owner to `failed` before accepting more work. It must not continue with authoritative state newer than its advertised snapshot.

13. **No implied rollback:** ordinary mutable action failure may preserve partial state. Undo, rollback, isolation, and external-effect compensation remain separate future contracts.

14. **Lifecycle closure:** stopping rejects new commands, drains accepted work according to M8, closes subscriber channels, and makes snapshot/subscription lifecycle outcomes deterministic.

## Public and private seams

### Public read/lifecycle seam

The minimal eventual public surface should expose only:

- a coherent current `(revision, snapshot)` read;
- subscription that atomically returns the current root plus a capacity-one invalidation handle;
- unsubscribe/close;
- existing command admission, completion, stop, and join operations.

Subscribers must not receive arbitrary callbacks, deltas, domain events, or mutable state references.

### Private owner seam

Keep private:

- the authoritative state object;
- owner-thread mutation operations;
- snapshot construction;
- root installation and subscriber registry mutation;
- revision assignment;
- the bridge by which a state-capable action receives owner authority.

A state capability, if introduced, should be valid only on its owning lane and must not expose raw mutable storage. Retaining or invoking it off-lane should fail deterministically.

### Action bridge: unresolved gate

Existing actions receive explicit arguments only, and direct `invoke-action` remains public. Capturing one state object in a process-wide action closure is therefore unsafe for multiple runtime instances.  
`research/tuna-current-state-boundary.md:34-42,100-114`

The least invasive candidate to test is a **separate state-capable action generation** whose owner capability is injected only by the runtime at dequeue. Ordinary `defaction` and direct invocation remain unchanged. Alternatives to compare in a disposable spike are:

1. dedicated state-capable actions;
2. a separate owner component composed with CommandRuntime;
3. action-produced transition objects.

Reject any bridge that relies on M5 ambient contexts, moves action lookup to admission time, makes ordinary action returns magical, or leaks mutable state.

## What M9 should implement—after its gates pass

M9 should implement only:

1. one runtime-instance publication root containing revision plus opaque snapshot;
2. synchronized root reads;
3. atomic subscribe-plus-current-root acquisition;
4. one capacity-one invalidation channel per subscriber;
5. nonblocking `channel-try-put` coalescing;
6. unsubscribe and shutdown closure;
7. owner-only installation ordered before command completion;
8. tests for coherence, races, coalescing, failure, and lifecycle in source, normal `gxc`, and `gxc -O`.

M9 should **not** implement:

- any application state schema or resource type;
- HTTP, Server-Sent Events, Datastar, rendering, browser/editor/session concepts;
- M5 contexts as application state;
- a process-global state singleton or public `publish!` callable from arbitrary threads;
- immutable reducers as a universal requirement;
- persistent collection dependencies;
- deep-copy policy for arbitrary objects;
- rollback, undo, transactions, cancellation, or external effect staging;
- hooks, arbitrary observer callbacks, deltas, dirty categories, or changed-resource lists;
- a durable/lossless event log, replay, persistence, event sourcing, or brokers;
- per-resource actors, actor supervision, sharding, or cross-runtime transactions.

These exclusions match the existing M9 stop gate at `plans/emacsen-runtime/checklist.md:276-286`.

## Staged validation and stop gates

### Stage 0 — Contract only

Record the invariants above without changing runtime source.

**Stop if:** application terminology, state schema, reducer representation, or host lifecycle policy is required to state the contract.

### Stage 1 — Publication mechanism spike

Use an opaque fixture value to prove:

- coherent revision/snapshot reads;
- atomic initial-read-plus-subscribe;
- capacity-one coalescing under a slow subscriber;
- owner progress when subscribers are full;
- unsubscribe versus publish races;
- channel closure during shutdown;
- publication-before-completion ordering.

Use a mutex-protected root, not raw `atom-deref` or Atom watches.

**Stop if:** a reader can observe a mixed revision/payload, the publisher blocks on consumers, a bound is bypassed, or subscription has a missed-wakeup window.

### Stage 2 — Action bridge spike

Compare the three bridge candidates while preserving:

- action lookup at dequeue;
- coherent implementation/acquirer generation;
- existing ordinary action behavior;
- multiple independent runtimes;
- rejection of off-owner state access.

**Stop if:** ordinary M6 action arity or return meaning changes, direct `invoke-action` gains ambient mutation authority, state is captured process-wide, or M5 context inheritance becomes part of durable state semantics.

### Stage 3 — Mutable failure and snapshot experiment

With an opaque mutable graph, test:

- successful mutation and publication;
- mutation followed by an exception;
- snapshot construction failure;
- nested mutable aliases;
- an attempted off-lane mutation;
- completion ordering after success and failure.

**Stop if:** a failed command can leave authoritative state newer than the published root, a snapshot retains a mutable alias, or snapshot failure permits later commands to continue against unpublishable state.

### Stage 4 — Real-host cost gate

Only a real host can establish whether snapshot construction is a small projection, structural-sharing handoff, or prohibitive O(n) copy.

**Stop or reconsider reducers if:** representative snapshot cost stalls admission/shutdown, mutable alias isolation cannot be maintained, or whole-state consistency is required at a frequency the mutable snapshot approach cannot support.

### Stage 5 — SMP re-audit

The current runtime is SMP-disabled. Before claiming SMP support, re-audit channel close visibility and all snapshot-root access against Gambit’s memory-coherency rules.  
`research/gerbil-host-neutral-state-mechanisms.md:69-76,414-426`

## Focused and full validation commands

Current M8 baseline:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test/run-command-runtime-matrix.sh
```

This executes source `gxi`, normal `gxc`, and `gxc -O`, then compares worktree status: `tuna/test/run-command-runtime-matrix.sh:29-94`.

Gerbil synchronization primitives:

```sh
cd /home/jay/Code/workbench-gerbil
gerbil test -g \
  gerbil-dev/src/std/sync/atom-test.ss \
  gerbil-dev/src/std/sync/channel-test.ss \
  gerbil-dev/src/std/sync/completion-test.ss
```

Broader repository-supported validation after an implementation exists:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
gerbil build
gerbil test test/command-runtime-test.ss
test/run-command-runtime-matrix.sh

cd /home/jay/Code/workbench-gerbil/packages/dummy
GERBIL_PATH="$PWD/../../tuna/.gerbil" GERBIL_LOADPATH= gerbil build
```

Full upstream Gerbil validation, if Gerbil itself is changed:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil-dev
make check
# documented alternative:
./build.sh env gerbil test ./...
```

Source: `gerbil-dev/CONTRIBUTING.md:182-190`; `gerbil-dev/doc/reference/dev/test.md:17-25`.

## Review findings

- **High — unresolved state/action bridge:** `tuna/lib/runtime.ss:65-85` and `tuna/lib/bindings.ss:247-258` provide no explicit way for a runtime-instance state capability to reach an action. M9 must not proceed by closure-capturing process-global state.

- **High — ownership currently unenforceable:** exported direct action/value APIs can bypass the command lane. `research/tuna-current-state-boundary.md:116-123`.

- **High — mutable failure can partially apply:** neither Tuna nor Gerbil automatically rolls back in-place mutation after an exception. `research/emacs-host-neutral-state-model.md:357-374`; `research/gerbil-host-neutral-state-mechanisms.md:239-268`.

- **High — unrestricted global mutation is incompatible with coherent instance ownership:** Tuna’s live values provide only independent-cell atomicity and are shared across runtime instances. `tuna/lib/bindings.ss:54-131,385-446`.

- **Medium — snapshot representation is host-dependent:** shallow copies preserve aliases, while deep serialization is O(n) and excludes some objects. `research/gerbil-host-neutral-state-mechanisms.md:192-219`.

- **Medium — Atom is not a proven publication read seam:** `atom-deref` is unsynchronized and watches execute under the commit lock. `gerbil-dev/src/std/sync/atom.ss:16-18,38-54`.

- **Medium — publication failure precedence is unresolved:** if an action fails after mutation and snapshot construction also fails, Tuna lacks an exception-chaining contract. The minimum safe outcome is fatal owner failure, not silent continuation.

- **Medium — subscriber lifecycle remains unspecified:** registration races, unsubscribe, channel closure, and publication-versus-completion ordering are absent from current M9. `research/tuna-current-state-boundary.md:116-128`.

- **Low — terminology collision:** `command-runtime-state` already means lifecycle state; application state must use different public terminology. `tuna/lib/runtime.ss:51-63`.

## Deferred questions

- Which explicit state-capable action bridge preserves M6 and multiple runtime instances?
- Does every state-capable command publish, or can a capability reliably mark mutation?
- What exact post-failure publication and exception-precedence contract is acceptable?
- What constitutes an immutable/detached snapshot for the first real host?
- Is snapshot construction cheap enough on representative state?
- Can revisions advance on publication attempts with no semantic change?
- How are abandoned subscriber handles reclaimed?
- May configuration reload occur while state commands run, and under which ordering?
- When, if ever, are per-resource owners, reducers, persistent collections, rollback, or durable events justified?
- What changes when Gerbil is built with SMP?

## Residual risks and confidence

- **High:** no current Tuna test can attest state ownership, snapshot isolation, or publication because those facilities do not exist.
- **High:** selecting mutable ownership leaves partial-failure semantics visible; this is intentional but must be tested and documented.
- **Medium:** the eventual action bridge could enlarge the public API or weaken multiple-runtime isolation.
- **Medium:** snapshot cost and alias isolation cannot be resolved without representative host state.
- **Medium:** current Atom/channel implementation details require renewed scrutiny under SMP.
- **Low:** GNU Emacs citations are pinned to release tag `emacs-30.2`; current-master line numbers may differ.

**Confidence:** High for current Tuna boundaries, Emacs lessons, and Gerbil v19 mechanism semantics; medium-high for selecting owner-confined mutable state as the least committal architecture; medium for the eventual public API because the state/action bridge and real snapshot boundary remain deliberately gated.