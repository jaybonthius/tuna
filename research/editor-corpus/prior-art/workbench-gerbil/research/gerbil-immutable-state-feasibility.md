# Gerbil v19 immutable/new-root state feasibility

## Concise answer

A new-root-per-command architecture is **feasible in installed Gerbil v19**, but immutability is contractual rather than enforced.

The practical model is:

1. one command thread owns the current `(revision, application-state)` root;
2. a state-capable command computes a candidate without mutating the installed root;
3. the owner validates it and constructs one replacement root;
4. it installs that root under a mutex shared with readers, or serves all reads through the owner queue;
5. it then issues nonblocking invalidations and completes the command.

Gerbil has functional list/alist operations and a limited “pure” wrapped-alist API, but no installed production persistent hash map, set, or vector. Lists, vectors, hash tables, structs, boxes, and strings remain mutable. Structural sharing is therefore safe only when every shared descendant is immutable by convention.

For a schema-neutral runtime, the strongest abstraction is an **application-supplied state adapter** or an opaque root of extension-owned fragments. Tuna should own only the revision/installation protocol, not fragment schemas or generic deep-copy rules.

## Evidence baseline

- Installed runtime: `Gerbil v0.19-dev-31-g4a4d1a30 on Gambit v4.9.7-6-g64f4d369`.
- The Gerbil checkout is one commit newer (`4531c21b...`), but inspected `std/list/walist.ss`, `std/list/alist.ss`, `gerbil/runtime/hash.ss`, `gerbil/runtime/mop.ss`, and `std/sync/atom.ss` are byte-identical to `/opt/gerbil/src`.
- Existing research correctly identifies the missing installed Hash Array Mapped Trie (HAMT), shallow-copy aliasing, Atom read gap, and owner-thread model: `research/gerbil-host-neutral-state-mechanisms.md:168-219,315-366`.
- Current Tuna has only an executor: `CommandRuntime` stores inbox, lifecycle mutex/state, and thread, not application state: `tuna/lib/runtime.ss:21-46`.
- The roadmap explicitly keeps state opaque and owner-confined and defers publication until a real host state exists: `plans/emacsen-runtime/checklist.md:260-286`.

## Collections and aliasing

| Representation | What exists | Update/copy cost | Aliasing and immutability |
|---|---|---|---|
| Lists/alists | Ordinary lists plus functional alist operations and `PureAList`/`WAList` wrappers | Prepending is O(1). Lookup is O(n). Replacing/removing an existing key copies the prefix to that key and shares the suffix; adding an absent key scans O(n) but can prepend O(1). | Pairs are mutable. Keys, values, shared suffixes, and nested objects remain aliased. |
| Vectors | Ordinary mutable vectors; functional mapping utilities construct new vectors | `vector-copy` or copy-and-set is O(n) | Copy is shallow; all elements remain aliased. |
| Hash tables | Mutable, open-addressed tables with expected constant-time access | Mutation is expected O(1); `hash-copy` is whole-table O(n) | Copy duplicates the table structure only; keys and values remain aliased. No freeze operation. |
| Structs/classes | Fixed-layout structs and dynamic-layout classes | Construction/copy is proportional to fields; field access is direct for structs | Generated mutators remain available; `final:` blocks subclassing, not mutation. `struct-copy` is shallow. |
| Persistent map/set/vector | No supported installed implementation | N/A | SRFI 146/HAMT exists only in retired v19 WIP/TODIE source and cannot be imported. |

### Lists and wrapped alists

The active `:std/list/walist` defines `PureAList` and “pure” variants at `gerbil/src/std/list/walist.ss:51-80`. This is a useful but limited persistent-by-convention map:

- constructors wrap the caller’s alist without copying it: `gerbil/src/std/list/walist.ss:118-142`;
- `walist->list` returns the underlying list directly: `gerbil/src/std/list/walist.ss:161-162`;
- `waput` copies a prefix and shares the untouched suffix: `gerbil/src/std/list/walist.ss:220-236`;
- `waremove` reconstructs the prefix and shares the tail: `gerbil/src/std/list/walist.ss:258-271`.

The underlying alist remains composed of mutable pairs. The ordinary alist module exposes both functional and destructive operations:

- functional replacement: `gerbil/src/std/list/alist.ss:32-47`;
- destructive `set-car!`/`set-cdr!` updates: `gerbil/src/std/list/alist.ss:49-66,80-100`.

Thus `PureAList` is not a hard security or immutability boundary. An installed probe changed a wrapped “pure” alist through its original constructor argument, and the wrapper immediately observed the change.

The only installed HAMT implementation is inactive source:

- SRFI 146 mapping surface: `gerbil/src/v0.19-WIP/v0.19-TODIE-std/srfi/146.ss:3-37`;
- HAMT mutable/immutable operations: `gerbil/src/v0.19-WIP/v0.19-TODIE-std/srfi/146/hamt-map.ss:3-23`.

Importing `:std/srfi/146` fails with “cannot find library module.”

### Vectors

Gambit explicitly says `vector-copy` does not recursively copy elements: `gerbil/src/gambit/doc/gambit.txi:3833-3838`. `vector-copy!` mutates its destination: `gerbil/src/gambit/doc/gambit.txi:3857-3863`.

A full immutable update therefore needs:

```text
copy vector → replace one slot in private copy → never mutate it after publication
```

That is O(vector length), even for a one-element change, and nested values still require their own immutable/copy policy.

### Hash tables

Gambit tables are mutable, open-addressed, automatically resized structures with constant-time access under normal hashing: `gerbil/src/gambit/doc/gambit.txi:9336-9361`. Gerbil’s hash interface exposes mutation, deletion, copying, and clearing: `gerbil/src/gerbil/runtime/hash.ss:23-34,50-89`.

`hash-copy` delegates to the implementation’s copy method: `gerbil/src/gerbil/runtime/hash.ss:633-635`. Gambit promises a new table with the same bindings and parameters, not recursively copied bindings: `gerbil/src/gambit/doc/gambit.txi:9693-9698`.

Consequences:

- copy-on-write hash state pays O(n) per changed table;
- nested values and mutable keys remain shared;
- a mutable key used with `equal?` can change its hash/equality after insertion and invalidate lookup assumptions;
- weak tables are inappropriate for authoritative state because garbage collection may remove bindings: `gerbil/src/gambit/doc/gambit.txi:9345-9354`.

### Structs and classes

Generated accessors and mutators can directly modify slots: `gerbil/doc/guide/intro.md:431-459`. Structs provide fixed-prefix layouts and direct field access, not immutability: `gerbil/doc/guide/intro.md:548-616`.

Equality/printing metadata is computed separately from mutability:

- `transparent:` implies fields participate in equality and printing;
- `equal: #t` selects all new fields;
- a slot list selects particular fields;
- an opaque type may reduce `equal?` to identity.

Implementation: `gerbil/src/gerbil/runtime/mop.ss:209-260,267-304`. `struct-copy` directly calls `##structure-copy`: `gerbil/src/gerbil/runtime/mop.ss:970-971`, and installed probing confirmed nested boxes/vectors remain aliased.

`final: #t` only affects extensibility at `gerbil/src/gerbil/runtime/mop.ss:278-304`; it does not remove generated mutators or freeze descendants.

## Equality, hashing, copying, and serialization

### Equality and hashing

Available primitives include `eq?`, `eqv?`, `equal?`, and corresponding hash functions. `equal?-hash` returns a fixnum and guarantees equal values have equal hashes: `gerbil/src/gambit/doc/gambit.txi:9205-9210`.

Hash-table `equal?` also compares weakness, comparison/hash procedures, size, and each value: `gerbil/src/gambit/doc/gambit.txi:9381-9386`.

Architectural implications:

- `eq?` is a cheap and useful unchanged test under strict new-root discipline: returning the old state object can mean “unchanged.”
- `equal?` may traverse the reachable graph and should not be a universal per-command change detector.
- Equality metadata does not make a struct immutable.
- Hashing mutable values is unsafe for cached hashes or map keys.
- An application adapter should define `changed?` or state equivalence when identity is insufficient.

A narrow installed-runtime mismatch exists: `gerbil/src/gerbil/test/mop-test.ss:86-89` expects an `equal: ()` corner case to compare all instances equal, while installed dev31 returns `#f`. Ordinary transparent, opaque, and selected-slot cases behaved as expected. Avoid depending on the empty-slot-list corner case.

### Shallow copy support

- `list-copy`: copies list spine only; nested objects remain references.
- `vector-copy`: shallow by documented contract.
- `hash-copy`: copies the table but retains key/value references.
- `struct-copy`: copies fields but retains field references.

Installed probing confirmed one nested box remained shared by the vector, hash, and struct copies.

### Deep serialization copy

Gambit provides `object->u8vector` and `u8vector->object`. The latter reconstructs a structurally equal object: `gerbil/src/gambit/doc/gambit.txi:8958-8970`. Threads, wills, some ports, and any graph containing them are not serializable: `gerbil/src/gambit/doc/gambit.txi:8971-8973`.

The installed probe showed serialization:

- detached a nested box from the source graph;
- preserved internal sharing between two references to that box;
- produced an `equal?` graph with the same `equal?-hash`.

Its costs are O(reachable graph size), plus a byte buffer and reconstructed graph. During copying, the old graph, byte vector, and new graph can all be live. It is viable for checkpoints, tests, infrequent isolation, or an application-selected clone strategy—not as a universal high-frequency state copier.

The current `:std/serde/marshal` also supports graph scanning, class filtering, and a maximum integer bit size: `gerbil/src/std/serde/marshal.ss:16-35`. Its deserialization interfaces explicitly treat incoming objects as untrusted and perform resolution/untainting: `gerbil/src/std/serde/interface.ss:175-260`. It is a larger, evolving surface than the documented Gambit serializer.

## Revisions

Use an exact nonnegative integer stored in the same root as state:

```text
Root = (revision, application-state)
next revision = (+ revision 1)
```

Gambit promotes values outside fixnum range to bignums: `gerbil/src/gambit/doc/gambit.txi:19146-19152`. Generic arithmetic therefore avoids rollover, at the cost of allocating bignums once the fixnum range is exceeded.

Do not use `AtomicCounter` for the authoritative revision:

- it stores a fixnum in a vector and uses `fx+` plus vector compare-and-swap: `gerbil/src/std/sync/atom.ss:110-125`;
- it returns the old value;
- installed probing showed wraparound from `##max-fixnum` to `##min-fixnum`;
- it is separate from the application root and cannot atomically commit state plus revision.

## Atomic publication

### Preferred mutex publication cell

Gambit states raw store reads/writes are not atomic and concurrent read/write access is erroneous: `gerbil/src/gambit/doc/gambit.txi:10045-10053`.

Therefore, if readers access a separately published root:

- both getter and installer must lock the same mutex;
- the owner computes the candidate outside this publication lock;
- the critical section only replaces the fully constructed root;
- revision and state must be one object, never two separately updated cells.

This gives a logical linearization point without holding the lock during an application transition, copy, validation, rendering, or I/O. Mutexes are nonrecursive, so callbacks must not re-enter the same publication lock: `gerbil/src/gambit/doc/gambit.txi:9911-9935`.

An even simpler alternative is to serve snapshot reads as owner commands. That eliminates the shared publication location but adds queue latency and head-of-line blocking.

### Atom limitations

Atom mutation functions run under the Atom mutex, including validator execution, assignment, and watchers: `gerbil/src/std/sync/atom.ss:31-54,57-105`.

However:

- `atom-deref` is only the exported `Atom-value` accessor: `gerbil/src/std/sync/atom.ss:16-18,38`;
- it does not lock;
- watchers run synchronously after assignment while the mutation lock remains held;
- a watcher exception occurs after commit;
- compare-and-set uses `eq?`, not structural equality: `gerbil/src/std/sync/atom.ss:90-95`.

Consequently an Atom is acceptable for owner-only storage or short synchronized transformations, but raw `atom-deref` is not a proven cross-thread publication read under Gambit’s memory model. A private mutex-protected cell is clearer.

### Concrete owner sequence

For a pure state-capable command:

```text
old-root := current owner-local root
(candidate-state, result, effect-intents, changed?) :=
    transition(old-root.state, command)

validate candidate-state and effect-intents

if changed:
    new-root := Root(old-root.revision + 1, candidate-state)
    lock publication cell
    install new-root
    unlock publication cell
    update owner-local root
    nonblocking invalidation attempts

stage/dispatch committed effects according to policy
complete command with result
```

If transition or validation raises before installation, retain `old-root` and fail only that command. No compare-and-set is needed because there is one installer.

If expensive candidate computation is offloaded, the result must carry its base revision/root identity. The owner must reject or recompute it when current state has advanced.

Current Tuna already supplies serial execution and completion, but `complete-command!` directly invokes ordinary actions and posts their result: `tuna/lib/runtime.ss:65-85,105-117`. Existing action signatures receive only explicit arguments or an acquired argument list: `tuna/lib/bindings.ss:247-258`. A separate state-capable action/adapter seam is therefore required; silently changing ordinary action returns or arity would break current behavior.

## Extension-safe composition without a universal schema

Two compatible patterns are feasible.

### Opaque application state adapter

Tuna owns only:

```text
Root(revision, opaque-state)
Adapter:
  transition(old-state, command) -> candidate/result/effect-intents/changed?
  validate(candidate-state)
  snapshot(candidate-state)      ; if published state differs
  equivalent?(old, candidate)    ; optional
```

The application selects lists, custom persistent collections, copying, database handles, or owner-confined mutable storage. Tuna neither enumerates fields nor performs generic serialization. This is the strongest schema-neutral boundary.

The adapter must guarantee that published candidates/snapshots do not contain mutable aliases exposed elsewhere. Gerbil cannot verify this transitively.

### Qualified extension fragments

An application may use a shallow map/alist:

```text
opaque-state = qualified-extension-id -> private fragment
```

Each extension gets a capability for its own qualified key and returns a replacement fragment. The outer map is a composition mechanism, not a schema for fragment contents.

Safety requires:

- globally stable, package-qualified keys;
- no raw outer hash/list reference exposed to extensions;
- extension reducers receive only their fragment and explicit shared services;
- every replacement fragment obeys the same immutability/snapshot contract;
- multi-extension changes are orchestrated by one command before installation;
- extension registration/definitions remain separate from durable state;
- reducer ordering and duplicate-key ownership are deterministic.

A `PureAList` can support small fragment counts, with linear lookup/update and convention-only safety. Large extension sets need either full hash copying, an application dependency on a vetted persistent map, or mutable owner-confined indexing behind detached snapshots.

## External-effect staging

A new root only isolates in-memory state. Files, sockets, subprocesses, databases, clocks, logging, and extension callbacks do not roll back when candidate installation is discarded.

A pure transition should return **effect intents**, not execute effects during candidate computation. After that, there are materially different semantics:

1. **Commit state, then execute effect.**  
   State remains committed if the effect fails. Use retries, idempotency keys based on command/revision, and later commands to record outcomes.

2. **Execute effect, then install state.**  
   State can remain old after an effect has already happened. This requires compensation or a prepare/commit protocol.

3. **Durable state plus outbox.**  
   Persist candidate state and an effect record atomically in one transactional store, then dispatch effects and record acknowledgements. This is the only robust generic crash-recovery pattern when the store supports it.

4. **Resource-specific two-phase preparation.**  
   Prepare reversible temporary resources before installation, commit after installation, and abort on candidate failure. Not every external system supports this.

There is no generic atomic transaction across a Gerbil heap assignment and arbitrary external systems. Blocking effects on the owner also stall all commands and shutdown; dispatching them elsewhere requires explicit ordering, retry, stale-result, and lifecycle rules.

## Garbage collection and old roots

Gambit garbage collection follows reachability from roots; pairs, vectors, records, and closures hold strong references: `gerbil/src/gambit/doc/gambit.txi:9224-9241`.

Therefore:

- an old root retained by a reader, history list, completion, closure, subscriber channel, cache, or debugger keeps every reachable descendant alive;
- once no reference to an old root remains, its unshared nodes become collectible;
- shared nodes remain live through the current root;
- weak references must not be used to provide required history.

Expected memory shapes:

- **Full copy, no history:** during a transition both complete graphs are live; after readers release the old root, it can be reclaimed.
- **Full copy with unbounded history:** live memory grows approximately with state size × retained revisions.
- **Structural sharing:** retained history keeps the base graph plus the union of changed paths, approximately O(base + updates × changed-path size), unless each update replaces a large leaf.
- **Serialization copy:** transient peak includes source graph, serialized bytes, and rebuilt graph.
- **Mutable internals plus detached snapshots:** authoritative storage stays singular, but retained snapshots may dominate memory.

Use bounded history and invalidation tokens rather than placing complete roots in subscriber channels. Measure allocation and live data with Gambit garbage-collection reports before choosing retention limits.

## Strategy comparison

| Strategy | Strengths | Costs and risks | Fit |
|---|---|---|---|
| Full copy per command | Candidate can be mutated privately and discarded on failure; no persistent collection dependency | O(n) time/allocation; requires a complete copier; nested aliases and nonserializable resources are hazards; high transient memory | Small state or low command frequency |
| Structural sharing by convention | O(1) root reads and path-sized updates; clean failed-command behavior | No enforcement; no installed scalable persistent map; one leaked mutable descendant corrupts several revisions | Strong when state is custom immutable structs/lists or an external persistent library |
| Application-supplied adapter | Preserves schema neutrality; host chooses representation, validation, equality, copy, and snapshots | Runtime cannot prove adapter correctness; adapter/version compatibility becomes application responsibility | Best generic Tuna boundary |
| Mutable owner-confined internals behind immutable snapshot API | Cheap local mutation; easy extension integration; stable immutable read contract | Not a strict immutable authoritative root; partial mutation survives exceptions; snapshot detachment may be O(n) | Best when mutation performance matters and rollback is not promised |
| Hybrid clone/builder then publish | Lets imperative application code construct a candidate while preserving old root | Clone quality and cost determine safety; effects still require staging | Useful application-specific compromise |

## Review findings

- **High — no enforced persistent collection substrate:** installed v19 has no supported HAMT, persistent set, or persistent vector. `PureAList` is linear and aliasable.
- **High — immutable candidate safety is transitive:** sharing one mutable list cell, vector, hash, struct, box, string, payload, or extension object can corrupt old and new roots together.
- **High — current Tuna has no state/action bridge:** `tuna/lib/runtime.ss:65-85` and `tuna/lib/bindings.ss:247-258` cannot currently pass instance-owned state authority to an action.
- **High — external effects are outside root rollback:** generic atomicity is impossible without resource-specific transactions, an outbox, idempotency, or compensation.
- **Medium — Atom is not a complete publication seam:** mutations lock, but `atom-deref` does not.
- **Medium — retained snapshots can create an application-level memory leak:** garbage collection correctly retains every object reachable from old roots.
- **Medium — equality is potentially expensive and mutable-key-sensitive:** use identity/change tokens or an adapter rather than universally hashing/comparing roots.
- **Medium — equality corner mismatch:** the current MOP test’s `equal: ()` expectation fails against installed dev31.
- **Medium — installed/check-out skew:** tools are dev31 while the Gerbil checkout is dev32; inspected implementation files match, but full source-suite expectations can still differ.
- **Low — current runtime is SMP-disabled:** synchronization is still required by Gambit’s contract, and publication should be re-audited if SMP is enabled.

## Residual gaps and confidence

Unresolved application-level questions:

- the exact state-capable action/adapter API;
- whether unchanged commands advance revision;
- whether effects complete before command completion;
- snapshot representation and retention bounds;
- multi-extension reducer ordering;
- stale offloaded-candidate policy;
- crash recovery and durable effect semantics.

**Confidence:** high for installed collection, copy, Atom, mutex, integer, serialization, and garbage-collection behavior; high that a mutex-published single-owner new-root architecture is feasible; medium-high for the extension composition alternatives; medium for real costs until representative state and mutation patterns exist.

## Validation

### Performed

Focused installed-library tests passed:

```sh
gerbil test -g \
  gerbil/src/std/sync/atom-test.ss \
  gerbil/src/std/list/alist-test.ss \
  gerbil/src/std/list/walist-test.ss \
  gerbil/src/std/hash/misc-test.ss \
  gerbil/src/std/serde/binary-test.ss
```

Installed probes confirmed:

- `:std/srfi/146` is unavailable;
- `PureAList` exists but aliases constructor/list-extractor data;
- vector/hash/struct copies preserve nested aliases;
- serialization detaches nested mutable objects while preserving internal sharing;
- generic exact integers become bignums;
- `AtomicCounter` wraps at fixnum bounds;
- ordinary transparent/opaque/selected-field struct equality;
- no staged Workbench or Tuna files.

The combined test including `gerbil/src/gerbil/test/mop-test.ss` failed only at line 87’s `equal: ()` expectation; all other listed modules passed.

### Focused validation for a future implementation

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test/run-command-runtime-matrix.sh
```

The matrix runs source `gxi`, normal `gxc`, and `gxc -O`, then compares worktree status: `tuna/test/run-command-runtime-matrix.sh:29-94`.

Add state-facing cases for:

- candidate exception leaves the installed root and revision unchanged;
- old/new root alias isolation;
- coherent locked `(revision, state)` reads;
- exactly one installer and no overlapping transitions;
- stale offloaded candidate rejection;
- extension fragment key isolation;
- full subscriber channel does not block commit;
- bounded old-root retention;
- effect failure under each documented staging policy;
- install/invalidation/completion ordering.

### Full validation

Gerbil documents recursive testing at `gerbil/doc/reference/dev/test.md:1-25`. If Gerbil itself changes:

```sh
cd /home/jay/Code/workbench-gerbil/gerbil
make check
# documented alternative
./build.sh env gerbil test ./...
```

Supported at `gerbil/CONTRIBUTING.md:182-190`. These full commands were not run because this task was read-only research against installed behavior.