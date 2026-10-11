# Weevil — Architecture

## Introduction

Weevil will be a browser-based text editor and IDE focused on
performance and high extensibility. The developers of Weevil view it
as a modern alternative to GNU Emacs.

The implementation language for v1 is **Racket**. Weevil has a Racket
core and a Racket configuration/extension layer. These run in the same
Racket runtime, but they are separated by a deliberate public API
boundary: the core owns editor internals; user configuration programs
against stable editor concepts.


## Stack

- **Racket CS** — editor core, command/config runtime, HTTP server,
  file I/O, LSP orchestration, process management, semantic UI
  rendering, and session state.
- **Racket web-server + Datastar Racket SDK** — HTTP routes and
  Server-Sent Events for streaming rendered UI changes to the browser.
- **SQLite via Racket `db`** — durable persistence for sessions,
  history, recently opened files, and other queryable local state.
- **tree-sitter via adapter boundary** — server-side syntax parsing and
  highlighting. The binding/FFI layer is intentionally isolated so it
  can be replaced, forked, or run in a worker place if needed.
- **Browser client** — small JavaScript layer for key, mouse, clipboard,
  focus, and viewport events.

No NATS in v1. Live editor/session state is in-process Racket state.
SQLite is used only for durable persistence.

No client-side editor library. The browser is a rendering surface and
input capture device. There is no CodeMirror, Monaco, or other editor
component.

User configuration is plain `#lang racket`, not a custom language in
v1. A custom `#lang weevil/config` can be considered later if concrete
needs appear.

At startup, Weevil loads its built-in default configuration and then,
if present, a user `init.rkt` from the selected config directory. The
config directory defaults to an XDG-style user location, but startup
can override it with a command-line flag so tests and development can
use a local `./config` directory.


## Racket Core and Racket Configuration Layer

Weevil is a single-language system, but it still has two architectural
layers.

### Racket core

The Racket core owns data, operating-system integration, transport, and
concrete rendering. It implements:

- buffer storage and editing primitives
- point, mark, markers, selections, overlays, and undo transactions
- windows, frames, layouts, sessions, and per-session event queues
- file I/O and autosave/snapshot logic
- subprocess and LSP server lifecycle
- tree-sitter integration and syntax highlighting
- HTTP handlers and Datastar SSE streaming
- conversion of semantic UI specs into escaped HTML/xexpr fragments
- SQLite persistence

The core exposes a public editor API through stable modules such as
`weevil/config`, `weevil/commands`, `weevil/keymap`, `weevil/hooks`,
`weevil/modes`, and `weevil/ui`. Private implementation modules are not
part of the extension API.

Because config and core are both Racket, calls do not cross a foreign
runtime boundary. The boundary is conceptual and contractual: public
modules are stable; private modules may change.

### Racket configuration layer

The configuration layer defines user-facing behavior. The core should
not decide what a keystroke means. Every key — including printable
characters — goes through Racket command dispatch. This is how Emacs
works: pressing `a` calls a self-insert command.

Configuration and extensions own:

- commands
- keymaps
- major/minor modes
- hooks
- user options
- semantic UI providers
- command palette entries
- completion policy
- diagnostic display policy
- status bar / mode line content

Built-in editor behavior is also configuration. Weevil should ship a
rich default set of commands and keybindings so an empty user config is
a useful editor. Basic operations such as self-insert, newline,
backspace, delete-char, kill-word, backward-kill-word, kill-line,
yank, save-buffer, find-file, split-window, and other-window should be
provided by Weevil. Users customize by rebinding, advising, replacing,
or composing those public commands; they should not have to implement
basic editing behavior from scratch.

Configuration does **not** own concrete DOM structure in v1. It returns
semantic editor UI specs — status bar segments, faces, overlays,
gutters, completion candidates, diagnostics, panels, minibuffer content,
etc. The Racket core converts those specs into HTML/Datastar fragments.

Example user config:

```racket
#lang racket

(require weevil/config
         weevil/commands
         weevil/keymap
         weevil/hooks
         weevil/modes
         weevil/ui)

;; Self-insert: default binding for printable characters.
;; Every character goes through command dispatch.
(define-command (self-insert key)
  (insert! key))

(bind-printable-chars! global-keymap self-insert)

;; Commands
(define-command (kill-line)
  (define start (point))
  (define eol (end-of-line-pos))
  (kill-region! start eol))

;; Keymaps
(define-key! global-keymap "C-k" kill-line)
(define-key! global-keymap "C-x C-s" save-buffer!)
(define-key! global-keymap "C-x 2" split-window-below!)

;; Modes
(define go-mode-keymap (copy-keymap global-keymap))
(define-key! go-mode-keymap "C-c C-r" go-run)

(define (go-mode-setup)
  (set-buffer-local! 'tab-width 4)
  (lsp-start! "gopls"))

(add-major-mode! 'go-mode
                 #:extensions '(".go")
                 #:keymap go-mode-keymap
                 #:setup go-mode-setup)

;; Hooks
(add-hook! 'before-save-hook delete-trailing-whitespace!)
(add-hook! 'after-open-hook auto-detect-mode!)

;; User preferences
(set-option! 'theme 'gruvbox)
(set-option! 'show-line-numbers? #t)

;; Semantic UI provider: config chooses what the status bar means.
;; Core chooses the concrete HTML/Datastar representation.
(define (default-status-bar ctx)
  `((left
     (segment mode     (text ,(buffer-mode ctx)) (face mode))
     (segment filename (text ,(buffer-name ctx)))
     ,@(if (buffer-modified? ctx)
           `((segment modified (text "[+]") (face warning)))
           '()))
    (right
     (segment position (text ,(format "L~a C~a"
                                      (window-line ctx)
                                      (window-col ctx)))))))

(set-status-bar-provider! default-status-bar)
```


## Keystroke Flow

Every keystroke, including typing a regular character, follows one
path. The difference from Emacs is that HTTP is in the middle.

```text
Browser                    Racket Server/Core              Racket Command Layer
───────                    ──────────────────              ────────────────────
User presses "a"
       │
       ├──POST /key────────► route handler
       │                         │
       │                         ├──enqueue event──────────► session event loop
       │                         │                              │
       │                         │                         dispatch-key "a"
       │                         │                              │
       │                         │                         lookup-key finds
       │                         │                         self-insert
       │                         │                              │
       │                         │                         run pre-command hooks
       │                         │                              │
       │                         │  ◄──insert! "a"─────────────┘
       │                         │
       │                    mutate buffer in undo transaction
       │                         │
       │                    render affected fragments
       │                         │
       ◄──SSE patch──────────────┤
       │
Browser updates UI
via Datastar
```

HTTP handlers do not directly mutate editor state. They validate and
enqueue input events. The session event loop processes events in order,
runs commands, performs mutations, and triggers rendering.


## Session Event Model

Each editor session has a serialized event loop. This is the only place
where session editor state is mutated.

Inputs include:

- key events
- mouse events
- paste events
- client capability replies
- LSP/process notifications that affect editor state
- timers and deferred callbacks

Routine background work can use Racket threads and channels. CPU-heavy
or blocking work can use Racket places. Long-running work posts results
back to the session event loop instead of mutating editor state
directly.

This preserves Emacs-like command-loop semantics while still allowing
background LSP, syntax, indexing, persistence, and process I/O work.


## Buffers, Panes, Frames, and Sessions

The editor's object model follows Emacs behavior, but Weevil uses
**pane** for the view concept that Emacs calls a window. Four layers:

**Buffer** — owns content, mode, local variables, undo history,
markers, overlays, and buffer-local state. Exists whether or not it is
visible. Identified by a buffer ID. Multiple panes can display the
same buffer. Stores a default point/mark used when no pane is
displaying it.

**Pane** — a view onto a buffer. Each pane owns its own point,
mark, and scroll position. Two panes showing the same buffer have
independent cursors and scroll positions. When a pane switches to a
different buffer, the old buffer's point/mark are saved as the buffer's
default; the new buffer's saved state is restored into the pane. Panes
live inside frames.

**Frame** — a layout of panes. A tree of splits, where each leaf is a
pane. The server renders this as nested HTML divs. The client never
reasons about layout. One frame is active at a time in a browser tab.

**Session** — a snapshot of the entire editor state: which buffers are
open, the frame layout, which buffer each pane displays, per-pane
point/mark/scroll, minibuffer state, histories, and session-local
options. Restoring a session brings back the full workspace. Similar to
Emacs' `desktop-save-mode` or the `easysession` package.

```text
Session
 └── Frame
      ├── Pane (top)    → Buffer "main.rkt"    point: 1503  mark: 1503  scroll: line 42
      └── Pane (bottom) → Buffer "*messages*"  point: 892   mark: 892   scroll: line 0

Buffers (independent of layout):
  "main.rkt"      mode: racket-mode   undo: [...]  default-point: 1503
  "*messages*"    mode: messages-mode undo: [...]  default-point: 892
  "utils.rkt"     mode: racket-mode   undo: [...]  default-point: 340  (not visible)
```

**Minibuffer and minipane** — transient editor input such as buffer
selection, command prompts, completion, and file prompts is still editor
state. Weevil should model this as minibuffer state displayed in a
frame-owned minipane, not as ad hoc popups or DOM-only UI. The
minibuffer records the invoking pane so accepting a prompt acts on the
right editor context. Refreshing a browser page should reproduce the
active minibuffer from server session state.

**Focus, modes, and keymaps** — focus chooses the active dispatch
context; it is not itself the mode. Weevil tracks an explicit selected
input target separately from active minibuffer state. When the selected
input target is a pane, that pane identifies the current buffer, and
that buffer's major and minor modes participate in key dispatch before
the global keymap. When the selected input target is the minibuffer,
the minibuffer keymap is active. A minibuffer can remain active and
visible while input is routed to a normal pane; in that case, the
minibuffer is pending state, not a global input capture.

Initial keymap precedence:

```text
normal pane context:
  transient override maps
  buffer minor-mode maps
  buffer major-mode map
  global map

minibuffer context:
  transient override maps
  minibuffer map
```


## Buffer Storage

The public API should not expose the concrete buffer storage strategy.
Internally, the buffer layer must support efficient insertion,
deletion, slicing, line indexing, marker updates, undo records, and
incremental syntax parsing.

A naive "one Racket string per buffer" implementation is acceptable
only for the earliest spike. It is not the target architecture for v1.
Before v1, the buffer layer must be benchmarked and likely replaced by
a piece-table or rope-like representation. A plausible design is:

- immutable original file bytes
- append-only add buffer for inserted text
- a balanced sequence of pieces, likely backed by Racket treelists or a
  custom tree
- cached line-start indexes for visible range rendering and line/column
  conversion
- marker/overlay indexes updated with insertion bias rules

Large-file support does not have a fixed promise yet. The v1 gate is:
benchmark the buffer implementation against representative project
files and explicit 1MB, 10MB, and 100MB scenarios before declaring v1
performance goals.


## The Browser Client

The browser is not an editor. It is a div, a keydown handler, and a few
event handlers for mouse, clipboard, focus, and viewport state. No
editor library.

```html
<div id="buffer"
     tabindex="0"
     data-on:keydown="handleKey(event)">
  <!-- server-rendered buffer content -->
</div>
```

```javascript
const weevil = window.weevil; // {sessionId, token, seq}

function nextSeq() {
  weevil.seq += 1;
  return weevil.seq;
}

function postInput(path, payload) {
  return fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: {
      'Content-Type': 'application/json',
      'X-Weevil-Token': weevil.token
    },
    body: JSON.stringify({
      sessionId: weevil.sessionId,
      seq: nextSeq(),
      ...payload
    })
  });
}

function handleKey(event) {
  event.preventDefault();
  postInput('/key', {key: encodeKey(event)});
}
```

**Protocol envelope.** Every client event carries a session ID and a
monotonically increasing `seq` number. Events that refer to rendered
DOM also carry a `renderRev`. POST requests include the auth token in a
header when `fetch` allows it. SSE/event streams authenticate via the
same-origin session cookie because EventSource-like transports cannot
always attach custom headers.

The client is responsible for three things beyond keystroke capture:

**Mouse.** Buffer text is selectable — no `user-select: none`. Native
browser selection works at full speed (click, double-click to select
word, drag to select range). On `mouseup`, the client reads
`window.getSelection()`, resolves anchor and focus to line/col using
`data-line` attributes on rendered line elements, and POSTs the range
to the server. The server converts line/col to byte offsets, updates
the window's point and mark, and patches the selection signals.

Double-click word selection uses browser word boundary rules in v1.
Racket commands can override later by intercepting `dblclick` as an
input event.

Conceptual pseudocode:

```javascript
// Pseudocode — real implementation must handle syntax highlighting
// spans, selection direction, stale render revisions, and split panes.
document.addEventListener('mouseup', () => {
  const sel = window.getSelection();
  if (sel.rangeCount === 0) return;
  const pane = sel.anchorNode.parentElement.closest('[data-window-id]');
  const anchor = resolvePosition(sel.anchorNode, sel.anchorOffset);
  const head = resolvePosition(sel.focusNode, sel.focusOffset);
  postInput('/mouse', {
    windowId: pane.dataset.windowId,
    bufferId: pane.dataset.bufferId,
    renderRev: parseInt(pane.dataset.renderRev),
    anchor, head
  });
});
```

**Clipboard.** Clipboard integration is server-command driven, via the
kill ring — the same model as Emacs. Every key goes through Racket,
including `C-w` (kill), `M-w` (copy), and `C-y` (yank).

The system clipboard is a **client capability that the server
requests:**

- **Copy/kill:** command puts text on the kill ring. The server sends a
  client action via Datastar telling the browser to call
  `navigator.clipboard.writeText(text)`.
- **Yank:** command fires. The server sends a client action telling the
  browser to call `navigator.clipboard.readText()` and POST the result
  back. The server merges any external clipboard content into the kill
  ring, then inserts.

On macOS, `Cmd+C/V/X` are free because Cmd is not Ctrl; those can be
mapped to clipboard commands if desired. On Linux/Windows, users can
use Emacs-style bindings, same as actual Emacs.

**Caveat:** `navigator.clipboard.readText()` requires user activation
and browser permission in most browsers. Prototype this early. If
permission timing is a problem, fallback options include a hidden
textarea bridge or prompting the user to grant clipboard access on
first use.

**Async client capabilities.** Client capability requests are
asynchronous. Commands that need browser capabilities suspend and
resume when the client replies. Replies carry a request ID so the
session event loop can match them to the suspended command. Failures
and timeouts abort the command and report in the minibuffer.

While a command is suspended waiting for a capability reply, subsequent
input events for that session are queued. The capability reply resumes
the suspended command first, then queued events are processed in order.
This prevents keystrokes from interleaving with a half-finished command
such as `C-y` waiting for a clipboard read.

**Scroll position.** Scrolling is local CSS. The server renders more
lines than the viewport. When the user scrolls near the edge, the
client reports the new viewport position so the server can render
additional content.

The client-side JS should remain small and mechanical. Editor behavior
lives in Racket.


## Syntax Highlighting

Server-side. The Racket core asks the syntax subsystem for highlight
ranges, then renders the visible viewport as HTML with CSS classes
baked in. The browser just displays the HTML it receives.

```html
<!-- Server renders this directly -->
<span class="keyword">define</span> <span class="function">main</span>
```

The target parser is tree-sitter, but it lives behind an adapter
boundary. Racket tree-sitter bindings and native FFI behavior need an
early spike. If necessary, syntax parsing can run in a worker place, or
the binding can be vendored/forked. The rest of the editor should not
depend on tree-sitter package details.

Only the visible viewport plus a buffer needs rendering. The client
sends scroll position and viewport dimensions so the server knows which
lines to render.


## File Structure

Proposed Racket package layout:

```text
main.rkt                         executable entrypoint
weevil/
  config.rkt                     public config API aggregate; not env settings
  commands.rkt                   public command helpers/macros and built-ins
  keymap.rkt                     public keymap API
  buffer.rkt                     public buffer editing/movement API
  window.rkt                     public window operations
  frame.rkt                      public frame/layout operations
  modes.rkt                      public mode API
  hooks.rkt                      public hook API
  options.rkt                    public global/session/buffer option API
  ui.rkt                         public semantic UI API
  faces.rkt                      public face/theme API
  defaults.rkt                   built-in default config loaded before user init

  private/
    runtime-config.rkt           env/CLI runtime settings such as host/port
    config-loader.rkt            config-dir resolution and init.rkt loading

    core/
      editor.rkt                 editor/session state
      buffer.rkt                 buffer mutation operations behind public API
      piece-table.rkt            buffer storage implementation
      marker.rkt                 point/mark/marker behavior
      window.rkt                 windows and view state
      frame.rkt                  split tree/layout model
      undo.rkt                   undo transactions
      command-loop.rkt           dispatch-key, command lifecycle
      event-loop.rkt             per-session serialized event loop

    web/
      server.rkt                 Racket web-server setup
      routes.rkt                 /key, /mouse, /events, /capability
      sse.rkt                    Datastar SSE helpers
      render.rkt                 semantic specs → HTML/xexpr fragments
      assets.rkt                 static asset serving

    ui/
      spec.rkt                   semantic UI data model
      render-buffer.rkt          visible buffer rendering
      status-bar.rkt             status bar rendering
      overlays.rkt               overlays/decorations/gutters
      minibuffer.rkt             minibuffer/echo area rendering

    integrations/
      lsp.rkt                    LSP client orchestration
      tree-sitter.rkt            tree-sitter adapter boundary
      process.rkt                subprocess management

    persistence/
      sqlite.rkt                 SQLite schema and queries
      snapshot.rkt               session snapshot logic

config/
  init.rkt                       local dev/test user config (#lang racket)

~/.config/weevil/
  init.rkt                       default user config location
```

The exact paths can change, but the important rule is stable public
modules vs private implementation modules.


## ADR: Every Key Through the Racket Command Layer

Every keystroke goes to the server and through Racket command dispatch.
There is no client-side editing. Typing `a` in a buffer calls
`self-insert`, which calls a core insertion primitive, which mutates the
buffer inside the session event loop, and the server streams back the
updated state.

**Why:** This gives Racket total control over the editor. Keymaps,
modes, hooks, command history, undo boundaries, and macros all work
uniformly because every input event flows through the same dispatch
path. Macro recording is trivial: record the key sequence and replay
it. Before/after-change hooks fire on every edit. Modal editing is just
a keymap or state change.

**Tradeoff:** On a remote server there will be perceptible latency for
every keystroke. This is the same tradeoff as Emacs or Neovim over SSH.
People accept it. On localhost it should be fast.

**If latency becomes a problem:** Add speculative local echo for
`self-insert` only — show the character immediately, correct if the
server disagrees. This can be added later without changing the
architecture.

**Input methods (CJK, accents, etc.):** In v1, handled server-side in
Racket, similar to Emacs' built-in input method system. The browser
sends keystrokes, a Racket input method mode accumulates them, shows
candidates, and inserts the final character. This is just another mode,
not a special case.

**v1 limitation:** OS-level IME will not work reliably on the focused
div. This is a deliberate tradeoff. Emacs can integrate with platform
input methods, and Weevil may add browser composition-event support in
the future, but v1 relies on Racket-side input methods only.


## ADR: Single Writer Session Event Loop

Each session has exactly one logical writer: its event loop. HTTP
handlers, LSP readers, process readers, timers, and background workers
must enqueue events or callbacks. They do not directly mutate session
state.

**Why:** Racket makes concurrency easy, but editor state is highly
interdependent. A single writer preserves command ordering, simplifies
undo transactions, and avoids races between fast key events, LSP
updates, mouse selection, and render invalidation.

**Implementation:** Use Racket threads/channels or async-channels for
event delivery. Use custodians to clean up per-session resources. Use
places for CPU-heavy or blocking FFI/native work when needed.


## ADR: Signals vs Server-Rendered HTML

The server is the editor. The server owns all editor state. The default
is to stream rendered HTML via Datastar SSE on every state change
(CQRS — commands up, state down). Signals are the exception, not the
rule.

When this ADR says server-rendered HTML, it means the Racket core
renders HTML from editor state plus semantic UI specs supplied by
config/extensions. Config does not emit Datastar attributes or raw DOM
fragments in v1.

**Server-rendered HTML streamed as fragments on state change:**

Everything the server knows. This includes buffer content with syntax
highlighting baked in, status bar, minibuffer/echo area, file tree,
completion popup, hover docs, diagnostics panel, window layout, and
cursor representation.

When a command changes state, the server re-renders affected fragments
and streams them down. No client-side templating. No signal
interpolation for editor UI.

**Datastar signals only for state the client knows or needs to apply
locally:**

```html
<div data-signals="{
  sel: {
    anchor: {line: 0, col: 0},
    head: {line: 0, col: 0}
  },
  scroll: {top: 0},
  viewport: {rows: 40, cols: 80},
  browser: {width: 1200, height: 800}
}">
```

- `sel.anchor` and `sel.head` — line/col positions for the selection
  range of the focused window. `head` is the cursor/point; `anchor` is
  the mark. When there is no selection, anchor equals head. Per-window
  selection state is stored on the server; signals reflect the focused
  window.
- `scroll.top` — which line is at the top of the focused window.
- `viewport.rows`, `viewport.cols` — how many rows/cols the pane can
  show, so the server knows how many lines to render.
- `browser.width`, `browser.height` — browser dimensions, so the server
  can compute split layouts.

Selection signals are **bidirectional**:

- Mouse selection goes up: browser handles it natively at 60fps. On
  `mouseup`, the client reads the range and POSTs it. The server
  updates state and patches signals.
- Server-driven selection comes down: a Racket command updates point
  and mark. The server patches signals. A client effect applies the
  selection via the browser Selection API.

```javascript
// Pseudocode — real implementation must preserve selection direction
// with setBaseAndExtent and clear selection when anchor equals head.
function applySelection(anchor, head) {
  // resolve line/col to DOM nodes, apply via Selection API
}
```

That's the complete signal list for v1. Everything else is server state
rendered as HTML by Racket.

**Not even signals, just CSS:** cursor blink, focus styling, hover
effects.

**Why:** Signals introduce client-side logic. Every signal with a
`data-text` or `data-show` is rendering logic that lives outside the
server. The point of this architecture is that the server renders the
UI.


## ADR: Semantic UI Specs, Not Raw HTML in Config

Racket config controls editor behavior and presentation intent. It does
not emit raw HTML in v1.

Extensions customize the UI by returning semantic specs for known
editor surfaces: status bar segments, buffer overlays, faces, gutters,
completions, diagnostics, panels, minibuffer content, and command
palette entries.

The Racket core owns concrete DOM structure, CSS class mapping,
Datastar attributes, escaping, and SSE fragment generation.

**Why:** The extension API should describe editor concepts, not browser
implementation details. This keeps plugins stable if the DOM structure
changes, avoids exposing Datastar internals, reduces XSS risk, and
leaves room for alternate renderers later.

**Security:** Text supplied by config is escaped by the core renderer.
Extensions may name faces, slots, actions, and semantic roles, but may
not attach arbitrary HTML attributes, JavaScript, or event handlers via
the public v1 UI API.

**Trusted users can bypass this:** User config is trusted Racket code.
A user can intentionally require private modules or monkey-patch
things. That is allowed but unsupported. The stable extension API does
not include raw HTML.

**Escape hatch:** Trusted raw HTML components may be considered later,
but they are not part of the v1 extension API.


## ADR: Canonical Position Unit

Internal buffer positions are **byte offsets**. This is the canonical
representation in the private Racket core (buffer model, editor state,
render projections, and storage-facing logic).

Tree-sitter also uses byte offsets, so syntax integration does not need
conversion for parser ranges.

Public extension-facing position APIs are intentionally
**character-oriented** and Emacs-like:

- `point` and `point-char` are 1-based character positions (`1` at
  beginning of buffer; `N+1` after `N` characters).
- `point-byte` is the explicit low-level UTF-8 byte-offset accessor and
  is 0-based.

LSP uses UTF-16 line/column pairs. Conversion happens at the LSP bridge
boundary in the Racket core. Config code should normally not deal with
LSP coordinates directly.

The browser works with line/col positions only. Client `col` is the
UTF-16 code-unit offset within a rendered line, which is what
`window.getSelection()` gives naturally. The server converts `{line,
col}` to byte offsets. Mouse events include a `renderRev` so the server
can reject stale positions if the buffer changed since that DOM was
rendered.

Core movement/editing primitives validate that positions land on UTF-8
codepoint boundaries. A byte offset in the middle of a multi-byte
character is snapped or rejected according to the primitive's contract.

Markers, point, mark, overlays, and diagnostics need insertion-bias
semantics, similar to Emacs marker insertion types. This should be part
of the buffer/marker design, not bolted on later.


## ADR: Buffer Representation and Benchmark Gate

The buffer storage implementation is private, but the architecture must
allow efficient editing of non-trivial files.

**Decision:** Do not make whole-buffer Racket strings the v1 storage
architecture. Use a benchmarked piece-table/rope-like structure before
v1, unless measurements prove a simpler structure is sufficient.

**Why:** Editing by repeatedly copying whole strings will eventually
fail on large files, frequent inserts/deletes, undo history, and
incremental parse/render workloads.

**Benchmark gate:** Before v1, benchmark open, insert, delete, line
lookup, slice/render visible range, undo/redo, and save operations
against representative project files plus explicit 1MB, 10MB, and
100MB scenarios. Use the results to set public large-file claims.

**Outcome (2026-06-16):** Gate met. The buffer is now an **augmented
persistent rope** (a B+-tree of bounded UTF-8 chunks with per-node summary
metadata: utf8/char/utf16 lengths, newline count, last-line width). It is the
production backend, selected behind the unchanged `buffer-model` API; the
original whole-string implementation is retained only as a differential-test
oracle. Measured 1MB/10MB on Racket CS 9.1: per-keystroke insert/delete went
from O(n) (~0.7 s at 10MB) to flat ~0.3 ms; the O(n) string conversions
(`char→byte`, line/utf16-col→byte) became O(log n); the render window slice is
window-bounded (not whole-buffer); snapshots are ~60× cheaper via structural
sharing (enabling cheap undo / SSE revisions / background re-parse). The only
regression is whole-buffer `serialize` (the save path), now O(n) instead of an
O(1) field read — acceptable, as saving n bytes is inherently O(n) and it is
not a per-keystroke op. Full numbers, methodology, and follow-ups:
`plans/archive/buffer-rope-benchmark-results.md`. Harness: `bench/buffer-bench.rkt`
(`task bench`). A dedicated **100MB** rope run confirms the posture: per-keystroke
edits stay sub-ms to a few ms and grow only logarithmically (insert
0.29→0.27→0.63 ms across 1→10→100 MB), conversions/render stay flat, and
retaining several 100 MB edit states costs ~0.3 MB (structural sharing). Only
`load` (~1.6 s) and `save`/serialize (~1 s) are O(n) at 100 MB, inherent to
reading/writing n bytes. **Weevil edits 100 MB files interactively** (open/save
~1–2 s).


## ADR: Undo/Redo

The server owns undo history. There is no client-side undo.

Commands execute inside undo transactions. Undo/redo are Racket
commands like any other, bound to keys in the keymap.

Because every edit flows through command dispatch, undo boundaries
align naturally with commands. Consecutive `self-insert` commands can
coalesce — typing `hello` is one undo entry, not five. A macro that
runs multiple edits can be one undo transaction.

Full implementation can be deferred, but the ownership decision is made
now: server-side, command-granularity, Racket-command-controlled.


## ADR: Input Ordering

Each input event carries a monotonically increasing sequence number per
session. The server processes events in order. Each rendered update
carries a revision number. The client ignores stale updates with a
revision older than the last one applied.

This prevents out-of-order edits when typing fast or when the network
reorders requests.

The per-session event loop is the enforcement point for ordering.


## ADR: Extensibility and User Configuration Loading

Extensibility is not a plugin feature bolted onto the side of Weevil.
It is a primary architectural constraint. Weevil should feel closer to
Emacs than to a fixed editor with a small extension surface: most
editor behavior should be inspectable, replaceable, and composable from
Racket.

**Decision:** Weevil is structured as a small private editor kernel, a
large stable public extension API, and a default configuration that is
implemented through that same public API. The private kernel protects
invariants. The public API exposes editor concepts.

The core owns:

- state invariants and serialized mutation through the session event
  loop
- concrete buffer storage representation
- marker, overlay, and undo bookkeeping
- concrete rendering, escaping, DOM structure, Datastar patching, and
  HTTP routes
- subprocess/LSP/process custody and persistence mechanics

The public extension API owns the stable vocabulary users program
against:

- commands and command metadata
- command dispatch and interactive argument conventions
- keymaps, prefix maps, printable-character bindings, and lookup rules
- buffer editing and movement primitives such as `insert!`,
  `delete-region!`, `point`, `mark`, `forward-word!`, and
  `end-of-line-pos`
- window/frame operations such as split, select, display-buffer, and
  other-window
- hooks, modes, buffer-local variables, options, faces, themes, and
  semantic UI providers

**Command model (current).** Commands are nullary thunks that read their
inputs from the dynamic command context (key, payload, selected pane/buffer).
A command value also carries discovery metadata — `docstring`, `category`,
`interactive?`, and a reserved `arg-spec` — supplied via keyword arguments to
`make-command` / `define-command` and inspected through `command-docstring`,
`command-category`, `command-interactive?`, `command-arg-spec`, `all-commands`,
and `describe-command`. `arg-spec` is a seam only: `M-x`, the command palette,
and Emacs-style `interactive` argument reading are deliberately deferred and
are not yet implemented. Metadata never changes dispatch or execution
semantics.

Public modules such as `weevil/config`, `weevil/commands`,
`weevil/keymap`, `weevil/buffer`, `weevil/window`, `weevil/hooks`,
`weevil/modes`, `weevil/options`, `weevil/faces`, and `weevil/ui` are
stable extension API. Modules under `weevil/private/*` are unsupported
implementation detail. Trusted users may still require private modules,
because Racket code is trusted, but private modules can change without
compatibility promises.

**`weevil/config` is reserved for user-facing configuration.** Runtime
environment settings such as host, port, debug mode, and log level must
live under a private module such as `weevil/private/runtime-config.rkt`,
not in `weevil/config.rkt`.

**Default editor behavior is loaded as configuration.** Startup loads a
built-in default config module before user config. That default config
registers basic commands and default keybindings through the public API:
self-insert, newline, delete-backward-char, delete-char, kill-word,
backward-kill-word, kill-line, yank, save-buffer, find-file,
split-window, other-window, and similar editor fundamentals. The core
may encode raw key events and maintain command-loop invariants, but it
should not hardcode what Backspace or `C-k` means.

A user with no `init.rkt` gets a complete default editor. A user with an
`init.rkt` can customize by changing options, rebinding keys, replacing
providers, adding hooks, defining modes, or defining new commands. They
should not need to write basic editing commands unless they want a
different behavior.

**Startup config loading:**

1. resolve the config directory
2. instantiate Weevil's built-in default config
3. if `<config-dir>/init.rkt` exists, instantiate it
4. continue normal startup/session restore

The config directory resolution order is:

1. explicit `--config-dir <path>` command-line flag
2. `WEEVIL_CONFIG_DIR`
3. `$XDG_CONFIG_HOME/weevil`, when `XDG_CONFIG_HOME` is set
4. `~/.config/weevil`

For tests and local development, run with `--config-dir ./config` and
put a plain Racket module at `./config/init.rkt`.

Future phases may add `early-init.rkt`, `post-init.rkt`, or more named
startup hooks if concrete needs appear. v1 should start with one
`init.rkt` so the loading model stays simple.

**Racket loading model:** Use `dynamic-require` to instantiate config
modules for side effects:

```racket
(dynamic-require 'weevil/defaults #f)
(dynamic-require init-path #f)
```

The user's `init.rkt` is ordinary `#lang racket`. It can require public
Weevil modules and any other Racket modules. Loading it with
`dynamic-require` runs its top-level forms once in the active namespace.
Because Racket normally instantiates a module once per namespace,
live-reloading config is not trivial; hot reload should be treated as a
future feature requiring a fresh namespace, versioned module path, or
explicit unload/reload protocol.

**API shape:** Public APIs should expose opaque editor handles,
procedures, contracts, and semantic data. They should not expose raw
mutable struct fields or concrete storage types that would prevent
later replacement of buffer storage, renderer internals, or session
representation.

**Overridable definitions:** Racket module imports are lexical and
cannot be mutated by importers, so Weevil does not try to emulate Emacs
function cells directly.

Public extension APIs should prefer composable mechanisms: hooks,
keymaps/remapping, options, modes, and explicit policy-style APIs.
`define-extension-point` is a private helper used inside
`weevil/private/*`; it is an implementation detail, not a public
extension API.

When Weevil exposes singleton replacement APIs, treat them as advanced
user escape hatches and expose them under `weevil/unsafe/*` (for
example, page-template override in `weevil/unsafe/ui`), not through the
normal `weevil/config` aggregate.

See `docs/EXTENDING.md` for user-facing extension guidance.

**Emacs-inspired naming conventions:** Weevil should use predictable
suffixes for extension APIs: `*-hook` for normal no-result hooks,
`*-functions` for callback lists whose arguments or return values
matter, `*-function` or `*-provider` for single callbacks, `*-mode` for
mode commands/state, and `*-mode-map` for mode-local keymaps. Keymaps
that are NOT a major/minor mode's own map use `*-keymap` instead of
`*-mode-map` (following Emacs's own non-`*-mode-map` keymap names): the
frame-wide fallback map is `global-keymap` (Emacs `global-map`) and the
minibuffer's editing map is `minibuffer-keymap` (Emacs
`minibuffer-local-map`), even though the minibuffer is entered via
`minibuffer-mode`. Racket
modules provide namespace structure, so public identifiers do not need
a global `weevil-` prefix, but registered symbols and persisted option
names should still be namespaced.

**Terminal subsystem (current).** A terminal buffer is in scope as a bundled
feature, but it is not part of the irreducible editor kernel. Pure session state
holds only an immutable terminal snapshot on a terminal buffer. The live PTY,
terminal engine, owner thread, and controller live outside session-state in a
side table keyed by buffer id. Terminal output posts snapshot events back to the
same single-writer event loop as keys and file I/O, and terminal rendering uses
the normal display-projection path. This keeps the terminal optionalizable later
without letting live OS resources leak into pure editor state.

**v1 non-goals:** No plugin package manager, no sandboxed third-party
extension system, no automatic project-local config execution, and no
config hot reload are required for v1. Those features should be added
only after the trusted local config model is solid.


## ADR: Trusted User Configuration

User configuration is fully trusted, like Emacs init files.

The user's `init.rkt` is plain `#lang racket`. It can require arbitrary
Racket modules, read/write files, start processes, and call public
Weevil APIs. This is intentional. A malicious init file can compromise
the user account, just like a malicious Emacs init file, shell profile,
or editor plugin.

v1 does not auto-execute project-local Racket config by default. If
project-local config is added later, it should require explicit opt-in,
allowlisting, or prompting, because project files are not inherently
trusted.

Third-party package sandboxing can be considered later. It is not part
of the v1 user-config model.


## ADR: Security

Weevil can run shell commands and read/write files. It must not be
accidentally exposed over the network.

- Bind to localhost only by default.
- Require an auth token for all requests. Generate one at startup,
  print it to stdout, and pass it to the browser during the initial
  page load/bootstrap.
- After bootstrap, authenticate same-origin requests with a session
  cookie and include `X-Weevil-Token` on `fetch` requests where custom
  headers are available. SSE/EventSource-style streams authenticate via
  the same-origin cookie.
- Reject requests without a valid token/session.
- No unauthenticated LAN access. Require explicit `--listen 0.0.0.0`
  flag to bind beyond localhost.
- CSRF: check `Origin` header on all POST requests.
- Treat user `init.rkt` as trusted code, not sandboxed code.
- Do not auto-run project-local code in v1.

Racket custodians should manage per-session resources: threads, ports,
TCP connections, and subprocesses. Shutting down a session should clean
up its LSP servers, shell commands, background workers, and SSE
connections where possible.

Racket `sandbox` and security guards are available for future
untrusted-extension designs, but v1 should not pretend that normal user
config is sandboxed.


## ADR: Persistence

Session state is persisted so that restarting Weevil restores the full
workspace.

**Persisted, batched/snapshotted, not on every keystroke:**

- open buffers and unsaved content
- per-window point, mark, and scroll position
- per-buffer mode and local variables
- frame layout and window-buffer assignments
- undo history, if practical within snapshot size limits
- kill ring
- minibuffer command history
- named sessions
- recently opened files
- per-file cursor positions
- project-level state

**Not persisted:**

- LSP state; reconnect on restart
- running processes and shell sessions
- transient UI state such as completion popups and hover docs

v1 persistence uses in-process session state plus SQLite snapshots.
Snapshots are taken periodically, on focus loss, and on clean shutdown.
Do not write SQLite on every keystroke.

SQLite access goes through a persistence layer. Because SQLite uses
native/FFI calls in Racket's `db` library, long-running queries or
large snapshot work should run in a dedicated DB worker or place so the
editor event loops remain responsive.

On startup, Weevil restores the last session by default, like Emacs'
`desktop-save-mode` or the `easysession` package. Sessions can be
named, saved, and switched between.


## ADR: Racket Concurrency, Native Code, and Process Boundaries

Routine editor concurrency uses Racket threads, channels, and
async-channels. The session event loop remains the only writer for
session state.

Use Racket places or dedicated worker processes for work that is:

- CPU-heavy enough to harm interactivity
- potentially blocking in native FFI
- memory-intensive
- crash-prone or experimental

Likely candidates:

- tree-sitter parsing and query work
- large project indexing
- long SQLite snapshot/query work
- expensive LSP-side postprocessing

Subprocesses and LSP servers are owned by session or project
custodians. Output readers post events back to the session loop.
Process termination should be explicit and custodian-backed.


## What's Not In v1

- Collaborative editing
- Plugin package manager
- Sandboxed third-party plugin system
- Project-local config auto-execution
- DAP/debugger protocol
- Native desktop shell/webview
- Mobile
- Speculative local echo for typing latency
- OS-level IME integration; v1 uses Racket-side input methods
- Fixed public large-file guarantee before buffer benchmarks

These can be added later without changing the core architecture.
