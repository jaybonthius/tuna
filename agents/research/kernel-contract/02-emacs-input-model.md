# Research: Emacs's input model and Tuna's kernel input boundary

Emacs checkout: `/home/jay/Code/emacs` at `541f693ca2e8de166cfe52c39bbfc497142215e9`. Tuna: `/home/jay/Code/workbench-gerbil/tuna` (working tree, 2026-10). Fact = read in source; Inference = mine, marked.

## Summary

Emacs has exactly one input path: every kind of input becomes an *event* in one queue, and every event becomes a command through *keymap lookup* of a key sequence (`read_key_sequence` → `command_loop_1`). Menus, tool-bars, mouse clicks, and text buttons are not special actions: they are events whose key sequences start with a dummy prefix (`menu-bar`, `tool-bar`, `mouse-1` on a position carrying a text-property keymap). The "direct" call in Emacs (`button-activate` → `funcall action`) happens only *inside* a command that a keymap already selected (`push-button`). The only things the C core decides without keymaps are: queueing, the quit character (checked on arrival), and *special events* (looked up in `special-event-map` at read time). For Tuna I recommend **(c) both, unified**: the client sends only opaque, ordered input items; one `Input` service interprets all of them, including "this node was activated" items, resolving them through node-local keymaps that the *server* rendered. The kernel should hold an opaque `input-item` (client id, sequence, payload) and one arrival hook. It should not know keys, modifiers, mouse, nodes, or buttons.

## Findings

### 1. Event kinds in Emacs and how each becomes a command

1. **Claim:** Events are characters (ints with modifier bits) or symbols for keyboard input; everything else is a list `(type position ...)`. **Sources:** `doc/lispref/commands.texi:1357-1366` ("Input Events"). **Support:** direct. **Confidence:** high.
2. **Claim:** The kinds, per the manual node list (`commands.texi:1376-1396`): keyboard chars; function keys (symbols like `<left>`); mouse click `(mouse-1 POSITION CLICK-COUNT)` (also `wheel-up/down`), drag, button-down, repeat (double/triple), motion; touchscreen; focus; xwidget; misc system events. The position is a *mouse position list*: `(window pos-or-area (x . y) timestamp object text-pos (col . row) image (dx . dy) (w . h))` (`commands.texi:1630-1700`). Wheel events add clicks/lines/pixel-delta (`commands.texi:2570-2620`), pinch adds dx/dy/scale/angle. Misc events: `text-conversion`, `delete-frame`, `iconify-frame`, `touch-end`, `preedit-text`, etc. (`commands.texi:2498+`). **Support:** direct.
3. **Claim:** The mouse event's *event type* is the key-binding handle: "if there is a key binding for `mouse-1`, that binding would apply to all events whose event-type is `mouse-1`"; the position travels as data to the command (`(interactive "e")`, `event-start`, `posn-point`, `posn-string`). **Sources:** `commands.texi:1650-1660, 2997-3030`. **Support:** direct. Inference: *what was clicked* (window, buffer position, the object/string under it) is part of the event payload; the command interprets it. Context-dependent resolution happens because lookup consults the keymaps at that position (text/overlay `keymap` property, mode maps).
4. **Claim:** Raw platform events are enumerated in C (`enum event_kind`: `MOUSE_CLICK_EVENT`, `MENU_BAR_EVENT`, `TOOL_BAR_EVENT`, `DRAG_N_DROP_EVENT`, `FOCUS_IN_EVENT`, `SELECT_WINDOW_EVENT`, …; `src/termhooks.h:121-242`) and `make_lispy_event` (`src/keyboard.c:6230`) converts each to the Lisp form. Examples: `MENU_BAR_EVENT` → `(menu-bar)` for the prefix or the item's own event (`keyboard.c:7231-7240`); `TOOL_BAR_EVENT` → `(ITEM-SYMBOL (frame tool-bar))` (`keyboard.c:7245-7254`); `DRAG_N_DROP_EVENT` → `(drag-n-drop POSITION FILES)` (`keyboard.c:7225-7228`); `SELECT_WINDOW_EVENT` → `(select-window (WINDOW))`. **Support:** direct.
5. **Claim:** Menu-bar and tool-bar clicks are rewritten so they enter ordinary key lookup: "If this event is a mouse click in the menu bar, return just `menu-bar` for now"; the event's position is changed to `(menu-bar)` (`keyboard.c:3172-3200`). The keymap then has the bindings `[menu-bar edit copy]`, `[tool-bar save-buffer]` (`keymaps.texi:2903-2946, 3003`). **Support:** direct. Menu *display* is built by scanning each active keymap for the dummy prefix `menu-bar` (`keyboard.c:8690-8740`, "Look up in each map the dummy prefix key `menu-bar`"); tool-bar likewise (`keyboard.c:9636-9660`).
6. **Claim:** *Special events* bypass the key-sequence stage. In `read_char`, after reading an event, Emacs looks it up in `special-event-map`; if bound, runs `command-execute` on it immediately and reads another event (`keyboard.c:3105-3125`). Manual: they "do not echo, are never grouped into key sequences, never appear in `last-command-event` or `this-command-keys`, … may not appear in a keyboard macro, and are not recorded in a keyboard macro" (`commands.texi:4057-4075`). Bound by default: `delete-frame`, `iconify-frame`, `make-frame-visible`, `drag-n-drop`, `language-change`, `focus-in/out`, `move-frame`, `sleep-event`, `file-notify`, `dbus-event`, `thread-event`, user signals (`keyboard.c:14526-14602`). **Support:** direct. Note this is *still* a keymap lookup — only a different map, consulted at a different time.
7. **Claim:** Focus changes have two paths: `focus-in/out` are special events; per-frame focus is `select-window`/`switch-frame` events that go through the normal lookup (global bindings `handle-switch-frame`). **Support:** interpretation of `commands.texi:2340-2400` + the list above. **Confidence:** medium.
8. **Claim:** Quit is detected *on arrival*, before queueing: in `kbd_buffer_store_event_hold`, an ASCII keystroke equal to `quit_char` (after applying ctrl/meta modifiers) triggers the interrupt path rather than being queued normally (`keyboard.c:3786-3841`); `Vquit_flag` is checked in `read_char` (`keyboard.c:2805`) and by Lisp-level `quit` checks. After a quit char is read from the tty, further input is not looked at (`keyboard.c:8338-8340`, "Don't look at input that follows a C-g too closely"). The quit key is therefore a C-level integer (`quit_char`, `keyboard.c:214`), not a keymap entry; what C-g *does* when it reaches Lisp is `keyboard-quit` via the normal global map. **Support:** direct. This is exactly Tuna's `Input-quit-event?` design.

Mapping summary (inference, condensed from the above):

| Event class | Becomes a command by |
|---|---|
| char / function key | key sequence → `read_key_sequence` → `lookup` in active maps (also prefix, translation maps, `remap`) |
| mouse click/drag/wheel | event type (+ window area prefix like `mode-line`) is the key; position is event data for the command |
| menu-bar / tool-bar | dummy prefix `menu-bar`/`tool-bar` + item symbol, normal lookup in the active maps |
| special (focus, drag-n-drop, frame, signals) | `special-event-map`, executed at read time, invisible to macros and key history |
| quit char | recognized on arrival (C), then `keyboard-quit` through the keymap |
| `unread-command-events`, macro replay | pushed back as ordinary events |

### 2. Buttons, widgets, menu items: events through keymaps, with a direct call at the end

1. **Claim:** A button is a set of text/overlay properties; its `keymap` property is `button-map`, which binds `RET`, `<mouse-2>`, `<follow-link>`, `<touchscreen-down>`, `<mode-line> <mouse-2>`, and `<header-line> <mouse-2>` to the command `push-button` (`lisp/button.el:65-80, 660-663`; `display.texi:7981+`). So activation is: event → key lookup in the keymap found at the position (text-property map) → `push-button` → `button-at` → `button-activate`, which funcalls the `action` property (`button.el:247-271`) or jumps to a marker. **Support:** direct. **Confidence:** high.
2. **Claim:** `push-button` accepts either a position or an event; for a mouse event it switches to the event's window/buffer and looks up the `button` text property at the clicked position (`button.el:467-511`). The "direct action" lives on the data (the `action` property of the text, set by server-side Lisp code), not in the event. The event says *where* and *what gesture*; the buffer says what the click means. **Support:** direct.
3. **Claim:** Widgets work the same way with an extra indirection: `widget-keymap` binds `RET` → `widget-button-press`, `down-mouse-1/2` → `widget-button-click` (`wid-edit.el:1099-1113`). `widget-button-click` finds the `button` char-property at the event position, calls `widget-apply-action` → `:action` method (`wid-edit.el:700-726, 1259-1301`). If no widget is under the click, it falls back to `lookup-key widget-global-map` for the key and `call-interactively` — i.e., unresolved clicks fall through to keymaps (`wid-edit.el:1259-1300`, `1303-1311`). **Support:** direct.
4. **Claim:** Menu and tool-bar items are keymap entries `(menu-item CAPTION BINDING . PROPS)` where BINDING is a command or any function; `:enable`, `:visible`, `:filter`, `:help` are properties evaluated at display time (`keyboard.c:9339-9400, 9723-9790`; `keymaps.texi:3130+`). Selecting one produces an event, which is looked up as `[menu-bar a b]`, then `command-execute`d. **Support:** direct.
5. **Claim:** There are no direct-call paths from the platform into Lisp functions in Emacs: even a popup menu's choice returns a *key sequence* that is then looked up/executed (`read_char_x_menu_prompt`, `keyboard.c:10097+`). Direct calls (`funcall`) occur only after a command is running (button actions, widget `:action`, menu bindings that are lambdas still run via `command-execute`). **Support:** interpretation. **Confidence:** medium (I did not trace every GUI backend).

Consequences Emacs gets *for free* from this uniformity (inference from the code above, backed by the cited help functions): `describe-key` / `where-is` (`lisp/help.el:882, 1194`) work on menu items and mouse clicks because they are key sequences in maps; remapping (`remap` dummy prefix, `keymaps.texi:1899`) and user rebinding apply to menus/buttons too (`button-map` is just a keymap, `mouse-2` can be rebound); keyboard macros (`macros.c`, `kmacro.el`) record events, so a menu selection replays; pre/post-command hooks and `this-command` fire the same for all.

### 3. C core versus Lisp

| Concern | Where | Evidence |
|---|---|---|
| Event queue, platform → event struct, quit-on-arrival, input-pending, blocking/timers | C | `keyboard.c: kbd_buffer_*`, `3786-3841`, `8055` |
| Lispification of events (`make_lispy_event`), modifiers, click counting/drag detection | C | `keyboard.c:6230+` |
| Key-sequence assembly, prefix handling, translation maps, special-event dispatch, keymap property lookup at point | C | `read_key_sequence` `keyboard.c:10901`, `read_char` `2555`, `access_keymap` `keymap.c:492` |
| Command dispatch (`command-execute`, `call-interactively`, interactive specs) | C (`callint.c:256`) + Lisp (`simple.el`) | |
| Menu/tool-bar *content discovery* from keymaps | C | `keyboard.c:8690-8740, 9636-9660` |
| Buttons, widgets, `push-button`, `mouse.el` commands, kmacro UI, `help.el` | Lisp | `button.el`, `wid-edit.el`, `kmacro.el` |
| Macro record/replay primitive | C (`macros.c`) | event-level |

Inference: Emacs's C core is *larger* than a Tuna kernel should be because it also owns the keymap data structure and sequence reader. Tuna's equivalent split should put the queue, ordering, and quit-arrival in the kernel, and keymap/sequence/translation in the Input plugin (which already is the case: `plugins/keys.ss`).

### 4. Tuna's current code (facts)

1. `kernel/loop.ss:46-57`: `key-event` struct (client, sequence, key, code, location, repeat?, composing?, alt?, ctrl?, meta?, shift?) is defined *in the kernel* and exported. The `Input` interface has `resolve-event! (event : key-event) => :t` and `quit-event? (event : key-event) => :boolean` (`loop.ss:60-67`). `submit-event!` calls `Input-quit-event?` on the arriving thread and sends `[quit: event]` or `[event: event]` (`loop.ss:~177-183`). `input-queued?` and `discard-input!` filter by `key-event?` (`loop.ss:~340-350`). `dispatch!` calls `Input-resolve-event!` and starts the returned `command` as a task (`loop.ss:~395-410`); `on-quit!` re-enqueues the quit event when no task runs.
2. `plugins/keys.ss` implements `Input` as `global-keys` with *browser-specific decoding in the plugin* (`key-description`: `"Enter"` → `"RET"`, `ctrl?` → `C-`, etc.), keymaps (`keymap`, `targets` stack), pending prefix, `this-command`, `last-command`, `command-event`. Quit key is hard-coded `"C-g"` (`keys.ss:12, ~118`), though `keyboard-quit` binding is looked up in the keymaps first. Printing characters are matched by a `<printing-char>` binding.
3. `frontend/tuna-keyboard.ts`: one Datastar action `tunaKeyboard`, which builds a `Keydown` object `{version, type:"keydown", clientId, sequence, key, code, ...}`, queues it, and POSTs it serially to `/commands`; the sequence number is kept in `sessionStorage` (`tuna-keyboard.ts:8-80`). The `type` field already exists.
4. `plugins/web.ss`: `/commands` → `accept-event` → `parse-key-event` (validates, makes a `key-event`) → `submit-event!` (`web.ss:263-307`). So the *kernel* struct is constructed by the transport plugin: the transport must know the kernel's key shape.
5. Datastar buttons post with `data-on:click="@post('/endpoint')"` (docs.md:1374, 2628-2632); `@post(uri, {contentType:'form'|'json', ...})`, signals are sent in the body. A custom action (like `tunaKeyboard`) can be called as `data-on:click="@tunaKeyboard(...)"` too — Tuna already registers one via `action({name, apply})`. The element, `evt`, and `el` are available to the action.

Fact-level conclusion: the kernel contains a *browser keydown* shape (listed as drift in the kernel audit), and `Input` is typed to it. `Input-resolve-event!` is already the right single seam; its argument type is the problem.

### 5. Direct action vs keymap resolution: comparison

Three options for "a button that POSTs a specific request":

**(a) Client invokes a named action directly** (e.g. `POST /commands {command:"magit-stage", args:...}`).
- Pros: simplest for the page; no round trip through keymaps.
- Cons (facts/inference): (i) The client names commands — with ADR 10 ("an authenticated client has the same power as the user's shell") this is not an *escalation*, but a stale or forged id still needs validation (does this button exist now? is it enabled? is that command visible in this mode?) which re-creates, in a second place, the checks keymap resolution already does. (ii) Bypasses the pending-prefix/`this-command`/`last-command`, pre/post-command hooks, prefix arg, and macro recording unless every direct action re-implements them. (iii) `where-is` / `describe-key` on a button cannot work: the action is not in any keymap. (iv) Remapping and user rebinding cannot reach it. (v) Two entry paths → two sets of bugs (Emacs avoids this by having one).
- Macro recording (ADR 8 says "key replay by default"): a direct action either records as a synthetic event (then it is (c)) or is not replayable.

**(b) Emacs-style: everything is an event resolved through keymaps, buttons use node-local keymaps.**
- Pros: uniform pipeline (hooks, macros, prefix args, help, remap); matches ADR 8's "keymaps of the focused node and its ancestors"; `where-is` finds button commands; users rebind `<mouse-1>` on buttons.
- Cons: clicking a button needs the Input service to learn *which node* and the *gesture*; per-node keymaps require node ids be stable between render and click (race: the DOM may be one frame behind); a lookup step per click (negligible).

**(c) Both, unified (recommended).** Distinguish *what the client says* from *what the server does with it*:
- The client says only "item #N from client C: `activate` on node X with gesture G (+ position/data)". It never names a command, only a node id the server rendered earlier. Keyboard items say "keydown K". Same envelope (client id, sequence).
- The server's Input service interprets: keys through the key-sequence reader and active maps; node activations through the *node's* local keymap (`<activate>` or `<mouse-1>` event type), falling back to ancestors then the global map, exactly as Emacs's `keymap` text property does.
- A node can still carry an *action*, like `button-activate`: the node's keymap binds `<activate>` to a command (e.g. an anonymous or named command with captured arguments created by the server when it rendered the node). That is Emacs's `button` model: a direct call, but invoked by a command that the map chose, with arguments the server captured, not the client supplied.
- Validation: the server checks that node X exists in the *current* render (generation/epoch token), belongs to this client's view, and is enabled (`:enable`-like predicate). A stale id yields "no binding" (message), never a wrong command. Because the client never provides command names or arguments, there is nothing to sanitize beyond payload shape (ADR 10 is satisfied by authentication + this lookup; plugins are trusted anyway).
- Macros: record the input item (node id + gesture) like Emacs records mouse events; replay re-resolves, so if the node is gone replay yields "undefined" rather than invoking a stale action. Plus the optional command-level track in ADR 8 for robust replay of button-driven commands (inference).
- Help: `where-is`/`describe-key` take a gesture (e.g. `click on <node>`) and consult the same maps.
- Remapping: works at the `Input` level automatically.

Where option (a) is still fine (inference): purely *view-local* operations that do not touch editor state, e.g. expanding a client-side disclosure widget or scrolling the browser viewport. Those never need to reach the kernel. Anything that changes server state or runs a command goes through (c).

Not recommended: letting the *kernel* offer a "run action X" entry point; that is a second dispatch path and a policy decision (what is allowed, how it is recorded).

### 6. What the kernel should know about input

**Recommendation (inference, shaped by Emacs's own boundary):**

1. The kernel's input vocabulary is a single opaque item:
   `(defstruct input-item (client : :string) (sequence : :fixnum) (payload : :t))`.
   The kernel orders items (per the loop), keeps them FIFO with tasks and results, never looks inside `payload`. It does not know `key`, `ctrl?`, `mouse`, `node`, `focus`. The key shape (`key-event`) moves to the input service contract (e.g. `tuna/services/input.ss`), or to the web transport plus Input plugin pair; the transport builds a payload it and `Input` agree on. `parse-key-event` stays in the transport plugin, a "kind" discriminator (`type: "keydown"|"activate"|"focus"|...`) is the Input plugin's concern.
2. The `Input` interface shrinks to what the loop must call:
   - `resolve! (item) => (Maybe command)` — on the baton, as today's `resolve-event!`.
   - `arrival (item) => 'queue | 'interrupt` — on the arriving thread, no editor state, as today's `quit-event?`. Rename to avoid the key word "quit" in the contract; keep two outcomes. Emacs does this in C because it must run while Lisp is busy; Tuna needs it for the same reason (a busy task never reads the queue). Do **not** generalize to a third "handle now" outcome: Emacs's special events run Lisp at read time, but Tuna already has `call-on-editor-loop`/results for out-of-band work, and focus/resize can be ordinary queued items or a service call from the transport. Revisit only with a concrete plugin that cannot wait.
3. Kernel obligations beyond this, and nothing else:
   - `input-pending?` and `discard-input` — they count/drop *items* (replace `key-event?` with `input-item?`). These are Emacs primitives (`input-pending-p`, `discard-input`) and are about the queue, which the kernel owns. Fine to keep; they do not need the payload.
   - On quit arrival with no running task, re-enqueue the item (current `on-quit!`): legitimate loop policy ("quit key is an ordinary event when idle, prompts may bind it").
   - Macro replay and `unread-command-events` should be *Input-plugin features that call the same enqueue path* (`submit-item!` with a replay client id and per-replay sequence); ADR 3 already says "replay is an input source feeding the same loop". The kernel needs no macro knowledge; ADR 3's "defer job results during replay" can be a loop flag only if a second consumer appears (it currently would be a kernel-shaped policy for one feature; flag for the contract).
4. Things the kernel must **not** know: keys or modifiers; the `"C-g"` literal (it is in `plugins/keys.ss`; keep it configurable there); mouse/touch positions; nodes, buttons, menu items; prefix state, `this-command`, `last-command` (already in the plugin); the translation of browser key names (plugin, as today).
5. Client identity: `client` and `sequence` in the item envelope are fine in the kernel *only if* the kernel uses them for ordering/identity (the audit's concern is session slots). The loop today does not use them; they could live in the payload and be Input/web business. Inference: keep `client` and `sequence` in the envelope only if the contract wants ordered per-client delivery in the kernel; otherwise a bare `payload` suffices and the web plugin can wrap its own `(client, sequence)`. Decision for the owner/contract author; my lean is envelope-less (`submit-item! payload`), with the transport plugin owning client identity, because per-client input sessions (ADR 10/8) are an Input-plugin matter.
6. Line budget implication (inference, from the current numbers): `kernel/loop.ss` is 631 lines and contains the `key-event` struct and quit machinery. Removing `key-event` and `Input`'s browser-shaped arguments saves ~20 lines; the bigger saving is separate (tasks/quit/suspension could be a plugin-provided "execution" service, outside this lane).

## Contradictions

- ADR 8 says commands run by "keys that invoked it" and macro replay "key replay by default", while the capability for button/mouse input has no story yet; I found no ADR text that excludes button events from macros. Emacs excludes *special events* only. Not a contradiction in the sources; a gap.
- The brief says "quit detection on arrival, which today calls `Input-quit-event?`". Emacs *also* does that in the core, so keeping it is consistent, though the current kernel wording ties it to `key-event`.

## Missing evidence

- I did not trace each GUI backend's menu code (GTK/NS) to confirm that every path returns a key sequence rather than calling a function; sampled `keyboard.c` and `read_char_x_menu_prompt` only.
- I did not read `keymap.c` text-property keymap lookup in detail (`get_local_map` at point, `keymap` vs `local-map` property precedence); the manual (`keymaps.texi:1053-1100`) is the support.
- I did not verify how Datastar passes `el`/`evt` to custom actions beyond `tuna-keyboard.ts`'s use of `evt`; the `tunaKeyboard` pattern is evidence it works for events. A node-activation action would be new code.
- No evidence on UX of 1-frame staleness for node ids in browser; recommendation (epoch token) is design inference.

## Sources

- Kept: `/home/jay/Code/emacs/doc/lispref/commands.texi` (Input Events, Special Events) — authoritative event taxonomy and special-event rules.
- Kept: `/home/jay/Code/emacs/src/keyboard.c` — arrival quit (3786-3841), special-event dispatch (3105-3125), menu/tool-bar rewrite (3172-3200), `make_lispy_event` (7225-7254), menu-bar scan (8690-8740).
- Kept: `/home/jay/Code/emacs/lisp/button.el`, `lisp/wid-edit.el` — button/widget activation through keymaps.
- Kept: `/home/jay/Code/emacs/doc/lispref/keymaps.texi` (2903-3210), `display.texi` (7981+) — menu/tool-bar bindings; Buttons.
- Kept: Tuna `tuna/kernel/loop.ss`, `tuna/plugins/keys.ss`, `tuna/plugins/web.ss`, `tuna/services/keys.ss`, `frontend/tuna-keyboard.ts`, ADR 8 and ADR 10, `agents/reference/datastar/docs.md` (backend actions).
- Not used: codebase-memory graph (grep on source was sufficient; no index query needed).

## Recommendations for Tuna's kernel contract

1. **One input shape in the kernel: an opaque item.** The kernel queues, orders, counts (`input-pending?`), and drops (`discard-input`) items; it never reads their contents. Delete `key-event` from the kernel; define key/node/focus payload types in the Input service contract, not in `kernel/`.
2. **One `Input` interface, two methods:** `resolve!` (baton, returns a command or #f) and a thread-safe arrival classifier returning `queue` or `interrupt` (replaces `quit-event?`). Keep arrival classification in the contract: a running task cannot read the queue, so quit must be recognized before queueing (Emacs does the same at `keyboard.c:3786`).
3. **Do not add a client "invoke action X" entry point to the kernel.** Buttons, menu items, and mouse clicks are items resolved by Input through node-local keymaps; the client names nodes and gestures, never commands. This keeps one path for hooks, `this-command`, macro recording, `where-is`, remapping, and validation (stale ids resolve to "no binding").
4. **Direct actions are bindings, not a second dispatch path.** A node's keymap may bind `<activate>` to a server-created command with captured arguments (Emacs `button` `action`). Pure view-local UI (disclosure, scrolling) need not reach the server.
5. **Macros, replay, and `unread-command-events` belong to the Input plugin,** feeding items back through the same enqueue path. The kernel needs no macro state; flag ADR 3's "defer jobs during replay" as a likely single-consumer kernel policy.
6. **Special events (focus, resize, drag-and-drop) are not a kernel concept yet.** Treat them as ordinary items or service calls from the transport; revisit only if a plugin needs read-time handling.
7. **Decide the envelope.** Either keep `(client, sequence, payload)` in the kernel *only if* the loop uses them, or move identity into the payload/transport. My lean: bare opaque item; client identity and per-client input sessions are Input/web plugin concerns (ADR 8/10 allow it).
8. **Keep browser key-name translation, the quit-key literal, prefixes, `last-command`, and keymaps in `plugins/keys.ss`** (already there), and remove the transport's dependency on a kernel struct (`web.ss:290-307`).

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Report written to the bound path with findings, comparison of options (a)/(b)/(c), and kernel recommendations; sources cited by file:line in Emacs checkout and Tuna tree."
    }
  ],
  "changedFiles": [
    "/home/jay/Code/workbench-gerbil/scratch/tuna-kernel-contract/02-emacs-input-model.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "grep/sed reads of Emacs src/doc/lisp and Tuna kernel/plugins/frontend",
      "result": "passed",
      "summary": "Read-only inspection; no repository edits."
    }
  ],
  "validationOutput": [
    "Line references taken from sed/grep output of the Emacs checkout at 541f693 and the Tuna working tree; some loop.ss line numbers marked approximate (~)."
  ],
  "residualRisks": [
    "GUI-backend menu paths not fully traced",
    "keymap.c text-property lookup not read in detail",
    "Datastar custom action for node activation not prototyped",
    "A few loop.ss line numbers approximate"
  ],
  "noStagedFiles": true,
  "diffSummary": "Created one research report file; no other changes.",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "Main recommendation: kernel holds an opaque input item plus resolve/arrival-classify on one Input interface; buttons are node-local keymap bindings resolved server-side (option c), not client-named commands. codebase-memory index was not used."
}
```
