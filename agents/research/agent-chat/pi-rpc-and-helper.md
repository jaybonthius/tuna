# Pi RPC protocol and a persistent helper for Tuna's agent chat

Research only, 2026-10 (Pi 1.4.0 installed, Node v24.14.0). Evidence, not decisions.

Abbreviations: `DOCS` = `…/@earendil-works/pi-coding-agent/docs/` and `DIST` = `…/pi-coding-agent/dist/` under
`/home/jay/.local/share/pnpm/global/5/.pnpm/@earendil-works+pi-coding-agent@1.4.0_…/node_modules/@earendil-works/pi-coding-agent/`.
`CORE` = `…/@earendil-works+pi-agent-core@1.4.0_…/node_modules/@earendil-works/pi-agent-core/dist/`.
JSONL = one JSON object per line.

## 1. Protocol summary

**Framing** (DOCS/rpc.md "Framing"; DIST/modes/rpc/jsonl.js)
- Strict JSONL in both directions. Split on LF only and strip a trailing CR. Do not split on U+2028/U+2029; Node `readline` does, which is why Pi has its own reader in `jsonl.js`.
- Stdout carries only protocol records. Stderr carries logs; one experiment printed `level=info msg=mem.init …` there. Never parse stderr.
- Pi honours stdout backpressure (`waitForRawStdoutBackpressure`, rpc-mode.js ~line 262), so a reader that stops reading stalls Pi.
- Four record families (rpc.md "Protocol records"):
  - commands on stdin;
  - `{"type":"response","command",…,"success","data"|"error","id"?}`;
  - session events, which have no id;
  - `extension_ui_request`/`extension_ui_response`.
- Correlate by `id`, never by order. `handleInputLine` is started with `void` per line (rpc-mode.js ~line 660), so commands run concurrently and responses can arrive in any order. `prompt` returns its response asynchronously through `preflightResult` (rpc-mode.js 298–317).
- Malformed input gets `{"type":"response","command":"parse","success":false,…}` with no id. I verified this by sending `not json`.
- Shutdown: when stdin closes, Pi runs `shutdown()` (rpc-mode.js `onInputEnd`). SIGTERM and SIGHUP also shut it down: it kills tracked detached children and exits with 143 or 129. An extension may request shutdown; Pi honours it after the current command or after `agent_settled`.

**Commands Tuna needs** (DOCS/rpc-commands.md; dispatch in DIST/modes/rpc/rpc-mode.js `handleCommand`)
- `prompt {message, images?, streamingBehavior?: "steer"|"followUp"}`.
  - While streaming, `streamingBehavior` is required; without it the command errors.
  - On success, `data.disposition` is `started`, `queued`, or `handled`. With `handled`, no run starts, so do not wait for `agent_settled`.
  - Failures after acceptance arrive only as events and messages.
  - `/skill:`, prompt templates, and extension `/commands` are expanded or run, even while streaming.
- `steer` and `follow_up {message, images?}` return a disposition of `queued` or `handled`.
- `clear_queue` returns `{steering[], followUp[]}`. For Esc behaviour, send `clear_queue` and then `abort`.
- `abort` waits until the session is idle before it responds. Since 0.84.x it also cancels a manual compaction (CHANGELOG ~line 743).
- `get_state` returns `{model?, thinkingLevel, isStreaming, isCompacting, steeringMode, followUpMode, sessionFile, sessionId, sessionName?, autoCompactionEnabled, messageCount, pendingMessageCount}` (rpc-mode.js 345–360).
- `get_messages` returns `{messages: AgentMessage[]}`, which is the live `agent.state.messages` (agent-session.js:1230).
- `get_entries {since?}` returns `{entries, leafId}`.
  - It covers the full append-only tree, including messages from before a compaction and abandoned branches.
  - `since` is a durable cursor (an entry id). An unknown id is an error (rpc-mode.js 503–514).
- `get_tree` returns `{tree:[{entry,children,label?}], leafId}`.
- `get_fork_messages` returns `{entryId, text}` pairs. `fork {entryId}` returns `{text, cancelled}`. `clone` returns `{cancelled}`.
- `new_session {parentSession?}` and `switch_session {sessionPath}` return `{cancelled}`; an extension can veto them.
- `set_session_name {name}`; the change also emits `session_info_changed`.
- `set_model {provider, modelId}`, `cycle_model`, `get_available_models`. Each Model object includes provider, id, reasoning, input, cost, and contextWindow (rpc-commands.md "Model object").
- `set_thinking_level {level}`, `cycle_thinking_level`, `get_available_thinking_levels`. Levels go up to `max` (CHANGELOG ~line 1455).
- `set_steering_mode` and `set_follow_up_mode` (`all` | `one-at-a-time`).
- `compact {customInstructions?}` returns the result `{summary, firstKeptEntryId, tokensBefore, estimatedTokensAfter, usage?, details}`. `set_auto_compaction {enabled}`.
- `set_auto_retry {enabled}`, `abort_retry`.
- `bash {command, excludeFromContext?}`.
  - Output streams as `bash_execution_update {id, delta}`; these updates carry the command's id.
  - The final response holds the result, and the result is recorded in the conversation.
  - `abort_bash` stops it.
- `get_session_stats` returns tokens, cost, and `contextUsage {tokens, contextWindow, percent}`. `tokens` and `percent` are null just after compaction.
- `export_html {outputPath?}` returns `{path}`. `get_last_assistant_text`.
- `get_commands` returns extension commands, templates, and skills; run one as a `prompt` starting with `/`.

**Event stream** (DOCS/json.md)
- Lifecycle:
  - `agent_start`;
  - `turn_start`;
  - `turn_end {message, toolResults}`;
  - `agent_end {messages, willRetry}`, which ends one low-level run;
  - `agent_settled {aborted}`: Pi will not continue on its own. Wait for this, not `agent_end`.
- Messages: `message_start {message}`, then `message_update {usage, assistantMessageEvent}`, then `message_end {message}`. `message_end` is authoritative: replace the partial message with it.
  - Since ~0.84 `message_update` is delta-only, with no cumulative `message` or `partial` (CHANGELOG ~line 976). Its sub-events are `text_*`, `thinking_*`, and `toolcall_start/delta/end`, keyed by `contentIndex`. Each `*_end` carries the authoritative block.
- Tools: `tool_execution_start {toolCallId, toolName, args}`, then `tool_execution_update {…, partialResult}`, then `tool_execution_end {…, result, isError, durationMs?}`.
- Queue and state: `queue_update {steering, followUp}` carries the complete queue each time. Also `entry_appended`, `session_info_changed {name?}`, and `thinking_level_changed {level}`.
- Compaction: `compaction_start {reason: manual|threshold|overflow}`, then `compaction_end {reason, result?, aborted, willRetry, errorMessage?}`.
- Retry: `auto_retry_start {attempt, maxAttempts, delayMs, errorMessage}`, then `auto_retry_end {success, attempt}`. Summarisation retries: `summarization_retry_scheduled`, `_attempt_start`, `_finished`.
- RPC only: `bash_execution_update`, `extension_error {extensionPath, event, error}`.

**Extension UI** (DOCS/rpc-extension-ui.md; rpc-mode.js 40–200, 610–625)
- Dialogs (`select`, `confirm`, `input`, `editor`) block until Pi receives `{"type":"extension_ui_response","id",value|confirmed|cancelled:true}`. A dialog may carry `timeout` ms.
- Fire-and-forget methods: `notify`, `setStatus {statusKey, statusText?}`, `setWidget {widgetKey, widgetLines?, widgetPlacement}`, `setTitle`, `set_editor_text`. An absent text or lines field clears that key.
- **Observed:** on start-up with the owner's global extensions, Pi emits about 11 `setStatus`/`setWidget` requests before any command (powerline, plannotator, multi-pass). Tuna will receive these even though it runs no extension of its own. Starting Pi with `--no-extensions` (`-ne`; it turns off extension discovery *and* the built-in extensions) or ignoring unknown keys would be a product choice.
- `custom()`, themes, and the footer/header calls are no-ops in RPC mode.

## 2. Reconnect: what the helper must buffer

**What the RPC state queries include (verified in source)**
- `get_messages` contains **completed messages only**:
  - `agent.state.messages` gains a message only on `message_end` (CORE/agent.js 401–409).
  - The in-progress assistant message is kept separately in `state.streamingMessage`, and no RPC command exposes it.
- In-flight tools are tracked only as ids in `state.pendingToolCalls` (CORE/agent.js 411–420). Partial results are not stored anywhere queryable.
  - The assistant message that contains the tool calls is already complete, so it appears in `get_messages` with its `toolCall` blocks.
  - The tool result shows up only after `tool_execution_end` and the toolResult `message_end`.
- `get_state` gives `isStreaming`, `isCompacting`, and `pendingMessageCount`, but not the queue text, retry status, or pending dialogs.
- Pending dialogs live in the closure map `pendingExtensionRequests` (rpc-mode.js 41). No command lists them.
  - A dialog resolves silently when its timeout fires or its abort signal trips; no event is emitted.
  - A late `extension_ui_response` for an unknown id is ignored (rpc-mode.js 616–624), so replaying a stale dialog is harmless.
- Persistence happens at `message_end` (agent-session.js:767 `appendMessage`). The session file therefore matches `get_messages` and `get_entries` for completed messages.

**Simplest correct replay rule: snapshot plus open items, done by the helper**

The helper parses each stdout line only far enough to read `type`, `id`, `toolCallId`, and the UI keys. It keeps:
1. **Open items**, in arrival order:
   - the current assistant message's `message_start` and all its `message_update`s, dropped at its `message_end`;
   - `tool_execution_start`/`_update` per `toolCallId`, dropped at `_end`;
   - an open `compaction_start`, `auto_retry_start`, or `summarization_retry_*`, dropped at the matching end;
   - `bash_execution_update`s for a `bash` id whose response has not been relayed.
   Collapse `message_update`s if memory matters. Delta-only means the full list must be kept, or the helper can fold them into the block texts.
2. **Sticky last values:**
   - the latest `queue_update`;
   - the latest `setStatus`/`setWidget` per key and the last `setTitle`;
   - `set_editor_text`, optionally.
3. **Pending dialogs:** each `extension_ui_request` dialog, dropped when Tuna's response is forwarded or when `timeout` elapses. `agent_settled` does not drop them; an extension command can open a dialog while Pi is idle.
4. **Pending command ids** sent by the previous Tuna. If a response arrives while no Tuna is attached, drop it. Tuna re-queries on reconnect.

On connect:
- The helper itself sends `{"id":"helper:state","type":"get_state"}` and `{"id":"helper:messages","type":"get_messages"}` to Pi. (Pi correlates by id, and the helper swallows these ids.)
- When `helper:messages` is relayed, the helper sends Tuna, in order: the state, the messages, the open items as they stand at that point in the stream, the sticky values, and the pending dialogs. After that, everything goes live.
- This is correct because Pi writes the response and the events to one ordered stdout. Every message completed before the response is in the snapshot, and every record after it is relayed live, so nothing is duplicated or lost.
- Tuna can instead use `get_entries` (and `since` later) when it wants the tree or compaction history. The same ordering argument holds.
- This keeps the helper free of transcript logic. A simpler alternative is to buffer every record since the last `agent_settled` and let Tuna dedupe. That fails because the run log grows without bound on long autonomous runs, and dedupe needs message counting that compaction breaks.

## 3. Helper shape

**Tuna's terminal helper today** (ADR 18; agents/plans/terminal.md stage 2; plugins/terminal/{helper,io,connection,protocol}.ss)
- Gerbil executable `tuna-terminal-helper` (build.ss `exe: "helper"`).
- Started as `setsid -f [systemd-run --user --scope --collect --unit tuna-terminal-ID] helper --socket …`. It then calls `setsid` and drops stdio, sending stderr to `ID.log`.
- Socket in `$XDG_RUNTIME_DIR/tuna/terminals/` (falling back to `/tmp/tuna-UID/terminals`). The directory is mode 0700, with its owner checked (io.ss:190–194); the socket is 0600 and the peer is checked with `SO_PEERCRED` (io.ss:155–164).
- Versioned framed protocol (protocol.ss). One Tuna at a time: a second gets `refused "busy"` and Tuna retries every 100 ms.
- The session slot lists `(ID SOCKET BUFFER-NAME …)`. A stale socket is deleted, and then Tuna restores from the saved state.
- The helper ends after the program exits and Tuna sends `exit-ack`, or on `kill`. On SIGTERM it saves state.

**Options**
- **(a) Node script.** Pi already needs Node ≥ 22.19 (package.json engines). Unix sockets come from `net` and JSONL from about 30 lines of code.
  - Node has no `SO_PEERCRED`, so it would rely on the 0700 directory alone.
  - It adds a second language to the repository, with its own tests and packaging, and its detach and systemd-scope logic would duplicate Tuna's.
- **(b) Gerbil program, `tuna-agent-helper`.** It would use the same detach recipe, socket directory checks, peer check, framed and versioned protocol, logging, and test harness as the terminal helper. JSON comes from `:std/text/json`, and process pipes from `open-process`.
  - Plugin-boundary rule: the agent plugin may not import `plugins/terminal/io.ss`. The shared pieces (private socket directory, listen and accept with the peer check, detach command) must move to `tuna/lib/` first. That move is due anyway, since this is the second user (ADR 18 Consequences; AGENTS.md "add a framework only when a second user needs it").
- **(c) The terminal helper itself.** It is built around a pseudo-terminal and libghostty, and Pi needs pipes, not a terminal. Reuse would bloat the helper and break "does one job." Rejected.

**Recommendation: (b), a small Gerbil helper, one per chat.**
- It has one job: hold Pi's pipes, relay JSONL, keep the replay state from §2, and accept one Tuna at a time.
- Arguments: `--socket PATH --directory CWD -- pi --mode rpc [--session FILE | --session-id ID]`.
- The protocol stays plain JSONL over the socket: the helper's own `hello {version, piVersion}` first, then Pi's records verbatim. This avoids a second framing layer.
- Idle exit: the helper closes Pi's stdin and exits after a grace period when all of these hold:
  - no Tuna is attached;
  - the last state is settled (`agent_settled` seen after the last `agent_start`, with no open compaction, retry, or bash);
  - no dialog is pending.
  Closing stdin makes Pi shut down in order. Its file is already written, because appends are synchronous.
- Pi exiting on its own: the helper keeps the exit status and stderr tail and reports them to the next Tuna before it ends (the terminal helper's `exit-ack` pattern).
- Reboot:
  - The session slot keeps `(chat-id, sessionFile, cwd, name)`, taken from `get_state`.
  - A missing or stale socket means Tuna starts a new helper with `pi --mode rpc --session <sessionFile>` in that cwd.
  - Nothing is rerun. A run that was mid-flight at reboot is simply incomplete; Pi persists only completed messages.
- Caveat: a brand-new chat has no session file until its first user or assistant message (session-manager.js `_persist`, ~line 797). Nothing needs restoring in that case. To fix the path up front, pass `--session-id <uuid>`.

## 4. Session-file concurrency

- **There is no locking.**
  - session-manager.js uses `openSync(file,"wx")` only for the first flush, then `appendFileSync` per entry (lines ~797–812). It holds no lock and keeps no open file descriptor.
  - The docs say nothing about concurrent writers (sessions.md, session-format.md).
- With two writers on one file, each process appends to its own in-memory tree. Lines interleave, branches diverge by `parentId`, and neither process sees the other's entries until it reloads. The file stays parseable, since small O_APPEND writes are effectively atomic on local filesystems, but the history becomes a confusing tree.
- Detection:
  - Within Tuna, give at most one helper per session id. The socket name can be derived from the session id; before starting a helper, connect to that socket. A live socket means the session is in use, so attach to it instead.
  - A Pi TUI outside Tuna on the same file cannot be detected cheaply, because Pi holds no file descriptor or lock. An optional heuristic: if the file grows with entry ids that `get_entries` does not return, warn. Otherwise document "don't open the same chat in two Pis."

## 5. Minimum Pi version

- Features relied on, with the version that added them (CHANGELOG.md):
  - delta-only `message_update`: ~0.84;
  - `get_entries`/`get_tree`: 0.80.3;
  - `agent_settled`: 0.80.4;
  - prompt `disposition`: 0.99.0;
  - `agent_settled.aborted`: 1.1.0;
  - `get_entries since`: present in 1.4.0 (rpc-mode.js 503), release not identified.
- Recommend **≥ 1.4.0**, the version tested here. The simplest rule is "the tested version or newer."
- How to check:
  - Run `pi --version`, which prints `1.4.0`. Parse it as semver in the helper before starting Pi and include it in `hello`. Tuna reports "Pi too old" and does not start the chat.
  - The RPC protocol has no version command. A runtime probe such as `get_entries` with a bogus `since` would only confirm the feature.
  - Node needs to be ≥ 22.19 (engines); Pi itself fails clearly on an older Node.

## 6. Edge cases a robust client must handle

- **Pi exits** (crash, OOM, extension shutdown, SIGHUP): the helper sees EOF on Pi's stdout and reaps the exit status. It keeps the stderr tail and tells Tuna, then ends only after Tuna acknowledges. Tuna shows "agent stopped" and offers a restart with `--session <file>`.
- **Start-up failure** (`pi` not on PATH, bad flags, Node too old): there is no stdout. The helper reports stderr and the exit code in `hello` or an error.
- **Malformed lines from Pi:** Pi should never send them, but log and skip such a line rather than dying. Malformed input from Tuna gets a `parse` response with no id, so Tuna must not need ids for every response.
- **Huge lines:** `message_end`, `get_messages`, and `get_entries` can be many MB (base64 images, long tool output, the whole history).
  - Use a growable buffer with no per-line limit, or a high cap (for example 256 MB) that kills the chat with a clear error.
  - After reconnect, prefer `get_entries since` for incremental refreshes.
  - In Tuna, parse on a background thread so the editor does not freeze.
- **Backpressure:**
  - The helper must always drain Pi's stdout. When no Tuna is attached, it keeps only the §2 state, which is bounded except for an open message's deltas, and discards the rest.
  - When a Tuna is attached but slow, give the helper a bounded queue (for example 4–16 MB, as the terminal helper uses). Past that, the helper stops reading Pi, which then waits. Pi already does this, which is safer than unbounded memory.
- **Abort during a tool:**
  - `abort` responds only once Pi is idle.
  - Expect `tool_execution_end` with `isError` or aborted content, an assistant `message_end` with `stopReason` aborted or error, and `agent_settled {aborted:true}`.
  - Queued messages survive `abort` unless `clear_queue` runs first.
  - Close any open UI items when `agent_settled` arrives, even if an end event was missing.
- **Compaction while busy:** overflow and threshold compaction happen inside a run (`compaction_start`, then `compaction_end {willRetry}`, then a retried prompt). `get_messages` changes shape after compaction, so re-fetch messages or entries after `compaction_end`. Do not patch incrementally across it.
- **Retries:** show `auto_retry_start` with its delay and offer `abort_retry`. `agent_end {willRetry:true}` does not mean the run is finished.
- **No auth or no models:**
  - `get_state.model` is absent when no model is selected.
  - `prompt` preflight throws `No API key for <provider>/<model>` (agent-session.js:2010), or reports that no model is selected. It does so as a failed `prompt` response.
  - Show these, and offer `get_available_models`/`set_model`. Compaction can also fail with "No model available for summarization."
- **Concurrent commands:** responses come out of order, so always send unique ids. Do not send `prompt` without `streamingBehavior` while `isStreaming` is true.
- **Stray extension UI:** unknown widget or status keys from the user's global extensions arrive. Dialogs can arrive at any time, even while idle, from extension commands. A dialog with no answer blocks that extension until its timeout, so surface them prominently.
- **Session switches** (`new_session`, `switch_session`, `fork`, `clone`): `sessionFile` and `sessionId` change. Re-read `get_state` after each one and update the session slot. Each may return `cancelled:true`.
- **Tuna and the helper both restart:** the helper's socket may be gone, either because the helper exited idle or because of a reboot. Delete stale sockets, as the terminal plugin does, then start a new helper from `sessionFile`.
- **Process groups:** start Pi in the helper's session so that a SIGHUP to Tuna's terminal does not reach it. On `kill`, send SIGTERM; Pi kills its tracked detached children.
