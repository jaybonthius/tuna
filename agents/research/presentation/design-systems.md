# Design systems and CSS mechanisms for Tuna's styling layers

Researched 2026-10-16. Read-only. Labels: **Fact** (seen in a source), **Rationale** (the source's stated reason), **Inference** (mine).
Browser data comes from the web-platform-dx Baseline API (`https://api.webstatus.dev/v1/features/<id>`, queried 2026-10-16), plus MDN and the W3C CSS Cascade 5 spec.

## Answer in brief

- Ship **no design system by default**. Plugins style only against Tuna's own semantic variables, which default to CSS system colours (`Canvas`, `CanvasText`, `Highlight`, ...) and a few literal fluid sizes. Offer **Open Props v1** (MIT, plain CSS) as the first optional theme-plugin design system.
- Every mechanism the design needs is Baseline Widely available today except `light-dark()`, `@property` and `@scope` (all Newly available). Plan around that (table in part B).
- Use `@scope` sparingly. Cascade layers plus low-specificity class selectors already do the isolation job, and `@scope` only reached Baseline in March 2026.

## A. Candidate design systems

| | What it gives | Phones / fluid | Dark mode | Contrast guarantee | Licence | How a Tuna theme plugin ships it |
|---|---|---|---|---|---|---|
| **Open Props v1** (npm `latest` = 1.7.23) | Raw custom properties: 19 palettes x 12 steps (`--gray-0..12`), sizes, fluid sizes and fonts, shadows, easings, radii, z-index, animations. | Yes: `--size-fluid-1..10`, `--font-size-fluid-0..3`. | Not built in. Light/dark aliases (`--surface-1`, `--text-1`) are a *pattern* in its docs, switched with a media query or `.dark`/`.light` switch files. | None stated. | MIT. | Copy `open-props.min.css` or the per-pack files (`sizes.min.css`, `gray.min.css`, `easings.min.css`) into the plugin and register them as a stylesheet. No build step. |
| **Open Props v2** (npm tag `beta` = 2.0.0-beta.4; `beta.5` also tagged; not `latest`) | Adds a dynamic palette: 16 `oklch` variables `--color-1..16` from `--palette-hue`, `--palette-chroma`, `--palette-hue-rotate-by`. Adds `durations` (UX motion durations). | Same fluid props as v1 (inference: unchanged; not re-verified). | Same aliasing pattern; the palette hue is one variable. | None stated. | MIT (repo LICENSE). | Same as v1. Still a beta, so pin it and avoid it as a default (inference). |
| **Stellar** (Shux's tool; `/home/jay/Code/shux/.agents/reference/stellar/stellar.md`) | Generated `stellar.css`, 1,173 custom properties: 12-step theme scales (`--primary-1..12`, `-on`, `-dim` per step), fluid `clamp()` sizes from a 320-1440 px viewport, code-syntax colours, chart colours, shadows, easings. Scales swap automatically in dark mode. | Strong: fluid sizes and fonts throughout. | Yes, built in (scales regenerate under dark mode). | Partial: an `-on` token is meant for text on its exact base step. The doc itself says accents from another palette need independent verification. | **Fact:** the `stellar` binary and `stellar.key` are licensed and git-ignored. Whether the generated CSS may be redistributed is not stated. | Users cannot be assumed to own it. A theme plugin can ship a pre-generated `stellar.css` only if the owner confirms redistribution rights (open question). Never a default. |
| **Utopia** (utopia.fyi) | A calculator that emits `clamp()` custom properties for a fluid type scale (`--step--2..`) and space scale (`--space-s`, one-up pairs). Not a library. | Best-in-class: it is the method itself. | None (no colours). | None (no colours). | Calculator output is plain CSS. Licence terms not checked. | Paste the generated block into the plugin's stylesheet. It is two small ruleset blocks, no tool needed at runtime. |
| **Radix Colors** | 12-step scales per hue with a fixed use per step: 1-2 backgrounds, 3-5 component backgrounds (normal, hover, active), 6-8 borders and focus rings, 9-10 solid fills, 11-12 text. Dark scale for each. | None (colour only). | Yes: matching dark scale for each hue. | **Fact:** text steps are designed to meet target contrast against their background steps, using APCA (a newer contrast measure). | MIT per its repo (not re-verified in this pass). | Ship the CSS files, or copy the values into a theme plugin. Step semantics map naturally to semantic styles. |
| **Material 3 tokens** | A three-tier model: **reference** (`md.ref.*`, concrete values and tonal palettes), **system** (`md.sys.*`, roles such as `primary`, `on-primary`, `surface`, `outline`), **component** (`md.comp.*`, per-widget). Each component token maps to a system token, which maps to a reference value. On the web they are CSS custom properties (`--md-sys-color-primary`). | Not fluid. | Roles swap by scheme. | Role pairs (`primary` / `on-primary`) are built from tonal palettes with defined contrast between tones (rationale; not re-verified). | Material Web is open source (licence not re-checked). | Copy the **model**, not the values: roles in pairs (surface + on-surface). A theme plugin could generate its own set from one seed colour. |
| **DTCG format** | A vendor-neutral JSON token format. The first stable version (2025.10) was announced; Figma, Style Dictionary, Penpot and others adopt it. | n/a | n/a | n/a | W3C Community Group spec. | Optional interchange: a theme plugin could carry a `.tokens.json` and generate CSS. **Inference:** this pulls in build tooling that Tuna's no-build principle does not justify now. |

Sources: Open Props (https://open-props.style/ , https://github.com/argyleink/open-props/blob/main/LICENSE , https://registry.npmjs.org/open-props , https://opv2-beta.netlify.app/color/), Radix (https://www.radix-ui.com/colors , https://www.radix-ui.com/colors/docs/palette-composition/understanding-the-scale), Material (https://m3.material.io/foundations/design-tokens , https://github.com/material-foundation/material-tokens/blob/main/tokens.md , https://material-web.dev/theming/material-theming/), Utopia (https://utopia.fyi/type/calculator/ , https://utopia.fyi/space/calculator/), DTCG (https://www.designtokens.org/).

**Observations that matter to the design**

1. **Fact:** Open Props says components should not reference individual light/dark colours but theme-agnostic aliases (`--surface-1`, `--text-1`) that change with the theme (https://open-props.style/, "Creating adaptive color schemes"). That is exactly Tuna's semantic-style layer. **Inference:** Tuna should own the alias names, and a theme maps Open Props values to them.
2. **Fact:** Open Props, Stellar and Radix all use 12-ish step numeric scales; Material uses named roles in pairs. **Inference:** Semantic styles should be role pairs (a surface and its text colour), so contrast is a property of the pair, not left to each plugin.
3. **Fact:** Open Props v1 is imported by `<link>` or `@import` from CSS files without a build. Its CDN examples use unpkg, so a theme plugin should vendor the files (offline, no third party at runtime).
4. **Fact:** No candidate other than Radix (APCA targets) and, partly, Stellar makes a contrast promise. **Inference:** Contrast for Tuna's defaults must be checked by Tuna's own tests, or inherited from system colours, which the browser keeps legible.

## B. CSS mechanisms: verified support (Baseline API, 2026-10-16)

| Feature | Baseline | Since (all engines) | Notes |
|---|---|---|---|
| Cascade layers `@layer` | Widely (2024-09-14) | Chrome 99, Firefox 97, Safari 15.4 | Safe. |
| `color-scheme`, `prefers-color-scheme`, system colours | Widely | system colours since 2018 | Safe. |
| `forced-colors` media feature | Widely (2025-03-12) | | Safe. |
| `color-mix()`, `oklab`/`oklch` colour spaces | Widely (2025-11-09; the "oklab" feature entry) | Chrome 111, Firefox 113, Safari 15.4 / 16.2 | Safe. |
| Container size queries `@container` | Widely (2025-08-14) | Chrome 105, Firefox 110, Safari 16 | Safe. |
| `light-dark()` | **Newly** (2024-05-13) | Chrome 123, Firefox 120, Safari 17.5 | Reaches Widely about 30 months after, i.e. around Nov 2026 (inference from Baseline's rule). Works only for `<color>` and `<image>` and only when `color-scheme: light dark` is set (MDN). |
| `@property` (registered custom properties) | **Newly** (2024-07-09) | Chrome 85, Firefox 128, Safari 16.4 | |
| Relative colour syntax | Newly (2024-09-16) | | Avoid for core. |
| `@scope` | **Newly** (2026-03-24) | Chrome 143, Firefox 146, Safari 26.4 | Safari 26.4 is very recent; many phones will lack it for a while (inference). |
| Container **style** queries | Newly (2026-05-19) | Chrome 111, Firefox 151, Safari 18 | Same caveat; Firefox 151 is recent. |

Detail:

- **Layer ordering across several `<link>`s.** **Fact (spec):** "The first declared layer gets the lowest priority and the last declared layer gets the highest" (MDN `@layer`); `@layer a, b, c;` fixes the order up front; later rules into an existing layer do not reorder it. Unlayered rules sit in an implicit outer layer that **beats every explicit layer** for normal declarations (Cascade 5, "layer ordering"; MDN). For `!important` the order reverses: earlier layers win and unlayered loses. **Inference:** a small first-in-document `<link>` or `<style>` holding `@layer reset, design-system, theme, plugin, user;` pins the order regardless of how late the other sheets load; layer names then pick the winner, not source order or specificity. A user stylesheet should be **unlayered** to win last without `!important`, or be the last named layer. Do not use `!important` in layers (it inverts).
- **Layer declaration pitfall (inference):** a layer's position is fixed at the first mention anywhere in the document. If a plugin sheet mentions `@layer plugin` before the generated order sheet, the plugin layer is placed early. The generated sheet must therefore come first in `<head>`, or be inline.
- **`light-dark()` fits semantic styles.** `--tuna-surface: light-dark(Canvas, #1b1b1f)` works, and `light-dark(Canvas, Canvas)` is valid because `Canvas` already follows `color-scheme`. **Inference:** the generated sheet can set `color-scheme: light dark` on `:root` and a user or theme can force `light` or `dark` by changing `color-scheme` on `:root`, with no variable rewrite.
- **System colours and forced-colors mode.** **Fact (MDN):** keywords such as `Canvas`, `CanvasText`, `Field`, `FieldText`, `Highlight`, `HighlightText`, `LinkText`, `ButtonFace`, `ButtonBorder`, `GrayText`, `AccentColor`, `SelectedItem` describe user-agent colours. In forced-colors mode, `box-shadow` is forced to `none` (MDN example), so a border using `ButtonBorder` is needed where a shadow carries meaning. **Inference:** the defaults must pick system colours that hold in forced-colors mode (cursor, region and selection must not depend only on shadow, opacity or background-colour differences).
- **`color-mix()` for derived colours.** Safe. `color-mix(in oklch, var(--accent) 20%, Canvas)` gives tints from any base, so a theme only has to set a few bases. Percentages and the interpolation space are part of the spec; test in a forced-colors browser, where it is overridden along with other author colours.
- **`@property`.** Only worth it where Tuna needs typed values (animating a colour or length variable, or a guaranteed `initial-value` for an inherited variable). **Inference:** do not register every semantic style; a registered property with an invalid value silently falls back to its initial value, which hides theme mistakes. Unregistered `var(--x, fallback)` is enough for Tuna's defaults.
- **Container queries.** Size queries are Widely available, so plugin stylesheets can use `container-type: inline-size` for component behaviour (matches `agents/guides/html-css.md`). Style queries (`@container style(--x: y)`) are only Newly available: do not depend on them.
- **`@scope`.** **Fact:** it now has Baseline Newly status. **Inference:** it would let a plugin sheet say `@scope (.tuna-completion) { ... }`, but each plugin's HTML already has its own class prefix, and low-specificity `.plugin-thing` rules inside the `plugin` layer achieve the isolation. Use only when a feature degrades gracefully without it, and not in the first design.

## C. Recommendation for the default design system

**Recommend none shipped in the core; the Tuna default is a thin set of its own variables.**

Reasons (inference): (1) a design system the user may not want costs bytes on phones; (2) system colours plus `color-scheme` already give correct light, dark and forced-colors behaviour with no values to maintain; (3) the owner's layering already makes any design system an optional first layer.

Concrete plan:
1. Core generates the order sheet, `:root { color-scheme: light dark }` and each semantic style's current value (`--tuna-...`). Defaults come from system colours and literal `clamp()` sizes, so Tuna works with no theme.
2. A first official **theme plugin** (e.g. `theme-open-props`) vendors Open Props v1 files (`gray`, `sizes`, `easings`, `shadows`, plus the hue the theme uses) as the `design-system` layer and maps semantic styles to those props. Use Open Props v2 only after it leaves beta.
3. Generate Utopia-style fluid steps once and ship them as Tuna's own default size scale (no tool at runtime).
4. Treat Radix's step meanings and Material's role pairs as **naming models**. Do not import their values by default.
5. Keep DTCG JSON and Stellar out of the first build. A Stellar theme plugin remains possible if the owner confirms the generated CSS may be redistributed.

### Minimum tokens plugins may rely on

Names are placeholders; the owner has not chosen the term for "face".

- **Colour pairs:** `surface` + `on-surface` (the page); `surface-raised` + `on-surface` (popups, completion lists, dialogs); `surface-sunken` (minibuffer, mode line background); `on-surface-muted` (secondary text); `accent` + `on-accent` (selected row, primary action); `selection` + `on-selection` (region/selection); `border`; `focus-ring`; `danger`, `warning`, `success` (each with an `on-` partner, plus a non-colour cue in markup per `html-css.md`).
- **Editor-specific roles:** `cursor`, `current-line`, `match` (search hit), `link`, `code-keyword`, `code-string`, `code-comment`, `code-name`. These are the few things Emacs themes always set; they need real defaults (`Highlight`, `LinkText`, ...), not silence.
- **Type:** `font-ui`, `font-mono`, and a fluid scale `text-s`, `text-m`, `text-l`, `text-xl`. One line-height for code, one for prose.
- **Space and shape:** fluid `space-xs..xl` (Utopia style), `radius-s/m`, `border-width`, `touch-target` (minimum 2.75rem for phones, inference from common touch-target guidance, not verified here).
- **Depth and motion:** `shadow-raised`, `shadow-overlay`, `duration-fast`, `duration-slow`, `ease-standard`, with all motion wrapped in `prefers-reduced-motion`.
- **Z-order:** a short named set (`z-overlay`, `z-minibuffer`).
- Colours should be allowed to be **any CSS colour expression**, so a theme can use `light-dark()`, `color-mix()` or an Open Props variable. Lengths should be any length expression.

## Contradictions / gaps

- No contradiction found between sources. Gaps: Open Props v1 claims about layering and whether its files are wrapped in `@layer` were not verified (inference: they are not, so the theme plugin should wrap them with `@import url(...) layer(design-system)` or a build-free vendored copy that adds `@layer design-system { ... }`). The licences of Radix, Utopia and Material tokens were not read from source. Stellar redistribution terms are unknown. The Material contrast statement was not re-verified. The `oklch()` function has no separate Baseline entry in the API; I used the `oklab` colour-space entry (Widely, 2025-11-09) as the closest Baseline record.

## Recommendations for Tuna

1. No design system in core. Core owns semantic variables with system-colour defaults and a fluid size scale.
2. Put `@layer reset, design-system, theme, plugin, user` in the generated first-in-head sheet; keep the user stylesheet unlayered or last; never use `!important` in layers.
3. Define semantic styles as role pairs; let values be any CSS colour or length expression.
4. Use `light-dark()` plus `color-scheme: light dark` (Newly available, fine for target browsers from 2024), with `color-mix()` for derived tints.
5. Test the default look in forced-colors mode; never carry meaning with shadow or background alone.
6. First optional design system: vendored Open Props v1 in an official theme plugin; v2 after stable.
7. Avoid style queries and `@scope` in the first design; allow `@container` size queries.
8. Do not register custom properties with `@property` except where a typed animation needs it.
9. Ask the owner about Stellar CSS redistribution before any Stellar theme plugin.
