# Design tokens plugins may use

The `stylesheets` plugin (`plugins/stylesheets/plugin.ss`) adds one stylesheet, `(stylesheets tokens)`: the raw design scale as CSS custom properties. Its `variant:` option picks a shipped file in `plugins/stylesheets/tokens/`; today only `stellar-default`, Stellar's output for `tokens/stellar.config.json` with only the core sections. Never edit the generated file. Change the config and run `make tokens STELLAR=/path/to/stellar`. The Stellar binary and its key belong to the owner and are not in this repository. Normal builds and tests never run it.

Plugins rely only on the subset below, so that moving to another design system means mapping these names in one file. Use them in a plugin's semantic tokens file, always with a fallback (`--completion-selected-background: var(--primary-3, Highlight)`), never directly in rules. `make test` checks that the shipped file defines every name here (`plugins/stylesheets/tests/integration/tokens-test.ss`); update both together.

`N` is a step number; negative steps are written with a second hyphen (`--size--2`).

| Group | Names | Notes |
|---|---|---|
| Theme palettes | `--P-N`, `--P-N-on`, `--P-N-dim` for P in `primary`, `secondary`, `tertiary`, `neutral`, `neutral-variant`, `error`, and N from 1 to 12 | `-on` is the text colour for that exact step; `-dim` is a quieter partner. Step 1 is the lightest in light mode. The palettes swap under `prefers-color-scheme: dark`. |
| Sizes | `--size-N`, N from -2 to 12 | Fluid spacing and dimensions (`clamp()` between a 320 px and a 1440 px viewport). |
| Font families | `--font-sans`, `--font-serif`, `--font-mono` | System font stacks; no downloads. Stellar's other named stacks are not in the subset. |
| Font sizes | `--font-size-N`, N from -2 to 12 | `--font-size-0` is `1rem`. |
| Font weights | `--font-weight-W`, W in `thin`, `extra-light`, `light`, `normal`, `medium`, `semi-bold`, `bold`, `extra-bold`, `black`, `extra-black` | 100 to 950. |
| Line heights | `--font-line-height-N`, N from -3 to 4 | Absolute `rem` measures for body-sized text; their steps do not match font-size steps. |
| Border widths | `--border-width-N`, N from 0 to 5 | |
| Radii | `--border-radius-N`, N from 0 to 6 | The in-between radii (`--border-radius-1-2`) are not in the subset. |
| Shadows | `--shadow-N`, N from 0 to 6; inset `--shadow--N`, N from 1 to 4 | `--shadow-0` is `none`. They swap in dark mode. |
| Durations | `--anim-duration-D`, D in `none`, `instant`, `fast`, `base`, `slow`, `long` | Respect `prefers-reduced-motion` in rules that use them. |
| Easings | `--anim-ease-E`, E in `standard`, `emphasized`, `entrance`, `linear` | |
| Code colours | `--code-bg`, `--code-fg`, `--code-inner-bg`, `--code-border`, `--code-border-subtle`, `--code-selection`, `--code-highlight-line`, `--code-ln`, `--code-ln-current`; and the syntax roles `--code-R` for R in `comment`, `comment-special`, `keyword`, `keyword-const`, `keyword-decl`, `keyword-namespace`, `name`, `name-attribute`, `name-builtin`, `name-class`, `name-constant`, `name-decorator`, `name-entity`, `name-exception`, `name-function`, `name-label`, `name-namespace`, `name-property`, `name-tag`, `name-variable`, `string`, `string-affix`, `string-delim`, `string-doc`, `string-escape`, `string-regex`, `number`, `operator`, `type`, `error`, `deleted`, `inserted`, `emph`, `strong` | Swap in dark mode. |

Not in the subset, though the file defines them: the other font stacks, letter spacing, aspect ratios, z-indexes, the viewport bounds, the numbered durations, and the other easings and animation values (distances, rotations, scales, opacities). The file also defines an `.animate` helper class; plugins do not use it.
