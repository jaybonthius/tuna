# 12. A small fixed kernel; every editor feature is a plugin, in three tiers of replaceability

Status: accepted (2026-10-11); amended 2026-10-12 with the kernel contract (owner-approved brief: [`docs/briefs/2026-10-kernel-contract.md`](../../docs/briefs/2026-10-kernel-contract.md); research: [`agents/research/kernel-contract/`](../research/kernel-contract/), [`kernel-audit-2026-10-12.md`](../research/kernel-audit-2026-10-12.md)). The "Kernel contract" section below supersedes the kernel list in the Decision section where they differ.

## Context

The owner wants Tuna itself to be little more than scaffolding, with everything else (state, command loop, window management, buffers) supplied by plugins, as in Cordis-based systems. The alternative is a functional core that exposes replaceable parts through contracts.

The two differ in one respect that matters: whether Tuna's default implementations use the same contracts as third-party plugins. Where defaults live in a privileged core, contracts decay unnoticed (VS Code's and Neovim's editing cores are not replaceable for this reason). Where everything is a plugin, contracts are exercised daily, but some things cannot be plugins: the machinery that loads plugins, and the concurrency rules every plugin's safety depends on. Editor subsystems are also more tightly coupled than Cordis's original domain (chat bots); Eclipse/OSGi shows the cost of fine-grained extension points nobody can follow.

## Decision

- **Defaults are plugins.** Every editor feature is a plugin, and Tuna's own defaults (text store, buffers and views, command-loop policy, minibuffer, window manager, renderer, persistence, transport) use only public contracts, with no privileged access. Tuna ships a standard plugin set so it works out of the box. (Superseded 2026-10-12: there is no standard set; Tuna ships a starter `init.ss` the user copies, and with no configuration it turns nothing on. See the configuration brief.)
- **The kernel** is the only part that is not a plugin. It contains:
  1. the plugin runtime: contexts, receipts, the service registry, manifests, and dependency activation ([ADR 2](0002-plugins-contexts-and-services.md));
  2. the execution rules: the baton, tasks and yield points, jobs, and the quit lane ([ADR 3](0003-command-loop-and-jobs.md)) (the kernel contract below keeps only posting results; jobs are a shared library);
  3. shared vocabulary that contracts depend on: identities, revisions, and change records ([ADR 4](0004-state-ownership.md)) (the kernel contract below moves change records to the buffers contract and keeps only identities; revisions belong to the objects that carry them).

  It contains no editor features.
- **Three tiers of replaceability.**

  | Tier | What | How it is replaced |
  |---|---|---|
  | Fixed | The kernel | Only by upgrading Tuna |
  | Startup | Command-loop policy (key resolution, keymap stack, input sessions; [ADR 8](0008-input-keymaps-and-command-composition.md)), settings resolution ([ADR 9](0009-settings-and-scoped-values.md)), persistence format ([ADR 5](0005-persistence.md)), client transport ([ADR 7](0007-rendering-and-transport.md)) | Select another provider in configuration and restart |
  | Live | Text store, texts/buffers/views, window manager ([ADR 11](0011-window-management-is-a-plugin.md)), renderer, minibuffer and prompts, completion, modes, themes, and everything else | Swap at runtime; the outgoing provider hands its state to the incoming one through the contract |

  A service declares its tier. Startup-tier services refuse live replacement.
- **Few, coarse contracts.** Contracts sit at subsystem boundaries (text store, buffers, window manager, renderer, input), not around individual functions, and contracts between coupled subsystems are designed together.
- **Proving contracts.** Each contract is designed while its default is built and proven by swapping in a deliberately small second implementation.
- **Versioning.** Contracts carry versions; plugin manifests declare which versions they support.
- **Recovery and visibility.** Recovery from a broken configuration comes from the user's own configuration, not from a built-in default plugin set, and Tuna keeps no stored history of it (configuration brief, 2026-10-12). Built (configuration stage 1): start-up turns each declared plugin on separately, so a failure is undone and reported, plugins that need it are skipped, and the rest come up; a start-up report on the terminal and in `$XDG_STATE_HOME/tuna/startup.log` lists what came up, failed, or was skipped; `tuna check` loads and validates a configuration without starting anything. Reloading a fixed configuration into the running editor comes in stage 2. A `describe-services` command shows which provider fills each service, its tier, and its dependents.

## Kernel contract (amendment, 2026-10-12)

The skeleton let the kernel drift from about 1,050 to 1,800 non-test lines by absorbing pieces of features (hooks table, timers, session slots, a command registry, a browser keyboard event type, text ranges for one job policy, latency data). This section is the authoritative statement of what the kernel is.

**Four layers**, each using only the layers below it: plugins (Tuna's own and users'), contracts (`tuna/services/`: interfaces, service values, vocabulary types, thin dispatchers only), shared libraries (`tuna/lib/`: conveniences built only on the public kernel API, with no special access; today timers and jobs), and the kernel (`tuna/kernel/`, facade `tuna/kernel.ss`).

**The kernel contains exactly:**
1. **Plugin runtime:** plugins, `defplugin`, contexts and receipts (`context-defer!` is the one primitive every registration is built from), owner-tagged entries, activation and deactivation, services with providers, tiers, dependents that restart or adapt, and swap handover.
2. **Execution rules:** the baton, tasks, suspension at yield points, the quit lane, the input queue, `input-pending?`, `discard-input`, and posting a result to the editor thread from another thread (`result-poster`). Input reaches the queue through a procedure captured from the kernel (`input-submitter`, which replaced `submit-input!`): the kernel object is private, so only the kernel can bind a submission to its own loop, and a transport's request threads never select a kernel.
3. **Hooks and identities:** one generic hook mechanism (each hook object owns its callbacks; no kernel table), which the kernel also uses to announce its own lifecycle events (`plugin-activated-hook`, `plugin-deactivated-hook`, `service-changed-hook`, `task-started-hook`, `task-finished-hook`; each runs after its state change is complete, and its callbacks must not activate or deactivate plugins; while the editor loop runs they may queue a task that does); and `next-id!`.
4. **Consumed seams:** the `Input`, `Display`, and `Messages` services the kernel calls.

**The kernel must never know about:** keys, mouse, browsers, HTTP, clients, text, characters, positions, ranges, changes to text, buffers, views, windows, frames, screens, rendering, a command registry, keymaps, settings, files, saving and sessions, timers, profiling or measurement, the demo, or the name of any plugin. `tuna/kernel/` imports nothing from `tuna/services/` or `tuna/plugins/`.

**Input:** the kernel queues opaque input items and never looks inside them. The `Input` service has two duties: classify an arriving item as "queue" or "interrupt" (on the arriving thread, without touching editor state; this is how the quit key works), and resolve a queued item to the task it starts, as a name and a thunk (on the baton; for keys, the command registry in the keys plugin supplies both). Key presses are resolved through keymaps by context and mode. Clickable UI (buttons, menu items, mouse clicks) sends "activate node N with gesture G"; the input plugin checks that node N is still current and resolves the gesture through the node's keymap, which the server bound when it rendered the node (for example `activate` to a command with captured arguments). The client never names a command. This follows Emacs, where buttons and menus are events resolved through keymaps. Purely presentational interaction (scrolling, disclosure) may stay in the browser.

**Changes to the kernel:** there is no size limit. Every new kernel export, data field, or interface method requires an amendment to this ADR saying why no plugin or library could own it, and every merge review states whether the kernel changed and why. `make test` includes mechanical checks: a search of `tuna/kernel/` for the forbidden nouns above, a check that the kernel imports no service or plugin module, a check that libraries import only `:gerbil`, `:std`, the kernel facade `:tuna/kernel`, and other libraries, and a check that only tests import test support (`tuna/test-support/`, which holds the test-only way to make a fresh kernel).

- **`plugin-requires` (2026-10-12, configuration stage 1).** The facade now exports the accessor for the services a plugin declares it requires, an existing field of the plugin value (ADR 2's manifests already list required services). The start-up code (`tuna/boot.ss`) uses it to turn a declared plugin on only once its services are provided and to report a plugin it skips as "needs X, which no plugin provides". Nothing outside the kernel can recover this from the plugin value otherwise. It adds no behavior and no state.

## Consequences

- "State management" is not a replaceable component: each plugin owns its state objects, the kernel enforces ownership, and saving state is the persistence plugin's job.
- The kernel stays small enough to understand completely; most of Tuna's code lives in plugins that users can read, fork, and replace.
- Every default costs a contract and a toy second implementation. This is the price of honest replaceability and is paid once per subsystem.

## Alternatives considered

- **Functional core with replaceable parts.** Rejected: defaults inside the core bypass the contracts, so replaceability erodes.
- **Literally everything a plugin, including execution rules.** Rejected: plugins cannot load themselves, and swapping concurrency rules mid-session would invalidate every running task.
- **Every service live-replaceable.** Rejected: large design cost for things changed perhaps once.
