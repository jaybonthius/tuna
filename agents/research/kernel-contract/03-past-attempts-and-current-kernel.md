# Lane 3: Lessons from earlier attempts, applied to the current Tuna kernel

Read-only research. Facts cite `file:line` (paths relative to `/home/jay/Code/workbench-gerbil/tuna`, kernel at `c3d35b4`, line numbers identical to the audit's `380fdc0`). Anything marked **Inference** is mine. I read the sources the brief named; I did not run builds or tests.

## Short answer

- Every earlier attempt grew its core the same way: **a feature needed per-instance state, so it got a field or module in the central thing, shaped around its one consumer.** The Racket profiler, Weevil's "storage" API, old Tuna's feature-inventory buffer record, and the Gerbil attempt's frameworks are one failure repeated.
- The current kernel (1,798 non-test lines) is drifting the same way, but only mildly. About 16% is outside ADR 12's list. The worst entanglement, `services/buffers.ss`, is outside the kernel.
- **Inference, stronger than the audit:** the kernel does not need an input-event base type. `loop.ss` never reads a field of the event (no `key-event-*` accessor or `.key` use in `loop.ss`; it only passes the event to `Input` and tests `key-event?` at 419-426). Make events opaque to the kernel and the browser noun disappears entirely.
- A realistic kernel is about **1,150-1,250 non-test lines** (the audit's ~1,500 after moves still carries jobs, the command registry and per-feature residue). Hard cap: 1,400.

---

## 1. Recurring failure patterns across attempts

Each pattern has evidence from at least two attempts.

### P-A. The private counter/field per feature ("just one more field")

- **Racket profiler.** Core carried profiler data through nearly every layer: `command-request` held an observation, `state-root` held provenance, each state subscription held `may-be-profiled?`, the completion observer stored a coordinator, and shutdown ordered profiler close stages (`agents/research/profiling/racket-profiler-extraction-research.md:17-30`, `71-127`). The research's own conclusion: extraction "cannot be achieved by moving the coordinator and renderer files alone"; the vocabulary and types must leave core. A later full audit has to search vocabulary, representation, control flow, web boundary, package topology, tests and ADRs (`:999-1041`).
- **Current Tuna.** The `kernel` class has one hard-wired field per feature: `commands`, `slots`, `hooks`, `jobs` (`tuna/kernel/state.ss:26-36`). The latency attempt (`f5a07f3`, reverted `c1cd140`) added an `unshown` field to the loop and passed data through `Display` "so it could measure" (`agents/research/kernel-audit-2026-10-12.md:7`). AGENTS.md now cites this as the rule's origin.
- **Mechanism.** Each feature is added in the commit that needs it; the field makes it work; nobody asks whether a plugin could own it.

### P-B. A contract shaped around one consumer, or a "contract" that is the implementation

- **Weevil storage API.** A "storage" API with 25 operations that also owned word motion, line begin/end and backspace policy; the text provider and dispatcher formed a dependency cycle (`agents/research/editor-corpus/prior-attempts-audit.md`, "Weevil's augmented persistent rope").
- **Old Tuna's feature-inventory buffer.** One record held text, file state, modes, markers, undo and overlays "before those facilities had behavior contracts or tests" (`prior-attempts-audit.md`, "A feature-inventory buffer record").
- **SumTree.** Public revisions, change sets, cursors, a splice engine and a benchmark framework "grew together" before one editor behavior needed them (`prior-attempts-audit.md`, section 2).
- **Current Tuna.** `services/buffers.ss` is a 674-line implementation (texts, undo, journal, decorations, points) presented as a contract; the `Buffers` interface covers only a list and two tables (audit P1-1). The kernel's `key-event` is the browser's `KeyboardEvent` (`kernel/loop.ss:51-64`). `JobTarget` plus `rebase-spans` assume results are lists of text spans (`kernel/jobs.ss:92-94,174-199`).

### P-C. Mechanism built before a second concrete user existed

- **Weevil roadmap review.** The simplicity review warned: "Generalizing a plugin abstraction from **zero** factored plugins... needs >=2 real ones"; "Pre-creating extension points/hook/option registries 'for future' ... dead weight that look like API and ossify"; it concluded "keep 'plugins' as a vocabulary you adopt later, only after >=2 concrete extractions prove the boundary" (`agents/research/editor-corpus/prior-art/weevil/plans/kernel-plugin-roadmap-2026-06-19/subagents/d-simplicity-review.md`, "Traps" 1, 2, 4 and "Notes").
- **Gerbil attempt.** The previous Gerbil Tuna had 14 commits and reached an input worker and a static page. The `plans/` directory holds a 565-line buffer spec and a 418-line app-state spec; the later single-buffer plan states "remove premature callback/local-value frameworks explicitly in Appendix A" (`agents/research/tuna-gerbil-2026-10/plans/editor-core-spec-unfinished.md` section 1). `tuna-old-2026-10` has 7.3k lines of `.ss` of which checkpoint/state-protocol/app-core machinery (`checkpoint.ss` 391, `private/checkpoint-data.ss` 447, `private/state-protocol.ss` 453, `private/app-core.ss` 763) exists for state that the app did not yet have.
- **Current Tuna.** Dead code: `revision-counter`/`revision-bump!` (`kernel/ids.ss:22-33`) have **no user outside `ids.ss`** (grep across `tuna/`). `discard-input` has no non-test user. `command-entry`, `active-plugin-names`, `with-inhibit-quit` have no non-test user. `call-on-editor-loop` is used only by tests. These were built for ADR text, not a caller.

### P-D. One log/mechanism conflating different concerns, and policy hidden in a primitive

- Command rollback, user undo, persistence and recovery were treated as one log (prior-attempts-audit "Patterns not to repeat").
- Weevil: marker adjustment code "existed but was not connected"; "tested-but-disconnected helpers" passed for a working anchor model.
- **Current Tuna.** Position-mapping logic exists three times: kernel `rebase-spans` (`jobs.ss:179-199`), `relocate-decorations!` (`services/buffers.ss:300`), `relocate-through` (`:338`). Kernel `change` records are text-specific (1-based char positions, `ids.ss:35-43`) and are used only by `services/buffers.ss`, the demo and jobs.

### P-E. Special paths per surface instead of composing ordinary concepts

- Weevil/old Tuna had separate minibuffer, terminal and popup state paths and two cursor/projection pipelines; a second canonical layout tree beside an existing one (prior-attempts-audit section 5).
- **Current Tuna.** `Minibuffer`, `EchoArea`, `Help` are separate services (`tuna/services/`), but are plugin-level, not kernel. **Not a kernel problem today**, but the demo reaching into other plugins and owning `describe-services` (audit P2-3/P2-4) is the same pattern at plugin level.

### P-F. Process failure: owner could not follow, plans ballooned

- The Gerbil attempt wrote very long specs (buffer 565 lines, app-state 418, editor-core 290 unfinished, roadmap 680 lines) with review loops ("one fresh read-only reviewer found two P1 contract gaps"; "BLOCK on proposal acceptance") before a vertical slice existed (`agents/research/tuna-gerbil-2026-10/tuna-buffer-model/reviews/*`). Result: contracts were reviewed against each other, not against running code. AGENTS.md records "Earlier attempts failed partly because [the owner] did not [understand]".
- Profiler/live-extensibility charter: a seven-gate program (research, alternatives, spikes, performance, spec, Oracle, owner approval) before any code (`agents/research/live-extensibility-racket/README.md`, "Evidence and review gates").
- **Inference:** heavy ceremony delayed code while the core still grew unobserved; no gate measured *size* or *placement*.

### P-G. Process-global singletons

- Weevil: "Event loop state, subscribers, side tables, and queues are module-global" (`weevil/architecture-review-2026-06-19/recommendations.md:95-97`); simplicity review trap 5: "Don't grow new global registries for a plugin layer."
- **Current Tuna.** `current-kernel` is a global parameter whose purpose is test isolation (`state.ss:50-52`), and the per-feature kernel fields exist partly so each test gets fresh feature state (audit P2-1). The kernel object and `new-kernel` are exported and `web.ss` re-parameterizes it on request threads (`web.ss:32,275,322`).

---

## 2. Which patterns are present in the current code, file by file

| File | Lines | Patterns present | Notes |
|---|---:|---|---|
| `kernel/ids.ss` | 50 | P-B, P-C, P-D | `span` is a text-range type; `change` is a text-edit record with 1-based char positions; `revision-counter` is dead. Only `next-id!` is generic. |
| `kernel/entries.ss` | 68 | none | Generic owner-tagged slot table; used by keymaps, settings, buffers. Good. |
| `kernel/state.ss` | 66 | P-A, P-G | Four feature fields (`commands`, `slots`, `hooks`, `jobs`) plus `live?` and `loop`. `exception-summary` (a string formatter) lives here. |
| `kernel/plugins.ss` | 565 | P-A (commands 44 lines), P-B (`command` struct shapes the Input contract) | Contexts, receipts, services, handover, adapters, activation are legitimate. Commands (`:503-546`) are a registry feature; `Messages` (`:548-565`) is a kernel-consumed seam. |
| `kernel/hooks.ss` | 78 | P-A | Callbacks stored in `kernel-hooks` by name although the `hook` object could own its list. Uses only `context-defer!`, `next-id!`, `message`, `exception-summary`. |
| `kernel/timers.ss` | 59 | P-A | Uses only public kernel API (`spawn-task!`, `cancel-task!`, `running-task`, `context-defer!`) and needs no kernel state at all. Pure library. |
| `kernel/slots.ss` | 50 | P-A, P-C | Registry for session persistence; consumer is the session plugin only (`plugins/session.ss`), registrants are `services/session`, `windows`, `autosave`. |
| `kernel/jobs.ss` | 199 | P-A (`kernel-jobs`), P-B/D (`rebase-spans`, `span`, `change`) | Validity policies `exact-revision`/`target-alive`/`rebase` are named for text targets. One user: the demo (`plugins/demo.ss`). |
| `kernel/loop.ss` | 631 | P-B | Browser `key-event` (`:51-64`); `input-queued?`/`discard-input!` test `key-event?` (`:419-426`); `submit-event!` typed on it (`:271`). Contains `current-task-id` (used by undo grouping in `services/buffers.ss`). Rest is the baton/quit/suspend machinery that ADR 12 puts in the kernel. |
| `kernel.ss` | 32 | P-G | Exports `kernel`, `new-kernel`, `current-kernel`; also re-exports every module. |
| `services/buffers.ss` | 674 | P-B (worst), P-D | Implementation as contract. Out of kernel scope but the biggest source of kernel-shaped vocabulary (`change`, `span`, `current-task-id`, `run-hook`). |
| `services/session.ss` | 85 | small P-A | `plain-data?`, `write-file-atomically!` file helper inside a contract module. |
| `services/renderer.ss` | 36 | small P-B | `status-line-text` mode-line policy in a contract module. |
| `plugins/demo.ss` | 181 | P-E | Owns `describe-services`; in `standard-plugins`; imports four other plugins. |
| `plugins/web.ss` | 348 | P-G | Needs `current-kernel` to parameterize threads. |
| `main.ss` | 71 | minor | Boot hard-codes the web transport URL. |

Plugins other than demo use no `kernel-*` accessors or `##` primitives (audit "Undeclared dependencies" paragraph), so entanglement is currently one-way: kernel and the buffers service hold shapes, plugins do not reach into kernel internals.

---

## 3. Verdicts per kernel module and export

Legend: **K** belongs in the kernel; **L** move to a shared library layer (neither kernel nor plugin; built only on the public kernel API, e.g. `tuna/lib/`); **P** move to a plugin; **D** delete (until a real caller exists); **S** keep in the services layer (contract plus vocabulary, not kernel).

Rule used (from AGENTS.md "Keep the kernel small" and ADR 12): kernel = what **no plugin could implement**, because plugins depend on it to exist or because it defines the concurrency rules every plugin's safety rests on. If a mechanism needs only the public kernel API, it is **L**.

### `kernel/ids.ss`
| Export | Verdict | Reason |
|---|---|---|
| `next-id!` | **K** | Needed by receipts/entries/tasks; thread-safe unique ids (ADR 12 "identities"). |
| `revision-counter`, `new-revision-counter`, `revision-bump!` | **D** | No user anywhere. ADR 4 says renderable objects carry revisions; `services/buffers.ss` uses plain `:fixnum` fields instead. Re-add as a library when a second consumer needs it. |
| `change` | **S** (move to `services/buffers.ss` or a text-contract module) | Text-specific (`start`, `removed`, `inserted` strings, 1-based chars). ADR 12 lists "change records" as vocabulary, but the only producer and consumers are texts. A rich-node buffer would define different changes. If a plugin-neutral change record is wanted, it must be shape-agnostic; none is needed today. |
| `span` | **S** (to buffers) | Text range; audit P2-2. |

### `kernel/entries.ss`
| Export | Verdict | Reason |
|---|---|---|
| `entry`, `entry-outranks?`, `entry-table`, `new-entry-table`, `entry-table-add!/remove!/ref/entries/keys` | **K** | ADR 2 "owner-tagged effects"; the kernel itself uses it for providers and adapters, and `context-add-entry!` is the primitive that makes any contributed slot reversible. Keep as is (68 lines). |

### `kernel/state.ss`
| Export | Verdict | Reason |
|---|---|---|
| `kernel`, `new-kernel`, `current-kernel`, `the-kernel` | **K, but private** | Needed internally. Stop exporting from the public facade; give the transport an `input-submitter` closure the way `result-poster` already works (audit P2-6). Tests import a test-support facade. |
| fields `plugins`, `services`, `providers`, `adapters`, `live?`, `loop` | **K** | Plugin runtime and loop state. |
| fields `commands`, `slots`, `hooks`, `jobs` | **D** (see below) | `hooks`: let `hook` own its callbacks. `slots`: registry moves to the session contract (S). `commands`: registry moves out (P/S). `jobs`: library state (L), keyed by a module-level or service-held table. No generic extension store is needed if each feature owns its state; adding a `define-kernel-local` store would re-create "the kernel holds everything" with nicer syntax. Prefer: state lives in an object that the owning service/plugin holds. |
| `exception-summary` | **K, private helper, or L** | Used by kernel for messages and by `main.ss`/session. Tiny; keep unexported from the kernel and offer a copy in the lib layer, or keep exported as the only text helper. Not a design issue. |

### `kernel/plugins.ss`
| Export | Verdict | Reason |
|---|---|---|
| `plugin`, `defplugin`, `context`, `current-context`, `context-plugin-name`, `context-defer!`, `context-add-entry!`, `activate-plugin!`, `deactivate-plugin!`, `plugin-active?`, `deactivate-all-plugins!` | **K** | The plugin runtime (ADR 12 bucket 1). `context-defer!` is the single primitive on which hooks, timers, jobs, slots, commands are all built, which is exactly why they need not be in the kernel. |
| `service`, `new-service`, `service-provider`, `StartupServiceError`, `context-provide!`, `context-adapt!`, `describe-services`/`service-info` (data) | **K** | Service registry, tiers, handover, adapters: ADR 12 bucket 1/ADR 2 amendment. The audit is right that handover and adapters are the live-replacement mechanism. Consider splitting the file (plugins vs services) for reviewability; see budget. |
| `active-plugin-names` | **D** or keep | No non-test user. Cheap, but unused. |
| `command`, `define-command`, `context-define-command!`, `defcommand`, `command-ref`, `command-entry` | **P/S** | A command is a name plus procedure plus doc; the kernel loop only needs "a name and a thunk to run as a task". Moving the registry to the input-policy contract (`services/keys.ss` or a `commands` service) matches ADR 8 (interactive specs belong to input policy). Change `Input-resolve-event!` to return a plain task request (name and thunk) rather than the `command` struct. Cost: `defcommand` becomes a macro from the commands service, not `:tuna/kernel`. Low risk; `keys.ss` already is the only consumer of `command-ref`. |
| `Messages`, `messages-service`, `message` | **K** | The kernel reports its own failures (handover failure, bad callbacks, loop errors). 18 lines. Rule: no features added to it. |
| `stx-source-string` (phi) | **K** | Only for `defplugin` source locations. |

### `kernel/hooks.ss` (78)
`hook`, `new-hook`, `context-add-hook!`, `hook-callback-names`, `run-hook` → **L**. It needs only `context-defer!`, `next-id!`, `message`. Make the `hook` object hold its own callback list (a mutable field) so `kernel-hooks` is deleted. Caveat: hook objects are module-level values, so tests that need isolation rely on receipts removing callbacks; this already holds because every registration goes through a context. ADR 2 still says "hooks are registered through contexts"; that remains true. Cordis counter-point (inference): Cordis keeps `ctx.on`/`emit` events in its core. If the owner wants hooks to be one of the 3-4 kernel primitives, the cost is ~80 lines; the evidence here says it is not needed to *bootstrap* plugins, so L is the smaller choice.

### `kernel/timers.ss` (59)
`context-run-with-timer!`, `timer?`, `cancel-timer` → **L**. Built purely on `spawn-task!`, `cancel-task!`, `running-task`, `context-defer!`. Zero kernel state. (ADR 3 lists timer callbacks as tasks; the *timer* is a thread that sleeps, not an execution rule.)

### `kernel/slots.ss` (50)
`session-slot`, `context-add-session-slot!`, `session-slots` → **S** (next to the session contract). The kernel keeps no knowledge of persistence (ADR 5). If plugin *reload* later becomes a kernel operation (ADR 2 "save its session slots, deactivate, restore"), reload itself is a library/plugin that talks to the session service, not a kernel op. Verdict holds either way.

### `kernel/jobs.ss` (199)
| Export | Verdict | Reason |
|---|---|---|
| the one primitive "post a thunk to the baton from any thread" (`result-poster`, in `loop.ss`) | **K** | The only thing a job manager cannot do itself. |
| `start-job`, `job?`, `job-cancel!`, keyed run/pending coalescing, owner cancellation | **L** | ADR 12 puts "jobs" in the kernel's execution rules, but the implementation is a thread plus `result-poster` plus a table. **This needs an ADR 12 amendment**; fallback if the owner wants jobs in-kernel: keep ~110 lines without validity policies. |
| `JobTarget`, validity `exact-revision`/`target-alive`/`rebase`, `rebase-spans` | **S** (to the buffers/text contract) | Validity is the *target's* knowledge. Replace with a single `(job-valid? result since)`-style method on the target, or let the apply procedure decide. Removes the kernel's last text-specific type. |

### `kernel/loop.ss` (631)
| Export | Verdict | Reason |
|---|---|---|
| `start-editor-loop!`, `stop-editor-loop!`, `editor-loop-running?` | **K** | |
| `task?`, `running-task`, `spawn-task!`, `cancel-task!`, `current-task-id`, `current-command-name` | **K** | Task identity; `current-task-id` is a generic command boundary id (undo grouping uses it). Fine; keep generic. |
| `suspend`, `suspension?`, `resume!`, `resume-quit!` | **K** | Yield points (ADR 3). |
| `check-quit`, `signal-quit`, `call-with-inhibit-quit`, `with-inhibit-quit`, `quit-condition?`, `quit-condition-forced?` | **K** | Quit lane (ADR 3). `with-inhibit-quit` has no non-test user; keep (it is the documented rule), but mark unused. |
| `result-poster` | **K** | See jobs. |
| `submit-event!`, `Input`, `input-service` | **K, retyped** | Make `event` opaque (`:t`). The loop only forwards it. The queue needs to tell events from tasks: wrap events in a private `queued-event` struct instead of `key-event?`. No client-id/sequence base type is needed in the kernel; ADR 10's client id belongs in the transport's event type, which the keys contract owns. This is stricter and smaller than the audit's "minimal `input-event` base". |
| `key-event` | **S** (`services/keys.ss`) | Browser noun. |
| `Display`, `display-service`, `redisplay` | **K** | The loop must trigger redisplay. Keep `(redisplay!) => :void` only. |
| `input-pending?` | **K** | Documented (ADR 3) and used by the session plugin. |
| `discard-input` | **D** | No non-test user. Re-add when `keyboard-quit` needs it. |
| `call-on-editor-loop` | **K or D** | Test/REPL entry; ~10 lines. Keep; it is the seam a future REPL needs. |

### `kernel.ss` (32)
**K** as a facade, but export only what the contract lists. Today it re-exports whole modules (`(import: ./kernel/hooks)` etc.), so the public surface changes whenever any module's exports change. **Recommendation:** list exports explicitly in `kernel.ss`, so the contract is one file.

### Services layer (not kernel; for placement)
`services/buffers.ss` (674) → split: vocabulary/dispatchers stay; behavior to the buffers plugin (audit P1-1). `services/session.ss` file helpers → files library. `services/renderer.ss` `status-line-text` → mode-line plugin later. `join-runs` plain-text run format → renderer contract (audit P2-3).

---

## 4. What the kernel must never know about

Justification by lesson in brackets.

| Noun | Why it must stay out |
|---|---|
| **Keys, key events, keymaps, modifiers, `KeyboardEvent` fields, quit *key*** | [P-B] The kernel's `key-event` is the web's. ADR 7 requires mouse, paste, composition, resize. The kernel forwards opaque events and asks `Input` whether one is "the quit event"; it never inspects it. |
| **Browsers, HTTP, SSE, Datastar, tokens, client ids, tabs** | [P-B, P-G] The transport is a startup-tier plugin (ADR 7, 10). `web.ss` currently needs `current-kernel`; that dependency should disappear behind a submitter closure. |
| **Text, strings, characters, positions, ranges, spans, changes, revisions of texts, undo, markers, decorations** | [P-B, P-D] Three copies of position mapping already exist; Weevil/old Tuna/SumTree all mixed text policy into the lowest layer. The kernel's `span` and `change` are the last text vocabulary inside it. |
| **Buffers, views, windows, frames, minibuffer, echo area, mode line, screens, render targets, HTML** | [P-E] Each is a service/plugin. The kernel calls `Display.redisplay!` and `Messages.message!` and nothing else about presentation. |
| **Commands as a registry, interactive specs, prefix state, last-command, `pre/post-command`** | [P-A] ADR 8: command-loop policy is startup-tier plugin. The kernel runs *a name and a thunk as a task*. |
| **Hooks, advice, timers, idle timers, jobs' validity policy** | [P-A, P-C] Mechanisms built only on `context-defer!`; the Racket profiler's hooks-in-core lesson. |
| **Settings, scoped values, `with-settings`** | [P-A] Already a plugin (ADR 9). Thread-scoped values are Gambit parameters in plugin code. |
| **Persistence: files, session format, autosave, atomic writes, plain-data checks, slots** | [P-D] ADR 5: a persistence plugin. Prior attempts conflated rollback, undo, persistence, recovery. |
| **Measurement: latency, profiling, spans-of-time, logging, tracing** | [P-A] The Racket attempt's central lesson; the revert `c1cd140`. The kernel exposes general-purpose seams (below) and never data for a particular observer. |
| **Files, processes, network, terminals, subprocesses** | Services/plugins (ADR 5). |
| **Which plugins exist** (names of default plugins, the standard set, demo) | [P-E] `main.ss` boot lists the standard set, not the kernel. The kernel must not import any plugin or service module. |
| **Session / persistence slot** vocabulary | Same as persistence. |
| **Emacs concepts**: modes, major/minor, `current-buffer`, `last-command`, faces | Plugins (and thread-scoped values, ADR 4). |

What the kernel **may** know about (the contract's positive list): plugins, contexts, receipts, owner-tagged entries, services/providers/tiers/handover/adapters, the baton, tasks, yield points/suspension, the quit lane, the input queue (as opaque items), job-result posting (`result-poster`), identities (`next-id!`), and the two seams it *consumes*: `Input`, `Display`, `Messages`.

Seams for observers (answers "how does a profiler/diagnostic plugin work without kernel changes"): a plugin can wrap a service provider (`Display`, `Input`) at activation, add hook callbacks, or advise procedures; it never needs a kernel field. If something cannot be observed this way, the question is "what general-purpose hook is missing?" not "pass the data in".

---

## 5. Line budget after cleanup

Current non-test lines: 1,798 (`ids 50, entries 68, state 66, plugins 565, hooks 78, loop 631, jobs 199, timers 59, slots 50, kernel 32`).

| Module (after cleanup) | Budget | Derivation |
|---|---:|---|
| `kernel/ids.ss` | 15 | `next-id!` and mutex only; `revision-counter` deleted (~11), `change` (~9) and `span` (~6) moved. |
| `kernel/entries.ss` | 68 | Unchanged. |
| `kernel/state.ss` | 40 | Drop four fields and their init; `exception-summary` stays or moves (~12). |
| `kernel/plugins.ss` (contexts, receipts, activation, defplugin) | 190 | Lines 1-146 and 353-470 of the current file, minus services. |
| `kernel/services.ss` (services, providers, handover, adapters, describe-services, `Messages`) | 270 | Lines 146-352 and 471-502, 548-565 (~260). Splitting is optional but makes ADR 12's two runtime halves separately reviewable. Combined runtime ≈ 460, versus 565 today (minus commands 44 minus ~60 of file overhead and re-export noise). |
| `kernel/loop.ss` | 540 | Remove `key-event` (14), retype Input, remove `discard-input`/`input-queued?` rewrites roughly neutral, add a small `queued-event` wrapper (~6), remove `current-*` helpers that move; the baton, quit lane, suspension and redisplay remain. Real reduction is small; this file is mostly comments plus the state machine. |
| `kernel.ss` facade | 30 | Explicit export list. |
| **Total** | **≈1,150-1,200** | |
| If jobs stay in the kernel (owner's choice) | +110 | Keyed run/pending and owner cancellation, no validity/rebase. Total ≈ 1,300. |

**Hard rules for the contract** (inference, from P-A):
1. Hard cap **1,400 non-test lines**; any module over its budget by 10% needs a one-line justification in the merge review.
2. No new fields in `kernel` or exports in `kernel.ss` without an ADR 12 amendment.
3. `tuna/kernel/` imports nothing from `tuna/services` or `tuna/plugins`; tests assert it (a grep check in `make test`).
4. Lib layer (`tuna/lib/`): hooks, timers, jobs; each module imports only `:tuna/kernel`.

---

## 6. Process safeguards that would have caught each drift early

Task briefs (for implementers) and merge reviews. Each safeguard names the pattern it catches.

| Pattern | Task-brief safeguard | Merge-review safeguard (cheap, mechanical) |
|---|---|---|
| P-A per-feature field | "Name the plugin or lib module that owns this feature's state. Kernel changes are listed explicitly and need owner approval." | `git diff --stat -- tuna/kernel tuna/kernel.ss`: any change prompts the placement question. Count lines against the budget table in the kernel contract. Diff `kernel` class fields; no new fields. |
| P-A feature named in the kernel | "No feature noun in kernel code: keys, buffers, text, browser, timer, hook, job, session, latency, profile." | `grep -rEi 'key|browser|buffer|text|window|latency|profil|session|timer|hook' tuna/kernel/*.ss` (non-test, non-comment) must be empty or allow-listed. This would have flagged `key-event`, `span`, `hooks`, `timers`, `slots` at the commit that introduced each. |
| P-B contract shaped by one consumer | "Name two consumers (one may be the toy second implementation) before adding a kernel interface method or type." AGENTS.md already says never shape a kernel interface around one consumer. | For each new kernel export: list its callers; one caller in one plugin means it belongs in that plugin. A rule from `d-simplicity-review.md` trap 2: "needs >=2 real". |
| P-B contract is the implementation | "A contract module contains interface, service value, vocabulary types, and thin dispatchers only." | Contract file over ~150 lines or containing `defclass` of mutable state triggers a review question. `services/buffers.ss` is 674. |
| P-C speculative mechanism, dead code | "Do not add an export until a caller exists in this task." | A dead-export check: for every `kernel.ss` export, require a non-test caller or a documented ADR requirement. Would have caught `revision-counter`, `discard-input`, `command-entry`. Cheap script: for each exported name, grep non-test non-kernel usage. |
| P-D one mechanism for several concerns; helper without connection | "State which concerns a record serves; one record per concern." | Review check: is every tested helper reachable from a production path? (Weevil's marker adjustment) |
| P-E special paths | "Before adding a separate path for a new surface, show why the ordinary buffer/service concept does not compose." | Reviewer lists new `defstruct`/`defclass` and answers "which layer owns it?" per AGENTS.md. |
| P-F ceremony, owner can't follow | Keep AGENTS.md rules: a one-page brief with a worked scenario before architecture; vertical slices that run in the browser; no review/oracle loops unless requested. Add: *every brief states its kernel delta in numbers* ("kernel +0 lines" or "+N lines, because..."). | Merge note: kernel line count before/after; `docs/overview.md` updated to match what landed. |
| P-G global state | "Per-feature state goes in an object the feature's service or plugin holds; do not add a global registry." | Grep for module-level `(def ... (make-hash-table))` in kernel and lib; each needs justification. `current-kernel` exported only through a test facade. |
| Placement review | AGENTS.md item: "which layer owns it, did the kernel grow, does a contract serve a single consumer". | Make it a three-line checklist in the merge template. Record per merge: kernel lines, new exports, new fields. |

Process note (**inference**): the audit found drift after 4 stages of commits (`3255918`, `b9b7758`, `45af055`, `f5a07f3`). A mechanical size and vocabulary check at each of those merges would have caught every item in the kernel audit. None of these checks needs an agent, an Oracle or a review loop, which matches the owner's "no review loops" rule.

---

## Recommendations for Tuna's kernel contract

1. **Define the kernel as what plugins cannot supply for themselves:** the plugin runtime (contexts, receipts, entries, services/providers/tiers/handover/adapters), the execution rules (baton, tasks, yield points, quit lane, input queue, `result-poster`), identities, and three consumed seams (`Input`, `Display`, `Messages`). Nothing else.
2. **Make input events opaque to the kernel.** Remove `key-event`; the kernel queue wraps events in a private struct. No base `input-event` type with client id is needed, because `loop.ss` never reads any event field.
3. **Return a plain name-and-thunk from `Input-resolve-event!`** and move the command registry (`command`, `defcommand`, `command-ref`) to the input-policy contract.
4. **Delete the per-feature kernel fields.** Hooks own their callback lists; slots move beside `Session`; the job registry is library state; do not add a generic `kernel-local` store.
5. **Create a library tier** (`tuna/lib/`, named in ADR 12) for mechanisms built only on the public kernel API: hooks, timers, jobs. Amend ADR 12/3 to say jobs are a library over `result-poster`.
6. **Move text vocabulary out:** `change`, `span`, `rebase-spans`, `JobTarget` validity to the buffers/text contract; delete `revision-counter`; delete `discard-input` and other unused exports until a caller exists.
7. **Stop exporting the kernel object.** Give the transport an `input-submitter` closure; `kernel.ss` lists its exports explicitly.
8. **Put numbers in the contract:** about 1,150-1,200 lines (1,300 if jobs stay in), hard cap 1,400, per-module budgets above, no new `kernel` fields or exports without an ADR 12 amendment.
9. **Enforce by mechanical checks in `make test` / merge review:** forbidden-noun grep over `tuna/kernel/`, no imports from services/plugins, dead-export check, kernel line-count diff, no module-level global tables.
10. **Fix the buffers contract before more kernel-adjacent work** (audit P1-1); until then record the deviation in ADR 12, because it is the main place where earlier attempts' pattern (implementation presented as contract) is repeating.
11. **Require every task brief to state its kernel delta and owning plugin**, and every merge review to answer "which layer, did the kernel grow, does a contract serve a single consumer."

## Open points / uncertainty

- I did not verify Cordis's exact kernel contents against its repository; the remark that Cordis core includes event emit/bail is from my knowledge and should be checked by another lane before it is used to argue hooks belong in the kernel.
- The line budgets are estimates from the current files' structure (not from editing); comments account for a large share of lines (e.g. `loop.ss`), so the reductions in `loop.ss` and `plugins.ss` are small relative to the removals of whole modules.
- I did not examine `tuna-old-2026-10` session history beyond the repository's git log, plan files and file sizes.
