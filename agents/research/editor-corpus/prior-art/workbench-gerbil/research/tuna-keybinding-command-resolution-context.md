# Tuna keybinding and command-resolution context

**Question:** What influences mapping a keystroke or key sequence to a command, especially in Emacs, and should Tuna design keybindings now?

**Conclusion:** Concrete Tuna keybindings are **premature but separable**, not a prerequisite for the web vertical slice. Tuna already has the stable command-side seams—live named actions and transitions, typed descriptors, serialized execution, and revisioned state—but intentionally has no focus, cursor, mode, editable-region, browser event, or host-context model. Those missing semantics determine most useful binding predicates and precedence rules.

The smallest stable definition now is the boundary: **a host-local input resolver selects a live action name and supplies explicit arguments or an opaque host context; Tuna core resolves and executes that name at dequeue.** Event normalization, key sequences, precedence, focus scopes, and browser cancellation should remain in the browser host package.

## Evidence baseline and confidence

- GNU Emacs evidence comes from development checkout commit `541f693ca2e8de166cfe52c39bbfc497142215e9`, described as `emacs-31.0.90-546-g541f693ca2e`. The keymap architecture is longstanding, but exact edge behavior is version-sensitive.
- Tuna evidence comes from clean nested checkout commit `5a481b1216236c64701cf950c3a8dcf529aba183`.
- Browser claims cite MDN, the DOM/UI Events specifications, and official editor documentation.

**Confidence:**
- **High:** Emacs pipeline, normal active-map precedence, prefix maps, translation maps, command remapping, and invocation distinctions.
- **High:** Current Tuna boundaries and explicit host-layer exclusion.
- **High:** Browser focus, propagation, `key`/`code`, composition, repeat, and cancellation constraints.
- **Medium-high:** Exact Emacs interaction when multiple overriding maps are simultaneously non-`nil`; current source and manual wording are not perfectly aligned.
- **Medium:** The best future Tuna binding model, because the application/web state and focus model do not yet exist.

---

## 1. GNU Emacs input-to-command pipeline

### Stage 1: platform input becomes Emacs events

Emacs receives terminal/window-system input and represents it as input events:

- ordinary keyboard characters are integer character events with modifier bits;
- function keys are symbols;
- mouse, touchscreen, focus, and system events are lists whose `car` is the event type.

For key binding, keyboard event type is the event itself; for list events, it is the `car`. Two events with the same type select the same binding even though the invoked command can inspect their full data and behave differently.

Evidence:

- event representation: `/home/jay/Code/emacs/doc/lispref/commands.texi:1357-1409`
- keyboard modifiers and function-key representation: `commands.texi:1399-1603`
- binding equivalence versus command behavior: `commands.texi:2869-2891`
- input device and frame records: `commands.texi:1219-1264`

On character terminals, bytes are first decoded through the terminal’s keyboard coding system. That coding system is terminal-specific; the selected frame’s terminal is the default:

- `/home/jay/Code/emacs/doc/lispref/nonascii.texi:2031-2050`
- `/home/jay/Code/emacs/doc/lispref/keymaps.texi:1982-1985`

There is no single cross-platform “raw scancode” stage exposed to Lisp. Window systems and terminals can produce materially different events before normal key lookup begins.

### Stage 2: `read-key-sequence` reads until a complete key

The command loop calls `read-key-sequence`, which accumulates events until the active keymaps identify either:

- a complete non-prefix binding;
- an undefined sequence with no remaining possible translation; or
- a special termination condition.

The active maps are recomputed when input changes the relevant buffer/window context or asynchronous activity changes the selected buffer during reading.

Evidence:

- overview: `/home/jay/Code/emacs/doc/lispref/commands.texi:37-67`
- public behavior: `commands.texi:3351-3425`
- command-loop call: `/home/jay/Code/emacs/src/keyboard.c:1318-1464`
- sequence reader and map rebuilding: `keyboard.c:10901-11381`

A key sequence is therefore not merely a fixed list recognized independently of state. Whether Emacs continues reading depends on whether the prefix so far is a prefix in the currently active maps and translation maps.

### Stage 3: event and sequence normalization

During reading, Emacs applies several transformations.

#### Translation maps

In effective order:

1. `input-decode-map` — terminal-local escape-sequence decoding;
2. `local-function-key-map` — terminal-local preferred interpretation, inheriting from global `function-key-map`, but normally only when the original sequence has no ordinary binding;
3. `key-translation-map` — global translation applied after function-key translation and regardless of ordinary bindings.

Mappings can replace subsequences anywhere in the sequence. A translation can also be a function, so it can compute a replacement dynamically, inspect arbitrary Lisp state, or read more input.

Evidence:

- complete translation-map semantics: `/home/jay/Code/emacs/doc/lispref/keymaps.texi:1942-2098`
- concrete reader initialization/order: `/home/jay/Code/emacs/src/keyboard.c:10407-10429,11029-11070`
- terminal-local declarations: `keyboard.c:14155-14213`

An ordinary binding can cause the reader to stop before a longer translation is recognized. The manual specifically warns against commands whose sequence is a prefix of a terminal escape translation: `keymaps.texi:2075-2098`.

#### Other normalizations

`read-key-sequence` can also:

- downcase an undefined uppercase/shifted event when the lowercase equivalent is bound, controlled by `translate-upper-case-key-bindings`;
- turn an unbound drag into a click;
- discard an unbound button-down event;
- move focus/window events outside a multi-event sequence;
- add imaginary prefix events such as `mode-line`, `header-line`, `left-fringe`, or `vertical-scroll-bar` based on mouse/touch target area.

Evidence: `/home/jay/Code/emacs/doc/lispref/commands.texi:3427-3499`.

At keymap lookup, Meta-modified character events are additionally treated as `meta-prefix-char`—normally `ESC`—followed by the non-Meta character. This conversion applies to character events, not function keys: `/home/jay/Code/emacs/doc/lispref/keymaps.texi:438-460,1607-1652`.

### Stage 4: discover active keymaps

Normal precedence is:

1. `keymap` text/overlay property at point, or at the mouse event position;
2. enabled emulation maps in `emulation-mode-map-alists`;
3. `minor-mode-overriding-map-alist`;
4. enabled entries of `minor-mode-map-alist`;
5. a `local-map` text/overlay property, otherwise the current buffer’s local map;
6. global map.

Special overriding maps sit above these:

- terminal-local `overriding-terminal-local-map` has highest precedence and is used by transient/modal facilities;
- `overriding-local-map` replaces ordinary property/minor/local maps while leaving the global map as fallback.

Evidence:

- normal discovery and precedence: `/home/jay/Code/emacs/doc/lispref/keymaps.texi:1043-1119`
- pseudo-code including mouse position: `keymaps.texi:1121-1170`
- enabling variables and transient maps: `keymaps.texi:1230-1378`
- implementation: `/home/jay/Code/emacs/src/keymap.c:1650-1794`
- event position passed into discovery: `/home/jay/Code/emacs/src/keyboard.c:10391-10404`

**Version-sensitive gap:** the current Emacs source deliberately ignores `overriding-local-map` when `overriding-terminal-local-map` is non-`nil`, then prepends the terminal map to ordinary maps (`keymap.c:1687-1791`). Some manual wording and pseudo-code can be read as searching both overriding maps. Code should not depend on simultaneously setting both without testing the target Emacs version.

### Stage 5: search maps and prefix maps

For each event, Emacs searches active maps in precedence order.

- A command, keyboard macro, or other complete binding ends lookup.
- A keymap binding means the events so far form a prefix; the next event is looked up in that submap.
- When the same prefix exists in multiple active maps, the prefix definitions are effectively merged in active-map precedence order.
- A higher-precedence complete binding shadows all lower bindings for that sequence.

Evidence:

- prefix definition and merging: `/home/jay/Code/emacs/doc/lispref/keymaps.texi:885-999`
- sequential lookup: `keymaps.texi:1380-1404`

Within a map:

- parent bindings are consulted dynamically at lookup;
- a child can override its parent;
- composed maps search constituent maps in order, then an optional parent;
- nested keymaps can be inlined for multiple inheritance.

Evidence:

- parent and composed maps: `/home/jay/Code/emacs/doc/lispref/keymaps.texi:798-869`
- inline maps and `nil` behavior: `keymaps.texi:420-449`

### Stage 6: resolve indirect, default, undefined, and dynamic bindings

Material binding forms include:

- `nil`: no binding; lower-precedence active maps can still supply one;
- command or interactive lambda;
- keyboard macro string/vector;
- keymap or symbol whose function definition is a keymap;
- symbol indirection leading to a command, macro, or map;
- `undefined`: an executable command deliberately used to stop lower-precedence fallback and report an undefined key;
- default binding, conventionally the `t` entry, when defaults are accepted.

Evidence:

- binding forms and `undefined`: `/home/jay/Code/emacs/doc/lispref/keymaps.texi:1380-1490`
- defaults and lookup options: `keymaps.texi:1497-1566`

A subtle distinction:

- `nil` masks a default or parent binding inside the same map but does **not** prevent lookup in lower-precedence active maps;
- `undefined` is used when the higher-precedence map must actively suppress a lower command.

Extended `menu-item` entries may include `:filter`. During key-element resolution, Emacs evaluates that function to produce the real binding, so effective binding can depend on arbitrary dynamic state:

- manual: `/home/jay/Code/emacs/doc/lispref/keymaps.texi:2511-2538,2620-2630`
- implementation: `/home/jay/Code/emacs/src/keymap.c:647-711`

Other menu properties such as `:visible`, `:enable`, and `:button` primarily control menu presentation/selection state; they are not general keyboard binding predicates. `:filter` is the material binding-producing escape hatch.

### Stage 7: one-level command remapping

After ordinary lookup selects a command symbol, Emacs searches the active maps again for `[remap ORIGINAL-COMMAND]`.

Properties:

- remapping uses active maps, not the prefix map through which the command happened to be reached;
- it applies one level only;
- position-sensitive active maps can affect remapping;
- `this-original-command` records the pre-remap command while `this-command` records the command actually run.

Evidence:

- `/home/jay/Code/emacs/doc/lispref/keymaps.texi:1892-1940`
- `/home/jay/Code/emacs/src/keymap.c:1217-1242`
- remapping while the correct mouse/buffer context is still active: `/home/jay/Code/emacs/src/keyboard.c:11863-11872`
- original versus actual command: `/home/jay/Code/emacs/doc/lispref/commands.texi:1140-1145`

### Stage 8: pre-command interception and invocation

The command loop:

1. records the original and remapped commands;
2. sets `this-command` and `real-this-command`;
3. runs `pre-command-hook`;
4. invokes the resulting `this-command` through `command-execute`.

A pre-command hook can mutate or clear `this-command`, so it is a final dynamic interception point after keymap resolution.

Evidence: `/home/jay/Code/emacs/src/keyboard.c:1492-1548`.

`command-execute` then:

- transfers `prefix-arg` into `current-prefix-arg`;
- checks the command symbol’s `disabled` property and can invoke `disabled-command-function` instead;
- follows function indirection and autoloads;
- executes keyboard macros or calls the function interactively.

Evidence:

- invocation contract: `/home/jay/Code/emacs/doc/lispref/commands.texi:806-914`
- disabled commands: `commands.texi:4559-4627`
- implementation: `/home/jay/Code/emacs/lisp/simple.el:2789-2859`

For functions, `call-interactively` evaluates the interactive specification to acquire arguments. This can use:

- prefix argument;
- point, mark, or region;
- current buffer and directory;
- minibuffer prompts and completion;
- the full mouse/system event;
- the invoking key sequence;
- selected mouse window.

Evidence:

- interactive argument computation: `/home/jay/Code/emacs/doc/lispref/commands.texi:115-196,237-306,386-592`
- implementation examples: `/home/jay/Code/emacs/src/callint.c:256-345,350-720`

### Stage 9: post-command state

After invocation, Emacs runs `post-command-hook`, updates:

- `last-command`;
- `real-last-command`;
- `last-repeatable-command`;
- `last-prefix-arg`;
- command key/event records;
- mark/selection and redisplay state.

These values normally affect later command behavior, not the completed lookup. They can indirectly affect the next lookup when hooks install a transient map.

Evidence: `/home/jay/Code/emacs/src/keyboard.c:1559-1692`; `/home/jay/Code/emacs/doc/lispref/commands.texi:1071-1217`.

---

## 2. Material context and state inputs

### Direct lookup-time inputs

| Input | Material effect |
|---|---|
| Raw event identity and modifiers | Determine the normalized event type searched in maps. |
| Events already read | Determine current prefix submaps and whether to await another event. |
| Keyboard coding system | Decodes terminal bytes before translation. |
| Terminal/kboard | Owns terminal-local decode, function-key, and overriding-terminal maps. |
| Active global translation maps | Can replace any recognized subsequence. |
| Translation functions | Can compute events from arbitrary Lisp state and can read more input. |
| Selected frame | Selects a terminal and, through its selected window, the normal keyboard buffer. |
| Selected window | Its buffer becomes current at the top of the command loop. |
| Current buffer | Supplies local map, buffer-local mode variables, point, and properties. |
| Mouse/touch target window and buffer | Replace current buffer/point as the lookup context for target-sensitive events. |
| Point or explicit event position | Selects `keymap`/`local-map` text and overlay properties. |
| Embedded/display string target | Its properties can override properties of underlying buffer text. |
| Major mode | Material indirectly because it normally installs the buffer-local map. The mode symbol is not independently searched. |
| Minor-mode enable variables | Directly decide which entries of the minor/emulation map alists are active. |
| Ordering of map alists | Earlier active minor entries have higher priority. |
| Overriding/transient maps | Can preempt normal maps; terminal transient maps have highest priority. |
| Map contents and live customization | User/package mutation of global, local, minor, property, parent, or translation maps immediately changes future lookup. |
| Parent/composed maps | Add dynamic fallback and multiple-map precedence. |
| Prefix-map contents | Determine both sequence validity and the final command. |
| Binding indirection and `menu-item :filter` | Can dynamically change the effective binding. |
| Command-remap entries | Can replace the selected command once through the active maps. |
| `pre-command-hook` | Can replace or cancel the command after lookup but before invocation. |
| Disabled-command property | Does not change key lookup, but can substitute a confirmation/disabled handler at invocation. |

### Terminal, device, frame, window, and buffer distinctions

- **Terminal:** directly material through terminal-local coding and maps.
- **Physical input device identity:** recorded in `last-event-device`, but not a normal built-in keymap precedence axis. It becomes material only if extension code—translation functions, filters, hooks, or command bodies—consults it.
- **Frame:** material mainly through terminal selection, focus, and selected window. There is no general frame-local keymap tier.
- **Window:** normal keyboard lookup uses the selected window’s buffer. Mouse lookup uses the clicked window’s buffer and position. Merely displaying one buffer in multiple windows does not itself create distinct buffer keymaps.
- **Buffer:** directly material through local map, point, properties, major/minor modes, and buffer-local variables.

### Point, overlays, text properties, and mouse target

Point affects mapping only because Emacs consults `keymap` and `local-map` properties there. Other cursor attributes do not automatically influence mapping.

Mouse coordinates beyond their derived event type and target position do not select different commands. They remain invocation data so the same command can act at different coordinates. The manual states this distinction explicitly: `/home/jay/Code/emacs/doc/lispref/commands.texi:2869-2891`.

### Minibuffer and recursive edit

- The minibuffer has its own buffer and local map, so minibuffer focus changes bindings.
- Minibuffer input is a recursive command loop, but the changed bindings arise from the minibuffer’s local map.
- Recursive edit depth by itself does **not** add a general keymap tier; ordinary recursive edits use commands from the same active maps unless surrounding code changes maps or buffer context.

Evidence: `/home/jay/Code/emacs/doc/lispref/commands.texi:4436-4467`.

### Current/previous command, history, prefix arguments, and repeat

#### Factors that normally do **not** select the current command

- `command-history` is output from interactive invocation; it does not participate in normal key lookup.
- `this-command`, `last-command`, `real-last-command`, and `last-repeatable-command` are command-loop records, not ordinary keymap inputs.
- `current-prefix-arg`, `prefix-arg`, and `last-prefix-arg` normally determine interactive arguments and command behavior, not which command a final key resolves to.
- point, region, read-only state, and mode-specific command applicability often affect interactive argument acquisition or behavior without changing the key’s binding.
- a command’s extended `interactive` mode list affects `M-x` completion relevance, not ordinary keymap lookup: `/home/jay/Code/emacs/doc/lispref/commands.texi:661-680`.

#### Ways those factors can indirectly become mapping inputs

- `universal-argument` and related commands install/read special prefix behavior for following keystrokes.
- `repeat-mode` inspects the prior command’s `repeat-map` property in `post-command-hook` and installs that map with `set-transient-map`, so prior-command state changes the next lookup.
- transient-map keep predicates are arbitrary functions evaluated before commands.
- translation functions, menu filters, and hooks can consult any of the above variables.

Repeat evidence:

- repeat-map metadata: `/home/jay/Code/emacs/doc/lispref/keymaps.texi:683-748`
- repeat mode installs a transient map after the command: `/home/jay/Code/emacs/lisp/repeat.el:419-558`
- prefix argument roles: `/home/jay/Code/emacs/doc/lispref/commands.texi:4373-4411`

### Selection versus behavior

This is the most important architectural distinction.

**Command selection** normally depends on normalized event type, sequence prefix, active maps, position-sensitive map properties, binding indirection/filtering, and remapping.

**Invocation arguments** can depend on the full event, target window, point/mark, prefix argument, minibuffer input, and key sequence.

**Command behavior** can depend on arbitrary application state, modes, history, current/previous command, device, cursor, selection, buffer content, or external effects.

A design that puts all behavior predicates into the keybinding engine will reproduce Emacs’s open-ended dynamic escape hatches rather than define a tractable binding model.

---

## 3. Browser constraints for a future Tuna UI

### Focus and event target

A `keydown` targets the currently focused element. This can be an `input`, `textarea`, `contenteditable` host, link, button, or other keyboard-interactive element; otherwise the target is normally `body` or the document root. The target can change between `keydown` and `keyup`, notably when Tab moves focus.

Source: [MDN: Element `keydown` event](https://developer.mozilla.org/en-US/docs/Web/API/Element/keydown_event).

**Implication:** focus scope is a first-class binding context. The server cannot discover it authoritatively without a client report, and that report can already be stale when it arrives.

### Capture, target, bubble, and delegation

Keyboard events bubble to ancestors, `Document`, and `Window`. Listeners registered with `capture: true` run on the capture path before normal target/bubble handlers. `event.target` remains the original element; `currentTarget` changes per listener.

Sources:

- [MDN: `keydown`](https://developer.mozilla.org/en-US/docs/Web/API/Element/keydown_event)
- [MDN: Event bubbling and capture](https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/Scripting/Event_bubbling)

**Implication:** Tuna must eventually decide whether bindings are component-local, editor-surface scoped, or document-global, and how a high-level listener cooperates with embedded controls and widgets.

### `key` versus `code`, layout, and platform modifiers

- `KeyboardEvent.key` is semantic: it reflects modifiers, locale, and keyboard layout. Dead keys report `"Dead"`.
- `KeyboardEvent.code` identifies the physical-key position and does not change with layout or modifiers. A `KeyQ` position can produce `q`, `'`, or `a` on QWERTY, Dvorak, or AZERTY.
- Modifier conventions differ by platform; “primary modifier” usually means Control on Windows/Linux and Meta/Command on macOS. Actual flags and `getModifierState()` must be read from each event.

Sources:

- [MDN: `KeyboardEvent.key`](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/key)
- [MDN: `KeyboardEvent.code`](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/code)
- [UI Events KeyboardEvent key values](https://www.w3.org/TR/uievents-key/)

**Implication:** bindings need an explicit semantic-key versus physical-key policy. Tuna should not serialize US-layout characters and assume they identify physical keys.

### Repeat

`KeyboardEvent.repeat` is true for automatically repeated keydown events. Repeat timing is platform-controlled, and modifier release can change the `key` value during repetition.

Source: [MDN: `KeyboardEvent.repeat`](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/repeat).

**Implication:** the host must decide whether a command accepts repeats, ignores them, or treats them as a separate gesture. This is separate from Emacs-style repeat maps.

### Composition, IME, and dead keys

`isComposing` reports events between `compositionstart` and `compositionend`, but browser ordering has edge cases where composition starts after the first keydown or ends before the final keydown. MDN documents the legacy `keyCode === 229` workaround despite `keyCode` being deprecated.

Sources:

- [MDN: `KeyboardEvent.isComposing`](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/isComposing)
- [MDN: keydown events with IME](https://developer.mozilla.org/en-US/docs/Web/API/Element/keydown_event#keydown_events_with_ime)
- [MDN: `KeyboardEvent.key`](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/key)

**Implication:** printable-key bindings must not consume composition/dead-key input by default. Text insertion should normally be modeled through `beforeinput`/`input`, not inferred solely from keydown.

### Editable controls and default editing

Character keys in `input`, `textarea`, and contenteditable hosts can produce `beforeinput` and `input`. `beforeinput` may be non-cancelable or absent for autocomplete, spell correction, password managers, or input method editors (IMEs), with browser/operating-system variation.

Source: [MDN: `beforeinput`](https://developer.mozilla.org/en-US/docs/Web/API/Element/beforeinput_event).

**Implication:** “typing a key” and “editing text” are different event domains. Any editor-like Tuna host needs explicit editable-region and native-control policies before broad printable shortcuts are safe.

### `preventDefault`, propagation, and reserved shortcuts

`preventDefault()` suppresses a cancelable event’s browser default action, such as scrolling, navigation, or text insertion. It does not stop propagation. It has no effect on non-cancelable events or from passive listeners.

Source: [MDN: `Event.preventDefault()`](https://developer.mozilla.org/en-US/docs/Web/API/Event/preventDefault).

Browser, operating-system, and assistive-technology shortcuts can conflict. MDN advises against overriding them, particularly screen-reader shortcuts, and notes the cross-layout problems of character bindings:

- [MDN: `aria-keyshortcuts`](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-keyshortcuts#dont_override_browser_assistive_technology_or_operating_system_shortcuts)

The experimental Keyboard Lock API can capture only keys granted by the underlying operating system:

- [MDN: `Keyboard.lock()`](https://developer.mozilla.org/en-US/docs/Web/API/Keyboard/lock)

**Implication:** not every desired shortcut is deliverable or safely interceptable. Support must be tested per target browser, operating system, keyboard layout, and assistive technology.

### Accessibility

A keyboard interface must preserve:

- logical focus order;
- visible focus;
- activation of interactive controls through standard keyboard behavior;
- a way to leave complex widgets, especially through Tab;
- discoverable shortcuts and `aria-keyshortcuts` metadata where appropriate.

`aria-keyshortcuts` only exposes already-implemented behavior to assistive technology; it does not implement the shortcut.

Sources:

- [MDN: Keyboard accessibility](https://developer.mozilla.org/en-US/docs/Web/Accessibility/Guides/Understanding_WCAG/Keyboard)
- [MDN: `aria-keyshortcuts`](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-keyshortcuts)

### Client-side versus server-side authority

| Must be resolved synchronously in the client | Can be supplied or validated authoritatively by the server |
|---|---|
| Actual focus and event target | Current application revision and durable state |
| Capture/bubble cooperation | Authorization and command availability |
| `key`, `code`, modifier, location, repeat | Binding/configuration data delivered ahead of time |
| Composition/dead-key/editable-control exclusions | Validation that a selected action remains legal |
| Sequence/chord buffering and timeout | Final transition execution and revision installation |
| Whether to call `preventDefault`/`stopPropagation` | Rejection or reinterpretation of stale command intent |
| Native browser/accessibility fallback | Serialized live action/transition resolution |

A server **can** receive raw event descriptions and choose a command, but a round trip is too late to synchronously prevent the browser’s default action. It also introduces chord latency, focus races, and stale context. A client could preemptively cancel every potential prefix and await the server, but that risks trapping text input and accessibility navigation.

The robust split is:

1. server supplies current binding/configuration and application-context projections;
2. client performs immediate host-event resolution and cancellation;
3. client submits a live action/transition name plus arguments/context and observed revision;
4. server validates and executes through Tuna’s serialized owner.

---

## 4. Relevant modern editor models

### Visual Studio Code

Visual Studio Code keybinding rules contain a key/chord, command, and optional Boolean `when` clause. Rules are evaluated bottom-to-top; the first rule matching both key and context wins. User rules are appended and therefore override defaults. Context keys include concrete concepts such as editor text focus, read-only state, language identifier, visible UI, and debugger availability.

Source: [VS Code Keyboard Shortcuts](https://code.visualstudio.com/docs/configure/keybindings#_keyboard-rules).

**Insight for Tuna:** conditional bindings require a defined vocabulary of context keys. Designing predicates before Tuna defines focus, editor state, read-only state, modes, or active surfaces would either invent product semantics prematurely or expose an unbounded generic predicate language.

### CodeMirror 6

CodeMirror keybindings:

- use names based on `KeyboardEvent.key`;
- support platform-specific alternatives;
- are scoped, with the default scope requiring focus in editor content;
- are checked by extension precedence;
- stop after the first handler returns true;
- control `preventDefault` and propagation explicitly;
- include a Tab-focus mode so keyboard users can escape the editor.

Source: [CodeMirror 6 reference: Key bindings](https://codemirror.net/docs/ref/#view.KeyBinding).

**Insight for Tuna:** browser keymaps belong near the focused view/component and accessibility behavior. They need not be part of the authoritative state runtime.

---

## 5. Mapping the findings onto Tuna

### Existing stable architecture

#### Deliberate live definitions

Tuna separates live functions, actions, transitions, and values into distinct stable-cell domains:

- `/home/jay/Code/workbench-gerbil/tuna/tuna/lib/bindings.ss:41-95`
- action publication: `bindings.ss:369-393`
- transition publication: `bindings.ss:395-410`

Queued name-backed work resolves the current action/transition when the owner executes it, preserving live replacement:

- actions: `bindings.ss:430-452`
- transitions: `bindings.ss:462-475`
- runtime dispatch: `/home/jay/Code/workbench-gerbil/tuna/tuna/lib/runtime.ss:137-178`
- tests: `tuna/tuna/test/command-runtime-test.ss:131-170`, `tuna/tuna/test/state-runtime-test.ss:117-138`

This is already the correct command identity boundary for a future host resolver: bind to a live symbol, not a captured implementation procedure.

#### Host-neutral action acquisition

An action atomically groups implementation, opaque host descriptor, and a `context -> argument-list` acquirer. The context is not interpreted by core:

- `tuna/tuna/lib/bindings.ss:41-46,369-392,437-452`
- `tuna/tuna/README.md:207-226`

This directly supports browser-host argument acquisition without making Document Object Model (DOM) events, focus, or input concepts core responsibilities.

#### Serialized command owner

`CommandRuntime` owns a bounded inbox, lifecycle state, one worker, optional state root, and subscriptions:

- `tuna/tuna/lib/runtime.ss:31-74`
- owner worker and sequential loop: `runtime.ss:155-223`
- bounded admission: `runtime.ss:247-288`

State installation verifies that the current thread is the command owner: `runtime.ss:114-135`.

#### Immutable revisioned state

The state runtime owns an application-supplied opaque value and revision. Changed transitions install a new root before completion; unchanged, invalid, and failed transitions do not install:

- `tuna/tuna/lib/runtime.ss:43-57,79-89,102-153`
- README contract: `tuna/tuna/README.md:128-179`
- tests: `tuna/tuna/test/state-runtime-test.ss:61-115,196-220`

Installed values are immutable by contract rather than deep-frozen or interpreted by Tuna.

#### Typed discovery

`callable-descriptor` distinguishes `function`, `action`, and `state-transition`; value descriptors remain independent:

- descriptor implementation: `tuna/tuna/lib/bindings.ss:247-282`
- publication of kinds: `bindings.ss:350-409`
- tests: `tuna/tuna/test/documentation-test.ss:63-99,131-188`

Important limitation: current typed discovery is lookup by known name; there is no public action enumeration or keybinding metadata schema.

### Explicit architectural exclusion

The roadmap explicitly says the following are host-layer concerns, not runtime milestones:

- keyboard/pointer input decoding;
- keymaps and command remapping;
- host-specific input/render event loops;
- windows, sessions, requests, and workspaces before a host defines them.

A future host package may map its own inputs and contexts onto live actions and values without changing core:

- `/home/jay/Code/workbench-gerbil/plans/emacsen-runtime/checklist.md:388-399`

Tuna’s README likewise states that core adds no input mapping or HTTP behavior: `tuna/tuna/README.md:164-171`.

### Architectural implication

Tuna already has the **command half** of an input-to-command system. It does not yet have the host concepts that determine the **lookup half**.

Putting a generic keymap system in core now would contradict the current boundary and would force decisions about:

- focus identity;
- modes and mode variables;
- point/cursor and selection;
- editable controls;
- mouse/event target;
- transient state and chord timeout;
- browser layout and reserved-shortcut policy;
- user override ordering;
- which application snapshot fields are safe to expose to client predicates.

---

## 6. What can be defined now, and what should wait

### Smallest stable abstractions available now

These do not require concrete key choices:

1. **Live command identity:** a binding ultimately names an interned Tuna action or transition; it does not capture its current procedure.
2. **Host-local resolution boundary:** raw events and key-sequence state remain outside core.
3. **Explicit resolution/invocation separation:** resolving a command is distinct from acquiring its arguments and from executing it.
4. **Opaque host context:** browser-specific target/focus/event data can enter through the existing host-context action path.
5. **Server validation boundary:** authoritative transition execution remains on the serialized owner against current revisioned state.
6. **Handled versus unhandled host outcome:** a browser resolver eventually needs enough local information to decide cancellation/fallback, but the exact result type should be defined with the first host rather than added speculatively to core.

### Details that require the web/application slice

- focus scopes and component hierarchy;
- which DOM regions are editable and when printable keys remain native;
- cursor/point, selection, active resource, and modal semantics;
- concrete mode/context predicates;
- binding precedence and user customization persistence;
- semantic `key` versus physical `code`;
- platform-specific modifiers;
- chord timeout, prefix display, abort, and replay behavior;
- repeat and keyup policy;
- IME/composition behavior;
- Tab and accessibility escape behavior;
- browser/OS collision matrix;
- client-visible application-state projection and stale-revision policy;
- whether bindings follow actions, UI commands, or state transitions.

## 7. Implementation sequencing options

These are alternatives, not an implementation plan.

### Option A — Web slice first, extract after one real interaction

Implement the web slice with a few component-local event handlers that directly submit existing live action/transition names. Extract a keybinding resolver only after focus, cursor, editable-state, and mode semantics exist.

**Trade-offs:**
- lowest architectural risk;
- gives real browser and accessibility evidence;
- may temporarily duplicate a few handlers;
- delays user-remappable bindings.

**Assessment:** strongest default given Tuna’s explicit host-layer boundary.

### Option B — Thin resolver alongside the web slice

Build a browser-host-only flat binding table with:

- normalized `KeyboardEvent` gesture;
- focus/component scope;
- small typed predicates over the slice’s concrete state;
- ordered precedence;
- sequence state and timeout;
- action name plus cancellation policy.

Keep the table and resolver outside Tuna core; server execution still uses existing runtime submission.

**Trade-offs:**
- establishes customization earlier;
- remains grounded in real state;
- requires more browser and accessibility testing during the first slice;
- predicate vocabulary can still churn as the product develops.

### Option C — Generic Emacs-like keymap engine before the slice

Create host-neutral events, layered maps, prefixes, translations, remapping, dynamic predicates, transient maps, and user overrides before building the UI.

**Trade-offs:**
- theoretically reusable across hosts;
- highest complexity and weakest requirements evidence;
- risks reproducing Emacs’s open-ended dynamic semantics without Emacs’s buffer/window/mode model;
- conflicts with current explicit host exclusions;
- likely to require redesign once browser focus and editing behavior are known.

**Assessment:** premature unless a concrete second host and compatibility requirement are approved.

---

## 8. Risks and unresolved gaps

- **High — premature core coupling:** adding keymaps to Tuna core would conflict with `plans/emacsen-runtime/checklist.md:388-399` and invent missing host concepts.
- **High — browser default-action race:** server-round-trip mapping cannot synchronously decide `preventDefault`; preemptive cancellation risks breaking native editing and accessibility.
- **High — IME/editable behavior:** broad printable shortcuts can corrupt composition or intercept text entry.
- **High — accessibility collisions:** browser, operating-system, and assistive-technology shortcuts are not a fully capturable namespace.
- **Medium — unbounded dynamic context:** Emacs translation functions, binding filters, transient predicates, and hooks make “all mapping inputs” formally open-ended. Tuna should prefer a small typed context vocabulary over arbitrary predicates when a real host exists.
- **Medium — stale client state:** state-dependent client resolution needs a revision/projection policy; Tuna has revisions but no web synchronization or client context contract.
- **Medium — discovery gap:** typed descriptors identify known names but do not enumerate actions or carry keybinding schemas.
- **Medium — platform variation:** browser/OS behavior for reserved shortcuts, IME ordering, `beforeinput` cancellation, and Keyboard Lock remains implementation-dependent.
- **Medium — Emacs overriding-map edge:** simultaneous overriding-terminal and overriding-local behavior should be tested against the selected Emacs version rather than inferred solely from manual prose.
- **Low — no current keybinding regression surface:** Tuna has no keybinding implementation or tests yet; future validation must be browser-facing, not only Gerbil unit tests.

---

## 9. Validation commands

No tests were run during this read-only research task.

### Focused current-runtime validation

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil test test/state-runtime-test.ss
gerbil test test/documentation-test.ss
```

These validate the state transition boundary and typed descriptor seam that a host resolver would target.

### Full Tuna validation

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil build
test/run-command-runtime-matrix.sh
```

The matrix runs command, state, event, and documentation suites under source `gxi`, normal `gxc`, and `gxc -O`, then verifies worktree status is unchanged: `tuna/tuna/test/run-command-runtime-matrix.sh:1-94`.

A future browser binding implementation additionally requires real-browser tests across:

- focus and editable targets;
- capture/bubble interaction;
- QWERTY and at least one non-QWERTY layout;
- macOS and Control-based platforms;
- IME composition and dead keys;
- repeat;
- browser/OS shortcut conflicts;
- keyboard-only and screen-reader navigation;
- latency/stale-revision behavior.