# Tuna kernel audit (read-only)

Audited at `HEAD` = `380fdc0` ("Remove latency instrumentation from the kernel and web plugin"), branch `main`, 2026-10-12. HEAD changed during this audit: the latency commit `f5a07f3` was reverted (`c1cd140`, merged in `380fdc0`). Everything below describes the code after that revert. Line numbers refer to it.

## Answer

- **The latency leak is gone.** `Display` is back to `(redisplay!) => :void` (`tuna/kernel/loop.ss:74-76`). The loop no longer has an `unshown` field. `tuna/plugins/web.ss` has no arrival, shown, or latency state. The demo no longer imports `:tuna/plugins/web`.
- **The kernel is roughly the size ADR 12 implies, but it is drifting.** It has 1,798 non-test lines. About 1,500 of them are the three things ADR 12 lists. The other ~290 lines (hooks, timers, session slots, the command registry, `span`/`rebase-spans`, and the browser-shaped `key-event`) arrived one stage at a time. Each one also added a hard-coded field to the `kernel` class.
- **The biggest ADR 12 problem is now outside `tuna/kernel/`.** `tuna/services/buffers.ss` is a 674-line implementation of texts, undo, the change journal, decorations, points, and editing, presented as a contract. The "default buffers plugin" (`tuna/plugins/buffers.ss`, 58 lines) is only a registry, so no replacement can change how texts, buffers, or views behave.
- **The worst remaining kernel contract is the input event type.** It is shaped around one consumer: the kernel's input event is the browser's `KeyboardEvent`.

## Kernel size: now versus ADR 12

ADR 12 gives no line budget. It names three buckets: (1) the plugin runtime: contexts, receipts, services, manifests, dependency activation; (2) the execution rules: baton, tasks and yield points, jobs, quit lane; (3) shared vocabulary: identities, revisions, change records.

| Module | Lines | ADR 12 bucket | Content outside ADR 12's list |
|---|---:|---|---|
| `kernel/ids.ss` | 50 | vocabulary | `span` (ids.ss:45-50), a text-range type |
| `kernel/entries.ss` | 68 | runtime (owner-tagged entries) | none |
| `kernel/state.ss` | 66 | runtime state | fields `commands`, `slots`, `hooks`, `jobs` (state.ss:29-33), one per feature |
| `kernel/plugins.ss` | 565 | runtime, services, adapters, handover, `describe-services` | command registry (503-546, ~44 lines); `Messages` (548-565, ~18 lines) |
| `kernel/hooks.ss` | 78 | not listed | all of it |
| `kernel/loop.ss` | 631 | execution rules | browser `key-event` struct (51-64) and the queue predicates built on it (419-426) |
| `kernel/jobs.ss` | 199 | execution rules | `rebase-spans` (179-199): assumes results are lists of spans |
| `kernel/timers.ss` | 59 | not listed | all of it; uses only the public kernel API |
| `kernel/slots.ss` | 50 | not listed (ADR 2/5 reload) | all of it |
| `kernel.ss` | 32 | facade | exports the `kernel` object, `new-kernel`, `current-kernel` |
| **Total** | **1,798** | | **~290 lines (~16%) outside the list** |

How it grew (from `git log`): stage 1 added the runtime and loop, which fit the list. `3255918` added `Messages`, the command registry, and change records. `b9b7758` added hooks, timers, jobs, and suspension. `45af055` added handover and slots. `f5a07f3` added latency, which is now reverted. The architecture-skeleton plan's "Shape" section lists `tuna/kernel/` as "plugin runtime, service registry, editor loop, ids and revisions". Hooks, timers, and slots are not in it.

## Findings, by severity

### P1-1. The buffers "contract" is the implementation, so texts, buffers, and views cannot be replaced
- **Where:** `tuna/services/buffers.ss:55-674`. It contains the concrete final classes `text`, `buffer`, `view`, and `node`, plus undo (216-270), the journal (190-214), decorations and their relocation (272-324), point relocation (326-350), `kill-buffer` policy (579-587), and `insert`/`delete-region`/`goto-char`. The `Buffers` interface (411-428) covers only a list, the selected and focus views, and two entry tables. The provider `tuna/plugins/buffers.ss` (58 lines) implements just that.
- **What:** A replacement buffers plugin can change where buffers are stored. It cannot change undo, the journal, decorations, positions, or editing, because every plugin calls these as concrete procedures in the facade.
- **Category:** (c) feature and policy inside a non-replaceable module, and (e) a contract shaped around the one default.
- **Why it is there:** Stage 2 (`0dbcec1`) built texts, buffers, and views as one module "next to the service". Stage 3 (`15db121`) added undo grouping, snapshots, the change hook, and highlights to the same file.
- **Conflicts with:** ADR 12 ("Defaults are plugins… texts/buffers/views: Live"); ADR 6 ("editor policy stays above the store… undo… live in the buffer layer"); `docs/overview.md:15` ("anything they can do, a replacement can do too").
- **Recommendation:** Decide this in a brief before the next buffer work.
  - Keep in `services/buffers.ss`: identities and vocabulary (`node` and its kinds, `change`, `snapshot`) and thin dispatchers.
  - Move the behavior behind the `Buffers` interface, into the buffers plugin: text editing, undo, journal, decorations, and point relocation.
  - Smallest first step: route `text-replace!`, `text-undo!`, `set-highlights!`, and `relocate-position` through `Buffers` methods. Until then, record the deviation in ADR 12 and `TODO.md`.

### P1-2. The kernel's input event is the browser's KeyboardEvent
- **Where:** `tuna/kernel/loop.ss:51-64` (`key-event` with `key`, `code`, `location`, `repeat?`, `composing?`, `alt?`, `ctrl?`, `meta?`, `shift?`). The `Input` interface is typed on it (67-72). `input-queued?` and `discard-input!` test `key-event?` (419-426). `submit-event!` takes `key-event`.
- **What:** ADR 7 requires mouse, paste, composition, and resize events. Each one would need a kernel edit, because the queue recognizes input only as `key-event?`.
- **Category:** (e) a kernel contract shaped around one consumer: the web keyboard plugin.
- **Why it is there:** Stage 1 (`3cda8ed`, `c56edee`) needed one event type, and the struct was put next to the loop.
- **Recommendation:** The kernel should define only a minimal `input-event` base: client id and sequence number (ADR 10 vocabulary).
  - Type `Input`, `submit-event!`, `input-queued?`, and `discard-input!` on that base.
  - Move `key-event` (as a subtype) to `tuna/services/keys.ss`, which the transport and the keys plugin both import.
  - Update `kernel/test-fixtures.ss` and `plugins/test-keys.ss`, which construct `make-key-event`.

### P2-1. The kernel keeps growing a field and a module per feature
- **Where:** `tuna/kernel/state.ss:26-36` (fields `commands`, `slots`, `hooks`, `jobs`), `kernel/hooks.ss`, `kernel/timers.ss`, `kernel/slots.ss`.
- **What:**
  - `timers.ss` uses only public kernel exports: `spawn-task!`, `cancel-task!`, `running-task`, `context-defer!`.
  - `hooks.ss` uses only `context-defer!`, `context-plugin-name`, `next-id!`, and `message`, plus its own kernel field.
  - `slots.ss` is `context-add-entry!` over its own kernel field.
  - None of the three is in ADR 12's list. They live in the kernel because each needs per-kernel state for test isolation (`current-kernel` is parameterized per test).
- **Category:** (b) generic mechanisms that are fine but could live outside the kernel.
- **Why it is there:** `b9b7758` (hooks, timers) and `45af055` (slots). The plan's stage 3 and 4 text says "registered through plugin contexts", not "in the kernel".
- **Recommendation:**
  - Add one generic per-kernel extension store (for example `(define-kernel-local name init)`) and delete the per-feature fields.
  - Move `timers.ss` and `hooks.ss` to a non-kernel library directory (for example `tuna/lib/`) that is built only on the public kernel API.
  - For `slots.ss`: keep it in the kernel only if plugin reload (ADR 2, "save its session slots, deactivate…, restore") will be a kernel operation, and then add it to ADR 12's list. Otherwise move it next to the session contract.
  - In every case, name the third layer (contract and mechanism libraries that are neither kernel nor plugin) in ADR 12, because `services/*` already is one.

### P2-2. The kernel's job `rebase` policy assumes text spans
- **Where:** `tuna/kernel/ids.ss:45-50` (`span`); `tuna/kernel/jobs.ss:92-94` and `174-199` (`rebase-spans`).
- **What:** The kernel interprets the job result's shape (a list of `span`) and implements position mapping. That mapping exists twice more in the buffers facade: `relocate-decorations!` (buffers.ss:300) and `relocate-through` (buffers.ss:338).
- **Category:** (e). ADR 3 names `rebase` as a kernel policy, but mapping positions is the target's knowledge.
- **Why it is there:** Stage 3 (`b9b7758`) was built for the demo's digit highlighter.
- **Recommendation:**
  - Add `(job-rebase result since-revision) => result-or-#f` to the `JobTarget` interface, so the kernel keeps only the policy name and calls the target.
  - Move `span` and `rebase-spans` to `services/buffers.ss` and implement `job-rebase` on `text` (buffers.ss:87).
  - This removes the kernel's last text-specific type.

### P2-3. The demo reaches into other plugins
- **Where:** `tuna/plugins/demo.ss:16-19` imports `string-text-store`, `basic-editing`, `plain-text-renderer`, and `two-windows`, and toggles their plugin values (`demo.ss:111-115`, `148-169`). `demo.ss:125` uses `join-runs` from `:tuna/plugins/plain-text-renderer`.
- **What:**
  - The toggling is acknowledged (`demo.ss:5-7`). Until manifests exist (ADR 2), a plugin can only be referenced by importing its module.
  - The `join-runs` use is real coupling. The run format of the `plain-text` render target is defined privately by one renderer, so any node kind that wants plain-text output must import that renderer plugin.
- **Category:** (d).
- **Recommendation:**
  - Move `join-runs` and the definition of the run format to `tuna/services/renderer.ss`; the format is part of the render-target contract.
  - Leave the toggle imports until manifests exist, then replace them with activation by name.

### P2-4. The demo is in the standard plugin set and owns `describe-services`
- **Where:** `tuna/main.ss:30-34` (`demo-plugin` in `standard-plugins`); `demo.ss:137-138` and `175` (`describe-services` / `C-h s`); `demo.ss:158-159` (a slow digit highlighter on `after-change-hook` for every text).
- **What:** ADR 12 makes `describe-services` part of recovery and visibility, but it disappears when the demo is turned off. Every normal session runs a demo job after each edit.
- **Category:** (c) demo concern in the default boot.
- **Recommendation:** Move `describe-services` and `services-description` (`demo.ss:29-47`) into the help plugin, or a small `describe` plugin. Take `demo-plugin` out of `standard-plugins`, or enable it only with a `--demo` flag.

### P2-5. Boot hard-codes the web transport; the URL is read by checking the provider's type
- **Where:** `tuna/main.ss:51-54` (`web-transport-listen-port`, `web-transport-url`); `tuna/plugins/web.ss:59-64` (`web-transport-url` tests `(web-transport? display)` on the display provider).
- **Category:** (d), minor; boot is not a plugin.
- **Recommendation:** Let the transport report its own launch URL when it activates; it owns the token. Then `main.ss` only activates the configured plugin set. This matches ADR 12's "client transport: select another provider in configuration".

### P2-6. The kernel object and its constructor are public
- **Where:** `tuna/kernel.ss:22-25` exports `kernel`, `kernel?`, `new-kernel`, `current-kernel`. Outside the kernel they are used only by `web.ss:32,275,322` (to parameterize request threads) and the test fixtures.
- **What:** Any plugin can make or swap a kernel. The transport needs only a way to submit events from foreign threads.
- **Category:** (d) public, but more than a plugin should hold.
- **Recommendation:** Add a kernel `input-submitter` that closes over the kernel, the way `result-poster` (`loop.ss:309`) already does for jobs. Use it in `web.ss` and stop exporting the kernel object from the plugin facade. Tests can import a test-only facade.

### P2-7. Utilities and presentation policy inside contract modules
- **Where:**
  - `tuna/services/session.ss:49-90` (`plain-data?`, `write-file-atomically!`). Autosave uses the second (`autosave.ss:72`) and so depends on the session contract for a file helper.
  - `tuna/services/renderer.ss:23-40` (`status-line-text`): mode-line content shared by both renderers.
- **Category:** (b) and (c), small.
- **Recommendation:** Move the file helpers to a files library; that is where ADR 5's file-system service will go. Leave `status-line-text` until mode lines are built, then give it to a mode-line plugin.

### P2-8. Test aids live in the kernel and plugin directories
- **Where:** `tuna/kernel/test-fixtures.ss`, `tuna/plugins/test-keys.ss`. Neither is a built module (both are absent from `build.ss`); test files include them.
- **Category:** (c), placement only; they do not ship.
- **Recommendation:** Move them to a test-support directory so `tuna/kernel/` holds only kernel code. This follows the new AGENTS.md rule ("test aid lives in a plugin" or at least outside the kernel).

## What a plugin could own instead

| Kernel piece | Verdict |
|---|---|
| Service handover (`plugins.ss:147-231`) | **Keep** (a). It is part of service replacement; ADR 12 defines the live tier by handing state over. |
| Adapters (`context-adapt!`, `plugins.ss:296-326`) | **Keep** (a). ADR 2, amended. |
| `describe-services` data (`plugins.ss:471-502`) | **Keep** (a); move the command out of the demo (P2-4). |
| `Messages` service and `message` (`plugins.ss:548-565`) | **Keep** (a/b). The kernel reports its own failures and consumes this service as it consumes `Input` and `Display`. Do not add features to it. |
| `Input` / `Display` seams (`loop.ss:67-84`) | **Keep**, after P1-2. `Display` is clean again. |
| Command registry (`plugins.ss:503-546`) | **Keep for now** (b). When ADR 8 interactive specifications arrive, they belong to the input-policy plugin, not the kernel. |
| Hooks, timers | **Move out** (b), P2-1. |
| Session slots | **Decide** (b), P2-1: keep only if reload is a kernel operation, and then list it in ADR 12. |
| `span`, `rebase-spans`, `key-event` | **Move out** (e), P2-2 and P1-2. |
| Settings | Already a startup-tier plugin (`plugins/settings.ss`). The dynamic layer in `services/settings.ss` is language-level, as ADR 9 intends. **No change.** |
| Echo area | Already a plugin (`plugins/echo-area.ss`). **No change.** |

## Services: tiers and dependency kinds

| Service | Tier | Assessment |
|---|---|---|
| input, display, settings, session | startup | Correct per ADR 12. |
| text-store | live; buffers **adapts** | Correct; proven by the string-store toy. |
| window-manager | live, with handover | Correct; proven by the two-windows toy. |
| renderer, help, messages, minibuffer | live, no handover | Acceptable: stateless, or state that is fine to lose. The minibuffer's receipt abandons waiting prompts. |
| **buffers** | **live, no handover, no toy** | **Unproven tier.** Replacing the provider restarts minibuffer, basic-editing, both window managers, both renderers, autosave, and the demo, and replaces every buffer with a fresh `*scratch*` (`plugins/buffers.ss:45`). ADR 12 requires a handover and a toy for live services. Declare it `startup` until it has a handover, or add one (buffer list plus selected view). This finding is mostly moot until P1-1 is fixed. |

Undeclared dependencies:
- `demo-plugin` (`demo.ss:118`) requires only `input-service` and `buffers-service`. It calls `setting-value` on every edit (`demo.ss:80`), `show-help`, and `read-string`. It works only because `main.ss` activates settings, help, and minibuffer first. Add `settings-service` to its `requires:`; help and minibuffer are optional, used at command time.

No plugin uses kernel internals: there are no `kernel-*` accessors, `slot-ref`, or `##` primitives in `tuna/plugins/` or `tuna/services/`. Only the demo imports another plugin.

## Notes for the planned profiler plugin

The retraction note (`agents/plans/architecture-skeleton.md`, stage 4) says measurement should be "built on general-purpose hooks". Three constraints apply:

- **Kernel hooks are baton-confined.** `run-hook` reads `(the-kernel)` tables without a lock (`hooks.ss:29-38`). Event arrival and stream writes happen on HTTP request and writer threads, so they cannot use kernel hooks. The transport needs its own thread-safe observer list, which it owns and documents as part of its plugin. Alternatively it can post facts to the baton with `result-poster`.
- **Command-loop hooks belong to the input-policy plugin.** ADR 8 lists `pre-command` and `post-command` as policy hooks, so they belong in `plugins/keys.ss`, not the kernel loop. Render timing can be observed by wrapping `Display` at startup.
- **The untracked research recommends a design the new AGENTS.md rule forbids.** `agents/research/profiling/tuna-profiler-stream-design.md` recommends "Option A": a private profile token threaded through the runtime's command request and state root. That is exactly the kernel entanglement the rule forbids. That document targets an earlier runtime (`tuna/tuna/lib/runtime.ss`), so do not port its recommendation as written.

## Top changes to restore the kernel's size and purity

1. Replace the kernel's `key-event` with a minimal `input-event` (client and sequence number); move the browser fields to `services/keys.ss` (P1-2).
2. Split `services/buffers.ss` so undo, journal, decorations, relocation, and editing sit behind the `Buffers` provider. Until then, record the deviation in ADR 12 and make the buffers service startup-tier (P1-1).
3. Add one per-kernel extension store; delete the `commands`/`slots`/`hooks`/`jobs` special fields; move `hooks.ss` and `timers.ss` out of `tuna/kernel/`; decide on slots in ADR 12 (P2-1).
4. Move `span` and `rebase-spans` out of the kernel behind `JobTarget-job-rebase` (P2-2).
5. Move `describe-services` to a help plugin and take the demo out of the default boot (P2-4). Put `join-runs` and the plain-text run format in the renderer contract (P2-3).
6. Add a short line-count budget per kernel module to ADR 12 (today about 1,500 lines after the moves above) so drift shows up in review.

## Residual risks

- I did not build or run tests (read-only audit). Every line reference is from source at `380fdc0`.
- HEAD moved during the audit; findings reflect the post-revert tree. Uncommitted changes at audit time: `AGENTS.md` (the new "Keep the kernel small" section) and the untracked `agents/research/profiling/` and `.vscode/`.
- Line counts are raw `wc -l`, including comments.
