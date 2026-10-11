# 2. Everything is a plugin; plugin contexts revert what they register

Status: accepted (2026-10-11)

## Context

Emacs extensibility is a set of unrelated mechanisms: symbol cells, advice, hooks, registries and alists, and best-effort `unload-feature` ([research](../../research/live-extensibility-racket/research/emacs-extension-architecture.md)). Nothing owns a package's contributions, so disabling or reloading a package rarely restores the prior state.

Cordis ([source](https://github.com/cordiverse/cordis), [paper](https://arxiv.org/abs/2608.25512)) structures a program as plugins that receive a context. Every effect registered through that context carries its inverse (temporal composability), and plugins declare the services they depend on, activating and deactivating as those services come and go (spatial composability).

The owner requires that as much as possible be user-replaceable, including the text data structure behind buffers.

## Decision

- **Plugin.** A plugin is a named unit with an activation procedure that receives a context. Tuna's own features (basic editing, minibuffer, files, windows, the HTML renderer) are plugins; the core only provides the editor thread, the plugin registry, and the service registry.
- **Context.** Every contribution goes through the context: commands, keybindings, hooks, advice, services, renderers, jobs, timers, subprocesses, persisted-state slots ([ADR 5](0005-persistence.md)). The context records an inverse for each. Deactivating a plugin runs those inverses in reverse order. Contributions made outside a context are the package's own responsibility.
- **Services.** A service is a named slot holding an implementation of a `std/interface` interface (for example `TextStore` or `Renderer`). Plugins declare the services they require. When a provider is replaced, dependents are deactivated and reactivated against the new provider. Replacing the buffer text structure means providing another `TextStore` service.
- **Reload.** Reloading a package means: deactivate its plugins, reload its modules, activate again. Fine-grained redefinition through `set!` remains available ([ADR 1](0001-language-and-extension-surface.md)) but is not the lifecycle mechanism.
- **Hooks and advice.** Hooks are named, ordered (depth, then registration order) lists of named callbacks. Advice wraps commands and service methods with Emacs's combinators (`before`, `after`, `around`, `override`, `filter-args`, `filter-return`). Both are registered through contexts and therefore removed on deactivation.
- **Configuration.** `init.ss` is itself a plugin, which is activated last; editing and re-evaluating it reverts its previous contributions first.
- **Trust.** Plugins are trusted in-process code. There is no sandbox.

## Consequences

- Disabling, reloading, and replacing packages become routine operations, not best-effort cleanup.
- Every core API that creates a long-lived effect must be context-aware. This is the main tax on core authors and must stay small.
- Service replacement while state exists (for example swapping `TextStore` with buffers open) requires a migration path: the new provider receives existing content through the interface. The first implementation may require switching before buffers exist.
- The design is validated by the architecture skeleton: activating, deactivating and reactivating a plugin must leave no stray commands, keys, hooks, or jobs.

## Alternatives considered

- **Emacs model (global mutable registries plus `unload-feature`).** Rejected: no reliable reversal.
- **Redefinition only (macros or `set!`).** Rejected as the primary mechanism: it cannot express "remove everything this package added".
- **Out-of-process plugins.** Rejected as the default: latency and API friction. Long-running external work still runs in subprocesses ([ADR 3](0003-command-loop-and-jobs.md)).
