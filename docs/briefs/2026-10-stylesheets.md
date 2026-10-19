# Brief: HTML and stylesheets

**Date:** 2026-10-16. **Status:** built 2026-10-17 (see [how Tuna works](../overview.md#how-it-looks-html-and-stylesheets)); approved 2026-10-16 (owner: ship Stellar's default output, core sections only; committing it is fine); revised after an independent review (`/home/jay/Code/workbench-gerbil/scratch/stylesheets-review/review.md`). Research: [`agents/research/presentation/`](../../agents/research/presentation/) (design systems, naming, audit of today's CSS, mobile). Changes [ADR 7](../../agents/adr/0007-rendering-and-transport.md).

## What we're building and why

**Tuna is a hypermedia application** (owner decision, 2026-10-16). HTML is the only presentation language: plugins render their nodes to HTML, and the browser draws them. Buffers stay trees of nodes with text and positions; HTML is how they are shown, never how they are stored.

**CSS stays CSS.** Gerbil does not define colours, tokens or styles. It only knows which CSS files are on the page, in what order, and lets anyone replace any of them.

Today one 368-line `tuna.css`, owned by the web transport, styles every plugin. Turning a plugin off leaves its styles behind, a new plugin cannot add any, and nobody can restyle one plugin without editing that file. This brief fixes that:

- **Each plugin ships its own CSS files**, usually two: **semantic tokens** naming what its parts mean (`--completion-selected-background: var(--primary-3, Highlight)`), and **rules** styling its HTML with those names.
- **A `design-tokens` plugin ships the raw scale**: pregenerated Stellar files (palettes, fluid sizes, fonts, radii, shadows, motion). An option picks one.
- **Anyone can add CSS or replace any file**: a theme plugin, or you in `init.ss`. Swapping Stellar for Open Props means replacing the design tokens file and the plugins' small semantic-tokens files; the rules files stay.

## The picture

![Where completion's CSS comes from](../diagrams/stylesheets-completion.svg)

**Status:** built 2026-10-17. When this brief was written, the web transport's single `tuna.css` styled everything.

## A walkthrough: changing the selected completion row's colour

1. Tuna starts. The page's `<head>` links every registered stylesheet, in `init.ss` order: `design-tokens` first because the starter `init.ss` declares it first, then each plugin's files, then yours.
2. The completion plugin's `tokens` file says `--completion-selected-background: var(--primary-3, Highlight)`. Its `rules` file colours the selected row with that name.
3. You want your accent colour. You add a stylesheet in `init.ss` that sets `--completion-selected-background` to it. Yours comes last, so it wins, and any token the plugin adds later still has its default.
4. You edit your CSS file and run `M-x reload-stylesheets`. Tuna reads the registered files again; the browser fetches only the one that changed.
5. Later you swap the design tokens for Open Props. `M-x describe-stylesheets` lists every `var(--x)` without a fallback that nothing defines, so you know what to map.

## What a package author writes

The names are provisional.

```scheme
;; A plugin: the files sit next to plugin.ss.
(defplugin (completion-vertical ctx) "…"
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules  "rules.css")
  …)

;; A theme: replaces other plugins' files, by plugin name and stylesheet name.
(defplugin (theme-terminal ctx) "A flat, monospace look."
  (replace-stylesheet 'design-tokens 'tokens "tokens.css")
  (replace-stylesheet 'completion-vertical 'rules "completion.css")
  (replace-stylesheet 'layout 'rules "layout.css"))
```

```scheme
;; init.ss
(use-plugin design-tokens variant: stellar-default)
(use-plugin theme-terminal)
(replace-stylesheet 'buffers 'rules "my-buffers.css")   ; a whole file
(add-stylesheet 'mine "user.css")                       ; overrides, last on the page
```

## The rules

**API.** Two forms, the same in plugins, themes and `init.ss`: `add-stylesheet` and `replace-stylesheet`. Replacing with `#f` removes a file. Like `defcommand` and `keymap-set`, they register through the current plugin's context, so turning the plugin off undoes them; an optional leading context argument covers callbacks.

**Files.** A literal path resolves relative to the file containing the form; for code evaluated interactively, relative to `init.ss`. The text is read when the stylesheet is registered, and again by `M-x reload-stylesheets`. No rebuild or restart is needed to edit CSS. A missing file is a warning, never an error, so a typo cannot turn off your whole `init.ss`.

**Identity and precedence.** A stylesheet is named by its owner and a symbol, `(completion-vertical rules)`, so renaming a file breaks no theme. Replacements beat the owner's own file; among replacements, the latest in `init.ss` wins, so your `init.ss` beats every theme. Turning a theme off restores what it replaced. A replacement for a plugin that is off is simply dormant.

**Order.** By the owner's place in `init.ss`, then by registration within a plugin. Nothing is special about design tokens: custom properties are resolved when values are computed, so a tokens file only needs to come before files that redefine the same names. No cascade layers yet; plugins keep specificity low (`:where()`).

**Conventions.**
- Semantic tokens use the plugin's class prefix (`--completion-…` for the `completion-…` classes) and a fallback to a system colour or plain value, so a design-token swap degrades to readable defaults.
- Plugins use only a documented subset of design tokens (a few palettes, sizes, fonts, radii, shadows), so moving to another design system means mapping that subset in one file.
- To change a few tokens, add a sheet that redefines them. Replace a file when you rewrite it.

**Checks.** `M-x describe-stylesheets` lists every stylesheet in order, with its owner, file and any replacement, and two warnings: a replacement whose active target does not register that name, and a `var(--x)` without a fallback that no loaded stylesheet defines (a text scan that skips comments and fallbacks, not a CSS parser). A failing check also shows one line in the echo area.

**Fonts and images.** A stylesheet's `url(fonts/x.woff2)` resolves against its own directory, which Tuna serves beside it; paths outside that directory are refused.

**Delivery.** Each stylesheet is served at `/css/<n>/<hash>/<file>`, cacheable forever, with `text/css`; a stale hash gets 404. The `<head>`'s links are rendered from the current registrations by the same code as the first page, and sent as one morph whenever they change, always before the screen, including when a stream reconnects. That keeps the immediate-mode rule: the server never patches individual links, and stable ids still mean the browser re-fetches only changed files.

**Where it lives.** A `stylesheets` contract holds the registry, one per editor, registered through contexts like hooks. It has no service, so plugins that style themselves declare nothing new and no activation cycle can arise. A small `stylesheets-help` plugin provides `describe-stylesheets` and `reload-stylesheets`. The web transport serves the files and renders the links. The kernel knows nothing about CSS.

**Mobile.** Splitting `tuna.css` also fixes what the audit found: dynamic viewport units instead of `100vh`, touch-sized targets, safe areas. Narrow-screen layout belongs to the layout-facts research.

## Decisions for you

1. **Which Stellar files ship at first.** *Decided:* one, `stellar-default`, generated from Stellar's built-in default config without named colours, charts, gradients, decorative borders or font downloads (about 61 KB unminified; light and dark follow the system). Add others (high contrast, forced dark) when you want them.
2. **Shipping Stellar's output in Tuna's repository.** Users never need the binary; only regenerating does. Is redistributing the generated CSS fine?

## New terms

- **Stylesheet:** a CSS file on the page, owned by a plugin or by your `init.ss`, and named, such as `(completion-vertical rules)`.
- **Design tokens:** the raw scale (palette steps, sizes, fonts), from the `design-tokens` plugin.
- **Semantic tokens:** a plugin's own CSS custom properties naming what its parts mean, defined with design tokens.
- **Theme:** a plugin that replaces other plugins' stylesheets.
