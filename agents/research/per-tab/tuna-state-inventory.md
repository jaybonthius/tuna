# Tuna mutable-state inventory for per-tab frames and input sessions

Read-only research at `main` `33b2163` (2026-10). Citations are `path:line` relative to `/home/jay/Code/workbench-gerbil/tuna` unless they name another tree. **Inference** marks conclusions that I drew and the code does not state.

Classes used below:
- **(a) shared:** editor-wide by nature; every tab should see the same value.
- **(b) per-tab:** per connection or tab by nature: transport pacing, numbering, measurements of one browser's viewport, what one stream was sent.
- **(c) choice:** a product choice; it could be shared (mirrored, as in tmux) or per tab (as with `emacsclient -c` frames).

"Saved" means saved in a session slot (ADR 5; `plugins/session/contract.ss:26`).

## Summary

Today, every piece of selection, input and scroll state is a **single global per provider instance**: one frame, one selected view, one key prefix, one `last-command`, one scroll state per view, and one input counter. The kernel has one `Display` provider whose `redisplay!` takes no client argument (`tuna/kernel/loop.ss:58-60`). The renderer's `render-screen` takes no argument either (`plugins/renderer/contract.ss:19-22`), and the layout draws from its only frame (`plugins/layout/plugin.ss:885-897`). Nothing in the input path carries a tab identity: the page's counter is a module `let` (`plugins/web/frontend/input-sender.ts:4`). The web plugin already keeps a small amount of per-stream state (`applied`, `sent`, `sent-head`, `count`), so screen pacing is the only part that already works per tab.

### Summary table

| # | State | Lives in | Saved? | Class | Notes |
|---|---|---|---|---|---|
| 1 | Plugin registry, services, providers, cached dispatch | kernel `tuna/kernel/state.ss:19-25` | no | a | |
| 2 | Id counter `last-id` | kernel `tuna/kernel/ids.ss:6-7` | no | a | |
| 3 | Editor loop: queue, running task, waiting (suspended) tasks, `dirty?`, `last-redisplay`, quit `force-at` | kernel `tuna/kernel/loop.ss:140-154` | no | a (queue) / c (quit target) | One queue for all input; C-g interrupts whichever task runs (`loop.ss:553-562`) |
| 4 | Web: input numbering `next`, `pending`, `numbered?` | web `plugins/web/plugin.ss:68-70` | no | **b** | Reset on `GET /` (`:387`, `:416-421`): the main breakage with two tabs |
| 5 | Web: `streams` counter, `applied` per stream | web `:82-83` | no | b (already per stream) | |
| 6 | Web: `screen`, `rendered`, `revision`, `head`, `served` | web `:75-80` | no | b once screens differ per tab; today one screen for all | |
| 7 | Web: `owed` (a scroll report awaits a screen) | web `:79`, set `:486` | no | **b** | Global boolean |
| 8 | Web: `slot-numbers`, `stylesheets-seen` | web `:71-72` | no | a (URL numbering), b-ish (`stylesheets-seen`, see §2) | |
| 9 | Page: `sequence` counter; `scrollers` WeakMap (`placed`, `owed`) | `plugins/web/frontend/input-sender.ts:4`, `tuna-scroll.ts:30-31` | no (browser memory) | b | Already per tab because they live in the page |
| 10 | Stylesheet registry, `generation`, `generation-shown` | stylesheets contract `plugins/stylesheets/contract.ss:83-91`, `:228-234` | no | a (theme could be c) | |
| 11 | Key prefix `pending`, `command-event`, input targets, keymaps, generation | keys `plugins/keys/plugin.ss:35-40` | no | **pending / command-event: c (ADR 8 says per session)**; keymaps a | |
| 12 | `activation-event` parameter | keys `:202` | no | already per task | |
| 13 | `last-command` (`registry.last`); `this-command` via activation parameter | commands `plugins/commands/plugin.ss:7`, `:38-69`, `:86-90` | no | c (ADR 8: per input session) | `this-command` is already thread-scoped |
| 14 | Buffer list, buffers, nodes, texts (undo, journal, highlights), node kinds and renderers | buffers `plugins/buffers/plugin.ss:24-37`, `:204-212`, `:292-298`, `:344-348` | buffers: yes, via autosave `buffers` slot (text, point) | a | |
| 15 | Buffer point (`point-node`, `point-position`), used while not displayed | buffers `plugins/buffers/plugin.ss:294-296` | yes (autosave) | a | |
| 16 | **Selected view** (buffers registry `selected`) | buffers `plugins/buffers/plugin.ss:345`, `:424-425` | via layout slot | **c** | The source of `current-buffer`, `point` and `goto-char` |
| 17 | View: `showing`, `focus`, `position`/`revision` (point), `goal-column` | buffers contract `plugins/buffers/contract.ss:259-264` | point: yes (layout slot) | c | A view is a layout part; per-tab only if views are |
| 18 | View scroll state: `top-item`, `scroll-offset`, `last-placement` | `contract.ss:265-267` | placement: yes (layout slot) | **c** (the "fight") | |
| 19 | View measurements: `facts` (incl. width/height), `average-item-height`, `drawn-before/after` | `contract.ss:268-271` | no ("never saved", `:248-251`) | **b** | They describe one browser's viewport |
| 20 | Layout tree incl. container focus memory (`container-focus`), pins, locks | layout `plugins/layout/plugin.ss:64`, `tree.ss:57-61` | yes (`layout-tree` slot) | tree a; **focus memory c** (ADR 13:63) | |
| 21 | Frame (`part`, `start`, `selected`) | layout `plugin.ss:47-50`, `:65` | yes (`layout`/`layout-tree`) | **c** (roadmap 6: per-tab frames) | |
| 22 | Selected part `level` | layout `plugin.ss:66` | no | c (follows the frame) | |
| 23 | Frame marks | layout `plugin.ss:53-56`, `:67` | yes | a (likely; marks are named places) | |
| 24 | Locked-view requests, container kinds | layout `:68-69` | no (owners rebuild) | a | |
| 25 | Scrolling: `moved-last`, `owed` scrolls, `point-placements` per view; `before` stack; `recentered` | scrolling `plugins/scrolling/plugin.ss:196-207` | no | c (moved-last, point-placements follow the view); `owed` closures b/c; `recentered` c (follows last-command) | |
| 26 | Renderer HTML cache per view id (`view-html`: start, nodes, pinned line ids) | renderer `plugins/renderer/plugin.ss:93-99` | no | b once drawings differ per tab | |
| 27 | Minibuffer: `prompts` stack, each prompt's `shown-in`, `previous-view`, `waiting` suspension; idle buffer; histories | minibuffer `plugins/minibuffer/plugin.ss:37-57` | histories: yes (`minibuffer-history`) | prompts **c**; histories a | |
| 28 | Echo area: `text`, `home` buffer; target chosen by nearest the selected view | echo-area `plugins/echo-area/plugin.ss:15-23` | no | c | |
| 29 | Completion `sessions` stack (input, candidates, selected, origin view copy, ui) | completion `plugins/completion/plugin.ss:59-66` | no | c (tied to its prompt) | |
| 30 | Completion-vertical `displays` per prompt buffer | `plugins/completion-vertical/plugin.ss:14-17`, `:79` | no | c (follows the prompt) | |
| 31 | Help: last `output`, `*Help*` buffer | `plugins/help/plugin.ss:18-20` | no | a | Where it is displayed depends on the selected view (c) |
| 32 | Settings registry (globals, scopes); `current-setting-bindings` parameter | `plugins/settings/plugin.ss:10-12`; contract `:34` | no (config) | a; `mac-option-modifier` arguably per device (c) | |
| 33 | Session store (slots, entries, written) | `plugins/session/plugin.ss:41-51` | it *is* the store | a | |
| 34 | Autosave `written` | `plugins/autosave/plugin.ss:19-20` | — | a | |
| 35 | `children-items-kept` (weak cache of item counts) | buffers contract `contract.ss:674` | no | a | |
| 36 | Advice list, plugin options, boot/eval module state | `tuna/lib/advice.ss:44`, `tuna/lib/plugin-options.ss:70-79`, `tuna/boot.ss:540,1258,1263` | no | a | |

## 1. State by layer, with readers and writers

### Kernel (`tuna/kernel/*`)

- **Kernel record** (`tuna/kernel/state.ss:19-25`): plugins, services, providers, cached services, and the loop. It is reached through the `current-kernel` parameter (`:37`). Class (a).
- **Editor loop** (`tuna/kernel/loop.ss:140-154`): `pending`/`pending-tail` (one input queue), `resumes`, `results`, `waiting` (suspended tasks such as `read-string`), `running`, `dirty?`, `last-redisplay`, `quit-grace`, `force-at`. Class (a), except who a quit targets.
  - Input enters through `input-submitter` (`:216-224`), which asks the `Input` provider's `arrival` to choose `'queue` or `'interrupt`.
  - `on-interrupt!` (`:553-562`) raises quit in **the running task, whoever started it**. With no task running, it queues the item.
  - `discard-input` (`:327`) drops **every** queued input item.
  - Inference: once tabs have separate input sessions, the quit and discard policy becomes a product choice; the kernel itself needs no change, because the policy lives in the `Input` provider and in what the web plugin submits.
- **Services `input` and `display`** (`loop.ss:44-69`): exactly one provider each. `Display.redisplay!` takes no argument (`:58-60`); `(redisplay)` calls the provider (`:273`). So **"which tab" cannot pass through the kernel's display path today**. Inference: a per-tab renderer can stay inside the web plugin, which calls the renderer once per stream, without changing the kernel.
- **Task parameters**: `current-task` (`tasks.ss:47`), `current-context` (`plugins.ss:75`), and `held-quit`/`pending-events`/`announcing?` (`plugins.ss:276-312`). These are already per task or per operation.
- **`last-id`** (`ids.ss:6-7`): class (a).

### Web transport (`plugins/web/plugin.ss`, frontend)

See §2 for the full mechanism. Fields are at `:62-87`:
- Per tab by nature: `next`, `pending`, `numbered?`, `owed`, `applied`, `streams`.
- Per tab once screens differ: `screen`, `rendered`, `revision`, `head`, `served`.
- Shared: `slot-numbers`, `host`, `origin`, `timeout`, `server`.

Page state:
- `sequence` (`frontend/input-sender.ts:4`), which `send` increments (`:7`).
- Per-scroller `{placed, owed}` (`frontend/tuna-scroll.ts:30-31`).
- The scroll report carries the view id, the scroller's root node, the placement number, the screen revision and **the viewport `width`/`height`** (`tuna-scroll.ts:112-151`). These become `scroll-event-viewport-width/height` (`plugins/keys/contract.ss:150-151`), parsed at `plugins/web/plugin.ss:643-691`.

### Keys (input plugin; `plugins/keys/plugin.ss`)

- `global-keys` (`:35-40`):
  - `keymap`: the global map. Class (a).
  - `click-resolvers`. Class (a).
  - `targets`: the input-target stack. No pusher outside tests today. ADR 8 places it in the input session. Class (c).
  - **`pending`**: the keys typed so far of a prefix. Written at `:213`, `:235`; read at `:225`, `:270`.
  - **`command-event`**: the last key or pointer event. Written by `complete-keys!` (`:211-214`).
  - `generation`.
- `activation-event` (`:202`) is a parameter bound per resolved task (`:204-209`, `:296-298`). `last-command-event` reads it, falling back to the global field (`:381-382`). It is per task already.
- `focused-node` (`:151-155`) starts key lookup from **the global `(selected-view)`**. `clicked-node` (`:158-161`) starts from the clicked `posn`.
- Prefix echo messages (`(message "C-x-")`, `:236`; `"… is undefined"`, `:244`) go to the echo area chosen from the selected view.
- A scroll report changes no key state (`:287-299`).

### Commands (`plugins/commands/plugin.ss`)

- `command-registry.last` (`:7`) is the editor-wide `last-command`. It is set when an activation completes (`:66-69`).
- `this-command` comes from the `current-activation` parameter (`:43`, `:86-87`), so it is per task.
- ADR 8 puts `last-command` in a per-client input session ("Initially all clients share one session"; `agents/adr/0008-input-keymaps-and-command-composition.md:11`).
- Readers of `last-command`:
  - undo continuation (`plugins/basic-editing/plugin.ss:81`);
  - the goal column (`basic-editing/plugin.ss:29`);
  - the `C-l` cycle (`plugins/scrolling/plugin.ss:494`).

### Buffers (contract `plugins/buffers/contract.ss`, plugin `plugins/buffers/plugin.ss`)

**Shared objects:**
- Texts (`plugin.ss:24-37`): store version, revisions, journal, undo list, `last-undo-task`, decorations.
- Nodes (`:204-212`) and buffers (`:292-298`): name, root, the buffer's own point, buffer-local settings.
- The buffer list (`:344`) and node kinds and renderers (`:346-347`).

**`buffer-registry.selected`** (`plugin.ss:345`; accessors `:424-425`) is the **single selected view**.
- The contract wraps it: `selected-view`/`set-selected-view!` (`contract.ss:1149-1155`). Only the layout writes it, in `settle-selection!` (`plugins/layout/plugin.ss:185`).
- Every "current" helper derives from it:
  - `current-buffer` (`contract.ss:1157-1159`)
  - `switch-to-buffer`
  - `current-text-node`
  - `current-text`
  - `point`
  - `goto-char`
  - `insert`
  - `goal-column` (`:1161-1204`)
- **Contradiction with ADR 4:** ADR 4 says "`current-buffer`, match data, and similar per-command context are thread-scoped values" (`agents/adr/0004-state-ownership.md:16`). In the code, `current-buffer` is not thread-scoped; it reads the global selected view.

**The view** (`contract.ss:259-273`) is a mutable object:
- Point: `showing`, `focus`, `position`, `revision`, `goal-column`.
- Scroll state: `top-item`, `scroll-offset`, `last-placement`.
- Measured or derived: `facts` (`placement`, `root`, `last-visible`, `visible-count`, **`width`, `height`**; `:237-243`), `average-item-height`, `drawn-before`, `drawn-after`.

The contract's own comment says the measured fields are "derived state, never saved", and that they live on the view "so the renderer can read them without a service of their own" (`:244-258`).

**Writers of scroll state:**
- `set-view-scroll!` (`:1105`; "a page loaded later puts V where it is"), from `view-scrolled!` in scrolling.
- `place-view!` (`:1120`), from commands and restore.
- `set-view-facts!`, `set-view-average-item-height!`, `set-view-drawn-items!` (`:1130-1147`).

**Saved state:**
- Buffer text and point: the autosave `buffers` slot (`plugins/autosave/plugin.ss:139-142`). On restore it sets the point of the selected view (`:128-130`).
- View point and placement: the layout slot (`saved-view-data`, `plugins/layout/contract.ss:76-94`).

`children-items-kept` (`contract.ss:674`) is a weak cache keyed by node. Class (a).

### Layout (`plugins/layout/plugin.ss`, `tree.ss`, contract)

- `tree-layout` (`plugin.ss:64-70`):
  - `root`: the frozen tree.
  - **`frame`**: a `frame-state` of `part`, `start` and **`selected`**, defined at `:47-50`.
  - **`level`**: the selected part, i3's "focus parent".
  - `marks`, `locked`, `kinds`.
- The contract says "The frame (there is one)" (`contract.ss:7`). `current-frame-target`, `move-frame`, the frame-mark operations and `render-layout` all act on that single frame (`contract.ss:315-332`).
- **Container focus memory**: `container-focus` lives in the tree (`tree.ss:57-61`; `focused-link`/`focused-leaf` at `:148-157`). It is therefore saved and shared, and `settle-selection!` rewrites it on every selection (`plugin.ss:181`, `select-path`).
  - ADR 13 states the conflict: "Frames shared by several tabs may later disagree about container focus memory; settled with per-tab frames" (`agents/adr/0013-views-layout-and-frames.md:63`).
  - The buffers/views/layout brief says the same (`docs/briefs/2026-10-buffers-views-layout.md:86-88`).
- **Saved:**
  - The `layout` slot (neutral, v2) holds views, the selected view id and marks (`plugin.ss:398-407`).
  - The `layout-tree` slot holds the tree (container focus included), `frame part start selected`, and marks (`:508-513`). Both are registered at `:914-920`.
  - `level` is not saved.
- **Anchored to the selected view:**
  - `display-buffer!` → `display-in!` (`:311-335`) reuses a visible view other than the selected one, or splits below the selected one.
  - `nearest` (`:807`) finds the minibuffer or echo-area view nearest a given view (callers pass `(selected-view)`).
  - `next-view` and `neighbor-view` start from the selected view.
  - The tab commands (`:624-658`) and `selected-part` (`:712`) do too.
- **Clicks** use `posn-view`/`posn-node` (`contract.ss:293-313`), which name a view id only. They are resolved against the single layout's `view-list`.

### Scrolling (`plugins/scrolling/plugin.ss`)

`scrolling-state` (`:196-207`) holds:
- `moved-last` (weak, per view): whether point or the view moved last.
- `owed` (weak, per view): closures for `C-v`/`M-v` deferred until the browser has measured the newest placement (`scroll-when-measured!`, `:340-343`; run in `after-report!`, `:442-451`).
- `point-placements` (weak, per view).
- `before`: a stack of point places pushed by `pre-command-hook` and popped by `post-command-hook` (`:545-555`).
- `recentered`: the `C-l` cycle position (`:494-501`).

The scroll commands act on `(selected-view)` (`:537-544`), and `point-place` uses `(selected-view)` (`:508-512`).

`view-scrolled!` (`:373-…`) finds the view **by the id the report names** (`posn-view`). It accepts a report whose `placement` is at least the view's newest placement number. It then writes the view's scroll state, facts and drawn counts. **Inference:** with two tabs, either tab's reports overwrite the one shared scroll state; this is the "fight" over scroll state.

### Renderer (`plugins/renderer/plugin.ss`, contract)

- `html-rendering.views` (`:98-99`): view id → `view-html` (`start`, kept node HTML, pinned line ids; `:93-96`). `render-screen!` (`:484-494`) drops views that were not drawn.
  - Inference: the cache key would need a tab or frame component once two tabs draw the same view differently (different drawn runs, a different selected view).
- Inputs read from global state:
  - The cursor class depends on `(eq? v (selected-view))` (`:233`).
  - The status line shows the running command for the selected view (`renderer/contract.ss:43-57`, `current-task-name`).
  - The scroller carries `data-measured-width/height` from `view-facts` (`:350-366`).
  - The placement marker id carries the placement number. A freshly loaded page runs `tunaPlace` for each view (`:370-380`).
- `rendering-view` and `rendering-lines` are parameters (`:121-125`), so they are per call.

### Minibuffer (`plugins/minibuffer/plugin.ss`)

- `minibuffer-state` (`:37-41`): the `prompts` stack, the shared prompt `keymap`, the `idle` buffer, and `histories`.
- Each `prompt` (`:43-57`) records `shown-in` (a view), `previous-view`, `previous-buffer`, `waiting` (the kernel suspension), history position and draft.
- `ask!` (`:140-171`):
  1. Picks the minibuffer view nearest `(selected-view)`, or calls `display-buffer`.
  2. Selects that view (`select-view`).
  3. Suspends the command.
- `end-prompt!` reselects `previous-view` (`:175-188`).
- `prompts-here` uses `(current-buffer)` (`:192-201`), so RET and C-g act on the prompt whose buffer the selected view shows.
- Histories are saved (`minibuffer-history` slot, `:228-230`). Class (a).
- The prompts stack is class (c). Inference: if tab B can select the prompt's view, B can answer A's prompt; whether a prompt belongs to the tab that asked is the product choice.

### Echo area (`plugins/echo-area/plugin.ss`)

- `echo-area-state` (`:15-17`): `text` (the last message) and the `home` buffer.
- `message-buffer` (`:20-23`) writes to the echo-area view nearest `(selected-view)`.
- Not saved. Class (c): either messages go to every tab, or to the tab whose command produced them.

### Completion (`plugins/completion/plugin.ss`, `completion-vertical`)

- `completion-state.sessions` (`:59-60`) is a stack.
- Each `completion-session` (`:61-66`) holds input, candidates, the selected candidate, `origin-command`, `origin-buffer`, and **`origin-view`, a `copy-view` of the selected view** (`:180`).
- `annotate-visible` (`:134-145`) **temporarily replaces the global selected view** with `origin-view` while annotators run, then restores it. Inference: this global swap would have to become a scoped binding under per-tab selection.
- `session-here` matches `(current-buffer)` (`:69-72`).
- Completion-vertical keeps `displays` keyed by prompt buffer (`completion-vertical/plugin.ss:14-17`, `:79`).
- Not saved. Class (c), following the prompt.

### Other plugins

- **help** (`plugins/help/plugin.ss:18-20`): `output` and `shown`. Class (a). It shows `*Help*` through `display-buffer`, relative to the selected view (`:44`).
- **view-commands** (`plugins/view-commands/plugin.ss:22-80`): no state. Every command reads `(selected-view)`. `mouse-select-view` selects the view a click names (`:30-35`).
- **basic-editing, hungry-delete, extended-command, command-annotations:** no state. They use `current-text`, `point`, `selected-view` and `last-command`/`last-command-event` (for example `basic-editing/plugin.ss:26-51,81`; `extended-command/plugin.ss:23-24`; `command-annotations/plugin.ss:14`).
- **buttons** (`plugins/buttons/contract.ss:23`): a global `button-keymap`. Class (a).
- **settings** (`plugins/settings/plugin.ss:10-12`): globals and scopes. Class (a).
  - ADR 9's resolution chain names a "connection; frame or client" layer (`agents/adr/0009-settings-and-scoped-values.md:14`) that is not built.
  - `mac-option-modifier` (keys plugin) is a global setting, but it describes one device's keyboard. The page sends `isMac` per event. Class (c).
- **stylesheets** (`plugins/stylesheets/contract.ss:83-91`): `slots`, `owners`, `generation`, `generation-shown`. These are module globals. `stylesheets-generation` (`:228-234`) **mutates `generation-shown` when read**. Class (a). A per-device theme (for example the demo's `C-c T` terminal theme) would be class (c).
- **session** (`plugins/session/plugin.ss:41-51`) and **autosave** (`plugins/autosave/plugin.ss:19-20`): class (a).
- **reload-config, advice-help, stylesheets-help, design-tokens, orderless:** configuration or report state only. Class (a).

## 2. How the web plugin's stream works, and what assumes one tab

**Output path:**
1. The editor loop calls `{redisplay! web-server}` (`plugins/web/plugin.ss:146-160`). It renders **one** screen (`render-screen`, `:113-117`, calling the renderer with no tab argument).
2. If nothing changed and no scroll report is `owed`, it stops there (`:155-158`).
3. Otherwise `publish-screen!` (`:164-174`) stamps a new global `revision`, stores `screen`/`rendered`/`head`/`served`, clears `owed`, and broadcasts.

**Per-stream pacing (already per tab):**
- Each `GET /screen` gets a stream number from the global `streams` counter (`:425-429`).
- Its writer loop (`:433-444`) keeps `sent`, `sent-head` and `count` in local variables.
- `await-screen` (`:181-207`) sends the **newest global screen** once this stream's `applied[stream] >= count`, or resends after `timeout`.
- Each screen is stamped `data-init="@post('/applied?stream=S&count=N')"` (`stamp-applied`, `:126-130`).
- `/applied` updates `applied[stream]` (`:449-466`). The entry is removed when the stream ends (`:446`).
- So a slow tab skips intermediate screens without holding up another tab. Pacing is already per stream.

**Revision:** one global counter. Pointer and scroll items must name a revision no newer than it (`parse-pointer-event`, `:588`; `scroller-posn`, `:623-629`). Inference: with per-tab screens, revisions would need to be per stream (or per frame) for "the screen this click was computed on" to identify a drawing.

**Input numbering (implicitly one tab):**
- The page counts from 1 per page load (`frontend/input-sender.ts:4-7`).
- `GET /` calls `restart-numbering!` (`:387`, `:413-421`), which sets `next = 1`, `numbered? = #t`, and **clears `pending`**. The comment reads "One tab only." (`:415`).
- `admit-event!` (`:505-530`) submits contiguous numbers in order:
  - It ignores numbers below `next` as duplicates (`:513-514`).
  - With more than 64 waiting items, it skips to the smallest waiting number (`:519-521`).
  - After a server restart, the first item seen sets `next` (`:509-511`).
- Inference from the code, not observed:
  1. Opening tab B resets `next` to 1 while tab A's counter is, say, 57.
  2. A's next item (58) waits in `pending`, while B's items 1, 2, … are submitted.
  3. Once B passes 57, A's held items run at once, interleaved out of order.
  4. Meanwhile, B's items that number below A's last submitted value are dropped as "duplicates" after A's items advance `next`.
  5. If B stays below, A's items accumulate until the 64-item skip.
  6. Both tabs' keys also feed one `pending` prefix in the keys plugin. The capability audit gives the example: A types `C-x`, B types `2` → `split-window-below` (`agents/research/capability-audit/01-command-loop-and-input.md:199-203`).

**`owed`** (`:79`, set `:486`, cleared `:173`) is one boolean. A scroll report from any tab forces the next redisplay to publish a new revision, which every stream then receives. A rejected report republishes the current `rendered` (`:487-490`).

**Head and stylesheets:**
- `stylesheets-seen` is one per server (`:72`). Because `changed-stylesheets` (`:218-230`) runs only on the editor thread, that is correct for a single global head.
- Each stream compares the head with its own `sent-head` (`:439-440`), so a new stream receives the head first. Per tab already.

**Page serving:** `current-page` (`:205-207`) embeds the newest global `screen`. Every new tab starts from the same screen and frame.

**Pages are identical:** ADR 7's client scope is "One browser tab, displaying the server's frame" (`agents/adr/0007-rendering-and-transport.md:29`). ADR 10 removed client identity: "One tab is assumed" (`agents/adr/0010-security-clients-and-trust.md:14`). The input brief says the same (`docs/briefs/2026-10-input-without-waiting.md:3,32`).

## 3. How commands find "the current" view and frame, and where "which tab" is needed

**Today, commands find everything from global "current" state:**
- `(selected-view)` is the buffers registry's single field, which the layout's single frame keeps equal to `frame-state-selected` (`layout/plugin.ss:176-185`).
- `current-buffer`, `point`, `current-text`, `goto-char` and `goal-column` all derive from it (`buffers/contract.ss:1149-1204`).
- The layout's single `frame` gives `current-frame-target` and `render-layout`.

**Handles that are passed rather than found:**
- The event: `activation-event` is a per-task parameter.
- The `posn` in click and scroll events, which names a **view id** and a node.
- `Prompt` handles (minibuffer contract).
- Explicit `view` arguments to layout and scrolling operations.

AGENTS.md asks plugins to "use what you were handed … instead of reaching for another service's global 'current' state". The selected-view family is the main exception.

**Places that would need a tab or frame identity:**
1. **Input admission:** numbering per tab, which requires a tab id in the item or per-stream numbering (web `:416-421`, `:505-530`; `input-sender.ts:4-7`).
2. **Input resolution:** the prefix `pending`, `command-event`, input targets and `last-command` (keys `:35-40`; commands `:7`). `focused-node` must start from *that tab's* selected view (keys `:151-155`).
3. **Command context:** `selected-view` and everything derived from it, as a task-scoped binding set from the originating tab. That would honor ADR 4's "thread-scoped" claim. It covers basic-editing, view-commands, scrolling commands, extended-command, completion's `origin-view`, help/`display-buffer`, minibuffer `ask!`, and echo-area `message-buffer`.
4. **Layout:** the frame (`part`, `start`, `selected`), `level`, and possibly container focus memory, per tab. `render-layout` must take a frame. `move-frame`, `current-frame-target` and the frame-mark jump act on "this tab's frame".
5. **Renderer:** `render-screen` must take a frame or tab (`renderer/contract.ss:19-22`). The cursor/selected flag and the HTML cache key per (tab, view).
6. **Scroll reports:** the `posn` names only a view id (`web :640-647`; `keys/contract.ss:137-151`). Per-tab scroll state needs the report's tab, plus somewhere to store per-(tab, view) scroll state, measurements and drawn counts. Today they are fields of the shared `view` (`buffers/contract.ss:265-271`).
7. **Placements:** `place-view!` numbers placements per view. A placement made by a command in tab A should reach only A, if scroll state becomes per tab. A freshly loaded tab re-applies every view's newest placement (renderer `:370-380`). The saved placement in the layout slot is one per view (`layout/contract.ss:76-94`).
8. **Clicks:** `posn-view` resolves the view id against the single layout (`layout/contract.ss:293-297`). This is fine if views stay shared. The click's `revision` check needs the tab's revision.
9. **Quit:** `arrival` → kernel `on-interrupt!` targets the running task (`loop.ss:553-562`). The minibuffer's C-g in the prompt keymap aborts the prompt in the current buffer (`minibuffer/plugin.ss:248-252`, bound at `:257`).
10. **Messages:** echo-area target selection (`echo-area/plugin.ss:20-23`).

## 4. Earlier research on multi-tab and multi-client use

All of the following is evidence, not decisions.

- **Capability audit, lane 5, corner risk 6** (`agents/research/capability-audit/05-beyond-emacs-and-browser.md:160-166`) warned that events lack a client id and that "the key-sequence state is one global". It also gave the two-tab `C-x` / `2` scenario. Its smallest change: a per-tab `client` id in `sessionStorage`; prefix state belongs to the client's input target; point and scroll live on a view.
  - Its proposed divergence 3 (`:183`): "Per-client frames over one editor … each tab owns selected window, minibuffer focus, key-sequence state … Emacs code that assumes one selected window per process works if commands execute with the originating client's context."
  - Rows 40-41 mark multiple clients and per-client prefix/minibuffer ownership as corner risks (`:77-78`).
  - Row 38 notes that HTTP/1.1 allows about six connections per host, so a seventh tab's SSE stream hangs (`:75`, inference in the source).
- **Capability audit, lane 1** (`01-command-loop-and-input.md:50`, `:154`, `:195-203`): `last-command` is per-KBOARD in Emacs, and should be per session once there are several clients. It recommends `client` plus a per-client `seq` in the item.
- **Capability audit, lane 2** (`02-buffers-text-and-display.md:146`, `:159`, `:302` OQ-3): options are mirrored with last-writer-wins, per-tab view state over shared text and windows, or fully per-tab frames. It recommended mirroring for the prototype while keeping a tab id in events.
- **Kernel contract research** (`agents/research/kernel-contract/02-emacs-input-model.md:108`, `:140`): client identity and per-client input sessions are Input/web plugin concerns; the kernel item stays opaque. This matches ADR 12's rule that the kernel never knows "clients".
- **Layout-state research** (`agents/research/layout-state/README.md:35`): a renderer can remember "last sent revision" per client and visit only newer subtrees. This is an incremental-rendering note, not a multi-tab design.
- **ADRs and briefs:**
  - ADR 8 defines the per-client input session (`0008…:11`).
  - ADR 13 defers focus-memory conflicts to per-tab frames (`0013…:63`).
  - The buffers/views/layout brief says "several browser tabs, each with its own frame. The model already allows it, but it waits for per-tab input" (`docs/briefs/2026-10-buffers-views-layout.md:86`).
  - Roadmap item 6: "Per-tab frames and input sessions; client-side reactivity where it pays off." (`docs/roadmap.md:52`).
  - Overview glossary: "Every tab shows the same frame for now" (`docs/overview.md:307`).
- **Workbench-gerbil investigations** (`agents/research/workbench-gerbil/tuna-sse-datastar-fanout-investigation.md:1-20`; `tuna-firefox-multitab-subscription-investigation.md:1-25`): the earlier runtime fanned one state out to several SSE subscribers correctly with raw TCP clients. Failures in headless Firefox and WebKit two-tab tests came from the browser or the test runner, not from Tuna. This is relevant if per-tab tests use Playwright.
- **Previous attempt** (`/home/jay/Code/workbench-gerbil/tuna-old-2026-10`, evidence only):
  - The owner's constraint then was "All browser tabs mirror that same buffer, including navigation and focus, like attaching to one tmux session. No independent per-tab state or browser-tab identity." (`plans/tuna-buffer-model/spec.md:16`).
  - The research followed that ("Independent per-tab views conflict with the owner's shared-session decision", `research/tuna-buffer-model-findings.md:69`; "mirrored literally by every browser tab", `research/tuna-buffer-model/semantics-shared-followup.md:4`).
  - It had a subscribe/unsubscribe app-state fanout (`tuna/app-state.ss:18-20`).
  - Roadmap item 6 shows that this position has since changed.
- I found no per-tab material in `agents/research/emacs-web/` or `agents/research/window-management/` (grep for tab/client/multi), beyond i3/niri focus-memory prior art in layout-state.

## Contradictions

- **ADR 4 vs code:** ADR 4 says `current-buffer` is thread-scoped (`agents/adr/0004-state-ownership.md:16`). The code derives it from the global selected view (`plugins/buffers/contract.ss:1157-1159`).
- **ADR 3 vs code:** ADR 3 says input is "enqueued per input session" (`agents/adr/0003-command-loop-and-jobs.md:14`). No input session object exists; the keys plugin's prefix and the commands registry's `last` are single globals.
- **When numbering resets:** ADR 10 says "Opening the screen stream resets the server's numbering" (`agents/adr/0010-…:14`), and the overview says the same (`docs/overview.md:64`). ADR 7 (`0007…:16`, amended 2026-10-16) and the code (`plugins/web/plugin.ss:387`, `:413-415`) reset on `GET /`. ADR 10 and the overview are stale on this point.
- **Overview line 7** still mentions "the secret link Tuna prints at start". ADR 10 removed the launch token.
- **Two copies of the selected view:** the buffers registry (`buffers/plugin.ss:345`) and the layout frame (`layout/plugin.ss:49`) both hold it. `settle-selection!` keeps them equal, and completion's `annotate-visible` swaps only the buffers copy temporarily (`completion/plugin.ss:134-145`).

## Missing evidence

- I did not open two tabs to observe the numbering interleave or the scroll fight. The scenarios in §2 and §1 (scrolling) are inference from the code.
- Whether `drawn-before/after` and `average-item-height` should be per tab or per view if scroll state stays shared is not discussed in ADR 15. ADR 15 only says "per scroller (today each view)" (`0015…:20`).
- Session-slot shape for per-tab frames: nothing exists. Whether frames are saved per tab, and how a reconnecting tab finds its frame without a client id (ADR 10 forbids `sessionStorage` ids today), is an open owner question.
- The HTTP/1.1 limit of about six SSE streams per host is an inference in the audit, and is not measured for Tuna.

## Sources

- **Kept:**
  - Code: `tuna/kernel/{state,loop,ids,plugins,tasks}.ss`
  - Code: every `plugins/*/plugin.ss` and `contract.ss` named above
  - Code: `plugins/web/frontend/*.ts`
  - ADRs 3, 4, 7, 8, 9, 10, 13, 15
  - Docs: `docs/roadmap.md`, `docs/overview.md`
  - Briefs: input-without-waiting and buffers-views-layout
  - Research: capability-audit lanes 1, 2, 3, 5; `kernel-contract/02`; `layout-state/README.md`; workbench-gerbil fanout and Firefox investigations
  - Previous attempt: old-tree spec and research
- **Deprioritized:**
  - `agents/research/emacs-web/*`: Emacs GUI frontend feasibility, nothing on multiple clients.
  - `window-management/niri`: tabbed-column UI only.
  - `tuna-old-2026-10` code beyond `app-state.ss`: a superseded architecture.

## Next steps

- Owner decisions, one per row marked (c) in the table. The most coupled set is: frame plus selected view plus `level` plus container focus memory plus per-view scroll state (whether a view is shared across tabs or each tab gets its own views).
- Before designing: decide how a tab is identified (per-stream id issued at `GET /` and echoed by the page, or `sessionStorage`; ADR 10 currently forbids client ids). Then decide whether `render-screen` takes a frame handle while `Display.redisplay!` stays argument-free, with the web plugin looping over its streams.
