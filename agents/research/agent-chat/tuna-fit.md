# Agent chat plugin: what Tuna has, what it lacks

Read-only research, 2026-10-28. Question: what a plugin hosting Pi coding-agent chats (`pi --mode rpc`) can reuse, and what is missing, under ADR 12 (small kernel). Citations are `path:line` in `/home/jay/Code/workbench-gerbil/tuna`.

## Bottom line

- **Most of it exists.** Plugin-defined node kinds with their own HTML, item-based scrolling over many nodes, text nodes, background jobs that post to the editor thread, session slots restored before the layout, `completing-read` with sources, buttons, status-line parts, the program-status hook, `find-file-noselect`, the region API, per-plugin stylesheets, and node keymaps all fit a chat buffer.
- **Five real gaps:** (1) read-only text nodes inside a writable buffer, (2) a small transient-style menu, (3) completion in the buffer (`@file`), (4) a non-terminal way to start a long-lived helper and talk to it, (5) program-status and notifications only accept *terminals*. Smaller gaps: appending a child costs O(n), there is no shared `file:line` opener, and there is no multi-line minibuffer prompt (the chat's own prompt node removes the need for one).
- **None of these needs kernel code.** Each belongs in an existing plugin's contract or in the new chat plugin.

## 1. Buffers and nodes

- **A buffer is a named tree of nodes.** Text nodes refer to texts. Plugins define every other kind (`plugins/buffers/contract.ss:8-11`). API: `new-node kind attributes: children: keymap:` (`:680`), `new-text-node` (`:693`), `set-node-attribute!` (`:710`), `set-node-children!` (`:751`), `node-children` with a range (`:740`), `set-node-keymap!` (`:719`).
- **A kind is defined per plugin context and goes away with the plugin.** Use `context-define-node-kind! ctx name doc: project: items:` (`:779`). `items:` is `'children` or `'whole` (`:302-312`). `context-define-node-renderer! ctx kind (lambda (n children) sxml)` returns SXML, and the already-rendered children are opaque (`:794-803`). `project:` gives the plain text used for search and copy (`:821`).
- **Revisions.** Every node has a source. Any change to a node or below it gives it a larger revision (`:11-12`, `:729`). Setting an attribute to the same value keeps the revision (`:707-710`). Drawing reuses HTML per piece through `memo` (ADR 17).
- **Kinds that exist today.** Built-in: `text`, `minibuffer` (`plugins/minibuffer/contract.ss:34`), `echo-area` (`plugins/echo-area/contract.ss:21`), `button` (`plugins/buttons/contract.ss:22`), plus terminal rows. There is no generic "section", "collapsible" or "columns" kind. Each plugin makes its own. `demo/mixed.ss` is the model for a chat. It is a long buffer of 2,000 sections: headings, wrapped paragraphs, code blocks, cards and pictures (`demo/mixed.ss:1-7`, kinds `:105-116`, renderers `:117-137`). Its paragraphs and code blocks are editable text nodes that open into lines (`:44-60`). Cards are one item each (`:62-71`).
- **Proportional vs monospace is pure CSS.** The page font defaults to monospace (`plugins/web/tokens.css:7`). The mixed demo picks a mono token for code (`demo/mixed.css:9`). A chat sets its prose font in its own `tokens.css`.
- **Scrolling many nodes (ADR 15).** A view lays out *items*: a text node's lines, a `'children` node's children's items, or a `'whole` node as one item (`contract.ss:836-850`, `node-opening` `:871`). Item counts are cached per node and revision, and only a changed child is counted again (`:851-858`, `:881-925`). Only about two screens are drawn each way (`drawn-screens`, `:418`). A chat of thousands of messages scrolls as `*mixed*` does.
- **Appending while streaming.**
  - Tokens go into a text node with `text-replace!` at its end (`contract.ss:612`). It is cheap: a rope with a change journal. Owner-side changes bypass `buffer-read-only` (`:1682-1685`). Streamed text should not fill undo: use `text-clear-undo!` (`:638`) or amalgamate.
  - Adding a message node costs O(n): `set-node-children!` replaces the whole list (`plugins/buffers/plugin.ss:457`), and `children-items-of` rebuilds vectors over all children (`contract.ss:885-893`), although it reuses kept counts. That is fine for hundreds of messages. For thousands, see Gap G6.
  - "Changed since revision" means only the streaming message redraws.
- **Read-only vs editable.** The only read-only flag is per buffer: the `buffer-read-only` setting (`contract.ss:1686`). It is checked by `check-writable` for the editing primitives (`:1690-1704`). Every text node in a writable buffer can be edited, and the renderer has no per-node read-only (grep finds none in `plugins/renderer/plugin.ss`). The terminal works around this by flipping the whole buffer read-only in copy mode (`plugins/terminal/plugin.ss:1564`, `:1596`). This is **Gap G1**: the chat wants read-only transcript text nodes you can select and copy, beside an editable prompt node.
- **Keeping the prompt at the bottom.** Make the root's children `[message ... prompt-node]` and always insert new messages before the last child. The view's focus is "the focused text node" (`contract.ss:20`, `:391-396`, `set-view-focus!` `:116`). A keymap on the prompt node (RET to send, M-p history) comes first in key resolution (`plugins/keys/contract.ss:12-18`). Scroll-to-bottom on new output: a placement aligned `'bottom` (`contract.ss:316-327`).

## 2. Terminal helper, session slot, restore on start

- **The pattern (ADR 18).** One helper per terminal. It detaches with `setsid -f [systemd-run --user --scope]`, listens on a private socket in `$XDG_RUNTIME_DIR/tuna/terminals/` (mode 0700, peer uid checked), serves one Tuna at a time, and speaks versioned frames. Restarts, crashes and swaps all take one path: reconnect from the helper list in the session slot (`agents/adr/0018-terminals-in-helper-processes.md:19-27`, as built `:38-50`).
- **Reusable (generic, but private to the terminal package today):**
  - `plugins/terminal/connection.ss`: `helper-launch` (`:16`, struct region), `in-systemd-unit?` (`:31`), `helper-command`/`launch-helper!` (setsid plus scope, `:40-60`), `wait-for-socket` (`:70`), a writer thread so the editor never blocks (`:81`, header `:11-13`), and the frame inbox with a bound (flood pacing).
  - `plugins/terminal/io.ss`: unix listen, accept and connect, raw-device reads and writes, a private 0700 directory, `start-session` (`:329-398`). It also holds the pty spawn C code (`:75`, `:280`), which is terminal-specific.
  - The protocol framing (1-byte type, 4-byte length; `plugins/terminal/protocol.ss:2-5`) is generic. Its message set (snapshot, resize, colors) is not.
- **Terminal-specific:** `helper.ss` (libghostty emulator, pty, screen saving; `plugins/terminal/helper.ss:1-27`), `screen.ss`, `saved-screen.ss`, `keys.ss`, `copy-text.ss`.
- **The plan already foresaw sharing:** "Starting programs … lives in the helper until a second user needs it, then moves to the planned process library" (ADR 18 `:36`). The roadmap lists a **process library** (shared code, not a plugin) for exactly this (`docs/roadmap.md:71`). Plugins may not import another package's private files (tuna/AGENTS.md), so the chat cannot import `plugins/terminal/connection.ss`. See Gap G4.
- **Session slot.** Register with `context-add-session-slot! ctx 'terminals version: 2 save: restore:` (`plugins/terminal/plugin.ss:2485-2487`; contract `plugins/session/contract.ss:38-64`). Slots restore in registration order (`session/contract.ss:42-43`). As built, "the plugin is declared before the layout, so its session slot makes the terminal buffers before the layout restores the views" (ADR 18 `:45`).
  - Save: a plain list per terminal (`plugin.ss:2198-2210`).
  - Restore: recreate buffers with `unique-buffer-name`, start the readers, and re-point views that a swap left on another buffer (`:2212-2233`).
  - Restores during start-up are queued until the editor loop runs (`:560-562`, drained at `:2480-2484`).
  - The chat copies this shape: slot data `(id socket buffer-name pi-session-file cwd)`.

## 3. Background reading → editor thread

- **Job groups** (`tuna/lib/jobs.ss`): `new-job-group ctx` (`:111`), `job-group-start! group key input: run: apply:` (`:145`), `job-cancel!` (`:185`), `job-sleep` (`:195`). `run` runs on its own thread with `(input cancelled? post!)`. `apply` runs on the editor thread, once for each post (`post-result!` `:230`).
- **The terminal's reader is the template.** `start-reader!` (`plugins/terminal/plugin.ss:549-562`) and `reader-run` (`:568-596`): launch, wait for the socket, connect, post `'connected`, loop over reads into a bounded inbox, and post `'frames` only when the inbox was empty. `receive!` (`:607-627`) applies batches on the editor thread and handles `'gone` → revive and `'ended`.
- **Pi RPC is JSON lines.** The chat's `run` reads lines and posts parsed events, batched the same way. Parsing JSON can also happen on the job thread, since results are plain data.
- **Also available:** `off-thread`, `sleep-for` and sources (`tuna/lib/background.ss:104`, `:156`, `context-start-source!` `:186`), which the files watcher uses (`plugins/files/watcher.ss:4-13`).
- **Validity:** the capability audit flagged that append-only streams must not be gated on revision (`agents/research/capability-audit/04-package-stress-tests.md:19`, `:203`). Jobs now have policies (`jobs.ss:100-101`: `exact-revision`, `target-alive`, `rebase`; `queue`, `latest`), and the terminal reader shows the right shape.

## 4. Minibuffer, completing-read, prompts, echo area

- **`read-from-minibuffer`/`read-string`** suspend the command, direct style (`plugins/minibuffer/contract.ss:1-5`, `:76-84`). The `Prompt` handle has `prompt-buffer`, `prompt-answer-node`, a prompt-local keymap, an exit check and `prompt-exit!` (`:49-70`). Named histories exist (`:87`).
- **`completing-read question sources require-match: initial: history: default: setup:`** (`plugins/completion/contract.ss:75-81`). It takes several sources with titles and groups (Consult style, `:16-27`), candidates with explicit values (`:12`), and annotators per category (`:94`).
  - This covers the **chat picker** (candidates = live chats, value = chat object), the **model picker**, and Pi extension **select** UI requests.
  - The **confirm** request needs a yes/no reader. Grep found no `y-or-n-p`. The smallest version is `completing-read` over `["yes" "no"]`, or `read-string` with an exit check; a real `y-or-n-p` belongs in the minibuffer contract only once a second user exists.
  - The **input** request maps to `read-string`.
- **Multi-line prompt:** the minibuffer answer is one text node. RET exits; newline handling is noted at `plugins/minibuffer/plugin.ss:13`. The chat's own bottom prompt node is the multi-line editor, so the minibuffer needs no change. Pi's `editor` UI request can prefill the chat prompt node.
- **Echo area:** `message` (used by notifications, `plugins/notifications/plugin.ss:26`). `current-message` is at `plugins/echo-area/contract.ss:26`.

## 5. Transient / which-key / menu

- **None is built.** There is no transient, hydra, which-key or `set-transient-map`. The audit lists them as "later": transient as "a suspended command that owns a modal keymap and renders a rich popup" (`04-package-stress-tests.md:86`); `set-transient-map` (`01-command-loop-and-input.md:93`); pending-prefix inspection as a better which-key, because the loop owns key resolution (`01-…:67`, `:253`). `docs/ideas/modes.md` covers modes per node, not menus.
- **The building blocks exist:**
  - The input-target stack: "a keymap pushed on the input-target stack: while it is the innermost target, keys resolve in KEYMAP before the global keymap" (`plugins/keys/contract.ss:277-281`; resolution order `:12-18`).
  - The `Prompt` handle can add nodes to the minibuffer buffer through the ordinary buffers contract (`minibuffer/contract.ss:50-51`).
  - `completing-read`'s `setup:` adds prompt-local nodes and keys (`completion/contract.ss:71-74`). The file picker does this (`plugins/files/picker.ss:15-18`).
- **Smallest thing that fits:** a chat-local `chat-menu` command that calls `read-from-minibuffer` with `setup:`. Setup draws a grid of `key → label` nodes in the prompt buffer (rendered by the chat plugin's own node kind and CSS) and binds each single key in `prompt-keymap`, where the binding calls `prompt-exit!` with the command symbol. Then `call` that command.
  - It needs no new service and no kernel change. It is roughly one function plus one node kind.
  - It is *not* a general transient: there are no infix arguments and no persistent values.
  - Promote it to its own `menus` plugin and contract only when a second plugin wants one (AGENTS: "add a framework only when a second concrete user needs it").

## 6. program-status and notifications

- **program-status** follows only terminal hooks (`plugins/program-status/plugin.ss:4-6`, hooks `:156-172`). Records are keyed by terminal. Its contract hook passes "a terminal, a record id …" (`plugins/program-status/contract.ss:12-14`). Status shows through `context-add-status-line-part!` (import at `plugin.ss:24`; `plugins/renderer/contract.ss:25`, `:98`).
- **notifications** listens to `terminal-notification-hook` and `program-status-change-hook`. It calls `(terminal-buffer t)` and decides "looked at" by buffer (`plugins/notifications/plugin.ss:25-31`, `:35-49`).
- **The record type is neutral:** `program-status-report` with id, state (`idle|working|done|blocked|error`), kind (`permission|question|auth`), progress, app, title and message (`plugins/terminal/contract.ss:93-108`). It maps exactly onto Pi's working, blocked-on-approval and done states. It lives in the terminal contract, though.
- **So a chat cannot feed them today without pretending to be a terminal.** See Gap G5. Both plugins only ever use the terminal's *buffer*.

## 7. Files: open at line, file:line links, completion, selection

- **Open:** `find-file-noselect` and `find-file` (`plugins/files/contract.ss:199-206`). Goto: `goto-char` (`plugins/buffers/contract.ss:1678`) and `text-position-at line column` (`:606`).
- **file:line exists only privately in the terminal.** `plugins/terminal/links.ss:1-6` finds `FILE:LINE[:COLUMN]` for files that exist, plus URLs, as `fileref:` URIs. `open-link!` opens them in a buffer at the line (`plugins/terminal/plugin.ss:858-890`, RET at `:2548`). The chat cannot import that private file. See Gap G7.
- **Buttons** for clickable links: `new-button label action attributes:` (`plugins/buttons/contract.ss:1-10`, `:28`). A tool-output line can carry a node keymap with `RET` instead.
- **File-name completion:** `file-table from` and `recent-file-table` are exported, but from `plugins/files/picker.ss:24-25`, which is a *private* file. Only `plugins/files/plugin.ss:747` uses them. The `@file` mention needs (a) a completion table reachable through a contract and (b) in-buffer completion. There is no completion-at-point (grep finds none). See Gap G3.
- **File watcher:** inotify on folders with polling as a fallback (`plugins/files/watcher.ss:4-13`). Unmodified buffers reload by diff (roadmap `docs/roadmap.md:69`, stage 3). When Pi edits files, the editor already follows them, and unsaved buffers get the conflict question.
- **Selection:** `region-active?`, `region-beginning`, `region-end` and `deactivate-mark!` in the editing contract (`plugins/editing/contract.ss:28-39`). `text-substring` gives the text (`buffers/contract.ss:565`) and `buffer-file` gives the source path (`files/contract.ss:219`). That is enough for "send selection with path:lines".
- **Terminal output for "send to chat":** `terminal-buffer` plus the buffer's text projection (`node-text-projection`, `buffers/contract.ss:821`). There are also the command-finish hooks (`terminal/contract.ss:72-78`). For *errors*: there is no `*Messages*` or error log to read yet. Error recovery is roadmap tier 0 (`docs/roadmap.md:68`).

## 8. Stylesheets, keymaps, modes

- **Each plugin ships `tokens.css` and `rules.css`** and registers them with `(add-stylesheet 'tokens "tokens.css")` / `(add-stylesheet 'rules "rules.css")` (`agents/guides/html-css.md:59-75`). There are no colours in Gerbil. The mixed demo does the same (`demo/mixed.ss:104`).
- **Buffer-local keymaps are built** as node keymaps. The root node's keymap is the buffer's local map (`plugins/buffers/contract.ss:12-18`; order `plugins/keys/contract.ss:12-18`). Buffer-local settings are built too: `set-buffer-setting!`/`buffer-local-value` (`buffers/contract.ss:1168-1180`).
- **Modes are not built.** `docs/ideas/modes.md` is "desired, not scheduled". The terminal uses switched node keymaps until modes exist, and must migrate later (`modes.md` last paragraph). The chat should do the same: a root keymap plus a prompt-node keymap.

## 9. Capability audit on LLM/agents

- **D11 "Chat as node tree"** (message nodes, tool calls, reasoning, code blocks, streaming into text nodes, collapsible tool output, the prompt editable while the stream continues; `04-package-stress-tests.md:321`). This matches the owner's decision.
- **Row 87, streaming insertion:** an append-only stream targets a node, not a revision (`:203`, break scenario `:258`). This is already solved by job policies and the terminal reader pattern.
- **Row 73, comint:** "output as stream nodes, prompt as a rich node" (`:179`).
- **CR4:** a non-interactive, baton-holding task started by process events (gptel) (`:18`). Job `apply` covers it today.
- **Roadmap:** an `llm` plugin (chat and agents) is listed among later plugins (`docs/roadmap.md:99`).

## 10. Gaps, owners, smallest versions

| # | Need | Missing today | Owner (ADR 12 placement) | Smallest version |
|---|---|---|---|---|
| G1 | Read-only transcript text beside an editable prompt | Only `buffer-read-only` exists (`buffers/contract.ss:1686`) | **buffers contract** (it owns `check-writable`) | A `read-only` node attribute: `check-writable` refuses when the focused text node or an ancestor has it. About 5 lines. The owner still writes with `text-replace!`. Alternative with no contract change: transcript text nodes are not focusable and render from attributes, but then motion, selection and copy are lost. G1 is preferred. |
| G2 | Transient-like chat menu | No menu facility (§5) | **chat plugin** | A prompt with `setup:` that draws key→label nodes and binds single keys to `prompt-exit!`. Promote to a `menus` plugin on a second user. |
| G3 | `@file` completion in the prompt | No completion-at-point; file tables are private (`files/picker.ss:24`) | **files contract** exports a `file-completion-table` (moved from the picker). The chat's prompt keymap binds `@`/TAB to a command that runs `completing-read` over it and inserts `@path` | The minibuffer-based pick is enough at first. Inline popup completion (corfu-like) is a separate, later completion feature. |
| G4 | Pi survives Tuna restarts | Helper launch, socket and framing are private to `plugins/terminal/` | **The process library** in `tuna/lib/` (roadmap `:71`, ADR 18 `:36`): move `connection.ss` launch/socket/frame-inbox and the io.ss socket parts there. The terminal and the chat both import it. The terminal keeps pty/libghostty. | A `tuna-agent-helper` that is a *relay*: it starts `pi --mode rpc` on pipes, keeps the last N KiB or the events since an ack, and serves one Tuna on a 0700 socket. On a reboot, restart Pi with its saved session file (Pi persists sessions on disk). Check Pi's own resume flags before designing. |
| G5 | Chat status and notifications | program-status and notifications are typed to `terminal` (`program-status/contract.ss:12`, `notifications/plugin.ss:25-31`) | **program-status contract** | Move `program-status-report` into the program-status contract and key records by *buffer* (the only thing either plugin uses). Add one entry point, `report-program-status! buffer report`, that the terminal's hook handler and the chat both call. Notifications then needs no change beyond `buffer`. No compatibility aliases (AGENTS). |
| G6 | Cheap append of message nodes | `set-node-children!` is O(n) (`buffers/plugin.ss:457`) | **buffers contract**, only if measured | Do nothing at first. If a 2,000-message chat is slow in the profiler, group messages into `'children` chunk nodes (for example 100 per chunk), so an append touches one chunk. That needs no contract change. Add an `insert-node-child!` only if chunking is not enough. |
| G7 | RET on file:line in tool output | Finder and opener private to terminal (`terminal/links.ss`, `plugin.ss:858`) | **files contract**: `find-file-at-line path line column` and a small `file-references text` finder, used by the terminal and the chat | For tool output Pi gives structured paths (edit and read tool arguments), so the chat can attach a keymap or button with the path directly and needs no regex at first. |
| G8 | Yes/no for Pi confirm UI | No `y-or-n-p` | **chat plugin** now. The minibuffer contract later, on a second user | `completing-read` over `["yes" "no"]` with `require-match`. |
| G9 | "Send error to chat" | No error log or `*Messages*` buffer | Error-recovery work (roadmap tier 0) | Start with selection, terminal output and the echo area's `current-message`. Errors come later. |

- **What the chat plugin itself owns:**
  - Node kinds: `chat`, `chat-message` (role attribute), `chat-tool` (collapsible via an attribute plus a `'children`/`'whole` switch), `chat-prompt`.
  - Renderers and CSS, the RPC event → node mapping, the job reader, the session slot, commands, the menu, the chat picker, and send-selection and send-region commands.
- **It requires** `buffers`, `commands`, `input`, `minibuffer`/`completion`, `session`, `settings` and `files`. Status goes through the program-status contract after G5.
- **Kernel growth: none.**

## Residual risks

- I did not check Pi's RPC protocol here: the event names, whether Pi itself can resume a session or attach to a running process, and whether the extension UI request kinds are exactly select, confirm, input and editor. G4's helper design depends on it.
- Per-node read-only (G1) may interact with the region, yank, `delete-selection` and mouse selection paths that call `text-replace!` directly. Grep those callers before choosing the check site.
- A collapsed tool node toggling between `'children` and `'whole` is a per-node decision, but `items:` is per *kind* (`buffers/contract.ss:302-312`). Collapsing may need two kinds or a node with no children while collapsed.
