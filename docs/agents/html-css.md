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
