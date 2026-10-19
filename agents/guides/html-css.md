# HTML and CSS guidelines

Apply this to Tuna's renderers and browser assets. Tuna's declarative enhancement
layer is Datastar; see [ADR 7](../adr/0007-rendering-and-transport.md).

Build with the web platform first:

1. Semantic HTML
2. CSS
3. The repository's declarative enhancement layer
4. Handwritten JavaScript only as a justified exception

## HTML

- Choose elements for meaning, not default appearance. Use landmarks, headings,
  sections, articles, lists, tables, and form elements when appropriate.
- Use `<a>` for navigation and `<button>` for actions. Do not make generic
  elements clickable substitutes for native controls.
- Prefer native forms, validation, `<details>`, and `<dialog>` over custom
  widgets.
- Give every form control an accessible label. Use `<fieldset>` and `<legend>`
  for related controls and connect help and error text when needed.
- Keep document and heading order logical. CSS must not repair incoherent source
  order visually.
- Use concise, meaningful link and button text.
- Use ARIA only when native HTML cannot express the required semantics or state,
  and keep dynamic ARIA state synchronized.
- Reuse the repository's established template/component functions. Give live
  fragments stable IDs only when the enhancement mechanism needs a target; do
  not use IDs as ordinary CSS hooks.

## CSS

- Never edit generated stylesheets or design tokens. Discover source files and
  generation commands from repository configuration.
- Follow repository-local asset ownership and stylesheet ordering.
- Name classes after domain roles or components, not visual appearance.
- Keep specificity low. Prefer short type and class selectors and `:where()` for
  zero-specificity defaults when useful.
- Avoid styling with IDs, deep descendant chains, inline styles, and
  `!important`; fix the cascade instead.
- Let normal flow solve layout first, then use Grid or Flexbox. Prefer intrinsic
  layouts with `minmax()`, `auto-fit`, and `clamp()` over breakpoint collections.
- Use container queries for component behavior and media queries for viewport or
  user preferences. Prefer logical properties.
- Preserve visible keyboard focus, do not communicate state through color alone,
  and tolerate zoom and larger text.
- Treat hover as enhancement. Essential content and actions must remain
  available to keyboard and touch users.
- Respect `prefers-reduced-motion` for application motion.

## Stylesheets in Tuna

Each plugin styles only the HTML it renders, with CSS files beside its
`plugin.ss`, registered when it turns on (stylesheets contract,
`plugins/stylesheets/contract.ss`):

```scheme
(add-stylesheet 'tokens "tokens.css")
(add-stylesheet 'rules "rules.css")
```

- **`tokens.css`** defines the plugin's semantic tokens on `:root`. A plugin
  with only a few rules may define them at the top of `rules.css` instead.
- **Names** use the plugin's class prefix: `--completion-selected-background`
  for `.completion-…`, `--tab-padding` for `.tab`, `--status-line-…` for
  `.status-line`. One name per meaning; never reuse a token for two roles.
- **Values** are a design token from the documented subset
  ([design-tokens.md](design-tokens.md)) with a fallback: a CSS system colour
  (`Canvas`, `CanvasText`, `Highlight`, `HighlightText`, `GrayText`, `Mark`,
  `ButtonBorder`, `LinkText`) or a plain value:
  `--completion-selected-background: var(--primary-3, Highlight);`.
  Spacing may be a plain value; the fluid Stellar sizes are too coarse for
  editor chrome.
- **`rules.css`** uses only the plugin's own semantic tokens, never a design
  token or a hard-coded colour.
- **Specificity:** wrap selectors in `:where()` so a theme's or `init.ss`'s
  rule wins wherever it sits on the page. Keep real specificity only where a
  rule must beat another plugin's whatever the page order, and say why in a
  comment (the renderer's cursor beats face classes; completion's grid beats
  the minibuffer's flex).
- **Cross-plugin selectors** belong to the plugin that adds the coupling:
  the minibuffer's rules may select `.view` and `.buffer`; completion's may
  select `.minibuffer`. The renderer's classes and attributes (`.screen`,
  `.view`, `.buffer`, `.text`, `.line`, `.cursor`, `.inactive-cursor`,
  `.status-line`, `.face-NAME`, `data-view`, `data-selected`, `data-part`,
  `data-node`, `data-clickable`) are a published styling surface.
- **Test fixtures and doubles** bring their own support stylesheets in their
  `tests/support/` directory; production CSS never styles them.
- **Mobile:** dynamic viewport units (`dvh`), safe-area insets, and touch
  targets of at least 2.75rem under `@media (pointer: coarse)` for clickable
  chrome; hover effects only under `@media (hover: hover)`.
- **Check** with `M-x describe-stylesheets`; `tests/integration/stylesheets-test.ss`
  fails if the starter or demo page has an unreadable file or an undefined
  `var()` without a fallback.

A theme is a plugin that calls `replace-stylesheet` on other plugins'
files; replace a file to rewrite it, and add a later file to change a few
tokens.

## Server-driven enhancement

When a repository uses Datastar, SSE, or another server-driven enhancement
layer:

- enhance semantic HTML rather than replacing it;
- keep authoritative state on the server and treat browser signals as request or
  interaction state;
- prefer server-rendered fragments and broad correct updates before fine-grained
  client DOM management;
- keep morph targets and state-owning shells stable;
- prefer anchors and HTTP redirects for navigation;
- show pending work honestly and render success only after server confirmation;
- avoid optimistic UI unless the product explicitly requires and reconciles it.

## Primary references

- [WHATWG HTML semantics](https://html.spec.whatwg.org/dev/semantics.html)
- [MDN: ARIA and semantic HTML](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA)
- [MDN: CSS specificity](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Cascade/Specificity)
- [MDN: Container queries](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Containment/Container_queries)
- [MDN: Logical properties](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Logical_properties_and_values)
- [MDN: Reduced motion](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@media/prefers-reduced-motion)
