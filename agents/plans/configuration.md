# Plan: user configuration

Owner-approved brief: [`docs/briefs/2026-10-configuration.md`](../../docs/briefs/2026-10-configuration.md) (decided 2026-10-12). Evidence: [`agents/research/configuration/`](../research/configuration/). Owner rules: no standard setup, no magic (Tuna never creates or edits the user's config on its own), no stored history, kernel unchanged.

## Invariants (every stage)

- **Loading `init.ss` has no effect on the running editor.** Loading only produces a value: the declared plugins (with options and `config:` blocks) plus the user's own code as one more plugin. Every effect happens when those plugins are turned on, so receipts undo it. This is what makes the "trial run" a load, not a staging kernel. Prefer a configuration language (`#lang :tuna/config` or a macro) whose body becomes plugin activation code; a staging kernel instance needs a new kernel export and is the fallback, justified in an ADR 12 amendment only if the first approach cannot work.
- **Each load of `init.ss` gets a fresh module namespace in memory** (research 01, finding 8), so the version currently running stays loaded and can be turned back on. Nothing is written to disk except the start-up report log.
- **Loading runs on a worker thread with a timeout** and is always a reload (`import-module path #t #t`), so an endless loop or a failed load never leaves a stuck module (research 01, findings 6-7).
- **Failure isolation:** a plugin, or a `config:` block, that fails to turn on is undone and recorded; plugins that need it are recorded as skipped; everything else proceeds.
- **Placement:** finding and reading the file and boot activation live in `tuna/main.ss` (outside the kernel); reload/check commands live in an ordinary configuration plugin. Any kernel export added or restored (for example a plugin's `requires` for the "skipped: needs X" report) is justified in the merge report; no new kernel feature.
- `make test` stays green with the boundary checks unchanged; each stage is checked in a real browser in an isolated run.

## Stages

1. **Start from `init.ss`.** Link the Gerbil expander into the `tuna` executable. `main` finds the config (`--config PATH`, then `TUNA_CONFIG`, then `$XDG_CONFIG_HOME/tuna/init.ss`); with none, it turns nothing on, says how to get one, and keeps running. `use-plugin` (no options yet) plus `config:` blocks plus top-level user code, per the invariants. Boot activates declared plugins with isolation, then the user-code plugin. Start-up report to stderr and to a log file in the state directory replaced each start. A starter `init.ss` in the repository reproducing today's hard-coded set; `tuna init` copies it to the default path only when run (refuses to overwrite). Delete the hard-coded list. `tuna check` (load + validate without turning anything on) if cheap here, else stage 2.
2. **Reload.** `reload-config` command in a configuration plugin and `tuna reload` from a terminal (a control channel; pick the simplest robust mechanism: signal or local socket, justified). Reload = load new version (trial), diff declarations against what is running, turn off/on only the differences; a failed new plugin or block is undone and the running version turned back on; the user-code plugin likewise. Changing a startup-tier provider is reported as "takes effect at next start". `tuna check` if not done in stage 1.
3. **Options and the report inside Tuna.** `use-plugin` options validated against a schema each plugin declares (all problems collected with their lines, research 02 rec. 7), passed to the plugin at activation. Show the start-up/reload report inside Tuna when something can display messages, plus a command to show it again.

Later, each with its own plan: bisect (in memory), reloading plugin code itself, package installation. The STATUS item "demo out of default startup" becomes a one-line choice in the starter `init.ss`.
