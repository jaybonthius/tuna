# Stylesheets plan, stages 6–7: report

Worktree `/home/jay/Code/workbench-gerbil/tuna__stylesheets-split`, branch `stylesheets-split`. Nothing pushed. The kernel is unchanged. `make test` passed (last line `OK`, exit 0) under `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 2400` after stage 6 (2 min 52 s) and after stage 7 (3 min 46 s).

## Commits

| Stage | Commit | Subject |
|---|---|---|
| 6 | `dbc94b1` | stylesheets: split tuna.css into each owning plugin's files |
| 6 (follow-up from the phone check) | `00cc4ae` | completion-vertical: drop the doc column when the list is narrow |
| 7 | `b417669` | theme-terminal: prove themes and init.ss restyle real plugins |
| 7 (records) | `4493cd8` | Record the stylesheets split and how to restyle Tuna |

## Stage 6: the split

`plugins/web/web/tuna.css` is deleted. The web transport no longer links `/static/tuna.css`. Each owner registers its files with `(add-stylesheet 'tokens "tokens.css")` and `(add-stylesheet 'rules "rules.css")` in its `defplugin` body.

| Owner | Files | Rules (old tuna.css lines) | Semantic tokens |
|---|---|---|---|
| web-transport | `plugins/web/tokens.css`, `rules.css` | `:root` colour-scheme (2), `body` (27–32); new: `text-size-adjust`, `overscroll-behavior: none` | `--page-background`, `--page-foreground`, `--page-font` |
| html-renderer | `plugins/renderer/tokens.css`, `rules.css` | `.screen` (36–40), `.view` (146–149), `.buffer` (161–165), `.text`, `.line` (179–186), `.cursor`, `.inactive-cursor` (192–201), `.status-line` (203–208, 223–235), `[data-clickable]` (259–270) | `--buffer-padding`, `--cursor-background/-foreground`, `--inactive-cursor-outline`, `--status-line-background/-foreground/-selected-foreground/-border/-padding`, `--clickable-hover/-pressed` |
| layout | `plugins/layout/tokens.css`, `rules.css` | `.layout`, children and `[data-size]` (51–70), `[data-selected-part]` (73–76), containers and tabs (78–144) | `--container-rule`, `--tabs-background`, `--tab-foreground`, `--tab-selected-background/-foreground`, `--tab-padding`, `--selected-part-outline` |
| minibuffer | `plugins/minibuffer/rules.css` (tokens at its top) | `.minibuffer` (203–213), `.minibuffer .text` (215–217), `.prompt` (219–221), and the cross-plugin `.view:has(> .buffer > .minibuffer:empty)` (152–154) and `.buffer:has(> .minibuffer)` (half of 157–159) | `--minibuffer-padding`, `--prompt-foreground` |
| echo-area | `plugins/echo-area/rules.css` (tokens at its top) | `.echo-area` (203–208, 237–241), cross-plugin `.buffer:has(> .echo-area)` (other half of 157–159) | `--echo-area-padding` |
| buttons | `plugins/buttons/rules.css` (tokens at its top) | `.button` (245–253) | `--button-border`, `--button-radius`, `--button-padding` |
| help-buffer | `plugins/help/rules.css` | `.help h1` (43–46) | none |
| completion-vertical | `plugins/completion-vertical/tokens.css`, `rules.css` | `.completion-*`, `mark`, and the cross-plugin `.minibuffer:has(> .completion-list)` (273–357); the `.completion-key`/`.completion-doc` field rules stay here, since completion-vertical draws annotation fields as `completion-CLASS` | `--completion-muted`, `--completion-selected-background/-foreground/-border`, `--completion-focus-ring`, `--completion-match-foreground`, `--completion-row-radius/-padding`, `--completion-group-font`, `--completion-list-max-size` |
| tree-buffer fixture | `tests/support/tree-buffer.css` | `.column`, `.heading` (167–177) | `--heading-font` |
| digit-highlighter fixture | `tests/support/digit-highlighter.css` | `.face-digit` (188–190) | `--face-digit-foreground` |
| bare-renderer double | `plugins/renderer/tests/support/bare-renderer.css` | new: the minimum its screen needs once the HTML renderer's sheets go away on a swap (`C-c v`) | none |
| two-views double | `plugins/layout/tests/support/two-views.css` | new: the minimum its `.layout` needs on a swap (`C-c w`) | none |

**Conventions applied.**
- Every semantic token is `var(<design token>, <fallback>)`, with the fallback a system colour (`Canvas`, `CanvasText`, `Highlight`, `HighlightText`, `GrayText`, `ButtonBorder`, `LinkText`) or a plain value. Rules use only their plugin's own tokens; no hard-coded colours.
- Colour mapping, in both schemes (Stellar's neutral palette swaps under dark mode): page background `--neutral-1`, foreground `--neutral-12`, bars `--neutral-3`, rules `--neutral-4`, muted text `--neutral-7`; selected completion row `--primary-3` with `--primary-3-on`; completion focus ring `--primary-6`; match highlight and digit face `--primary-7`; radii `--border-radius-0`; fonts `--font-mono` and `--font-sans`.
- **`--tuna-digit` is split** into `--face-digit-foreground` (fixture), `--completion-focus-ring` and `--completion-match-foreground`.
- **Specificity.** The renderer's rules are all in `:where()`, so any other plugin's or theme's rule beats them whatever the page order. Other plugins wrap their own rules in `:where()`. Real specificity is kept only where a rule must beat another plugin's regardless of order, with a comment: the cursor (`.text .cursor`, two classes, so it beats face classes such as `.face-digit` that come later on the page); the minibuffer's and echo area's `.buffer:has(…)` padding overrides; `.minibuffer .text`; completion's `.minibuffer:has(> .completion-list)` grid over the minibuffer's flex.
- **Published surface.** The renderer's `rules.css` header documents `.screen`, `.view`, `.buffer`, `.text`, `.line`, `.cursor`, `.inactive-cursor`, `.status-line`, `.face-NAME` and the `data-view`, `data-selected`, `data-part`, `data-node`, `data-clickable` attributes as a styling surface other plugins may select on.
- **Forced colours.** `@media (forced-colors: active) { .text .cursor { forced-color-adjust: none; background: Highlight; color: HighlightText } }`. Checked with Chromium's forced-colors emulation over CDP: the computed cursor was `forced-color-adjust: none` with the Highlight colour, and visible (`after-forced-colors.png`). The inactive cursor is an outline, which forced colours keep.
- **Mobile.** `.screen` uses `block-size: 100dvh` (no `100vh` line: every engine Tuna targets has `dvh`) and pads by `env(safe-area-inset-*)`. Tabs, buttons, completion rows and clickable status lines get `min-block-size: 2.75rem` under `@media (pointer: coarse)`. The hover overlay is under `@media (hover: hover)`, and clickable parts get `touch-action: manipulation`. The completion list's maximum height is `60dvh`.

**Page order** (starter): `(design-tokens tokens)`, `(web-transport tokens)`, `(web-transport rules)`, `(layout tokens)`, `(layout rules)`, `(html-renderer tokens)`, `(html-renderer rules)`, `(buttons rules)`, `(minibuffer rules)`, `(completion-vertical tokens)`, `(completion-vertical rules)`, `(echo-area rules)`, `(help-buffer rules)`; the demo adds `(digit-highlighter rules)` and `(tree-buffer rules)`.

**Tests.**
- New `tests/integration/stylesheets-test.ss` starts `starter/init.ss` and `demo/init.ss` with every XDG directory in a temporary directory. It checks the exact page order, that no stylesheet has a warning (an unreadable file), and that `stylesheet-warnings` (the list `describe-stylesheets` shows) is empty, so there is no undefined `var()` without a fallback. It caught a real mistake during the work (a missing `plugins/web/tokens.css`).
- `plugins/web/tests/integration/web-stylesheets-test.ss` no longer assumes the test's stylesheet is slot 1 (the web transport's own sheets take slots now); it reads the slot from the page, and checks that `/static/tuna.css` is not linked.
- Every existing test passes unchanged otherwise.

### Deliberate visual changes (stage 6)

Compare `before-desktop-light.png` / `before-desktop-dark.png` with `after-desktop-light.png` / `after-desktop-dark.png`. Geometry is identical: same status-line, tab, sidebar and completion positions at 1280×800. The differences:
- **Colours come from the Stellar palette.** The light background is a pale blue-grey (`#eaf2f7`) instead of near-white `#fdfdfb`; dark is `#0a1216` instead of `#0d1117`. Bars, rules and muted text are Stellar neutrals close to the old values.
- **The selected completion row is tinted** with `--primary-3` (pale blue in light, deep teal in dark) instead of the grey bar colour, as in the brief's example.
- **Match highlights and digits are a muted blue-grey** (`--primary-7`) instead of saturated blue; they stay underlined (matches).
- **Button and completion-row radii** follow `--border-radius-0`, which is fluid: about 0.45rem at 1280 px, about 0.15rem at 390 px (was 0.25rem).
- **Phones and touch:** taller tabs, buttons, completion rows and clickable status lines; the tab strip scrolls instead of spilling over the next part; completion rows narrower than 48ch hide the documentation column (before, the label collapsed to one character per line, see `theme-off-phone-*.png` taken after the fix).
- **The viewport meta** now reads `width=device-width, initial-scale=1, interactive-widget=resizes-content, viewport-fit=cover` (see deviations).

## Stage 7: proof and records

**`theme-terminal`** (`tests/support/theme-terminal.ss`, files in `tests/support/theme-terminal/`): a flat, monospace, reverse-video look in the system colours `Canvas` and `CanvasText`, so it follows light and dark. It replaces five stylesheets and adds none:
- `(web-transport tokens)` → `page.css`;
- `(html-renderer tokens)` → `renderer.css` (reverse-video status lines, block cursor, one-character padding);
- `(completion-vertical tokens)` → `completion.css` (reverse-video selection, square rows, matches underlined in the text colour);
- `(layout rules)` → `layout.css` (the whole layout file rewritten flat: single-line dividers, `[bracketed]` tabs with the selected one reversed, dashed selected part);
- `(buttons rules)` → `buttons.css` (`[ label ]`).

The demo toggles it with **`C-c T`** (`toggle-theme-terminal` in `demo/demo.ss`, noted in `demo/init.ss`); the echo area says "Terminal theme on/off".

**Test** (in `tests/integration/stylesheets-test.ss`): an init.ss made of the starter plus `(use-plugin theme-terminal)` and `(replace-stylesheet 'completion-vertical 'tokens "my-completion.css")`. It checks that the theme's files fill `(html-renderer tokens)` and `(layout rules)`, that init.ss's file beats the theme's for `(completion-vertical tokens)`, that the page has no warnings, and that after `deactivate-plugin! theme-terminal` the renderer, layout and web tokens are the plugins' own files again, init.ss's replacement stays, and the page is still clean.

**Starter.** `starter/init.ss` now imports the stylesheets contract and ends with a commented example of `add-stylesheet` and `replace-stylesheet`, so `init.ss` code can restyle without editing imports.

**Records:** `docs/overview.md` (new section "How it looks: HTML and stylesheets", status line, the demo's `C-c T`, glossary: stylesheet, design tokens, semantic tokens, theme); `docs/emacs-equivalents.md` (faces, `defface` defaults, themes, `custom-set-faces`, `describe-stylesheets` rows; two divergences: faces as CSS classes, themes as file replacement); ADR 7 (a "Stylesheets" decision bullet, so the divergences have their ADR); `agents/guides/html-css.md` (new "Stylesheets in Tuna" section); `AGENTS.md`'s HTML and CSS line (the old "Stellar is not used" was wrong since stage 5); `agents/plans/stylesheets.md` (done); the brief (built); `docs/roadmap.md` (a Done entry); `agents/STATUS.md`.

## Browser checks and screenshots

All in `/home/jay/Code/workbench-gerbil/scratch/stylesheets/screens/`. Tuna ran from `.gerbil/bin/tuna --config demo/init.ss` with temporary `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME` and `XDG_RUNTIME_DIR` (script `scratch/stylesheets/run-tuna.sh`), on ports 18731–18733, each stopped by its PID; `pgrep` confirmed none left. Each screen shows a split (`C-x 3`), a tab (`C-x t 2`), the demo sidebar (`C-c d`), typed text with highlighted digits, and `M-x desc` with completion in the minibuffer; the `*-echo-*` shots show the echo area.

| File | What |
|---|---|
| `before-desktop-light.png`, `before-desktop-dark.png`, `before-desktop-dark-echo.png` | Before stage 6 (old tuna.css), 1280×800 |
| `after-desktop-light.png`, `after-desktop-dark.png` | After stage 6, same scene |
| `after-forced-colors.png` | Forced-colors emulation (dark): the cursor in the minibuffer shows in Highlight |
| `after-phone-light.png` | 390×844, touch emulation, after `M-x reload-stylesheets` picked up the tab-strip fix |
| `after-bare-renderer.png` | After `C-c v`: the bare renderer double with its own support stylesheet |
| `theme-off-desktop-light.png`, `theme-off-desktop-dark.png`, `theme-off-phone-light.png`, `theme-off-phone-dark.png` | Theme off (after toggling it on and off again), desktop and phone, light and dark |
| `theme-on-desktop-light.png`, `theme-on-desktop-dark.png`, `theme-on-phone-light.png`, `theme-on-phone-dark.png` | Theme on, same views |
| `theme-on-echo-desktop-light.png`, `theme-off-echo-desktop-light.png` | The echo area after `C-c T` ("Terminal theme on" / "off") |

Also observed: the head's links after `C-c T` named the theme's files (`page.css`, `renderer.css`, `layout.css`, `completion.css`, `buttons.css`) and after the second `C-c T` the plugins' own files again; `M-x reload-stylesheets` after editing a file applied it without a page reload ("Stylesheets reread: 1 changed").

Tools: the before/after desktop shots used `agent_browser` (Chrome, `set media light|dark`). Forced colours and touch need CDP emulation that `agent_browser` does not expose (`set media` covers only light, dark and reduced motion), so those and the theme series used a small Node script driving headless Chromium over CDP (`scratch/stylesheets/cdp-shot.mjs`: `Emulation.setEmulatedMedia` for `forced-colors` and `prefers-color-scheme`, `setDeviceMetricsOverride` with `mobile: true` and `setTouchEmulationEnabled`; `(pointer: coarse)` matched). Each run used a temporary profile and killed its browser.

## Deviations and decisions to confirm

1. **Spacing stays plain values** (`0.25rem 0.5rem` and so on) in semantic tokens, not Stellar `--size-N`: the fluid sizes are about 0.7–1 rem at desktop width, which would double the editor's chrome. Colours, fonts and radii use design tokens. The guide records this.
2. **Viewport meta changed**, as the audit recommends (recommendation 7): `interactive-widget=resizes-content` now, and `viewport-fit=cover` because the safe-area padding now exists.
3. **`stylesheet-warnings` is exported** from the `stylesheets-help` plugin module so the test can read exactly what `describe-stylesheets` would warn about.
4. **The theme lives in `tests/support/`, not `demo/`**: `make test` forbids tests importing the demo, and the test needs the theme. The demo imports it (allowed: it defines a plugin) and binds the toggle.
5. **The theme adds no stylesheet of its own.** A plugin turned on at runtime and not declared in init.ss has rank 0, so its own sheet would come first on the page and lose to everything; replacements are unaffected by that.
6. **Extra fixes found by the phone check:** the tab strip scrolls (`overflow: auto`) instead of overlapping the next part, and completion rows drop the documentation column below 48ch (container query). Not in the task list; both are small and in the owning plugin's rules.
7. **The completion list keeps a viewport-relative cap** (`60dvh`, now dynamic) rather than the audit's "relative to its container": the bar sizes to its content, so a percentage has nothing to resolve against.
8. **Doubles got support stylesheets** (bare renderer, two views): without them the demo's `C-c v` and `C-c w` swaps would show an unstyled page, since the swapped-out plugin's sheets leave with it.
9. **`--tuna-size`** (the layout's inline weight) keeps its name; it is data from the server, not a semantic token. Renaming it to `--layout-…` would be a separate small change.
10. **The before shots** have one stray extra copy of the typed text (an early `keyboard type` attempt); layout positions are unaffected.

## Not done / open

- Narrow-screen layout (the 1/5 sidebar and side-by-side splits on a 390 px phone) belongs to the layout-facts research, as the brief says. Phones still cannot type: ADR 7's input proxy is not built.
- Firefox and Safari not checked; `align-content` on block containers needs Chrome 123, Safari 17.4, Firefox 125.
- The Gerbil MCP tools were not available; balance was checked by reading the new test file's forms with `gxi`, and syntax by building and running the tests.
