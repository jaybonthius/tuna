# Plan: HTML and stylesheets

Brief: [`docs/briefs/2026-10-stylesheets.md`](../../docs/briefs/2026-10-stylesheets.md) (proposed 2026-10-16). Evidence: [`agents/research/presentation/`](../research/presentation/).

## Invariants

- The kernel gains nothing. Registrations go through contexts; turning a plugin off removes its stylesheets and restores what it replaced.
- No colours, tokens or styles in Gerbil. Gerbil holds stylesheet identities, sources and order only.
- Plugins import only contracts; a theme names other plugins' stylesheets by symbol, never by importing their modules.
- `make test` green under the memory cap after each stage; the last stage is checked in a real browser, on a phone-sized viewport too.

## Stages

1. **HTML is the presentation language.** Amend ADR 7. Remove the per-target argument of node renderers (`'html`) and the plain-text test renderer; the renderer contract says it returns HTML.
2. **The `stylesheets` contract and plugin.**
   - `(stylesheet "file.css")`: a macro reading the file next to the source that names it; at compile time in plugins, at configuration load in `init.ss`.
   - `context-add-stylesheet!`, `context-replace-stylesheet!` (with `#f` to remove), and the `init.ss` forms `add-stylesheet` and `replace-stylesheet`, which run as the `init` plugin's code.
   - One winner per `(owner name)` slot, through owner-tagged entry tables: replacements outrank the owner's own sheet; later in `init.ss` wins.
   - Page order as the brief states. Checks: missing replacement targets; undefined `var(--x)` without a fallback. `M-x describe-stylesheets`; the same warnings in the reload report.
   - Tests: add, replace, remove, restore on theme deactivation, order, both checks.
3. **Delivery in the web transport.** Serve `/css/<owner>/<name>?v=<hash>` with an immutable cache header; link each in `<head>` with a stable id; on a change, patch only changed links. Verify against Datastar's head morph (`agents/research/presentation/audit-and-mobile.md`, part c) that scripts in `<head>` are untouched.
4. **The `design-tokens` plugin.** The Stellar core output generated from the owner's `stellar.config.json` (no named colours, charts, gradients, decorative borders or font imports); a `file:` option; the config and a `make tokens` target for regenerating with the owner's binary (not part of the normal build).
5. **Split `tuna.css`.** Each plugin gets `tokens.css` (semantic tokens, prefixed with its name, defined with Stellar tokens) and `rules.css`, following the audit's ownership table. Delete `plugins/web/web/tuna.css`. Fix the mobile items: dynamic viewport units, touch targets, safe areas.
6. **Proof and records.** A small theme in the demo (`theme-terminal`: flat, monospace) replacing a few stylesheets; an `init.ss` replacement in a test; a browser check, desktop and phone width. Update the overview, the Emacs-equivalents table (faces and themes) and the HTML/CSS guide.

## Not in this plan

Cascade layers; restoring a plugin's own stylesheet from `init.ss` while a theme replaces it; scoping mixed token systems; layout facts and narrow-screen layout (separate research); a settings screen for tokens.
