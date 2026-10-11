# Functional application-state patterns for a serialized Lisp runtime

## Concise answer

For a generic extensible Lisp runtime with one serialized command lane, the cleanest functional model is:

```text
stable runtime identity
  → current immutable (revision, state) value

transition(state, command)
  → (candidate-state, result, effect-descriptions)

validate candidate
  → atomically install (next-revision, candidate-state)
  → execute/schedule effects outside the pure transition
  → feed effect outcomes back as later commands
```

This separates **identity** from its successive **state values**, makes failed pure transitions discardable, supports coherent snapshots, and does not require Software Transactional Memory (STM) or optimistic retry inside an already serialized lane.

That is the conceptual ideal. In this repository’s Gerbil v19 environment, immutability is conventional rather than enforced and no supported persistent map implementation is installed. Therefore **owner-confined mutable internals with detached immutable snapshots** are a materially different and often more practical option when state is large, update-intensive, resource-bearing, or tied to mutable libraries. Such internals do not provide automatic rollback.

Event sourcing is not merely “keeping snapshots.” It makes an append-only event stream authoritative and derives state by replay; snapshots are only replay optimizations. Adopt it only when auditability, reconstruction, temporal queries, or durable integration justify its schema, replay, idempotency, and operational costs.

Labels below distinguish **Established fact** from **Inference for this runtime**.

---

## 1. Immutable values, identity, and persistent data

### Identity as a reference to successive values

**Established fact.** Clojure’s official state essay defines identity as “a stable logical entity associated with a series of different values over time,” defines state as an identity’s value at a point in time, and separates the identity from immutable state values. It recommends calculating a new value from the old value and then associating the identity with that new value:

- [Clojure, “Values and Change,” pinned source lines 31–57](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/about/state.adoc#L31-L57)

This produces a useful three-part distinction:

1. **Value:** immutable data describing one state.
2. **Identity/reference:** stable location or capability whose current value may be replaced.
3. **Transition:** calculation from an old value and input to a new value.

**Inference for a serialized runtime.** One runtime instance can be the identity; one coherent `(revision, state)` root can be its current value. Revision and state should be installed together rather than maintained in separate cells.

### Persistent values and structural sharing

**Established fact.** Clojure collections are immutable and persistent; “modified” versions use structural sharing rather than mutating the source:

- [Clojure data structures, pinned source lines 119–124](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/reference/data_structures.adoc#L119-L124)

“Persistent” here means previous versions remain valid. It does not mean durable disk persistence.

Structural sharing is safe only when every shared reachable descendant is immutable. A mutable box, vector, hash table, or object shared between roots defeats snapshot isolation.

### Memory retention

**Established fact.** Gambit reclaims unreachable objects by tracing reachability from roots; pairs, vectors, records, and closures normally hold strong references:

- `gerbil-dev/src/gambit/doc/gambit.txi:9224-9235`

**Inference.** Retaining an old persistent root—through undo history, a subscriber, a cache, an unfinished command, or an accidental closure—keeps everything reachable from that root alive. Structural sharing lowers copying and allocation but does not make retained versions free:

- nodes shared with the current root remain live once;
- nodes replaced along old paths remain live while any old root references them;
- unbounded root history is therefore unbounded retention.

Use bounded history, explicit snapshot lifetimes, and subscriber cleanup. Event logs have a separate durable-retention problem; snapshots add storage and do not automatically permit deleting authoritative events.

---

## 2. Reducers and state machines

### Pure reducer

**Established fact.** Redux defines reducer rules as:

- calculate only from the current state and action;
- do not mutate existing state;
- perform no asynchronous work or other side effects.

Source:

- [Redux reducer rules, pinned source lines 323–344](https://github.com/reduxjs/redux/blob/2d5498d1c302f8a6691a9564b3b25cf50b7e176b/docs/tutorials/fundamentals/part-3-state-actions-reducers.md#L323-L344)

This is technically relevant outside any frontend: a reducer is simply a deterministic state transition such as:

```text
reduce : State × Command → State × Result × Effects
```

The `Effects` component should be data describing work, not work performed during the transition.

### Explicit state machine

**Established fact.** Erlang/Open Telecom Platform (OTP) describes an event-driven state machine as:

```text
State(S) × Event(E) → Actions(A), State(S')
```

- [Erlang/OTP 29.0.4 `gen_statem` design, lines 29–58](https://github.com/erlang/otp/blob/OTP-29.0.4/system/doc/design_principles/statem.md#L29-L58)

A state machine is preferable to a generic reducer when legal states and transitions need explicit enumeration, rejected transitions need precise diagnostics, or lifecycle phases matter. It is still compatible with an immutable root: the machine state and associated data are part of the returned next value.

### Rollback and validation

**Inference.** A pure reducer gives cheap **pre-commit rollback**, not general transactional rollback:

1. retain the old root;
2. calculate a candidate without publishing it;
3. reject an exception or invalid candidate;
4. leave the old root installed.

This works only if the transition did not mutate the old reachable graph and did not perform external effects.

Validation can occur at two levels:

- extension-local checks while constructing each slice;
- root-level invariants over the complete candidate before installation.

Validation should be deterministic and effect-free. Validation after installing a mutable candidate is too late to provide discard semantics.

---

## 3. Clojure Atom semantics—and the Gerbil difference

### Clojure Atom

**Established fact.** Clojure Atoms provide shared, synchronous, independent state. `swap!` reads a current immutable value, computes a replacement, and uses compare-and-set. Concurrent interference causes the function to be called again, so the function must be free of side effects:

- [Clojure Atom reference, pinned source lines 14–18](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/reference/atoms.adoc#L14-L18)

Atoms support validators and watches, but coordinate only one independent identity. If two cells must change coherently, two Atoms are the wrong abstraction unless one root combines both values.

**Rollback:** a rejected validator or failed candidate computation leaves the old value installed; already performed external effects do not roll back.

**Optimistic retry:** `swap!` may rerun its function. Nondeterminism, I/O, logging, identifier allocation, and mutation inside that function can occur multiple times.

### Current Gerbil Atom

**Established repository fact.** Gerbil’s Atom is explicitly styled after Clojure but currently differs:

- it stores a mutex, value, validator, and watches: `gerbil-dev/src/std/sync/atom.ss:31-36`;
- transformations execute once while holding the mutex: `gerbil-dev/src/std/sync/atom.ss:40-80`;
- validation occurs before assignment: `gerbil-dev/src/std/sync/atom.ss:45-50`;
- watches run after assignment while the same lock remains held: `gerbil-dev/src/std/sync/atom.ss:45-54,97-105`;
- the documentation says the current implementation does not retry but reserves the right to change: `gerbil-dev/doc/reference/std/misc/atom.md:35-40`;
- `atom-deref` is a generated field accessor, not a locked read: `gerbil-dev/src/std/sync/atom.ss:16-18,38`.

Gambit says concurrent read/write or write/write access to one location without synchronization is erroneous:

- `gerbil-dev/src/gambit/doc/gambit.txi:10045-10053`

**Inference for one command lane.** Wrapping owner-only transitions in an Atom adds a mutex and callback hazards without resolving any internal conflict: the lane already serializes writes. A separately synchronized publication root may still be needed for readers, but Gerbil’s raw `atom-deref` should not be assumed to be a proven Symmetric Multiprocessing (SMP)-safe read seam.

Do not use Atom watches as the authoritative effects bus: a watch runs after commit, under the lock, and a watch exception cannot undo the committed value.

---

## 4. Clojure Refs and STM

**Established fact.** Clojure Refs implement coordinated, synchronous change across multiple locations through STM. Transactions are:

- atomic: all Ref changes occur or none do;
- consistent: validators check candidate values;
- isolated: a transaction does not see another transaction’s effects while running;
- automatically retried on conflict.

Clojure uses multiversion concurrency control and snapshot isolation:

- [Clojure Ref reference, lines 16–20](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/reference/refs.adoc#L16-L20)

Reads see a consistent Ref-world snapshot; writes appear at one write point. `ensure` protects an otherwise unmodified Ref, while `commute` permits concurrent changes only when its function is genuinely commutative:

- [Clojure Ref details, lines 22–32](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/reference/refs.adoc#L22-L32)

The official reference explicitly warns that transactions will retry and therefore I/O and other side effects should be avoided. Ref values must be immutable or treated as immutable:

- same source, lines 30–33.

### Fit for a single command lane

**Inference.** STM is useful when independent concurrent writers need a consistent multi-reference view. A single command owner already provides serializability and can commit one whole root without transaction conflicts. Adding STM would therefore duplicate serialization and retry machinery.

STM becomes materially different and potentially justified if:

- mutations are deliberately allowed from multiple threads;
- extensions own independently addressable references;
- commands need consistent transactions across those references;
- concurrency is valuable enough to offset retries and stricter effect discipline.

No active Clojure-style STM facility was identified in this Gerbil v19 tree. Implementing one merely to manage a single serialized root would be disproportionate.

---

## 5. Agents

**Established fact.** Clojure Agents provide independent, asynchronous change of one location. An action receives the current immutable state, and its return value—after validation—becomes the new state:

- [Clojure Agent reference, lines 17–27](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/reference/agents.adoc#L17-L27)

Additional semantics:

- at most one action executes for each Agent;
- sends from one producer preserve order but may interleave with other producers;
- an action exception is cached and affects later interactions;
- sends issued inside an STM transaction are delayed until commit and discarded if the transaction retries or aborts.

Source:

- [Clojure Agent reference, lines 29–37](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/reference/agents.adoc#L29-L37)

The action set is open because actions are functions and may be multimethods, which is relevant to extensible Lisps.

### Fit for a single command lane

**Inference.** A long-lived serialized command owner is already agent-like but may offer stronger global ordering, bounded admission, synchronous completion, and explicit lifecycle. Adding one Agent per state slice changes semantics:

- there is no longer one global mutation order;
- cross-agent transitions need STM or another coordinator;
- asynchronous failures and shutdown become distributed;
- command completion may precede eventual state changes unless explicitly awaited.

Agents are better for independent asynchronous workers or effect processors than for replacing an existing authoritative lane.

---

## 6. Pure transitions and external effects

### Established update-loop precedents

**Established fact.** Redux requires effects outside reducers and places asynchronous/effectful work in middleware:

- [Redux side-effect guidance, pinned lines 17–42](https://github.com/reduxjs/redux/blob/2d5498d1c302f8a6691a9564b3b25cf50b7e176b/docs/usage/side-effects-approaches.mdx#L17-L42)

**Established fact.** Elm’s update model returns a new model together with `Cmd` values sent to the runtime. Commands and subscriptions are the interface to the outside world:

- [Elm guide, commands and subscriptions, pinned lines 24–34](https://github.com/evancz/guide.elm-lang.org/blob/df8f5e964e1ee7ca6610b856e16877d94af7aa98/book/effects/README.md#L24-L34)
- [Elm HTTP update signature and command result, lines 140–165](https://github.com/evancz/guide.elm-lang.org/blob/df8f5e964e1ee7ca6610b856e16877d94af7aa98/book/effects/http.md#L140-L165)

These are relevant as effect-boundary designs, not as frontend architecture requirements.

### Generic effect protocol

**Inference.** A neutral runtime can use:

```text
transition(old-state, command)
  -> {
       next-state,
       command-result,
       effects: [effect-description ...]
     }
```

The owner then:

1. computes the transition;
2. validates the whole candidate;
3. installs `(revision, next-state)`;
4. records or schedules effects;
5. posts completion according to its documented ordering;
6. converts effect success/failure into later commands.

Effects should carry stable identifiers when duplicate execution is possible.

### Failure windows

No in-memory reducer, Atom, STM, or owner thread can atomically commit both Lisp memory and an arbitrary filesystem, process, or network service.

Materially different orderings are:

| Ordering | Benefit | Failure window |
|---|---|---|
| Effect before state commit | State can reflect successful effect | Process may crash after effect but before commit; retry can duplicate it |
| State commit before effect | Pure state commit is reliable and observable | Effect may fail after state says it is pending/required |
| Durable event/outbox commit, then effect | Replayable delivery and recovery | Requires durable storage, idempotency, and delivery policy |
| Compensating action | Can repair some completed effects | Compensation may fail and is not true rollback |

A robust functional model usually represents `pending`, `succeeded`, and `failed` explicitly in state. Exactly-once external effects are not implied.

---

## 7. Event sourcing versus snapshots

### Event sourcing

**Established fact.** Fowler defines Event Sourcing as capturing every application-state change as a sequence of stored events, enabling reconstruction and temporal replay:

- [Martin Fowler, “Event Sourcing,” “How it Works” and “Complete Rebuild”](https://martinfowler.com/eaaDev/EventSourcing.html)

**Established fact.** Microsoft’s architecture guidance describes:

- an append-only event store as system of record;
- current-state rehydration by replay;
- optimistic concurrency through expected stream position, followed by reload, reevaluation, and retry;
- compensating events rather than rewriting authoritative history;
- idempotent consumers because delivery is typically at least once.

Pinned source:

- [Event store and rehydration, lines 28–36](https://github.com/microsoftdocs/architecture-center/blob/0f26b91205beba357b3498f05151b22a2ec25c4b/docs/patterns/event-sourcing.md#L28-L36)
- [Optimistic concurrency and compensation, lines 68–86](https://github.com/microsoftdocs/architecture-center/blob/0f26b91205beba357b3498f05151b22a2ec25c4b/docs/patterns/event-sourcing.md#L68-L86)
- [History correction and idempotency, lines 91–139](https://github.com/microsoftdocs/architecture-center/blob/0f26b91205beba357b3498f05151b22a2ec25c4b/docs/patterns/event-sourcing.md#L91-L139)

### Snapshots

**Established fact.** In an event-sourced system, a snapshot serializes entity state at one stream position so replay can begin there. It is an optimization, not a replacement for the authoritative event stream:

- [Microsoft Event Sourcing guidance, lines 128–131](https://github.com/microsoftdocs/architecture-center/blob/0f26b91205beba357b3498f05151b22a2ec25c4b/docs/patterns/event-sourcing.md#L128-L131)

A non-event-sourced snapshot store is different: the latest snapshot is authoritative, and past intent/history is absent unless separately retained.

### Rollback

- **Immutable root:** restore or retain an old root, provided no shared descendant was mutated.
- **STM:** discard speculative Ref writes; external effects remain outside rollback.
- **Event sourcing:** normally append a compensating event. Removing or rewriting old events undermines the log’s audit semantics.
- **Snapshot recovery:** restores state at a point, but does not reverse effects already performed after that point.
- **Mutable graph:** requires a complete inverse log, copy, transaction-aware data structure, or application compensation.

### Fit for one lane

**Inference.** A serialized lane naturally establishes event order but does not itself justify event sourcing. Event sourcing is appropriate when the event sequence must be durable and authoritative. If the requirement is only coherent latest-state reads and restart recovery, periodic/current snapshots or ordinary database state are simpler.

---

## 8. Extension and plugin composition

### Slice reducers

**Established fact.** Redux’s `combineReducers` composes slice reducers. Each receives its owned slice and the same action, and their results are assembled into one state object:

- [Redux `combineReducers`, pinned lines 12–29](https://github.com/reduxjs/redux/blob/2d5498d1c302f8a6691a9564b3b25cf50b7e176b/docs/usage/structuring-reducers/UsingCombineReducers.md#L12-L29)

Redux also documents dynamic reducer replacement/injection:

- [Redux code splitting, pinned lines 10–35](https://github.com/reduxjs/redux/blob/2d5498d1c302f8a6691a9564b3b25cf50b7e176b/docs/usage/CodeSplitting.md#L10-L35)

### Generic Lisp composition options

1. **Namespaced slices and reducer registry**
   - State is a map from qualified plugin identity to plugin-owned immutable value.
   - The owner snapshots the reducer registry for one command.
   - Each plugin reducer returns a new slice and effects.
   - Root validation runs before installation.

   This gives strong isolation but requires collision-free keys, deterministic reducer order, versioned slice schemas, install/uninstall policy, and efficient persistent maps.

2. **Targeted reducer dispatch**
   - Commands identify one reducer or a declared set.
   - Avoids invoking every extension on every command.
   - Cross-slice commands require an explicit coordinator.

3. **Ordered transition middleware**
   - Plugins transform a transition context in sequence.
   - More flexible, but order becomes semantics and one plugin can invalidate another’s assumptions.

4. **Open polymorphic action functions**
   - Clojure Agents demonstrate that an open function/multimethod action set can be extensible.
   - This is behavior extensibility, not automatic state-schema composition.

5. **Event subscribers**
   - Plugins derive independent projections or integrations from durable events.
   - Strong decoupling, but event schemas become long-lived public contracts and delivery is usually at least once.

6. **Private mutable plugin components**
   - Each plugin owns mutable data reachable only through owner-lane capabilities.
   - Integrates well with foreign resources and specialized mutable structures.
   - Whole-application rollback and coherent snapshots become harder.

**Inference.** Dynamic registration, removal, migration, and reducer replacement should themselves occur on the command lane. One command should use one coherent registry generation; otherwise a queued command could combine transition code from incompatible plugin generations.

---

## 9. When owner-confined mutation is preferable

**Established fact.** Clojure’s persistent collections themselves use hidden mutation while constructing newly allocated internal nodes, then publish them for immutable use. Clojure Transients extend this optimization to isolated construction and explicitly require thread isolation:

- [Clojure Transients, lines 21–40](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/reference/transients.adoc#L21-L40)
- [Thread isolation, lines 69–73](https://github.com/clojure/clojure-site/blob/7f50046bb123933674e6fd6d6ddc627f70cb5c5a/content/reference/transients.adoc#L69-L73)

Owner-confined mutable internals are preferable when one or more apply:

- no efficient persistent representation is available;
- state contains large arrays, indexes, caches, queues, foreign objects, ports, or library-owned objects;
- update frequency would make whole-container copying prohibitive;
- state is never exposed directly and all mutation truly passes through one owner;
- partial-failure semantics are acceptable or an explicit local journal supplies rollback;
- detached snapshots can be built cheaply enough for readers;
- mutation is an implementation optimization beneath a functional public boundary.

They are not preferable merely because mutation is familiar. Required safeguards are:

- one unforgeable owner capability;
- no mutable aliases in commands, completions, snapshots, or plugin APIs;
- deterministic post-failure policy;
- snapshot construction on the owner lane or under synchronization;
- explicit resource cleanup;
- tests proving off-lane access rejection and alias isolation.

---

## 10. Comparison for this repository’s serialized runtime

### Current behavior and constraints

**Established repository fact.**

- `CommandRuntime` currently owns only inbox, mutex, lifecycle state, and thread—not application state: `tuna/lib/runtime.ss:21-31`.
- It creates a positive-capacity bounded channel: `tuna/lib/runtime.ss:39-46`.
- One worker executes requests sequentially: `tuna/lib/runtime.ss:105-117`.
- Submission is immediate and returns `accepted`, `full`, or `not-running`: `tuna/lib/runtime.ss:154-172`.
- Payload ownership transfers by reference and relies on a no-mutation contract: `tuna/lib/runtime.ss:141-152`.
- Action exceptions are returned through completions and the worker continues: `tuna/lib/runtime.ss:65-85`; tested at `tuna/test/command-runtime-test.ss:162-170`.
- There is no transactional rollback: `tuna/README.md:115-128`.
- Tests attest non-overlap and per-producer order: `tuna/test/command-runtime-test.ss:195-216`.
- Direct action APIs can bypass the lane, so owner confinement is not currently enforceable for future application state: `research/tuna-current-state-boundary.md:116-123`.

Gerbil-specific constraints:

- classes and structs expose mutators; `final: #t` does not make fields immutable: `gerbil-dev/doc/guide/intro.md:431-465,548-616`;
- no installed standard persistent Hash Array Mapped Trie (HAMT) API was found; SRFI 146 sources are only under `gerbil-dev/src/v0.19-WIP/v0.19-TODIE-std/srfi/146/`;
- shallow copies preserve nested references, so they do not establish snapshot isolation: `research/gerbil-host-neutral-state-mechanisms.md:192-217`;
- immutable-root handoff is O(1) only by convention and only when the full reachable graph is immutable: `research/gerbil-host-neutral-state-mechanisms.md:194-198`.

### Comparative fit

| Approach | Fit with one lane | Failure/rollback | Extension fit | Main cost |
|---|---|---|---|---|
| Immutable reducer root | Excellent conceptual fit | Failed candidate can be discarded; effects cannot | Namespaced slices and composed reducers | Persistent representation unavailable by default |
| Explicit state machine | Excellent for lifecycle/protocol state | Same as reducer | Events and states form explicit contracts | More schema and transition ceremony |
| One Clojure-style Atom | Redundant for owner writes | Validator/CAS protects one root; retry requires purity | Simple shared identity | Retry/effect hazards; Gerbil differs |
| Ref/STM | Usually unnecessary | Atomic multi-Ref rollback and retries | Independent coordinated references | Complexity with no internal concurrency benefit |
| Agent | Duplicates owner queue | Per-agent action/error semantics | Open action functions | Async completion and cross-agent coordination |
| Event sourcing | Good only with durability/audit need | Compensating events, replay | Durable subscriber/projection contracts | Schema evolution, replay, storage, idempotency |
| Owner-confined mutable graph | Practical Gerbil option | Partial mutation survives exceptions | Private plugin resources | Snapshot isolation and rollback burden |

### Materially different implementation directions

1. **Pure immutable root**
   - Best rollback and testing semantics.
   - Requires immutable-use discipline, manual structural sharing, small functional structures, or a vetted persistent-collection dependency.

2. **Owner-confined mutable authority plus immutable snapshots**
   - Best compatibility with current Gerbil representations and mutable libraries.
   - Failed commands may partially mutate; publication must not silently lag authoritative state.

3. **Hybrid**
   - Immutable/revisioned domain root for decisions and publication.
   - Mutable owner-confined caches, indexes, and resource handles treated as derived or effect-layer state.
   - Often provides the cleanest practical boundary: only the value root participates in reducer semantics.

4. **Event-sourced core**
   - Pure command decider returns events; pure event reducer derives state.
   - Appropriate only if the event log’s durable history is itself a requirement.

---

## 11. Review findings and residual risks

- **High — `tuna/lib/runtime.ss:21-31,65-85`: no application-state or transition bridge exists.** Current actions return arbitrary results and can mutate captured state or external resources before failing.

- **High — `tuna/lib/bindings.ss:247-258,385-446`: owner confinement is bypassable.** Public direct invocation and live-value mutation can occur outside the command lane.

- **High — `gerbil-dev/src/v0.19-WIP/v0.19-TODIE-std/srfi/146/`: supported persistent maps are unavailable.** An immutable extensible root needs a dependency, small functional structures, manual path reconstruction, or copying.

- **High — external effects remain nontransactional under every in-memory option.** Pure transitions can discard candidate state but cannot undo files, processes, or network operations.

- **Medium — `gerbil-dev/src/std/sync/atom.ss:16-18,38-54`: Gerbil Atom is not Clojure Atom.** It currently runs transformations once under a mutex, invokes watches under that mutex after assignment, and exposes an unsynchronized dereference accessor.

- **Medium — structural sharing can retain memory.** Long-lived snapshots, undo roots, subscriber closures, and queued payloads can retain old versions; no bounded-history policy currently exists.

- **Medium — plugin lifecycle is undefined.** Reducer registration ordering, state initialization, schema migration, unload, failed initialization, and queued-command behavior across replacement require explicit contracts.

- **Medium — effects need idempotency and recovery semantics.** A crash between state commit and effect completion otherwise creates ambiguity.

- **Medium — mutable snapshot construction is host-dependent.** Shallow copying preserves aliases; deep serialization is O(reachable graph size) and excludes some objects.

- **Low — `command-runtime-state` already names lifecycle state:** `tuna/lib/runtime.ss:51-63`. Application-state terminology should avoid this collision.

**Confidence:** High for the cited Clojure, Redux, Elm, Erlang, event-sourcing, Gerbil, and current Tuna semantics; medium-high for the comparative conclusions; medium for memory/performance fit until representative state shapes are measured.

---

## 12. Validation

No project tests were run during this read-only research.

### Focused current-runtime validation

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test/run-command-runtime-matrix.sh
```

This runs source `gxi`, normal `gxc`, and `gxc -O`, then verifies unchanged worktree status:

- `tuna/test/run-command-runtime-matrix.sh:29-94`

Focused synchronization primitives:

```sh
cd /home/jay/Code/workbench-gerbil
gerbil test -g \
  gerbil-dev/src/std/sync/atom-test.ss \
  gerbil-dev/src/std/sync/channel-test.ss \
  gerbil-dev/src/std/sync/completion-test.ss
```

### Full repository-supported validation after state work exists

```sh
cd /home/jay/Code/workbench-gerbil/tuna
gerbil build
gerbil test test/command-runtime-test.ss
test/run-command-runtime-matrix.sh

cd /home/jay/Code/workbench-gerbil/packages/dummy
GERBIL_PATH="$PWD/../../tuna/.gerbil" \
GERBIL_LOADPATH= \
gerbil build
```

If Gerbil primitives themselves change:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil-dev
make check
# Documented alternative:
./build.sh env gerbil test ./...
```

The recursive test command is documented at `gerbil-dev/doc/reference/dev/test.md:17-25`; upstream contribution validation is documented at `gerbil-dev/CONTRIBUTING.md:182-190`.