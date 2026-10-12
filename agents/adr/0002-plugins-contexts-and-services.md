# 2. Everything is a plugin; plugin contexts revert what they register

Status: accepted (2026-10-11); amended after the [capability audit](../research/capability-audit/README.md) (owner-tagged effects, manifests, reload, multi-provider services, provenance), and after stage 2 (dependents that adapt instead of restarting).

## Context

Emacs extensibility is a set of unrelated mechanisms: symbol cells, advice, hooks, registries and alists, and best-effort `unload-feature` ([research](../research/live-extensibility-racket/research/emacs-extension-architecture.md)). Nothing owns a package's contributions, so disabling or reloading a package rarely restores the prior state.

Cordis ([source](https://github.com/cordiverse/cordis), [paper](https://arxiv.org/abs/2608.25512)) structures a program as plugins that receive a context. Every effect registered through that context carries its inverse (temporal composability), and plugins declare the services they depend on, activating and deactivating as those services come and go (spatial composability).

The owner requires that as much as possible be user-replaceable, including the text data structure behind buffers.

## Decision

- **Plugin.** A plugin is a named unit with an activation procedure that receives a context. Tuna's own features (basic editing, minibuffer, files, windows, the HTML renderer) are plugins with no privileged access; the kernel and the tiers of replaceability are defined in [ADR 12](0012-kernel-boundary-and-replaceability.md).
- **Context and receipt.** Every contribution goes through the context: commands, key bindings, hooks, advice, settings values, services, renderers, jobs, tasks, timers, subprocesses, persisted-state slots (kept by the session service; [ADR 5](0005-persistence.md)). The context records an inverse for each in the plugin's **receipt**. Deactivating a plugin runs the receipt's inverses in reverse order. Contributions made outside a context are the package's own responsibility.
- **Owner-tagged effects.** Slot-like effects (a key binding, a setting value, an advice entry, a service provider) are stored as entries tagged with their owning plugin and a priority; the effective value is the highest-priority live entry. An inverse removes only its owner's entry, so deactivation order between plugins never matters. This also lets help commands show who set what.
- **Provenance.** Every registration records its plugin, source location, and documentation, so `describe-key`, `describe-function`, jump-to-definition, and `where-is` work uniformly.
- **Manifest.** Declarative forms also produce a static manifest per plugin (commands with documentation, key bindings, file patterns, required services) at build or install time. Inactive plugins can therefore appear in `M-x` and help; invoking a stub activates its plugin first (Emacs autoload).
- **Dependencies.** Plugins declare required plugins and services; configuration that depends on another plugin attaches to it and is reverted when it deactivates (replaces `with-eval-after-load`).
- **Services.** A service is a named slot holding an implementation of a `std/interface` interface (for example `TextStore` or `Renderer`). Plugins declare the services they require. When a provider is replaced, each dependent either **restarts** (the default: it is deactivated and reactivated against the new provider, which suits stateless dependents) or **adapts** (it declares a handler that receives the old and new providers and migrates its own state in place, which suits stateful dependents such as buffers over the text store). Either way the dependency is visible in `describe-services`. Some services dispatch among several providers by key: the file-system and process services choose a provider by path, so remote files can be added later without touching their callers ([ADR 5](0005-persistence.md)).
- **Reload.** Reloading a package means: save its session slots, deactivate its plugins, reload its modules, activate them again, restore the slots. State not held in a slot does not survive reload. Fine-grained redefinition through `set!` remains available ([ADR 1](0001-language-and-extension-surface.md)).
- **Hooks and advice.** Hooks are named, ordered (depth, then registration order) lists of named callbacks. An erroring callback is disabled individually and reported, not the whole hook. Advice is described in [ADR 1](0001-language-and-extension-surface.md). Both are registered through contexts.
- **Configuration.** `init.ss` is itself a plugin, which is activated last; editing and re-evaluating it reverts its previous contributions first. Code evaluated interactively from a plugin's source buffer registers into that plugin; code evaluated elsewhere registers into a user-visible "eval" plugin.
- **Trust.** Plugins are trusted in-process code with the user's privileges. There is no sandbox. See [ADR 10](0010-security-clients-and-trust.md) for who may reach them.

## Consequences

- Disabling, reloading, and replacing packages become routine operations, not best-effort cleanup.
- Every core API that creates a long-lived effect must be context-aware. This is the main tax on core authors and must stay small.
- Replacing a service while state exists (for example swapping `TextStore` with buffers open) requires a migration path through the interface. The first implementation may require switching before buffers exist.
- The architecture skeleton validates this: activating, deactivating and reactivating a plugin must leave no stray commands, keys, hooks, timers, or jobs, and overlapping key bindings from two plugins must survive either deactivation order.

## Alternatives considered

- **Emacs model (global mutable registries plus `unload-feature`).** Rejected: no reliable reversal.
- **Restore-previous-value inverses.** Rejected: incorrect when two plugins set the same slot.
- **Redefinition only (macros or `set!`).** Rejected as the primary mechanism: it cannot express "remove everything this package added".
- **Out-of-process plugins.** Rejected as the default: latency and API friction. Long-running external work still runs in subprocesses ([ADR 3](0003-command-loop-and-jobs.md)).
