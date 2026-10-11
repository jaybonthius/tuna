# Tuna input/keymap API options

## Executive answer

**Recommend option 1:** add one small, pure Tuna keymap/resolver library, while keeping authoritative orchestration in an application-owned dispatcher state transition over the existing opaque root.

The public module should own only normalized key identity, immutable-by-contract keymap construction, ordered layered lookup, and four explicit results: **exact**, **continuation**, **undefined**, and **absent**. The application should own:

- keymaps and prefix/input state inside its one immutable root;
- deriving the current ordered active maps from that opaque root;
- argument acquisition;
- transient/modal/positional policy;
- clearing or extending prefix state;
- direct atomic invocation of the selected live state transition.

Do **not** add process-global live keymap cells, a new runtime request kind, or a new command registry/domain in v1. Bindings name existing live state transitions and may carry an opaque immutable argument specification. This gives Tuna a reusable deep module without teaching the runtime an application state schema.

This recommendation reconciles the owner-set browser-terminal model with the existing runtime evidence: the browser transports normalized events, while the serialized owner resolves each event against the dequeue-time application root. The dispatcher directly invokes its selected transition and returns one combined state outcome; it never submits nested work.

## Evidence used

This evaluation is based on the three assigned research artifacts rather than a new source investigation:

1. `research/tuna-keybinding-command-resolution-context.md`
   - Emacs reads a sequence against currently active maps, merges layered prefix behavior, distinguishes absence from explicit `undefined`, performs translation before lookup and one-level command remapping afterward, and acquires arguments separately from command selection (sections 1, lines 24-243).
   - Lookup context and command behavior are distinct; arbitrary behavior predicates do not belong in the keymap engine (section “Selection versus behavior,” lines 337-348).
   - Browser default cancellation, Input Method Editor (IME) composition, native editing, and accessibility cannot be decided after a server round trip (sections 3, lines 351-467). That remains a transport/product constraint even though the owner has now chosen server-authoritative resolution.
   - Tuna already has dequeue-time live names, an opaque revisioned root, and serialized execution, while prior roadmap scope excluded host input policy from the runtime (sections 5-6, lines 498-618).

2. `research/tuna-input-command-runtime-seams.md`
   - The proven composition seam is a named dispatcher transition which resolves from the current root and directly calls `invoke-state-transition`; nested submission either deadlocks or loses atomicity (lines 3-35).
   - Root-resident policy preserves per-runtime independence and one coherent commit without forcing a Tuna-owned envelope (state ownership comparison, lines 116-130).
   - Existing transitions already provide live resolution, current-state access, explicit changed/unchanged outcomes, and direct composition. Actions lack the authoritative state seam; a new command domain duplicates unresolved behavior (lines 132-181).
   - The highest behavior seam is the public state runtime, including newer dequeue-time state, live target replacement, one installation, rollback, and independent roots (lines 183-215).

3. `research/gerbil-v19-keymap-implementation-idioms.md`
   - A hidden sorted vector of full normalized sequences is the recommended minimal backing; active Gerbil has no supported persistent map/trie dependency (lines 3-15, 33-97, 207-229).
   - Final structs are the established result-variant idiom, although all values remain immutable only by contract (lines 99-120).
   - Normalized events, sequence vectors, live symbolic targets, and the absent/undefined/prefix/command distinction have direct implementation support (lines 122-205).
   - Translation, remap, transient, and computed behavior can remain separate resolver stages/providers, allowing a later trie without changing the public seam (lines 217-229).

## Product and architecture constraints

The following are treated as settled, not reopened:

- The browser is a terminal. It reports normalized host events but does not own semantic view, mode, focus, keymap, prefix, or command state.
- Tuna’s application root is the one authoritative immutable value for semantic application, user-interface, and input concepts.
- Rendering is a function of that state.
- Resolution runs on the serialized owner against the current root, not producer-side state.
- The first API must remain small while leaving an explicit path to layered, positional, modal, transient, translated, remapped, and computed behavior.
- Proven Emacs selection semantics are the default unless Tuna’s immutable state/transaction model offers a clearer or safer rule.

A consequence should be stated plainly: server-authoritative resolution cannot synchronously decide browser `preventDefault`. A browser terminal therefore needs a nonsemantic transport/capture policy established ahead of time, and v1 should avoid native editable controls, broad printable interception, and IME-sensitive shortcuts until that policy has browser evidence. The terminal may decide whether an event is safe to transport/cancel; it must not select the semantic command.

## Materially different API shapes

### Option 1 — Generic Tuna keymap/resolver plus application dispatcher and opaque root

**Shape**

- Tuna supplies a pure `keymap` module with opaque maps and explicit resolution values.
- The application stores maps, active-mode/transient state, and the current prefix in its immutable root.
- An application transition derives ordered active maps from the current root, calls the pure resolver, acquires arguments, and directly invokes the selected live transition.
- The existing runtime sees only an ordinary transition request carrying an immutable normalized event.

**Strengths**

- Adds one reusable deep module without changing runtime request, lifecycle, descriptor, or installation protocols.
- Gives applications one canonical definition of layered prefix lookup and absent-versus-undefined behavior.
- Keeps application-specific state projection outside Tuna; the resolver never needs a lens into an opaque root.
- Preserves per-runtime maps and atomic input/application updates.
- Symbolic transition targets retain existing dequeue/invocation-time live replacement.
- Hidden sorted-vector backing can become a trie later without changing consumers.

**Costs and constraints**

- Every application still writes a small dispatcher adapter because Tuna cannot generically clear a prefix or replace part of an opaque root.
- Argument acquisition remains application code rather than a universal interactive-spec language.
- A generic keymap module creates a compatibility surface, so v1 semantics must be deliberately narrow.

**Assessment:** recommended. This is the smallest shared interface that captures difficult, reusable lookup semantics while respecting the opaque-root boundary.

### Option 2 — Application-only composition using existing transitions

**Shape**

Each application defines its own event representation, maps, resolver, dispatcher transition, prefix state, and target/argument conventions. Tuna adds no public keymap API. The application still directly invokes selected transitions through the existing seam.

**Strengths**

- Zero Tuna API or runtime growth.
- Maximum freedom while the first application discovers its modes, focus, and input vocabulary.
- Fully consistent with current state-transition composition evidence.

**Costs and constraints**

- Layer precedence, prefix merging, explicit undefined, and exact/continuation distinctions become application conventions rather than a stable reusable contract.
- Separate Tuna applications can silently diverge from Emacs semantics.
- Reuse, documentation, configuration tooling, and behavior-facing fixtures arrive later and may require migration from ad hoc data.
- It gives up the requested high-leverage shared seam even though the representation and semantics are now sufficiently bounded.

**Assessment:** viable fallback if no second consumer is expected, but less attractive after the owner explicitly committed to sophisticated future input behavior. It saves a small module now at the cost of duplicating the hardest rules later.

### Option 3 — Runtime-native input request and new command domain

**Shape**

Add concepts such as `command-runtime-submit-input!`, a runtime input request variant, runtime-owned resolver/configuration state, and a new live `command` registry that combines state transition, argument acquisition, and command metadata.

**Strengths**

- Could make input submission and command discovery look uniform.
- Could centralize command metadata, remap information, and argument acquisition.
- The runtime could enforce direct invocation internally.

**Costs and constraints**

- Duplicates existing transition live cells, invocation, outcome, descriptors, and lifecycle semantics.
- Forces Tuna to define how a generic command relates to actions, transitions, effects, rollback, aliases, and replacement before evidence requires it.
- Runtime-owned keymaps or prefix state either violate the one opaque authoritative root or require a new transaction joining two state owners.
- Process-global command/keymap publication conflicts with independent runtime roots and makes configuration generations non-atomic.
- Adds a new wire/request compatibility surface even though an ordinary transition request already reaches the correct serialized owner.

**Assessment:** reject for v1. A future command domain is justified only if multiple non-keyboard invocation sources demonstrate a shared need that transitions cannot express. No assigned evidence shows such a gap.

### Comparison

| Criterion | Option 1: pure library + app dispatcher | Option 2: app only | Option 3: runtime-native domain |
|---|---|---|---|
| Runtime changes | None | None | Substantial |
| One-root atomicity | Yes | Yes | Only with a new joined protocol |
| Reusable lookup semantics | Yes | No | Yes |
| Per-runtime keymaps | Naturally root-owned | Naturally root-owned | Ambiguous unless root-owned |
| Existing live transition targets | Reused | Reused | Duplicated or wrapped |
| Evolution to Emacs-like stages | Explicit staged path | Application-specific | Powerful but premature |
| Compatibility risk | Small public module | Local only | High, hard to reverse |

## Recommended public API

The following is **illustrative Gerbil-shaped API**, not an implementation or a claim that these identifiers already exist.

```scheme
;; Canonical binding identity. Raw browser metadata is not part of map identity.
(make-key-stroke domain code modifier-bits)       ; -> KeyStroke
(key-stroke? value)

;; Opaque immutable-by-contract sequence values.
(empty-key-sequence)                              ; -> KeySequence
(key-sequence-append sequence stroke)             ; -> KeySequence
(key-sequence-length sequence)                    ; -> exact integer

;; A target is an existing state-transition name plus application-owned,
;; immutable argument recipe data. The keymap never interprets argument-spec.
(make-transition-key-binding transition-name argument-spec)
(transition-key-binding? value)
(transition-key-binding-name binding)
(transition-key-binding-argument-spec binding)

;; Runtime construction. Entries are (sequence, binding) or
;; (sequence, key-undefined). Construction validates, copies, and sorts.
(make-keymap entries)                             ; -> Keymap
(keymap? value)
key-undefined                                     ; explicit fallback stopper

;; Maps are ordered highest precedence first.
(resolve-key-sequence ordered-keymaps sequence)   ; -> one result below

(key-exact? result)
(key-exact-binding result)
(key-exact-sequence result)
(key-continuation? result)
(key-continuation-sequence result)
(key-undefined? result)
(key-undefined-sequence result)
(key-absent? result)
(key-absent-sequence result)
```

### Value contracts

- `domain` distinguishes at least logical/named key identity from physical key position. The application/browser protocol chooses which domain a binding uses; it must not assume a United States keyboard layout.
- `code` is a validated character, integer, or controlled string/token. Externally supplied arbitrary strings must not be interned into an unbounded symbol namespace.
- `modifier-bits` is canonical; aliases and platform “primary modifier” normalization happen before construction according to application protocol.
- A key sequence is nonempty when installed as an entry.
- A transition name is a trusted interned application symbol, never a procedure captured in the map and never a browser-selected arbitrary command.
- `argument-spec` is opaque to Tuna and immutable by the same contract as the root. It can be a fixed argument list or application data interpreted during acquisition.
- `make-keymap` rejects duplicate sequences and rejects an exact definition whose sequence is also the strict prefix of another definition **within the same map**. This avoids an unreachable exact-plus-continuation ambiguity. Cross-layer shadowing remains valid.
- Map internals are not exposed. The initial backing should be a sorted vector of full sequence/definition entries.

A declaration macro and key-string parser are intentionally absent from the minimal API. Runtime construction supports configuration data and gives one validation path. A later literal macro may compile into this constructor without changing lookup.

## Precise resolution semantics

For one map and one complete candidate sequence, the private contribution is:

- **exact:** the sequence has a transition binding;
- **undefined:** the sequence has the explicit `key-undefined` definition;
- **continuation:** the sequence is a strict prefix of at least one entry;
- **absent:** none of the above.

The resolver inspects active maps in supplied precedence order. The first non-absent contribution wins:

1. exact returns `KeyExact`;
2. explicit undefined returns `KeyUndefined` and suppresses every lower map;
3. continuation returns `KeyContinuation` and suppresses a lower exact binding at that shorter sequence;
4. absent falls through to the next map;
5. all maps absent returns `KeyAbsent`.

On the next event, the application appends to the root-resident prefix and resolves the **whole sequence again against the then-current active maps**. This gives Emacs-like merged prefixes without retaining internal map cursors: if a higher map has no definition for the extended sequence, a lower map’s extension can resolve. It also intentionally allows active maps to change between events, matching the evidence that Emacs recomputes relevant maps while reading.

Within one static map, exact-plus-continuation is rejected. Across maps, a higher exact shadows all lower exacts and continuations; a higher continuation shadows a lower exact at that sequence. No timeout or ambiguous result exists in v1.

### Terminal outcomes

- `KeyContinuation`: store the extended prefix in the application root and return a changed state outcome.
- `KeyExact`: acquire arguments, clear the prefix in a candidate root, invoke the named transition directly on that candidate, and combine its outcome into the dispatcher’s one outcome.
- `KeyUndefined`: clear the prefix and apply the application’s explicit-undefined feedback policy; never fall through.
- `KeyAbsent`: clear the prefix and apply the application’s unbound-input policy. With no existing prefix and no feedback state, this may be state-unchanged.

Undefined and absent remain observably distinct even if the initial application displays the same message.

## Application adapter and atomic invocation

Because Tuna cannot inspect the opaque root, active maps are supplied by ordinary application code, not by a Tuna registry or root lens:

```scheme
;; Application-owned functions, shown schematically.
(application-input-prefix root)                    ; -> KeySequence
(application-active-keymaps root request)          ; -> ordered Keymap list
(application-with-input-prefix root sequence)       ; -> new root
(application-clear-input-prefix root resolution)    ; -> new root
(application-acquire-input-arguments
  root request sequence binding)                    ; -> argument list
```

The dispatcher is an ordinary live state transition:

```scheme
(deftransition application-dispatch-input (root request)
  (let* ((stroke   (application-normalized-stroke root request))
         (sequence (key-sequence-append
                     (application-input-prefix root)
                     stroke))
         (maps     (application-active-keymaps root request))
         (result   (resolve-key-sequence maps sequence)))
    (cond
     ((key-continuation? result)
      (state-outcome-for
       root
       (application-with-input-prefix root sequence)))

     ((key-exact? result)
      (let* ((binding (key-exact-binding result))
             (args (application-acquire-input-arguments
                    root request sequence binding))
             (base (application-clear-input-prefix root result))
             (target-outcome
              (apply invoke-state-transition
                     (transition-key-binding-name binding)
                     base
                     args)))
        (compose-input-and-target-outcome root base target-outcome)))

     ((key-undefined? result)
      (application-finish-undefined root request result))

     (else
      (application-finish-absent root request result)))))
```

`state-outcome-for`, `compose-input-and-target-outcome`, and the finish functions are application adapters because only the application can compare/replace its root shape and record user-visible feedback. They are not proposed Tuna exports.

Atomicity rules:

- The dispatcher and target execute on the same owner call stack.
- The dispatcher must call `invoke-state-transition` directly. It must never call a runtime submit function from inside the owner.
- Arguments are acquired from the original current root, request, full invoking sequence, and binding specification.
- The target receives the candidate root with terminal prefix state cleared.
- If the target returns changed, its candidate is the dispatcher candidate.
- If the target returns unchanged but clearing the prefix changed the root, the dispatcher returns that prefix-cleared candidate as changed.
- If argument acquisition or target invocation raises, the dispatcher raises and the existing runtime installs nothing. Therefore application state, including the previous prefix, remains unchanged. External effects still cannot be rolled back.

The last rule diverges from Emacs’s ordinary “sequence consumed even when a command errors,” but it is the clearer Tuna v1 transaction rule: one request either installs one coherent candidate or installs nothing. Changing it later would require an explicit error-as-state protocol rather than a partial commit hidden in the resolver.

### Argument acquisition

V1 deliberately does not copy Emacs `interactive` specifications or permit a resolver to read more input.

- Fixed arguments may be stored directly in `argument-spec`.
- State/event-derived arguments are computed by the application acquirer after exact selection and before target invocation.
- The full normalized request and invoking sequence are available to acquisition, while semantic focus, selection, point, mode, and prefix arguments come from the authoritative root.
- Acquisition must be synchronous and must not submit runtime work.
- Prompts, minibuffers, universal arguments, and other read-more interactions are modeled as application state transitions which install a prompt/transient mode; later normalized events continue that state machine.

This preserves the Emacs distinction between command selection and interactive argument computation without adding an open-ended generic argument language.

## Ownership decisions

### Keymaps: immutable application state, not process-global live cells

Authoritative maps and their ordering belong in the application root. Immutable map snapshots can structurally share module-created constants, but changing policy means installing a new root (or a new root reference), not mutating or rebinding a global keymap cell.

Reasons:

- two runtimes can have different modes/configuration while sharing live transition definitions;
- maps, active modes, prefix state, and application changes can commit coherently in one revision;
- configuration does not expose mixed global policy generations;
- Tuna keeps its opaque-root contract.

Existing transition implementations remain process-global live definitions by current Tuna design. Thus the root decides **which name** is selected, while `invoke-state-transition` resolves **the current implementation** of that name.

### Targets: existing state-transition names, not a new command domain

V1 authoritative bindings target only existing state transitions. Actions do not receive/install current state, and a new command domain has no demonstrated semantic gap to fill. Wrong-kind or undefined targets fail authoritatively at invocation; descriptor prechecks may improve diagnostics but must not be treated as authoritative because live definitions can change.

If future evidence shows that a user command must atomically combine state change, durable effects, discovery metadata, and non-keyboard invocation in a way transitions cannot express, that is the threshold for reconsidering a command domain.

### Prefix state: authoritative root state

The root owns the accumulated sequence and any future numeric argument, prompt, transient, repeat, or translation state. The browser does not own a semantic chord buffer. Every event is resolved from the latest dequeue-time root, and continuation itself is a revisioned state transition.

## Forward-compatible staged pipeline

The recommended architecture has explicit stages, but only the middle lookup stage becomes generic in v1:

1. **Host normalization** — browser transport produces a normalized request; no semantic command selection.
2. **Application validation/context** — owner validates the request against current state.
3. **Translation** — future ordered state-derived providers transform sequences before lookup.
4. **Active-map supply** — application derives ordered transient, positional, modal, local, and global maps from the root.
5. **Lookup** — v1 `resolve-key-sequence` returns exact/continuation/undefined/absent.
6. **One-level remap** — future state-derived provider maps the selected transition name once, using the same active context.
7. **Argument acquisition** — application interprets the binding’s opaque argument specification.
8. **Direct invocation** — existing live state transition runs on the prefix-cleared candidate root.
9. **Post-command state** — target/dispatcher returns one candidate containing history, repeat/transient, feedback, and application updates.

No stage callback is captured inside a keymap. Dynamic behavior is obtained by deriving maps or transformations from the current root in the dispatcher. This keeps map lookup pure and bounded.

Evolution examples:

- **Layered/local/modal/positional maps:** change `application-active-keymaps`; resolver API unchanged.
- **Transient/repeat maps:** store transient state in the root and prepend its map while active.
- **Dynamic computed bindings:** compute an immutable map/provider contribution from the current root before lookup; cache only inside authoritative immutable state if needed.
- **Translation:** introduce a separate pure sequence transformation before lookup. Keep raw and translated prefix data in application state if replay/debugging requires both.
- **Remapping:** apply exactly one post-lookup name substitution by default, preserving Emacs’s nonrecursive remap rule.
- **Trie optimization:** replace hidden sorted-vector lookup after representative benchmarks; public values and results remain unchanged.
- **User configuration:** parse into a validated map snapshot, then install that snapshot through an application transition.

## Invariants

1. One runtime root is authoritative for semantic application, UI, keymap, mode, and prefix state.
2. A submitted event payload is immutable by contract until completion.
3. Resolution uses the root current at dequeue after all earlier owner work.
4. Active maps are ordered high-to-low and derived from that same root/request.
5. Keymaps contain symbolic transition names, never captured transition procedures.
6. Explicit undefined suppresses lower layers; absence permits fallback.
7. Continuation is authoritative state, not browser-owned hidden state.
8. Terminal resolution clears prefix state in the candidate presented to the target.
9. Dispatcher and target form one direct call stack and at most one state installation.
10. No owner handler performs nested runtime submission.
11. Raised acquisition/target work installs no root; external effects remain outside rollback.
12. Resolver lookup is pure, nonblocking, and does not read global mutable policy.
13. Map backing and all shared descendants are immutable by contract.
14. Remap, when introduced, is one level by default.
15. Browser transport/capture behavior never becomes semantic command authority.

## Minimal v1 scope

Include only:

- canonical key-stroke and sequence values;
- runtime keymap construction with validation;
- transition binding plus opaque argument specification;
- explicit undefined entries;
- ordered layered exact/continuation/undefined/absent resolution;
- application-owned prefix and active-map adapters;
- direct existing-transition invocation in an application dispatcher;
- behavior tests through the public state-runtime boundary plus focused pure resolver contract tests.

Exclude from v1:

- pointer/touch gestures;
- keyup and repeat policy;
- printable text editing and IME composition behavior;
- key-string declaration syntax and macros;
- process-global live keymap publication;
- a Tuna-owned application root envelope or lens;
- arbitrary predicates/procedures stored in maps;
- translation providers and command remapping implementation;
- timeout/replay for exact-plus-prefix ambiguity;
- prompts, minibuffers, universal arguments, and blocking read-more acquisition;
- a new action/command/input request domain;
- keymap enumeration, persistence schema, or user-facing customization protocol;
- performance-driven trie/hash indexes before representative benchmarks.

## Acceptance behavior and highest public test seam

The primary acceptance seam is the existing public state runtime, not access to the sorted vector. A behavior fixture for the recommended API should demonstrate:

1. An event queued behind an earlier state change resolves from the newer dequeue-time root.
2. Two runtimes sharing live transition definitions but holding different root-resident maps resolve the same event differently.
3. A target redefined after admission but before invocation runs its new live implementation.
4. Higher exact shadows lower exact/continuation.
5. Higher continuation suppresses a lower exact at the shorter sequence, while a later extended sequence may resolve from a lower map.
6. Explicit undefined suppresses lower exact; absence falls through.
7. Continuation installs the prefix; terminal resolution presents a prefix-cleared candidate to the target.
8. A target returning unchanged still commits prefix clearing when needed.
9. A raising target installs neither its candidate nor the tentative prefix clear, and a later request still succeeds.
10. One input request produces at most one revision installation, with completion after installation.
11. No second request is enqueued for the selected target.
12. Wrong-kind/undefined live targets fail in a controlled way without installation.

Focused resolver tests should cover constructor rejection, sorted-order independence, all four results, cross-layer prefix behavior, and immutability-by-contract documentation. Browser tests remain necessary for the predeclared transport/capture policy, layout handling, focus transport, native editable controls, accessibility, IME, and repeat; Gerbil tests cannot validate those constraints.

## Migration path

### From option 2 application-only code

Adopt the canonical `KeyStroke`, `KeySequence`, `Keymap`, and result values behind the existing application dispatcher. Keep root shape, prefix location, active-map derivation, argument acquisition, and target transitions unchanged. Replace only the application’s private lookup routine.

### From recommended v1 to richer Emacs-like behavior

Add stages around `resolve-key-sequence`, not fields inside its backing vector:

- translation before lookup;
- more state-derived active providers for positional/modal/transient layers;
- one-level remap after exact selection;
- prompt/argument modes as ordinary root state and transitions;
- later backing replacement after benchmarks.

Existing static maps and transition bindings remain valid.

### If a new command domain eventually becomes necessary

Introduce it as a separate target type only after its state/effect/metadata contract is settled. During migration, command entries can delegate to existing transitions; do not silently reinterpret every transition as a command or move keymaps out of application state.

## Hard-to-reverse decisions and ADR assessment

- The sorted-vector backing is private and reversible; it does not justify an Architecture Decision Record (ADR).
- Root-owned versus process-global keymaps and reuse of transitions versus a new command domain are architectural boundaries. The owner’s one-authoritative-state decision settles the former for this design.
- A concise ADR would be justified **before** adopting option 3, process-global keymap cells, a second authoritative input state owner, or a new command registry because each changes runtime compatibility and transaction semantics.
- No ADR or implementation plan is created by this research artifact.

## Residual risks

- **High — browser capture/default behavior:** server resolution arrives too late for synchronous default cancellation. The terminal capture policy needs separate real-browser evidence and must preserve accessibility/native editing.
- **High — contractual immutability:** Gerbil vectors, structs, pairs, and strings are mutable; constructor copying and disciplined publication are required.
- **High — external effects:** direct transition composition rolls back root installation, not I/O or mutable global effects.
- **Medium — failure retains prior prefix:** atomic rollback is coherent but differs from Emacs command-error consumption and may require an explicit abort/error-state design.
- **Medium — event identity policy:** logical versus physical keys, platform modifiers, repeat, composition, and layout normalization still require an application/browser protocol.
- **Medium — dynamic provider cost:** deriving large or computed active maps on the sole owner can cause head-of-line blocking.
- **Medium — no representative performance budget:** sorted vectors are evidence-backed but still need workload benchmarks before optimization.
- **Medium — configuration trust:** binding target symbols and argument specifications must be validated before root installation; browser input must never choose an arbitrary target name.

## Validation status

This is design-only research. No application source or tests were modified, and no behavior tests were run. Validation consisted of checking the requested artifact against the three assigned evidence reports and ensuring the design explicitly covers all requested decisions, options, semantics, staged evolution, invariants, v1 boundary, test seam, risks, and migration paths.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Created only the requested design-research artifact at research/tuna-input-keymap-api-options.md; no application source, tests, plan, ADR, or approval metadata was changed."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "The artifact cites all three assigned research reports, compares three materially different API shapes, recommends a precise public API, resolves each requested ownership/semantics question, and supplies invariants, v1/deferred scope, migration, acceptance behavior, and residual risks for independent review."
    }
  ],
  "changedFiles": [
    "research/tuna-input-keymap-api-options.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "python3 artifact structure and acceptance-report JSON validation",
      "result": "passed",
      "summary": "Confirmed the artifact exists, all required design sections are present, and the final acceptance-report parses as JSON."
    },
    {
      "command": "git -C /home/jay/Code/workbench-gerbil diff --cached --name-only; git -C /home/jay/Code/workbench-gerbil status --short -- research/tuna-input-keymap-api-options.md",
      "result": "passed",
      "summary": "Confirmed there are no staged files and the only target-path status is the new untracked research artifact."
    }
  ],
  "validationOutput": [
    "PASS: artifact exists (494 lines); required design sections present; acceptance-report JSON parses.",
    "No staged paths were reported; target status is ?? research/tuna-input-keymap-api-options.md.",
    "No behavior tests were run because the requested work is design-only and makes no implementation change."
  ],
  "residualRisks": [
    "Server-authoritative resolution cannot synchronously decide browser default cancellation; a separately validated nonsemantic terminal capture policy is required.",
    "Gerbil immutability is contractual rather than enforced.",
    "Atomic target failure retains the prior prefix state and differs from Emacs command-error consumption.",
    "Logical/physical key normalization, IME, repeat, editable-control, and accessibility protocol details remain product/host work."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added one design research artifact evaluating three Tuna input/keymap API shapes and recommending a pure resolver plus an application-owned dispatcher over the opaque root.",
  "reviewFindings": [
    "no blockers identified in the design-only scope"
  ],
  "manualNotes": "No implementation plan or approval metadata was created."
}
```
