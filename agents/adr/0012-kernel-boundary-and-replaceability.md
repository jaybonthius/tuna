# 12. A small fixed kernel; every editor feature is a plugin, in three tiers of replaceability

Status: accepted (2026-10-11).

## Context

The owner wants Tuna itself to be little more than scaffolding, with everything else (state, command loop, window management, buffers) supplied by plugins, as in Cordis-based systems. The alternative is a functional core that exposes replaceable parts through contracts.

The two differ in one respect that matters: whether Tuna's default implementations use the same contracts as third-party plugins. Where defaults live in a privileged core, contracts decay unnoticed (VS Code's and Neovim's editing cores are not replaceable for this reason). Where everything is a plugin, contracts are exercised daily, but some things cannot be plugins: the machinery that loads plugins, and the concurrency rules every plugin's safety depends on. Editor subsystems are also more tightly coupled than Cordis's original domain (chat bots); Eclipse/OSGi shows the cost of fine-grained extension points nobody can follow.

## Decision

- **Defaults are plugins.** Every editor feature is a plugin, and Tuna's own defaults (text store, buffers and views, command-loop policy, minibuffer, window manager, renderer, persistence, transport) use only public contracts, with no privileged access. Tuna ships a standard plugin set so it works out of the box.
- **The kernel** is the only part that is not a plugin. It contains:
  1. the plugin runtime: contexts, receipts, the service registry, manifests, and dependency activation ([ADR 2](0002-plugins-contexts-and-services.md));
  2. the execution rules: the baton, tasks and yield points, jobs, and the quit lane ([ADR 3](0003-command-loop-and-jobs.md));
  3. shared vocabulary that contracts depend on: identities, revisions, and change records ([ADR 4](0004-state-ownership.md)).

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
- **Recovery and visibility.** A safe mode starts Tuna with only the standard plugins. A `describe-services` command shows which provider fills each service, its tier, and its dependents.

## Consequences

- "State management" is not a replaceable component: each plugin owns its state objects, the kernel enforces ownership, and saving state is the persistence plugin's job.
- The kernel stays small enough to understand completely; most of Tuna's code lives in plugins that users can read, fork, and replace.
- Every default costs a contract and a toy second implementation. This is the price of honest replaceability and is paid once per subsystem.

## Alternatives considered

- **Functional core with replaceable parts.** Rejected: defaults inside the core bypass the contracts, so replaceability erodes.
- **Literally everything a plugin, including execution rules.** Rejected: plugins cannot load themselves, and swapping concurrency rules mid-session would invalidate every running task.
- **Every service live-replaceable.** Rejected: large design cost for things changed perhaps once.
