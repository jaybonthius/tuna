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
- **M-x is a plugin** (`execute-extended-command`), a command over the commands contract with category `command` and history `extended-command`. Vertico-, Orderless- and Marginalia-like plugins are ordinary plugins; turning any of them off leaves M-x working with less.
- **Rendering** follows ADR 7 and ADR 13: candidate rows are nodes in the prompt's buffer, rebuilt from the session, clickable through node keymaps.

## Consequences

- No completion plugin needs advice; the session gives Embark- and Consult-like plugins a supported place to read and act.
- Emacs code that builds string tables or reads text properties of candidates changes when ported.
- The kernel is unchanged.

## Alternatives considered

- **Strings with properties (Emacs).** Rejected: hidden data and disambiguation tricks for every source.
- **Advice-based plugins mirroring the packages.** Rejected: the owner wants proper extension points, and advice hides who changes what.
- **Filtering as jobs from the start.** Deferred: the list could arrive a redraw after the keystroke; the pure pipeline keeps it a later switch.
