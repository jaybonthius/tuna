# Research: Cordis's actual core, mapped to Tuna's kernel

Evidence base: Cordis `cordiverse/cordis` at commit `c261dd2c` (package `cordis` 4.0.0-rc.10; shallow clone in `/tmp/cordis`), paper repo README (abstract only; arXiv 2608.25512 abstract page answers HTTP 200 but I read only the repo's copy of the abstract). Tuna files read in full: `tuna/kernel/{plugins,entries,hooks,timers,slots,state}.ss`. I did not re-read the ADRs or the audit (the brief covers them); anything about them is inference. "Fact" = read in source; "Inference" is labeled.

## Summary

Cordis core is ~1,650 lines of TypeScript (1,891 with the bundled logger) around **four primitives**: a context (an immutable-ish scope object), a fiber (one plugin instance with a lifecycle), revertible effects (every side effect returns its inverse, held by the fiber), and services with coeffect-style injection (a fiber declares `inject`; it is active only while those services exist). Everything else is a convenience layered on those, or lives in packages. Timers (`timer`, 148 lines), the loader, hot reload (`hmr`), `include`, and the console logger exporter are separate packages that use only the public primitives (`ctx.effect`, `ctx.provide`/`Service`, `ctx.on`). Note: contrary to the lane premise, the **logger service itself is in core** (`logger.ts`, 246 lines; only exporters are separate). Tuna's kernel already has the right skeleton (context+receipt, services, entries) but additionally carries hooks, timers, session slots, commands, messages, and an adapter/handover mechanism, all of which Cordis either does not have or keeps outside core.

## 1. What is in Cordis core (line counts; fundamental vs convenience)

`wc -l packages/core/src/*.ts` (fact):

| File | Lines | Contents | Fundamental? |
|---|---:|---|---|
| `fiber.ts` | 507 | `Fiber`: state machine PENDING/LOADING/ACTIVE/FAILED/DISPOSED/UNLOADING; `effect()` (sync/async/iterator effects, reverse-order disposal, effect-tree metadata); epoch-based reload/unload; `update(config)`; config validation via Standard Schema | **Yes**, the heart. Roughly 150 lines of it are error-stack composition, async/iterator effect forms, and validation: conveniences. |
| `reflect.ts` | 283 | `ReflectService`: service store (`provide`, `get`, `set`, `notify`), property proxy so `ctx.foo` resolves a service, `accessor`, `mixin`, `bind`/`trace` | **Yes** for `provide`/`get`/`notify` (~80 lines). The Proxy handler, `accessor`, `mixin`, traceable wrappers are JS-ergonomics conveniences with no Scheme analogue needed. |
| `utils.ts` | 282 | `DisposableList`, symbol table, traceable/shadow proxies, `isConstructor` | Only `DisposableList` (a removal-safe ordered set) is fundamental. Rest is TS-specific machinery. |
| `logger.ts` | 246 | `LoggerService`, formatters, levels | **Convenience that Cordis ships in core.** Used by the fiber for error reporting (`ctx.logger.error`). |
| `events.ts` | 194 | `EventsService`: `on`/`once`, `emit`/`parallel`/`serial`/`bail`/`waterfall`; hook list keyed by event name; internal events | See §4. Core, but small and built on `ctx.effect`. |
| `registry.ts` | 214 | `ctx.plugin()`, `Inject` resolution, plugin→runtime map (`Plugin.Runtime` = callback + its fibers), `registry.delete` | **Yes**: `plugin()` creates a fiber; `Inject.resolve` is the dependency declaration. Decorator form is convenience. |
| `context.ts` | 78 | `Context` class, `extend`, `isolate`, `intercept` | **Yes**: scope object. `isolate` (per-subtree service namespace) and `intercept` (inherited config override) are advanced conveniences. |
| `service.ts` | 80 | `Service` base class: registers itself with `ctx.provide` in constructor; `[init]` hook; callable services | Convenience. A service is just `ctx.provide(name, value)`. |
| `index.ts` | 7 | re-exports | – |

Fundamental set (my classification, inference from the dependency structure): **(a)** context, **(b)** fiber/plugin lifecycle, **(c)** `effect(execute) -> inverse`, **(d)** `provide`/service lookup + `inject` + reactive notify, **(e)** event dispatch, and only because events/timers/etc. need it, (c) is the one primitive everything else is built from. Events are *implemented via* effects (`register` calls `fiber.effect`, `events.ts:140-146`), providing a service is an effect (`reflect.ts:~175`), a child plugin is an effect (`registry.ts`, `fiber.ts:~126`, `parent.fiber.effect(...)`). That is the central design point: **one revert mechanism, everything else a client of it.**

Tests (2,647 lines across 15 specs: associate, decorator, dispose, events, fiber, invoke, isolate, logger, plugin, reflect, service, shadow, update) are ~1.4x the code size, mostly on concurrent update/dispose ordering. Intended semantics worth copying are in `dispose.spec.ts` (effects reverse, errors during dispose logged not fatal), `update.spec.ts` (concurrent config updates coalesce to the latest), `service.spec.ts` ("compare snapshot": after unloading a plugin the hook/effect snapshot equals the pre-load snapshot: a leak test).

## 2. Effects, services, replacement, dependents, state

**Effects recorded and reverted (fact).** `Fiber.effect(execute, label)` (`fiber.ts` ~L255-330) runs `execute`, which returns a disposer (or iterator/promise of disposers); the disposer is pushed to a local list *and* to the fiber's `_disposables` list. The returned handle is itself a disposer, so effects nest (child effect metadata is collected in `EffectMeta.children`, giving an inspectable effect tree via `getEffects()`). Disposing a fiber (`_unload`, ~L388) clears `_disposables` newest-first and awaits each; a failing disposer is logged and does not stop the others. `effect()` refuses to run on a disposed fiber (`assertActive`, `CordisError INACTIVE_EFFECT`), so a stale context cannot leak effects after unload. If the effect's `execute` throws, partial disposers are run immediately (`fiber.ts` effect body: `catch → dispose(); throw`).

**Services provided/injected/replaced (fact).**
- `ctx.provide(name, value)` (`reflect.ts` ~L170-205) is itself an effect: it stores `Impl{name, value, fiber, check}` in `reflect.store[key]` and, if the providing fiber is ACTIVE, calls `notify([name])`. Its inverse deletes the impl, notifies dependents, **awaits their unload**, and only then drops the provider's own store entry ("ensure self access before dependencies cleanup").
- **Only one provider per (isolated) name**: a second `provide` throws `service "x" has been registered at <fiber>`. There is no priority, no "outranks" rule. Replacement is therefore *dispose old, then provide new*, driven by whoever manages the plugins (the loader/hmr), not by the service registry.
- Injection: a plugin declares `inject: ['foo']` or `{foo: config}`. `Fiber` keeps `_store` of resolved impls for its injects and computes an **epoch string** `"<revision>:<providerUid>:..."`, or `INACTIVE` if any required service is missing (`_refresh`, ~L333). `_setEpoch` starts reload/unload when the epoch changes. Because the provider fiber's `uid` is in the epoch, a *replaced* provider (new fiber, new uid) changes the epoch and reloads dependents even when the name never went absent.
- Optional `check()` on a service lets it declare itself unusable for a dependent (`_checkImpl`).
- Dependents react: `notify(names)` walks every fiber in the registry, re-checks impls, calls `_refresh()`. Fibers whose epoch changed unload (all their effects reverted, in reverse) and reload (the plugin function runs again) when the dependency is back. State transitions emit `internal/status`; `internal/service` events tell listeners a service changed.
- Access discipline: `ctx.foo` without `inject` throws "cannot get property without inject" (`reflect.ts` handler `get`), and inside an inactive context throws "cannot get required service ... in inactive context". So dependency declaration is enforced, not advisory.

**State on replacement (fact + inference).** Cordis has **no handover or adapter mechanism in core**. Dependents are torn down completely and re-run; any state they held in closures is lost unless it was stored in a service that is not replaced. Config changes follow the same rule (`update()` → `restart()` bumps `_revision`, so epoch changes and the fiber unloads/reloads), with one escape hatch: a plugin can listen to `internal/update` (a waterfall event) and call or veto `next()` to apply a new config *in place* (`fiber.ts` `update`; `events.spec.ts` "internal/update"). That is Cordis's analogue of Tuna's `context-adapt!`, but scoped to *config* changes, not provider changes. Persisting state across reloads is left to packages (loader/hmr), not core. (Inference: I did not read hmr's state handling in detail.)

**Failure semantics (fact).** A plugin that throws on load becomes FAILED, its partial effects are reverted, and it stays failed until `update()` clears `_error`. Errors go to `ctx.logger.error`; they do not propagate to unrelated fibers.

## 3. What Cordis keeps OUT of core

Packages in the monorepo (fact, `ls packages`; line counts of `src`):

| Package | Lines | Role |
|---|---:|---|
| `timer` | 148 | `TimerService`: `timeout`, `interval`, `throttle`, `debounce` as a `Service` that calls `ctx.effect(() => { const t = setTimeout(...); return () => clearTimeout(t) })` and mixes its methods onto the context via `ctx.mixin('timer', [...])` (`timer/src/index.ts:1-60`). **Timers are a plain client of `effect`; core has no notion of time.** |
| `logger-console` | 137 | Console/browser *exporters* for the core logger |
| `loader` | ~390 + config dir | Declarative plugin loading from config entries, groups, isolation, reconciliation, module resolution |
| `hmr` | 503 | Hot module replacement: watches files, finds which plugins use a changed module, reloads them |
| `include` | ~950 | `include` of external module graphs with a journal and patching |
| `group`, `utils`, `create` | tiny | helpers/scaffold |

Also absent from core: any config *file* format, schema library (core accepts any Standard Schema validator and calls it; it does not define schemas), persistence of state, commands/keymaps (not an editor), HTTP, and scheduling. Logger-in-core is the counterexample to "everything is a package": Cordis's own authors decided error reporting needs a built-in sink so the fiber can always report a failure. (Inference: Tuna's analogue is the `messages` interface, which the kernel uses for the same reason; a smaller alternative is a bare `report-failure!` that writes to stderr, with a plugin able to subscribe.)

## 4. Events

**Events are core, but thin and entirely effect-based (fact).** `EventsService` (194 lines) holds `_hooks: name -> Hook[]` where `Hook = {ctx, callback, prepend, global}`. `ctx.on(name, cb, {prepend, global})` returns a disposer and registers through `fiber.effect`, so listeners die with the plugin that registered them and re-register when it reloads (`events.spec.ts`: "does not accumulate across reloads"; "removes empty event buckets after disposal"). Five dispatch modes: `emit` (sync, all), `parallel` (async, all, aggregate errors), `serial` (async until a non-null result), `bail` (sync until non-null), `waterfall` (middleware chain with `next()`, rejects duplicate `next()` calls). Scoping: if the first argument to `emit` is an object with a `[Context.filter]` method, only hooks whose `ctx` passes the filter run (used for service-isolation: events about a service reach only contexts that see the same isolated service). Otherwise all hooks run. There is no event name registry or typing at runtime; names are strings or symbols (`Events` interface is TypeScript-only).

Notable: the core itself uses events as its extension points: `internal/plugin`, `internal/status`, `internal/service`, `internal/update`, `internal/commit`, `internal/config`, `internal/get`, `internal/set`, `internal/listener`, `internal/dispatch`. `internal/config` is a waterfall that is how config validation is composed in; `internal/listener` is how `on('internal/update')` gets special treatment. (Inference: this is how a small core stays extensible without per-feature fields: the extension points are named events that plugins hook, not kernel struct slots.)

## 5. Mapping to Tuna's kernel

Tuna line counts (fact, `wc -l`): `plugins.ss` 565, `entries.ss` 68, `hooks.ss` 78, `timers.ss` 59, `slots.ss` 50, `state.ss` 66, `ids.ss` 50, `jobs.ss` 199, `loop.ss` 631, `kernel.ss` 32. The files this lane maps total 886 lines; the whole kernel dir is 1,478 non-test lines. Cordis core is 1,650 non-logger lines but covers a much more elaborate runtime (async effects, iterators, isolation, proxies, stack composition, config validation) that Tuna does not need.

| Cordis primitive | Tuna today | Notes |
|---|---|---|
| Context (`Context`, `extend`) | `context` class `(owner, receipt)` (`plugins.ss:~50`) + `current-context` parameter | Tuna's context is a bare owner+receipt. No hierarchy, so no `extend`, `isolate`, `intercept`. Good: don't add them without a second user. |
| Fiber (plugin instance, lifecycle) | `plugin-record` (`definition, wanted?, active, registered, activated`) and `activate-plugin!`/`deactivate-plugin!` | Tuna is a two-state machine (active / not, plus `wanted?`); Cordis has six states, async load/unload, and concurrent-update coalescing. Tuna runs on a single baton, so synchronous is right. No children: a Tuna plugin cannot activate sub-plugins that die with it. |
| Effect with inverse | `context-defer!` pushes an inverse thunk to the receipt; `run-receipt!` runs newest-first and survives failures (`plugins.ss:~60-75`) | **Direct equivalent of `fiber.effect`**; Tuna's version is simpler and fine. Differences: Cordis also reverts partial effects on activation failure (Tuna does too, `run-activation!`), and effects nest as an inspectable tree (Tuna: flat list, no labels). |
| `inject` / service dependency | `plugin-requires` (list of `service`), `requirements-met?`, activation gating, `deactivation-closure` | Same idea. Tuna's closure-based deactivation is explicit and computed up-front, Cordis's is reactive through `notify`. |
| `provide` | `context-provide!` | **Tuna adds priority-ranked multiple providers** (`entry-outranks?`), live vs startup tier, and a `handover` thunk. Cordis allows exactly one provider and throws on conflict. |
| Events (`on`, `emit`, 5 modes) | `hooks.ss` (`new-hook`, `context-add-hook!`, `run-hook`) | Tuna has one dispatch mode (call all, remove failing callbacks, report). Cordis's `internal/*` events are core's own extension mechanism; Tuna's kernel has none but has the separate `hook` registry. |
| Timers | `timers.ss`, in the kernel, spawns Gambit threads and talks to `loop.ss` (`spawn-task!`) | **Cordis: separate package, 148 lines, ~10 lines of core coupling (`ctx.effect`).** Tuna needs `spawn-task!`/task cancellation from the loop, so it can be a plugin importing only `context-defer!` + the loop's public spawn function. |
| Logger | `message` + `Messages` interface/service in `plugins.ss` | Cordis keeps logger in core. Tuna's `message` is the analogue; keep only if the kernel itself must report failures. |
| (no analogue) | `entries.ss` / `entry-table` (owner-tagged priority entries) | A generic "slot with owner and priority" registry. **Cordis has no such thing in core**; named slots are always either services (single provider) or hooks. This is Tuna's biggest invention; see below. |
| (no analogue) | `slots.ss` (session slots) | Cordis core has no persistence. Equivalent in Cordis terms: a plugin that registers `ctx.on('session/save')`, or a service. |
| (no analogue) | commands (`defcommand`, `command`, `define-command`) | Editor-domain feature in `plugins.ss`; no Cordis counterpart in core (a command is just a plugin-provided registry entry). |
| (no analogue) | `context-adapt!`/`adapter`/`reconcile-adapters!`/`stranded-adapters` | Analogue is `internal/update` for config only. |
| Config validation, `update()`, concurrency | – | Tuna lacks this. Not needed in a single-baton kernel unless plugins gain config; if added, it should be a plugin (`loader`-like) as in Cordis's own split. |
| `registry` (list/inspect plugins) | `kernel-plugins`, `describe-services`, `active-plugin-names` | Present. |

**What Tuna's kernel has that Cordis keeps outside core** (fact on the Cordis side; verdicts are my inference):
1. **Timers** (`timers.ss`) → plugin. Cordis: `packages/timer`.
2. **Hooks registry** (`hooks.ss`, `kernel-hooks`) → Cordis has events in core, but nothing like per-feature registry fields in the kernel struct. If Tuna keeps *a* generic dispatch primitive in the kernel, it should be the only one, with names as plain symbols and no hook objects in kernel state; a hook that is a service (`provide` an interface; callers dispatch) needs no kernel code at all.
3. **Session slots** (`slots.ss`, `kernel-slots`) → plugin. Cordis has no persistence in core. A session plugin can own the slot table and expose a "register slot" interface; participating plugins `inject` it.
4. **Commands** (`kernel-commands`, `defcommand`, `command-ref`) → plugin. The command table is a feature registry; same reasoning.
5. **Adapters/handover** (`context-adapt!`, `handover`) → Cordis's answer is "restart dependents; state that must survive lives in a service that does not restart". It offers no state-migration hook, because replacing a provider is rare outside hot reload. Keep handover only if ADR 11/12 decisions require live provider swap with state; otherwise delete. This is where Tuna deliberately diverges (Emacs-like live editing), so it should be recorded as a divergence (per project rule) and kept as small as possible: a plugin-level protocol if possible, not kernel logic.
6. **Priority-ranked multi-provider services and the generic `entry-table`**: Cordis chose single-provider and throws on conflict. Priority resolution is policy (which provider wins) and can be implemented by a plugin that provides a *resolver* service, or by requiring unique providers and letting a selector plugin decide who activates. The `entry` struct (owner, priority, serial, doc, source) also bakes provenance/doc into the kernel; Cordis keeps `label` and effect-tree metadata on effects instead, which is also what lets `describe-*` be written generically.
7. **Messages / echo area plumbing**: arguably acceptable (Cordis ships a logger), but should be the *only* UI-ish concept, with no editor words.
8. **Startup vs live tier** (`check-live-change!`): policy about whether a service can be replaced; Cordis has none. Candidate to move to a plugin that vetoes via a general mechanism (e.g. a `before-deactivate` hook), or drop.

**What Cordis has that Tuna lacks** (assess each skeptically):
- **Nested/child plugins** (`ctx.plugin` inside a plugin, disposed with the parent, via `parent.fiber.effect`). Most valuable missing primitive: it makes composite features (a "group" of plugins) and the loader a plugin rather than kernel code. Cost: Tuna's flat `kernel-plugins` hash and global `activate-plugin!` would become parent-owned. Moderate.
- **Effects that are themselves revertible handles** (`effect()` returns its own disposer, early disposal allowed, effect tree metadata with labels). Tuna's receipt is unlabeled; adding a label per `context-defer!` would let introspection show "what did this plugin register", which the audit wanted. Cheap.
- **Reactive injection by name with enforced access** ("cannot get without inject"). Tuna's `requires` is a list of service objects used for gating but not for access enforcement; a plugin can call `service-provider` for anything. Whether enforcement is worth it is a judgement call; it catches undeclared dependencies at the cost of a context-scoped lookup.
- **Events as the kernel's own extension points** (`internal/plugin`, `internal/status`, `internal/service`). Lets observers (diagnostics, logging, profiling) watch lifecycle without kernel fields: matches ADR 12's "observe through hooks, advice, or services".
- **Config as input to a fiber** and live `update`. Not needed yet.
- **Failed state** that persists until config changes. Tuna turns `wanted?` off on failure, equivalent.
- **Isolation (`isolate`)** and **`intercept`**: skip.
- **Async effects/iterators**: skip; Tuna's single baton makes sync inverses sufficient. (Inference: if inverses must wait for a job to cancel, that is a Tuna-specific need handled by the loop, not the receipt.)

## 6. Recommended minimal plugin-runtime surface for Tuna's kernel

Smallest set that still gives Cordis's two guarantees (temporal: everything a plugin did is reverted; spatial: dependencies declared and reactive). Inference from §§1-5.

**Kernel exports (target ≈ 250-350 lines):**
1. `plugin` (name, doc, requires, activate) and `defplugin`.
2. `context` (owner + receipt) and exactly one registration verb: `context-defer! ctx inverse` (optionally `label`), the equivalent of `effect`. Every feature is built from this.
3. Plugin lifecycle: `activate-plugin!`, `deactivate-plugin!`, `plugin-active?`, `active-plugin-names`, `deactivate-all-plugins!`; activation gated on required services; failed activation reverts its partial receipt; failure isolation.
4. Services: `service` (name, predicate), `context-provide!`, `service-provider`, with dependents deactivated/reactivated on provider change. **Decide between** (A) Cordis rule: one provider, conflict is an error, replacement = deactivate then activate; or (B) keep priority. Recommendation: A in kernel, with the priority/selection policy living in a "service selection" plugin. If B stays, `entry-table` is the single ranked-registry primitive and must be the *only* one.
5. Lifecycle observation seam, to replace per-feature kernel fields: one generic dispatch (`on`/`emit` by symbol name, effect-registered, as in Cordis) used by the kernel to announce `plugin-activated`, `plugin-deactivated`, `service-changed`, `plugin-failed`. Hooks, timers' lifecycle, diagnostics, and session saving are then plugin clients. This single primitive replaces `hooks.ss`; `kernel-hooks` should not exist as a kernel-owned feature table (the table can live inside the dispatch primitive).
6. A failure reporter that does not depend on any UI: write to stderr and emit a `plugin-failed` event; the `messages` service becomes a plugin that listens. (Cordis puts a logger in core; Tuna can go one smaller.)

**Move out of the kernel into plugins:** `timers.ss`, `slots.ss` (+ `kernel-slots`), commands (+ `kernel-commands`, `defcommand`), `Messages` interface and `message`, startup/live tier policy, `context-adapt!`/handover machinery (or reduce to one generic "provider-changed" event with old/new values that a plugin may handle; kernel does not special-case adapters), session/job-specific fields (`kernel-jobs`, `kernel-loop` belong to the loop plugin or a separate runtime layer, not generic kernel state).

**Deliberately do not add:** async effects, effect iterators, context hierarchy/`isolate`/`intercept`, config validation, proxy-based service access, `mixin`/`accessor`, decorators. Add child plugins only when a second concrete user (a loader plugin) needs them.

**Instrumentation:** give each `context-defer!` an optional label so `describe-plugin` can list what a plugin registered, as Cordis's `getEffects()` does. This is the one observability feature that is cheap in the kernel and unavoidable otherwise.

## Contradictions

- Lane premise "loggers are a separate package": **partly wrong.** `LoggerService` is in `packages/core/src/logger.ts` and constructed in the `Context` constructor (`context.ts:46`); only exporters (`logger-console`) are separate. Timers are indeed separate.
- Cordis lets `ctx.on('internal/update')` replace a config restart with in-place update, so "state is always lost on update" is not strictly true; for *provider* replacement (the Tuna handover case) it is true.

## Missing evidence

- Did not read `loader` and `hmr` internals; claims about how state survives hot reload are inference.
- Did not read the paper body (only the repo abstract), so I have not verified the formal "observational equivalence" claim or whether the paper discusses state transfer on replacement.
- Did not trace Tuna call sites; a few "should move" verdicts (e.g. commands) assume current ADRs don't require them in the kernel, which I did not re-read (ADR 12 reading was delegated to the shared brief).
- Line counts for per-feature items (e.g. 150 lines of conveniences inside `fiber.ts`) are estimates.

## Sources

- Kept: Cordis repo, `packages/core/src/*.ts` and `packages/core/tests/*.spec.ts`, commit c261dd2c (https://github.com/cordiverse/cordis): primary evidence for everything in §§1-4.
- Kept: `packages/timer/src/index.ts`, `packages/loader/src/index.ts`, `packages` directory listing: evidence of what is outside core.
- Kept: Cordis paper repo README (https://github.com/cordiverse/paper), abstract defining "revertible effects" and "reactive coeffects" (https://arxiv.org/abs/2608.25512 reachable, full text not read).
- Kept: Tuna `tuna/kernel/{plugins,entries,hooks,timers,slots,state}.ss` and `kernel.ss`.
- Rejected/deprioritized: Cordis docs site (documentation "still under construction" per README).

## Recommendations for Tuna's kernel contract

1. **Define the kernel as five things**: plugin, context with one `defer!`/effect verb, activation lifecycle, services with dependent reactivity, one generic symbol-named event dispatch. Everything else is a plugin. Budget ~350 lines for this layer.
2. **Ban per-feature fields in `kernel` state** (`commands`, `slots`, `hooks`, `adapters`, `jobs`, `loop`). A feature's table lives inside the plugin that owns it; the kernel provides only the receipt and event dispatch. Cordis has no such fields.
3. **Move timers out** (Cordis's `timer` package is 148 lines on top of `ctx.effect`). Kernel exposes only what a timer plugin needs: `context-defer!` and the loop's public spawn/cancel.
4. **Move session slots and commands out.** Cordis has no persistence or commands in core.
5. **Services: prefer one provider per name** (conflict = error) as in Cordis; put priority/selection policy in a plugin. If priority stays in the kernel, say so explicitly in the contract as a divergence and record it in ADR + `docs/emacs-equivalents.md`.
6. **Treat handover/adapters as a kernel divergence to justify or delete.** Cordis restarts dependents and loses closure state. If Tuna keeps live provider swap with state transfer, reduce it to a "provider changed (old, new)" notification and let plugins migrate; no adapter bookkeeping or `stranded-adapters` closure logic in the kernel.
7. **Use events for lifecycle observation** (`plugin-activated`, `plugin-deactivated`, `plugin-failed`, `service-changed`) so diagnostics, profiling, logging, and session persistence never need kernel changes (ADR 12's rule, achieved Cordis's way).
8. **Label effects** (optional string on `context-defer!`) for introspection; it is the only Cordis feature worth adopting that Tuna lacks cheaply.
9. **Defer child plugins, config/update, isolation, async effects.** Add child plugins only when a loader plugin demands them.
10. **Failure reporting must not depend on a UI service**: stderr + event; `messages` is a plugin.
11. **Write leak tests like Cordis's "compare snapshot"**: after deactivating a plugin, every kernel table equals its pre-activation snapshot. This makes drift and leaks visible mechanically and fits the contract's purpose.
12. **Count lines in the contract**: `plugins.ss` is 565 lines (vs. Cordis's ~900 for fiber+registry+reflect), already larger per capability than Cordis; shrinking happens by moving commands, adapters, messages, tiers, and slots out, not by compressing code.

```acceptance-report
{
  "criteriaSatisfied": [
    {"id": "criterion-1", "status": "satisfied", "evidence": "Report written to the bound path covering all six questions with file-level citations, line counts, mapping table, and contract recommendations."}
  ],
  "changedFiles": ["/home/jay/Code/workbench-gerbil/scratch/tuna-kernel-contract/01-cordis-core.md"],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {"command": "git clone --depth 1 cordiverse/cordis and cordiverse/paper into /tmp; wc -l; cat of core src, tests, timer/loader; cat Tuna kernel files", "result": "passed", "summary": "Sources read; line counts gathered"}
  ],
  "validationOutput": ["Cordis commit c261dd2c; core src 1891 lines (1645 excl. logger); Tuna kernel plugins.ss 565 lines"],
  "residualRisks": ["loader/hmr internals and paper body not read; some line-count splits and move-out verdicts are inference; ADRs not re-read by this lane"],
  "noStagedFiles": true,
  "diffSummary": "Single new research report file; no repository modified.",
  "reviewFindings": ["no blockers"],
  "manualNotes": "Correction to lane premise: Cordis core includes a LoggerService (logger.ts); only exporters and timers are separate packages. Cordis permits exactly one provider per service (conflict throws), which differs from Tuna's priority-ranked providers and handover."
}
```
