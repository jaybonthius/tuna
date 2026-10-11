# Tuna immutable-state spike results

## Decision

The spikes support the simpler immutable-root design:

```text
(current revision, current opaque value)
  + live transition name and arguments
  -> unchanged(result)
   | changed(candidate value, result)
   | exception/rejection
```

One existing-style owner thread resolves the transition when dequeued. A changed outcome installs one new root; an unchanged or failed outcome retains the exact prior root object and revision. Publication is latest-state invalidation, not history or an event log.

Proceed to a small production design for this contract. Do not add a fact database, persistent history, Software Transactional Memory, a generic transaction manager, an effects engine, or an application state schema.

## Fixture

The independent fixture is outside Tuna application files:

- `research/fixtures/tuna-immutable-state-spike/src/workbench/tuna/state/spike.ss`
- `research/fixtures/tuna-immutable-state-spike/run.sh`

Source SHA-256:

```text
42c85afbdb85f411cabedb74d814843d7380efb0789f0707552db633880a364d
```

The fixture deliberately implements only enough mechanism to test the contract. Generated source, objects, executables, homes, and package environments are created beneath `/tmp`.

## Environment

```text
Workbench baseline: 6b22b3508a9675868aab9056b65fd88ceaa056b1
Tuna baseline:       806ece2dfd58c1ddd121e19f5b359f27a40a0e73
Gerbil checkout:    4531c21b90fa6ee04f374af905ae3ddb9d89d590
Runtime:            Gerbil v0.19-dev-31-g4a4d1a30
Gambit:             v4.9.7-6-g64f4d369
gxi:                /opt/gerbil/bin/gxi
gxc:                /opt/gerbil/bin/gxc
```

The pre-existing Gerbil dirt remained:

```text
M src/gambit/lib/_kernel.c
M src/gambit/lib/_module.c
M src/gambit/lib/_num.c
```

No Gerbil or Tuna source was modified by the fixture.

## Results

Run:

```sh
research/fixtures/tuna-immutable-state-spike/run.sh
```

All behavior passed under source `gxi`, normal `gxc`, and `gxc -O`:

```text
gxi: pass
gxc: pass
gxc -O: pass
worktree status: unchanged
```

The existing M8 matrix also remained green:

```sh
tuna/test/run-command-runtime-matrix.sh
```

```text
gxi: pass
gxc: pass
gxc -O: pass
worktree status: unchanged
```

### 1. Pure candidate and rollback semantics

Observed:

- a changed transition replaced `(revision, value)` once;
- an explicit unchanged result preserved the exact root object and revision;
- a raised transition preserved the exact root object and revision;
- direct transition invocation produced only a candidate outcome and could not install it;
- an off-owner installation attempt failed and left the root unchanged.

This gives rollback of in-memory authoritative decisions by discard, with no undo journal. It does not roll back effects performed by bad extension code.

### 2. Live transition bridge and runtime isolation

Observed:

- a request queued behind a fixture-only pause used a transition replacement made after admission but before dequeue;
- two runtime instances used the same live transition definition while retaining independent roots and revisions;
- ordinary `define-action!`/`invoke-action` behavior remained unchanged;
- the state root was not captured in a process-global transition closure.

This confirms that state transitions should be a distinct live definition class or metadata seam, while resolution remains at dequeue. Existing ordinary actions should not acquire state authority.

### 3. Coherent publication

The fixture used one mutex-protected `StateRoot` object and capacity-one channels. It passed:

- concurrent readers observing `revision = value` through 1,000 commits;
- install-before-completion ordering;
- one slow subscriber receiving one coalesced wakeup while rereading the latest root;
- 100 concurrent subscribe/install races without a missed-wakeup gap;
- unsubscribe and shutdown channel closure;
- full subscriber channels never blocking the owner.

This matches Gerbil's actual channel implementation: the configured bound is enforced by `channel-try-put`, which returns false when full (`gerbil-dev/src/std/sync/channel.ss:49-63`). `channel-sync` must not be used because it bypasses the bound (`channel.ss:65-75`).

The root is read under a mutex. Raw `atom-deref` remains inappropriate as the publication read seam because it is only the generated value accessor; synchronized Atom updates and watches use the Atom mutex (`gerbil-dev/src/std/sync/atom.ss:16-18,38-54`).

### 4. Immutability and aliases

The spike confirmed both sides of the contract:

- a functional list update shared an unchanged tail and preserved the old root;
- `vector-copy` was shallow: mutating a shared nested box changed the old vector's reachable value;
- an application-selected nested copy isolated the old value;
- copying a vector command payload before installation prevented later caller mutation from changing state;
- installing the mutable payload directly allowed later caller mutation to change the installed value.

Therefore Tuna cannot infer, freeze, or deep-copy arbitrary application values. The application and its transitions must guarantee transitive immutability of installed values, including values derived from command payloads. Tuna should validate only the transition outcome shape, not the application's data representation.

The installed v19 runtime has no `:std/srfi/146/hamt`; importing it fails with `cannot find library module`. The only HAMT source found is quarantined beneath `gerbil-dev/src/v0.19-WIP/`. Production M9 must not depend on it.

### 5. Effects

A sentinel transition returned an effect intent without running it. After command completion, the committed root was already readable; only then did the caller run the sentinel effect.

This demonstrates the required ordering but cannot enforce purity. The first production slice should document transitions as effect-free and add no generic effect runner. Applications may perform work after commit and submit its outcome as a later command.

## Throughput

The benchmark submits and completes 50,000 integer transitions while one subscriber remains full, exercising:

- bounded admission;
- dequeue-time transition resolution;
- candidate creation;
- mutex-protected root installation;
- failed nonblocking invalidation on every commit;
- one completion per command.

Median of the disposable repeated runs:

| Mode | Commands/second |
|---|---:|
| source `gxi` (3 runs) | 170,413 |
| normal `gxc` (5 runs) | 354,402 |
| `gxc -O` (5 runs) | 628,230 |

The earlier M8 no-op characterization was approximately 405,000 commands/second under normal `gxc` and 655,000 under `gxc -O`. The spike mechanism is therefore in the same range, especially under `-O`. This synthetic integer benchmark does not predict application transition cost.

No representative application state exists, so full-copy versus structural-sharing cost cannot yet be measured honestly. That remains a real-application gate, not a reason to add a persistent collection dependency now.

## Plan informed by the spikes

The smallest production slice should add:

1. one runtime-instance immutable root containing revision and opaque value;
2. one dedicated live state-transition definition seam, resolved at dequeue;
3. explicit `changed`, `unchanged`, and failure outcomes;
4. owner-only root installation;
5. coherent current-root reads under a private mutex;
6. atomic subscribe-plus-current-root acquisition;
7. one capacity-one invalidation channel per subscriber;
8. install, then invalidate, then complete ordering;
9. deterministic unsubscribe and shutdown closure;
10. behavior tests in source `gxi`, normal `gxc`, and `gxc -O`.

The application supplies the initial value, transition bodies, invariants, immutable representation, plugin-state composition, effects, persistence, history, and migration.

The production slice should not:

- alter ordinary action arity or return semantics;
- make state ambient through a parameter or M5 context;
- expose installation authority through direct invocation;
- deep-copy or compare application values;
- retain old roots as history;
- define application fields or a top-level map;
- add Datomic facts, event sourcing, undo, rollback journals, effects, or persistence.

## Follow-up implementation decision

The production slice selected a separate transition metadata registry while
retaining the ordinary live function wrapper. This keeps action acquisition
metadata and state-transition semantics independent without changing ordinary
action dispatch. The public vocabulary is `deftransition`, `state-changed`,
`state-unchanged`, `make-state-command-runtime`,
`command-runtime-submit-transition!`, `command-runtime-snapshot`, and opaque
state subscriptions.

A disposable benchmark against the production implementation, again using
50,000 integer transitions and one permanently full subscriber, measured medians
of approximately 323,000 commands/second under normal `gxc` and 591,000 under
`gxc -O`. The source, normal, and optimized behavior matrix passes. The spikes
therefore resolved the interface questions without changing the immutable
candidate/commit direction.
