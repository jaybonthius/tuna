# Pilish (Emacs Pi frontend): what to copy, what to skip

Research for Tuna's Pi chat plugin (`pi`) (`pi --mode rpc`). Read-only study.

- Source studied: `/home/jay/.config/emacs/var/elpaca/sources/pilish` (git, 294 commits,
  HEAD `7ca4ee5`, v3.1.0+). The path given in the task
  (`/tmp/pi-github-repos/runtime-hxOpND/...`) no longer existed; this elpaca checkout is the same
  project (dnouri/pilish). Citations below are relative to it.
- Pi RPC reference used to cross-check: `.../@earendil-works/pi-coding-agent/docs/rpc.md`
  (found under `/data/home-docker/caddy/pi-web/upstream/node_modules/`).
- Scale warning: about 23k lines of Elisp (`pilish-render.el` 7.6k, `pilish-browse.el` 5.4k,
  `pilish-ui.el` 3.2k). Most of that is Emacs-specific rendering and race handling. Tuna needs only a small part of it.

## 1. Process lifecycle

- **Argv**: `pilish-executable` (default `("pi")`) + `--mode rpc` + `pilish-extra-args` + trust flag
  (`pilish-core.el:694-699`). Trust policy `approve` (the default) → `--approve`; `default` → none;
  `no-approve` → `--no-approve` (`pilish-core.el:683-692`, `pilish-ui.el:113-128`). The default became
  `approve` so project-local Pi resources work (commit `3600fdb`).
- **Spawn**: `make-process`, pipe (no PTY), `:noquery t`, stderr to a separate hidden buffer, cwd =
  session directory (project root) (`pilish-core.el:710-739`). The environment is inherited, with no PI_* env changes.
  Over TRAMP it uses a `sh -c 'printf READY; exec "$0" "$@"'` wrapper that prints a ready marker (`pilish-core.el:701-708`).
- **One process per chat** (chat buffer + input buffer pair). A session is keyed by
  (directory, optional name) (`pilish-ui.el:1008` `pilish--find-session`). Events route only to the
  owning process's handler (`pilish-core.el:604-611`).
- **Framing**: it accumulates stdout chunks, splits on `\n`, and parses each line as JSON. Stdout receipt time is recorded for
  the stall warning (`pilish-core.el:521-542`).
- **Request correlation**: each request gets an `:id` and a callback table, plus a table of pending command types. Responses are matched by
  id, then by `command` when the id is missing and only one match exists, then by "sole pending request"
  (`pilish-core.el:476-494`, `549-600`). The command is encoded *before* registration, so an
  encoding failure cannot leave an orphaned pending entry (`pilish-core.el:481-482`).
- **Death detection**: the sentinel fires when the process is not live and calls
  `handle-process-exit`. That function fails **every pending callback** with a synthetic
  `{success:false, processExit:t, error, exitCode, stderr}` and then calls the exit handler
  (`pilish-core.el:544-547`, `639-669`). The chat renders a single "pi process exited" block with a
  bounded stderr excerpt (head+tail, 4000 chars, `pilish-core.el:615-631`). It is guarded so that a
  *replaced* process's late sentinel cannot reset the live session
  (`pilish-render.el:1398-1430`; commit `498b867`).
- **Startup errors** (no node, no model): stderr is shown in the chat (commit `22d6706`). There is a
  "No models available" hint (`pilish-render.el:1301-1320`).
- **History on open/resume/reload**: `get_state` and `get_messages` run in parallel behind a
  "transition latch" (`pilish-menu.el:404-437`, `463-482`). Pilish does **not** use `get_entries` for the
  chat, only for the tree browser and fake tests. History is re-rendered from the `AgentMessage[]` array.
- **Reload** (`pilish-menu.el:541-635`): it starts a NEW process, sends `switch_session {sessionPath}`,
  and only on success (and `cancelled:false`) kills the old process, adopts the new one, and refreshes state, history, and commands.
  On failure it kills the new process and keeps the old one. Reload doubles as "the process died, recover."
- **Resume** (session browser / open file) reuses the live process with `switch_session`, then the same
  state+history refresh (`pilish-menu.el:637-694`).
- **Stall warning**: after 300 s with no stdout while streaming or compacting, the input header shows a
  warning (advisory only, no auto-abort) (`pilish-ui.el:135-143`; commit `9267346`).
- **Emacs exit**: processes are `:noquery`. A `kill-emacs-query-functions` hook asks once if any
  live Pi process exists (`pilish-ui.el:1894-1909`). Killing either buffer kills both buffers and the
  process (`pilish-render.el:1322-1363`). `pilish-quit` asks *before* any teardown (`pilish-input.el:483+`).

## 2. Event handling

Two layers: protocol state is updated first, then display (`pilish-render.el:1432-1470`). The comment
says protocol state "must advance before fallible display work", so a render error can't wedge the lifecycle.

- **Consumed events** (`pilish-core.el:801-865`, `pilish-render.el:1481-1684`): `agent_start`,
  `agent_end`, `agent_settled`, `message_start/update/end`, `tool_execution_start/update/end`,
  `compaction_start/end`, `auto_retry_start/end`, `extension_error`, `extension_ui_request`,
  `queue_update` (`pilish-core.el:604-611`). It ignores `turn_start/turn_end` and `bash_execution_update`.
- **Status machine** (single source of truth, `pilish-core.el:743-765`): `idle | sending |
  streaming | compacting`.
  - `agent_start`→streaming; `agent_end`→sending; **`agent_settled`→idle**. Idle means settled, not
    agent_end, because Pi may continue with retries, compaction, or queued follow-ups (rpc.md
    `agent_settled`; fake contract "agent_end is not permission to send"). Known upstream gap: settled
    events carry no run id (`pilish-core.el:816-822`).
  - `compaction_start` saves the prior status and restores it on `compaction_end`. An end without a start (exhausted
    overflow) is tolerated (`pilish-core.el:836-851`).
  - `auto_retry_*` sets `is-retrying` and `last-error`.
- **Streaming text/thinking**: `message_update.assistantMessageEvent` is delta-only.
  `text_delta`/`thinking_delta` are **queued and flushed on a 50 ms one-shot timer**, and flushed
  synchronously before any non-delta event so ordering stays correct (`pilish-render.el:98`, `781-820`,
  `1455-1477`). Commit `2912ba0`: 1,080 deltas became about 20 renders, and resume of a 433 KB session went from 18 s to 0.35 s.
  `thinking_start/end`, `text_end` (finalize a table), and `error` (`reason`) are handled inline.
- **Authoritative replace on `message_end`**: the completed assistant message overrides streamed
  previews (tool-call ids and args, usage) (`pilish-render.el:1566-1595`). Error `stopReason` → error block.
- **Tool calls**: `toolcall_start/delta/end` inside message_update create a *preview* block keyed by
  toolCallId (args are partial). `tool_execution_start` reuses that block and resets the header from the authoritative
  args (`pilish-render.el:1597-1616`; commit `3f4fd36`). Args are cached because
  `tool_execution_end` has no args (`:1606`, `:1625`).
- **`tool_execution_update`** carries the *complete partial output so far*. Pilish keeps only the latest per
  toolCallId and renders at the flush cadence (`pilish-render.el:1644-1652`, `3646`; commit `136c794`:
  subagent storms of about 40 events/s). `tool_execution_end` discards any pending update first, then
  renders the final result once (`:1617-1643`).
- **User messages**: Pilish echoes the prompt locally for responsiveness and then dedupes against Pi's
  `message_start{role:user}` (`pilish-render.el:1501-1522`). Steering is *not* echoed locally; Pi's echo
  places it at the correct point (`pilish-input.el:675-690`). `role:custom` with `display` is rendered;
  late `toolResult` messages must not reset assistant markers (`:1492-1495`).
- **Queue**: Pilish keeps a **client-side follow-up FIFO**. Its docstring says it is "simpler than using pi's RPC
  follow_up" (`pilish-ui.el:1597-1603`). It sends the next item on settlement and restores items to input on failure or retry failure.
  Steering uses the `steer` RPC while streaming; during compaction it falls back to the local queue
  (`pilish-input.el:692-722`). This is the largest source of race-fix commits (`1007a59`, `d459c55`,
  `41a636a`, `be4eb0d`, `a4a97be`). It also stores Pi's `queue_update` snapshot for the header count
  (`pilish-core.el:604-607`).
- **Prompt accepted but no agent_start** (extension commands, handled slash commands): a timer
  probes with `get_state` before it releases "sending" (`pilish-ui.el:3046-3110`).
- **Abort**: sets an `aborted` flag, clears the local queue, and sends `abort`. If `agent_start` or
  `compaction_start` arrives later while aborted, it re-sends abort (`pilish-input.el:465-480`, `pilish-render.el:1487`, `1654`).
- **Client-side vs Pi state**: model, thinking level, sessionFile, and counts come from `get_state` after
  start/resume/reload and from responses to `set_model`/`cycle_*` (`pilish-core.el:900-949`). A snapshot
  never overrides a busy status the events own (`pilish-core.el:891-898`). Cost and context % come from
  `get_session_stats` (`pilish-ui.el:2763-2779`, `2951`). Commands come from `get_commands`.
  The transcript is client-side, rebuilt from `get_messages`.

## 3. Rendering

- **Turn structure**: setext-style headings "You · <full date>" and "Assistant", with one blank line
  between sections (`pilish-ui.el:2200-2215`; commits `a71cd79`, `95c533e`). TAB on a heading folds the turn (outline).
  `n`/`p` move between user messages.
- **Tool blocks**: the header is the tool name plus its key arg (bash command, read/write/edit path) (`pilish-render.el:2127-2135`).
  Output is collapsed to a preview: **10 visual lines generally, 5 for bash**, with a 50 KB cap, blank lines
  stripped but original line numbers kept (for RET), and a "... (N more lines)" hint (`pilish-ui.el:201-216`,
  `pilish-render.el:1691-1705`, `3777-3790`). TAB expands. Read/write get language highlighting;
  edit shows a diff. ANSI codes are stripped (commit `a669425`).
- **Thinking**: streamed live as a blockquote. When complete, it shows as `visible` (default) or `hidden` (a stub line
  with an optional first-line preview), with a per-buffer toggle in the menu (`pilish-ui.el:308-332`).
- **Markdown**: the chat buffer *is* Markdown text with tree-sitter `md-ts-mode` fontification and
  per-language grammars for fences (replaced gfm-mode, commit `a5fe982`). Change tracking is suspended
  during replay and flushes (commit `2912ba0`). Copy can yield visible text or raw markdown.
- **Tables**: display-only overlays with box-drawing characters wrapped to the window width. The buffer text stays raw
  Markdown (`pilish-ui.el:334`, `pilish-table.el`). Tables are re-wrapped only inside the hot tail on resize.
- **Images**: inline previews from user content and tool results (max 900 px wide, 10 MB). Prompt attach is
  3 MB, one image per draft (`pilish-ui.el:218-233`). Terminals get a placeholder.
- **Hot tail**: the last N=3 headed turns stay "hot" (live overlays, buttons, re-wrap on resize).
  Completed tool blocks older than that are **cooled** to plain text (header + preview kept; overlays,
  buttons, payloads, and syntax tagging dropped), one block per 50 ms timer tick
  (`pilish-ui.el:300-306`, `660`; `pilish-render.el:4259-4330`; commit `7af3b13`). The cause is Emacs redisplay
  cost from overlays. In the browser the equivalent cost is DOM size and morph cost.
- **File targets**: RET on a tool-content row, a plain path, or a local md link visits it. It supports `:L:C`
  and `#L12-L20`. `!` runs a shell command on the path, `w` copies it (README.org:290-305, 1066-1100).
  Strict targets only: headers and fences are not clickable.
- **Header line** (`pilish-ui.el:2746-2880`): model (click to select), thinking level (click to
  cycle), activity phase (`thinking|replying|running|compact|idle`, `pilish-ui.el:1367`, `1465`),
  session name, cumulative cost, context % (warning at 70, error at 90), queued count, extension
  `setStatus` texts with per-key faces, and an inactivity warning.
- **Startup header**: Pi and Pilish versions, skill and prompt counts, and an expandable list of context
  files, skills, templates, and extension commands with source links (README.org:307-317).
- **Hover**: timestamps, model/provider, token usage, and tool durations on hover (commit `fe54fec`). This is polish.

## 4. Extension UI (`pilish-render.el:1146-1299`)

| Method | Pilish | Response |
|---|---|---|
| `select` | `completing-read` (require-match) | `{value}` |
| `confirm` | `yes-or-no-p` "title: message" | `{confirmed: bool}` |
| `input` | `read-string` with placeholder as default | `{value}` |
| `editor` | **unsupported** → `{cancelled:true}` | |
| `notify` | echo-area message with ⚠/✗ prefix | none |
| `setStatus` | keyed alist in header; nil text removes; ANSI stripped | none |
| `set_editor_text` | replaces the input draft | none |
| `setWorkingMessage` | header (RPC currently suppresses it) | none |
| `setWidget`, `setTitle` | unsupported, warned once per session | none (fire-and-forget) |

- The unsupported-method rule: dialogs get `{cancelled:true}` so extensions don't hang. Fire-and-forget
  methods get only a one-time warning (`pilish-render.el:1255-1284`; commits `3b022b3`, `6380ddd`).
- Gaps: it ignores the request `timeout`. The dialogs are modal minibuffer prompts, and it is not obvious that C-g sends `cancelled`
  (a quit inside `completing-read` would leave Pi waiting). Tuna should always answer, cancelling on dismiss or timeout.

## 5. Commands and menu

- **Chat keys** (`pilish-ui.el:565-584`): `q` quit, `C-c C-p` menu, `C-c C-k` abort, `C-c C-n` new,
  `C-c C-r` sessions, `C-c C-e` export, `C-c C-c` compact, `C-c C-m` model, `C-c C-t` cycle thinking,
  `C-c C-y` copy last, `n/p` messages, `f` fork at point, TAB toggle, `!` shell, `w` copy path, RET visit.
- **Input keys** (`pilish-ui.el:947-958`): `C-c C-c` send (it queues as a follow-up when busy),
  `C-c C-s` steer, `C-c C-k` abort, TAB complete, `M-p/M-n`/`C-r` input history, `C-c C-p` menu.
- **Transient menu** (`pilish-menu.el:1360-1393`): Session (new, sessions, reload, name, export,
  quit) · Context (compact, fork, tree) · Actions (send, steer, attach, abort) · Model (select,
  thinking) · Completed thinking display · Info (stats, copy last). Submenus list templates,
  extensions, and skills from `get_commands`, grouped by source and location (`pilish-menu.el:1420-1600`).
  `pilish-refresh-commands` re-fetches them.
- **Slash commands**: built-ins are **dispatched client-side**: `/compact /new /model /session /name
  /fork /resume /reload /export /copy /quit` (`pilish-ui.el:1786-1800`; commit `1d38a20`). Everything
  else is sent literally as a `prompt` (Pi expands templates and skills and runs extension commands). Completion
  combines the built-ins with `get_commands`, and triggers only at buffer start (commit `8e1651c`). Path completion handles
  `./ ../ ~/ /`, and `@` triggers only at word boundaries (`pilish-input.el:625-666`; commit `ba275a1`).
- Model picker: `get_available_models` (with provider shown) → `set_model`. Thinking: `get_available_thinking_levels` →
  `set_thinking_level` (`pilish-menu.el:739-915`).

## 6. Sessions

- **Session browser** (`pilish-browse.el`): it reads `~/.pi/agent/sessions/` (or
  `$PI_CODING_AGENT_DIR/sessions`) **JSONL directly, without a live process**, using time-sliced scans. Views are
  flat/threaded (fork families via header parent links) and scopes are current/all, with search, rename,
  and delete. Live sessions are marked. Selecting one resumes via `switch_session` (`pilish-browse.el:24-45`).
- **Tree browser**: it projects the active session's JSONL into a `get_tree`-shaped tree, filters it
  (default no-tools), and labels nodes. "Continue from here" **atomically rewrites the session file**
  out-of-band (write-temp + rename), because RPC has no `navigate_tree`/`/tree` command
  (`pilish-browse.el:40-45`; rpc.md has no navigate command). This is fragile; avoid it.
- **Fork**: `get_fork_messages` → pick a user message (or the one at point) → `fork {entryId}` → reload
  history (`pilish-menu.el:1161-1260`; commit `9f9313b` fixed it for deep sessions). `clone` creates a
  separate file with no branch point; Pilish exposes only fork (clone appears only in threaded view).
- Rename uses `set_session_name` RPC for the live session, never a direct file write (commit `dcd5717`).
- Session transitions are refused while not idle, busy, or awaiting the prompt echo (`pilish-menu.el:439-453`).

## 7. Hard-won lessons

- **Idle = `agent_settled`, not `agent_end`.** Do tool finalization and cooling at agent_end, and new prompts and
  queue drains at settled (fake contract; `pilish-core.el:812-822`).
- **Coalesce deltas and tool updates**, and flush before any structural event. Never retry a failed flush
  batch; log it and drop it (commit `2912ba0`).
- **State first, render second.** A render exception must not leave the status wedged.
- **Every pending request must resolve**, including on process death. Ignore events and callbacks from a
  stale or replaced process (generation counters everywhere: history loads, transitions, prompt waits).
- **Show stderr when the process dies, exactly once** (`498b867`).
- **The local follow-up queue + prompt-ownership state machine** caused about a dozen race fixes (late prompt
  acks, retry failure, compaction, abort). Pilish's own docstring admits it chose this over `follow_up`.
  Pi now has `follow_up`, `steer`, `streamingBehavior` on `prompt`, `clear_queue`, and `queue_update`.
- **A prompt can succeed without a turn** (extension command). Do not wait forever for agent_start.
- **Authoritative data beats streamed previews**: tool header and path come from `tool_execution_start` args
  and the final message comes from `message_end` (`3f4fd36`, `c00caf4` delta-only tool calls in Pi 0.84).
- **Reload = new process + switch_session, swapped atomically.** Never kill the old process before the new one is ready
  (`db8e7c7` "reload reverts to old session").
- **Version drift**: Pi changed its wire format several times (0.51 template→prompt, 0.65, 0.84, 0.85).
  Pilish pins a minimum Pi version and does a delayed version probe (`0c29d3a`, `1007a59`).
- **Long sessions**: rendering cost grows with history, so cool old blocks (hot tail) and batch history replay
  (`6141936`, `308c74b`).
- Smaller fixes: scroll-follow only when at the end (`f65df45`); preserve scroll on toggle
  (`4d5d979`); strip ANSI; truncate huge single lines; dedupe the local prompt echo; an "empty session" display bug
  (`df1b2fe`).
- **Fake-pi testing** (`test/support/fake-pi-contract.md`, `fake_pi.py` 1.9k lines Python): a
  protocol double entered through the real seam (`pilish-executable` + extra args), so production code has no
  test branch. Strict JSONL. `prompt` responds immediately and then streams scripted events. It supports
  get_state, get_commands, prompt, abort, clear_queue, steer, new_session, get_fork_messages,
  get_entries, get_tree, get_messages, switch_session, set_session_name, set_model,
  set_thinking_level, and extension_ui_response. It rejects `follow_up` and fails unsupported commands loudly. Scenarios
  are fixtures. A thin real-pi suite guards against drift. Benchmarks (`bench/`) replay delta storms,
  tool-update storms, and reload of large sessions, and they fail on correctness, not timing.

## 8. Judgment for Tuna v1

**Essential (copy the decision)**
- One `pi --mode rpc --approve` child per chat, with cwd = project. JSONL framing, ids + callback table,
  all pending requests failed on exit, and a stderr excerpt shown in the chat.
- Status machine `idle|sending|streaming|compacting` driven by events. Idle on `agent_settled`.
- Server-side transcript model: one keyed record per message/tool call, built from deltas and
  replaced by `message_end`/`tool_execution_end`. History is loaded with `get_messages` on open, resume, and reload.
- Coalesced rendering (about 50 ms) for text/thinking deltas and `tool_execution_update` (latest wins).
  In Tuna this maps to batching fat morphs per tick.
- Tool blocks: a header with the key arg, collapsed preview (10 lines, 5 for bash, byte cap), expand toggle, error styling.
- Thinking shown live and collapsible when done. Markdown with fenced-code highlighting.
- Header: model, thinking, phase, context %, cost, queued count, extension statuses.
- Send / steer / abort. **Use Pi's own queue** (`prompt` with `streamingBehavior: "followUp"|"steer"`,
  `clear_queue`, and `queue_update` for display) instead of Pilish's local FIFO.
- Extension UI: select, confirm, input, notify, setStatus, set_editor_text. **Always answer dialogs**
  (cancel on dismiss or `timeout`). `editor` as a textarea is cheap in a browser, so consider supporting it.
  Fire-and-forget methods with no support: warn once.
- Commands: new, sessions (resume), reload, compact, model, thinking, fork, abort, name, export.
  Slash completion from `get_commands` plus a few client-dispatched built-ins.
- File targets: clicking a path visits it in Tuna (this fits a browser naturally).
- Reload as atomic swap (new process + `switch_session`); reload is also the recovery after a crash.
- A fake-pi test double at the process seam, with no test branches in production.

**Polish (defer)**
- Session browser with threaded fork families, search, delete. v1 can be a simple list from
  disk or from Pi. Hover metadata, durations. Startup resource summary. Image attach and inline images.
  Pretty table overlays (HTML tables already wrap). `!` shell-on-path, copy-path. Stall warning (cheap,
  but optional). Per-block thinking toggles and display modes. Input history isearch.

**Avoid (complexity that doesn't pay)**
- The client-side follow-up FIFO and prompt-ownership probing (`pilish-ui.el:1597-1670`, `3040-3227`).
  Pi's queue and `queue_update` make it unnecessary. Keep only "prompt accepted but no agent_start →
  check `get_state`" if the UI must leave "sending".
- Locally echoing the user prompt with later dedupe. Render on Pi's `message_start{role:user}`
  (latency is a local pipe). If an echo is wanted, mark it pending and replace it on echo.
- Rewriting session JSONL out-of-band (tree navigation, renaming non-live sessions). Wait for an RPC.
- Emacs-specific machinery: cooling and hot-tail overlay management (in a browser use simpler
  virtualization or collapse instead; morph only the live turn), tree-sitter grammar management, TRAMP
  ready markers, window and input-display modes, Evil integration.
- Heuristic response routing without ids. Always send ids.
