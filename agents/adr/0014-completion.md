# 14. Completion: typed candidates, a session, and slots instead of advice

Status: accepted (2026-10-13). Owner-approved brief: [`docs/briefs/2026-10-completion.md`](../../docs/briefs/2026-10-completion.md). Research: [`agents/research/completion/`](../research/completion/README.md).

## Context

The owner wants M-x with a Vertico, Orderless, Marginalia and Consult experience, each part a separate plugin reusable by every feature that asks the user to choose (file pickers, buffer switching, help). Emacs's core already separates completion tables with metadata, a matching-style registry, history, and a UI slot (`completing-read-function`). The packages reach past it with advice where the core lacks an extension point: Vertico advises `completing-read-default`, Marginalia advises `completion-metadata-get`, and Consult and Embark write per-UI glue because there is no object for the running read. Candidates are strings, so packages hide data in text properties and disambiguate equal strings with invisible characters.

## Decision

- **Typed candidates** (owner decision, a divergence from Emacs): a candidate is a record of the text shown and matched, the value returned, an identity (so the selection survives updates), and optional category and group. Ported string tables go through a one-line adapter.
- **Completion contract** (`tuna/services/completion.ss`): candidates, tables (a required category; items as a list, a procedure of the input, or later an async source; optional sort, group, fallback annotation, preview, narrowing), `completing-read`, and a **session** object for the running read (input, matches, selection, category, origin command) that any plugin may query. Two live-tier slots: the **engine** (`completion-service`) and the **UI** (`completion-ui-service`).
- **Registries in the engine, not advice:** matching styles (a style compiles the input into a matcher returning match spans, highlighted only for shown rows) chosen by a `completion-styles` setting with per-category overrides; annotators by category, consulted for shown rows before the table's own annotation. Entries are owner-tagged, so they go with their plugin.
- **Commands contract** (`tuna/services/commands.ss`), split from keys: command records with documentation and visibility, listing, and `call-command`, which runs a command as if its keys were pressed. The keys plugin keeps bindings and resolution and adds `where-is`.
- **Command-loop hooks:** `pre-command-hook` and `post-command-hook` (ADR 8) are built now, in the keys contract; the engine recomputes from `post-command-hook`, so the list changes in the same redraw as the keystroke. Matching runs inline on the baton as a pure function of plain data, so moving it to jobs later is a switch, not a redesign.
- **History belongs to the minibuffer:** named lists, `M-p`/`M-n`, saved in a session slot.
- **M-x** (`execute-extended-command`) is a command over the commands contract with category `command` and history `extended-command`. ~~It is a plugin; Vertico-, Orderless- and Marginalia-like plugins are ordinary plugins; turning any of them off leaves M-x working with less.~~ *Superseded 2026-10-24 (plugin restructure, roadmap tier 0):* M-x, the any-order matching style (like Orderless) and the command annotator (like Marginalia) are part of the completion plugin (`completion`); the list (like Vertico) is the `completion-list` plugin, and turning it off leaves M-x working with less. Matching styles and annotators remain registries, so other plugins still add their own.
- **Rendering** follows ADR 7 and ADR 13: candidate rows are nodes in the prompt's buffer, rebuilt from the session, clickable through node keymaps.

## Consequences

- No completion plugin needs advice; the session gives Embark- and Consult-like plugins a supported place to read and act.
- Emacs code that builds string tables or reads text properties of candidates changes when ported.
- The kernel is unchanged.

## Alternatives considered

- **Strings with properties (Emacs).** Rejected: hidden data and disambiguation tricks for every source.
- **Advice-based plugins mirroring the packages.** Rejected: the owner wants proper extension points, and advice hides who changes what.
- **Filtering as jobs from the start.** Deferred: the list could arrive a redraw after the keystroke; the pure pipeline keeps it a later switch.

## Amendment (2026-10-13)

The command-loop hooks live in the commands contract, not keys (see ADR 8's amendment); the keys contract no longer re-exports commands. The completion list uses only the session and prompt handle it is given.

## Amendment (2026-10-24, plugin restructure)

A plugin is a feature turned on, off or swapped as a whole (roadmap, tier 0), so the completion package's one plugin holds the engine, M-x, the `substring` and `any-order` styles and the command annotator; `orderless`, `command-annotations` and `extended-command` are gone, and `completion-vertical` is `completion-list`. M-x lives in completion, not commands, because the completion package already imports the commands contract; the reverse would make the two packages import each other. Third-party names are not used: Orderless's style is `any-order`, and the package README credits Orderless, Marginalia and Vertico.
