# Brief: HTML and stylesheets

**Date:** 2026-10-16. **Status:** proposed. Research: [`agents/research/presentation/`](../../agents/research/presentation/) (design systems, naming, audit of today's CSS, mobile). Changes [ADR 7](../../agents/adr/0007-rendering-and-transport.md).

## What we're building and why

**Tuna is a hypermedia application** (owner decision, 2026-10-16). HTML is the only presentation language: plugins render their nodes to HTML, and the browser draws them. Buffers stay trees of nodes with text and positions; HTML is how they are shown, never how they are stored.

**CSS stays CSS.** Gerbil does not define colours, tokens or styles. It only decides which stylesheets are on the page, in what order, and lets anyone replace any of them.

Today one 368-line `tuna.css`, owned by the web transport, styles every plugin. Turning a plugin off leaves its styles behind, a new plugin cannot add any, and nobody can restyle one plugin without editing that file. This brief fixes that:

- **Each plugin ships its own stylesheets**, usually two: a **semantic tokens** file naming what its parts mean (`--completion-selected-background: var(--primary-3)`), and a **rules** file styling its HTML with those names.
- **A `design-tokens` plugin ships the raw scale**: pregenerated Stellar files (palettes, fluid sizes, fonts, radii, shadows, motion). An option picks which file.
- **Anyone can replace any stylesheet**: a theme plugin, or you in `init.ss`. Swap the design tokens for Open Props and replace each plugin's small semantic tokens file; the rules files stay as they are.

## The picture

![Where completion's CSS comes from](../diagrams/stylesheets-completion.svg)

**Status:** planned. Today the web transport's single `tuna.css` styles everything.

## A walkthrough: restyling the selected completion row

1. Tuna starts. The web page links the `design-tokens` plugin's Stellar file, then each active plugin's stylesheets in `init.ss` order.
2. The completion plugin's `tokens` stylesheet says `--completion-selected-background: var(--primary-3)`. Its `rules` stylesheet colours the selected row with `--completion-selected-background`.
3. You want the selected row in your accent colour. In `init.ss` you replace completion's `tokens` stylesheet with your own file, which points the same name at another colour.
4. You run `reload-config`. Tuna swaps one `<link>` on the page; the browser fetches only that file. Nothing else changes.
5. Later you switch the design tokens to Open Props. `M-x describe-stylesheets` warns that `buffers/tokens` uses `--primary-6`, which no loaded stylesheet defines. You replace that file too.

## What a package author writes

The names are provisional.

```scheme
;; plugins/completion-vertical/plugin.ss: the files sit next to the module.
(defplugin (completion-vertical ctx) "…"
  (context-add-stylesheet! ctx 'tokens (stylesheet "tokens.css"))
  (context-add-stylesheet! ctx 'rules  (stylesheet "rules.css"))
  …)

;; a theme plugin: replaces other plugins' stylesheets by plugin and name.
(defplugin (theme-terminal ctx) "A flat, monospace look."
  (context-replace-stylesheet! ctx 'design-tokens 'tokens (stylesheet "tokens.css"))
  (context-replace-stylesheet! ctx 'completion-vertical 'rules (stylesheet "completion.css"))
  (context-replace-stylesheet! ctx 'layout 'rules (stylesheet "layout.css")))
```

```scheme
;; init.ss
(use-plugin design-tokens file: "stellar-default")
(use-plugin theme-terminal)
(replace-stylesheet 'completion-vertical 'tokens (stylesheet "my-completion-tokens.css"))
(add-stylesheet 'mine (stylesheet "user.css"))       ; extra CSS, last on the page
```

## The rules

- **A stylesheet is identified by its owner and a name**: `completion-vertical/tokens`. Names are symbols the plugin chooses, so renaming a file does not break the themes that replace it.
- **`(stylesheet "file.css")` reads the file next to the code that names it.** In a plugin it is read when the plugin is compiled, so installed plugins carry their CSS; editing a plugin's CSS needs a rebuild. In `init.ss` it is read when the configuration loads, so `reload-config` picks up your edits.
- **Replacing beats adding; among replacements, the latest in `init.ss` wins**, so your `init.ss` beats every theme. Replacing with `#f` removes a stylesheet. Turning a theme off restores what it replaced.
- **Page order:** the design tokens first, then each plugin's stylesheets in `init.ss` order and registration order, then stylesheets you add. A replacement takes the place of what it replaces. There are no cascade layers yet; plugins keep specificity low (`:where()`), so later files win.
- **Naming convention:** a plugin's semantic tokens are prefixed with its name (`--completion-…`, `--buffers-…`), so nothing collides with a design system or another plugin.
- **Checks, reported by `reload-config` and `M-x describe-stylesheets`, never fatal:** a replacement whose target the active plugin does not register; a `var(--x)` without a fallback that no loaded stylesheet defines. The second is a text scan, not a CSS parser.
- **Delivery:** each stylesheet is served at `/css/<owner>/<name>?v=<hash of its text>`, cacheable forever. The page's `<head>` holds one `<link>` per stylesheet, with a stable id; when the set changes, the server patches only the links that changed. A redraw never touches CSS. A plugin turned on over a slow connection may show its HTML unstyled for a moment.
- **Where it lives:** a small `stylesheets` contract and plugin hold the registrations and the checks; the web transport serves and links them. The kernel knows nothing about CSS.
- **Mobile:** the split of `tuna.css` also fixes what the audit found: dynamic viewport units instead of `100vh`, touch-sized targets, safe areas. Narrow-screen layout belongs to the layout-facts research.

## Decisions for you

1. **Which Stellar files ship at first.** *Recommended:* one, `stellar-default`, generated from your current `stellar.config.json` without named colours, charts, gradients, decorative borders or font downloads (about 61 KB unminified, light and dark automatic). Add others (a high-contrast one, a forced-dark one) when you want them.
2. **Cascade layers.** *Recommended:* none for now; file order and low specificity are enough while each plugin styles only its own classes. Wrapping each plugin's CSS in its own `@layer` can come later without changing any API.

## New terms

- **Stylesheet:** a CSS file on the page, owned by a plugin (or by your `init.ss`) and named, such as `completion-vertical/rules`.
- **Design tokens:** the raw scale (palette steps, sizes, fonts), from the `design-tokens` plugin.
- **Semantic tokens:** a plugin's own CSS custom properties naming what its parts mean, defined with design tokens.
- **Theme:** a plugin that replaces other plugins' stylesheets.
