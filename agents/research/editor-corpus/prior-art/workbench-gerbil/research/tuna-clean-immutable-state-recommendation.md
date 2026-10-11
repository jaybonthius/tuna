# Tuna immutable state recommendation

## Decision

**Adopt one runtime-owned immutable application root with pure, application-supplied transitions.**

Use this semantic model:

```text
Root = (revision, opaque-application-value)

transition(old-value, command)
  -> unchanged(result)
   | changed(candidate-value, result)
   | reject(error)
```

Tuna should:

1. serialize transitions on the existing command lane;
2. leave the current root untouched while calculating and validating a candidate;
3. atomically install one new `(revision, value)` root only for `changed`;
4. publish nonblocking invalidations after installation;
5. complete the command after publication.

A rejected or raised transition leaves both value and revision unchanged. An unchanged command should not advance Tuna’s revision: Tuna’s revision is a latest-state invalidation token, not Datomic transaction time.

Do **not** add a fact database, durable log, event sourcing, Software Transactional Memory (STM), or a general transaction manager now. Keep mutable caches, resource handles, and effect machinery outside the authoritative value root and application-supplied.

## Is “each change creates a new application state” correct?

**Yes, if stated precisely:**

> Each successful semantic state change publishes one new complete application value. The previous value is not mutated.

It does **not** mean:

- every command succeeds or changes state;
- every field update is separately observable;
- reads create states;
- a new value is necessarily a full physical copy;
- Tuna retains every old value;
- immutable roots provide durable history, undo, branching, or external-effect rollback;
- files, processes, services, threads, and resource handles are part of the rollback boundary.

Datomic itself publishes one successor database value per complete successful transaction, not per datom; failed transactions leave the database unchanged (`research/datomic-state-model-lessons.md:270-302`). Persistent structures may share unchanged immutable subtrees (`research/datomic-state-model-lessons.md:304-331`).

## What Datomic actually contributes

Datomic contributes two distinct things.

### Transferable state semantics

- stable identity associated with successive immutable values;
- pure candidate calculation (`d/with`);
- one serialized commit order;
- explicit `db-before` and `db-after`;
- validation before publication;
- atomic publication of one complete value;
- transaction functions that must be pure;
- separation of database commit from external effects.

Evidence: `research/datomic-state-model-lessons.md:31-70,120-159,173-204,206-228`.

These principles directly support Tuna’s immutable-root model.

### Database facilities Tuna does not obtain from immutability

- entity/attribute/value/transaction facts and retractions;
- durable chronological transaction log;
- transaction identities and provenance;
- schema types, cardinality, uniqueness, and entity identity;
- persistent indexes;
- `as-of`, `since`, history, and log queries;
- durable atomic writes, recovery, backup, and distributed synchronization;
- Atomicity, Consistency, Isolation, and Durability (ACID) guarantees.

Evidence: `research/datomic-state-model-lessons.md:72-118,230-268,374-386`.

An in-memory root replacement is therefore **Datomic-like only in its before/candidate/after semantics**. It is not a database.

Authoritative references:

- [Clojure, Values and Change](https://clojure.org/about/state)
- [Datomic transaction model](https://docs.datomic.com/transactions/model.html)
- [Datomic ACID guarantees](https://docs.datomic.com/transactions/acid.html)
- [Datomic transaction functions](https://docs.datomic.com/transactions/transaction-functions.html)
- [Datomic database filters and history](https://docs.datomic.com/reference/filters.html)
- [Datomic log API](https://docs.datomic.com/reference/log.html)

## Architecture comparison

For this comparison, a **transactional adapter** means an application-supplied `begin/prepare/validate/commit/abort/snapshot` interface that may wrap mutable storage or a durable database.

| Model | Rollback | External effects | Plugins and schema | Gerbil v19 and performance | Migration |
|---|---|---|---|---|---|
| **Immutable root with pure transitions** | Strong pre-commit discard: exception or rejection leaves the installed root unchanged. No automatic post-commit undo. | Forbidden during transition; application runs them after commit and feeds outcomes back as later commands. | Tuna sees an opaque value. Application owns command vocabulary, invariants, fragment layout, and plugin composition. Pure plugin transitions receive values, not mutation authority. | Feasible by contract. Root reads are O(1); updates range from path-sized structural sharing to O(n) copying. No supported installed persistent map exists. | Best now because Tuna has no application-state implementation or persisted state to migrate. Can later place a database value behind the same opaque boundary. |
| **Immutable database-like facts/log** | Failed database transactions abort. Historical reads and corrective transactions are possible; external effects still do not roll back. | Requires application delivery, idempotency, or compensation outside the database. | Fact, schema, transaction, and event shapes become long-lived shared contracts. Plugin evolution requires schema and historical-data migration. | Requires a real database or substantial indexing, storage, query, and retention machinery. Highest fixed cost. | Expensive: application state and commands must be remodeled as facts or events, with durable evolution rules. |
| **Transactional adapter** | Only as strong as the adapter. Cross-adapter atomicity is undefined; abort may be impossible after a native commit. | Atomic only when an effect belongs to the same transactional resource. Arbitrary effects remain outside. | Representation stays opaque, but Tuna becomes coupled to adapter lifecycle, commit failures, snapshot basis, and capability rules. Plugin transactions need composition semantics. | Implementable, but correctness and blocking costs are application-specific. A slow commit stalls the one owner lane. | Useful future escape hatch for an application already backed by transactional storage, but premature as Tuna’s default contract. |
| **Mutable owner-confined state with immutable snapshots** | A command may partially mutate before raising. Tuna must publish the partial result or fail the owner; it cannot simply discard it. | Not rolled back. | Easy integration with mutable libraries and resources, but plugins receive dangerous mutation authority and alias discipline becomes harder. | Cheapest writes. Safe snapshot construction may be O(n), and shallow copies do not isolate nested data. | Read-side snapshots can remain stable, but later conversion to pure transitions changes failure and plugin-authority semantics. |

Supporting comparisons: `research/functional-application-state-patterns.md:428-457` and `research/gerbil-immutable-state-feasibility.md:303-311`.

## Why this is cleaner than the prior mutable-first recommendation

The prior recommendation selected mutable owner-confined authority plus detached snapshots (`research/tuna-host-neutral-state-architecture.md:3-18,94-119`). That remains a practical application-specific fallback, but it is not the cleanest default state contract.

It creates two representations of truth:

1. a private mutable graph;
2. a separately constructed immutable snapshot.

That introduces unavoidable questions after every partial failure:

- Did mutation occur before the exception?
- Can a coherent snapshot still be constructed?
- Must partial state be published?
- If snapshot construction also fails, must the owner terminate?
- Did any snapshot retain a mutable alias?

Those problems are explicit in the prior invariants and gates (`research/tuna-host-neutral-state-architecture.md:128-157,263-280`).

With an immutable root, the authoritative value **is also the readable snapshot**. Candidate failure simply discards an unpublished value. There is no post-failure snapshot repair protocol and plugins need not receive mutation capabilities.

The lack of a built-in Gerbil persistent map is a representation/performance constraint, not a reason for Tuna to promise weaker failure semantics. Tuna can stay schema-neutral by requiring the application to supply an opaque immutable-by-contract value.

## Minimal Tuna contract

### Tuna owns

- one state identity per runtime instance;
- one current `(revision, opaque-value)` root;
- one serialized transition/commit lane;
- a dedicated state-transition action seam distinct from existing ordinary actions;
- dequeue-time transition resolution and coherent action generation;
- transition-outcome shape validation;
- atomic root installation under a private mutex;
- coherent root reads;
- capacity-one, nonblocking invalidation channels;
- install → invalidate → completion ordering;
- lifecycle and subscriber closure.

Revision and value must be one published object. Gambit declares unsynchronized concurrent store reads/writes erroneous, so a private mutex-protected cell is clearer than raw `atom-deref` (`research/gerbil-immutable-state-feasibility.md:141-188`; authoritative Gambit source `gerbil-dev/src/gambit/doc/gambit.txi:10045-10053`).

### The application supplies

- the initial immutable value;
- state-transition functions and command vocabulary;
- complete validation and domain invariants;
- the concrete immutable representation, copying, or structural-sharing strategy;
- explicit `changed` versus `unchanged` outcomes;
- state schema, identities, qualified plugin fragments, and cross-fragment coordination;
- plugin initialization, replacement, unload, and state-schema migration;
- external resource handles, caches, indexes, and cleanup;
- effect descriptions, execution, retry, idempotency, and compensation policy;
- persistence, durable history, audit, undo, and recovery if required;
- snapshot retention limits and performance budgets.

Tuna must not deep-copy arbitrary Gerbil objects, infer equality using `equal?`, prescribe a top-level map, or retain old roots as history.

### Effects

The first state slice should contain **no generic effects engine**. State transitions must not perform input/output or mutate external resources. If a command needs work performed:

1. commit state describing the request if appropriate;
2. return an application-defined result or intent;
3. perform the effect outside the pure transition;
4. submit success or failure as a later command.

No in-memory architecture can atomically combine a heap-root replacement with arbitrary external effects (`research/functional-application-state-patterns.md:244-281`; `research/gerbil-immutable-state-feasibility.md:262-280`).

## Plugin extensibility without Tuna schema coupling

Use a separate state-capable action class whose semantic signature is:

```text
(old-opaque-value, arguments)
  -> unchanged(result)
   | changed(new-opaque-value, result)
   | reject(error)
```

Ordinary actions retain their current arity and behavior. Direct ordinary invocation must not gain application-state authority.

An application may implement qualified plugin slices, targeted dispatch, custom persistent structures, or a single domain aggregate. Tuna should not define those layouts. Registration, removal, and transition-definition replacement should be ordered on the command lane so one command sees one coherent plugin generation.

Evidence:

- existing actions receive only explicit arguments and may be invoked directly: `tuna/lib/bindings.ss:247-258`;
- current dispatch resolves actions at dequeue: `tuna/lib/runtime.ss:65-85`;
- the bridge is currently absent: `research/tuna-current-state-boundary.md:34-42,116-123`;
- application-supplied adapters and fragment options: `research/gerbil-immutable-state-feasibility.md:219-260`.

## Gerbil v19 feasibility and cost

A new-root design is feasible, but Gerbil does not enforce transitive immutability (`research/gerbil-immutable-state-feasibility.md:3-17`).

Constraints:

- lists and alists are mutable despite functional update helpers;
- vectors and hash tables require shallow O(n) copies;
- structs/classes expose mutators; `final: #t` does not freeze them;
- shallow vector/hash/struct copies retain nested aliases;
- no supported installed persistent Hash Array Mapped Trie (HAMT), persistent set, or persistent vector exists.

Evidence: `research/gerbil-immutable-state-feasibility.md:27-98,118-139`.

Expected costs:

- immutable root handoff/read: O(1);
- alist lookup/update: generally O(n), with some suffix sharing;
- vector/hash copy-on-write: O(n) for each copied container;
- custom structural sharing: proportional to changed paths, provided all shared descendants are immutable;
- old-root retention: keeps reachable old nodes live;
- unbounded history: unbounded memory.

Gambit’s authoritative garbage-collection documentation confirms that pairs, vectors, records, and closures hold strong references and remain live while reachable: `gerbil-dev/src/gambit/doc/gambit.txi:9224-9241`.

Mutable owner-confined caches and resource handles remain reasonable **outside** the authoritative root. If an application cannot represent its decision-relevant state immutably within its measured budget, that application should choose an explicit adapter or mutable model rather than weakening Tuna’s default guarantee silently.

## Current behavior and migration

Tuna currently has no application-state root:

- `CommandRuntime` contains only inbox, mutex, lifecycle state, and thread: `tuna/lib/runtime.ss:21-31`.
- One worker invokes actions sequentially and catches ordinary failures: `tuna/lib/runtime.ss:65-117`.
- Submission remains bounded and nonblocking: `tuna/lib/runtime.ss:141-172`.
- Direct action and live-value APIs bypass the command lane: `tuna/lib/bindings.ss:247-258,385-446`.
- A failed ordinary action may leave mutations or effects behind: `research/tuna-current-state-boundary.md:55-63`.

Therefore migration is currently cheap: introduce a separate state-transition path without changing existing ordinary action arity, return meaning, direct invocation, bounded admission, dequeue-time lookup, or shutdown behavior. There is no existing application state or persisted schema to convert.

The roadmap correctly blocks state publication until an approved state contract exists and explicitly describes invalidation as coalesced latest-state notification rather than a durable log (`plans/emacsen-runtime/checklist.md:276-286,387-400`).

## Disposable experiments and hard stop gates

Do not implement the production state slice until all experiments pass.

### 1. Pure-transition and alias experiment

Use nested lists, vectors, hashes, structs, and boxes to verify:

- a raised transition leaves root identity and revision unchanged;
- `unchanged` does not increment revision;
- a committed candidate cannot mutate an older root through a shared descendant;
- later mutation of command payloads cannot alter installed state.

**Stop if:** safety requires Tuna to understand or deep-copy application fields, or an application cannot guarantee transitive immutability.

### 2. State-action bridge experiment

Prototype only the dedicated state-transition action seam. Verify:

- ordinary action arity and result semantics remain unchanged;
- transition resolution remains at dequeue;
- two runtime instances using the same transition definition retain independent roots;
- direct invocation cannot install state;
- no process-global closure captures a runtime state object;
- off-lane installation is impossible.

**Stop if:** existing action contracts change, state becomes ambient, or state authority escapes the owner.

### 3. Publication experiment

With opaque immutable fixtures, prove:

- revision and value are always read coherently;
- subscribe-plus-initial-read has no missed-wakeup gap;
- full capacity-one subscriber channels never block commit;
- unsubscribe and shutdown races are deterministic;
- installation precedes invalidation and completion.

**Stop if:** any reader observes a mixed root, publication blocks on a consumer, or raw `atom-deref` is required.

### 4. Effects experiment

Use a sentinel effect to prove transition calculation performs no effect. Commit first, execute the application effect separately, and return success/failure through a later command.

**Stop if:** required semantics depend on an arbitrary effect being atomic with the in-memory commit. That requirement needs application-specific transactional storage, not a stronger claim from Tuna.

### 5. Representative cost and retention experiment

The first real application must provide representative state size, update distribution, snapshot lifetime, and explicit latency/allocation budgets. Measure full copy, application-selected structural sharing, and bounded retained roots using Gambit garbage-collection reports.

**Stop if:** no budget is supplied, immutable updates exceed it, aliases cannot be controlled, or old roots are retained without a bound. Only then compare an application-specific transactional adapter or mutable owner-confined fallback.

Run every experiment under source `gxi`, normal `gxc`, and `gxc -O`.

## Validation commands

No behavior tests were run during this read-only recommendation.

Focused current baseline:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test/run-command-runtime-matrix.sh
```

The matrix runs source `gxi`, normal `gxc`, and `gxc -O`, then verifies unchanged worktree status: `tuna/test/run-command-runtime-matrix.sh:29-94`.

Relevant synchronization primitives:

```sh
cd /home/jay/Code/workbench-gerbil
gerbil test -g \
  gerbil-dev/src/std/sync/atom-test.ss \
  gerbil-dev/src/std/sync/channel-test.ss \
  gerbil-dev/src/std/sync/completion-test.ss
```

Full project-supported validation after implementation:

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

If Gerbil synchronization code changes:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil-dev
make check
# documented alternative:
./build.sh env gerbil test ./...
```

Evidence: `research/tuna-host-neutral-state-architecture.md:287-329` and `gerbil-dev/doc/reference/dev/test.md:17-25`.

## Review findings

- **Blocker — `tuna/lib/runtime.ss:21-31,65-85`:** Tuna has no application root or state-transition bridge. Production state work must not begin by changing ordinary action return semantics.
- **High — `tuna/lib/bindings.ss:247-258,385-446`:** public direct action/value APIs can bypass the serialized lane; they must never receive installation authority.
- **High — `research/gerbil-immutable-state-feasibility.md:27-139,313-318`:** Gerbil v19 cannot enforce transitive immutability, and shallow copies retain aliases.
- **High — `research/functional-application-state-patterns.md:268-281`:** no proposed in-memory model rolls back arbitrary external effects.
- **Medium — `research/gerbil-immutable-state-feasibility.md:282-301`:** retained roots can cause substantial memory retention; Tuna must not retain history by default.
- **Medium — `research/tuna-current-state-boundary.md:116-128`:** subscriber lifecycle, action bridging, and publication ordering remain unimplemented and untested.
- **Medium — `plans/emacsen-runtime/checklist.md:276-286`:** state publication remains gated on a concrete approved state contract.
- **Low — `tuna/lib/runtime.ss:51-63`:** `command-runtime-state` already names runtime lifecycle; application-root terminology must not reuse it.

## Residual risks and confidence

- **High:** transition purity and transitive immutability remain contractual; arbitrary Gerbil extension code can violate them.
- **High:** effect crash recovery remains application-specific.
- **Medium:** representative application performance is unknown because no concrete state shape exists.
- **Medium:** plugin initialization, migration, and unload semantics remain application-supplied and untested.
- **Medium:** the current installed Gerbil runtime and checkout differ by one development commit, although inspected relevant files matched.
- **Low:** Tuna’s nested checkout is clean at `806ece2dfd58c1ddd121e19f5b359f27a40a0e73`; the enclosing workbench already contains unrelated unstaged and untracked paths.

**Confidence:** High that immutable-root semantics are the cleanest application-agnostic contract; high on current Tuna and Datomic behavior; high that Gerbil v19 can implement the protocol by convention; medium on cost until a representative application passes the hard gate.