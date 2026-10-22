# Research: per-tab state — Emacs multi-terminal and multi-client prior art

Read-only research, 2026-10 (researcher subagent). Emacs claims target the local checkout `/home/jay/Code/emacs` at commit `541f693ca2e8de166cfe52c39bbfc497142215e9` (master, 2026-07-04, Emacs 31 development); permalinks below use `E` = `https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9`. Labels: **[F]** cited fact, **[I]** interpretation of a source, **[R]** researcher inference.

## Summary

Emacs keeps almost everything global or per-buffer; per-terminal state (the `kboard`) is only the *input stream's* state — pending prefix argument, `last-command`, keyboard macro being defined, key-translation maps, keystroke echo — while each frame owns a window tree and a selected window, and each window owns point, start and hscroll. Its sharp edges come from the few things that stayed process-global: one selected frame, one `this-command`, one minibuffer recursion depth, so a prompt in one terminal locks every other terminal ("single-kboard mode"), a known pain point still being patched in 2026. Prior art splits into two coherent models — **mirror** (tmux clients on one session, Neovim's multiple UIs: one current window/cursor, shared size computed from all clients) and **independent frames** (emacsclient, tmux session groups, VS Code/Zed "follow" as opt-in) — and both agree that **input-sequence state and measured geometry must be per client**. For Tuna, the minimum per-tab set is: client identity and input numbering, pending key-sequence/prefix state, measured layout facts (viewport size, scroll measurements), the screen last sent/applied, and which frame the tab displays; everything else (buffers, texts, layout tree, views with their points, kill ring, settings, histories) can stay shared, with "which frame and which selected view" being the product choice between mirror and independent.

## 1. Emacs

### 1.1 Per-terminal: `struct kboard`

- **[F]** Each KBOARD is "one logical input stream"; there is one per terminal device, and "So that definition of keyboard macros, and reading of prefix arguments, can happen in parallel on various KBOARDs at once, the state information for those activities is stored in the KBOARD" (`src/keyboard.h:40-52`, [src/keyboard.h#L40-L79](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/keyboard.h#L40-L79)). Fields (`src/keyboard.h:81-185`):
  - `Voverriding_terminal_local_map` (per-terminal overriding keymap; used by `universal-argument` and transient maps);
  - `Vlast_command`, `Vreal_last_command`, `Vlast_repeatable_command`;
  - `Vprefix_arg` (argument for the *next* command), `Vlast_prefix_arg`;
  - `kbd_queue` + `kbd_queue_has_data` (events from this terminal set aside while another terminal is being served);
  - `defining_kbd_macro`, `kbd_macro_buffer/ptr/end/bufsize`, `Vlast_kbd_macro`;
  - `Vkeyboard_translate_table`, `Vlocal_function_key_map`, `Vinput_decode_map`, `Vsystem_key_alist`, `Vwindow_system`;
  - `Vdefault_minibuffer_frame`;
  - `echo_string`, `echo_prompt`, `immediate_echo` (the partially typed key sequence echoed in the echo area).
- **[F]** Not per-kboard: `this-command` is a plain global (`DEFVAR_LISP ("this-command", …)`, `src/keyboard.c:13808`), as are `current-prefix-arg` (`src/callint.c:878`) and `executing-kbd-macro` (`src/macros.c:435`); `prefix-arg`, `last-command`, `defining-kbd-macro` are `DEFVAR_KBOARD` (`src/callint.c:863`, `src/keyboard.c:13781`, `src/macros.c:427`). The manual lists terminal-local variables as "`default-minibuffer-frame`, `defining-kbd-macro`, `last-kbd-macro`, and `system-key-alist`", which "can never be buffer-local" (`doc/lispref/frames.texi:353-360`).
- **[I]** A pending prefix *key* (e.g. `C-x` waiting for its second key) is held by `read_key_sequence`'s locals plus the kboard's `echo_string` and `kbd_queue`; prefix *arguments* are in `Vprefix_arg`. Both are effectively per terminal.

### 1.2 Per-frame

- **[F]** `struct frame` (`src/frame.h:187-244`, [src/frame.h#L183-L244](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/src/frame.h#L183-L244)): `root_window` (the window tree), `selected_window` ("Each frame has its own window hierarchy and one of the windows in it is selected within the frame… The selected window of the selected frame is Emacs's selected window"), `minibuffer_window` ("only the selected frame's minibuffer window can actually appear to exist"), `param_alist` (frame parameters), `buffer_list`/`buried_buffer_list` (per-frame buffer ordering for `other-buffer`), `buffer_predicate`, face cache, pixel/text size (`src/frame.h:590-598`), and `terminal` (`:648`) whose `kboard` is `src/termhooks.h:530`.
- **[F]** Tab-bar tabs are a frame parameter: `tab-bar-tabs` reads `(frame-parameter frame 'tabs)` (`lisp/tab-bar.el:847-852`).
- **[F]** "Each X display has its own selected frame and its own minibuffer windows; however, only one of those frames is *the* selected frame at any given moment" (`doc/lispref/frames.texi:367-370`). The global `selected_frame` is a single variable (`src/frame.c:58`).

### 1.3 Per-window

- **[F]** `struct window` (`src/window.h`): `contents` (buffer, :143), `prev_buffers`/`next_buffers` (:147-149, window history, `doc/lispref/windows.texi:4929-4939`), `start` (:160), `pointm` and `old_pointm` (:166-171), `display_table` (:201), `dedicated` (:206), `hscroll`/`min_hscroll` (:268-272), `start_at_line_beg`, `force_start` (:408-412), `suspend_auto_hscroll` (:462), `vscroll` (:470).
- **[F]** "Each window has its own value of point… independent of the value of point in other windows displaying the same buffer"; selecting a window copies its point into the buffer, deselecting copies it back; "when one and the same buffer is simultaneously displayed in more than one window, its buffer point may change in unpredictable ways to the position of window point of any of these windows as a side-effect of things like redisplay, calling `with-selected-window`…" (`doc/lispref/windows.texi:5897-5929`, [doc/lispref/windows.texi#L5897-L5929](https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/doc/lispref/windows.texi#L5897-L5929)).

### 1.4 Per-buffer and global

- **[F]** Per buffer: buffer point `pt`, narrowing `begv`, `mark`, `mark_active`, `undo_list`, buffer-local variables (`src/buffer.h:357, 362, 461, 497, 611, 617, 745`). So **the mark and region activity are per buffer, not per window** — two windows on one buffer share one mark.
- **[F]** Global: `kill-ring` (`lisp/simple.el:5666`), buffer list, `this-command`, `current-prefix-arg`, `minibuf_level` (minibuffer recursion depth, `src/minibuf.c:56`), selected frame, current buffer.

### 1.5 emacsclient attach

- **[F]** `emacsclient -c` creates "a new graphical client frame"; `-t` "a new client frame on the current text terminal" (`doc/emacs/misc.texi:2150-2157, 2267-2274`); without a file, the new frame shows `*scratch*`/`initial-buffer-choice` (:2165-2168). `server-create-tty-frame` creates the frame with the client's tty, `TERM`, `LANG`, `COLUMNS`, etc. and tags it with the `client` frame parameter (`lisp/server.el:910-939`, `:994` makes `client` inherited by child frames). A new tty is a new terminal, hence a new kboard.
- **[I]** Buffers, kill ring, settings, histories and processes are shared across all clients; frames, their window trees, selected windows and tab bars are per client frame; input state is per terminal.

### 1.6 Two terminals typing at once; known pain

- **[F]** Two input states: *any-kboard* (complete commands from any terminal run as they arrive) and *single-kboard* (while a command runs for one terminal, others' events are queued in their `kbd_queue`) (`src/keyboard.h:54-79`). Entering a recursive edit or the minibuffer calls `temporarily_switch_to_single_kboard` (`src/keyboard.c:829-830`, `src/minibuf.c:721-722`, `src/callint.c:247-248`); it errors with "Terminal %d is locked, cannot read from it" if another terminal already holds the lock (`src/keyboard.c:918-948`).
- **[F]** Typing in a locked frame looked like a hang (bug#79892); since 2026 Emacs shows "Frame is locked; see `multiple-terminals-merge-keyboards`" (`src/keyboard.c:2365-2380`). The new Emacs 31 option `multiple-terminals-merge-keyboards` (default nil) stops entering single-kboard mode for recursive edits (`src/keyboard.c:14467-14474`, `etc/NEWS.31:845-849`). Design rationale: one person with several `ssh -X emacsclient -c` frames wants merged keyboards; "Someone doing the poor-man's-Etherpad thing would want this turned off" ([bug#79892, Sean Whitton, 2026-02-21](https://lists.libreplanet.org/archive/html/bug-gnu-emacs/2026-02/msg01352.html)).
- **[F]** bug#81894 (2026-09): an idle new `emacsclient -nw` steals the minibuffer: `server--create-frame` selects the new frame, `choose_minibuf_frame` uses the global selected frame, and the original terminal then gets "Frame is locked". Eli Zaretskii: "Emacs quite correctly selects a new client frame… What would you expect to happen instead, given that Emacs can only accept input from a single client frame?" ([thread](https://lists.defectivebydesign.org/archive/html/bug-gnu-emacs/2026-09/msg01227.html)).
- **[F]** `minibuffer-follows-selected-frame` (default t): an active minibuffer moves to the frame you switch to; the command's effect "always takes place in the frame where you first opened it" (`doc/emacs/mini.texi:70-85`).
- **[I]** Root causes: global selected frame/window, global `this-command`, and one minibuffer recursion stack, all on a single-threaded command loop. Per-terminal state was bolted onto a single-user design.

## 2. Prior art

| System | Shared | Per client | Complaints / lessons |
|---|---|---|---|
| **tmux, clients on one session** | Session, its windows and panes, the session's **current window** and each window's active pane and layout [I]; a window has one size | Client's terminal size, key table and prefix state (`client_key_table`, `client_prefix` formats), read-only/ignore-size flags, last session [F, tmux(1)] | Window size: `window-size` = `largest`/`smallest`/`manual`/`latest`; since 3.1 default `latest` = "size of the client that had the most recent activity" [F, CHANGES 3.1]; earlier default was smallest (small client shrinks everyone). Windows larger than a client show only part, following the cursor, "not as efficient" [F, CHANGES 2.9]. `aggressive-resize` sizes by sessions for which it is *current* [F]. `-r` = read-only + ignore-size so a watcher does not shrink others [F]. |
| **tmux session groups** (`new-session -t`) | Same set of windows | "The current and previous window and any session options remain independent" [F, tmux(1)] | The standard workaround for "two monitors, different windows" — i.e. the independent model is opt-in. |
| **GNU screen `-x`** | Windows | Each display has its own region layout/current window [I, `displays` list, multiuser ACLs] | `fit` exists because "screen doesn't adapt the window size automatically if the window is displayed more than once" [F, screen manual §9.7]. |
| **Neovim, several UIs** | Everything: one editor, one current window and cursor; "Nvim sends RPC notifications to all attached UIs" — the same redraw batches [F, api-ui-events] | Only the UI's requested size and capabilities | Grid size = **minimum width and height over all UIs** (`ui_refresh`, `src/nvim/ui.c:194-203` at `d714648`); capabilities = intersection unless `override` [F]. `'background'` with several UIs: "last wins" [F, options doc]. `ext_multigrid` gives per-window grids, but the window set is still shared [F/I]. |
| **VS Code Live Share** | Files and edits | Each participant's cursor, selections, open files and scroll; "follow" syncs to a person's "currently open file and scroll position", is "linked to an editor group", and stops automatically when you open or close a file [F, MS Learn] | Follow mode is opt-in per editor group; independence is the default. |
| **Zed collaboration** | Project, buffers | Per-participant cursor colour; following "is confined to a particular pane" and stops "whenever you move the cursor or edit" [F, zed.dev/features] | Same shape as Live Share. |
| **JupyterLab, one notebook in two tabs** (no RTC) | File on disk, kernel | Whole document model per tab | "… has changed on disk since the last time it was opened or saved. Do you want to overwrite…" ([#11352](https://github.com/jupyterlab/jupyterlab/issues/11352)); server does not know which frontends opened a file ([#19080](https://github.com/jupyterlab/jupyterlab/issues/19080)). RTC (Yjs) shares the document model [F, JupyterLab 3.6 docs]. Lesson: per-tab *document* state is the failure mode. |
| **Google Docs** | Document | Cursor, selection, scroll per user | [R, background knowledge, not verified here.] |

## 3. Synthesis for Tuna

### 3.1 Must be per tab (any model) [R, grounded in §1.1 and §2]

1. **Client identity and input sequence numbering.** ADR 7 numbers input from page load and "One tab is assumed"; two tabs would collide. Needs a per-tab id (e.g. in `sessionStorage`, which is per tab, unlike cookies) and per-tab expected-number/holding queue.
2. **Pending key sequence, prefix argument, transient/overriding-terminal map, keystroke echo, `last-command`/`real-last-command`/`last-repeatable-command`, `last-prefix-arg`, keyboard macro being defined and last macro.** Exactly Emacs's kboard (§1.1). Without this, `C-x` in tab A plus `b` in tab B runs `switch-to-buffer` (also noted in capability-audit lane 1, row 80). `this-command` and `current-prefix-arg` are dynamic for the duration of one command and can stay loop-scoped.
3. **Measured layout facts.** Viewport size and everything ADR 15 measures (top item and offset, last item in view, average item height, drawn-run sizes). A phone and a desktop showing the same view produce different measurements; storing one copy on the shared view means the last reporter wins and the other tab's placements fight (tmux/Neovim size problem in a new form).
4. **Transport bookkeeping:** the SSE stream, the last screen sent, `/applied` acknowledgement, placement numbers, HTML-reuse caches keyed by a tab's view state.
5. **Which frame the tab draws**, even in the mirror model (a reference, possibly shared).

### 3.2 Product choice: mirror vs independent [R]

| State | Mirror (tmux one session, Neovim) | Independent (emacsclient, tmux groups) |
|---|---|---|
| Frame (target, frame marks?) | One shared frame | One frame per tab; frame marks probably stay shared (they name parts, ADR 13) |
| Selected view | Shared | Per frame |
| Container focus memory | Shared in the layout (ADR 13) | ADR 13 already flags this: frames may disagree; either keep it shared (last writer wins) or move it into the frame |
| Layout tree | Shared | Shared tree, per-frame targets (Tuna's frame-as-pointer makes this cheap: two tabs can zoom into different subtrees of one tree) — or per-tab layout trees (Emacs) |
| View point / scroll | Shared views, so shared point; scroll *positions* still need per-tab measurement | Views under different frames are different views with their own points; same view visible in two tabs → as mirror |
| Active minibuffer prompt | Shared; any tab can answer | Belongs to the tab that started it; "nearest minibuffer" walks from *that tab's* selected view |
| Echo-area message | Shared | Command-result messages to the originating tab; global notices to all |

Trade-offs: mirror is simplest and matches "the vast majority is shared", but a small tab forces size decisions (Neovim min, tmux latest) and two people/devices fight over the selected view. Independent frames match emacsclient and Tuna's frame-as-pointer, but every "selected view/current frame" accessor must become "of the originating client", and prompts need an owner — exactly where Emacs breaks (§1.6). Because Tuna browsers lay out themselves (ADR 7), the size problem is milder than in tmux/Neovim: there is no shared grid, only per-tab scroll measurements.

**[R] Hybrid worth considering:** independent frames by default, with a "follow tab X" mode (Live Share/Zed) that shares a frame until the follower acts.

### 3.3 Must stay shared [R]

Buffers, nodes, texts, undo, mark (Emacs: per buffer) and point (per view), narrowing, the layout tree, kill ring, settings, keymaps, plugins, hooks, histories, jobs and processes, session persistence. Tuna's "the server processes everything" rule (STATUS) makes per-tab *document* state a non-goal; Jupyter shows why.

### 3.4 Concurrency rule (lesson from Emacs) [R]

Emacs's single-kboard lock exists because a prompt reads input synchronously from one stream. Tuna should tag every command with its originating client and run it with that client's input state and frame bound; a prompt should be owned by the client that asked, with other tabs continuing to work (or explicitly allowed to answer, a product choice, cf. `multiple-terminals-merge-keyboards`). Never select a new tab's frame on connect "globally" (bug#81894).

## Contradictions

- Emacs maintainers disagree whether a new client stealing the selected frame is a bug (Eli Zaretskii: correct behaviour; reporter: wrong frame) — bug#81894.
- Single-kboard default: kept conservative (nil) for Emacs 31 although Whitton judged multi-display single-user use more common (bug#79892).
- tmux changed its own default from smallest to latest (3.1), showing no size policy pleases everyone.

## Missing evidence

- GNU screen per-display current window and Google Docs per-user scroll: not verified from primary sources.
- tmux "current window shared by all clients of one session" is inferred from the session-group text, not quoted directly.
- Neovim per-UI input state: not checked (input from all UIs is assumed to merge into one stream).
- No measurement of how often Emacs users hit single-kboard locks.
- Tuna's existing code was not inspected for where input numbering and scroll facts are stored; only ADR 7, 13, 15 and STATUS were read.

## Sources

- Kept: Emacs checkout `541f693c` — `src/keyboard.h`, `src/keyboard.c`, `src/frame.h`, `src/window.h`, `src/buffer.h`, `src/minibuf.c`, `src/callint.c`, `src/macros.c`, `lisp/server.el`, `lisp/tab-bar.el`, `doc/lispref/frames.texi`, `doc/lispref/windows.texi`, `doc/emacs/misc.texi`, `doc/emacs/mini.texi`, `etc/NEWS.31` (primary).
- Kept: bug#79892 design mail (https://lists.libreplanet.org/archive/html/bug-gnu-emacs/2026-02/msg01352.html); bug#81894 (https://lists.defectivebydesign.org/archive/html/bug-gnu-emacs/2026-09/msg01227.html) — current pain points.
- Kept: tmux(1) (https://man7.org/linux/man-pages/man1/tmux.1.html) and tmux CHANGES (https://raw.githubusercontent.com/tmux/tmux/master/CHANGES) — size policies, groups, per-client flags.
- Kept: Neovim UI protocol (https://neovim.io/doc/user/api-ui-events/) and `src/nvim/ui.c` at `d714648b8e7c` — min-size rule, broadcast redraw.
- Kept: GNU screen manual (https://www.gnu.org/software/screen/manual/screen.html) — `fit`, displays.
- Kept: Live Share co-edit/follow (https://learn.microsoft.com/en-us/visualstudio/liveshare/use/coedit-follow-focus-visual-studio-code); Zed features (https://zed.dev/features).
- Kept: JupyterLab issues #11352, #19080.
- Prior Tuna research consulted: `agents/research/capability-audit/01-command-loop-and-input.md` (rows 14, 16, 29, 80; Open question 1), `05-beyond-emacs-and-browser.md` (corner risk 6).
- Rejected: libtmux.org mirrors (duplicate of tmux(1)); Medium/blog tmux comparisons (SEO); Stack Exchange emacsclient blocking answer (generic single-thread point).

## Next steps

1. Inspect Tuna's web plugin and keys/input plugin to list where input numbering, prefix state and ADR 15 scroll facts live today, and which accessors assume one selected view.
2. Owner decision for a brief: mirror, independent frames, or independent-with-follow; and who may answer a prompt.
