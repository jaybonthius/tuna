# Datomic state-model lessons for Tuna

## Concise answer

Datomic separates a stable **identity** from the immutable **values** that represent its state over time. A database connection is a reference-like identity; each successful transaction associates it with a new immutable database value. A transaction does not imperatively edit that value: transaction data declares an unordered set of additions and retractions, transaction functions derive more data from `db-before`, validation considers the complete candidate, and one serialized commit publishes `db-after` atomically.

“Every change creates a new app state” is accurate only with qualifications:

- one **successful transaction**, not each datom inside it, creates one successor database value;
- a failed transaction leaves the current database value unchanged;
- reads create no state;
- the statement concerns database state, not arbitrary process state or external effects;
- “new value” does not imply a full physical copy—persistent data structures can reuse unchanged immutable structure;
- retaining immutable values permits old-state reads, but does not itself provide durable history, branching, undo, or external-effect rollback.

The transferable core for an in-process extensible Gerbil application is the identity/value separation, immutable-by-contract snapshots, one serialized commit boundary, explicit before/after values, pure validation/transformation, atomic root publication, and effects kept outside candidate-state calculation. Datomic’s durable datom log, global transaction time, indexes, distributed reads, synchronization, database schema, audit retention, and ACID durability are database facilities, not consequences of immutable application snapshots.

Current Tuna has only the serialized command lane. It has no application state, immutable transition contract, publication root, history, or rollback. Existing Tuna research currently favors owner-confined mutable state with detached immutable snapshots, while an older proposal favored immutable state transitions. Datomic clarifies the semantic difference but does not resolve that existing choice.

## 1. Identity, value, and state

The official Clojure design essay linked directly from Datomic’s transaction model supplies the clearest terminology:

> identity: “a stable logical entity associated with a series of different values over time”

and:

> “a value is something that doesn’t change”

It further defines an identity’s state as its value at a point in time and says an apparent change means associating the identity with a different state value.

Sources:

- [Clojure, “Values and Change,” § Working Models and Identity](https://clojure.org/about/state#_working_models_and_identity)
- [Clojure, “Values and Change,” § Clojure programming](https://clojure.org/about/state#_clojure_programming)
- [Datomic Transaction Model, § d/with and d/transact](https://docs.datomic.com/transactions/model.html#with-and-transact)

In Datomic this appears at two levels:

1. **Database identity versus database values.** A connection acts as the durable reference whose successive states are immutable database values. Datomic describes `d/transact` as `d/with` composed with a durable swap.
2. **Entity identity versus point-in-time entity state.** Every entity has a database-unique entity ID assigned by the transactor that “never change[s].” The effective attributes associated with that ID can differ across database values.

Sources:

- [Identity and Uniqueness, § Entities](https://docs.datomic.com/schema/identity.html#entities)
- [Transaction Data, § Entity ids](https://docs.datomic.com/transactions/transaction-data-reference.html#eid)
- [Database Filters, § history](https://docs.datomic.com/reference/filters.html#history), which says an entity is a point-in-time view.

This is not the same as saying an identity is itself immutable data. The identity/reference is the stable rendezvous point; the values associated with it are immutable.

## 2. Immutable database values and datoms

### Database values

Datomic defines a database as information rather than mutable places:

> “A database is not a set of places that get updated.”

A database value accrues information via transactions and is immutable. `d/with` is the pure operation that takes a database value and transaction data and returns a successor value; `d/transact` adds durable publication.

Sources:

- [Transaction Model, § It’s All About Information](https://docs.datomic.com/transactions/model.html#about-info)
- [Transaction Model, § d/with and d/transact](https://docs.datomic.com/transactions/model.html#with-and-transact)
- [`d/with` Peer API](https://docs.datomic.com/clojure/index.html#datomic.api/with)
- [Client `with`](https://docs.datomic.com/client-api/datomic.client.api.html#var-with), which explicitly says the durable database is unaffected.

A database value is therefore a stable snapshot, not a live view that changes in hand. The Peer API’s `d/db` retrieves a value for reading without communicating with the transactor or blocking:

- [`d/db` Peer API](https://docs.datomic.com/clojure/index.html#datomic.api/db)

### Datoms

A datom is Datomic’s atomic fact. Its full shape is:

```text
entity, attribute, value, transaction, added?
E       A          V      Tx           boolean
```

- `added? = true` records an assertion.
- `added? = false` records a retraction.
- `Tx` identifies the transaction entity that established the fact or retraction.

Sources:

- [Datomic Overview, § Information Model](https://docs.datomic.com/datomic-overview.html#information-model)
- [Transaction Data, § Assert and Retract](https://docs.datomic.com/transactions/transaction-data-reference.html#list-forms)
- [Transaction Data, § Reified Transactions](https://docs.datomic.com/transactions/transaction-data-reference.html#reified-txes)

Before transaction processing, the author writes forms such as:

```clojure
[:db/add e a v]
[:db/retract e a v]
```

The transaction ID is assigned during processing. Transaction data is syntactically ordered for author convenience but semantically an unordered set:

- [Transaction Data, § Transaction Data](https://docs.datomic.com/transactions/transaction-data-reference.html#tx-data)

### Append-only does not mean “everything stays currently true”

A retraction is new information saying an earlier E/A/V assertion is no longer true. It does not overwrite or erase the earlier assertion. For a cardinality-one attribute, asserting a replacement automatically creates the necessary retraction of the old current value.

Sources:

- [Client Tutorial, Retract, § Explicit Retract](https://docs.datomic.com/client-tutorial/retract.html#explicit-retract)
- [Client Tutorial, Retract, § Implicit Retract](https://docs.datomic.com/client-tutorial/retract.html#implicit-retract)
- [Datomic Overview, § Log](https://docs.datomic.com/datomic-overview.html#log)

Thus:

- the normal database view exposes current effective facts;
- the history view exposes present and past additions and retractions;
- the durable log remains chronological and indelible under the default model.

Datomic has specialized retention/excision facilities, so “nothing is ever removed” describes the core information model rather than every optional administrative policy.

## 3. Serialized processing, atomicity, and before/after values

### One write order

The transactor queues transactions and processes them serially:

- [Processing Transactions, § Processing Transactions](https://docs.datomic.com/transactions/transaction-processing.html#processing-transactions)

Datomic’s overview makes the tradeoff explicit: because transactions are totally serialized, only one transaction can occur at a time for a database:

- [Datomic Overview, § Tradeoffs](https://docs.datomic.com/datomic-overview.html#tradeoffs)

Serialization supplies a total write order and ensures that every successful transaction has a definite immediate predecessor.

### `db-before` and `db-after`

The transaction result contains:

- `db-before`: complete database value immediately before the transaction;
- `db-after`: complete database value after it;
- `tx-data`: resulting assertion/retraction datoms;
- `tempids`: resolved temporary identities.

Sources:

- [Processing Transactions, § Monitoring Transactions](https://docs.datomic.com/transactions/transaction-processing.html#monitoring-transactions)
- [`d/with` Peer API](https://docs.datomic.com/clojure/index.html#datomic.api/with)

The transaction model says any particular database value is the product of its immediate predecessor plus one complete transaction. There are no supported mid-transaction database states or smaller published effects:

- [Transaction Model, § d/with and d/transact](https://docs.datomic.com/transactions/model.html#with-and-transact)
- [Transaction Model, § Why Do Things This Way?](https://docs.datomic.com/transactions/model.html#why)

### Atomicity

Datomic’s atomicity guarantee is “all or nothing”: if one part fails, the entire transaction fails and the database is unchanged. Durable storage receives one atomic write; a peer updates its in-memory database pointer in one atomic operation.

- [ACID, § Atomicity](https://docs.datomic.com/transactions/acid.html#atomicity)

This is stronger than merely executing handlers one at a time. A serialized imperative handler can mutate several objects and then fail, leaving partial state. Atomicity additionally requires that no candidate be published unless the whole candidate is valid.

### Consistency and isolation

Datomic validates complete database values, including schema and application constraints. Transaction functions inspect `db-before`; entity predicates can validate `db-after`.

- [ACID, § Consistency](https://docs.datomic.com/transactions/acid.html#consistency)
- [Transaction Model, § Application Correctness](https://docs.datomic.com/transactions/model.html#app-correctness)

Writes are strongly serializable. Reads on one peer are monotonic; reads across peers remain serializable but can lag, and `sync` can establish a required basis.

- [ACID, § Isolation](https://docs.datomic.com/transactions/acid.html#isolation)
- [Synchronization, §§ Background, Sync, Comparison to As-Of](https://docs.datomic.com/transactions/client-synchronization.html)

## 4. Transaction functions

A transaction function has the semantic shape:

```text
[db-before, args] -> tx-data
```

It does not receive a mutable database, the whole transaction, or another transaction function’s result. All functions see the same `db-before`; their returned data is combined with the rest of the transaction data before one complete validation/commit. This removes order semantics among transaction functions.

Sources:

- [Transaction Functions, § Transaction Function Semantics](https://docs.datomic.com/transactions/transaction-functions.html#semantics)
- [Transaction Model, § Application Correctness](https://docs.datomic.com/transactions/model.html#app-correctness)

The official writing requirements are explicit:

- pure and free of side effects;
- first argument is `db-before`;
- success returns transaction data;
- cancellation aborts the transaction.

Sources:

- [Transaction Functions, § Writing Transaction Functions](https://docs.datomic.com/transactions/transaction-functions.html#writing)
- [Transaction Functions, § Canceling a transaction](https://docs.datomic.com/transactions/transaction-functions.html#canceling)

They execute inside the serialized transaction pipeline. Slow code delays the current transaction and every transaction behind it, and arbitrary deployed code is a security concern:

- [Transaction Functions, § Performance and Security](https://docs.datomic.com/transactions/transaction-functions.html#performance-and-security)

A transaction function is therefore not a stored imperative procedure. It derives declarative transaction data from a known prior value.

## 5. Reads and effects

### Reads

An immutable database value can be shared freely among readers. Readers need no coordination with writers to keep an already-obtained value stable. Datomic emphasizes that immutable databases permit read scaling without reader coordination:

- [Datomic Overview, § Benefits](https://docs.datomic.com/datomic-overview.html#benefits)

A newly requested value may be recent rather than globally latest, especially across distributed callers, but it is complete and valid. Clients do not observe partial transactions:

- [Synchronization, § Background](https://docs.datomic.com/transactions/client-synchronization.html#background)

### Effects

The transaction model sharply limits the database effect: acceptance of one complete transaction data set. `d/with` is pure; `d/transact` adds the durable swap. Transaction functions must not perform side effects.

This means Datomic’s database transaction does **not** make arbitrary application effects atomic. Sending email, writing a file, calling another service, mutating a process-global cell, or controlling a device is outside the database-value transition. Datomic’s prohibition on transaction-function side effects avoids pretending those effects can be rolled back with the database.

A transaction timeout demonstrates another effect boundary: the caller may not know whether the transaction committed and must inspect a recent database value:

- [Processing Transactions, § Transaction Timeouts](https://docs.datomic.com/transactions/transaction-processing.html#transaction-timeouts)

For an in-process model, the transferable distinction is candidate-state calculation versus effect execution. Datomic does not supply a general external-effect transaction protocol.

## 6. History, log, and filters

These are distinct facilities:

| Facility | Meaning |
|---|---|
| Normal database value | Point-in-time current facts at one basis |
| `as-of` | Same database no later than a chosen transaction/time |
| `since` | Datoms added after a chosen point |
| `history` | Present plus unfiltered past, including retractions |
| Log / `tx-range` | Transactions in chronological order, optimized for time-range access |

Sources:

- [Database Filters](https://docs.datomic.com/reference/filters.html)
- [Database Filters, § as-of](https://docs.datomic.com/reference/filters.html#as-of)
- [Database Filters, § since](https://docs.datomic.com/reference/filters.html#since)
- [Database Filters, § history](https://docs.datomic.com/reference/filters.html#history)
- [Log API](https://docs.datomic.com/reference/log.html)
- [Log API, § tx-range](https://docs.datomic.com/reference/log.html#tx-range)

Important constraints:

1. A history database can expose several values for what a current entity view treats as one fact. An entity is point-in-time and cannot be constructed from a history database.
2. `as-of` is not a branch. Combining `with` and `as-of` can inspect a speculative value with recent facts filtered out, but does not create an alternative durable timeline.
3. A time-only “what happened?” question fits the log; an entity-at-time question fits indexes plus `as-of`.
4. Present reads do not scan all history and therefore do not inherently pay a query penalty proportional to retained history.

Sources:

- [Database Filters, § history](https://docs.datomic.com/reference/filters.html#history)
- [Database Filters, § as-of Is Not a Branch](https://docs.datomic.com/reference/filters.html#as-of-not-branch)
- [Database Filters, § The Present Pays No Penalty](https://docs.datomic.com/reference/filters.html#the-present-pays-no-penalty)
- [Database Filters, § Filter or Log?](https://docs.datomic.com/reference/filters.html#filter-or-log)

The Client tutorial explains the audit motivation: mistaken data should be corrected rather than silently deleted because other parties may already have acted on it.

- [Client Tutorial, History, § asOf Query](https://docs.datomic.com/client-tutorial/history.html#as-of-query)
- [Client Tutorial, History, § History Query](https://docs.datomic.com/client-tutorial/history.html#history-query)

## 7. Is “every change creates a new app state” accurate?

### Accurate reading

For Datomic database identity:

```text
db-before + one complete successful transaction -> db-after
```

Every successful transaction establishes a new time basis. Even if user-supplied datoms are redundant, the transaction itself has a new transaction-time fact:

- [Transaction Data, § Redundancy Elimination](https://docs.datomic.com/transactions/transaction-data-reference.html#redundancy-elimination)

There is no intermediate published state per datom. All datoms in the transaction take effect together at one logical point in time.

### Inaccurate readings

The phrase is misleading if interpreted as any of the following:

- every individual field/dat​​om produces a separately observable state;
- every command succeeds;
- reads create state;
- the entire application, including sockets, files, threads, caches, and external services, is represented by the database value;
- every new logical value is a full copy;
- merely using immutable values automatically creates retained or durable history;
- reverting the current reference erases later facts or effects.

A more exact statement is:

> Every successful authoritative transaction publishes one new complete database value; prior values remain immutable, and the durable database records the transaction’s additions and retractions.

For Tuna, even that statement would describe a possible state contract, not current behavior.

## 8. Structural sharing

A persistent data structure preserves prior versions while efficiently constructing a modified successor. **Structural sharing** means that the successor allocates only changed paths/nodes and refers to unchanged immutable nodes from its predecessor.

Official Clojure documentation states that immutable collections create modified versions using structural sharing rather than full copying:

- [Clojure Data Structures, § Collections](https://clojure.org/reference/data_structures#Collections)
- [Clojure Functional Programming, § Immutable Data Structures](https://clojure.org/about/functional_programming#_immutable_data_structures)

Datomic describes database values as persistent data structures and its indexes as immutable persistent trees whose nodes are immutable segments:

- [Datomic Overview, § Inspired by Clojure](https://docs.datomic.com/datomic-overview.html#inspired)
- [Datomic Overview, § Indexes](https://docs.datomic.com/datomic-overview.html#indexes)
- [ACID, § How It Works](https://docs.datomic.com/transactions/acid.html#how-it-works)

Conceptually:

```text
old root ─┬─ unchanged subtree A
          ├─ old changed path
          └─ unchanged subtree C

new root ─┬─ same subtree A
          ├─ newly allocated changed path
          └─ same subtree C
```

Safety depends on shared structure being immutable. Sharing a mutable nested Gerbil vector, hash table, or struct would let later mutation alter an earlier “snapshot.” Structural sharing is therefore a representation property, not a synonym for shallow copying or pointer reuse.

Existing Gerbil research finds no supported persistent map library and warns that final structs and shallow copies do not provide transitive immutability:

- `research/gerbil-host-neutral-state-mechanisms.md:168-219`
- `research/tuna-host-neutral-state-architecture.md:83-92,114-119`

## 9. What rollback means

“Rollback” covers several materially different operations:

1. **Abort before commit.** This is Datomic atomicity. A failed or canceled transaction does not install `db-after`; the current durable database remains `db-before`.
2. **Read an older state.** `as-of` returns a historical point-in-time view. It does not change the current database.
3. **Correct present truth.** Submit another transaction containing retractions/additions. This creates a later successor while retaining evidence of both the mistake and correction.
4. **Branch from the past.** Datomic explicitly says `as-of` plus `with` is not a durable branch.
5. **Undo external effects.** Datomic does not do this. Transaction functions are required to be side-effect-free; effects outside the database require separate application semantics.
6. **Restore storage from backup.** This is an operational disaster-recovery procedure, not ordinary transaction rollback.

Therefore, immutable values make aborting an unpublished candidate cheap and make old-state inspection possible. They do not by themselves supply undo, compensation, branching, or durability.

## 10. Transferable versus database-specific lessons

### Transferable to an in-process extensible Gerbil application

- Stable runtime/resource identity can be distinct from immutable state snapshots.
- A state transition can be reasoned about as `before -> candidate after`.
- One owner/commit lane can impose a total order on authoritative transitions.
- Validation can occur against a complete candidate rather than partially mutated public state.
- Publication can atomically replace one coherent root rather than several independent cells.
- Readers can retain stable roots without blocking the writer, if all reachable snapshot data is immutable.
- Pure transformation/validation code is safer on the serialized path.
- Slow extension code on the owner lane delays every command behind it.
- Effects should not be confused with state calculation or rollback.
- Revision/basis values can identify coherent snapshots without being domain events.

### Transferable only if explicitly chosen

- Datom-shaped facts may suit some domains, but are not required by immutable state.
- Retaining old roots may support temporary history, but retention, indexing, and garbage collection require an explicit policy.
- A transaction report can expose before/after/delta, but Tuna’s planned notification is only a coalesced wakeup.
- Transaction-function-like extensibility requires purity and a controlled authority boundary; ordinary Tuna actions currently have neither constraint.
- Structural sharing requires a suitable persistent representation; it is not guaranteed by Gerbil aggregates.

### Primarily durable-database facilities

- Durable transaction log and recovery across process restart.
- Monotonic global transaction IDs and wall-clock transaction entities.
- Persistent additions/retractions with provenance and auditing.
- `as-of`, `since`, history, and log queries backed by indexes.
- Durable atomic writes, storage compare-and-swap, backup, and restore.
- Distributed read propagation, peer caches, and `sync`.
- Schema-level type, cardinality, uniqueness, lookup references, and entity-ID allocation.
- Immutable persistent index segments and background indexing.
- ACID durability and cross-node serializability.

An in-memory root swap may have atomic publication without being an ACID database: it lacks at least durability and usually lacks a retained, queryable history.

## 11. Relationship to current Tuna research

### Current behavior

Tuna’s `CommandRuntime` contains only inbox, mutex, lifecycle state, and thread—no application-state root:

- `tuna/lib/runtime.ss:21-31`

Its one worker invokes commands sequentially and catches ordinary action failures:

- `tuna/lib/runtime.ss:65-117`

Admission is bounded and synchronized with stopping:

- `tuna/lib/runtime.ss:141-172,178-190`

This matches Datomic’s useful **serialization** lesson but not its transaction semantics. Tuna actions can mutate shared values or external resources and then raise; the worker surviving does not undo those mutations:

- `research/tuna-current-state-boundary.md:55-63`
- `research/tuna-current-state-boundary.md:116-123`

Tuna’s live cells provide atomic replacement only per cell; a sequence of updates is not a transaction:

- `tuna/README.md:240-246`

### Deferred state boundary

The roadmap’s M9 requires a concrete host state model before adding coherent revisioned snapshots and capacity-one coalesced invalidations. It explicitly excludes persistence and event sourcing:

- `plans/emacsen-runtime/checklist.md:276-286`
- dependency: `plans/emacsen-runtime/checklist.md:387-400`

This differs from Datomic’s transaction report queue and durable log:

- Datomic’s report queue delivers every connected transaction and must be drained to prevent memory growth: [Processing Transactions, § Monitoring Transactions](https://docs.datomic.com/transactions/transaction-processing.html#monitoring-transactions).
- Tuna’s proposed M9 channel is a lossy/coalesced “newer state exists” wakeup, not a transaction record: `plans/emacsen-runtime/checklist.md:280-284`.

### Existing model tension

The current Tuna state research favors private owner-confined mutable state plus detached immutable snapshots:

- `research/tuna-host-neutral-state-architecture.md:3-18`
- comparison and failure semantics: `research/tuna-host-neutral-state-architecture.md:94-119`

An earlier proposal favored action-produced immutable next-state transitions:

- `research/tuna-long-lived-command-runtime-boundary.md:24-29,34-74`

Datomic most closely resembles the latter semantically: pure candidate construction followed by atomic publication. It also demonstrates why the two Tuna models differ on failure:

- an immutable candidate can be discarded before publication;
- in-place owner-confined mutation can partially apply before an exception;
- neither model rolls back external effects.

Current Tuna research explicitly recognizes this:

- `research/tuna-host-neutral-state-architecture.md:96-106,128-157`
- mutable failure experiment: `research/tuna-host-neutral-state-architecture.md:263-280`

## 12. Materially different model options already present in the evidence

These are analytical distinctions, not an implementation recommendation.

| Model | Failure before publication | Reader snapshot | History/durability |
|---|---|---|---|
| Immutable successor root | Discard candidate root; current root unchanged | Old root remains stable | Only if roots/log are retained; process-local by default |
| Owner-confined mutable state plus detached snapshots | Partial mutation can remain after failure | Safe only if snapshots are detached/transitively immutable | Not implied |
| Durable Datomic-like fact/log database | Failed transaction leaves durable DB unchanged | Immutable database value at a basis | Built-in durable log, indexes, history, provenance |

The third is not merely an optimized version of the first. It adds a database information model, durable storage protocol, indexing, transaction identity, temporal query semantics, and operational recovery.

## Review findings and residual risks

- **High — `tuna/lib/runtime.ss:65-85`: serialization is not atomicity.** Current actions may mutate and then fail; Datomic-style “database unchanged” semantics do not apply.
- **High — `research/tuna-host-neutral-state-architecture.md:83-92`: immutable snapshots are not enforced by Gerbil.** Mutable nested aliases can corrupt older snapshots.
- **High — `research/tuna-current-state-boundary.md:116-123`: ownership is bypassable.** Direct public action/value APIs can mutate outside the command lane.
- **High — `plans/emacsen-runtime/checklist.md:276-286`: M9 is not implemented or authorized.** No current Tuna test attests state coherence, snapshot isolation, publication, or rollback.
- **High — external effects remain outside either model.** Datomic’s pure transaction-function rule prevents treating arbitrary I/O as transactionally reversible.
- **Medium — `research/tuna-host-neutral-state-architecture.md:94-119`: existing Tuna research contains two materially different state directions.** Datomic evidence clarifies their semantics but does not select between them.
- **Medium — `plans/emacsen-runtime/checklist.md:280-284`: coalesced invalidation cannot reconstruct history.** It must not be described as a Datomic-like log.
- **Medium — structural-sharing feasibility remains host-dependent.** The repository identifies no supported Gerbil persistent map and no concrete host state shape.
- **Medium — slow or impure live extensions can stall or compromise the owner lane.** Datomic’s corresponding serialized-code warning applies directly.
- **Low — terminology collision:** `command-runtime-state` currently means lifecycle state, not application state: `tuna/lib/runtime.ss:51-63`.

**Confidence:** High for the Datomic transaction, value, history, read, and effect semantics; high for current Tuna behavior; medium for the applicability of persistent structural sharing in Gerbil because no concrete state representation or supported persistent collection has been established.

## Validation

Research was read-only. No Tuna behavior tests were executed.

Focused current baseline:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test/run-command-runtime-matrix.sh
```

This runs source `gxi`, normal `gxc`, and `gxc -O`, then verifies worktree status is unchanged: `tuna/test/run-command-runtime-matrix.sh:29-94`.

Broader repository-supported validation:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
gerbil build
gerbil test test/command-runtime-test.ss
test/run-command-runtime-matrix.sh

cd /home/jay/Code/workbench-gerbil/packages/dummy
GERBIL_PATH="$PWD/../../tuna/.gerbil" GERBIL_LOADPATH= gerbil build
```

If Gerbil synchronization internals are changed:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil-dev
make check
# documented alternative:
./build.sh env gerbil test ./...
```

Evidence: `gerbil-dev/CONTRIBUTING.md:182-190`; `gerbil-dev/doc/reference/dev/test.md:17-25`.