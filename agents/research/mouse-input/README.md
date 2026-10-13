# Mouse input for Tuna: Emacs's model, Datastar idioms, dragging, hover

Read-only research, 2026-10-13.

Labels: **Fact** (cited), **Inference** (my reasoning from facts), **Unverified** (general web-platform knowledge or not checked here).

Sources and pins:
- Emacs checkout `/home/jay/Code/emacs` at `541f693ca2e8de166cfe52c39bbfc497142215e9` (abbreviated 541f693). Paths below are relative to it. Upstream permalink form (not fetched): `https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/<path>#L<line>`.
- Datastar source `/home/jay/Code/datastar/datastar` at `e8e935ab`, `VERSION` says `1.0.0-RC.1`. The shipped bundle is `web/datastar-v1.0.2.js`, so source claims are version-sensitive.
- hyperlith `/home/jay/Code/hyperlith`; Discord export searched with `corpus.py` (read-only index, no export run).

---

## 1. Emacs's mouse model

### 1.1 Events

- **Fact.** Four kinds: click, drag, button-down, motion. Each is a list `(TYPE POSITION CLICK-COUNT)`. For key lookup *only the type matters*; the command reads the full event with the `e` interactive code. `doc/lispref/commands.texi:1608-1628`.
- **Fact.** Type symbols: `mouse-1`, `mouse-2`, …, wheel events; modifiers `A- C- H- M- S- s-` prefix. A click fires on release at the same character position. `commands.texi:1630-1668`.
- **Fact.** `down-mouse-1` fires on press. Unbound down events are ignored by `read-key-sequence`, so you only define them to start tracking motion. `commands.texi:1911-1933`.
- **Fact.** `drag-mouse-1` fires on release at a different character position; the event is `(drag-mouse-1 START-POSN END-POSN)`. An unbound drag event becomes a click at the start position. `commands.texi:1875-1909`.
- **Fact.** `double-mouse-1` / `triple-mouse-1` (and `double-down-`, `double-drag-`): the first click is delivered as an ordinary click *before* the double event, and an unbound double falls back to the single binding; triple falls back to double. Prefix order is modifiers, then `double-`, e.g. `M-double-mouse-2`. Count via `event-click-count`. `commands.texi:1935-2028`.
- **Fact.** Clicks on non-text areas get a faked prefix key, a symbol naming the area: `mode-line`, `header-line`, `tab-line`, `tab-bar`, `vertical-line`, scroll bars, margins. Default bindings: `[mode-line mouse-1]` → `mouse-select-window`, `[mode-line down-mouse-1]` → `mouse-drag-mode-line`, `[header-line mouse-1]`, `[tab-line mouse-1]`, `[vertical-line down-mouse-1]` → `mouse-drag-vertical-line`. `commands.texi:3463-3500`; `lisp/mouse.el:3812-3830`.
- **Fact.** Global text bindings: `down-mouse-1` → `mouse-drag-region`, `mouse-1` → `mouse-set-point`, `drag-mouse-1` → `mouse-set-region`. `lisp/mouse.el:3781-3783`.

### 1.2 `posn` objects

- **Fact.** A position list is `(WINDOW POS-OR-AREA (X . Y) TIMESTAMP OBJECT TEXT-POS (COL . ROW) IMAGE (DX . DY) (W . H))` for window clicks. `POS-OR-AREA` is a buffer position in text, otherwise the area symbol. `OBJECT` is `(STRING . STRING-POS)` when the click hit a string from a text property or overlay. `commands.texi:1676-1760`.
- **Fact.** Frame-level clicks (tab bar, tool bar, border) are `(FRAME PART (X . Y) TIMESTAMP OBJECT)`; for tab-bar `OBJECT` is the propertized string of the clicked tab. `commands.texi:1810-1873`.
- **Fact.** Accessors: `event-start`, `event-end`, `posn-window`, `posn-area`, `posn-point`, `posn-x-y`, `posn-string`, `posn-object`; keyboard events answer the same accessors with zero/nil. `commands.texi:2997-3100`.

### 1.3 How the keymap for a click is chosen

- **Fact.** A key sequence that starts with a mouse event is read with the keymaps of **the buffer in the window under the pointer, not the current buffer**, and the `keymap` / `local-map` text and overlay properties are looked up **at the event position instead of point**. A `display`/`before-string`/`after-string` string's own `keymap` or `local-map` overrides the underlying text's. `commands.texi:1623-1628`; `doc/lispref/keymaps.texi:1121-1160`. C code: `src/keyboard.c:8695-8720` uses `get_local_map (PT, …, Qkeymap)` for the position.
- **Fact.** Precedence otherwise unchanged: transient/overriding maps, `keymap` property, minor modes, local map (or `local-map` property), global map. `keymaps.texi:1043-1100`.
- **Fact.** Mode-line and header-line strings carry their own `keymap` / `local-map` properties; that is how mode-line segments are clickable (`doc/lispref/modes.texi`, mode-line section; not re-read line by line: **Unverified** detail).
- **Fact.** `mouse-face` is a text/overlay property: the display engine applies its face while the pointer is over the text; pair it with `help-echo`. `doc/lispref/text.texi:3618-3640`, `4280-4296`. So in Emacs hover highlight is a property of the *content*, painted by the display engine without running Lisp.
- **Fact.** `mouse-1-click-follows-link` (default 450 ms): a `mouse-1` click on a "link" (text with `follow-link` property or `mouse-face`) is rewritten to `mouse-2`, unless held longer than 450 ms. Implemented in `key-translation-map` with `down-mouse-1`/`mouse-1`/`double-mouse-1` entries. `lisp/mouse.el:68-75`, `150-206`; `text.texi:4260-4380`.

### 1.4 How a click selects a window

- **Fact.** Clicking does **not** inherently select a window or its buffer; that is entirely up to the command bound. `mouse-select-window` (`lisp/mouse.el:792`) and `mouse-set-point` / `mouse-set-region` call `select-window (posn-window (event-start click))`. `commands.texi:1623-1628`.

### 1.5 How commands read the event

- **Fact.** `(interactive "e")` passes the event. Inside, use `(event-start event)`, `(posn-window …)`, `(posn-point …)`; for drag-aware commands use `event-end`. Example: `dired-mouse-find-file-other-window`, quoted at `text.texi:4298-4330`. `mouse-set-point` deliberately uses `event-end` so it works for clicks and drags: `lisp/mouse.el:1586-1603`.
- **Fact.** `last-command-event` holds the last input event of the key sequence that called the command (`src/keyboard.c:13739`). Tuna's `Keys` contract already has `last-command-event`, but typed as `key-event` only (`tuna/services/keys.ss`, `last-command-event`).

### 1.6 What carries over to Tuna

Tuna reports a click on a stable part id, not a screen position. Mapping:

| Emacs | Tuna (Inference) |
|---|---|
| `mouse-1`, `C-mouse-1`, `double-mouse-1`, `drag-mouse-1`, `down-mouse-1` | Keep the names and the `<mouse-1>` key syntax (`keymap-set` already uses `<...>`; the lispref example uses `(keymap-set map "<mouse-2>" …)`, `text.texi:4338`). The **server** builds the symbol from raw button/modifier/count/kind facts. |
| `posn` | A `posn` struct: `{view, part, area, node, offset}`. `part` replaces `window`+position; `area` is the part kind (`tab`, `status-line`, `split-handle`, `node`, `container`); `node` is the node under the pointer; `offset` is `#f` until text nodes exist. |
| Area prefix keys (`mode-line`, `tab-line`) | Part kind as a prefix key: `"<tab> <mouse-1>"`, `"<status-line> <mouse-1>"`, `"<split-handle> <drag-mouse-1>"` in the global map. Same extensibility as Emacs, plugin-owned bindings. |
| `keymap`/`local-map` property at the click position | Keymaps on the *clicked node and its ancestors* (ADR 8 already lists "keymaps of the focused node and its ancestors"; for a click, "clicked" replaces "focused", exactly as event position replaces point). Then view's buffer map, minor modes, global. |
| Keymap of the buffer under the pointer, not the current buffer | Use the clicked part's view and buffer, not `selected-view`. |
| Click does not select | Same: the default `<mouse-1>` binding on a view part is a command `select-view`; plugins may bind otherwise. |
| double/triple fallback, drag → click fallback, down ignored if unbound | Keep exactly; it is free once lookup works on symbols. |
| `mouse-face` | CSS `:hover` on elements the renderer marks (section 4). |
| `mouse-1-click-follows-link` | Not needed for buttons and tabs (mouse-1 is the activation). Needed only for links *inside text*; ADR 8's translation stage can host the same key-translation hack later. |
| Pixel `(x . y)`, `(col . row)`, `image` fields | Drop. Layout belongs to the browser (ADR 7). Keep `x,y` only as optional `client-x/y` for popups anchored to a click. |

---

## 2. Datastar idioms for pointer input

### 2.1 Facts about the current Tuna transport

- **Fact.** Keyboard: `data-on:keydown__document__capture="@tunaKeyboard()"` on `<html>` (`tuna/plugins/web.ss:112`). The action (`frontend/tuna-keyboard.ts`) pushes an item with `version`, `clientId` (per tab, `sessionStorage`), `sequence` (per tab, increasing across reloads) onto a **local FIFO queue** and a drain loop sends one `fetch('/commands')` at a time, so the browser never has two in flight. The server validates strictly and builds a `key-event` (`web.ss:283-304`).
- **Fact.** Security: Host/Origin checks and the launch-token cookie on every route (`web.ss:181-230`; ADR 10, "Authentication"). ADR 7: "pointer events also carry the revision of the screen they were computed against."
- **Fact.** The server tracks a screen `revision` (`web.ss:41,77`), but the rendered `main#screen` carries no revision attribute (`html-renderer.ss:230`). The client cannot yet report it. (Gap.)
- **Fact.** Existing markers: container `id="container-N" data-container="N"` (`layout.ss:75-81`); view `section.view data-view="N"` (`html-renderer.ss:209-212`); nodes `id="view-V-node-M" data-node="M"` (`html-renderer.ss:69-76`). Tabs (`li.tab`) and the status line have **no** id or data attribute (`layout.ss:92-99`, `html-renderer.ss:216`). (Gap.)

### 2.2 Facts about Datastar and the community

- **Fact.** `@post` (and `@get`…) **aborts any earlier in-flight request issued from the same element** (`library/src/plugins/backend/actions/fetch.ts:36-38`; the shipped v1.0.2 bundle contains `abort()` calls too, not read in detail). With one delegated element issuing `@post`, a second pointer event would cancel the first. Also `@post` ships all non-`_` signals as JSON body (`docs.md:977`), not Tuna's item format.
- **Fact.** `data-on` expressions have `evt` and `el` (`library/src/plugins/attributes/on.ts`, `argNames: ['evt']`; `docs.md:1559` uses `el.classList`). Modifiers: `__window`, `__document`, `__capture`, `__prevent`, `__stop`, `__throttle`, `__debounce`, `__passive` (`docs.md:1925-1962`). In the RC source, untrusted (synthetic) events are ignored unless `__trusted`; I did not find `isTrusted` in the v1.0.2 bundle, so **Unverified** for v1.0.2.
- **Fact.** hyperlith's billion_cells puts **one** `data-on:mousedown` on the morphed `main#morph`; it reads `evt.target.dataset.action` (a *handler URL path*, set per clickable element), copies `data-id`s of the target and its parents into signals, then `@post`s to that path (`examples/billion_cells/src/app/main.clj:446-454`; elements: `:data-action handler-focused` at 338/344/494). So hyperlith is delegation + generic routes + ids; the "routes" are a fixed handler set, not per element. Its README recommends `pointerdown`/`mousedown` over `click` for snappier feel (`README.md:84`).
- **Fact.** Delaney (Datastar author), 2026-02-18, #help "spa like navigation": "use semantic elements as intended", and for non-anchor use "a span with the mousedown or whatever" (Discord links in thread `1473426251309125702`, msgs `1473829776148926538`, `1473830044349632594`). thefiddler adds that `<a>` gives middle-click / ctrl-click behaviour that a `<div>` does not (`1474045476461609055`).
- **Fact.** Datastar's guide says logic that does not fit `data-*` belongs in external scripts or web components, "preferably using Rocket" (`docs.md:909-913`). Tuna already follows this with `frontend/`.

### 2.3 Comparison

**(a) One delegated pointer handler, posting "pointer event on part X" through Tuna's queue.** Listener on `<html>` (never morphed; keyboard already lives there) or on `main#screen`. A new action `tunaPointer` in `frontend/` shares the keyboard queue, `clientId` and sequence counter. Item names the nearest `[data-part]` ancestor.

**(b) `data-on:click="@post(...)"` per element**, either to the generic route with an id (b1) or to per-element server-created routes (b2).

| Criterion | (a) delegated + shared queue | (b1) per-element `@post` to `/commands` | (b2) per-element routes |
|---|---|---|---|
| Ordering vs keyboard | **Fact** the keyboard queue is strictly sequential; sharing it gives total client order. Inference: the same sequence counter makes order checkable on the server. | `@post` bypasses the queue, so a key typed just after a click can overtake it, and `@post` has no `sequence`. Fixable by calling a custom action instead (then it is (a) with more markup). | Same as b1, plus one route per element. |
| Security (ADR 10) | One route, one validator (extend `parse-key-event`), part id parsed server-side and checked to exist. Client names no command. | Same route, but Datastar's body is signals JSON; needs a second parser or a custom action. | **Inference:** the route table grows every redisplay and must be pruned; each route is a capability URL needing its own unguessable token and expiry; a stale route is a replay surface. Worst option. |
| Stale clicks after a morph | Part ids are stable (ADR 13 identity); resolve at receipt, drop with an echo-area note if gone. Per-part revision (ADR 13 stamps changed nodes and ancestors) lets a command refuse if the part changed after the screen the click saw (Inference). | Same, if the id is sent. | Route may be absent (404) or point at changed state; handling is ad hoc. |
| Macro recording, `describe-key` | **Inference:** all pointer input funnels into the one input-session resolver (ADR 8), so recording, "describe next key", prefix state, `unread-command-events` and transient maps see pointer events the same way as keys. | Only if b1 posts the same item shape. | Bypasses the session; the route would have to re-enter it. Breaks "client never names a command" in spirit. |
| User rebinding | Pure keymap change, server-side. | Same if routing goes through keymaps. | Route must re-resolve every time; rebinding means nothing at the route level. |
| "Is clickable" in the browser | Renderer emits `data-clickable` (or a class) only where a binding exists (2.4). | Same; the attribute itself (`data-on:click`) is a natural marker but it is per-element markup the HTML reuse cache must carry. | Same, plus the route. |
| Idiom | **Fact:** matches hyperlith's delegated `data-on:mousedown` and Delaney's "span with mousedown" advice. | **Fact:** the textbook form in the docs (`data-on:click="@post('/x')"`, `docs.md:1374`), right for ordinary apps. | Not seen in hyperlith or docs. |
| Cost | One listener; HTML for each part is unchanged when bindings are unchanged. | Attribute on every clickable part, in every morph. | Same plus route bookkeeping. |

**Recommendation (Inference supported by the above):** (a), implemented as a custom action `tunaPointer` (not `@post`), because (i) it keeps the existing ordered queue and sequence numbers, (ii) `@post` per-element abort and signal payload do not fit, (iii) every pointer event passes the same resolver as keys. Attributes can still *call* `@tunaPointer(...)` where the markup must start a drag (section 3), so the Datastar-attribute style is preserved.

### 2.4 "Clickable" marking

- **Inference.** The renderer should ask the keys service whether the clicked-part chain has a `<mouse-1>` (or double/drag) binding *beyond the global fallbacks*, and emit `data-clickable` (plus `data-draggable`, `data-drop-accepts`) only on parts whose own or ancestor node keymap binds one. Global fallbacks (select-view on any view click) should **not** mark everything.
- **Inference (cost).** ADR 13 keys HTML reuse on node revision, view state, and display-wide settings. A keymap change must therefore count as a display-wide input (like `face-remapping`), or a rebind will not repaint markers until the node changes. Simplest: a "keymap generation" number in the key.
- **Inference (accessibility).** Render real `<button>` (with `tabindex="-1"`) or `role="button"` for clickables so screen readers announce them. A keyboard activation yields a `click` with `detail === 0` (**Unverified**); the same listener should treat it as `mouse-1` on the part.

---

## 3. Dragging

Owner decision (STATUS): one input item on drop; the drag must still look good, using Datastar attributes and CSS.

- **Fact (community).** Anders: "Most of this can be solved with animations … and ghosting (drag drop API gives you this for free)" (2026-07-05, thread `1517172213441106032`, msg `1523189359912681472`); "I've also done no signals drag drop using the web browser API", and he credits William with a desktop-window-manager UI built that way (2025-12-30, #rocket, msg `1455603676419981536`). William: sending every move to the server meant "hundreds of HTTP requests per second… you should NOT do that" (msg `1455604928054689852`, `…605308100575242`). Delaney points to the Rocket "flow" example for client-local dragging (2026-07-04, same thread). Anders also linked `data-star.dev/examples/sortable` (2025-02-12, msg `1339340249326686238`); he calls it a sortable.js example. I did not find a drag example in the local Datastar checkout (**Unverified** what the website example contains).
- **Fact.** Hyperlith uses "client side … drag column resizing" (Anders, 2025-11-14, #data-clojure, msg `1438942302885380277`); I did not locate that code in the local examples.

### 3.1 Two drag kinds, two mechanisms (Inference)

1. **Resize a split border** (continuous, no drop target): Pointer Events with pointer capture.
2. **Move a tab or part to another container** (discrete targets): either pointer events with capture and `elementFromPoint`, or the HTML5 Drag and Drop API (`draggable`, `dragstart`, `dragover`, `drop`), which gives the ghost image and target events for free (Anders). Cost: no custom ghost styling, poor touch support (**Unverified**), and no continuous preview of layout change. Start with HTML5 DnD for tabs (simplest, matches Anders); move to pointer events if the owner wants a live "tab slides into place" preview.

### 3.2 Pointer capture and local preview

- **Unverified (platform knowledge).** `el.setPointerCapture(evt.pointerId)` on `pointerdown` redirects later `pointermove`/`pointerup` to that element even when the pointer leaves it; `pointercancel` or `Escape` aborts. CSS `touch-action: none` on the handle prevents the browser claiming the touch for scrolling.
- **Fact.** Expressions can reach `el` and `evt` (`docs.md:1559`), so a handle can be pure attributes:
  `data-on:pointerdown="el.setPointerCapture(evt.pointerId); $_drag = 0"`, `data-on:pointermove="$_drag !== null && ($_drag = evt.clientX)"`, `data-on:pointerup="@tunaPointer('drop', ...)"`.
  `_`-prefixed signals are local and never sent (`docs.md:977`, `2187`).
- **Inference.** Drive the preview with a CSS custom property, not layout: `data-style:--drag-x="$_drag"` (or `el.style.setProperty`), and a rule that uses it (`transform: translateX(var(--drag-x))` on a ghost line, or `flex-basis` on the neighbours). Style-only changes cost no server round trip.
- **Inference.** Server wins on the next morph. If the preview is an inline style or class that the morph rewrites, the browser cannot drift (ADR 13: "browser can drift out of sync" is the owner's concern). Tradeoff: between drop and morph the element may snap back for a frame. Mitigation: keep the preview until the next morph and let the morph overwrite it; `data-ignore-morph` (`docs.md:1794-1804`) on the *ghost only* if it must survive an unrelated morph during the drag.
- **Inference (important).** Redisplays continue during a drag (other clients, timers). Anything under the pointer that a morph replaces loses capture if the *element* is replaced, though idiomorph normally preserves element identity when the id matches (**Unverified**). Handles must keep stable ids (`container-N-handle-K`).

### 3.3 Drop targets and the drop item

- **Inference.** Targets are found by `closest('[data-part]')` on the element under the pointer (`document.elementFromPoint`, because captured events target the captured element) and, for containers, by an `edge` computed from the pointer's position in the target's box: `before | after | inside` or `left | right | top | bottom` for splits. This is layout the client owns (ADR 7).
- **Item** (kind `drop`): `{kind:"drop", from: "<part string>", to: "<part string>", edge, button, modifiers, fraction?}`. For a split-border resize, `from` is the handle, `fraction` is the new share (pointer offset / container length) as a number in `[0,1]`; the server clamps. The item carries **facts, not intents**: the server picks the command by looking up `<drag-mouse-1>` through the keymap chain from `from`, with `to` and `edge` in the end posn (mirrors Emacs's `(drag-mouse-1 START END)`).
- **Inference.** Mark valid drop targets on the server (`data-drop-accepts="tab"`), so illegal drops (a container into itself) show no highlight. Client-side `dragenter`/`dragleave` toggle a `_`-signal or a class for the highlight.
- **Inference.** If `down-mouse` bindings are ever used for non-drag actions, the shared queue should send a `down` item only on parts marked `data-pressable`; do not send every press.

---

## 4. Hover and polish

- **Pure CSS (Inference, standard CSS):** `:hover`, `:active`, `:focus-visible`, `cursor: pointer | col-resize | grab`, transitions, `[data-clickable]:hover`, `:has()`, `touch-action`, `user-select: none` on chrome, `title` as the `help-echo` analog. This is Emacs's `mouse-face`, with no server involvement. Matches the owner's polish decision (STATUS, "Polish matters").
- **Server-rendered state:** `aria-selected` (already on tabs, `layout.ss:95`), `data-selected` on views (`html-renderer.ss:212`), disabled/locked, active tab, `data-clickable`, `data-draggable`, `data-drop-accepts`. These change only when the state changes, so the HTML-reuse cache applies.
- **Needs the server or a Rocket component:** hover that depends on content the client lacks (hover cards, lazily computed `help-echo`). Not for now; if needed, a throttled `pointerenter` item on marked parts.
- **Keeping focus on Tuna's input (Fact + Unverified).** Fact: keys are captured on `document` in capture phase and `preventDefault`ed unless composing (`tuna-keyboard.ts`), and there is no hidden input proxy yet (`page-html` in `web.ss:107-123`). Clicking a non-focusable element leaves `document` receiving keydown, so nothing breaks today. Inference: `<button>`s steal focus (browser-dependent, **Unverified** on Safari), so call `preventDefault()` on `mousedown` / `pointerdown` for clickable parts and give them `tabindex="-1"`; when the input proxy exists, `focus()` it after pointer handling, except on touch (avoids popping the soft keyboard). Exempt text nodes later: `preventDefault` on mousedown stops native text selection.

---

## 5. Text nodes: what to leave open (out of scope)

Not designing; only so nothing is painted into a corner:

- **Item shape must be extensible.** `kind` is an open set (`click`, `drop`, later `down`, `move`, `up`, `drag`), plus an optional `offset` field. A selection drag in text needs live feedback; either throttled `move` items, or a Rocket component (CodeMirror-like) owning selection and reporting only the result as events (ADR 7's "props down, events up"). Do not hard-code "drops only" into the server protocol.
- **Part strings need to name a node and an offset.** `view-V-node-M` ids already exist (`html-renderer.ss:69-76`). Offsets into text will want character-offset attributes on spans/lines; `revision` (ADR 7) is essential there because an offset is only meaningful for one text revision. Per-part revision checks (section 2.3) generalise to this.
- **`posn` has an `offset` slot from day one**, `#f` for non-text parts (section 1.6), mirroring `posn-point`.
- **Scope `preventDefault` and `user-select: none` by part kind**, never globally, so native selection and IME stay available inside text.
- **Double/triple click counts** come from the platform's click `detail` (**Unverified**) and the server derives `double-mouse-1` etc.; word/line selection then lives in commands, as in Emacs (`mouse-set-point` with `promote-to-region`, `lisp/mouse.el:1586-1600`).
- **Links in text** reuse `follow-link` semantics via the translation stage (section 1.6).

---

## Recommended design for Tuna

- **Input item.** `{version:1, type:"pointer", clientId, sequence, revision, kind:"click"|"drop", button, clicks, modifiers:{alt,ctrl,meta,shift}, target:"<opaque part string>", from?, to?, edge?, fraction?, offset?}`. Same queue, same `clientId`, same `sequence` counter as keydown. The server validates every field (as `parse-key-event` does), checks the part exists, and turns raw facts into an event symbol (`mouse-1`, `C-double-mouse-1`, `drag-mouse-1`) and a `posn`. The client never sends a command name.
- **Listener.** One `data-on:click__document` (and `pointerdown`/`pointerup` only for marked drag handles) on `<html>` calling `@tunaPointer`, in `frontend/` beside `tunaKeyboard`. Every renderable part carries `data-part="<kind>:<ids>"` (add to tabs, status line, handles; keep the existing ids).
- **Keymap lookup.** Resolve from the clicked part upward: node keymaps → buffer/view local → containers → minor → global, with the part *kind* as a faked prefix key (`"<tab> <mouse-1>"`). Double → click and drag → click fallbacks as in Emacs. Default global `<mouse-1>` selects the clicked view, matching Emacs's `mouse-select-window` (click ≠ implicit selection). `last-command-event` widens to `input-event`; `defcommand` gets an `event` argument kind; `event-start`/`event-end`/`posn-*` accessors.
- **Dragging.** Pointer capture plus `touch-action:none` for split borders, HTML5 drag and drop for tab/part moves; local `_`-signals and CSS custom properties for the preview, with the next morph as the source of truth; one `drop` item carrying `from`, `to`, `edge`, and `fraction`.
- **Hover.** Pure CSS for `:hover`/`:active`/`cursor`; server-rendered `data-clickable`, `data-draggable`, `data-drop-accepts`, `aria-*`; markers only where a non-global binding exists; keymap generation joins the HTML-reuse key.
- **Focus.** `preventDefault` on `mousedown` for clickable parts, `tabindex="-1"`, refocus the input proxy when it exists.

## Genuine owner decisions

1. **Click on press or on release?** Hyperlith favours press for snappiness (`README.md:84`); Emacs fires `mouse-1` on release and `down-mouse-1` on press. **Recommend release** for `mouse-1` (cancellable, matches buttons and Emacs); add `down-` only on `data-pressable` parts.
2. **Tab/part moves: HTML5 drag and drop or pointer events?** **Recommend HTML5 DnD first** (free ghost, matches Anders), switch if the live-slide preview matters more than touch support. Resize handles always use pointer capture.
3. **Adopt Emacs event names and area-prefix keys (`"<tab> <mouse-1>"`)?** Divergence from Emacs would need an ADR and a line in `docs/emacs-equivalents.md`; this proposal keeps Emacs names, so only the `posn` shape differs. **Recommend adopting.**
4. **Mark clickables only where a non-global binding exists**, versus marking everything with a global fallback. **Recommend the former**; it requires keymap generation in the HTML-reuse key.
5. **Stale clicks.** Drop silently, drop with an echo message, or run unless the part's revision is newer than the screen the click saw. **Recommend part-revision refusal with a one-line echo message** for commands that opt in; run otherwise.

## What is shallow

- Emacs's mode-line `keymap` string property behaviour and `describe-key`/keyboard-macro handling of mouse events were not read in source; section 1 claims about them are inference.
- Not verified against v1.0.2: `isTrusted` filtering, abort-per-element exactness, idiomorph element identity during captured drags, `data-style` availability and `--var` handling.
- Platform claims (pointer capture, `touch-action`, `click.detail`, focus-on-click per browser, HTML5 DnD on touch) are standard but not checked against MDN or a browser here.
- I did not read ADR 10 beyond its authentication paragraph, `agents/research/capability-audit/` on mouse, or the actual Datastar `sortable` / `rocket_flow` example sources; no drag example was found locally.
- No browser prototype was run; flicker between drop and morph, and morph interaction with an active pointer capture, need a spike (one split handle and one tab drag) before the brief.
- The Discord index failed to load one 58 MB channel export (`general`, JSON error), so searches may miss messages from that channel.
