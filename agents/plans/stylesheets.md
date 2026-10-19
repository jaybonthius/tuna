# Plan: HTML and stylesheets

**Status: done (2026-10-17).** All seven stages are built; reports in `agents/research/presentation/stage-1-3.md`, `stage-4-5.md`, and `/home/jay/Code/workbench-gerbil/scratch/stylesheets/stage-6-7-report.md`.

Brief: [`docs/briefs/2026-10-stylesheets.md`](../../docs/briefs/2026-10-stylesheets.md) (approved 2026-10-16). Evidence: [`agents/research/presentation/`](../research/presentation/) and the design review in `/home/jay/Code/workbench-gerbil/scratch/stylesheets-review/review.md`.

## Invariants

- The kernel gains nothing. Registrations go through contexts; turning a plugin off removes its stylesheets and restores what it replaced.
- No colours, tokens or styles in Gerbil: only stylesheet identities, paths and order.
- The stylesheets contract exports no service, so styled plugins need no new `requires:`.
- Rendering stays immediate mode: the `<head>` links are rendered from state and sent whole, never patched link by link.
- `make test` green under the memory cap after each stage; the last stage is checked in a real browser at desktop and phone widths.

## Stages

1. **HTML is the presentation language.** Amend ADR 7. Remove the per-target argument of node renderers (`'html`) and the plain-text test renderer.
2. **The stylesheets contract.** A per-editor registry of `(owner name)` slots in owner-tagged entry tables: the owner's file at priority 0, replacements at 1, ties by `init.ss` rank, read at use time. `add-stylesheet`, `replace-stylesheet` (`#f` removes), optional leading context. Literal paths resolve against the naming file (`this-source-path`); interactive code against `init.ss`. Text read on registration; missing file is a warning. A change counter. Tests: add, replace, remove, restore, dormant replacement, order after reordering `init.ss`, missing file.
3. **The `stylesheets-help` plugin.** `describe-stylesheets` (order, owners, replacements, both checks) and `reload-stylesheets`; one echo-area line when a check fails. Tests for both checks.
4. **Delivery in the web transport.** `/css/<n>/<hash>/<file>` with a real digest, `immutable`, `text/css`, 404 for stale hashes; assets beside each stylesheet with validators, `..` refused. Head links rendered from the registry and sent as one morph on change and first on each stream open. Browser check that `<head>` scripts are untouched and only changed files are fetched.
5. **The `design-tokens` plugin.** Stellar core output from the owner's config; a `variant:` option accepting only shipped names; the config and a `make tokens` target using the owner's binary, outside the normal build. Document the subset of tokens plugins may use.
6. **Split `tuna.css`.** Each plugin gets `tokens.css` (class-prefixed names with fallbacks, built on the subset) and `rules.css`, per the audit's ownership table. Delete `plugins/web/web/tuna.css`. Mobile fixes: dynamic viewport units, touch targets, safe areas.
7. **Proof and records.** A demo theme (`theme-terminal`: flat, monospace) replacing a few stylesheets; an `init.ss` override in a test; browser check at desktop and phone widths. Update the overview, the Emacs-equivalents table (faces and themes), the HTML/CSS guide, and the starter `init.ss`.

## Not in this plan

Cascade layers; restoring a plugin's own file from `init.ss` while a theme replaces it; scoping mixed token systems; source-less plugin distribution (embedding); layout facts and narrow-screen layout.
