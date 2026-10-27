# Research: OSC and terminal protocols for Tuna's `terminal` plugin

Read-only research, 2026-10-27. Intended home: `tuna/agents/research/terminal/04-osc-and-terminal-protocols.md`.

Labels used below. **Fact** means a primary source states it, with a citation. **Inference** is my reasoning from those facts. Ghostty claims are pinned to upstream commit
[`9ee02ae601d3eec567723287e1c20bd0e9f1489c`](https://github.com/ghostty-org/ghostty/tree/9ee02ae601d3eec567723287e1c20bd0e9f1489c) (2026-10-26). In the citations, `terminal.h` means `include/ghostty/vt/terminal.h` at that commit, and `stream.zig` and `stream_terminal.zig` mean files under `src/terminal/`.

## Summary

libghostty-vt already does most of the decoding. It turns titles, OSC 7, OSC 52, OSC 9/777, OSC 9;4, OSC 133, OSC 7501, the bell and others into typed **effects**, which are synchronous callbacks. It answers queries such as colours, DECRQM, XTVERSION and XTGETTCAP by itself through a write-back callback. It hands any OSC whose number it does not recognise to an opt-in "unknown sequence" callback. So the `terminal` plugin can stay a thin translator from effects to Tuna hooks.

There are three hard constraints:

1. **Clipboard callbacks must answer before they return.** The browser clipboard is asynchronous and gated by user activation. OSC 52 *read* therefore cannot be served live from the browser clipboard. Deny it by default.
2. **Some sequences are unreachable.** libghostty parses OSC 99 (kitty notifications) and most of OSC 1337 (`SetUserVar`, `RequestAttention`, …) and then drops them. Because it recognises their numbers, it never reports them as unknown either.
3. **Rune's OSC 7501 is not Rune's protocol.** It is Mitchell Hashimoto's Program Status Protocol, published in the Rex/Superlogical documentation. Ghostty implements it, and Rune and Claude Code adopted it. The `gerbil-libghostty` binding currently targets a Ghostty commit from before the OSC 7501 effect was added.

## Findings

### A. How libghostty-vt exposes sequences (the integration surface)

1. **Claim:** Side-effect sequences are ignored unless the embedder registers an effect callback. The effects are: `WRITE_PTY`, `BELL`, `TITLE_CHANGED` (OSC 0/2), `PWD_CHANGED` (OSC 7 / OSC 9 / OSC 1337), `ENQUIRY`, `XTVERSION`, `SIZE`, `COLOR_SCHEME` (CSI ? 996 n), `DEVICE_ATTRIBUTES`, `CLIPBOARD_WRITE` (OSC 52 / 1337 / 5522), `CLIPBOARD_READ` (OSC 52 "?" / 5522), `DESKTOP_NOTIFICATION` (OSC 9 / 777), `PROGRESS_REPORT` (OSC 9;4), `PROGRAM_STATUS` (OSC 7501), `UNKNOWN_SEQUENCE`, `RENDER_HOLD` (mode 2026), `SEMANTIC_PROMPT` (OSC 133), `RESET` (RIS) and `RESIZE_WINDOW` (CSI 8 t). Callbacks run synchronously during the VT write. They must not re-enter the terminal and must not block for long. **Sources:** [terminal.h L56–108](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/terminal.h#L56-L108). **Support:** direct. **Confidence:** high.
2. **Claim:** An OSC whose number libghostty does not implement reaches `UNKNOWN_SEQUENCE` only when `UNKNOWN_MAX_BYTES` is set (the default 0 means off). The callback gets the raw content after `ESC ]` plus the terminator, so a reply can use the same terminator. APC sequences are reported too. A number libghostty *does* implement is never reported, even when its payload is malformed. **Sources:** terminal.h L130–200; [`osc.h`](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/osc.h). **Support:** direct. **Confidence:** high.
3. **Claim:** Some sequences are parsed and then silently dropped. Neither an effect nor the unknown callback sees them: kitty notifications (OSC 99), kitty text sizing, OSC 3008 hierarchical context, and the ConEmu OSC 9;x sub-commands other than progress and cwd. In OSC 1337, only `Copy` and `CurrentDir` are acted on. `SetUserVar`, `RequestAttention`, `SetMark`, `File` and the others are logged as "unimplemented". **Sources:** [`stream.zig` L2957–2970](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/src/terminal/stream.zig#L2957-L2970); [`osc/parsers/iterm2.zig`](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/src/terminal/osc/parsers/iterm2.zig) (L34–133). **Support:** direct (source reading). **Confidence:** high.
4. **Claim:** Some state is readable but has no change callback: the OSC 8 hyperlink per cell (`ghostty_grid_ref_hyperlink_uri`), the OSC 22 pointer shape (`GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE`), mouse tracking, kitty keyboard flags, modes (`DATA_MODE`), "cursor at prompt", title and pwd. **Sources:** [`grid_ref.h`](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/grid_ref.h) (L168–187); terminal.h L2796–3213. **Support:** direct. **Confidence:** high.
5. **Claim:** The local binding `gerbil-libghostty` targets Ghostty `befcdfd2c` (2026-10-03). The OSC 7501 effect landed later, in `bae2c3cdb` (2026-10-06), and was revised to spec 0.4 in `b7207b2ef` (2026-10-10). The semantic-prompt effect (`7bb45ba34`) and unknown-OSC reporting (`7b11f3dca`) are included in the targeted commit. **Sources:** `gerbil-libghostty/PARITY.md`; `git log` on `include/ghostty/vt/terminal.h` and `git merge-base --is-ancestor` in a local clone. **Support:** direct. **Confidence:** high. *Inference:* bump the binding to at least `b7207b2ef` before building the terminal plugin. Without the bump, OSC 7501 would arrive only through the unknown-sequence callback and would have to be parsed by hand.

### B. Catalogue

Columns: **Format**, **Origin/spec**, **Emitted by**, **Security**, **libghostty**, and **Tuna action → owning plugin**. The Tuna column is my *inference*. Everything else is fact unless marked.

#### OSC 0 / 1 / 2 (titles)
- **Format:** `OSC 0;title ST` sets the icon name and title, `OSC 1` sets the icon name only, `OSC 2` sets the title only. Origin: xterm ([ctlseqs](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)).
- **Emitted by:** shells (via prompt settings), vim, tmux, and agents. Claude Code puts a status glyph in the title unless the terminal supports OSC 7501 ([Claude Code docs](https://code.claude.com/docs/en/terminal-config)).
- **Security:** the text is untrusted. Strip control and bidirectional characters, cap the length, and never treat it as markup.
- **libghostty:** `TITLE_CHANGED` effect for OSC 0/2. OSC 1 is parsed (`CHANGE_WINDOW_ICON`) but has no effect.
- **Tuna:** publish *title changed*. The terminal plugin uses it as the default buffer or mode-line name, and other plugins (tabs, layout) may use it too.

#### OSC 7 (working directory)
- **Format:** `OSC 7;file://host/percent-encoded/path ST`. Origin: xterm and VTE convention, also documented by iTerm2 as RemoteHost plus CurrentDir ([iTerm2](https://iterm2.com/documentation-escape-codes.html)). Equivalents: `OSC 1337;CurrentDir=` (iTerm2), `OSC 9;9` (ConEmu), and `OSC 633;P;Cwd=` (VS Code).
- **Emitted by:** shell integrations (fish by default, Ghostty/VTE/Wave scripts), and ssh sessions that carry the remote host.
- **Security:** the host may be remote. Do not treat the path as local unless the host is the local machine or empty. Cap the length.
- **libghostty:** `PWD_CHANGED` for OSC 7, OSC 9;9 and OSC 1337 CurrentDir. libghostty stores the raw URL undecoded (truncated at 4096 bytes), and the embedder must decode it ([`stream_terminal.zig` L1905–1920](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/src/terminal/stream_terminal.zig#L1905-L1920)).
- **Tuna:** publish *directory changed* with the host, the decoded path and whether it is local. The terminal plugin itself sets the buffer's default directory, because Emacs's `default-directory` is per buffer.

#### OSC 8 (hyperlinks)
- **Format:** `OSC 8;params;URI ST` text `OSC 8;; ST`. `params` may contain `id=`. Origin: Egmont Koblinger's [hyperlinks spec](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda) (not re-fetched in this run).
- **Emitted by:** `ls --hyperlink`, gcc diagnostics, systemd, git, ripgrep, and agents linking files.
- **Security:** the link text can disguise the target. Show the URI on hover, allow only some schemes (`http`, `https`, and `file` with a host check), never follow a link automatically, and when drawing `<a>` in HTML forbid `javascript:` and `data:` and add `rel="noopener noreferrer"`.
- **libghostty:** stored per cell, with no effect. The renderer reads it per cell.
- **Tuna:** the renderer draws link styling. An "open link" command opens the target: in the browser for URLs, or `find-file` for local `file://` paths. This is a rendering property, not an event.

#### OSC 52 (clipboard)
- **Format:** `OSC 52;Pc;Pd ST`. `Pc` is the selection target (`c` clipboard, `p` primary, `s` select, …) and `Pd` is base64 data, or `?` to read. Origin: xterm ctlseqs. Related protocols: `OSC 1337;Copy=:base64` (iTerm2) and OSC 5522 (the kitty clipboard protocol, with MIME types and passwords).
- **Emitted by:** tmux, Neovim (0.11 checks the terminfo capability `Ms` through XTGETTCAP and then copies via OSC 52 with no setup; see [Rune clipboard docs](https://github.com/unstablebuild/rune/blob/604b5478dfe83fa20be5db06559e28eff4ce5deb/docs/docs/learn/clipboard.md)), vim plugins, and Claude Code's `/copy`.
- **Security:**
  - **Write:** any output (a file you `cat`, a log, a remote host) can replace what you are about to paste.
  - **Read:** dangerous. It hands any program, or any file you `cat`, whatever you copied last, which may be a password or token. Rune defaults to write on, read off for exactly this reason (same Rune doc).
- **libghostty:** `CLIPBOARD_WRITE` and `CLIPBOARD_READ` effects. Both are synchronous: the reply must be called inside the callback, and returning without replying denies. OSC 52 has no write acknowledgement, so the write result is discarded. A denied or failed read answers the program with an empty clipboard. Write size is capped (`OPT_CLIPBOARD_WRITE_MAX_BYTES`). Installing the read callback also enables kitty paste events (mode 5522). ([terminal.h L935–1320](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/terminal.h#L935-L1320).)
  - **Fact:** XTGETTCAP answers come from Ghostty's compiled-in terminfo, which always advertises `Ms`, regardless of what the embedder does ([`stream_terminal.zig` L857–867](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/src/terminal/stream_terminal.zig#L857-L867); `src/terminfo/ghostty.zig` L123).
  - *Inference:* Neovim will therefore always try OSC 52 in Tuna, so writes must be handled.
- **Tuna:**
  - **Write:** reply success immediately and publish *copy requested* with the target and the text. A **clipboard plugin** then (a) pushes the text onto Tuna's kill ring via `kill-new` (this always works, since it is on the server), and (b) asks the browser client to write the system clipboard, within the browser limits in section C.
  - **Read:** deny by default. Optionally, a setting could let the clipboard plugin answer from the kill-ring head. It must not use the live browser clipboard (see C).
  - Placement: the read answer must be synchronous. *Inference:* the terminal contract therefore needs a replaceable *clipboard read policy* (a service with a deny default), not a hook.

#### OSC 133 (semantic prompts) and OSC 633 (VS Code)
- **OSC 133 format:** `OSC 133;A` (prompt start), `B` (input start), `C` (output start), `D[;exit]` (command end), plus options such as `aid=`, `cl=`, `k=`, and Ghostty's `cmdline=` / `cmdline_url=`. Origin: FinalTerm, later the Per Bothner [semantic-prompts proposal](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md) (that page needs JavaScript and was not fetched; cited via the OSC 7501 spec and the VS Code docs).
- **OSC 633 format:** `A/B/C/D` as in 133. `E;<commandline>[;<nonce>]` sends the exact command line; it is escaped with `\xAB`, and the nonce proves the sequence came from the integration script, which guards against command spoofing. `P;Key=Value` sets properties (`Cwd`, `IsWindows`, `HasRichCommandDetection`). VS Code itself recommends checking `TERM_PROGRAM=vscode` before emitting them ([VS Code docs](https://code.visualstudio.com/docs/terminal/shell-integration)).
- **Emitted by:** shell integration scripts (Ghostty, kitty, WezTerm, VS Code, fish 4 natively). Wave uses its own `OSC 16162;A/C/D/M/I/R` with JSON payloads ([Wave doc, v0.14.4](https://github.com/wavetermdev/waveterm/blob/v0.14.4/aiprompts/wave-osc-16162.md)).
- **Security:** a program can fake prompts or command lines. Never run a command recovered from a mark without the user confirming it. The 633 nonce exists for this reason.
- **libghostty:** `SEMANTIC_PROMPT` effect with kind (prompt start / input start / output start / command end), prompt kind, exit code, decoded command line and error text. The terminal also tracks prompt rows (`DATA_CURSOR_AT_PROMPT`). The callback warns that shells skip steps and redraw prompts ([terminal.h L1640–1790](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/terminal.h#L1640-L1790)). OSC 633 and 16162 are not recognised, so they come through `UNKNOWN_SEQUENCE`.
- **Tuna:** publish *prompt shown*, *command started* (with the command line) and *command finished* (with the exit code and the duration the terminal measured). Consumers:
  - the terminal plugin's own prompt navigation (Emacs `comint-previous-prompt` / `term-previous-prompt` equivalents) and "select last output";
  - a notifications plugin ("long command finished while you were away");
  - the program-status plugin (prompt start clears `working` and `blocked` records).
  
  Ship Tuna's shell integration emitting OSC 133 and OSC 7. Translate 633 inside the terminal plugin only if it is cheap.

#### OSC 9, OSC 777, OSC 99 (notifications)
- **Formats:**
  - `OSC 9;body ST` (iTerm2; [iTerm2](https://iterm2.com/documentation-escape-codes.html)).
  - `OSC 777;notify;title;body ST` (rxvt-unicode extension, used by Warp, Ghostty and others; [Warp](https://docs.warp.dev/terminal/more-features/notifications)).
  - `OSC 99;metadata;payload ST` (kitty). Its metadata is colon-separated `k=v` pairs. It supports chunking (`i=`, `d=`), base64 (`e=1`), app name and type (`f=`, `t=`), and activation callbacks. Payloads are limited to 2048 bytes before encoding and must be plain text, with no markup ([kitty](https://sw.kovidgoyal.net/kitty/desktop-notifications/)).
- **Emitted by:**
  - Claude Code sends desktop notifications by default only in Ghostty, kitty and iTerm2; elsewhere it falls back to the bell or hooks ([Claude Code docs](https://code.claude.com/docs/en/terminal-config)).
  - Codex CLI has `tui.notifications_method` = `auto | osc9 | bel` ([openai/codex#10043](https://github.com/openai/codex/pull/10043)).
  - Warp's Claude Code and OpenCode plugins use OSC 777 (below).
- **Security:** spoofing ("sudo password required"), spam, and text from other panes pretending to be elsewhere. Rate-limit, name the source terminal, strip bidi characters, and treat everything as plain text.
- **libghostty:** `DESKTOP_NOTIFICATION` gets `{title, body}` for OSC 9 and OSC 777. It disambiguates OSC 9 from the ConEmu `9;n` sub-commands. OSC 99 is parsed and dropped (A.3), so it is unavailable without an upstream change.
- **Tuna:** publish *notification requested* (title, body, source protocol). A **notifications plugin** decides how to show it: in the echo area when the terminal is visible, and through the browser Notifications API when the tab is hidden (see C).

#### OSC 9;4 (progress)
- **Format:** `OSC 9;4;st;pr ST`. `st` is 0 remove, 1 set (with a percentage), 2 error, 3 indeterminate, 4 paused. Origin: ConEmu, now also in Windows Terminal, iTerm2 and Ghostty ([iTerm2](https://iterm2.com/documentation-escape-codes.html)).
- **Emitted by:** systemd, winget, Claude Code (`terminalProgressBarEnabled`), Codex and build tools.
- **Security:** low. Rate-limit redraws.
- **libghostty:** `PROGRESS_REPORT` effect `{state, progress (-1 if absent)}`. A full reset sends `remove` ([terminal.h ~L1360–1415](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/terminal.h#L1360-L1415); `stream_terminal.zig` L730–745).
- **Tuna:** publish *progress changed*. The mode line or tab shows it.
  - **Fact:** the OSC 7501 spec says a terminal MAY map 9;4 onto the root status record, and SHOULD stop doing so once it has received a real OSC 7501 report.
  - **Fact:** Rune does not map it at all.
  - *Inference:* keep the two separate at first.

#### OSC 4 / 10 / 11 / 12 (colour set and query)
- **Format:** `OSC 4;n;spec` sets or queries a palette entry. `OSC 10`, `11` and `12` cover foreground, background and cursor. `?` queries, and `OSC 104/110–112` reset. Origin: xterm ctlseqs.
- **Emitted by:** Neovim, Emacs `-nw`, Claude Code's "auto" theme, and others query the background to pick light or dark ([Claude Code docs](https://code.claude.com/docs/en/terminal-config)).
- **Security:** replies leak only colours. Set requests can make text unreadable; that is cosmetic.
- **libghostty:** handled internally. The embedder sets the defaults (`OPT_COLOR_FOREGROUND/BACKGROUND/CURSOR/PALETTE`) and libghostty answers queries itself via `WRITE_PTY`. Overrides are kept separately from the defaults (terminal.h L200–260). Related: CSI ? 996 n and mode 2031 report dark or light through `COLOR_SCHEME`.
- **Tuna:** no event is needed. The terminal plugin feeds the theme colours to libghostty. *Inference:* when the browser's `prefers-color-scheme` or the Tuna theme changes, update the defaults and report mode 2031.

#### OSC 1337 (iTerm2): the parts that matter
- **Parts acted on in libghostty:** `CurrentDir=` (goes to the PWD effect) and `Copy=:base64` (goes to the clipboard write effect).
- **Parts that would matter but are dropped:**
  - `SetUserVar=k=base64v`, which shells and WezTerm users rely on;
  - `RequestAttention`;
  - `SetMark`;
  - `File=` inline images ([iTerm2](https://iterm2.com/documentation-escape-codes.html)).
- **Also from iTerm2:** `OSC 21337;indicator=…;status=…` (session status). It goes through `UNKNOWN_SEQUENCE`, but the OSC 7501 author calls it presentation-specific.
- **Tuna:** nothing beyond the effects above.

#### OSC 22 (pointer shape)
- **Format:** `OSC 22;[=|>|<|?]names ST`, with a push/pop stack and query support. The shape names are CSS cursor names. Origin: an xterm proposal, specified by kitty ([kitty](https://sw.kovidgoyal.net/kitty/pointer-shapes/)).
- **Emitted by:** TUIs with buttons, pane resizing, links.
- **Security:** none significant.
- **libghostty:** stored in state (`DATA_MOUSE_SHAPE`, `GHOSTTY_MOUSE_SHAPE_*`, defaulting to `TEXT`), with no effect.
- **Tuna:** the renderer maps it to a CSS `cursor:` value on the terminal element. *Inference:* if this changes at runtime it needs a style or attribute patch, and per Tuna's HTML/CSS guide that belongs in the terminal plugin's rules, not in Gerbil colours or styles.

#### OSC 7501 (Program Status Protocol): "Rune's" sequence
- **Origin (fact):** specified by Mitchell Hashimoto, published at [superlogical.com/rex/docs/build/program-status](https://www.superlogical.com/rex/docs/build/program-status) (revision 0.4, 2026-10-10), and announced in his [blog post](https://mitchellh.com/writing/program-status-osc7501). Rune *implements* it and documents its own presentation ([Rune program-status.md @604b547](https://github.com/unstablebuild/rune/blob/604b5478dfe83fa20be5db06559e28eff4ce5deb/docs/docs/learn/terminal/program-status.md)).
- **Format:**
  - A report is `OSC 7501;key=value(:key=value)* ST`; feature detection is `OSC 7501;? ST`.
  - Keys:
    - `state` (required): `idle | working | done | blocked | error | clear`. Unknown values make the whole report ignored.
    - `id`: a `/`-separated path; absent means the root record.
    - `kind`: `permission | question | auth`, read only with `blocked`.
    - `progress`: 0–100, read with `working` or `blocked`; absent means indeterminate.
    - `app`: a stable identifier such as `cargo` or `claude-code`, inherited from ancestors.
    - `title` and `msg`: base64 UTF-8, a single line, with no control characters.
  - Records:
    - Each report **replaces** its record completely.
    - `clear` removes the record and its subtree; with no `id` it removes all records.
    - `working` and `blocked` records are dropped when the process exits or a new OSC 133 `A` prompt starts.
    - `done` and `error` persist until the user has seen them.
    - RIS removes all records.
  - Limits: 4096-byte sequence, `msg` ≤ 2048 bytes decoded, `title` ≤ 192, 256 records (at least 64).
  - The reply to `?` contains nothing from any report.
- **Emitted by:** Claude Code v2.1.295+, automatically after detecting support. It does not report inside tmux, from background sessions, or with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` ([Claude Code docs](https://code.claude.com/docs/en/terminal-config)). Also `runectl status` and Rune Agent. The spec's motivating examples are terraform, brew and deploy scripts.
- **Security (spec):**
  - MUST refuse a report whose decoded text contains control characters.
  - Never treat text as markup.
  - SHOULD disarm bidi and invisible characters.
  - SHOULD say which terminal a status came from.
  - SHOULD rate-limit side effects such as notifications.
- **libghostty:** `PROGRAM_STATUS` effect with a validated, decoded report `{state, kind, progress, id, app, title, message}`. libghostty does not store records; the embedder must. It answers the `?` query only if the effect is installed. On RIS it sends `clear` with an empty id ([terminal.h L1415–1640](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/terminal.h#L1415-L1640); `stream_terminal.zig` L983–1000).
- **Rune's "async notifications" (fact, Rune docs):**
  - Status shows on the tab icon, on the workspace bar (most pressing first: blocked > error > done > working > idle), as notifications, and in a `:programstatus` inbox.
  - A notification fires whenever a record's `msg` changes. A state notification fires when an out-of-sight terminal enters `blocked`, `error` or `done`, rate-limited to one per tab every 2 s, latest wins.
  - Notifications in unfocused workspaces stay open and add to a badge until you visit ([Rune worktrees.md §"Knowing when a worktree needs you"](https://github.com/unstablebuild/rune/blob/604b5478dfe83fa20be5db06559e28eff4ce5deb/docs/docs/learn/worktrees.md)).
  - Rune *ignores* OSC 9/99/777 and 9;4. It reads only OSC 133 `A` and tells programs to use `msg` instead.
- **Tuna:** publish *program status reported* (the decoded report plus the terminal) and *program status cleared*. A **program-status plugin** owns the records, the lifetime rules (it listens to *prompt shown*, *process exited* and *terminal reset*) and an inbox command. A notifications plugin listens to it.

#### Other agent-related sequences in use
- **Warp:** structured agent events go through `OSC 777;notify;warp://cli-agent;<JSON>`. The JSON carries a protocol version, session id, cwd and event type (SessionStart, Stop, PermissionRequest, PromptSubmit, ToolComplete, …). Emitters use it only when `WARP_CLI_AGENT_PROTOCOL_VERSION` is set. Claude Code ≥ 2.1.141 lets hooks emit terminal sequences via a `terminalSequence` JSON field ([warpdotdev/claude-code-warp @53ab8d6](https://github.com/warpdotdev/claude-code-warp/tree/53ab8d63ef74d7653002444762812d2fb5639eee): README, `plugins/warp/scripts/emit-terminal-sequence.sh`). *Inference:* in libghostty these arrive as an ordinary OSC 777 notification whose title is `warp://cli-agent`. Tuna should not advertise the Warp environment variable, so these will not be sent to it.
- **Wave:** `OSC 16162` shell integration (A/C/D/M/I/R with JSON), described above. It is a shell protocol, not an agent protocol.
- **Codex CLI:** OSC 9 or BEL notifications only (above). Its `notify` hook is an external program, not an escape sequence ([Codex config docs](https://learn.chatgpt.com/docs/config-file/config-advanced)).
- **Claude Code:** OSC 7501 status, OSC 9/99/777 notifications (which one depends on the terminal), OSC 9;4 progress, title glyphs, the bell, and OSC 52 for `/copy` (the iTerm2 setting). It also asks tmux users to enable `focus-events` and `extended-keys`, which means it uses focus reporting and extended keys (CSI u) ([Claude Code docs](https://code.claude.com/docs/en/terminal-config)).
- **OSC 9999 (Orca):** mentioned only in the OSC 7501 spec as earlier work. Unverified.

#### DCS / CSI items

| Item | Format and origin | libghostty | Tuna action |
|---|---|---|---|
| Bracketed paste | `CSI ? 2004 h/l`; pastes are wrapped in `CSI 200~ … CSI 201~` (xterm) | Mode tracked. `ghostty_terminal_paste()` wraps the text, replaces unsafe control bytes and refuses unsafe text unless `allow_unsafe` is set ([`paste.h`](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/paste.h)) | The terminal plugin's paste/yank command goes through the libghostty paste API. If it is refused, ask the user. |
| Focus reporting | `CSI ? 1004 h`; terminal sends `CSI I` / `CSI O` | Mode tracked; `ghostty_focus_encode` ([`focus.h`](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/focus.h)) | Send on Tuna window selection changes *and* browser tab visibility. Codex decides whether to notify based on focus. |
| Synchronized output | `CSI ? 2026 h/l` (Contour/kitty spec) | `RENDER_HOLD` effect plus `DATA_MODE` | Renderer-internal: suppress patches while held, with a timeout. Not a public hook (ADR 12: don't shape the contract around one consumer). |
| Kitty keyboard protocol | `CSI > flags u` push, `CSI < u` pop, `CSI ? u` query ([kitty](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)) | Query answered internally; flags readable (`DATA_KITTY_KEYBOARD_FLAGS`); key encoder in [`key.h`](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/key.h) | Terminal plugin keymap → libghostty key encoder. Needed for Shift+Enter in agents. |
| Mouse modes | 9/1000/1002/1003 tracking; 1005/1006/1015/1016 encodings; 1007 alternate scroll ([`modes.h`](https://github.com/ghostty-org/ghostty/blob/9ee02ae601d3eec567723287e1c20bd0e9f1489c/include/ghostty/vt/modes.h)) | Tracking readable (`DATA_MOUSE_TRACKING`); encoder in `mouse.h` | When tracking is on, send mouse events to the program; otherwise Tuna selection. Emacs-style: Shift overrides. |
| Kitty graphics | APC `_G…` ([kitty](https://sw.kovidgoyal.net/kitty/graphics-protocol/)) | Implemented: image storage, placements, pixels, animation (`kitty_graphics.h`); file/temp-file/shared-memory media off by default unless enabled | Later: renderer ships image pixels to the browser. Keep file and shared-memory media off (a remote program could otherwise read local files). |
| Sixel | DCS `q` | **Not implemented.** DA reports the sixel flag only as a constant; there is no sixel code in `src/terminal` | Not supported. |
| XTVERSION | `CSI > q` → `DCS >| name ST` | Answered internally; `XTVERSION` effect supplies the string, default "libghostty" (`stream_terminal.zig` L1806–1816) | Answer `tuna <version>`, so programs do not assume Ghostty's features. |
| DECRQM | `CSI ? Ps $ p` → `CSI ? Ps;Pm $ y` | Answered internally (`request_mode`) | Nothing to do. |
| XTGETTCAP / DECRQSS | DCS `+q` / `$q` | Answered from Ghostty's terminfo (advertises `Ms`) | See OSC 52. |
| Window ops | `CSI 8 t` resize; `CSI 14/16/18/19 t` size reports; mode 2048 in-band resize | `RESIZE_WINDOW` effect; `SIZE` effect | Ignore resize requests. Answer size queries from the terminal view. |

#### Bell
- **Format:** BEL `0x07`, outside an OSC.
- **Emitted by:** shells, Claude Code (`preferredNotifChannel: terminal_bell`), Codex (`bel`) and Rune programs.
- **libghostty:** `BELL` effect.
- **Tuna:** publish *bell rang*. The default reaction is Emacs's `ring-bell-function`: a visible flash plus a "needs attention" mark on the buffer if it is not visible. Rate-limit. A notifications plugin may raise a browser notification when the tab is hidden.

### C. Browser constraints

1. **Claim:** The Async Clipboard API exists only in secure contexts (HTTPS, or `localhost`, which browsers treat as potentially trustworthy). **Sources:** [MDN Clipboard API](https://developer.mozilla.org/en-US/docs/Web/API/Clipboard_API). **Support:** direct. **Confidence:** high.
2. **Claim:** Browsers differ on writes:
   - **Chromium:** a write needs the `clipboard-write` permission or transient activation; the permission persists. web.dev says `clipboard-write` is granted automatically to the active tab.
   - **Firefox and Safari:** a write needs transient activation, and neither supports the clipboard permissions (MDN says they do not plan to).
   - **WebKit:** rejects `write`/`writeText` called "outside the scope of a user gesture". Reports indicate this includes after an `await` ([WebKit bug 222262](https://bugs.webkit.org/show_bug.cgi?id=222262)).
   
   **Sources:** [MDN](https://developer.mozilla.org/en-US/docs/Web/API/Clipboard_API); [web.dev](https://web.dev/articles/async-clipboard); [WebKit blog](https://webkit.org/blog/10855/async-clipboard-api/). **Support:** direct. **Confidence:** high for Chromium and WebKit, medium for Firefox's exact window.
3. **Claim:** Transient activation lasts a short, implementation-defined time. Chromium extended it to 5 s, and WebKit had a patch to raise it to 5 s "to match other user agents". **Sources:** [HTML spec §6.4](https://html.spec.whatwg.org/multipage/interaction.html); [Chromium commit 231d25ff](https://chromium.googlesource.com/chromium/src/+/231d25ff06df1691d1de539dcdebf65ca5bd5ef7); [WebKit bug 239832](https://bugs.webkit.org/show_bug.cgi?id=239832). **Support:** direct (search excerpts; the pages were not fully fetched). **Confidence:** medium.
4. **Inference (OSC 52 write from a server-pushed event):**
   - **Chromium (active, focused tab):** a write from a Datastar SSE handler should succeed with no gesture.
   - **Firefox:** it succeeds only when the keypress that caused the copy (for example `y` in Neovim) happened within the activation window, which is usually true because the program reacts in milliseconds.
   - **Safari:** expect it to fail.
   - **Fallback in every browser:** always put the text on Tuna's kill ring, and if the browser write rejects, show "Program copied N characters — press a key or click to copy to system clipboard". That press supplies the gesture.
5. **Claim:** Reads are stricter:
   - The spec wants transient activation plus a browser "paste" UI.
   - Chromium prompts for the `clipboard-read` permission.
   - Firefox and Safari show a one-item "Paste" menu.
   - WebKit allows a read without that menu only during a real paste gesture, or when the clipboard came from the same origin.
   
   **Sources:** MDN; WebKit blog. **Support:** direct. **Confidence:** high. *Inference:* the browser read is asynchronous and needs a gesture, while libghostty's read callback must answer synchronously, so OSC 52 read cannot be live. The only safe options are *deny* (recommended) or *answer from server-side state* (the kill-ring head) under an explicit setting.
6. **Claim:** Permissions Policy: `clipboard-read` / `clipboard-write` must be allowed for iframes (`<iframe allow="clipboard-read; clipboard-write">`). **Sources:** MDN; web.dev. **Support:** direct. **Confidence:** high. *Inference:* this is irrelevant unless Tuna is embedded in an iframe. If Tuna sends a `Permissions-Policy` header, it must not deny these features to itself.
7. **Claim:** Notifications API:
   - Permission must be requested in response to a user gesture (enforced by Firefox since version 72 and by Safari).
   - Chrome and Firefox require a secure context, and cross-origin iframes cannot request permission.
   - `new Notification()` throws on most mobile browsers, which need `ServiceWorkerRegistration.showNotification()` instead.
   - `tag` replaces an earlier notification with the same tag.
   - Some browsers block bursts of notifications.
   
   **Sources:** [MDN Using the Notifications API](https://developer.mozilla.org/en-US/docs/Web/API/Notifications_API/Using_the_Notifications_API). **Support:** direct. **Confidence:** high. *Inference:* the notifications plugin needs an "Enable notifications" command bound to a key or click. It should use one tag per terminal per record so updates replace each other (this matches Rune's "one notification per state per tab"), rate-limit, and notify only when `document.hidden` or `!document.hasFocus()`. This fits TODO.md's planned PWA and service-worker work.
8. **Inference:** once permission is granted, showing a notification from an SSE-driven script does not need transient activation. I did not find an explicit primary statement of this; verify it in Firefox and Safari.

## Addendum: native recognition vs the unknown-sequence capture path, at the binding's pinned commit

The binding pins Ghostty `befcdfd2c3a1cb24d9ec886e93c95b2b5daa7028` (2026-10-03), per `gerbil-libghostty/native/GHOSTTY_COMMIT`. Every claim in this addendum is checked against that commit with `git show befcdfd2c:<path>`. The first two facts below correct findings A.2 and A.5.

**Two separate capture paths for unrecognised OSC sequences (fact):**

1. **Standalone OSC parser.** In `include/ghostty/vt/osc.h`, `ghostty_osc_set(parser, GHOSTTY_OSC_OPT_UNKNOWN_MAX_BYTES, &n)` (declared at L320) makes `ghostty_osc_end` return `GHOSTTY_OSC_COMMAND_UNKNOWN` (enum value 27). The raw bytes are then read with `ghostty_osc_command_data(..., GHOSTTY_OSC_DATA_UNKNOWN_CONTENT, ...)`. This path applies only to a parser created with `ghostty_osc_new`. **The terminal does not use it.** This is the call the binding deliberately excludes. The binding does wrap the standalone parser itself (`make-osc-parser`, `osc-parser-feed!` and so on in `ghostty.ss` L2323–2350), just without `ghostty_osc_set`.
2. **Terminal.** In `include/ghostty/vt/terminal.h`, `ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, fn)` (option 35) together with `GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES` (option 36) delivers a `GhosttyTerminalUnknownSequence` whose tag is `GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_APC` (0) or `GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC` (1). These are header lines L534–537 and L2022–2043.
   - The binding sets both options: `native-set-unknown` and `native-set-unknown-limit` in `private/ffi.ss` L359–361.
   - **But its C trampoline `gg_terminal_unknown` returns early unless the tag is APC** (`private/ffi.ss` L102–110). `PARITY.md` lists "unknown OSC" as excluded.
   - *Inference:* so through the current binding, **no unrecognised OSC reaches Gerbil by either path.** Removing the APC-only filter in `gg_terminal_unknown`, and binding the OSC branch of the union, would open path 2 without touching `ghostty_osc_set`.

**Effects available at `befcdfd2c` (fact, from the table at terminal.h L88–106):**
- Present: `WRITE_PTY`, `BELL`, `TITLE_CHANGED`, `PWD_CHANGED`, `ENQUIRY`, `XTVERSION`, `SIZE`, `COLOR_SCHEME`, `DEVICE_ATTRIBUTES`, `CLIPBOARD_WRITE`, `CLIPBOARD_READ`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `UNKNOWN_SEQUENCE`, `RENDER_HOLD`, `SEMANTIC_PROMPT`, `RESET`.
- Absent: `PROGRAM_STATUS` and `RESIZE_WINDOW`. Both arrived later.
- Bound by `gerbil-libghostty` (`private/ffi.ss` L141 and L348–359): `WRITE_PTY`, `BELL`, `TITLE_CHANGED`, `PWD_CHANGED`, `ENQUIRY`, `XTVERSION`, `SIZE`, `COLOR_SCHEME`, `DEVICE_ATTRIBUTES`, `CLIPBOARD_WRITE`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, and `UNKNOWN_SEQUENCE` (APC only).
- Not bound although the header has them: `CLIPBOARD_READ`, `SEMANTIC_PROMPT`, `RENDER_HOLD`, `RESET`.

**Per-sequence table at `befcdfd2c`:**

How to read the second column:
- *Native effect* means terminal.h has an effect for it.
- *Native state* means libghostty handles it inside the terminal (state or an automatic reply), with no callback.
- *Dropped* means `src/terminal/osc.zig` recognises the number, so it never counts as unknown, but `src/terminal/stream.zig` (L2738–2744) only logs it. Neither capture path can see it.
- *Unknown* means the number is not among the prefixes `osc.zig` recognises, so the capture path is the only route.

| Sequence | At `befcdfd2c` | Header / API | Through the current binding? |
|---|---|---|---|
| OSC 0/2 title | Native effect | terminal.h `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED` | Yes |
| OSC 1 icon | Recognised (`GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON`), no effect | osc.h | No (not needed) |
| OSC 7, OSC 9;9, OSC 1337 CurrentDir | Native effect | terminal.h `OPT_PWD_CHANGED`; `GHOSTTY_TERMINAL_DATA_PWD` | Yes |
| OSC 8 hyperlinks | Native state | grid_ref.h `ghostty_grid_ref_hyperlink_uri` | Check the binding's grid/render surface; not verified here |
| OSC 52 write, OSC 1337 Copy, OSC 5522 write | Native effect | terminal.h `OPT_CLIPBOARD_WRITE`, `GhosttyClipboardWrite` | Yes |
| OSC 52 read, OSC 5522 read | Native effect | terminal.h `OPT_CLIPBOARD_READ` | No (not bound; reads therefore answer empty, which is the recommended default) |
| OSC 133 | Native effect plus native state | terminal.h `OPT_SEMANTIC_PROMPT` (option 42), `GhosttyTerminalSemanticPrompt` | No (not bound) |
| OSC 633 (VS Code) | Unknown | terminal.h `OPT_UNKNOWN_SEQUENCE` with the OSC tag | No (APC filter) |
| OSC 16162 (Wave), OSC 21337 (iTerm2 status) | Unknown | same | No |
| OSC 9 and OSC 777 notifications (including Warp `warp://cli-agent`) | Native effect | terminal.h `OPT_DESKTOP_NOTIFICATION` | Yes |
| OSC 99 (kitty notifications) | Dropped (`kitty_desktop_notification`) | none | No, and the capture path cannot help |
| OSC 9;4 progress | Native effect | terminal.h `OPT_PROGRESS_REPORT` | Yes |
| Other ConEmu OSC 9;n | Dropped | none | No |
| OSC 4/10/11/12/104/110–112 colours | Native state plus automatic reply | terminal.h `OPT_COLOR_*` defaults, `OPT_WRITE_PTY` | Yes, given the defaults and the pty callback |
| OSC 1337 SetUserVar, RequestAttention, SetMark, File | Dropped (iterm2 parser logs "unimplemented") | none | No |
| OSC 3008 (context signal) | Dropped (`context_signal`) | none | No |
| OSC 22 pointer shape | Native state | terminal.h `GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE` (option 41), mouse.h `GhosttyMouseShape` | Depends on the binding's data getters; not verified |
| **OSC 7501 program status** | **Unknown.** `osc.zig` at this commit has no `@"75"`/`@"7501"` state, osc.h has no `PROGRAM_STATUS` command, and terminal.h has no `OPT_PROGRAM_STATUS` | Only terminal.h `OPT_UNKNOWN_SEQUENCE` with `GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC` (or osc.h `ghostty_osc_set` on a standalone parser, which is excluded) | **No.** Needs either (a) the OSC branch opened in `gg_terminal_unknown`, plus a Gerbil parser and validator for the spec, and Tuna answering the `?` query itself through the pty; or (b) a pin bump to at least `b7207b2ef`, which brings native `GHOSTTY_OSC_COMMAND_PROGRAM_STATUS` and the terminal.h effect `GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS` with a validated `GhosttyTerminalProgramStatus` and an automatic `?` reply |
| BEL | Native effect | terminal.h `OPT_BELL` | Yes |
| Mode 2026 synchronized output | Native effect plus mode state | terminal.h `OPT_RENDER_HOLD`; modes.h `GHOSTTY_MODE_SYNC_OUTPUT` | Mode readable; effect not bound |
| RIS | Native effect | terminal.h `OPT_RESET` | No (not bound) |
| Bracketed paste, focus, mouse modes, kitty keyboard | Native state plus encoders | modes.h; paste.h; focus.h; mouse.h; key.h | Input-side; the binding maps input and focus enums per `PARITY.md` |
| XTVERSION, DECRQM, DA, XTGETTCAP, DECRQSS | Native automatic reply | terminal.h `OPT_XTVERSION`, `OPT_DEVICE_ATTRIBUTES`, `OPT_WRITE_PTY` | Yes |
| Kitty graphics (APC) | Native | kitty_graphics.h | APC reaches the binding only when unrecognised; kitty graphics is recognised natively |
| Sixel | Not implemented | none | No |

**What this means (inference):**
- **OSC 7501 is the only sequence in the ranked list that depends on the excluded capture path at the pinned commit.**
- **Recommended route: bump the pin to at least `b7207b2ef` and bind `GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`.** This keeps `ghostty_osc_set` excluded, leaves the APC-only filter in place, and gets the spec's validation and feature-detection reply for free.
- **The capture path is only for OSC 633, 16162 and 21337,** all of them low priority.
- **Bind before building the planned features:** `SEMANTIC_PROMPT`, `RESET` and `RENDER_HOLD` are present at the pinned commit but not bound. Bind them before relying on OSC 133 or the OSC 7501 lifetime rules.
- **Unchanged:** OSC 99 and the dropped OSC 1337 keys stay unreachable whichever path is opened.

## Addendum: keys the browser keeps from a terminal in a tab

Shells and editors need Ctrl-W (delete word in readline, window commands in vim and Emacs), Ctrl-T (transpose, or SIGINFO on BSD), Ctrl-N, Ctrl-Tab and others. In an ordinary browser tab, Chrome never delivers some of these to the page.

1. **Claim:** Chrome keeps Ctrl+W, Ctrl+N and Ctrl+T (and a few others) from tab contents, and offers no option to capture them in a tab (crbug 671774). The workaround is a dedicated window. On macOS, Ctrl shortcuts pass through, because the browser's shortcuts use Cmd; Cmd-W cannot be captured. **Sources:** [hterm/Secure Shell FAQ, "How do I send Ctrl+W, Ctrl+N or Ctrl+T to the terminal?"](https://chromium.googlesource.com/apps/libapps/+/HEAD/nassh/docs/FAQ.md). **Support:** direct. **Confidence:** high.
2. **Claim:** In Chromium's code, an app window reserves no keys, and a fullscreen window reserves only exit-fullscreen and quit (Mac differs while the toolbar is showing). `BrowserCommandController::IsReservedCommandOrKey` returns false for `TYPE_APP` and `TYPE_APP_POPUP` windows ("In Apps mode, no keys are reserved"). **Sources:** [`chrome/browser/ui/browser_command_controller.cc` L500–558 @ f8e0532d](https://chromium.googlesource.com/chromium/src/+/f8e0532d40c4af788b946836a9f7a17c0ecafa18/chrome/browser/ui/browser_command_controller.cc). **Support:** direct (source). **Confidence:** high. *Inference (medium confidence):* an installed PWA opened in a standalone window is such an app window. It then receives Ctrl-W, Ctrl-T, Ctrl-N and Ctrl-Tab as ordinary `keydown` events, and calling `preventDefault()` stops the browser action. OS-level shortcuts (Alt-Tab, Super, Ctrl-Alt-Del) are still taken by the system. Verify by running it.
3. **Claim:** The Keyboard Lock API (`navigator.keyboard.lock(codes?)`) is supported only in Chromium (Chrome, Edge and Opera since 68). Firefox and Safari do not support it. It is marked experimental. **Sources:** [MDN browser-compat-data `api/Keyboard.json`](https://github.com/mdn/browser-compat-data/blob/main/api/Keyboard.json); [MDN `Keyboard.lock()`](https://developer.mozilla.org/en-US/docs/Web/API/Keyboard/lock). **Support:** direct. **Confidence:** high.
4. **Claim:** Keyboard Lock only takes effect in fullscreen started from JavaScript (`requestFullscreen()`). It does nothing in F11 fullscreen, and it must be called in the active top-level browsing context. MDN adds that it needs transient user activation. Holding Esc for 2 seconds always exits (the spec requires an escape hatch). The spec calls itself "best effort": OS secure sequences such as Ctrl-Alt-Del stay with the OS. **Sources:** [WICG Keyboard Lock spec §3.2, §4.2, §7](https://wicg.github.io/keyboard-lock/); [Chrome developer docs](https://developer.chrome.com/docs/capabilities/web-apis/keyboard-lock); MDN. **Support:** direct. **Confidence:** high. *Inference:* Keyboard Lock is a fullscreen-mode tool, not a fix for an editor in a normal tab. And per finding 2, ordinary fullscreen in Chromium already passes these keys to the page.
5. **Claim (ttyd, built on xterm.js):** ttyd cannot capture Ctrl-W. The maintainer's answer is to register `beforeunload`, so Ctrl-W asks for confirmation instead of closing the tab silently. Users install browser extensions that intercept the key ("xterm-ctrl-w-capture", "Better ctrl-w"). A request to make ttyd a PWA so it gets the keys is open. **Sources:** [ttyd #164](https://github.com/tsl0922/ttyd/issues/164); [ttyd #1473](https://github.com/tsl0922/ttyd/issues/1473); [ttyd #1181](https://github.com/tsl0922/ttyd/issues/1181). **Support:** direct. **Confidence:** high.
6. **Claim (VS Code for the Web):**
   - Keyboard support is classified as `Always` when native or running as an installed web app (`display-mode: standalone` or `window-controls-overlay`); `FullScreen` when `navigator.keyboard` exists or the browser is Safari; otherwise `None` (`src/vs/base/browser/canIUse.ts`).
   - On entering fullscreen it calls `navigator.keyboard.lock(['Escape'])`, and unlocks on leaving.
   - Outside those modes it drops default keybindings that collide with the browser (`_assertBrowserConflicts`), and its documentation lists alternatives for Ctrl+W, Ctrl+N and Ctrl+Shift+P.
   
   **Sources:** vscode @ [`ed3d9c1`](https://github.com/microsoft/vscode/tree/ed3d9c11647cf2d6c7b0e4f327fd1c7c5f0afc6e): `src/vs/base/browser/canIUse.ts` L31–41, `src/vs/base/browser/browser.ts` L112–129, `src/vs/workbench/services/keybinding/browser/keybindingService.ts` L244–263 and L502–560; [VS Code for the Web docs, "Keyboard shortcuts"](https://code.visualstudio.com/docs/setup/vscode-web). **Support:** direct. **Confidence:** high.
7. **Claim (code-server):** "Many shortcuts will not work by default, since they'll be 'caught' by the browser." The fix is to install the PWA in Chrome. Firefox needs the third-party "PWAs for Firefox" add-on and runtime. Other browsers need remapped keys. **Sources:** [code-server FAQ @ 4cb856c](https://github.com/coder/code-server/blob/4cb856c47572a83e1ce294c15a7400c3477a3ad6/docs/FAQ.md). **Support:** direct. **Confidence:** high.

**For Tuna (inference):**
- **Primary answer: install Tuna as a PWA and open it in a standalone window** (this matches TODO.md's PWA plan). The browser-input plugin then calls `preventDefault()` on every key Tuna binds, including Ctrl-W, Ctrl-T, Ctrl-N and Ctrl-Tab. This is what code-server and VS Code rely on, and Chromium's source backs it.
- **In a plain tab:**
  - Register `beforeunload` so an accidental Ctrl-W asks before closing, as ttyd does.
  - Detect `matchMedia('(display-mode: standalone)')` to know which mode Tuna is in.
  - Show a one-time hint offering to install.
  - Provide a prefix-key way to send any key to the terminal, the way Emacs's term-mode uses `C-c C-q` / `term-send-raw`. Then the shell can still get a literal Ctrl-W.
- **Optional fullscreen mode:** `requestFullscreen()` plus `navigator.keyboard.lock()` in Chromium gives an immersive mode. It is not needed for Ctrl-W itself.
- **Firefox:** I could not verify Firefox's own mechanism (a per-site "override keyboard shortcuts" permission, possibly `permissions.default.shortcuts`) in a primary source. Treat it as unverified.

## Proposed published events (inference)

Each event carries the terminal (its buffer) as the first value. Names are plain language; in code they would follow Tuna's `…-hook` convention.

| Event | Data | Source | Likely consumers |
|---|---|---|---|
| title changed | title (sanitised) | OSC 0/2 | terminal (buffer name), tabs/layout |
| directory changed | host, path, local? | OSC 7, 9;9, 1337 CurrentDir | terminal (default directory), completion, project plugins |
| bell rang | — | BEL | notifications, mode line |
| copy requested | target (clipboard/primary/selection), text or MIME list, protocol | OSC 52 / 1337 Copy / 5522 | clipboard plugin (kill ring + browser) |
| notification requested | title, body, protocol | OSC 9 / 777 | notifications plugin |
| progress changed | state (none/normal/error/indeterminate/paused), percent or none | OSC 9;4 | mode line, notifications |
| program status reported | id, state, kind, percent or none, app, title, message | OSC 7501 | program-status plugin |
| program status cleared | id (empty = all) | OSC 7501 `clear`, RIS | program-status plugin |
| prompt shown | prompt kind | OSC 133 A/P | terminal (prompt navigation), program-status |
| command started | command line or none | OSC 133 C | history, notifications |
| command finished | exit code or none, duration | OSC 133 D | notifications, mode line |
| terminal reset | — | RIS | program-status, any plugin keeping per-terminal state |
| process exited | exit status | PTY layer (not VT) | program-status, notifications |
| unrecognised sequence | kind (OSC/APC), number, content, truncated?, terminator | `UNKNOWN_SEQUENCE` | opt-in plugins for OSC 633, 16162, 21337 |

Not hooks:
- **Clipboard read policy:** a replaceable service that must answer synchronously. The default is deny.
- **Render hold, pointer shape, hyperlinks, colours:** renderer-internal state.
- **XTVERSION string:** configuration.

## Ranked support order (inference)

1. **Write-back plumbing and internally answered queries.** `WRITE_PTY` (DA, DECRQM, XTVERSION=tuna, XTGETTCAP, colour queries with theme defaults), plus bracketed paste via the paste API, the key encoder with the kitty keyboard protocol, mouse modes, focus reporting and render hold. Without these, TUIs and agents misbehave.
2. **Title, directory and bell.** Cheap, and they feed Emacs-like behaviour (buffer name, `default-directory`).
3. **OSC 52 write.** The kill ring and a best-effort browser write. Neovim and tmux depend on it, and Ghostty advertises `Ms`. Read stays **denied**.
4. **OSC 133 semantic prompts.** Prompt navigation, command finished, and the lifetime rule for OSC 7501.
5. **OSC 7501 program status.** Bump the binding, then build the program-status plugin with an inbox. This is the best agent signal and Claude Code uses it automatically.
6. **OSC 9/777 notifications and OSC 9;4 progress,** together with the browser Notifications/PWA work.
7. **OSC 8 hyperlinks and OSC 22 pointer shape** (renderer).
8. **Unknown-sequence passthrough,** then OSC 633 translation if users run VS Code-style integrations.
9. **Kitty graphics** (image transport to the browser).
10. **Never, or not without upstream work:** OSC 52 read from the live browser clipboard, CSI 8 t window resize, sixel, OSC 99 and OSC 1337 `SetUserVar`/`RequestAttention`. libghostty drops the last two; they would need an upstream change or a pre-scan of the byte stream.

## Contradictions

- **Where OSC 7501 comes from.** The task framed it as Rune's protocol. The primary sources show it was written by Mitchell Hashimoto and published in the Rex/Superlogical documentation; Rune and Ghostty implement it.
- **OSC 9;4 and OSC 7501.** The spec allows mapping OSC 9;4 onto the root status record. Rune does not map it. Both are allowed by the spec.
- **Clipboard writes.** web.dev says Chromium grants `clipboard-write` automatically to the active tab. MDN describes it as "permission or transient activation". The two are consistent for an active tab, but MDN is more conservative.

## Missing evidence

- I did not find Firefox's exact transient-activation timeout in a primary source.
- I could not confirm whether WebKit's 5 s patch landed.
- I did not find a statement that `new Notification()` from a non-gesture script works once permission is granted.
- I could not fetch the Per Bothner semantic-prompts spec or the OSC 8 gist, because their pages need JavaScript or were not fetched. The format descriptions come from VS Code, iTerm2 and the Ghostty parsers.
- Which other agents (Codex, Gemini CLI, OpenCode) emit OSC 7501 is unknown. Only Claude Code is documented.
- I did not test kitty-graphics browser transport, or how libghostty behaves when the clipboard callbacks block.

## Sources

**Kept:**
- Ghostty libghostty-vt headers and source @9ee02ae (terminal.h, osc.h, modes.h, paste.h, focus.h, kitty_graphics.h, stream.zig, stream_terminal.zig, osc/parsers/*): the authoritative integration surface.
- Program Status Protocol spec 0.4 (superlogical.com) and Mitchell Hashimoto's post: the OSC 7501 definition and its security rules.
- Rune docs @604b547 (program-status.md, clipboard.md, worktrees.md) and its `vteparser/driver.go`: how Rune presents status and handles the clipboard.
- Claude Code terminal-config docs: which sequences Claude Code actually emits.
- VS Code shell-integration docs: OSC 633 and the 133/1337 support.
- kitty docs (desktop notifications, pointer shapes): OSC 99 and OSC 22.
- iTerm2 escape-code docs: OSC 9, 9;4, 1337 and 21337.
- Warp notification docs and the `warpdotdev/claude-code-warp` repository: OSC 777 and `warp://cli-agent`.
- Wave's OSC 16162 doc.
- Codex PR #10043.
- MDN (Clipboard API, User activation, Notifications), web.dev async clipboard, the WebKit async clipboard blog, the HTML spec §6.4, Chromium commit 231d25ff and WebKit bug 239832.

**Deprioritised:**
- Blog posts on Safari clipboard workarounds (wolfgangrittner.dev, kian.org.uk): secondary; WebKit's blog and bug tracker cover the same points.
- control-codes.page: secondary summary of OSC 633.
- Fossies mirror of Codex: redundant with the PR.

## Next steps

- Bump `gerbil-libghostty` to at least Ghostty `b7207b2ef` and bind the `PROGRAM_STATUS`, `SEMANTIC_PROMPT`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `CLIPBOARD_*` and `UNKNOWN_SEQUENCE` effects.
- Spike in Chrome, Firefox and Safari: does `navigator.clipboard.writeText` called from a Datastar SSE handler succeed within about 1 s of a keydown? This decides how much of the "click to copy" fallback is needed.
- Brief for the owner (per `tuna/AGENTS.md`) before writing the terminal plugin's contract. It should cover the event table above and the clipboard read policy decision.
