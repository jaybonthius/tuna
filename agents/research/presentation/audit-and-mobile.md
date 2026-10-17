# Presentation audit, mobile checklist and stylesheet delivery over Datastar

Research note, 2026-10-16. Read-only; no source changed. Labels: **Fact** = observed in code or quoted from a specification; **Rationale** = documented reason; **Inference** = my conclusion.

## (a) Audit of Tuna today

### Who styles what

**Fact.** One stylesheet, `plugins/web/web/tuna.css` (368 lines), is embedded by the web transport (`plugins/web/plugin.ss:34`, `embed-directory "web" "/static"`), linked once from the page shell (`plugins/web/plugin.ss:145`), and served with `Cache-Control: no-cache` and no `ETag`/`Last-Modified` (`plugins/web/plugin.ss:204-209`). Every plugin's HTML is styled by that one file. The table lists each rule block, the code that emits the HTML it styles, and the values it hard-codes.

| tuna.css lines | Selector(s) | HTML emitted by | Hard-coded values |
|---|---|---|---|
| 1-25 | `:root` custom properties, dark `@media` | (tokens) | 12 hex colours (light 3-8, dark 18-23); 2 font stacks (9-10); `color-mix` 8 % / 16 % (12-13); `color-scheme: light dark` |
| 27-32 | `body` | web: page shell `plugins/web/plugin.ss:129-150` | margin 0 |
| 36-40 | `.screen` | renderer `plugins/renderer/plugin.ss:254`; plain-text test double `plugins/renderer/tests/support/plain-text-renderer.ss:85` | **`block-size: 100vh`** |
| 43-46 | `.help h1` | help `plugins/help/plugin.ss:58,60` | 0.5rem, 1rem |
| 51-70 | `.layout`, `.layout > *`, `.container.fit > *`, `.tab-panel > *`, `[data-size="content"]` | layout `plugins/layout/plugin.ss:889` (`.layout`), `:83` (fit), `:105` (tab panel), `:438-443` (`style="--tuna-size: W"` / `data-size`) | none (weights arrive as `--tuna-size`) |
| 73-76 | `[data-selected-part]` | layout `:483` | 2px outline |
| 78-144 | `.container`, `.fit/.tabbed`, `.horizontal/.vertical`, `.tabs`, `.tab`, `.tab[aria-selected]`, `.tab-panel` | layout `:77-79`, `:93-106` | 1px rules; tab padding 0.25rem 0.75rem; bold |
| 146-165 | `.view`, `.view:has(> .buffer > .minibuffer:empty)`, `.buffer:has(> .minibuffer, > .echo-area)`, `.buffer` | renderer `:223-229`; the `:has()` parts depend on minibuffer `plugins/minibuffer/plugin.ss:218` and echo area `plugins/echo-area/plugin.ss:51` | 0.5rem padding |
| 167-177 | `.column`, `.heading` | **test support only**: `tests/support/tree-buffer.ss:25,28` (used by `demo/sidebar.ss:39,64`) | 0.5rem gap; 1.25rem |
| 179-201 | `.text`, `.line`, `.face-digit`, `.cursor`, `.inactive-cursor` | renderer text node `plugins/renderer/plugin.ss:130,136,166,184,188-193`; the `digit` face comes only from **test support** `tests/support/digit-highlighter.ss:31,35` (loaded by `demo/init.ss:80`) | 1lh; 1px outline |
| 204-212 | `.plain-text` | **test double** `plugins/renderer/tests/support/plain-text-renderer.ss:78` | 0.5rem; 1lh |
| 214-252 | `.status-line`, `.minibuffer`, `.minibuffer .text`, `.prompt`, `.view[data-selected] > .status-line`, `.echo-area` | renderer `:231-234`; minibuffer `:218,220`; echo area `:51` | 0.25rem 0.5rem; 0.5ch; 1.5em; 1px rules |
| 256-264 | `.button` | buttons `plugins/buttons/plugin.ss:38` | 0.25rem 0.5rem; 1px; radius 0.25rem |
| 270-281 | `[data-clickable]`, `:hover`, `:active` | renderer `:83` (node keymaps), `:233` (status line); layout `:92` (tabs) | `cursor: pointer`; hover overlay |
| 284-368 | `.minibuffer:has(> .completion-list)`, `.completion-*`, `.completion-row mark` | completion-vertical `plugins/completion-vertical/plugin.ss:46` (`mark`), `:50-58` (rows), `:113,116,118`; `.completion-key`/`.completion-doc` are `completion-<field class>` (`:56`) from command-annotations `plugins/command-annotations/plugin.ss:18-19` | **60vh** list height; 0.3rem / 0.5rem / 1rem / 0.25rem spacing; 22ch column; radius 0.25rem; 2px focus outline; 0.15em underline offset |

Classes emitted but never styled: `.node` (renderer fallback, `plugins/renderer/plugin.ss:117`), `.completion-item` (`completion-vertical:50`), `.help` itself.

**Inference: findings that matter for the layered design.**
1. **Production CSS styles test fixtures.** `.column`, `.heading`, `.plain-text` and `.face-digit` style HTML that only test-support or test-double plugins emit. Under per-plugin stylesheets these rules move to those fixtures.
2. **Cross-plugin selectors.** `.view:has(> .buffer > .minibuffer:empty)`, `.buffer:has(> .minibuffer, > .echo-area)`, `.minibuffer .text` and `.minibuffer:has(> .completion-list)` each combine HTML from two or three plugins. One rule has to be split, or assigned to the plugin that adds the dependency: minibuffer for the first three, completion-vertical for the last. Under ADR 12, a plugin's stylesheet may style its own classes plus the renderer's public structure (`.view`, `.buffer`, `.text`). The renderer's classes then become a contract, like `data-part` already is for `tuna-pointer.ts:18-45`.
3. **One token, three meanings.** `--tuna-digit` is used for the digit face (189), the completion focus outline (329) and completion match highlighting (365). These are three semantic styles: a syntax-like face, a focus ring and a match highlight.
4. **Semantic styles versus design tokens.** Raw values (the 12 hex colours, the rem steps, the radius, the font stacks) are design-system tokens. Role names (page background and foreground, muted text, rule or divider, bar or chrome surface, hover and pressed overlay, cursor, inactive cursor, selected part, focus ring, match highlight, code font, prose font, heading size) are semantic styles. Each needs a token-free default for running without a design system, for example `Canvas`, `CanvasText`, `GrayText`, `Highlight`, `HighlightText` and `ButtonBorder` from [CSS Color 4 system colours](https://www.w3.org/TR/css-color-4/#css-system-colors). Spacing steps (0.25 / 0.5 / 0.75 / 1rem) are tokens. A plugin needs a semantic style only where a theme should be able to change it independently, for example bar padding.
5. **`.cursor` disappears in forced-colours mode.** It swaps `background` and `color` (192-195). Under [`forced-colors: active`](https://www.w3.org/TR/css-color-adjust-1/#forced) the browser overrides both, so the cursor vanishes. Its default should use `Highlight`/`HighlightText` or an outline.

### Other places Tuna emits HTML or style-related attributes

**Fact.**
- **Page shell** (web transport) `plugins/web/plugin.ss:129-150`: `<html lang data-init data-on:*>` (132-139); viewport meta `width=device-width, initial-scale=1` (143); one stylesheet link (145); import map and module script (146-148). Empty screens appear at `:73` and `:392`. `stamp-revision` adds `data-revision` to the root element (`:77-88`). The SSE writer sends each screen as one default (outer, id-matched) element patch (`:223-239`, call at `:234`).
- **Renderer** `plugins/renderer/plugin.ss`: `with-node-id` adds `id`, `data-node` and `data-clickable` (79-91); the fallback node is `div.node[data-kind]` (117); `section.view#view-N[data-view][data-part][data-selected]` and `article.buffer[aria-label]` (223-229); `p.status-line[data-part][data-clickable]` (231-234); `main#screen.screen` (254).
- **Layout** `plugins/layout/plugin.ss`: `div.container.<kind>.<direction>#container-N[data-container]` (77-79); tabs as `ul.tabs[role=tablist][aria-orientation] > li.tab[role=tab][aria-selected][data-part]` and `div.tab-panel[role=tabpanel]` (93-106); **the only inline style in Tuna**, `style="--tuna-size: W"`, or `data-size="content"` (438-443); `data-selected-part` (483); `div.layout` (889).
- **Node-kind renderers in plugins**: buttons `button.button[type=button][tabindex=-1]` (`plugins/buttons/plugin.ss:38`); minibuffer `div.minibuffer`, `span.prompt` (`plugins/minibuffer/plugin.ss:218,220`); echo area `p.echo-area[role=status]` (`plugins/echo-area/plugin.ss:51`); help `div.help`, bare `h1` (`plugins/help/plugin.ss:58,60`); completion-vertical `span.completion-counter`, `ul.completion-list`, `li.completion-group`, `li.completion-item > button.completion-row[aria-current]`, `span.completion-label`, `mark`, `span.completion-field.completion-<class>` (`plugins/completion-vertical/plugin.ss:46-58,113-118`).
- **`tuna/` (the kernel and libraries)** emits no HTML: a grep for `class`, `style` and SXML found nothing.
- **Frontend** reads `data-part`, `data-node`, `data-clickable` and `data-revision` (`plugins/web/frontend/tuna-pointer.ts:18-45`). It has **no editable element**: keys come from a document-level `keydown` (`tuna-keyboard.ts:36-57`, `preventDefault` unless `isComposing`).

### How faces reach HTML today

**Fact.**
- A highlight span's value is a face-name symbol (`plugins/buffers/contract.ss:401`; layers set with `set-highlights!`).
- The renderer remaps each span's face through the buffer-local setting `face-remapping` ("Emacs's `face-remapping-alist`", `plugins/renderer/contract.ss:32-39`; applied at `plugins/renderer/plugin.ss:133-134`).
- It then writes the class `face-<name>` (`:188-189`), combined with the cursor class on the cursor character (`:191-193`).
- `face-remapping` is part of the drawing inputs, so changing it redraws (`:220`).
- Each character gets **one** face: later spans overwrite earlier ones (`:159-165`). Faces are never merged.
- Tuna has no face definitions. The only face CSS is `.face-digit`, and only a test plugin produces that face.

**Inference.**
- Today `face-remapping` swaps one class name for another. Under the new design it could map a semantic style to another semantic style. That could be rendered as a custom-property override on the buffer's `article.buffer`, scoped to that buffer by the cascade, instead of renaming classes per span.
- Overlapping highlights, such as a search match over a keyword, need nested elements or several classes per run. The current one-face vector cannot express them.

## (b) Mobile checklist

Kinds:
- **S-DS**: styling in the design system or theme.
- **S-P**: styling in a plugin's stylesheet.
- **Shell**: the web transport's page shell.
- **LF**: belongs to the layout-facts research (ADR 7, "Layout belongs to the browser").
- **IN**: the input plugin (`frontend/`).

| # | Item | Today | Do | Kind |
|---|---|---|---|---|
| 1 | **Viewport height.** `100vh` is the *large* viewport on mobile, so the bottom bar (minibuffer, echo area) hides behind the browser toolbar. `svh`/`lvh` are the small/large viewports; `dvh` follows the toolbar ([CSS Values 4, viewport variants](https://www.w3.org/TR/css-values-4/#viewport-variants); [web.dev](https://web.dev/blog/viewport-units)). | `.screen { block-size: 100vh }` (39); completion `max-block-size: 60vh` (302) | `block-size: 100dvh` on the screen. Size the completion list relative to its container, not the viewport. | S-P (renderer, completion-vertical) |
| 2 | **Soft keyboard and viewport.** The default `interactive-widget=resizes-visual` shrinks only the visual viewport, so `dvh` does not shrink and the keyboard covers the bar. `resizes-content` shrinks the initial (layout) viewport, so the flex screen fits above the keyboard ([CSS Viewport §3.4](https://drafts.csswg.org/css-viewport/#interactive-widget-section)). Supported by Chrome Android 108+ and Firefox Android 133+, **not by Safari or iOS** ([MDN](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/meta/name/viewport), BCD). | not set (`plugin.ss:143`) | Add `interactive-widget=resizes-content` to the viewport meta. On iOS, use [`visualViewport`](https://drafts.csswg.org/cssom-view/#the-visualviewport-interface) `resize` and `height`/`offsetTop`. The input plugin could expose that as a CSS custom property (presentation-only state, ADR 7) or report it as a fact. | Shell; LF for iOS |
| 3 | **VirtualKeyboard API** ([W3C draft](https://w3c.github.io/virtual-keyboard/)): `navigator.virtualKeyboard.overlaysContent = true` stops viewport resizing and exposes `env(keyboard-inset-height)` and the other `keyboard-inset-*` variables, plus `geometrychange` and `virtualkeyboardpolicy=manual`. Chromium only. `overlaysContent` overrides `interactive-widget` (CSS Viewport §3.4.1). | none | Not needed if item 2 works. Keep as an optional Chromium refinement, such as hiding the keyboard while the minibuffer is idle. | IN; LF |
| 4 | **Safe-area insets.** Without `viewport-fit=cover`, iOS letterboxes the page, which is safe. With it, pad the screen edges with `env(safe-area-inset-*)` ([CSS Env §2](https://drafts.csswg.org/css-env-1/#safe-area-insets); [`viewport-fit`](https://www.w3.org/TR/css-round-display-1/#viewport-fit-descriptor)). | not set | Pad the bar and screen with `max(token, env(safe-area-inset-bottom))` only if the shell opts in. | Shell + S-DS |
| 5 | **Target size.** [WCAG 2.2 SC 2.5.8](https://www.w3.org/TR/WCAG22/#target-size-minimum) (level AA) requires 24×24 CSS px, or 24 px spacing. Exceptions: *inline* targets in text, equivalent controls, user-agent controls, and essential presentation. [2.5.5](https://www.w3.org/TR/WCAG22/#target-size-enhanced) (AAA) requires 44×44. | tab padding 0.25rem; completion row 0.3rem; button 0.25rem; status line ~1 line high | Make a "minimum target size" semantic style (24px default; larger under `@media (pointer: coarse)`), used by tabs, buttons, completion rows and status-line hit areas. Clickable buffer text falls under the inline exception. | S-DS + S-P |
| 6 | **Touch versus hover.** `:hover` sticks after a tap on touch screens. Use `@media (hover: hover)` and `(pointer: coarse)` ([Media Queries 4 §7](https://www.w3.org/TR/mediaqueries-4/#hover)). A tap produces compatibility `mousedown`/`click` ([Pointer Events §compatibility mapping](https://w3c.github.io/pointerevents/#compatibility-mapping-with-mouse-events)), so `tuna-pointer.ts` works for taps. Long-press gives `contextmenu`; there is no middle button. `touch-action: manipulation` removes double-tap zoom on controls ([Pointer Events §touch-action](https://w3c.github.io/pointerevents/#the-touch-action-css-property)). | `[data-clickable]:hover` is unconditional (275-277) | Gate the hover overlay. Add `touch-action: manipulation` to clickable chrome. Give long-press and swipe gestures their own design later. | S-P; IN for gestures |
| 7 | **Text input and IME.** ADR 7's proxy is not built (only the document `keydown`). **Inference:** phones show a soft keyboard only for a focused editable element, so Tuna cannot be typed into on a phone today. Android IMEs report most keystrokes as `keydown` with `key` "Unidentified" (keyCode 229) and deliver the text through `beforeinput`/`input` and composition events ([UI Events §keyCode 229](https://w3c.github.io/uievents/#determine-keydown-keyup-keyCode); [Input Events 2](https://w3c.github.io/input-events/)). The proxy must forward `beforeinput.inputType`/`data` (insertText, insertCompositionText, deleteContentBackward…), not only keydown. | ADR 7:18 (decision only) | Proxy element (IN). Turn off text help with `autocapitalize="off"`, `autocorrect="off"`, `spellcheck="false"` and `writingsuggestions="false"`; set `enterkeyhint`; `inputmode="none"` can hide the keyboard deliberately ([HTML, input modalities](https://html.spec.whatwg.org/multipage/interaction.html#input-modalities:-the-inputmode-attribute)). Its CSS: inside the viewport and focusable, so not `display:none` or `visibility:hidden`; transparent; positioned at the cursor so the IME candidate window and the browser's scroll-into-view land near point. Observed WebKit behaviour (no primary source): iOS zooms into inputs below 16px font size and shows the keyboard only for focus given inside a user gesture. | IN; proxy CSS in S-P (web); caret position = LF |
| 8 | **Zoom and text inflation.** Never set `user-scalable=no` or `maximum-scale` ([WCAG 1.4.4](https://www.w3.org/TR/WCAG22/#resize-text)). Mobile browsers inflate text unless `text-size-adjust` says otherwise ([CSS Size Adjust](https://drafts.csswg.org/css-size-adjust/)). | fine (`plugin.ss:143`) | `text-size-adjust: 100%` on the root, so monospace columns stay aligned. | S-DS / Shell |
| 9 | **Pull-to-refresh and overscroll.** A page reload restarts input numbering (ADR 7); a stray pull-to-refresh is disruptive. | none | `overscroll-behavior: none` on the root; `contain` on `.buffer` ([CSS Overscroll](https://drafts.csswg.org/css-overscroll-1/)). | S-P (renderer) |
| 10 | **Split panes on narrow screens.** Fit containers split by weight at any width (57-63, 82-97), and `min-inline-size: 0` lets a pane shrink to nothing. On a 360px phone, two side-by-side views get about 180px each. | — | (a) Styling fallback: `container-type: inline-size` on `.container.fit.horizontal`, then `@container (inline-size < 40ch)` stacks the children vertically (html-css guide: container queries for components; [CSS Conditional 5](https://www.w3.org/TR/css-conditional-5/#container-queries)). (b) Policy: on narrow screens show one view at a time, like `C-x 1` or a tabbed presentation. Pinned side views such as the demo sidebar collapse to a tab. | (a) S-P (layout); (b) LF + owner decision |
| 11 | **Reduced motion, colour scheme, forced colours.** `color-scheme` is set (2); there is no motion yet; `.cursor` breaks in forced colours (audit point 5). | partial | Defaults use system colours; check `prefers-reduced-motion` once anything animates. | S-DS |

**Inference.** Item 10(a) has a geometry consequence. If CSS stacks views the server thinks are side by side, directional commands (windmove-like) and "the view to the left" become wrong. The layout plugin then needs the actual orientation as a layout fact, or it should own the narrow-screen policy (b) outright. That is why 10 is split.

## (c) Replacing an ordered list of stylesheets with a Datastar element patch

### Where `<link rel=stylesheet>` may go

**Fact (HTML Standard).**
- "If a `link` element has an `itemprop` attribute, or has a `rel` attribute that contains only keywords that are body-ok, then the element is said to be allowed in the body. This means that the element can be used where phrasing content is expected." ([§4.2.4 `#allowed-in-the-body`](https://html.spec.whatwg.org/multipage/semantics.html#allowed-in-the-body))
- "The body-ok keywords are `dns-prefetch`, `modulepreload`, `pingback`, `preconnect`, `prefetch`, `preload`, and `stylesheet`." ([§4.6.8 `#body-ok`](https://html.spec.whatwg.org/multipage/links.html#body-ok))
- The `stylesheet` section repeats: "This keyword is body-ok."

### What Datastar v1.0.2 does

**Fact (vendored docs).**
- `datastar-patch-elements` morphs by top-level id by default. A `selector` with modes `outer | inner | replace | prepend | append | before | after | remove` is also available (`agents/reference/datastar/docs.md:4134-4174`).
- "fat morph" up to the `html` tag is endorsed (`docs.md:1504-1506`).

**Fact (bundle `plugins/web/web/datastar-v1.0.2.js`, minified; behaviour read from the code).**
- If the `elements` string contains `</html>`, `</head>` or `</body>`, it is parsed as a document. A `<head>` element then targets `document.head` (and `<body>` targets `document.body`) in outer/replace mode without a selector.
- Otherwise the string is parsed inside `<body><template>…`, where `<link>` and `<style>` are valid.
- Morph walks children in order. An old and a new node *match* when they have the same node type and tag, and either the old node has no id or the ids are equal (function `Yt`).
- Elements whose id exists before and after are kept and moved, using `moveBefore` when the browser has it and `insertBefore` otherwise (function `rn`).
- On a matched element, morph calls `setAttribute` only for attributes whose value changed and removes missing ones. Subtrees that are `isEqualNode` are left alone (function `dt`).

**Fact (HTML Standard, [`#link-type-stylesheet`](https://html.spec.whatwg.org/multipage/links.html#link-type-stylesheet)).**
- The appropriate times to fetch include "When the `href` attribute of the `link` element of an external resource link that is already browsing-context connected is changed" and "When the external resource link's `link` element becomes browsing-context connected."
- Processing the response, step 2: if "since the resource in question was fetched, it has become appropriate to fetch it again … Return." Step 3: "If el has an associated CSS style sheet, remove the CSS style sheet." Step 4 then creates the new sheet.
- Render blocking: "A `link` element of this type is implicitly potentially render-blocking if the element was created by its node document's parser."
- "To block rendering on an element el: … If document allows adding render-blocking elements, then append el to document's render-blocking element set". A document "allows adding render-blocking elements if document's content type is `text/html` and the body element of document is null" ([§3.1.6](https://html.spec.whatwg.org/multipage/dom.html#render-blocking-mechanism)).

**Answers (inference from the facts above).**
1. **Can the server replace the list? Yes.** Either send a whole `<head>…</head>` (Datastar morphs `document.head`), or send targeted patches by id: outer for a changed `<link id=…>`, `append` with selector `head` for a new one, `remove` for one turned off. A list in `<body>` (inside any container element) also conforms, because `stylesheet` is body-ok.
2. **Only changed hrefs are re-fetched, if every link has a stable id** (for example, one per plugin). Morph then changes `href` in place on the one link whose version changed, inserts new links and removes dropped ones. **Without ids,** morph matches links by position: inserting one in the middle rewrites the `href` of every later link and re-fetches all of them. Today that is a full download each time, because `no-cache` is sent without validators.
3. **Flash of unstyled content.**
   - **Version bump of an existing link: no flash.** The old sheet stays until the new response is processed (step 3 after the fetch), and stale responses are discarded (step 2).
   - **New link: brief flash.** It is not render-blocking: it was not created by the parser, and after the body exists nothing can block rendering, so even `blocking="render"` does nothing. HTML for a newly enabled plugin can paint unstyled until its sheet arrives. That is milliseconds on loopback and noticeable on a remote phone.
   - **Removed link:** its rules disappear at once (observed browser behaviour; spec step 2 covers links that stop contributing).
   - **Moved link:** where `moveBefore` is missing, a move is a disconnect plus reconnect, which re-fetches the sheet and can flash. `moveBefore` shipped in Chromium 133; re-verify other engines.
   - **Cure for reordering:** if every plugin's rules sit inside `@layer`, and the generated sheet declaring the layer order comes first, link order no longer affects precedence. Layer order is fixed by first appearance ([CSS Cascade 5, layer ordering](https://www.w3.org/TR/css-cascade-5/#layer-ordering)). Links then never need to move. `<link>` has no standard `layer` attribute, so each file must wrap its own rules, or be pulled in with `@import … layer(name)`.
   - **First page load:** links written into `<head>` by the server are parser-created and render-blocking, so the first paint is correctly styled.
4. **Would `<style>` behave better?** It is synchronous: changing its text runs "update a style block" (remove the old sheet, create the new one) during the DOM mutation ([§4.2.6](https://html.spec.whatwg.org/multipage/semantics.html#update-a-style-block)). That means no fetch and no flash, and a parser-created `<style>` is render-blocking on first load. Costs:
   - the CSS travels in the patch, with no HTTP cache;
   - a future Content Security Policy needs a nonce or `'unsafe-inline'` for styles;
   - in `<body>` it is now non-conforming for a global sheet: "If a `style` element is a descendant of a `body` element, then the style sheet … must not contain any `@import` rules, and each style rule … must be inside an `@scope` rule without a <scope-start>" (§4.2.6). In `<head>` it is fine.

   **Inference:** `<style>` suits only the small, often-changing generated sheet (layer order plus semantic-style values). It changes on theme switches and setting changes, never on a plain redraw, and a synchronous swap makes theme changes flash-free.

## Recommendations for Tuna

1. **Ownership move (when stylesheets become per-plugin).** Split `tuna.css` by the table in (a):
   - web: shell and `body`;
   - renderer: `.screen`, `.view`, `.buffer`, `.text`, `.line`, cursors, `.status-line`, `[data-clickable]`;
   - layout: containers, tabs, `[data-selected-part]`;
   - minibuffer: `.minibuffer`, `.prompt`, and the `:has()` rules that mention it;
   - echo area, buttons, help;
   - completion-vertical: `.completion-*`, `mark`, and `.minibuffer:has(> .completion-list)`;
   - test fixtures: `.column`, `.heading`, `.plain-text`, `.face-digit`.

   Treat the renderer's classes and `data-*` attributes as a published contract that other plugins may select on.
2. **Semantic-style candidates.** Seed the semantic-style list from audit point 4. Split `--tuna-digit` into three: a digit face, a focus ring and a match highlight. Give every default a system-colour fallback, and fix `.cursor` for forced colours.
3. **Faces in the renderer.** Keep span values as style names, but plan for several classes per run, because one face per character cannot express overlaps. Consider rendering `face-remapping` as custom-property overrides on `article.buffer` instead of renaming classes.
4. **Delivery.**
   - First page: write every link (and the generated `<style>`, if chosen) into `<head>`, each with a stable id.
   - On change: send a separate patch, never with a redraw. Use `outer` by id for a version bump, `append` to `head` for a new plugin and `remove` for a plugin turned off. Send it before the first screen that uses the new plugin's HTML.
   - Never reorder links; declare the order with `@layer` in the first sheet.
   - Serve versioned URLs (content hash) with `Cache-Control: max-age=31536000, immutable` ([RFC 8246](https://www.rfc-editor.org/rfc/rfc8246)) instead of today's `no-cache` without validators.
   - Prefer targeted patches to a whole-`<head>` morph: they avoid touching the import map and module script. If a whole-head morph is chosen, test it in a browser first.
5. **Owner decision.** Should the generated sheet (layer order plus semantic-style values) be a versioned `<link>`, as currently decided, or a `<head><style>`? Recommendation: a `<style>`. It still never travels with a redraw, and it makes theme and setting changes synchronous and flash-free. Plugin, theme and user stylesheets stay as links.
6. **Mobile, styling (do with the stylesheet work).** Items 1, 5, 6, 8, 9, 10(a) and 11:
   - `100dvh`;
   - a minimum-target-size semantic style, larger for coarse pointers;
   - hover overlays inside `@media (hover: hover)`;
   - `touch-action: manipulation`;
   - `text-size-adjust: 100%`;
   - `overscroll-behavior`;
   - a container query that stacks narrow fit containers.
7. **Mobile, shell.** Add `interactive-widget=resizes-content` to the viewport meta now. Leave `viewport-fit=cover` until safe-area padding exists.
8. **Mobile, for the layout-facts research and the input plugin.**
   - Build ADR 7's input proxy first: without it phones cannot type. It should forward `beforeinput` and composition, sit at the cursor, and turn off autocorrect and autocapitalisation.
   - The iOS keyboard height through `visualViewport`.
   - The narrow-screen pane policy, 10(b), which needs the owner's choice between stacking and one view at a time.
   - The actual pane orientation, whenever CSS may change it.
