# Tuna authoritative input/command runtime seams

## Answer

**Recommendation:** use **(B) the existing application-owned opaque runtime root** and model authoritative input handling as one live **state transition** submitted through `command-runtime-submit-transition!`.

The queued payload should be an immutable host-normalized event. At dequeue, an application-defined dispatcher transition receives the current opaque state value, resolves the event using application-owned keymap/input policy, then directly calls the selected live transition with `invoke-state-transition`. It returns that target’s `state-changed` or `state-unchanged` outcome to the existing owner for one installation:

```scheme
;; Conceptual composition using only existing public seams.
(deftransition application-dispatch-input (root input-event)
  (let-values (((target arguments) (application-resolve-input root input-event)))
    (apply invoke-state-transition target root arguments)))

(command-runtime-submit-transition!
 runtime
 'application-dispatch-input
 (list immutable-input-event))
```

The direct target invocation is intentional. Calling `command-runtime-submit-transition!` from the dispatcher would be nested submission: waiting would deadlock the sole owner, while not waiting would run the selected command later as a separate transaction.

This requires **no new Tuna input, keymap, host, or command-loop abstraction**. The smallest stable public seam is the existing transition composition boundary:

- enqueue an interned dispatcher transition name;
- pass an opaque immutable event;
- resolve from the current state value on the owner;
- invoke another live transition directly;
- return one explicit transition outcome.

This refines the prior recommendation in `research/tuna-keybinding-command-resolution-context.md:593-602`: host normalization and browser cancellation remain outside core, but when authoritative state-dependent re-resolution is required, it belongs inside one owner-executed transition rather than producer-side action selection.

**Confidence:** high for this mapping to current Tuna; medium for eventual input/keymap semantics because focus, sequence, mode, stale-event, and browser cancellation policies remain unsettled.

---

## Current seams and exact behavior

### Serialized ownership and dequeue-time state

`CommandRuntime` owns the bounded inbox, lifecycle, worker, optional root, and subscriptions (`tuna/tuna/lib/runtime.ss:31-74`). Its sole worker drains requests sequentially (`runtime.ss:211-223`), and tests prove handlers do not overlap across concurrent producers (`tuna/tuna/test/command-runtime-test.ss:195-216`).

For transition requests:

1. the owner reads the current coherent state value;
2. resolves the named transition;
3. computes an outcome;
4. installs only `StateChanged`;
5. posts completion after installation and invalidation.

Evidence: `tuna/tuna/lib/runtime.ss:137-178`.

Thus “current root” means the `StateRoot-value` current **at dequeue after earlier lane work**, not a snapshot taken by the producer. The transition does not receive the runtime revision; `revision` is read but unused at `runtime.ss:137-143`.

Only the worker may install state (`runtime.ss:114-135`). The revision and value are one mutex-protected root (`runtime.ss:43-45,106-125`).

### Live command resolution

Transitions use stable global cells and are looked up when invoked:

- registry and stable cells: `tuna/tuna/lib/bindings.ss:69-107,159-162`;
- transition publication: `bindings.ss:395-410`;
- live lookup/invocation: `bindings.ss:454-475`.

Queued replacement is proven at `tuna/tuna/test/state-runtime-test.ss:117-138`. Independent runtimes share definitions but retain distinct roots and revisions (`state-runtime-test.ss:143-167`).

Consequently the dispatcher and its selected transition both remain live:

- replacing the dispatcher before dequeue changes resolution policy;
- replacing the selected target before its direct invocation changes command behavior;
- redefining either globally affects every runtime instance, while root-resident keymaps can remain per-runtime.

There is no multi-definition/configuration transaction. Concurrent replacement may expose individually coherent old or new definitions, but policy, target, and other cells are not one atomic generation.

### Commit, rollback, and publication

Changed outcomes install one new revision; unchanged, raised, or invalid outcomes preserve the prior state (`runtime.ss:137-153`; `state-runtime-test.ss:75-115`). Installation and invalidation precede command completion (`runtime.ss:114-135,175-178`).

Subscriptions are coalesced invalidations, not command or event delivery. Registration atomically returns the current revision/value/subscription (`runtime.ss:294-310`); readers must reread the latest snapshot. Tests cover coherent publication and install-before-completion (`state-runtime-test.ss:196-248`).

Immutability is contractual. Tuna neither freezes nor copies roots or payloads, and external effects cannot be rolled back (`tuna/tuna/README.md:164-179`). Accepted payloads remain caller-owned by reference but must not be mutated until completion (`runtime.ss:247-259`; `README.md:115-117`).

### Existing actions are not the authoritative state seam

Actions coherently bundle implementation, host descriptor, and context-to-arguments acquisition (`tuna/tuna/lib/bindings.ss:41-46,369-393,437-452`). They are appropriate for ordered effects and host-derived arguments, but:

- they receive no runtime state or revision;
- ordinary results are not state outcomes;
- their effects survive failure;
- `command-runtime-submit-with-context!` preselects the action name and cannot resolve it from the current root;
- capturing a runtime in an action and submitting a transition from inside it creates the forbidden nested-submission shape.

Runtime action dispatch is at `tuna/tuna/lib/runtime.ss:161-170`; the state bridge exists only for transition mode at lines 170-171.

### Tuna `Event` is unrelated

`Event` is a synchronous listener collection, not queued input. It snapshots registrations, invokes listeners on its caller’s thread, and fails fast (`tuna/tuna/lib/event.ss:74-88`). It owns no runtime root or revision. The README distinguishes it from asynchronous state invalidation at `tuna/tuna/README.md:181-205`. It should not be repurposed as the input command lane.

### Typed descriptors and configuration constraints

`callable-descriptor` distinguishes `function`, `action`, and `state-transition` (`tuna/tuna/lib/bindings.ss:247-304,326-343`; tests at `tuna/tuna/test/documentation-test.ss:63-99`). It provides lookup by a known name only—no enumeration, keymap metadata, arity schema, or universal command kind.

A descriptor precheck cannot be authoritative because the name can change kind afterward. Invocation should remain the authority and return a controlled undefined/wrong-kind error.

Configuration:

- evaluates trusted forms sequentially and partially applies before failure (`tuna/tuna/lib/config.ss:29-41`);
- is loaded before runtime start in the current executable (`tuna/tuna/main.ss:11-20`);
- currently starts a **stateless** runtime (`main.ss:15-16`);
- has no live keymap schema or serialized reload operation.

The clean Tuna tree contains no `CONTEXT.md` or Architecture Decision Record settling input/keymap ownership. The governing exclusion is `plans/emacsen-runtime/checklist.md:388-399`: input decoding, keymaps, command remapping, and host event loops are host-layer concerns.

---

## State ownership comparison

| Shape | Atomicity and revision coherence | Independent roots/live replacement | Configurability and future Emacs features | Assessment |
|---|---|---|---|---|
| **A. Tuna-standard envelope: application/input/keymap** | Excellent if every field is replaced in one transition and revision. Prefix state plus application changes can commit together. | Roots remain independent; live definitions remain process-global. | Central schema could support modes, prefix state, command history, transient maps, and tooling, but Tuna must define fields, lenses, lifecycle, and migration before a host establishes them. | **Not recommended now.** It contradicts the opaque-state contract (`README.md:128-171`) and explicit host exclusions. |
| **B. Application-owned opaque root with application resolver/lens** | Same single-root atomicity as A without Tuna interpreting fields. Dispatcher and selected transition form one pure call stack and one commit. | Current design already proves independent roots. Root-resident keymaps can differ per runtime; dispatcher/target definitions replace live globally. | Application owns keymap persistence, modes, point/focus projections, prefix state, prior-command state, and representation. Tuna remains schema-neutral. | **Recommended.** Smallest shape matching current code and prior immutable-state evidence (`research/gerbil-immutable-state-feasibility.md:5-17,223-238`). |
| **C. Runtime root plus separately owned input/keymap state** | Weak unless both states are committed under one combined root/transaction. Otherwise application snapshots, input state, revisions, subscriptions, and rollback can disagree. Combining their commit record effectively turns C into A. | Can be per-runtime if added to `CommandRuntime`; process-global live values would break per-runtime independence. | Convenient for ephemeral prefixes or device-local state, but unclear whether input-only changes increment the application revision or publish to subscribers. | Suitable only when sequence state is explicitly non-authoritative/host-local. Not suitable for the requested authoritative coherent loop without a new dual-state protocol. |

### Why B best preserves current constraints

The current contract deliberately gives Tuna one opaque application value without defining its shape (`tuna/tuna/README.md:128-155`). Earlier feasibility research concluded that an application adapter or opaque root is the strongest schema-neutral boundary because Gerbil cannot enforce transitive immutability (`research/gerbil-immutable-state-feasibility.md:5-17,303-318`).

B also permits a complete key sequence or transient-mode update and the selected application command to produce one replacement root. The application dispatcher must compose both changes into the candidate; Tuna cannot provide a generic lens because it does not know the root schema.

---

## Command target comparison

### 1. Existing state transitions — recommended

**Strengths**

- Receive the exact current opaque state value.
- Return explicit changed/unchanged outcomes.
- Preserve rollback-by-discard on failure.
- Resolve live names on invocation.
- Can be directly composed without exposing installation authority.
- Produce one coherent revision for input-state and application-state changes.

**Constraint:** the selected target must understand the application’s whole root or be called through an application lens/reducer. Tuna supplies no fragment composition.

### 2. Existing actions

**Strengths**

- Already live and dequeue-resolved.
- Host descriptor and argument acquisition are generation-coherent.
- Appropriate for non-authoritative ordered effects.

**Deficiencies for this task**

- No current state or revision.
- No installable candidate outcome.
- No rollback for effects.
- Producer must already know the action name for current submission modes.
- A symbol cannot simultaneously remain an action and transition: defining one clears the other (`tuna/tuna/lib/bindings.ss:369-410`; lifecycle tests at `state-runtime-test.ss:169-194`).

Actions can be emitted after commit by application policy, but they cannot be the atomic authoritative state command.

### 3. New command domain

A new live domain could combine command metadata, state access, argument acquisition, and transition outcomes. It could eventually provide a cleaner conceptual distinction between user commands and low-level reducers.

However, it would duplicate established transition behavior and require new rules for:

- aliases and replacement;
- descriptors and discovery;
- action/transition coexistence;
- direct invocation;
- effects and rollback;
- target validation;
- configuration publication.

No current test or host requirement demonstrates that gap. Existing transition composition is smaller and avoids inventing a generic “command” concept before deciding whether commands are editor operations, browser intents, reducers, or effects.

---

## Exact behavioral test seam

The highest stable test seam is the public state-runtime boundary, not a keymap data structure.

A focused behavior fixture should establish:

1. Start a state runtime with an application-owned root containing application data and minimal input/keymap policy.
2. Block the owner with the existing hold-action pattern.
3. Queue a state-changing transition ahead of an input-dispatch transition so the event must resolve against the newer dequeue-time root.
4. Replace the selected target transition after event admission but before dequeue.
5. Release the owner.
6. Assert:
   - the dispatcher selected according to the newer root;
   - the new target implementation ran;
   - dispatcher and target ran on the same owner call stack without a second submission;
   - exactly one candidate from the input request was installed;
   - completion followed installation;
   - the final revision/value pair is coherent.
7. Select a target that raises and assert the entire input request—including any tentative prefix reset—leaves the exact prior revision/value installed and that a later command succeeds.
8. Run two runtimes with different root-resident maps and the same global dispatcher/target definitions; assert different resolution with independent revisions.
9. Verify an unhandled event returns `state-unchanged` and does not increment revision.

Existing patterns supporting this seam:

- queued live replacement: `tuna/tuna/test/state-runtime-test.ss:117-138`;
- independent roots: `state-runtime-test.ss:143-167`;
- rollback outcomes: `state-runtime-test.ss:75-115`;
- coherent revision/publication: `state-runtime-test.ss:196-248`;
- owner serialization: `tuna/tuna/test/command-runtime-test.ss:195-216`.

Browser focus, default cancellation, Input Method Editor composition, editable controls, and accessibility still require host/browser tests. The prior report establishes why a server round trip cannot make synchronous `preventDefault` decisions (`research/tuna-keybinding-command-resolution-context.md:447-466,671-682`).

---

## Risks and unresolved decisions

- **High — nested submission:** `submit-command-request!` does not reject owner-thread submission (`tuna/tuna/lib/runtime.ss:261-288`). An owner handler that submits and waits can deadlock; submitting without waiting loses atomicity and current-root coupling.
- **High — external effects:** transition composition rolls back only the root candidate, never files, network operations, messages, mutable globals, or action effects (`tuna/tuna/README.md:164-179`).
- **High — mutable aliasing:** submitted events and installed roots are not copied or frozen. Mutation after admission/publication can corrupt authoritative history.
- **High — premature core schema:** A standard Tuna input/keymap envelope would conflict with the current opaque-state contract and explicit host exclusions.
- **Medium — revision visibility:** transitions receive the state value but not its runtime revision (`runtime.ss:137-143`). Observed-revision rejection requires an application version inside the opaque value or a future revision-aware seam.
- **Medium — global replacement:** live definitions are process-global, so redefining a dispatcher or command affects all runtime instances. Per-runtime differences must be state-driven.
- **Medium — nontransactional config:** sequential config reload could expose mixed policy/target generations; runtime-serialized configuration replacement does not exist.
- **Medium — descriptor gap:** known-name typed lookup exists, but enumeration, keybinding schemas, command argument schemas, and configurable binding discovery do not.
- **Medium — head-of-line blocking:** resolution and target execution occur on the sole owner; slow keymap predicates or commands stall every queued request.
- **Medium — command kind:** replacing a transition with an action/plain function before dequeue makes the queued authoritative invocation fail. That is currently coherent lifecycle behavior, not transparent migration.
- **Medium — browser authority split:** the owner must decide whether the server receives raw normalized events, client-resolved command intents, or both for validation. Browser cancellation cannot await the server.

### Owner decisions still required

1. Whether authoritative resolution receives raw normalized events or validates client-resolved command intents.
2. Whether authoritative commands are transition-only or require a future unified state/effect command domain.
3. Whether prefix/sequence state is revisioned application state or explicitly host-local ephemeral state.
4. Whether stale-event policy needs access to the runtime revision.
5. Whether keymap replacement is per-runtime revisioned data, process-global live configuration, or both with defined precedence.
6. The application-specific outcomes for unhandled input, prefixes, abort, repeat, timeout, and command results.

---

## Validation commands

No tests were run during this read-only research.

Focused existing seam:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil test test/state-runtime-test.ss
gerbil test test/command-runtime-test.ss
gerbil test test/documentation-test.ss
```

Full Tuna validation:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil build
test/run-command-runtime-matrix.sh
```

The matrix compiles and runs command, state, event, and documentation suites under source `gxi`, normal `gxc`, and `gxc -O`, then verifies both worktrees remain unchanged (`tuna/tuna/test/run-command-runtime-matrix.sh:1-101`).