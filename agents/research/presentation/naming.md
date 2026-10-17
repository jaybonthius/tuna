# Naming the presentation layers (prior art survey)

Date: 2026-10-16. Read-only research. Evidence labels: **[fact]** = seen in a source; **[rationale]** = the source's stated reason; **[inference]** = mine.
Verification: I fetched the W3C Design Tokens draft (section titles "Design token", "Group", "Type", "Alias (Reference)", "Composite (Design) Token", https://www.designtokens.org/tr/drafts/format/). The Material and Primer pages are client-rendered, so their term usage below is from my memory of the docs, not re-fetched; treat as medium confidence. No other system was re-fetched this run.

## 1. Survey of terms

### Raw values
| Term | Who | Meaning | Newcomer clarity |
|---|---|---|---|
| **design token** | W3C DTCG draft; Material, Primer, Spectrum, Radix (Themes) | A named value. DTCG: "name and value" pair, optionally typed, grouped, aliased. | Web devs: yes (widely known). Emacs users: no, but guessable. |
| **primitive / base / global / reference token** | DTCG community usage, Primer ("base"), Material ("reference"), Spectrum ("global") | Tier 1: raw palette/size values with no meaning (`blue-500`). Four names for one tier. | "primitive" clearest; "reference" is confusing (also means "alias" in DTCG). |
| **scale / palette** | Radix colours ("12-step scale"), Open Props ("--blue-5") | Ordered ramp of values. | Very clear. |
| **design system** | everyone | Whole body of tokens, components, guidelines. | Clear to web devs; heavier than "stylesheet of raw values" [inference]. |
| custom property | CSS (css-variables-1, https://www.w3.org/TR/css-variables-1/) | The mechanism (`--x`), not a concept. | Clear mechanism word, poor concept word. |

### Named semantic styles (applied to UI and text)
| Term | Who | Meaning | Clarity |
|---|---|---|---|
| **face** | Emacs (Elisp manual, "Faces"; `defface`, `set-face-attribute`) | Named bundle of text attributes (foreground, background, weight, slant, underline, box, inherit). Also the typeface sense. | Emacs users: yes. Web devs: no ("face" = typeface). Owner already finds it weird. |
| **highlight group** | Vim `:help highlight-groups`; Neovim `:help highlight` | Named set of attributes (`guifg`, `bold`); `link` makes one group inherit another (`hi link`); Neovim `nvim_set_hl`. | Moderate; "group" is vague, and "highlight" suggests only text marking. |
| **semantic token (type)** / TextMate **scope** | VS Code | Semantic tokens: language-server token types (`variable.readonly`) mapped to colours; TextMate scopes: dotted names (`keyword.control`) matched by selectors. | Specific to code highlighting. |
| **theme colour / colour ID** | VS Code `workbench.colorCustomizations` (e.g. `editor.background`, `statusBar.foreground`) | Dotted per-element colour keys, one value each. Component-scoped, not semantic roles. | Clear for VS Code users only. |
| **attribute key** | JetBrains `TextAttributesKey` (`DefaultLanguageHighlighterColors.KEYWORD`) | Named key resolving to attributes in a colour scheme; has a fallback key. | Opaque outside JetBrains. |
| **semantic token (design)** / **alias token** / **functional token** / **system token** | Spectrum "alias", Primer "functional", Material "system", DTCG community "semantic" | Tier 2: meaning-bearing name (`color-danger`, `fgColor-muted`) pointing at a primitive. | "semantic token" widest recognition [inference: web devs meet it in all four systems' guidance]. |
| **colour role** | Material 3 (`primary`, `on-primary`, `surface`, `error`) | Named role in a scheme; the `on-*` pairing convention gives text-on-surface. | Clear, but colour-only. |
| **style** | CSS/Word/Figma ("text style", "style") | Named bundle. | Universally understood; vague. |
| **system colour** | CSS Color 4 (`Canvas`, `Highlight`, `CanvasText`; https://www.w3.org/TR/css-color-4/#css-system-colors) | UA-defined colour keywords that follow the OS/user theme. | Web devs mostly know them as a curiosity. |

### Themes
"theme" is near-universal: Emacs `deftheme`/`load-theme`/`custom-theme-set-faces`; Vim/Neovim call them "colorschemes" (`:colorscheme`); VS Code "colour theme"; Zed/Helix "theme" (TOML/JSON mapping names to values); JetBrains "colour scheme" (+ separate UI "theme"); Material "theme"; Radix `<Theme>`. [fact] Modus themes (https://protesilaos.com/emacs/modus-themes) go further: a **palette** of named raw colours (`blue-warmer`, `bg-main`) plus a **palette mapping** layer (`fg-link`, `bg-active`, `border`) that faces then consume. [rationale, from its manual] The mapping lets users override meaning without touching faces: `modus-themes-common-palette-overrides`. So Modus is a three-tier system: palette → mappings → faces.

### Component styles
Material "component tokens"; Primer "component/ component-specific tokens"; Spectrum "component tokens"; DTCG community "component tokens"; VS Code encodes component in the key prefix (`statusBar.*`); Radix uses CSS classes with token variables. [fact/memory] "component token" is the shared term, but Tuna's plugin CSS is not tokens at all; it is CSS rules, so the right term is the stylesheet, not a token tier. [inference]

### User overrides
Emacs: `M-x customize-face`, `custom-set-faces` in init.el ("customization"). VS Code: `workbench.colorCustomizations`, `editor.tokenColorCustomizations` ("customizations"). Neovim: `:highlight` / `nvim_set_hl` after `:colorscheme`, or a `ColorScheme` autocmd. Modus: `*-overrides` variables. Primer/Material: "overrides"/"customization". [fact/memory] Both words, "customization" and "override", are widespread; "override" matches CSS cascade vocabulary.

## 2. Observations that shape the choice
- [fact] Every web design system has the same three tiers (raw → meaning → component) under ~4 names each; the *meaning* tier name varies most (alias/semantic/functional/system). The W3C draft uses "alias" for the *mechanism* (a token whose value is another token), not for the tier. So "alias" should not name the tier.
- [fact] Emacs's face is both the named style and its attribute set; Vim's `link`/Emacs's `:inherit` both give "this style defaults to that one", which Tuna needs for defaults.
- [inference] Tuna's semantic style is *not* only colour (weight, slant, underline, size appear too), so Material's "colour role" is too narrow, and VS Code's colour IDs (per element) are the wrong granularity: Tuna wants meaning ("error", "link", "region") consumed by many plugins.
- [inference] Audience is web developers first and Emacs users second; the web term should win unless it is ambiguous, and Emacs lineage can be recorded in docs/emacs-equivalents.md as the owner's rule requires.

## 3. Recommendations for Tuna

| Concept | Recommend | Runner-up | Why |
|---|---|---|---|
| Optional raw-value stylesheet | **design system** (owner's term; docs: "the design system stylesheet") | "palette" (too colour-only) | Matches owner's words and web usage. It is a stylesheet of design tokens. |
| Raw value inside it | **design token** (when speaking of the tier: "primitive token") | "primitive" alone | DTCG/Open Props/Primer all say token. Never call Tuna's semantic styles "tokens" in docs, to keep the two tiers distinct [inference]. |
| Semantic style ("face") | **semantic style** (form: `style`) | **role** | See decision below. |

Decision on the semantic style, stated plainly: use **"semantic style"** in prose and **`style`** as the Gerbil form name (`define-style`), with `style` always read in the Tuna sense and CSS stylesheets called "stylesheets". Runner-up: **"role"** (Material colour roles, Primer "roles"; clear but implies colour only and is a very overloaded word in software). Rejected: **face** (typeface ambiguity, owner dislikes; keep in emacs-equivalents.md), **highlight group** (wrong scope: not only highlighting), **token** (collides with design tokens and editor/lexer tokens, which Tuna will have for syntax highlighting [inference]), **alias** (DTCG mechanism). Risk: "style" collides with the HTML `style` attribute and CSS "style"; mitigate by always writing `semantic style` in docs and `define-semantic-style`/`style` only inside a plugin that has no inline styles (Tuna renders classes, not inline styles [inference]). If the owner judges that collision too heavy, take "role".

| Concept | Recommend | Runner-up | Why |
|---|---|---|---|
| Properties of a semantic style | **properties**, named by CSS: `color`, `background-color`, `font-weight`, `font-style`, `text-decoration`. | "attributes" (Emacs/JetBrains) | Value is "any CSS expression", so the names should be the CSS property names verbatim: zero translation table, devs already know them, and new CSS works without a Tuna change. Emacs users learn a 5-row mapping (foreground→color, background→background-color, weight→font-weight, slant→font-style, underline→text-decoration), which goes in emacs-equivalents.md. Emacs `:inherit` becomes a plain reference to another style's value (`var(--…)`), not a new attribute. |
| Theme | **theme** | "colour scheme" (Vim/JetBrains; colour-only) | Universal, Emacs-compatible. |
| Plugin stylesheet | **plugin stylesheet** (CSS for its own HTML) | "component styles" | Honest: it is a stylesheet, not tokens. Lives in a cascade layer named for the plugin. |
| User stylesheet | **user stylesheet** | "custom CSS" | Established term (user style sheet in CSS cascade spec, CSS Cascade 5 "user origin"); here deliberately author-origin but last; the doc should say so. |
| User customisation of a semantic style | **override** (`override-style` / `(style-override error color: "…")` in init.ss) | "customize" (Emacs, but Emacs's `customize` is a UI) | Matches the CSS cascade verb; works for themes too ("the user's overrides win over the theme"). |
| Generated stylesheet | **generated stylesheet**, file name `generated.css` | "base stylesheet", "layer-and-values stylesheet" | Says exactly what it is. Avoid "theme CSS": it also holds layer order and non-theme defaults. |

### Custom property spelling
Between the owner's two examples (`--face-error-foreground`, `--error-color`), recommend neither verbatim:
- A bare `--<name>-<css-property>` is ambiguous with design tokens (`--blue-5` Open Props, `--size-3`). Therefore use a fixed prefix for Tuna's own tier: **`--tuna-<style>-<property>`**, e.g. `--tuna-error-color`, `--tuna-region-background-color`, `--tuna-link-text-decoration`.
  Reasons: (1) custom properties share one global namespace with whatever design system is loaded (Open Props occupies `--blue-*`, `--size-*`, `--shadow-*`), so a prefix prevents collisions [inference]; (2) the property suffix is literally the CSS property, matching the property-name recommendation; (3) the style name is the middle, so the full variable is predictable from `(define-style error …)`; (4) it distinguishes tiers by prefix in devtools: unprefixed = design system, `--tuna-*` = semantic styles. Primer (`--fgColor-danger`, `--bgColor-muted`) and Material (`--md-sys-color-error`) also prefix their semantic tier ([fact/memory]).
- Runner-up: **`--style-<name>-<property>`** if "style" is chosen and the owner wants the word visible; shorter prefix not needed. Rejected: `--face-*` (term rejected), `--error-color` (collides with design-system or user variables; no tier signal; `color` name suggests colour only).
- Plugin-private values: `--tuna-<plugin>-<thing>` is allowed only if truly not a semantic style; prefer none.
- Names of styles: dotted/hyphenated, role-first, plugin-agnostic (`error`, `warning`, `link`, `region`, `muted`, `mode-line`); the plugin that defines one owns its name, qualified by plugin when not shared [inference].

### One-sentence glossary for docs
- **Design token**: one named raw value in the optional design system stylesheet (`--blue-5`).
- **Semantic style**: a named meaning ("error", "region") with CSS properties; each is published as `--tuna-<name>-<property>` custom properties.
- **Theme**: a plugin that sets semantic style values (and may ship a design system).
- **Plugin stylesheet**: CSS a plugin ships for its HTML, using only semantic styles and design tokens.
- **User stylesheet**: the CSS from init.ss, applied last.
- **Override**: a user's replacement value for one semantic-style property.
- **Generated stylesheet**: Tuna's small file with layer order and all current semantic-style values.

## Residual uncertainty
- Primer, Material, Spectrum, Zed, Helix, JetBrains, Neovim, VS Code term usage is from memory; the exact tier names should be re-checked before they are quoted in an ADR.
- Whether "style" is too overloaded is a judgment call; "role" is the fallback. No user testing exists.
