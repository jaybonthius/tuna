# Gerbil v19 keymap/input-resolver implementation idioms

## Conclusion

**Recommended:** represent each static keymap as a final struct containing a **sorted vector of full normalized key-sequence bindings**. Keep layering, inheritance/composition, translations, remapping, transient maps, and computed policies outside that backing representation as ordered resolver stages/providers.

This is the smallest option with a credible hot path:

- no unsupported persistent-collection dependency;
- compact, load-once static data;
- binary lower-bound support from active `:std/vector/vector`;
- no mutation or lookup allocation required inside the map;
- replacement remains a simple new-root publication;
- the backing can later change to a trie without changing normalized events, definitions, provider composition, or resolution result types.

A custom immutable trie is **not justified at the minimal stage**. Gerbil v19 has no active supported persistent map/trie implementation, typical key sequences are short, and representative binding counts and latency budgets do not yet exist.

## Evidence baseline

- Installed runtime: `/opt/gerbil/current` resolves to `/opt/gerbil/v0.19-dev-31-g4a4d1a30`; `gxi -v` reports Gerbil `v0.19-dev-31-g4a4d1a30` on Gambit `v4.9.7-6-g64f4d369`.
- Checkout: `/home/jay/Code/workbench-gerbil/gerbil` at `4531c21b90fa6ee04f374af905ae3ddb9d89d590`, one commit newer than the installed runtime.
- The installed and checked-out copies are byte-identical for:
  - `src/gerbil/runtime/hash.ss`
  - `src/std/list/alist.ss`
  - `src/std/list/walist.ss`
  - `src/std/vector/vector.ss`
  - `src/std/sync/atom.ss`
- Tuna is clean at `5a481b1216236c64701cf950c3a8dcf529aba183`.
- The outer Workbench checkout already contains unrelated modifications and untracked repositories. No staged files exist in either Workbench or Tuna.

**Confidence:** high on available Gerbil APIs and Tuna conventions; medium-high on the recommended representation; medium on performance until representative benchmarks exist.

## 1. Available collection substrate

### No active persistent map or trie

No active map/tree/trie implementation was found beneath either `/opt/gerbil/src/std` or the checkout’s active `gerbil/src/std`.

The only Hash Array Mapped Trie (HAMT) found is retired work-in-progress source:

- `gerbil/src/v0.19-WIP/v0.19-TODIE-std/srfi/146/hamt-map.ss:1-30` exposes mutable and immutable operations;
- it imports other retired `:std/srfi/*` modules at lines 5-8;
- the associated SRFI 146 mapping module depends on retired `:std/misc/rbtree` and other unavailable modules at `gerbil/src/v0.19-WIP/v0.19-TODIE-std/srfi/146.ss:5-12`.

This source is not an active installed API and must not be treated as a dependency.

**High:** adopting it would require reviving and owning a retired collection stack, not merely importing an available Gerbil library.

### Functional alists and wrapped alists

Active options include ordinary functional alist operations and `PureAList` wrappers:

- functional replacement/removal: `gerbil/src/std/list/alist.ss:32-47,68-78`;
- destructive alternatives remain exposed: `gerbil/src/std/list/alist.ss:49-66,80-100`;
- pure/mutable wrapper types: `gerbil/src/std/list/walist.ss:51-80`;
- constructors wrap the supplied list rather than copying it: `walist.ss:118-142`;
- `walist->list` exposes the underlying list: `walist.ss:161-162`;
- `waput` copies the traversed prefix and shares the suffix: `walist.ss:220-236`;
- `waremove` reconstructs the prefix and shares the remaining tail: `walist.ss:258-271`.

These are persistent **by convention**, with linear lookup/update. Neither pairs nor wrapper contents are frozen.

### Vectors

Vectors are ordinary mutable Gambit vectors, but they are useful as published read-only snapshots.

- `vector-least-index` performs lower-bound-style lookup over a sorted vector: `gerbil/src/std/vector/vector.ss:27-36`.
- `vector-copy` is explicitly shallow: `gerbil/src/gambit/doc/gambit.txi:3833-3838`.
- `vector-copy!` mutates its destination: `gambit.txi:3857-3864`.

A vector therefore supports a compact immutable-by-contract keymap, but an update requires constructing/copying a complete vector. Elements must also obey the immutability contract.

### Hash tables and weak tables

Gerbil’s active hash constructor supports:

- `size:`, `seed:`;
- custom `test:` and `hash:`;
- `lock:` and `check:`;
- `weak-keys:` and `weak-values:`.

Evidence: `gerbil/src/gerbil/runtime/hash.ss:385-393`.

It selects specialized `eq?`, `eqv?`, symbolic, immediate, string, or generic implementations when possible: `hash.ss:458-489`; convenience constructors are at `hash.ss:491-504`.

Gambit documents open addressing, automatic resizing, and typical constant-time access at `gerbil/src/gambit/doc/gambit.txi:9356-9361`. Custom equality requires a consistent fixnum-producing hash; omitting a useful hash for a custom comparator can degrade to linear search: `gambit.txi:9363-9379`.

Relevant limitations:

- tables are mutable;
- `hash-copy`/`table-copy` copies table structure, not keys or values: `gerbil/src/gerbil/runtime/hash.ss:633-635`; `gambit.txi:9693-9698`;
- `hash-get` conflates absence with a stored `#f`; use `hash-key?` or an explicit private sentinel: `hash.ss:568-588`;
- weak bindings can disappear during garbage collection: `gambit.txi:9345-9354`.

Weak tables fit caches and metadata, not authoritative key bindings. Tuna uses them accordingly for descriptor details at `tuna/tuna/lib/bindings.ss:247-262`.

A flat hash table is not especially attractive for sequences: exact lookup is expected O(1), but prefix recognition requires either scanning keys or maintaining a second prefix index. Copy-on-write updates remain O(n).

## 2. Structs, equality, hashing, and sum types

Gerbil structs have fixed slot layouts and direct field access suitable for hot-path value types:

- `defstruct` and fixed-layout behavior: `gerbil/doc/guide/intro.md:548-567`;
- positional constructors and compile-time-known offsets: `intro.md:603-616`.

They are not immutable. `final: #t` prevents subclassing, not slot mutation. `transparent:`/`equal:` control printing and structural equality:

- property meanings: `gerbil/src/gerbil/runtime/mop.ss:38-45`;
- equality-field construction: `mop.ss:213-277`;
- finality only controls extensibility flags: `mop.ss:278-304`;
- `struct-copy` is shallow: `mop.ss:970-971`.

`equal?-hash` is consistent with `equal?`: `gerbil/src/gambit/doc/gambit.txi:9205-9210`. Thus a transparent normalized-event struct can be used with an ordinary `equal?` hash table, provided every field is stable and immutable.

Gerbil has no active general algebraic-data-type facility. The idiomatic sum-type pattern is separate final structs plus predicates or `match`:

- structs are destructured directly by `match`: `gerbil/doc/guide/intro.md:190-222`;
- Tuna uses final `StateChanged` and `StateUnchanged` structs and predicate dispatch at `tuna/tuna/lib/runtime.ss:51-57,137-153`.

For singleton internal states, Tuna also uses private cons identities such as `+unbound-function+`: `tuna/tuna/lib/bindings.ss:54-67`.

## 3. Concrete value representations

### Normalized event

A suitable schematic representation is:

```text
NormalizedEvent(domain, code, modifiers)
```

- `domain`: an interned symbol or small enumeration distinguishing semantic character, named logical key, physical key, pointer event, and similar domains;
- `code`: character, exact integer, or controlled interned symbol;
- `modifiers`: integer bitset.

A final transparent struct is preferable to an ad hoc list:

- direct slot access;
- generated predicate/accessors;
- structural `equal?` when required;
- fields remain individually inspectable;
- no dependence on custom hashing at the minimal stage.

Raw browser properties such as repeat, composition state, target, or coordinates should remain host context unless explicitly selected as binding identity. This report does not decide that product policy.

Avoid interning arbitrary externally supplied strings solely to obtain `eq?` lookup; that can create an unbounded symbol namespace. Also avoid mutable strings, lists, or vectors as hash keys.

A packed fixnum is a possible later optimization, but it couples the representation to bit allocation, character range, event-domain limits, and fixnum width. It is not warranted without measurements.

### Key sequences

Use an immutable-by-contract vector of normalized events.

Advantages:

- O(1) indexed comparison;
- compact traversal;
- natural lexicographic ordering;
- compile-time static sequences allocate once;
- typical sequence lengths make whole-vector copying during interactive prefix accumulation small.

A list is simpler to prepend but requires reversal or prefix-spine traversal for ordered lookup. Either remains mutable by Gerbil’s object model.

### Definitions

Keep static binding definitions narrow:

```text
Command(name)
Undefined
```

`name` should be an interned Tuna action or transition name, not a captured procedure. Tuna resolves named actions and transitions through current live cells at invocation: `tuna/tuna/lib/bindings.ss:430-452,462-475`.

This matches Tuna’s existing callback convention: symbol listeners stay live, while procedure listeners are captured snapshots: `tuna/tuna/lib/event.ss:32-41,74-87`.

Computed policies should therefore be resolver providers invoked at lookup time—or live function names resolved at lookup—not opaque procedures captured inside every static binding.

### Absent, undefined, and prefix state

Absence and explicit undefined must be distinct:

- **Absent:** this map contributes nothing; lower layers may continue.
- **Undefined:** this map deliberately stops fallback.
- **Prefix:** at least one longer sequence remains.
- **Command:** an exact target exists.

An exact binding and longer extensions may coexist in a representation even if a future product policy chooses to stop immediately. To avoid baking that policy into storage, a map-local lookup should conceptually return:

```text
MapLookup(exact, continuation?)
exact = Absent | Undefined | Command(name)
```

The outer resolver can expose final structs such as:

```text
ResolutionUnbound
ResolutionUndefined
ResolutionPrefix
ResolutionCommand(name)
ResolutionAmbiguous(name)
```

`ResolutionAmbiguous` preserves the exact-plus-prefix case for a host that later uses a timeout or replay rule. The product semantics of that case remain unresolved.

## 4. Representation comparison

| Representation | Lookup and prefix behavior | Update/allocation | Assessment |
|---|---|---|---|
| Flat alist of `(sequence . definition)` | O(B × L) scan for exact/prefix, where B is bindings and L sequence length | Functional update copies a prefix and shares a suffix; pair-heavy and convention-only immutable | Smallest code for tiny maps, useful baseline |
| **Sorted vector of binding structs** | O(log B × L) lower-bound/exact search; a neighboring entry determines whether an extension exists | Static data allocated once; replacement/update O(B); compact and cache-friendly | **Recommended minimal representation** |
| Custom immutable trie with sorted-vector children | O(L × log F), where F is node fan-out; prefix is intrinsic and a resolver may retain a node cursor | Path-copy update plus child-vector copies; many node/edge allocations; custom correctness surface | Defer until benchmarks justify it |

A hash-table variant offers expected O(1) exact lookup but needs a separate prefix set/index, introduces mutable backing, hashes all sequence elements, and still pays O(B) for an immutable replacement. It is most defensible as a private construction-time builder that emits the sorted vector, not as the published minimal representation.

### Why the sorted vector does not block future features

The public seam should be lookup/provider behavior, not `vector-ref` exposure:

- **Inheritance/composition:** ordered fallback providers/maps; no physical merge required.
- **Layered maps:** an ordered list/vector of active providers.
- **Transient maps:** temporarily prepend a provider.
- **Translations:** a distinct pre-lookup sequence-to-sequence stage.
- **Remapping:** a distinct post-selection command-name-to-command-name stage.
- **Live computed policies:** a provider receives current host/application context and returns a lookup contribution.
- **Later trie:** replace one provider’s backing without changing events, definitions, layer order, or resolution variants.

This separation is important because Tuna currently defines no input mapping and keeps host context opaque: `tuna/tuna/README.md:164-171,207-226`.

## 5. Macros and compile-time parsing

Gerbil supports the required hygienic facilities:

- `defrules` for simple pattern rewriting: `gerbil/doc/guide/intro.md:253-263`;
- `defsyntax` and `syntax-case` for validation and parsing: `intro.md:265-277`;
- `begin-syntax` for phase-shifted helper code: `intro.md:308-329`;
- `(for-syntax ...)` imports for expansion dependencies.

The strongest active precedent is Gerbil’s format macro:

- imports its parser for syntax phase: `gerbil/src/std/format/api.ss:24`;
- performs parsing in `begin-syntax`: `format/api.ss:26-55`;
- reports source-associated syntax errors: `format/api.ss:45-47,69-100`;
- recognizes a literal with `stx-string?`, extracts it using `stx-e`, then emits runtime syntax through `with-syntax`: `format/api.ss:103-116`;
- has a runtime fallback for nonliteral expressions: `format/api.ss:117-120`.

Tuna already uses the same `defsyntax`/`syntax-case`, fender validation, `stx-string?`, and `raise-syntax-error` style in `tuna/tuna/lib/prelude.ss:61-95`.

For defkeymap-style syntax, two supported options are therefore available:

1. **Literal-only declaration:** parse key strings or explicit event forms during expansion and reject malformed/duplicate entries with source-located syntax errors.
2. **Literal fast path plus runtime parser:** mirror `format`, compiling literals while routing dynamic expressions through an ordinary runtime parser.

The first is smaller for static declarations; the second supports generated/user data at runtime. Either should emit constructor calls or primitive datums into runtime code rather than retaining phase-1 Gerbil objects.

Compile-time parsing can also sort bindings once using the public `list-sort` primitive documented at `gerbil/src/gambit/doc/gambit.txi:5728-5730`.

## 6. Publication and synchronization

Atoms are available and actively used by Tuna:

- `atom-deref` is merely the exported `Atom-value` accessor: `gerbil/src/std/sync/atom.ss:16-38`;
- swaps, resets, compare-and-set, validators, and watchers execute under the Atom mutex: `atom.ss:40-105`;
- compare-and-set compares the old value with `eq?`: `atom.ss:90-95`;
- watchers run synchronously during the locked update: `atom.ss:45-54`.

Tuna uses an Atom containing an immutable hash snapshot for an uncommon add-only set at `tuna/tuna/lib/bindings.ss:92-98`, while its state root uses a mutex for coherent read/install at `tuna/tuna/lib/runtime.ss:106-135`.

Concrete choices:

- **Single-thread/owner publication:** replace one immutable root directly.
- **Cross-thread coherent publication:** mutex-protected root getter and replacement, matching `CommandRuntime`.
- **Atom generation:** convenient when Tuna’s existing live-cell semantics are desired, but watcher work must remain short and `atom-deref` does not itself acquire the Atom mutex.

Hash tables also accept `lock:` directly: `gerbil/src/gerbil/runtime/hash.ss:385-405`. That protects mutation but does not make the table persistent or its contents immutable.

## 7. Hot-path implications

### Sorted vector

- Binary search compares only O(log B) candidate sequences.
- Each comparison examines at most L normalized events.
- Static bindings and sequences allocate at module initialization, not per lookup.
- Lookup can be allocation-free if the caller supplies an existing sequence and consumes singleton/result data without copying.
- Returning a fresh resolution struct adds one small allocation; at keyboard-event rates this is unlikely to dominate, but should be measured.
- Replacing a map is O(B) allocation and sorting/construction work, acceptable when configuration changes are uncommon.

### Alist

- No index construction.
- Linear pointer chasing and repeated sequence comparison.
- More pair objects and weaker locality than a vector.
- Functional update can share suffixes, but all sharing remains contractually immutable.

### Hash table

- Expected constant-time exact lookup, but hashing a sequence is O(L).
- Prefix detection needs another structure or an O(B) scan.
- Copy-on-write replacement is O(B) and shallow.
- Weak tables are invalid for required bindings.
- Custom equality/hash adds a correctness obligation without helping the sorted-vector design.

### Trie

- Natural prefix cursor and no repeated full-sequence search.
- More node and edge objects, branch indirection, and construction code.
- Sorted child vectors are persistent only by convention; hash children require shallow table copies at each changed node.
- A retained cursor can reduce repeated prefix work, but active-layer changes and translations may invalidate it.

**Decision threshold:** a trie becomes justified only if the sorted-vector implementation misses a measured latency/allocation budget for representative map sizes, layer counts, and prefix-heavy workloads.

## 8. Benchmark methodology

Gerbil’s own table benchmark provides the relevant idiom:

- parameterized implementations and element counts: `gerbil/src/gerbil/test/table-bench.ss:9-104`;
- correctness checks within benchmark setup: `table-bench.ss:106-135`;
- explicit `##gc` before each timed section and the `time` form around repeated work: `table-bench.ss:137-161`.

A fair keymap benchmark should:

1. benchmark alist, sorted vector, hash-plus-prefix-index, and trie through the same lookup interface;
2. use pre-normalized input for core lookup and a separate end-to-end normalization benchmark;
3. cover binding counts such as 16, 64, 256, and 1024, with measured real-world counts added later;
4. include sequence lengths 1-4 and realistic fan-out;
5. separate exact hits, misses, prefixes, explicit undefined, exact-plus-prefix, and remap hits;
6. vary layer counts and early/late winning layers;
7. benchmark rebuild/publication separately from lookup;
8. include static-only, occasional replacement, transient-layer, and computed-provider workloads;
9. precompute deterministic queries and consume results into a checked checksum so work cannot be discarded;
10. warm up, force garbage collection before timed batches, repeat batches, and report medians plus tail distributions;
11. bound or separately vary retention of old roots;
12. run the identical workload under source `gxi`, normal `gxc`, and `gxc -O`.

Do not mix compile-time macro parsing into hot lookup measurements. Record it separately as load/build cost.

## 9. Source and compiler compatibility

The proposed mechanisms—final structs, vectors, `vector-least-index`, `match`, `defsyntax`, `begin-syntax`, and public hash/Atom APIs—are active source APIs, not optimizer internals.

Tuna’s existing matrix:

- runs the suite through source `gxi`: `tuna/tuna/test/run-command-runtime-matrix.sh:29-39`;
- compiles modules normally and into an executable: lines 41-86;
- repeats compilation with `gxc -O`: lines 88-93;
- verifies worktree status remains unchanged: lines 95-101.

Tuna also records the ordinary macro phase boundary: newly expanded source can use a changed transformer, while already compiled expansions remain unchanged at `tuna/tuna/README.md:298-303`.

Constraints:

- keep compile-time parser dependencies in `(for-syntax ...)`;
- emit runtime constructors/data rather than leaking phase-1 objects;
- do not rely on `##` internals for the production lookup representation;
- do not confuse `gxc -O` module optimization with unsupported full-program optimization; Tuna’s README distinguishes these at `tuna/tuna/README.md:65-70`;
- the current matrix does not contain a keymap module because none exists, so it is not yet keymap validation.

## 10. Risks and unresolved gaps

- **High — no enforced immutability:** vectors, pairs, hashes, strings, and struct slots remain mutable. Published maps and every shared descendant require contractual immutability.
- **High — no supported persistent trie/map dependency:** the only HAMT is retired WIP source.
- **Medium — unresolved event identity:** semantic versus physical keys, modifier normalization, pointer events, and composition/repeat identity remain host/product decisions.
- **Medium — exact-plus-prefix semantics:** immediate resolution, timeout, replay, and layer precedence are intentionally not decided here.
- **Medium — active-layer semantics:** how prefixes from multiple layers merge, and whether explicit undefined suppresses lower-layer prefixes, requires a resolver contract.
- **Medium — computed-policy purity and latency:** arbitrary providers can allocate, block, or observe changing state; the static representation cannot constrain them.
- **Medium — no representative performance data:** map sizes, update frequency, prefix depth, and latency/allocation budgets are unknown.
- **Medium — installed/checkout skew:** relevant sources match, but the checkout is one commit newer and has unrelated dirty Gambit files.
- **Low — stale documentation surface:** some checkout reference documents describe retired modules, so active `/opt/gerbil/src` and active checkout source must remain the availability authority.

## Validation commands

No behavior tests were run during this read-only research task.

### Focused Gerbil collection baseline

```sh
cd /home/jay/Code/workbench-gerbil
gerbil test -g \
  gerbil/src/std/list/alist-test.ss \
  gerbil/src/std/list/walist-test.ss \
  gerbil/src/std/vector/vector-test.ss \
  gerbil/src/gerbil/test/table-test.ss \
  gerbil/src/std/sync/atom-test.ss
```

### Current full Tuna matrix

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil build
test/run-command-runtime-matrix.sh
```

The matrix is the evidence-backed source/normal/`-O` harness, but a future keymap module and its tests would need to be included in its explicit source list before it validates that subsystem.