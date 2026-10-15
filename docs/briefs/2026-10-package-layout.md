# Brief: one package per concept

**Date:** 2026-10-14. **Status:** approved 2026-10-14, with plugin names dropping the word "plugin". This replaces the version parked on 2026-10-14; it builds on the Cordis alignment (ADRs 2 and 12, amended 2026-10-14). Evidence: [`agents/research/package-layout/refresh-2026-10-14.md`](../../agents/research/package-layout/refresh-2026-10-14.md) (current imports, cycles, the full move map), the earlier [package-layout research](../../agents/research/package-layout/README.md) (Gerbil packaging facts, start-up timing) and [contract-models research](../../agents/research/contract-models/README.md).

## What this is and why

Today all of Tuna is one package under `tuna/`. Contracts sit together in `tuna/services/`, apart from the plugins that fill them, so they belong to no one. And Tuna's core still reaches into editor concepts: `main.ss` imports 21 plugins (the imports do nothing), and the language your `init.ss` is written in bundles `defcommand`, `keymap-set` and `defsetting` from the commands, keys and settings contracts.

This work makes the divide physical, with one rule: **each concept is one package, which owns the concept's contract and ships its default plugin.**
- **`tuna/`** is Tuna itself: the kernel, libraries, the start-up program and the `init.ss` language. It imports no concept and no plugin.
- **`plugins/<concept>/`** holds one concept: `contract.ss` (what any plugin filling the slot promises), `plugin.ss` (the default), private files, and its tests. A plugin that introduces no concept, such as Orderless, is a package with only `plugin.ss`.
- **Your package, or anyone's, works exactly the same way.** It imports Tuna and the contracts it needs. Our plugins have no other access.
- **Tests** live in a `tests/` directory beside what they test, split into `unit/` and `integration/`; tests that use several real plugins live in a top-level `tests/integration/`.

## The picture

![Which package may depend on which](../diagrams/package-layout.svg)

Arrows mean "imports". A replacement imports the concept's `contract.ss`, never its `plugin.ss`. Its package depends on the concept's package, so the default's code is installed alongside it but never loaded; you said that is fine. Each package is one directory with a `gerbil.pkg`, so moving one to its own repository later renames nothing.

## A walkthrough

1. **You write your own buffers plugin.** It imports `:tuna/plugins/buffers/contract` and declares `provides: [buffers-service]`.
2. **Your `init.ss` declares it** instead of ours. Declaring both is an error naming both (the Cordis work). Tuna loads it exactly as it loads its own.
3. **Someone publishes a package for a concept we never thought of,** say version control: `contract.ss` plus a default plugin. Other packages import its contract, and a third person can write a replacement against the same contract. Same files, same tools, same rules as ours.
4. **Someone adds an import of the layout plugin into the keys plugin.** `make test` fails, naming the file and the rule.
5. **Later the layout package moves to its own repository.** Nothing is renamed; `init.ss` still imports `:tuna/plugins/layout/plugin`.

## A code sample (package author's and user's view)

```scheme
;; plugins/my-buffers/gerbil.pkg
(package: tuna/plugins/my-buffers)

;; plugins/my-buffers/plugin.ss
(import :tuna/kernel
        :tuna/plugins/buffers/contract)        ; the promise only
(defplugin (my-buffers ctx)
  "Buffers kept my way."
  provides: [buffers-service]
  requires: [text-store-service settings-service]
  (context-provide! ctx buffers-service (make-my-buffers)))

;; your init.ss: you import what you use (decided 2026-10-14)
#lang :tuna/config
(import :tuna/plugins/keys/plugin
        :tuna/plugins/keys/contract                ; keymap-set
        :tuna/plugins/commands/contract)           ; defcommand
(use-plugin keys)
(keymap-set "C-c R" 'reload-config)
```

Names are illustrative.

## What has to change before files move

Moving directories alone would leave Tuna importing editor packages and two concepts importing each other. Each fix keeps behavior the same:
1. **`main.ss` drops its 21 empty plugin imports.** They never linked anything (earlier research measured it).
2. **The language stops bundling editor forms** (your decision). `#lang :tuna/config` and `#lang :tuna/prelude` give Gerbil, `defplugin` and `use-plugin`; files import `defcommand`, `keymap-set` and `defsetting` from the commands, keys and settings contracts. Code you evaluate later (`M-:`, `eval-buffer`) sees what your `init.ss` imported.
3. **Clicks:** the keys plugin no longer asks the layout plugin which node a click landed on. The layout plugin registers that lookup through the keys contract when it turns on, and removes it when it turns off. Without a layout plugin, clicks behave as they do today without one.
4. **Session saving:** start-up code stops calling the session contract. The configuration contract offers three moments a plugin can join (after start-up, around a swap or restart, before shutdown), and the session plugin joins them. Saving, restoring and rolling back work as they do today.
5. **The start-up summary in the echo area,** which names the `show-config-report` command, moves into the reload-config plugin (the plugin that defines that command). Tuna keeps the terminal report and the log file.
6. **The configuration contract moves into Tuna** (`tuna/configuration.ss`): it is the one contract whose provider is Tuna's own start-up code.

## How it gets built

1. **Untangle,** the six changes above, with no files moved; `make test` green.
2. **Move,** in one change: each concept to `plugins/<concept>/` with its `gerbil.pkg`, contract, plugin, private files, tests and test doubles; one root `build.ss` building every package into one `.gerbil/` (one `make` call per package); `starter/`, `demo/` and every import updated (no compatibility names). Package names are concept names: `text-store` (default: the rope), `renderer` (default: HTML), `help`, `completion` (default: the engine). The full file-by-file map is in the research.
3. **Check:** the boundary test enforces packages: Tuna imports no package; a plugin imports Tuna, contracts and its own files only; no two packages import each other.

## Decisions

**Decided by you (2026-10-14):**
- `init.ss` and plugin files import the forms they use; no editor-language package.
- **Plugin names drop the word "plugin"**: `(use-plugin buffers)`, not `(use-plugin buffers-plugin)`; likewise `keys`, `layout`, `rope-text-store`, `html-renderer`, `web-transport`. Done in the move step, every caller updated. Where a bare name would clash with a name its own contract exports, the implementer reports it and we pick another.

**Decided by the evidence (tell me if you disagree):**
- **The starter configuration stays inside Tuna as a file `tuna init` copies.** It names our plugins, but only as text you copy and own; Tuna's code never imports or turns on a plugin.
- **Completion's pieces stay separate packages.** The completion package owns candidates, matching styles and the list UI slot, and ships the engine; the vertical list, Orderless, annotations and `M-x` are their own packages, like anyone's would be.
- **One repository and one `make`, for now.** Gerbil can build many packages in one go; separate repositories come when a package needs one.

## New terms

- **Package:** a directory with a `gerbil.pkg` file; Gerbil names and builds its modules together.
- **Concept package:** a package that owns one concept: its `contract.ss` and its default `plugin.ss`.
