# Code review, 2026-10-14: is Tuna getting hacky or overcomplicated?

Read-only review of `main` at `3963901`, covering the Cordis kernel alignment (`f0bc354`, `7768b16`, `f1a1f46`), plugin-owned flags (`c3fa2da`) and the package layout (`6b78b55`, `5928c9a`). I read the kernel, start-up and reload code, the contracts, the plugins named in the task, the boundary test, the ADRs and briefs, and the stage reports in `scratch/tuna-{cordis,layout,cli-flags}/`. I did not build the project or run its tests. The one experiment, a parameter micro-benchmark, ran in `/tmp/tuna-review-bench/`.

Labels: **Fact** means checked in source, git or a report, with a citation. **Inference** means reasoned from facts but not run. **Opinion** means a judgement call.

## Summary for the owner

1. **The code is mostly not hacky, and the Cordis work made it simpler, not bigger.** Stage 2 deleted handover, adapters and provider priority. Across all three stages the kernel grew from 1,155 to 1,191 non-comment lines (Fact). The hacky parts are concentrated in two places, below.
2. **The first hacky place is "who is calling" tracking for declared service use.** Each call is charged to a plugin through an invisible current-plugin value. Every thread, callback and handed-out object must reset that value by hand. That rule is applied in about 25 places and missed in at least 8 more: node renderers, button actions, completion tables, prompt and completion methods, and the editor loop thread. Each miss is the same bug as `3963901`, waiting for a code path the tests don't reach (Fact for the code; Inference that these will fail).
3. **The Mac bug fix treated a symptom.** On a Mac with Option held, the keys plugin reads settings, and through them the selected buffer, on the web server's request thread. The input contract forbids touching editor state there. The fix made the permission check pass, and its new test now asserts the forbidden behaviour. A one-line change makes the read unnecessary (Fact).
4. **The second hacky place is start-up and reload code (`tuna/boot.ss`).** It holds one 402-line function, the rule "defer startup-tier changes" in three places, and code that recognizes a refusal by the shape of an error message (Fact). Most of this predates the Cordis work.
5. **Small workarounds are piling up so that tiny kernel exports can be avoided.** Examples: a type cast caught as an exception and used as a predicate, and a throwaway registration made only to learn a plugin's name. Exporting two read-only accessors would delete both (Fact; Opinion on the fix).
6. **Code you evaluate (`M-:` later) will not see imports added to `init.ss` by a reload.** Its environment is fixed at start-up (Inference from code). This contradicts the package-layout brief.
7. **Recommendation on run-time checking: replace it with a check in `make test`.** Each plugin package that imports a contract must declare that contract's service. Keep everything that gives registrations an owner (receipts, explicit `ctx`, command ownership). This deletes about 40 of roughly 165 tracking occurrences outright and makes the other ~100 plain lookups. It also removes the bug class and roughly halves dispatch cost. You lose per-call checking of transitive and dynamic uses, which matters little because restarts already follow required services transitively (Inference). It is a divergence from Cordis to record in ADR 2.
8. **The package layout is sound and not over-engineered.** Its fragile spots are a hand-ordered `build.ss` that nothing checks for completeness, hand-kept name lists in the boundary test, and tests that reach into other packages by relative path (Fact).
9. **What is genuinely good:** owner-tagged entries with ties broken by declaration order; commands that are cancelled with their plugin (about 10 lines); quit-safe plugin operations; the `#lang :tuna/config` loader; plugin-declared flags; and a boundary test with negative cases.
10. **Fourteen concrete cleanup items are listed at the end**, smallest first. Items 1–3 are worth doing now.

## Q1. Code quality since the Cordis work began

### What is genuinely good

- **The kernel stayed small, and stage 2 removed machinery.**
  - Non-comment kernel lines (`tuna/kernel/*.ss`, excluding tests): 1,155 at `6b4bf8f`, 1,285 after stage 1, 1,188 after stage 2, and 1,191 at HEAD (Fact, counted with `git show`).
  - Stage 2 touched 56 files with +827/−1,123 lines (Fact, `git diff --stat 7768b16^1 7768b16`).
  - The noun baseline holds three permanent entries (`tuna/kernel/boundary-baseline.sexp`).
- **Entry tables are small and correct** (`tuna/kernel/entries.ss`).
  - Each owner keeps one entry per name.
  - Ties go by shared `owner-order` ranks, so a reorder needs no re-registration.
  - Removal is by identity, so an old inverse cannot remove a replacement.
- **Hooks** (`tuna/kernel/hooks.ss`, `plugins.ss:174-191`) look up named callbacks late through a macro, and replacing a callback keeps its position.
- **Command ownership** is a temporary receipt inverse (`call-with-context-receipt`, `plugins.ss:89-93`; `call-with-task-owner`, `loop.ss:256-260`). About 10 lines close a real gap: suspended commands outliving their plugin (Fact).
- **Plugin operations are atomic with respect to `C-g`.** Lifecycle events are announced after the operation finishes (`plugins.ss:275-333`). The design is careful and well commented.
- **Configuration:**
  - the `#lang :tuna/config` reader splits load-time forms from user code (`tuna/config.ss:115-131`);
  - option problems are collected and reported together;
  - flags are declared on options, and two plugins claiming one flag is an error (`boot.ss:80-123`);
  - `main.ss` names no plugin.
- **Types and comments.** Typed signatures are nearly universal, and comments explain reasons rather than restate code.

### Findings, ranked

**P1-1. Run-time attribution is incomplete; the `3963901` bug class exists in at least 8 more places.**
- **Mechanism (Fact):**
  - The calling plugin is the dynamic parameter `current-context` (`tuna/kernel/plugins.ss:76`).
  - Gambit threads inherit it, and stored procedures run under whoever calls them.
  - Correct attribution therefore needs `context-bind` at every registration, `call-with-context` at every seam, and provider re-scoping in every dispatcher (`plugins.ss:404-425`).
- **Unbound procedures, stored by one plugin and run by another, so service uses are checked against the wrong plugin (Fact for the code; Inference for impact):**
  - Node renderers: `context-define-node-renderer!` stores `render` raw (`plugins/buffers/contract.ss:515-523`). The node-kind projection two forms earlier is bound (`:509`). Renderers from buttons, help, minibuffer, echo area and completion-vertical all run as `html-renderer`.
  - Button actions: `new-button` stores `action` raw (`plugins/buttons/contract.ss:27-31`). It runs as the `buttons` plugin inside `push-button` (`plugins/buttons/plugin.ss:45`). A button that calls `read-string` or `swap-plugins` from a plugin that declared them would fail with "buttons used an undeclared service".
  - Completion tables (`items`, `sort`, `group`, `annotate`) and styles run as `completion-engine` (`plugins/completion/plugin.ss:77,84,175-178`).
  - `nearest-view`'s `match?` runs as the layout (`plugins/layout/contract.ss:246-247`), while `render-layout` two forms later binds its callback (`:291-293`).
  - Job `apply` callbacks run with no owner (`#f`), so they are unchecked and unowned (`tuna/lib/jobs.ss:182`). `new-job-group` takes `ctx` but does not keep it (`:80-93`).
- **Handed-out objects re-scope by hand, inconsistently (Fact):**
  - `prompt-exit!` re-enters the minibuffer's context (`plugins/minibuffer/plugin.ss:100-101`). `prompt-input` does not (`:97`).
  - `session-exit!` re-enters the completion engine's context (`plugins/completion/plugin.ss:162-164`). `session-insert!`, `session-annotations` and `session-group` do not (`:165-178`). `session-annotations` calls `set-selected-view!` on the caller's account (`:135-148`).
- **Thread inheritance (Fact; Inference that it is latent):**
  - `start-editor-loop!` spawns the loop thread without clearing the context (`tuna/kernel/loop.ss:194`).
  - `dispatch!` then checks the inherited context before resolving each key (`:434`).
  - It works only because `main.ss:180` starts the loop with no context. A plugin or `M-:` that started the loop would make every key fail.
  - The `3963901` fix itself selects the provider through the foreign thread's `current-kernel` (`loop.ss:226-229`). This contradicts its own comment that the submitter works "from any thread … whose dynamic environment lacks the kernel" (`:213-218`).
- **Smallest fix:** see Q2. Under the recommended option these sites need no fix. Under option (a), each needs a bind (cleanup item 2).

**P1-2. Input `arrival` touches editor state off the baton; `3963901` hid the cause rather than removing it.**
- **The contract (Fact):** `arrival` is "called on the submitting thread … so it must not touch editor state" (`tuna/kernel/loop.ss:49-51`).
- **What the keys plugin does (Fact):**
  - Its `arrival` calls `key-description` (`plugins/keys/plugin.ss:285-287`).
  - On a Mac with Alt held, that path reads `setting-value` (`:62-76`).
  - Settings resolve through the buffers plugin's scope (`plugins/buffers/plugin.ss:424-425`).
  - That scope reads `current-buffer` → `selected-view` (`plugins/buffers/contract.ss:597-600`) and buffer-local settings.
- **Consequences:**
  - These reads happen on an HTTP request thread while the editor thread may mutate them (Inference).
  - The per-service cache can also be written from that thread without a lock on a cache miss (`plugins.ss:368-385`) (Inference: improbable but unsynchronized).
  - The new test `loop-test.ss:121-141,242-248` asserts that `arrival` may read a service, which enshrines the violation (Fact).
- **Smallest fix (Fact from code):** `C-g` is never produced while Alt is held. `alt-meta?` is reached only with Alt down (`keys/plugin.ss:71`), and the AltGr and Option paths cannot yield exactly `C-g`. So `arrival` can return `'queue` when `key-event-alt?` is true, before calling `key-description`. The Mac path then touches no settings. Change the test to assert that `arrival` needs no service.

**P2-1. Start-up and reload code carries the most accidental complexity (mostly pre-existing).**
- **Size (Fact):** `apply-configuration!` is 402 lines with 13 inner definitions and about 12 mutable locals (`tuna/boot.ss:567-969`). It was 384 lines before the Cordis work. Stage 2 added the swap pairing.
- **The startup-tier rule is implemented three times (Fact):**
  1. a pre-check of the plugin itself (`boot.ss:657,697`);
  2. a closure check in `restart-plugin!` that raises a generic `(error "Restart required for startup service" name)` (`:1025-1043`);
  3. recognition of that error back by its irritant shape, "exactly one symbol that names a startup-tier service with a provider" (`refused-startup-service`, `:1081-1091`).
- **Stale branch (Inference):** `activate-entry`'s `startup-refusal` branch (`:1124-1150`) handles a kernel refusal that stage 2 deleted. Before stage 2 the kernel raised a typed `StartupServiceError` (Fact, `6b4bf8f:tuna/kernel/plugins.ss:324,394`). The branch is now unreachable except by a coincidental error.
- **Naming and comments (Fact):**
  - `stays-on` turns the plugin off as its main effect (`:1057-1059`).
  - Its doc comment sits above `startup-closure` (`:1023-1025`).
  - `restart-plugin!` and `reload!` defensively reset the context (`:1039,1231`).
- **Fix:** use a typed refusal condition raised in one place, delete `startup-refusal`, and rename `stays-on` to `turn-off!`. Split `apply-configuration!` into classify → execute → report when reload next changes (cleanup items 4 and 5).

**P2-2. Interactive evaluation's environment is frozen at start-up.**
- **Code (Fact):**
  - `session-owner` builds its top context as a child of the module from the first load, passed in through a parameter (`initial-evaluation-context`, `boot.ss:1206-1207,1225,1263`).
  - `session-owner` is never restarted.
- **Effect (Inference):**
  - After a reload that adds `(import :foo)`, evaluated code cannot see `foo`.
  - If the first load failed, evaluation never sees `init.ss` imports, even after a successful reload.
  - The package-layout brief says "Code you evaluate later … sees what your `init.ss` imported" (`docs/briefs/2026-10-package-layout.md`, "What has to change", item 2).
- **Fix:** on each successful load, give the session a new child context of the latest module, keeping evaluated definitions in a context the user owns. Alternatively, document the limit. Add a test.

**P2-3. Workarounds instead of small kernel exports.**
- **Cast as predicate (Fact):** `declare-plugin!` uses `(with-catch (lambda (_) #f) (lambda () (: value plugin) #t))` because the facade exports no `plugin?` (`tuna/lib/configuration.ss:77-78`).
- **Throwaway registration (Fact):** `set-restart-wrapper!` creates a throwaway entry in a fresh table only to read the caller's plugin name for an error message (`boot.ss:1233-1241`). That also leaves a stray inverse in the caller's receipt.
- **Self-ordering (Fact):** `session-owner` sets its own rank from inside its activation with the Gambit primitive `##greatest-fixnum` (`:1257`), instead of the `order:` argument that exists for this purpose (`plugins.ss:590`).
- **Another ambient parameter (Fact):** `initial-evaluation-context` passes an argument into an activation through a parameter.
- **Opinion:** ADR 12's "every export needs an amendment" rule is right, but read-only accessors such as `plugin?` and a context's owner name are cheaper to add than these workarounds are to keep.

**P2-4. The same rule is implemented twice.**
- **Session save and restore (Fact):**
  - Capture happens in `keep-slot-data!` (a receipt, at deactivation, `plugins/session/plugin.ss:209-220`) and in `restart!` (before teardown, `:222-245`).
  - Restore happens in `restore-plugin-slots!` (a hook, reports failures, `:193-202`) and in `restore-pending!` (after a restart, strict, `:247-251`).
  - The comment on `restart!` says receipt-time capture can see state that a cleanup already erased. That also applies to `keep-slot-data!` on direct deactivations (Inference).
- **Click resolver (Fact):** the same lambda (`posn-node`, else the root of `posn-view`'s buffer) appears in the layout plugin (`plugins/layout/plugin.ss:917-921`) and the two-views double (`plugins/layout/tests/support/two-views.ss:112-118`). Every future layout must copy it. It uses only layout-contract functions, so it belongs in the contract as one named function.
- **Entry ordering (Fact):** entry tables insertion-sort in `entry-table-add!` (`entries.ss:49-63`) and sort again on every read (`:75-76`). The read-time sort is needed because ranks change after insertion, which makes the insert-time sort dead weight.
- **"Apply, roll back on failure" (Fact):** written twice, at `tuna/configuration.ss:90` and `boot.ss:1245`.
- **"Is the loop running?" (Fact):** both `kernel-live?` and the `kernel-loop` field (`state.ss:26`, `loop.ss:193,211`). `kernel-live?` has one reader (`plugins.ss:628`).

**P2-5. A plugin mutates another owner's registration.**
- **Fact:** the minibuffer patches `command-visible?` on commands after registering them (`plugins/minibuffer/plugin.ss:242-247`). This bypasses the `visible?:` argument and its `context-bind` (`plugins/commands/contract.ss:35-43`).
- **Inference:** `command-ref` returns the effective command, so it would patch another plugin's command if one outranked it.
- **Fix:** register these commands with `visible?:` (`context-define-command!` already accepts it).

**P2-6. Dead or stale code (Fact).**
- `context-define-container-kind!` is exported from the layout plugin (`plugins/layout/plugin.ss:42,123-130`) but never called. By the boundary rules, only `init.ss` could import it.
- `startup-refusal` (P2-1).
- `remove-plugin-option-override!` is used only by tests (`tuna/lib/plugin-options.ss`).
- Stale text:
  - "startup-tier services refuse replacement" (`loop.ss:178-179`);
  - session slots "may register the same name (alternative providers of one service)" (`plugins/session/contract.ss:34-36`), stale since stage 2;
  - the overview cites `tuna/services/configuration.ss`, now `tuna/configuration.ss` (`docs/overview.md:151`).

**P2-7. Live redefinition works in only 4 of 22 plugins.**
- **Fact:** only `basic-editing`, `minibuffer`, `reload-config` and `view-commands` use `#lang :tuna/prelude`, which adds `(declare (separate))` (`tuna/prelude.ss:14-20`). The others use `prelude: :gerbil/core`.
- **Inference:** "named callbacks are looked up late" (ADR 2, ADR 12) holds for `set!` redefinition only in those four.
- **Fix:** use one prelude for all plugin modules, or record that only some plugins are redefinable.

**P2-8. The activation watchdog injects an asynchronous error after 5 s (pre-existing).**
- **Fact:** `call-with-activation-time-limit` raises an `error` in the activating thread with `thread-interrupt!` (`boot.ss:238-287`). The quit inhibition that protects kernel bookkeeping does not cover a plain error.
- **Inference:** a slow but legitimate activation can be interrupted between, say, `entry-table-add!` and its `context-defer!` (`plugins.ss:125-126`). The registration would then belong to no receipt, which is the outcome the comment says it avoids. The Gerbil guide calls for cooperative cancellation.

**P2-9. Dispatcher boilerplate (Opinion; pre-existing).**
- 97 typed dispatchers write the return type twice, in the signature and in `(:- … T)`. A `defdispatch` form generated from the interface would halve the contracts.
- Text reads go through 3–6 dispatches per primitive. For example, `text-line-end` → `check-line` → `text-line-count` → `text-snapshot` (`plugins/buffers/contract.ss:337-352`). `TODO.md` already notes the read cost.

## Q2. The run-time declared-use mechanism

### What it is (Fact)

- **`current-context`** (`plugins.ss:76`) is the ambient owner. It is set during activation (`:538`). Inside a task it is reset to `#f` (`loop.ss:460`).
- **`call-with-context` / `context-bind`** (`:79-86`) switch it for a thunk or a stored procedure.
- **`call-with-service-provider` and the macro `with-service-provider`** (`:404-425`) do three things:
  - check the caller (`check-service-use!`, `:393-401`);
  - find the provider in a per-service cache (`:338-385`) holding implementation, provider context, provider name, contributing owners and a "last kernel" tag;
  - run the body under the provider's context, with a fallback for a provider that is still activating.
- **`call-with-task-owner`** (`loop.ss:256-260`) adds a temporary cancel inverse to the command's receipt. That part is lifetime management, not attribution.
- **Exemptions:**
  - `unchecked:` owners (`init`, `PLUGIN/config` and `session-owner`; `tuna/config.ss:54,111`, `boot.ss:1254`);
  - a provider using its own service;
  - the kernel's `message`;
  - any code with no owner (`#f`): tasks before a command re-scopes, job `apply`, kernel seams.
- **What the check found (Fact, stage-1 report):** one real omission (the layout plugin needed settings) and some over-declared fixtures.
- **What it broke for correct code (Fact):**
  - every `config:` block that bound a key, which is why `unchecked:` exists (stage-1 report, "Supervisor decision");
  - the Mac Option path (`3963901`).

### Inventory of tracking occurrences

The task estimate was ~154 occurrences in 15 files. My count of the eight names (`current-context`, `call-with-context`, `context-bind`, `call-with-service-provider`, `with-service-provider`, `call-with-task-owner`, `call-with-context-receipt`, `unchecked:`) across non-test `.ss` files is 186 matches in 24 files, including kernel definitions, exports, `starter/` and `demo/` (Fact, grep). By role:

| Role | Where | Count | Needed without run-time checking? |
|---|---|---|---|
| Typed dispatch `(with-service-provider (p svc I) …)` | 9 contract files, mostly `buffers` 49, `layout` 16, `keys` 8 | 97 | The lookup, yes; the context switch and check, no |
| Explicit `call-with-service-provider` | completion 2, echo-area 1, help 2, keys contract 2, minibuffer 1, web 1; kernel `loop.ss` 3, `plugins.ss` 2 | 14 | Becomes a plain `service-provider` lookup |
| `context-bind` at registration | buffers, commands, completion, keys, layout, minibuffer ×2, session ×2, settings, boot, timers; kernel `context-defer!` and hooks | ~15 | No |
| `call-with-context` re-scopes | completion `session-exit!`, minibuffer `prompt-exit!`, boot ×2; kernel: loop ×4, `message`, failure report, receipts | ~12 | No, except one in `evaluate` |
| `current-context` for implicit registration | `defcommand`, `keymap-set`/`keymap-set-in`, config-blocks, `starter`/`demo` `config:` blocks, activation | ~10 | Yes |
| `current-context` captured for attribution | `render-layout`, minibuffer `setup` and exit check | 3 | No |
| `unchecked:` | `config.ss` ×2, boot | 3 | No |
| `call-with-task-owner` | commands contract | 1 | Yes (lifetime) |

### Every place that must re-scope, and where the latent bug is

- **Threads spawned while a plugin context is current inherit it (Fact):**
  - The web server's request threads inherit web-transport's context (started in its activation, `plugins/web/plugin.ss:442`). The only service call on them is the input submitter, fixed in `3963901`. `web-transport-url` (`:66-70`) is called only by tests.
  - Timer countdown threads inherit the activating context but only queue tasks (`tuna/lib/timers.ss:30,46-51`): safe.
  - The loop thread inherits whatever context called `start-editor-loop!` (`loop.ss:194`): latent (P1-1).
  - Boot's load worker and watchdog: safe, because callers reset to `#f`.
  - Jobs use root threads with no context: safe for `run`, but `apply` is unowned (`jobs.ss:182`).
- **Kernel seams called from foreign threads (Fact):**
  - The input submitter re-scopes (fixed), but through the foreign thread's kernel parameter.
  - `call-on-editor-loop`, `spawn-task!`, `result-poster`, `cancel-task!`, `resume!` and `discard-input` only send messages: safe.
  - `message` resets to `#f` and then runs the Messages provider on the calling thread. That is safe only because no foreign thread calls it today.
- **Callbacks and handed-out objects:** the list in P1-1. Five unbound registration kinds, plus Prompt and CompletionSession methods.
- **Timers:** bound, safe.
- **Hooks and receipts:** bound.
  - `context-defer!` binds an inverse to whatever context is current when it is registered, not to `ctx` (`plugins.ss:99-102`). An inverse registered inside a provider's method therefore runs as the provider. This is surprising but harmless today (Fact).

### Is it earning its cost?

- **Cost: complexity.** The rule is cross-cutting and cannot be checked mechanically: every procedure, thread or object that crosses a plugin boundary must carry its owner. The code applies it in about 25 places and misses at least 8 (Fact). Failures surface in the user's editor, on paths tests did not take (Fact: `3963901`, `config:` blocks).
- **Cost: speed.** Measured medians (Fact):
  - Before Cordis, a dispatcher cost 134 ns and a direct method call 13 ns (`scratch/tuna-cordis/dispatch-bench/results.json`).
  - The first attribution version cost 349 ns. The per-service cache brought it back to 130 ns (stage 1) and 143 ns (stage 2).
  - A cached `service-provider` that reads two parameters and checks costs about 59 ns.
  - My micro-benchmark (`/tmp/tuna-review-bench/pbench.ss`, `gxc -O`, 3 runs) measured a parameter read at 27–40 ns over a direct call and a `parameterize` at 58–80 ns.
  - So most of a dispatcher's cost is the context switch, and the cache exists largely to pay for attribution (Inference).
- **Benefit.** It keeps `requires:` honest so that restarts reach every plugin holding a provider's objects. It also feeds `describe-services`.
  - **Inference:** the same honesty is available statically. A plugin can reach a service only through a contract it imports, or through the service value that contract exports. Code it receives from other plugins is that plugin's code.
  - **Inference:** transitive uses through another contract need no declaration for restart purposes. The restart closure already follows required services recursively (`deactivation-closure`, `plugins.ss:464-475`). If X requires layout and layout requires buffers, restarting buffers restarts X.

### The four options compared

| Option | What it deletes | What it keeps or adds | Occurrences removed (of ~165) | Guarantee lost or gained |
|---|---|---|---|---|
| **(a) Keep run-time checking, hardened.** Contexts do not cross threads (kernel-held thread-specific owner, or reset at the kernel's spawn points); bind every procedure-valued registration; re-scope Prompt and CompletionSession methods; store the input provider's context in the loop at start; a boundary-test lint for contract parameters of type `:procedure` that are not bound. | Thread resets (about 5) | About 10 new binds, the lint, and the cache; still ~130 ns | Net about +5 | **Gains:** the known latent sites closed. **Loses:** nothing. **Still:** a hand-applied rule for every new callback, run-time failures on untested paths, and exemption holes (`#f` code, jobs, `unchecked:`, evaluation). |
| **(b) Static check only (recommended).** `make test` rejects a plugin package (`plugin.ss` plus private files) that imports `plugins/X/contract.ss` without listing X's service in `requires:`, `optional:` or `provides:`. Imports of only struct and constant names are exempt (`only-in` of `struct-out` names). Later, run the same rule at configuration load for third-party packages; the expander already exposes module imports (`boot.ss:385-397`). | `check-service-use!`; the context switch in `with-provider-scope`; the cache fields for provider context, owner and owners; the activating-provider fallback; `unchecked:`; all registration binds; the manual re-scopes in completion, minibuffer and boot; the `#f` resets in `loop.ss` (including `3963901`'s); attribution tests. Estimated −60 to −80 kernel lines (Inference). | The 97 dispatchers as plain typed lookups; receipts, explicit `ctx`, owner-tagged entries, `call-with-task-owner`'s receipt; `current-context` for implicit registration; one `call-with-context` inside `evaluate`. Adds about 80–120 test lines. | About 40 outright; about 110 become plain lookups; about 10 stay | **Loses:** per-call enforcement; checking of use through another contract (covered by the transitive restart closure); checking of service objects obtained at run time (rare); and third-party plugins until the load-time version exists. **Gains:** catches undeclared imports on every path, including the Mac one, at test time; removes the bug class; dispatch should drop to about 60 ns (Inference from the measured `service-provider`). |
| **(c) Run-time check only in tests or debug builds.** | Production failures; production cost, if attribution is compiled out | All re-scoping code, now with two semantics | 0 | **Loses:** production checking. **Keeps:** the bug class in debug runs. It would not have caught the Mac bug, which no test reached. Not recommended. |
| **(d) Cordis-style explicit context objects:** services reached through `ctx` or a handle taken at activation. | All ambient attribution | An explicit `ctx` or handle argument on about 104 dispatchers and roughly 1,190 call sites outside contracts (Fact, grep, including tests and `init.ss`) | All ~165, but about 1,200 lines change | **Gains:** the strongest guarantee (checked when a handle is taken; captured lexically through threads and callbacks). **Loses:** Emacs-style `(insert "x")` ergonomics, which the approved brief keeps ("The dispatchers stay", research D7). Too costly now. |

### Recommendation: (b)

- **Rationale.**
  - The property Cordis's check protects (a complete restart closure, honest dependencies) is decided by which contracts a package imports. That is static, visible, and checkable on every path at `make test` time.
  - Ambient attribution cannot be made correct without discipline at every callback and thread boundary. It has already failed twice on correct code, and its holes (`#f` code, jobs, evaluation, raw callbacks) leave large unchecked regions anyway.
  - Keep the ownership attribution registrations always needed: receipts, explicit `ctx` on registration APIs, owner-tagged entries, and command cancellation. These predate the work and are not in question.
- **Order of work:**
  1. Add the import→declaration rule to `tuna/tests/unit/boundary-test.ss`, so the honesty guarantee exists before anything is removed.
  2. Delete per-call checking and re-scoping in the kernel and contracts.
  3. Put an explicit `call-with-context` in the session owner's `evaluate`. Today it relies on dispatcher scoping to make evaluated code belong to the session owner (`tuna/configuration.ss:54-56`, `boot.ss:1247-1249`).
  4. Record the divergence from Cordis (§5.1.4 checks every access) in ADR 2 and amend ADR 12's "Declared use" section.
- **Fallback.** If you keep run-time checking for Cordis fidelity, do (a), starting with the 8 unbound sites in P1-1 and the loop thread.

## Q3. Package layout (plugins/*, build.ss, Makefile, boundary test)

**Sound overall (Opinion).**
- One `gerbil.pkg` per concept with only a `package:` line.
- Contracts beside their default plugin.
- A boundary test that checks real imports, package cycles, private modules and re-exports, each with negative cases.
- None of this is elaborate for what it enforces.

**Fragile spots (Fact):**
- **`build.ss` is a hand-ordered list of 22 packages** (`build.ss:9-46`). Nothing checks that every `plugins/*/gerbil.pkg` appears there. A missing package simply is not built; that is caught only if something on a tested path imports it. The boundary test already computes the package graph (`boundary-test.ss` `package-graph`). Check `build.ss` against it, or derive the order from it.
- **Hand-kept lists in the boundary test:**
  - `feature-names`, described as "the exact pre-move file stems", is checked against kernel source. A new plugin's name is not forbidden in the kernel until someone adds it.
  - `program-files` and the public-module list in `public-tuna-target?`.
  - Opinion: derive the first from `plugins/*` and the `defplugin` names.
- **Vestigial baseline scaffolding.** The noun baseline is "shrink-only" with plan steps (`baseline-steps '()`), and now holds three permanent entries. A fixed allowlist would do (Opinion).
- **Tests and the demo reach into other packages by relative path,** for example `tests/support/swap-commands.ss:10-12` (`"../../plugins/renderer/tests/support/…"`) and `demo/init.ss`. Moving a package to its own repository, which the brief says "renames nothing", would break these. Module ids survive the move; test paths do not.
- **Module ids are `:tuna/plugins/X/…` while directories are `plugins/X/…`.** This needs a special case in the test's `reference-target`. It is fine, but every path tool must know it.
- **Missing:** the declarations-versus-imports check, which is Q2's recommendation and the natural next rule here.

## Cleanup items (what, where, why, size)

1. **Keys `arrival` reads no settings.** In `plugins/keys/plugin.ss:285-287`, return `'queue` when Alt is held, before calling `key-description`. Replace the `3963901` test with one asserting that `arrival` needs no service (`tuna/tests/unit/loop-test.ss:121-141,242-248`). *Why:* removes an off-baton read the contract forbids. *Size:* about 5 lines plus the test.
2. **Decide Q2.** For (b): add the rule to the boundary test (+80–120 lines), then delete attribution (about −60 to −80 kernel lines, about 20 sites in contracts, plugins and boot, plus attribution tests), and add an explicit context in `evaluate`. For (a): bind node renderers, button actions, completion tables and styles, `nearest-view`, job `apply`, and Prompt and CompletionSession methods; clear the context on the loop thread; store the input context in the loop (+30 lines and a lint). *Size:* one to two days either way.
3. **Fix the evaluation environment after reload.** `tuna/boot.ss:1206-1263`: give the session a child context of the latest configuration module on each successful load, and add a test. *Size:* about 15 lines plus a test.
4. **One startup-tier refusal.** In `boot.ss:1023-1160`: a typed condition raised by `restart-plugin!`; delete `refused-startup-service`'s irritant parsing and `startup-refusal`; rename `stays-on`; move its comment. *Size:* about −30 lines.
5. **Two kernel accessors instead of workarounds.** Export `plugin?` and a context-owner-name accessor (ADR 12 amendment). Delete the cast-as-predicate (`tuna/lib/configuration.ss:78`) and the throwaway entry (`boot.ss:1237-1238`). Pass `order:` for `session-owner` instead of `##greatest-fixnum` (`boot.ss:1257`). *Size:* about −10 lines.
6. **`posn-start-node` in the layout contract.** The layout and two-views register it instead of copying the lambda (`plugins/layout/plugin.ss:917-921`, `plugins/layout/tests/support/two-views.ss:112-118`). *Size:* about −8 lines.
7. **Minibuffer hides commands through `visible?:`** instead of patching command structs (`plugins/minibuffer/plugin.ss:242-247`). *Size:* about 5 lines.
8. **Entry tables keep one ordering.** Sort on read only (`tuna/kernel/entries.ss:49-63`). *Size:* about −10 lines.
9. **Delete dead code and fix stale text.**
   - Dead code: `context-define-container-kind!`, `startup-refusal`, `kernel-live?`, and `remove-plugin-option-override!` (or move it to test support).
   - Stale text: `loop.ss:178-179`, `plugins/session/contract.ss:34-36`, `docs/overview.md:151`.
   - *Size:* about −30 lines.
10. **Session plugin: one capture path and one restore path.** Route every orchestrated turn-off through the restart wrapper, and keep `keep-slot-data!` only for unorchestrated deactivation, or drop it (`plugins/session/plugin.ss:193-251`). *Size:* medium; needs care and tests.
11. **`build.ss` completeness check.** Assert in the boundary test that every `plugins/*/gerbil.pkg` is listed, or derive the order from `package-graph`. *Size:* about 20 lines.
12. **Boundary-test upkeep.** Derive `feature-names`; replace the count baseline with a fixed allowlist. *Size:* about −40 lines.
13. **One prelude for plugin modules,** if live redefinition is meant to work everywhere. 18 files, one line each.
14. **Split `apply-configuration!`** into classify, execute and report (`boot.ss:567-969`). Do this the next time reload changes. *Size:* large; behaviour-preserving with the existing reload tests.

## Limits of this review

- **Nothing was run** in the repository: no build and no `make test`. Claims about failures on unexercised paths (P1-1, P2-2, P2-4, P2-8) are inferences from reading.
- **The cost of option (b)'s dispatch is estimated,** from the measured `service-provider` (59 ns) and my `/tmp` micro-benchmark, not measured on a modified kernel.
- **The occurrence counts** come from grep over non-test `.ss` files and include comments and exports. They differ slightly from the task's ~154.
- **I did not read fully:** `tuna/control.ss`, the layout tree module (`plugins/layout/tree.ss`), the renderer and buffers plugins, or the kernel tests.
