# Cordis alignment: where Tuna's kernel differs from Cordis, and whether it should

Read-only research. Labels: **F** = fact with a citation; **I** = my inference; **U** = unverified.

## Sources read (pinned)

- **The paper, in full:** Shi, Zhang, Cui, *A Programming Paradigm for Spatiotemporal Composability*, arXiv:2608.25512 **v1** (submitted 26 Aug 2026), 92-page PDF. Copies: `/home/jay/Code/reference-repos/cordis-paper-2608.25512v1.pdf`, plus `pdftotext -layout` output `…v1.txt`. Page numbers below are the printed ones. I read §§1–3, 4.1–4.2, 4.4, 5–8 closely. In §4.3 I read the theorem statements and the prose around them, and skimmed the proofs.
- **The paper repository** `cordiverse/paper` at `0d43a6f`: it holds only a README (abstract and bibtex). There is no LaTeX source.
- **Cordis** `/home/jay/Code/reference-repos/cordis` at `a71c658` (2026-10-14). Read: `packages/core/src/{context,fiber,reflect,registry,events,service}.ts`; `loader/src/config/entry.ts`; the `internal/update` users; and `hmr/src/index.ts`, stage 1–3 reload.
- **Tuna** `main` at `ebf4bd1`. Read: AGENTS.md; STATUS "Owner decisions"; ADRs 2, 3, 11, 12, 13, plus the decisions of ADRs 4 and 5; `agents/research/kernel-contract/*`; `contract-models/README.md`; `tuna/kernel/{plugins,entries,hooks,tasks,state}.ss`; the outline of `loop.ss`; `tuna/kernel.ss`; and the handover code in `services/{buffers,layout}.ss` and `plugins/{buffers,layout}.ss`.

## Summary

- **Cordis's whole design rests on one rule.** Every shared piece of state sits at a *key* that exactly one *fiber* (a running plugin instance) provides. Every change to the shared context carries its inverse. A component sees only the keys it declared. On that basis the paper proves:
  - removal is exact, up to observation;
  - providers outlive their consumers;
  - the system always settles;
  - any order of loads ends where a load from scratch would have ended.
- **The paper chooses restart over state transfer, and says so.** Replacing a provider restarts its dependents from a clean slate. State that must survive belongs in a longer-lived dependency. Forward migration in the style of dynamic software updating (DSU) is named as future work (§7.3, p. 80).
- **Most of Tuna's kernel divergences** (priority-ranked providers, handover, adapters, undeclared service access, and the tie-break on registration order) **break exactly the assumptions those proofs use.** None of them has an ADR that argues against Cordis's reasoning.
- **Recommendation (I):**
  - **Align on services.** One provider per service; replacement is restart; delete `handover:`, `context-adapt!` and `priority:` on providers.
  - **Carry state across a replacement through the persistence path Tuna already has.** Session slots hold plain data, with a neutral form defined by the contract. Replace, reload and restart then become one operation.
  - **Keep, with recorded justification,** the editor thread and tasks, quitting with C-g, hooks, interface checks at activation, and startup tiers (as policy, outside the kernel).

## 1. Cordis's design and its reasons (the paper)

### 1.1 Plugins and fibers
- **F** A component is a triple: a coeffect specification *d* (the keys it reads), a provision *p* (the keys it provides), and a witnessed effect iterator *e*. "No key outside *p* is one its effect function installs a binding at." (§4.1, Def. 48, p. 31)
- **F** A *fiber* is one instance of a component. It has:
  - a parent;
  - its own table of the keys it provides;
  - a retirement flag;
  - one of four lifecycle states: Inactive, Reloading, Active, Unloading (Def. 49, p. 32).

  The shared coeffect context is not stored anywhere. It is derived as the union of the tables of the Active fibers (p. 33).
- **F** Instantiating a child is itself an effect. Its inverse *retires* the child (it does not remove it), so a parent's unload cascades to its children (Def. 52, p. 35).

### 1.2 Revertible effects (temporal composability)
- **F** An effect has the type Γ → Γ × (Γ → Γ): it returns the new context and its own inverse. The inverse only has to revert the effect at the state where it was applied (a "witnessed" effect). Inverses accumulate in last-in-first-out order (Defs. 1–18, pp. 9–16). Unloading means applying the accumulator.
- **F** The implementation does not check that an inverse really reverts its effect: "an obligation on the component author" (§5.1.1, p. 59).
- **F** Recovery is exact only "up to ≃", an observational equivalence built from the operations each key publishes. A heap layout, fresh names, and data already sent are not restored (§3.3.2, p. 23; after Cor. 69, p. 47).
- **F** The system boundary (§6.1, pp. 70–71) divides operations into two kinds:
  - acquisitions (open, malloc) are inside the boundary and revertible;
  - emissions (write, send) are outside, and can only be withheld or compensated.

### 1.3 Reactive coeffects (inject), and what happens to dependents when a service changes
- **F** A fiber may begin activating only when its declared keys are provided (Thm. 70(1), p. 47).
- **F** Every change to the context is classified as activating, deactivating or neutral for each fiber (Def. 22, p. 18).
- **F** The *target view* maps each declared key to its **provider fiber**, not to the value it provides (Def. 53, p. 36). When a key comes to be provided by a different fiber, the target changes, and the dependent reloads.
- **F** The implementation compares provider uids: "a provider that is replaced cannot be mistaken for the one it replaced, even when the two provide equal values." In-place overwrites by the same provider are deliberately not observed (§5.1.3, p. 63).
- **F** The *guard* (L-Unload, Def. 54, p. 36) controls the order of teardown:
  - a provider withdraws only after every consumer that resolved a key to it has deactivated;
  - before that, the provider leaves Active (L-Leave), so no new consumer can bind to it while it is leaving;
  - consumers read through their **committed view**, so a consumer can still use the dependency during its own teardown, for example to return pooled connections (pp. 35–36).

### 1.4 Replacement restarts dependents rather than transferring state
- **F** §7.3 (pp. 79–80) surveys forward migration (DSU, Kitsune, Erlang's `code_change/3`, webpack HMR) and concludes: "Cordis reverts the old component's tracked effects and reapplies the new component's from a clean slate, so a component's own in-memory state does not survive a reload unless placed in a longer-lived dependency, and layering DSU-style forward migration atop revertible effects is future work." The gains it claims for restart:
  - no hand-written migration functions are needed;
  - a component can be removed entirely, not just updated.
- **F** **Hot reload** (§5.2.2, pp. 67–69): the old fiber is disposed and a new one is made from the new module with the same configuration. The module graph is re-imported all-or-nothing before any fiber is touched (`hmr/src/index.ts`, stage 1). Koishi "re-applies edited plugins on save while preserving cache state and live connections elsewhere in the system" (§5.3, p. 70). In other words, what survives is what lives in other fibers.
- **F** **Configuration** (§4.4 "Configuration", pp. 56–57): a revision of the configuration is retire, deactivate, remove, then reinsert. Re-enabling deliberately creates a *fresh* fiber.
  - The loader's shorter routes are allowed only because Theorem 80 fixes the end state: "a new payload handed to a component that reloads only on a material change" (p. 57).
  - That route is `internal/update`, a waterfall: the plugin may apply the new configuration in place, or veto the restart (`fiber.ts` `update()`; `events.ts`, the `internal/update` hooks; `loader/src/config/group.ts:84`).
- **F** **Persistence:** the paper has no persistence mechanism. The loader's configuration is "a persistent record" (§5.2.1, p. 65); keeping data is left to providers such as databases (p. 70).

### 1.5 One provider per name, and isolation
- **F** The last premise of O-Insert forbids two fibers with overlapping provisions: "a key has one possible provider because the orchestrator may not admit a second component declaring it" (§4.2.1, p. 34). The single provider is what makes the union of tables well defined, and what makes `provider_k` a function of the configuration rather than of the state (p. 33).
- **F** Two sanctioned ways to have several providers (p. 33; §6.2, pp. 71–72):
  - *realms* (isolation: the same key resolves differently in different subtrees);
  - a *service broker*: one fiber provides the key and dispatches among implementations that register with it, each registration being a revertible effect.
- **F** The broker "absorbs this perturbation": when a backing provider changes, consumers do not reload. Rolling updates go through the broker too.
- **F** The code agrees: `reflect.ts` `provide()` throws `service "x" has been registered at <…>`.

### 1.6 Events
- **F** The paper does not cover events as a mechanism (the text never says "logger", and says "event listener" only as an example).
- **F** It does classify registrations (§3.4.2, p. 29):
  - a **table of entries, each with its own id**, such as routes or event listeners, is *commutative*: registrations in either order are indistinguishable, and either can be withdrawn while the other stays;
  - "a key whose value is an ordered chain is not commutative" (middleware).
- **F** The proofs need every key to be commutative (Def. 46; Lemma 66, p. 45). Order-sensitive behavior has to be imposed by declared dependencies, not by registration order.
- **F** The code has events in core: `on`/`emit`/`parallel`/`serial`/`bail`/`waterfall`, registered through `fiber.effect` and filtered by realm. The core's own extension points are `internal/*` events (`events.ts`). Order is registration order plus `prepend`.
- **I** So Cordis's own `waterfall` and `bail` events are ordered chains, and the paper's theorems do not cover them.

### 1.7 The logger in core
- **F** The paper says nothing about it.
- **F** In the code, `LoggerService` is built in the `Context` constructor, and the fiber reports failures through `ctx.logger.error` (`context.ts`, `fiber.ts`).
- **I** The reason is practical: a fiber must always be able to report a failure. Tuna's `Messages` service with a fallback to stderr does the same job.

### 1.8 What the paper guarantees, and under which assumptions
- **F** The guarantees:
  - **Preservation:** a well-formed registry, with provisions disjoint (Thm. 64).
  - **Recovery exactness:** applying a fiber's accumulator leaves every table where the other fibers' steps would have left it had this fiber never started (Thm. 68 and Cor. 69, pp. 46–47). This is the "observational equivalence after unload".
  - **Ordering:** providers activate first and outlive their consumers (Thm. 70).
  - **Resolution coherence:** no transition straddles two resolutions (Thm. 71).
  - **Progress:** the system quiesces (Thm. 73).
  - **Confluence:** the quiescent state equals a load of the final configuration from scratch (Thm. 80).
- **F** The assumptions:
  1. Every inverse reverts its effect, and every key is commutative. Both are author obligations and are not checked (pp. 29, 59).
  2. Context mediation: a component reads and writes only declared keys. "A location the system cannot reify as a coeffect lies outside … the theorem" (p. 30; Def. 55, confinement, p. 38).
  3. Single provider per key (p. 34).
  4. The dependency relation is acyclic (p. 48). A cycle leaves its members inactive, which can be detected from the declarations (§6.5, p. 74).
  5. Instantiation is finite.
  6. For confluence, every component installs every key it declares ("total on its provision"), and failed fibers are excluded (§4.4 "Failure", p. 56).
- **F** Undeclared access is rejected at run time ("cannot get property … without inject"; `reflect.ts`; §5.1.4, p. 64). The paper treats the `inject` list as a capability request (§6.3, p. 72).
- **F** Types are checked only by key name. Interface drift and key collisions are an open problem (§6.6, pp. 75–76).

## 2–3. Each divergence: the reasoning on both sides, and a recommendation

Each subsection gives Cordis's reasoning, Tuna's stated reason, what would break if Tuna aligned, what Cordis's guarantees lose under Tuna's version, and a recommendation.

### D1. Handover and adapters when a provider is replaced, instead of restarting dependents
- **Tuna does (F):**
  - `new-service … handover:` runs `(handover outgoing incoming)` when the effective provider changes (`plugins.ss` `hand-over!`). Buffers and layout use it to describe the old state and adopt it (`services/buffers.ss:305-311`, `services/layout.ss:156-161`).
  - `context-adapt!` lets a dependent stay active and migrate itself (`reconcile-adapters!`); `stranded-adapters` adds the bookkeeping for adapters left without a provider.
  - A failed handover is *reported, not rolled back* (`hand-over!`).
- **Cordis:** restart from a clean slate; state that must survive lives in a longer-lived dependency; migration is future work (§7.3).
- **Tuna's reason:**
  - ADR 2: dependents either **restart** or **adapt**, "which suits stateful dependents such as buffers over the text store".
  - ADR 11: "One piece is missing: moving existing state from one provider to another."
  - ADR 12, live tier: "the outgoing provider hands its state to the incoming one."
  - **None of these engages the paper's argument.**
- **If Tuna aligned (I):** state that is not in a slot is lost on a swap. Today's handover already loses most of it:
  - undo history and the change journal (`text-description` carries only content and highlights);
  - the layout's containers, sizes, pins, focus memory and frame marks (`layout-description` is only the views and the selected one).
- **Cordis guarantees lost under Tuna's version (I):**
  - recovery exactness and confluence: state moved by `adopt!` is not undone when the incoming provider is removed;
  - the guarantee is not even atomic, because a failed handover leaves both providers half-moved;
  - adapters keep references to the *old* provider's objects (`adapt-to-buffers!` re-points views by name), which is exactly the unmediated access that confinement forbids.
- **Recommendation: align (remove).** Details in §4.

### D2. Several providers ranked by priority ("outranks"), instead of one provider per name
- **Tuna does (F):** `context-provide! … priority:`. The best entry wins; the lower-ranked provider **stays active with its own state**. Withdrawing the winner hands state back down (`withdraw-provider!`).
- **Where Tuna uses priority (F):** priority 10 appears only in test doubles and test-support (`grep priority: 10`). Layout commands check `check-effective!` because an outranked layout plugin is still active and still has its commands bound (`plugins/layout.ss:836`).
- **Cordis:** one provider per key is what makes resolution a function of the configuration (pp. 33–34). Several implementations go through a broker or realms (§6.2).
- **Tuna's reason:** ADR 2's capability-audit amendment ("multi-provider services"). It argues for dispatch-by-key services (file system, process), which is a broker, not ranking. It does not argue for ranking.
- **If Tuna aligned (I):**
  - tests stop overriding a provider by outranking it, and simply do not turn the real one on (which `test-support/` already supports);
  - `check-effective!` disappears;
  - switching back to a previous provider no longer "restores" its live tree; restoring from its session slot replaces that (§4).
- **Cordis guarantees lost under Tuna's version (I):**
  - two live copies of editor state (both buffers registries) that can disagree;
  - commands from the inactive provider still bound (hence `check-effective!`);
  - which provider wins depends on activation order when priorities tie (D10).
- **Recommendation: align.**
  - A second `context-provide!` for a provided service is an error that names the current provider.
  - Selection is configuration: declare one provider.
  - Services that dispatch by key (file system, process) are brokers in the paper's sense (§6.2): one provider fiber, with backends registering into an entry table as revertible effects.

### D3. Startup and live service tiers
- **Tuna does (F):** `check-live-change!` raises `StartupServiceError` when a startup-tier provider would change while the loop runs.
- **Cordis:** has no tiers. Any fiber can be retired, and the guard orders the teardown.
- **Tuna's reason (F):** ADR 12 rejects "every service live-replaceable" because of the "large design cost for things changed perhaps once", and because "swapping concurrency rules mid-session would invalidate every running task".
- **If Tuna aligned (I):** replacing `Input` or the transport live would restart nearly every plugin and break the browser connection. That is possible under restart semantics, but of little value.
- **Cordis guarantees lost (I):** none are proved false. This is a policy restriction on orchestration. The paper's rules state when an action is *legal*, not when it occurs (§4.2, p. 34).
- **Recommendation: keep the tier as data on the service, and move enforcement out of the kernel** into the configuration reload orchestrator (`boot.ss` already defers startup-tier changes). Record in ADR 12 that this is policy and not semantics.

### D4. The editor thread (baton), tasks that suspend, and C-g interruption
- **Tuna does (F):**
  - plugin operations run synchronously, with quit inhibited and quits held (`call-as-plugin-operation`);
  - tasks hold the baton and suspend only at yield points (ADR 3).
- **Cordis:** transitions are asynchronous and inertial. A transition in flight completes. A divert may fall only at an iteration boundary (§4.4 "Asynchrony", p. 55). Every result holds for every schedule (p. 37).
- **Tuna's reason (F):** ADR 3 (Emacs direct-style commands, `C-g`, no shared mutable state under SMP).
- **Assessment (I):** Tuna's atomic plugin operations are a valid schedule of the calculus (synchronous rules, §4.2), so the guarantees carry over. Quitting cannot split a transition, which is safer than the aborting form of L-Divert.
- **Gap (I, from code; U at run time):** ADR 3 says tasks "are registered through a plugin context and cancelled when it deactivates". In the code, only `tuna/lib/timers.ss` calls `cancel-task!`. A command task that is suspended (say in `read-string`) when its plugin deactivates appears to outlive the plugin's receipt. That is an effect with no inverse, outside temporal composability.
- **Recommendation: keep** (justified, and already recorded in ADR 3). Add one alignment: a task started for a plugin's command is owned by that plugin's context and is cancelled by its receipt. Verify with a test.

### D5. Hooks as a kernel primitive, instead of Cordis's events
- **Tuna does (F):**
  - hook objects hold their callbacks;
  - callbacks are ordered by depth, then by `serial`;
  - a failing callback is removed and reported;
  - one dispatch mode (`hooks.ss`, `run-hook`);
  - the kernel announces lifecycle events on hooks (ADR 12, item 3).
- **Cordis:** events in core, registered as effects; five dispatch modes; the core's own extension points are events.
- **Tuna's reason (F):** owner decision, "Hooks stay in the kernel" (STATUS); ADR 12, item 3.
- **Assessment (I):** this is aligned in substance (effect-registered, in core, used for lifecycle). The divergences are small:
  - hooks are objects, not string names: better in Gerbil, because the payload can be typed and a typo is a compile error;
  - failing callbacks are removed (Emacs-like, and kinder);
  - only one mode: `bail`/`waterfall` would be ordered chains, which the paper treats as non-commutative anyway.
- **Recommendation: keep.** Record that a hook is a *registration table* (commutative) only if callbacks do not depend on order. Where order matters, depth must be declared by the plugin, never inferred from registration order (see D10).

### D6. Owner-tagged entry tables
- **Tuna does (F):** `entry-table` keeps one ordered list per slot name, ranked by priority, then by **newest serial**. Removing an entry removes only its owner's entry (ADR 2, "Owner-tagged effects").
- **Cordis:** has nothing like it in core. The paper says a table whose registrations each create their own entry is commutative (p. 29). An entry table's *effective value* is a winner-takes-all slot.
- **Tuna's reason (F):** ADR 2 rejects "restore-previous-value inverses" as "incorrect when two plugins set the same slot". That matches the paper's reasoning about per-registration entries.
- **Assessment (I):** removal is order-independent, which is good and matches Theorem 43's "withdraw in any order". But the effective value at equal priority depends on registration order. Two plugins binding the same key at priority 0 give "newest wins", so **reloading the older plugin changes which binding wins**. That breaks Theorem 80 (confluence: reload equals a fresh start) for keymaps, settings, completion styles and annotators.
- **Recommendation: keep the table, and fix the tie-break.** Equal priority resolves by something the configuration fixes (the declaration order of plugins in `init.ss`, or plugin name), not by `serial`. Then reconciliation equals a fresh load. Keep priority for these *slots*: it is user policy, not service resolution.

### D7. No enforcement that a plugin declared what it uses
- **Tuna does (F):**
  - `service-provider` and the contract dispatchers (`current-buffers`, `insert`) read the global current provider for any caller;
  - `requires:` only gates activation and computes which dependents restart;
  - STATUS records "optional service uses are guarded and documented per plugin".
- **Cordis:** access without `inject` throws (`reflect.ts`; §5.1.4). Reading through the committed view is "what Theorem 70 rests on" (p. 64). `inject` is also the capability list (§6.3).
- **Tuna's reason:** none recorded. The Emacs-style dispatchers (`(insert "x")`) are the implicit reason (contract-models, model (a)).
- **What Cordis's guarantees lose (I):**
  - a plugin that uses a service it did not declare is not restarted when that service changes, so it keeps stale references; adapters partly exist to patch this;
  - the restart closure is incomplete;
  - help cannot show true dependencies;
  - there is no capability boundary.
- **If Tuna aligned (I):** a dispatcher needs to know the calling plugin. Commands already run as tasks; the task can carry its owning plugin, and activation code has `current-context`.
- **Recommendation: align, with an Emacs-friendly form.**
  - The dispatchers stay.
  - `service-provider` checks, when there is an owning plugin (task owner or activation context), that the plugin declared the service. On a violation it raises the equivalent of "used buffers-service without requires:".
  - Code with no owner (the REPL, `init` evaluation) keeps unchecked access, as Cordis's root does (`reflect.ts`: "a fiber-less def site … keeps the unchecked root access").
  - Optional uses become declared optional requirements.

### D8. Receipts versus effects
- **Tuna does (F):** `context-defer!` pushes an inverse thunk. The receipt runs newest-first and survives failures. A failed activation reverts its partial receipt.
- **Cordis:** the same algebra (Algorithm 1, p. 59), plus:
  - effect handles that can be disposed early;
  - effect iterators with abort at step boundaries;
  - labels and an effect tree;
  - child fibers.
- **Assessment (I):** aligned. Tuna's per-activation receipt is the paper's per-fiber accumulator, and failure handling matches §4.4 "Failure". `init.ss` `config:` blocks already act as child fibers of their plugin (ADR 2 amendment).
- **Recommendation: keep.** Cheap additions only when they have a user:
  - a label on `context-defer!` for `describe-plugin` (kernel-contract lane 1, recommendation 8);
  - returning the inverse, so a single registration can be undone early.

### D9. Checks at activation (Gerbil interface predicates) versus TypeScript types
- **Tuna does (F):** `context-provide!` raises unless `((service-implements? svc) impl)` holds, typically an `is-Iface?` predicate that checks method names. Arity is not checked (contract-models, Q4).
- **Cordis:** types are checked only at compile time, against the key name. There is an optional run-time `check()` (`fiber.ts` `_checkImpl`). The paper names structural compatibility as the open fix for interface drift (§6.6).
- **Assessment (I):** Tuna is *ahead* of Cordis here. It is the run-time structural check that §6.6 calls for, done at the moment a provider is offered.
- **Recommendation: keep, and record it as a deliberate divergence.** Note the Gerbil cast cache: a class that fails a check is remembered as failing (contract-models, Q4; observed in gxi).

### D10. Configuration and update in place (`internal/update`) versus Tuna's reload
- **Tuna does (F):** reload diffs plugins by name. Changed plugins are replaced (deactivate, then activate). A failure turns the old version back on. Startup-tier changes are deferred (ADR 2, amendment 2026-10-13). Tuna has no hook for applying a new configuration in place.
- **Cordis:** the same restart by default, with the loader as orchestrator. `internal/update` lets a plugin absorb its own configuration change or veto the restart (pp. 56–57). HMR validates the whole import before swapping anything.
- **Assessment (I):** aligned. Tuna's "turn the running version back on" corresponds to the HMR rollback. The paper's Theorem 80 is exactly the soundness argument for Tuna's diff-and-apply, *provided* D2, D6 and D7 are fixed (single provider, order-independent slots, declared access).
- **Recommendation: keep.** Add a per-plugin update handler only when a plugin needs it. It is Cordis's one sanctioned in-place path, and it is limited to the plugin's *own configuration*, never a provider change.

### D11. Lifecycle ordering (an extra divergence found)
- **Tuna does (F):** `deactivate-records!` deactivates newest activation first. The provider's receipt runs after its dependents' receipts within one operation.
- **Cordis:** orders teardown by the dependency guard, not by time, and uses committed views (Def. 54).
- **Assessment (I):** equivalent for a single synchronous operation, because a dependent always activates after its provider. Once services are single-provider (D2), the only remaining gap is D7: dependents must read the provider they activated against, which is a committed view.
- **Recommendation: keep.** Document the equivalence in ADR 2.

### D12. `Messages` in the kernel as a consumed seam
- **Cordis:** keeps its logger in core. **Tuna:** keeps the `Messages` service, with stderr as fallback (`plugins.ss`).
- **Recommendation:** aligned in reason. Keep.

## 4. Handover in particular: swapping the splits layout for a tabs-only layout

**What crosses today (F, from the code).**
- **What happens:**
  1. The tabs plugin calls `context-provide! layout-service` at a higher priority.
  2. Dependents of `layout` deactivate.
  3. `hand-over!` calls `Layout-adopt-views!` on tabs with `Layout-describe-views` from splits.
- **What crosses** is the contract's neutral `layout-description` (`services/layout.ss:77`):
  - the **views in order**, outside locked parts (the locked bar's owners put those back);
  - the **selected view**.
- **The view objects themselves cross** (`view` is buffers-contract vocabulary). Each view carries its buffer, point and scroll, so per-view state survives.
- **What does not cross** (the provider's private state):
  - containers, kinds and directions;
  - sizes on links, pins and locks;
  - per-container focus memory;
  - frame target and frame marks (frame marks are a *contract* concept, yet they are not in the description);
  - zoom level.
- **The splits plugin stays active** at the lower priority, still holding its full tree.
- **When tabs is turned off:** `withdraw-provider!` hands the flat view list back. Splits' `adopt!` keeps the views it still holds in place (`plugins/layout.ss:420-446`), so its old structure partly "comes back". That only happens because two layouts were live at once.

**Is it sound? Mostly no (I):**
1. **No atomicity.** A failed `adopt!` is reported, and the swap goes ahead regardless.
2. **Two live layouts.** The outranked plugin keeps its commands and hooks (`kill-buffer-hook` still edits its stale tree), hence `check-effective!`.
3. **The description is chosen ad hoc.** Frame marks, a contract concept, are lost.
4. **The same data already exists elsewhere.** The layout saves the full tree in its session slot (`layout->data`). ADR 11 already says a missing provider "falls back to importing the neutral description" from persistence. The handover is a second path for the same data.

**Cordis's alternative: put surviving state in a service that is not replaced.**
- **For layout (I): no, if taken literally.** A tree shared by every layout plugin would fix the data model, so tabs-only would have to store splits, and replacing the layout would no longer mean much. What *should* outlive a layout swap is already outside the layout:
  - views and buffers (buffers plugin);
  - the locked bar (its owners' plugins);
  - the user's arrangement, as **plain data in the session store**, which is a non-replaced service in the paper's sense.
- **For buffers (I): partly.** "Buffer contents in a store, providers stateless" moves the problem rather than solving it. The buffers provider *is* the store, and its representation (nodes, revisions, undo, journal) is what a replacement exists to change. Two parts fit the paper's advice exactly:
  - **text content:** files on disk, plus autosave (ADR 5) as the longer-lived dependency;
  - **the text-store representation**, already a separate service (buffers adapts to it today with `move-texts!`).

**Recommendation: replacement equals restart, plus restore from persistence (I).**
1. **The kernel:** one provider per service. A provider change restarts the closure of its dependents. `handover:`, `context-adapt!`, `stranded-adapters` and `kernel-adapters` are deleted.
2. **The orchestrator (configuration reload, or an explicit `switch-provider` command), not the kernel:**
   1. ask the session service to *capture* the slot data of every plugin in the closure;
   2. deactivate the old provider (the closure follows it);
   3. activate the new provider (the dependents follow);
   4. restore the captured slots.

   This is ADR 2's existing **Reload** recipe ("save its session slots, deactivate…, restore the slots") applied to a replacement. Replace, reload and restart then share one path, and it is exercised at every start-up.
3. **Contracts that support replacement define a neutral slot format** next to each provider's private slot:
   - layout: views by buffer name and node id, the selected view, frame marks;
   - buffers: texts, nodes and ids, points, and file links.

   A provider restores its own slot if it has one, and the neutral slot otherwise (ADR 11's rule, generalized). Switching tabs → splits restores splits' own saved tree, which reproduces today's "comes back" behavior without two live layouts.
4. **What is lost:** whatever is not in a slot, notably undo history (also lost by today's handover) and in-flight prompts. The owner has accepted this (orchestrator guidance, 2026-10-14).

**Why this is better than today (I):**
- every guarantee in §1.8 holds again;
- one serialization path is tested daily instead of a rarely run handover;
- a failed swap is the existing reload rollback (turn the old version back on, then restore its slots);
- it matches the paper's own sanctioned route for state: a longer-lived dependency, which here is the session store.

## 5. State management in general (per the owner's guidance)

- **ADR 4: owner-confined mutable objects under the baton.**
  - **Compatible with the paper (I):** mutation in place is the "in-place realization" of an effect (Def. 23, p. 19). The paper needs only that cross-component state be reached through declared keys.
  - **The weak point** is *cross-plugin object references*: the layout holds buffers' `view` and `buffer` objects, and adapters re-point them. Under the recommended rule, a plugin may hold another provider's objects only while it is active against that provider. Restarting drops them, and restore re-derives them from stable ids (buffer name, node id).
  - **Recommend:** amend ADR 4 with this rule.
- **ADR 5: session slots, owned by the session plugin.**
  - Slots become *the* mechanism for state that survives a replacement or reload, not only a restart.
  - The session service must keep slot data for inactive plugins, which is required for switching back (**U**: whether unknown or inactive slots are kept today; ADR 5's text is cut off at "Unknown slots ar…").
  - A plugin that registers a slot requires the session service (ADR 5 already says so). The session provider itself must be a startup-tier service, or the capture step needs it alive.
  - **Recommend:** amend ADR 5.
- **ADR 13: the layout as a frozen value; buffers mutable with revisions.**
  - **I** This fits restart-plus-restore very well. `layout->data` is already cheap, and frozen values make capture trivial.
  - Keep it.
- **The general rule to record, Cordis-aligned:** state that must outlive a plugin lives in a longer-lived service as plain data. That service is the files plugin for content, the session plugin for arrangement and points, and settings for preferences. Plugins are free to hold anything in memory, knowing it may be dropped. This is Emacs-like (Emacs loses everything not in `desktop.el`), and it is more extensible, because any provider can be swapped without writing a migration.

## Divergence table

| # | Divergence | Cordis rationale | Tuna rationale (recorded?) | Recommendation |
|---|---|---|---|---|
| D1 | `handover:` and `context-adapt!` | Restart from a clean slate; state survives in a longer-lived dependency; migration is future work (§7.3 p. 80) | ADR 2/11/12 want live swaps with state; no engagement with Cordis | **Remove.** Restart, plus capture and restore through session slots |
| D2 | Priority-ranked providers | One provider per key makes resolution a function of the configuration; broker or realms for several (pp. 33–34, §6.2) | ADR 2 "multi-provider services" (argues for brokers, not ranking) | **Align.** Error on a second provider; brokers for dispatch by key |
| D3 | Startup and live tiers | No tiers; any fiber can be retired | ADR 12: cost, and the concurrency rules | **Keep as policy**, enforced by the orchestrator, not the kernel |
| D4 | Baton, tasks, C-g | Async inertial transitions; abort only at step boundaries | ADR 3 (Emacs direct style) | **Keep.** Add: command tasks owned and cancelled by their plugin's receipt |
| D5 | Hooks in the kernel | Events in core, effect-registered | Owner: "Hooks stay in the kernel" | **Keep.** Order only by declared depth |
| D6 | Entry tables (priority, then newest) | Per-registration entry tables are commutative; ordered chains are not (p. 29) | ADR 2 owner-tagged effects | **Keep. Fix ties** to a configuration-fixed order for confluence |
| D7 | No access enforcement | "Cannot get without inject"; committed view; capability (§5.1.4, §6.3) | None recorded | **Align.** Check the owner plugin's `requires:`; unchecked root access for the REPL and `init` |
| D8 | Receipts versus effects | Accumulator of inverses (Alg. 1) | ADR 2 | **Keep.** Optional labels |
| D9 | Interface predicates at provide | Key name only; structural compatibility is an open problem (§6.6) | ADR 2 services as interfaces | **Keep** as an improvement; record it |
| D10 | Reload diff-and-apply | Loader reconciliation sound by Thm 80; `internal/update` for own configuration | ADR 2 amendments | **Keep.** Sound once D2, D6 and D7 are fixed |
| D11 | Teardown by activation time | Guard plus committed view | Implicit | **Keep.** Document the equivalence |
| D12 | `Messages` in the kernel | Logger in core (code only) | ADR 12 consumed seam | **Keep** |

## Owner decisions

1. **Provider replacement: restart plus restore from slots, instead of handover and adapters.** *Recommend yes.* It restores the paper's guarantees, unifies replace, reload and restart, and deletes a kernel mechanism. It costs undo history on a swap, which is already lost today.
2. **One provider per service.** *Recommend yes.* Tests select doubles by configuration. Services that dispatch by key become brokers.
3. **Enforce declared service use.** *Recommend yes*, with unchecked access for the REPL and `init`, and declared optional requirements.
4. **Entry-table ties resolved by declaration order, not registration time.** *Recommend yes.* Reload then equals a fresh start for keys and settings.
5. **Command tasks belong to their plugin's receipt.** *Recommend yes.* It closes an effect with no inverse.
6. **Tiers as orchestration policy outside the kernel.** *Recommend yes;* low stakes.
7. **Record the kept divergences** (D3, D4, D5, D9, and the slot-based state rule) in ADRs 2, 4, 5 and 12, and in `docs/emacs-equivalents.md` where Emacs is involved. *Recommend yes;* this is what the owner asked for.

## What is shallow

- The §4.3 proofs were skimmed, not checked. I relied on the theorem statements and their stated assumptions.
- This is v1 of a preprint "under active revision" (repository README). Later versions may change section and page numbers.
- **U:** whether suspended command tasks really outlive their plugin's deactivation. This was inferred from a grep of `cancel-task!` callers, not tested.
- **U:** whether the session plugin keeps slot data of inactive or unknown plugins (needed for switching back).
- I did not read `loop.ss` in full, the session plugin, `boot.ss`'s reload code, or Cordis's loader isolation code beyond §5.2.1.
- The cost of restarting everything that depends on buffers (nearly every plugin) on a buffers swap was not measured.
- Unifying handover with persistence assumes that slot `save` and `restore` are complete enough. Only 3 plugins register slots today (`grep context-add-session-slot! tuna/plugins`).
