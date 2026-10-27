# Research: Emacs terminal packages (ghostel, vterm, eat, term.el) and what Tuna's `terminal` plugin should learn

Read-only research, 2026-10. Terms used throughout:

- **PTY**: pseudo-terminal, the kernel device pair a shell talks to as if it were a real terminal.
- **VT**: the escape-sequence language terminals speak (named for DEC's VT100 and later terminals).
- **OSC**: Operating System Command, an escape sequence `ESC ] number ; text` ended by BEL or `ESC \`.
- **TUI**: a full-screen text program (vim, htop, less).
- **Alt screen**: the second screen a TUI switches to, so the shell's scrollback is left alone.
- **FFI**: foreign function interface, which lets Gerbil call C.

Labels: **Fact** means read in the cited source. **Inference** means my own conclusion.

## Summary: ideas Tuna should adopt

1. **Run the emulator and the PTY reader off the editor thread, and wake the editor only to redraw.** Ghostel's native path reads the PTY on a Zig thread, feeds libghostty-vt directly, and queues "redraw" or "OSC happened" events to Emacs. It absorbs a 10 MB `cat` in about 110 ms without freezing Emacs. vterm and eat parse on Emacs's main thread and freeze it (ghostel README, *Performance*). For Tuna this means a reader thread per terminal that owns the libghostty-vt handle under a lock. The editor thread only takes a snapshot of the dirty rows.
2. **Redraw dirty rows only, on a coalescing timer, and draw immediately after a keystroke.** Ghostel redraws within 50 ms of a keystroke at once and batches everything else at about 30 fps. Its delay drops to 16 ms after 100 ms of quiet. A hidden terminal is not redrawn until it is shown. It respects synchronized output (DEC mode 2026) and skips frames while a program holds one. libghostty-vt's C render-state API provides per-row dirty flags designed for exactly this. Each dirty row maps naturally to one HTML row morph.
3. **Adopt eat's and ghostel's input modes:**
   - **semi-char** (the default): most keys go to the program, with a short exception list (`C-c`, `C-x`, `M-x`, …).
   - **char**: every key goes to the program, with one escape key (`M-RET`).
   - **emacs** (read-only, live) and **copy** (read-only, frozen).
   - **line**: edit locally and send on `RET`.

   Copy mode should exit on the first ordinary key ("fast exit"). The browser reserves some keys (`C-w`, `C-t`, `C-n`), which makes the escape key a design decision rather than a detail.
4. **Use the standard OSCs that libghostty-vt already parses**: 7 (directory), 133 (prompt marks), 0/2 (title), 8 (links), 9/777 (notifications), 9;4 and 7501 (progress and status), 52 (clipboard). Do not invent vterm-style private sequences for them.
   - Handle shell→editor commands (vterm's `vterm_cmd`) through libghostty-vt's "unknown sequence" callback, with an explicit allow-list of commands.
   - Keep OSC 52 clipboard *read* off by default. Eat and ghostel do this for security; ghostel even leaves OSC 52 off by default.
5. **Inject shell integration automatically**, as ghostel does (`ENV` for bash, `ZDOTDIR` for zsh, `XDG_DATA_DIRS` for fish and nushell), so users never edit their rc files.
6. **Expect terminals to die with the server, unless a separate process holds them.**
   - Emacs sends SIGHUP to every child's process group when it exits (`process.c:8461`).
   - Under `emacs --daemon`, terminals survive closing frames because the daemon owns them. Tuna's "browser tab closes, server keeps running" is the same model and needs nothing extra.
   - To survive a server restart or a plugin swap, the PTY and emulator must live outside Tuna's process. zmx is a libghostty-based session daemon used this way with ghostel; libghostty-vt has a snapshot API for it.
   - **Inference:** Tuna's "swap a plugin by restarting it" model makes this matter more than it does in Emacs.
7. **Never block while holding the terminal lock.** Ghostel's two worst bugs were permanent freezes: #689, a PTY reply written while holding the lock, and #758, the event pipe filling while holding the lock.
8. **Size the PTY to the smallest view showing the terminal.** This is Emacs's default (`window-adjust-process-window-size-smallest`), and both ghostel and vterm use it. Ignore temporary height changes, such as the minibuffer growing, while not on the alt screen.

## 1. ghostel (libghostty-vt)

Pinned to `dakra/ghostel@42de3eb31ef65a96c3c4d846ac5eeb5636c0438d` (2026-10-26, v0.59.0). It builds against `ghostty-org/ghostty@a2e440396403385680008e456a741a7776091412` (`build.zig.zon`). Permalink base: `https://github.com/dakra/ghostel/blob/42de3eb31ef65a96c3c4d846ac5eeb5636c0438d/`.

### Architecture

- **Fact:** There are two layers: a Zig dynamic module (the engine) and Elisp (the user interface) (`README.org`, *Architecture*).
  - `src/GhostelTerm.zig` wraps `gt.Terminal` and `gt.Stream`.
  - `src/Renderer.zig` turns the grid into an Emacs buffer.
  - `src/handler.zig` intercepts OSC actions.
  - `src/NativeProcess.zig` and `src/PosixPtyProcess.zig` own the PTY.
  - `src/input.zig` encodes keys.
- **Fact:** ghostel uses libghostty-vt's **Zig module** (`ghostty_dep.module("ghostty-vt")`, `build.zig`), not the C header. It reads internal pages, pins and per-row dirty flags directly (`Renderer.zig` 943–1022).
  - `src/AGENTS.md` warns: "Do not read-and-clear … libghostty dirty flags outside the renderer. `RenderState.update` also mutates dirty state."
  - **Inference:** Gerbil cannot use Zig types, so Tuna must use the C API (`include/ghostty/vt/*.h`). Its documented incremental path is `render.h`, the Render State with global and per-row dirty flags and a two-phase `begin_update`/`end_update` lock split. Use only that path, and never mix it with raw dirty-flag reads.
- **Fact: how the screen reaches the buffer** (`Renderer.redraw`, 160–206):
  - The buffer holds scrollback rows followed by the active screen.
  - The renderer walks rows from a tracked "active pin". A row counts as dirty if its own dirty flag is set, or if the cursor moved onto or off it (`isRowDirty`, 943–956). Adjacent dirty rows are coalesced into one span, and the old lines are replaced with `delete-region` plus an insert of propertized text.
  - The whole buffer is erased and rebuilt when the screen changes (primary versus alt), on a resize that changes the column count, or after a scrollback clear.
  - Scrollback evicted inside libghostty is deleted from the top of the buffer (`evictScrollback`).
  - Cursor position and style are published as buffer-local variables (`renderCursor`).
- **Fact:** "The renderer owns position preservation". Point, mark and window starts are saved and remapped across row replacement, resize and eviction inside the renderer, not by Elisp wrapped around the redraw (`README.org` *Renderer and buffer positions*; `src/saved_markers.zig`).
  - **Inference for Tuna:** keep selections, marks and view anchors inside the terminal plugin's projection. Do not patch them from outside after each redraw.
- **Fact: redraw scheduling** (`lisp/ghostel.el` 4285–4323, `ghostel--invalidate`):
  - If no window shows the buffer, it sets `ghostel--pending-redraw` and does nothing. A `pre-redisplay` hook renders when the buffer is shown.
  - Output within `ghostel-immediate-redraw-interval` (0.05 s) of the last keystroke is drawn immediately.
  - Otherwise a timer of `ghostel-timer-delay` (0.033 s) runs, reduced to 0.016 s if output had been idle for more than 100 ms.
  - Synchronized output (mode 2026) blocks redraw until the program closes the frame (`Renderer.redraw` line 161; `handler.zig` `renderHoldCallback`).
- **Fact: PTY ownership** (`README.org` *PTY and process ownership*; `NativeProcess.zig`):
  - Zig opens the PTY, forks with `setsid` and `TIOCSCTTY` (`PosixPtyProcess.zig` 110–111), and reads on a background thread.
  - Events are serialized as Lisp forms and written to an Emacs pipe process, whose filter evaluates them.
  - A detached reaper thread `waitpid`s the child, so teardown never blocks Emacs (`NativeProcess.zig` 258–276).
  - Remote (TRAMP) shells fall back to Emacs's own process and filter, sharing the same renderer.
- **Fact: wide characters and glyph fitting.** Wide cells are emitted once and their spacer cells skipped (`Renderer.zig` 583). Glyphs whose font metrics don't fit the cell are scaled with `display (min-width … height …)`. A lone wide icon may borrow the following blank cell (`adjustGlyph`/`adjustWidth`, 699–812).
  - **Inference:** this is Emacs-specific pain. In a browser, Tuna can render each row with a monospace grid (CSS `ch` units, or explicit two-cell spans for wide cells) and avoid most of it. The open issues below show it is still a bug source.

### libghostty-vt features ghostel uses

**Fact** (`handler.zig`, `GhostelTerm.zig`, README *Features*):

- Terminal plus Stream parser.
- Grapheme-cluster mode (`default_modes = .{ .grapheme_cluster = true }`).
- Scrollback limited by bytes (5 MB default, `ghostel-max-scrollback`, `ghostel.el:236`).
- Reflow on resize.
- Key encoder, including the Kitty keyboard protocol.
- Mouse encoder (SGR), focus events (mode 1004), bracketed paste.
- Kitty graphics, with a PNG decode hook through vendored `stb_image`.
- OSC 8 hyperlinks, read from page hyperlink sets.
- Effects callbacks for: write-to-PTY (query replies), bell, title, color-scheme query (`CSI ? 996 n`), device attributes (reports as VT220), XTWINOPS size, render hold (2026), semantic prompt (OSC 133), program status (OSC 7501).
- Its own title stack (`CSI 22/23 t`).
- OSC 4/10/11 color queries are answered from Emacs faces.
- `TERM=xterm-ghostty`, with bundled compiled terminfo in `etc/terminfo/`.
- Answers OSC 7501 support queries.

**Fact:** at the pinned commit, the C API (`include/ghostty/vt/terminal.h` lines 89–108) exposes the same effects:

- `WRITE_PTY`, `BELL`, `TITLE_CHANGED`
- `PWD_CHANGED` (OSC 7/9/1337)
- `CLIPBOARD_WRITE` and `CLIPBOARD_READ` (OSC 52, 1337, 5522)
- `DESKTOP_NOTIFICATION` (OSC 9/777), `PROGRESS_REPORT` (9;4), `PROGRAM_STATUS` (7501)
- `SEMANTIC_PROMPT` (133), `RENDER_HOLD` (2026), `RESET`, `RESIZE_WINDOW`
- `UNKNOWN_SEQUENCE`, for OSC and APC sequences the library doesn't implement

It also offers `render.h` (dirty tracking), `formatter.h` (format content as plain text, VT, or **HTML**), `snapshot.h` (encode and restore complete terminal state), `search.h`, `selection.h`, and key, mouse, focus and paste encoders.

The header warns: "This is an incomplete, work-in-progress API. It is not yet stable" (`include/ghostty/vt.h`). Callbacks run synchronously during writes and must not re-enter `vt_write` or block (`terminal.h` 79–84).

### Input

**Fact** (`README.org` *Input modes*; `ghostel.el:554`). There are five modes, borrowed from eat:

- **semi-char**: keys go to the program except `ghostel-keymap-exceptions` (`C-c`, `C-x`, `C-u`, `C-h`, `M-x`, `M-:`, `C-\`).
  - `C-c C-c`, `C-c C-z` and `C-c C-d` send interrupt, suspend and end-of-file.
  - `C-q` sends the next key literally.
  - `C-y` pastes using bracketed paste.
- **char**: all keys go to the program; `M-RET` is the only way out.
- **emacs**: read-only and live. The window follows output only while point sits on the cursor.
- **copy**: read-only and frozen; redraws pause.
- **line**: compose locally, send the whole line on `RET`. It drops to semi-char automatically when an alt-screen TUI starts, and resumes when the TUI exits.

Other input behaviour:

- `ghostel-readonly-fast-exit` leaves copy or emacs mode on a self-inserting key and sends that key on.
- Activating the mark, a mouse drag, isearch or `consult-line` switches to copy mode automatically, so streaming output can't clobber a selection.
- Mouse events go to the TUI when it enabled DEC mouse tracking (1000/1002/1003); otherwise they behave like normal Emacs mouse input.
- Soft-wrapped newlines are removed from copied text.
- **Password prompts:** when the PTY is in canonical mode with echo off (`pty_utils.zig:38–40`, `tio.lflag.ICANON and !tio.lflag.ECHO`), ghostel opens `read-passwd` and sends the answer through the PTY. The keys never enter the key history. A prompt regex is the fallback for remote shells.

### Escape sequences, OSC handling and shell callbacks

**Fact** (`handler.zig`):

| Sequence | What ghostel does |
|---|---|
| OSC 7 (and 9;9) | Routed to `ghostel--update-directory`, which sets `default-directory` and is TRAMP-aware for remote hosts (`ghostel.el:3538`). |
| OSC 133 A/B/C/D | Routed to `ghostel--osc133-marker` (`ghostel-shell.el:551`). Used for prompt navigation and for "is a command running?". |
| OSC 0/2 | Title, shown in the mode line or used to rename the buffer. |
| OSC 52 | Opt-in through `ghostel-enable-osc52` (default nil, `ghostel.el:473`). The bundled terminfo deliberately does not advertise OSC 52, so programs don't silently lose clipboard writes. Queries (`?`) are dropped. |
| OSC 52 with kind `e` | Ghostel's own extension: `ghostel_cmd`, which calls allow-listed Elisp in `ghostel-eval-cmds` (default `find-file`, `find-file-other-window`, `dired`, `dired-other-window`, `message`; `ghostel.el:462`). |
| OSC 8 | Clickable links, which survive wrapping across rows. Plain URLs and `file:line` text are also detected on a separate coalesced timer. |
| OSC 9 / 777 | Runs `ghostel-notification-functions` (alert.el, or re-emitted to an outer terminal). |
| OSC 9;4 and 7501 | Per-terminal status records, shown in the mode line, with a notification when a terminal you aren't looking at finishes or is blocked. |
| BEL | Runs `ghostel-bell-functions`. |
| `CSI ? 996 n` / mode 2031 | Reports light or dark, as classified from the Emacs face. |

**Inference:** overloading OSC 52 with a private kind byte is a hack. The C API's `UNKNOWN_SEQUENCE` callback lets Tuna own a private OSC number without touching the clipboard path. OSC 51, as used by vterm and eat, is reserved for Emacs in xterm (comment in `eat.el` 5431–5435).

### Shell integration

**Fact:** integration is automatic for bash, zsh, fish and nushell (`ghostel-shell.el` 320–356):

- **bash:** `ENV=<inject.bash>` plus `GHOSTEL_BASH_INJECT`. The bash script leaves POSIX mode, sources the user's normal startup files, then loads `etc/shell/ghostel.bash`.
- **zsh:** a `ZDOTDIR` shim, with the original saved in `GHOSTEL_ZSH_ZDOTDIR`.
- **fish and nushell:** `XDG_DATA_DIRS` prepended with the integration directory.

`ghostel.bash` sends:

- OSC 7 as `kitty-shell-cwd://host/path`, using the real `gethostname`.
- OSC 133 with the same marker layout as Ghostty's own integration (133;A from `PROMPT_COMMAND`, P/B wrapped around `PS1`).
- `stty echo`.
- The `ghostel_cmd` function.
- An `ssh` wrapper that installs the terminfo on remote hosts.

It sets `INSIDE_EMACS=ghostel` and `EMACS_GHOSTEL_PATH`. macOS's bash 3.2 ignores `ENV`, so auto-injection fails there (README).

### Exit, daemon and persistence

**Fact:**

- `kill-emacs-hook` sends `SIGKILL` (9) to every native child (`ghostel.el` 4186–4192, `ghostel--kill-native-processes-on-exit`). The reason given is that Emacs disables sentinels at exit, and the native children are not Emacs processes, so they would not otherwise receive Emacs's SIGHUP.
- Killing the buffer detaches the pipe and asks the child to terminate (4194–4206).
- `kill-buffer-query-functions` and `kill-emacs-query-functions` ask for confirmation when a command is running (`ghostel-query-before-killing`, `auto` uses OSC 133; 4970–4992).
- Daemon-aware code:
  - It skips the daemon's invisible initial frame when sizing (`ghostel--daemon-dummy-frame-p`, 4361–4367).
  - It installs a lone-ESC filter on terminal frames created later by `emacsclient -t` (around 4920).
  - Kitty graphics are off for a terminal frame.
- desktop.el and bookmarks restore only the directory and buffer name, starting a fresh shell. Saved commands and remote terminals are not respawned (README *Desktop*).
- No reattach: issue #745, "Run ghostel as a separate process to survive Emacs restarts", was closed after users pointed to **zmx** plus **emacs-term-sessions**.
- zmx (neurosnap/zmx) is a libghostty-based session daemon. Since PR 138 (2026-08) it sends libghostty snapshots to rehydrate a client that attaches (`https://pr.pico.sh/zmx/138`). I have not read its code.

### Known problems

**Fact**, from `gh issue list -R dakra/ghostel`, read 2026-10:

- **Freezes from lock discipline.**
  - #689 (closed): a query reply was written to the PTY inside the parse loop while holding the terminal lock. The PTY input queue filled, and Emacs hung forever.
  - #758 (open): the 16 KB event buffer is flushed with a blocking pipe write while the lock is held. On Windows the pipe is 4 KB, and Emacs hangs on switching to the buffer. The maintainer is undecided between dropping events and growing the buffer.
  - #691: a freeze with zellij, unresolved in the thread.
- **Performance:** #673. Redraw time was dominated by `ghostel--kitty-display-virtual`, which scanned for Kitty placeholder characters on every redraw. Output with long JSON lines took about 5 s to return a prompt. The user disabled it by hand.
- **Wide characters and glyphs:** #727 (Nerd Font icons at half size, a regression), #763 (cursor drift with zero-width glyphs), #752 (padding ignores text scale), #708.
- **Mouse selection and resize interactions:** #695, #698, #704, #674, #765.
- **Kitty images:** #642 (1×1 cell size reported before the first redraw), #677 (pixel size left at zero on the PTY).
- **Build friction:** exactly Zig 0.16.0 is required (`build.zig` has a compile error otherwise). A prebuilt module is downloaded or `M-x ghostel-module-compile` is offered (#730, #731).

### Design choices: copy or avoid

- **Copy:**
  - The background reader with a coalesced event channel.
  - The renderer as the single consumer of dirty state.
  - The immediate-echo fast path.
  - Skipping hidden terminals.
  - The five input modes with fast exit.
  - Password detection from termios.
  - The OSC 52 opt-in, and not advertising it in terminfo.
  - Auto-injected shell integration built on the standard OSCs.
  - Allow-listed shell→editor commands.
  - Status records from 9;4 and 7501.
  - Answering color queries from the theme.
- **Avoid:**
  - Blocking I/O while holding the terminal lock.
  - Unbounded per-redraw whole-buffer scans (#673).
  - Overloading OSC 52.
  - Depending on internal Zig structures. Tuna should use the C API and pin the ghostty commit.

## 2. vterm (emacs-libvterm, libvterm)

Pinned to `akermu/emacs-libvterm@6d715a93fa0e5182bc137d4db09f376e06938aa5`.

- **Architecture (fact).** A C module (`vterm-module.c`) wraps libvterm. The system libvterm is used, or it is downloaded and built through CMake (`CMakeLists.txt`). Emacs owns the PTY, started through `make-process :connection-type 'pty` with a `/bin/sh -c "stty … && exec shell"` wrapper (`vterm.el` 800–826). The filter feeds bytes to libvterm.
  - Damage callbacks (`term_damage`, `term_moverect`, `term_movecursor`) widen an "invalid" row range (`vterm-module.c` 567–592). `term_redraw` rewrites only those lines, plus scrollback pushed since the last redraw (`refresh_lines`, `refresh_screen`, 311–420, 628–672).
  - Merging is set to `VTERM_DAMAGE_SCROLL` (1269).
  - The redraw timer is `vterm-timer-delay` 0.1 s (`vterm.el:591`, 1410–1418).
  - Scrollback defaults to 1000 lines, capped at 100 000 by `SB_MAX` (README FAQ).
- **Input (fact).** One keymap sends everything except `vterm-keymap-exceptions` (`C-c C-x C-u C-g C-h C-l M-x M-o C-y M-y`; `vterm.el` 252–262). `vterm-copy-mode` (`C-c C-t`) freezes the buffer, and `RET` copies and exits (735–739). Resizing is skipped in copy mode (1649–1667). Per the ghostel comparison, vterm takes mouse clicks for Emacs rather than forwarding them.
- **OSC (fact).**
  - OSC 51;A sets the directory and marks the end of the prompt. Prompt columns are stored per line (`vterm-module.c` 1085–1112).
  - OSC 51;E queues Elisp-call strings, run at the next redraw (1113–1127).
  - `vterm--eval` splits the string and runs the command only if it is in `vterm-eval-cmds` (`vterm.el` 1769–1780). Shell side: `vterm_cmd` in `etc/emacs-vterm-bash.sh`.
  - OSC 52 sets the clipboard only, behind `vterm-enable-manipulate-selection-data-by-osc52`; there is no query support (`selection_callbacks .query = NULL`).
  - The title comes from `VTERM_PROP_TITLE`.
- **Shell integration (fact).** Manual: users source `etc/emacs-vterm-{bash,zsh}.sh` / `.fish`. These wrap the sequences for tmux and screen passthrough, emit 51;A from `PS1`, and redefine `clear`.
- **Exit and daemon (fact).** vterm relies on Emacs process semantics: SIGHUP on exit (section 5). `vterm-kill-buffer-on-exit` defaults to t. There is no persistence; bookmarks store only the directory.
- **Complaints (fact, open issue titles).** #766 term resize, #572 wrapping under 80 columns (`vterm-min-window-width` defaults to 80), #432 and #354 flicker with `hl-line-mode` and on every key press, #600, #631 and #691 tmux interactions, #776 shade glyphs, #558 freeze while compiling the module. The README warns that bugs "can lead to segmentation faults and crashes". There is no Windows support.

## 3. eat (Emulate A Terminal, pure Elisp)

Pinned to `codeberg.org/akib/emacs-eat@c8d54d649872bfe7b2b9f49ae5c2addbf12d3b99`. That is the last commit, 2025-02-06. **The project looks inactive; treat its status as stale.**

- **Architecture (fact).** The parser and emulator are Elisp (`eat--t-handle-output`, 3346).
  - It writes directly into the terminal region of the buffer, with `begin`/`end` markers (struct at 1126–1135). There is no separate grid.
  - Output chunks are queued. They are flushed after at most `eat-maximum-latency` (0.033 s), and at least `eat-minimum-latency` (0.008 s) after the last chunk (`eat--filter`, 6846–6869; options 635–655).
  - Scrollback is 128 K characters (159).
  - Wide characters are measured with Emacs's `char-width` (1716–1721), and cursor motion "Assume[s] all characters occupy a single column" (993).
  - **Inference:** Emacs's `char-width` can disagree with the program's `wcwidth`, which is a classic cause of misalignment.
- **Input (fact).** Semi-char, char, emacs and line modes (`eat-emacs-mode` 5897, `eat-semi-char-mode` 5907, `eat-char-mode` 5919, `eat-line-mode` 5998). `eat-semi-char-non-bound-keys` lists the exceptions (291–300). `C-q` quotes the next key, and `M-RET` / `C-M-m` leaves char mode. Emacs mode is live, not frozen. Full mouse support. Sixel images.
- **OSC (fact).**
  - 0/2 for the title, 7 for the directory (`eat--t-set-cwd` accepts only `file:` URLs), 10/11 color queries (3698–3728).
  - 52 with both set and **query**. Set is governed by `eat-enable-kill-from-terminal` (default t). Query is governed by `eat-enable-yank-to-terminal`, default **nil**, "disabled for security reasons" (165–181, 2889–2950).
  - OSC 51;e;… "UI commands" (5429–5490):
    - A: host and directory, base64-encoded.
    - B/C/E: prompt boundaries.
    - F: the command text.
    - G: pre-exec.
    - H: exit status.
    - I: shell history exchange, so line mode can use the shell's history.
    - J: new prompt.
    - M: messages to `eat-message-handler-alist`, which is eat's fixed, user-defined alternative to arbitrary eval.
- **Shell integration (fact).** `integration/bash` and `integration/zsh`, sourced manually, emit the 51;e codes from `PROMPT_COMMAND` and a DEBUG-trap preexec. It also ships its own terminfo (`eat-truecolor` and others).
- **Exit (fact).** `eat-query-before-killing-running-terminal` `auto` uses shell integration to tell whether a command is running (183–192). Otherwise eat follows Emacs process semantics.
- **Complaints.** Throughput is the main one. Ghostel's benchmark gives eat about 6 MB/s versus 75 MB/s for ghostel on the same Emacs-process path (README *Performance*; author-run, Apple M4 Max). **Missing:** I could not search Codeberg issues, because web search was rate-limited and `gh` doesn't reach Codeberg.

## 4. term.el / ansi-term (built in)

Emacs checkout `/home/jay/Code/emacs` at `541f693ca2e8de166cfe52c39bbfc497142215e9` (2026-07-16). Mirror permalinks: `https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/<path>#L<n>`.

- **Architecture (fact).**
  - Pure Elisp. `term-emulate-terminal` (`lisp/term.el:3077`) is the process filter and edits the buffer in place.
  - `TERM=eterm-color` (1702), with a TERMCAP string (1786–1797).
  - `term-buffer-maximum-size` is 8192 lines (933).
  - `term-width` is the logical width (341, 1181), and resizing goes through `term-reset-size` (1322).
- **Input (fact).**
  - **char mode** (`term-char-mode`, 1494) uses `term-raw-map`; **line mode** (`term-line-mode`, 1522) uses comint-like editing.
  - A single escape prefix, `term-escape-char` (default `C-c`, set by `term-set-escape-char`, 1076–1086), reaches Emacs from char mode.
  - ansi-term uses `C-x` as its escape.
- **OSC (fact).**
  - `term-osc-handlers` is checked first (607–632), then `ansi-osc-handlers` (`lisp/ansi-osc.el:65–68`): "0" and "2" set the window title, "7" tracks the directory, "8" makes links.
  - Older directory tracking uses `\032/dir\n` (`term-command-hook`) and `\033AnSiTc|h|u <value>\n` messages (`term-handle-ansi-terminal-messages`). Users paste the shell snippet from the commentary (200–245) into their rc files.
- **Complaints (fact).** vterm's README says term "do[es] not implement all the escape codes needed … inferior performance … with large bursts of output". Ghostel's benchmark puts term at about 7 MB/s.

## 5. GNU Emacs process and PTY handling (C)

Same checkout. All facts read in source.

- **PTY creation.**
  - `create_process` (`src/process.c:2201`) calls `allocate_pty` (878).
  - The child detaches with `dissociate_controlling_tty`, which calls `setsid` (2164), then sets the controlling terminal with `TIOCSCTTY` (`src/callproc.c:1561–1564`).
  - `set-process-window-size` (`process.c:1538–1556`) applies `TIOCSWINSZ` through `set_window_size`. The kernel then sends SIGWINCH to the foreground group.
- **Window size policy.**
  - `window--adjust-process-windows` runs on `window-configuration-change-hook` (`lisp/window.el` 11395–11409).
  - It calls `window-adjust-process-window-size-function`, which defaults to `window-adjust-process-window-size-smallest` (11311–11330), per process, over all windows that show its buffer.
  - The process property `adjust-window-size-function` overrides it (vterm uses this; `vterm.el` 835–836).
- **Signals.**
  - `process_send_signal` (`process.c:7088`) with `current_group` nil sends to the shell's process group (`gid = p->pid`, 7110–7112), computed as `pid = no_pgrp ? gid : - gid` (7212).
  - With `current_group` non-nil and `SIGNALS_VIA_CHARACTERS`, it writes the terminal's interrupt, quit or suspend character down the PTY instead (7115–7153). This reaches the *foreground* job.
- **Exit.**
  - `kill_buffer_processes` (`process.c:8461–8476`) calls `Fdelete_process` for network, serial and pipe connections, and **sends SIGHUP to the process group** for real subprocesses.
  - It runs when a buffer is killed (`src/buffer.c:2073`, from `Fkill_buffer`) and at exit (`src/emacs.c:3151–3152` in `shut_down_emacs`, 3100). At exit it first sets `inhibit_sentinels = 1`, so no sentinel runs.
  - Before that, `save-buffers-kill-emacs` asks "Active processes exist; kill them and exit anyway?" for processes with `process-query-on-exit-flag` set (`lisp/files.el:8652`).
- **Daemon (inference from the code above).**
  - Processes belong to the Emacs process, not to frames. Closing an `emacsclient` frame leaves terminals running, and a later client can display the same buffer.
  - Killing the daemon SIGHUPs them all.
  - The PTY size follows whichever windows currently show the buffer. When none do, nothing resizes it.

## How this maps onto Tuna (inferences)

- Tuna's process is the "daemon", and browser tabs are the "frames". Terminals survive closing a tab with no extra work. Tuna's own exit should SIGHUP each terminal's process group, as Emacs does, and ask first when OSC 133 shows a running command.
- Several tabs can mirror one editor, so several views may show one terminal. Use the Emacs "smallest" rule for the PTY size, and resize only from views that are actually displayed.
- **Placement under ADR 12:**
  - The PTY, reader thread and libghostty-vt FFI belong in a `terminal` plugin (or a small shared library if a second user appears), never in the kernel.
  - The capability audit already flags the gap: "no documented window-size (`TIOCSWINSZ`) or termios control — needs a small FFI" (`agents/research/capability-audit/03-runtime-and-environment.md` I2). It also notes that whole-frame morphs per output chunk won't scale, so chunks must be coalesced and frame rate capped (`04-package-stress-tests.md` row 70).
- **Rendering:** project the render state's dirty rows into per-row HTML nodes with stable IDs, so Datastar morphs only those rows. libghostty-vt's HTML formatter could produce the row markup, but its output and styling would need checking against Tuna's stylesheet rules (no colours in Gerbil; tokens in CSS). Unverified.
- **Copy and search:** materialize scrollback as text, as ghostel does, so the editor's search, selection and kill commands work on it. Or use libghostty's `search.h` and `selection.h`; this is a design choice to make in a brief.
- **Persistence:** with libghostty's snapshot API, a separate holder process (Tuna-owned, or zmx) could keep shells alive across server restarts and plugin swaps, then rehydrate the screen. Defer this, but keep the reader and emulator behind a seam so the holder can move out of process later.

## Contradictions

- Default scrollback: ghostel's comparison table says vterm has 1,000 lines and eat 128 KB. Both agree with source (`vterm.el:210`, `eat.el:159`). No conflict found.
- Ghostel says vterm "intercepts mouse clicks … and does not forward them". I did not verify this in vterm's source.
- Ghostel's README says the native module "is downloaded automatically on first use" in some places. Issue #730 says that is no longer true.

## Missing evidence

- Performance numbers come from ghostel's own benchmark on one machine, and I did not reproduce them.
- eat's and term.el's user complaints were not gathered from issue trackers, because web search was rate-limited and eat is on Codeberg.
- zmx and emacs-term-sessions were seen only through search summaries. Their protocols and licences are unverified.
- Whether a standalone `libghostty-vt` shared library with the C API builds cleanly at ghostty `a2e44039…`, and with which `zig build` flags, is unverified. Ghostel passes `.emit-lib-vt = true` to the dependency.
- The libghostty-vt C API is explicitly unstable, and how fast it changes was not measured.
- Browser-reserved keys, and which escape key works in a tab, are not covered here.

## Sources

**Kept:**

- ghostel source and README.org at `42de3eb` — the primary subject. Read: `src/handler.zig`, `src/Renderer.zig`, `src/GhostelTerm.zig`, `src/NativeProcess.zig`, `src/PosixPtyProcess.zig`, `src/pty_utils.zig`, `src/AGENTS.md`, `build.zig`, `build.zig.zon`, `lisp/ghostel.el`, `lisp/ghostel-shell.el`, `etc/shell/ghostel.bash`, `etc/shell/bootstrap/bash/inject.bash`.
- Ghostel GitHub issues #673, #689, #691, #745 and #758 (read with `gh`) — real failure modes.
- ghostty `a2e44039` `include/ghostty/vt.h`, `vt/terminal.h`, `vt/render.h`, `vt/snapshot.h`, `vt/screen.h` — the C API Tuna would bind.
- emacs-libvterm `6d715a9` `vterm-module.c`, `vterm.el`, `etc/emacs-vterm-bash.sh`, `CMakeLists.txt`, `README.md`, and its open issue list.
- emacs-eat `c8d54d6` `eat.el`, `integration/bash`.
- GNU Emacs `541f693` `src/process.c`, `src/emacs.c`, `src/buffer.c`, `src/callproc.c`, `lisp/term.el`, `lisp/ansi-osc.el`, `lisp/window.el`, `lisp/files.el`.

**Deprioritized:**

- The zmx site and the PR summary at pico.sh — search summaries only.
- Ghostel's feature-comparison table — written by an interested party; used only where checked against source.
