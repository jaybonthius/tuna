# Research: terminals that survive Tuna restarting

Read-only research, 2026-10-26. Tuna checkout at `91a8be3b3c700b777f2b6a6b29068a93394fe2aa`.
Labels used below: **Fact** means a cited source states it. **Interpretation** means my reading of a cited source. **Inference** means my own reasoning, with no source stating it.

## How tmux persistence works, in plain language

A terminal program such as a shell talks to a *pseudo-terminal* (PTY), which is a pair of kernel devices. The program holds one end, the *slave*. Whoever draws the screen holds the other end, the *master*. The kernel keeps the shell alive only while somebody holds the master open. When the last holder of the master closes it, the kernel "hangs up" the terminal and sends the shell `SIGHUP`, which by default kills it.

tmux keeps your shells alive by making sure the master is never held by the window you look at. When you first run `tmux`, it starts a background *server* process that detaches itself from your login and holds every PTY master. The server also runs its own terminal emulator for every pane, so it always knows what each screen looks like. The `tmux` command you type is only a *client*: it connects to the server over a Unix socket, forwards your keys, and draws whatever the server tells it. If you close the window, the client dies, but the server and its PTYs keep running. When you reattach, the server redraws your screen from its own copy of the screen. It does not replay old output.

The weak point is the server itself. If the tmux server crashes or is killed, every shell dies with it.

For Tuna this means three things:
- Something other than the Tuna process must hold each PTY master.
- Something must hold enough state to redraw the screen.
- That holder must be small and stable, because when it dies, its terminals die.

## Summary

*Revised after the parent's scrollback constraint (section 7). In short: keep a second emulator inside Tuna and read every row from it locally. The holder keeps its own emulator for the PTY and for restoring the screen.*


**Recommendation:** build design (a): a small, separate **holder program, one process per terminal**. It is started by the terminal plugin, detaches with `setsid`, holds the PTY master, and runs its own libghostty-vt emulator. Tuna connects to it over a private Unix socket. On attach, the holder sends a libghostty snapshot, then the live byte stream. Tuna builds its own mirror emulator from that snapshot and reads every scrollback row locally (design "a-dual", section 7).

The terminal plugin keeps only a socket connection and records the holder's identity in its session slot. This gives you three things:
- A plugin hot-swap closes the connection, not the PTY, so swaps and Tuna restarts take the same path.
- A Tuna crash or upgrade loses nothing.
- For reboots, the holder writes a snapshot to disk from time to time, and Tuna can "revive" the terminal: it shows the old screen read-only and starts a new shell in the saved directory.

tmux control mode (b) works and is proven, but it runs a second emulator (tmux's) in front of libghostty and filters out modern terminal features. The Emacs-style design (c) cannot meet the owner's requirement.

## Findings

### 1. Mechanism: why a separate process must hold the master

1. **Claim:** The PTY master's holder drives the process on the slave. Anything written to the master reaches the slave as typed input. **Sources:** [pty(7)](https://man7.org/linux/man-pages/man7/pty.7.html). **Support:** direct evidence. **Confidence:** high.
2. **Claim:** A session leader (the process that called `setsid`, normally the shell) acquires the terminal as its *controlling terminal* when it opens it. A terminal controls at most one session. **Sources:** [credentials(7)](https://man7.org/linux/man-pages/man7/credentials.7.html). **Support:** direct evidence. **Confidence:** high.
3. **Claim:** On Linux, closing the master hangs up the slave. `pty_close` on the master calls `tty_vhangup(tty->link)`. The hangup path (`tty_signal_session_leader`) sends `SIGHUP` and `SIGCONT` to the session leader and, on a hangup, `SIGHUP` to the foreground process group. **Sources:** Linux v6.12 [drivers/tty/pty.c](https://github.com/torvalds/linux/blob/v6.12/drivers/tty/pty.c) (`pty_close`) and [drivers/tty/tty_jobctrl.c](https://github.com/torvalds/linux/blob/v6.12/drivers/tty/tty_jobctrl.c). **Support:** direct evidence from the source. **Confidence:** high.
4. **Claim:** POSIX specifies this behaviour:
   - A modem disconnect sends `SIGHUP` to the controlling process, and later reads return end-of-file.
   - When a controlling process exits, `SIGHUP` goes to the foreground process group and the terminal is dissociated from the session.
   - A newly orphaned process group that contains stopped processes gets `SIGHUP` and then `SIGCONT`.

   **Sources:** [POSIX.1-2024 §11.1.10 Modem Disconnect and §11.1.3](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap11.html); [POSIX `_exit`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/_exit.html). **Support:** direct evidence. **Confidence:** high.
5. **Claim:** The kernel acts when the *last* reference to the master's open file description closes, not when any one process closes it. A descriptor passed to another process with `SCM_RIGHTS` passes a reference to the same open file description. A PTY can therefore be handed from an old server to a new one without a hangup. **Sources:** [unix(7) SCM_RIGHTS](https://man7.org/linux/man-pages/man7/unix.7.html). herdr does this during upgrades: its `src/server/handoff.rs` (herdr `2713feb5`) sends PTY descriptors in batches of 64 over `SCM_RIGHTS`. **Support:** direct evidence (man page and code). The "last reference" reading is interpretation of VFS release semantics. **Confidence:** high.
6. **Inference:** The conclusion follows from findings 1 to 5. If Tuna holds the master and Tuna exits, crashes or `exec`s without passing the descriptor on, every shell gets `SIGHUP`. Shells that ignore `SIGHUP` survive but lose their terminal: they can no longer be read from or written to. A long-lived holder must therefore own the master and call `setsid`, so it is not itself in Tuna's session or process group. The holder must also not be in Tuna's systemd control group: the default `KillMode=control-group` kills every process left in a unit's group when the unit stops ([systemd.kill](https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html)), and logind's `KillUserProcesses=yes` "will break tools like screen and tmux, unless they are moved out of the session scope" ([logind.conf](https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html)).

### 2. How existing tools do it

| Tool | Who holds the PTY | Screen restored on reattach from | Survives its own server restart? |
|---|---|---|---|
| tmux | One server daemon for all panes | The server's live per-pane emulator | No |
| GNU screen | One `SCREEN` process per session | Its built-in VT100 emulator | No |
| dtach / abduco | One holder per session | Nothing kept; sends ^L or `SIGWINCH` so the program redraws itself | Not applicable |
| shpool | One daemon | Built-in emulator (`shpool_vt100`, with an experimental replacement, `shpool-vterm`) | No |
| herdr | One server, which embeds libghostty-vt | The live emulator | Yes, through experimental `--handoff` (passes descriptors with `SCM_RIGHTS`) |
| VS Code | One pty-host child process | A headless xterm.js copy, serialized | Window reload: yes. Full app restart: no; it relaunches ("revive") |
| iTerm2 | One long-lived server per session | macOS window restoration | Crash or upgrade: yes. Reboot: no |
| WezTerm | `wezterm-mux-server` over a Unix socket | The mux server's model | No |
| zellij | One server per session | Live server state; otherwise resurrection from a layout file | No; resurrection reruns the commands |
| kitty | The GUI process | — | No (on the "someday" list) |
| Ghostty | The GUI process | macOS restores only the window structure | No |

Details and sources:

- **tmux.**
  - **Fact:** the server forks and calls `daemon()` (`proc_fork_and_daemon` in `proc.c`). Each `window_pane` holds the PTY `fd` created by `fdforkpty`, an input parser (`ictx`) and a `struct screen base`.
  - **Fact:** the socket lives in `$TMUX_TMPDIR/tmux-UID/`, which is created with mode 700. tmux refuses the directory if its owner is not the user or if any "other" permission bits are set (`TMUX_SOCK_PERM`). A server-side access-control list checks the peer's user id (`server-acl.c`).
  - **Fact:** control mode (`-C`, or `-CC` to disable echo) is a text protocol. Commands go in. Output comes back in `%begin`/`%end` blocks. Pane output arrives as `%output %pane value` with octal escapes. Flow control uses `pause-after` together with `%pause`/`%continue`. `refresh-client -C` sets the client size. `capture-pane -p -e -S -` returns the history with SGR attributes; `-P` returns any unfinished escape sequence.
  - All of the above is from tmux `f7ef88a1004684f763325ce00bf41657e9c251dd`: `tmux.c`, `tmux.h`, `spawn.c`, `proc.c`, and `tmux.1`, sections CONTROL MODE and `capture-pane`. **Confidence:** high.
- **GNU screen.**
  - **Fact:** "Each window in a screen session emulates a VT100 terminal … hard-coded". `autodetach` is on by default and keeps programs running after a hangup. Layouts are lost "if the screen process dies".
  - **Fact:** `$SCREENDIR` must be a directory with mode 700.
  - **Source:** [GNU screen manual](https://www.gnu.org/software/screen/manual/screen.html) §§8, 9.9, 11, 26.1. **Confidence:** high.
- **dtach.**
  - **Fact:** "dtach does not have a terminal emulation layer, and passes the raw output stream". On attach it redraws with ^L (the default), `SIGWINCH`, or nothing.
  - **Source:** [dtach README](https://github.com/crigler/dtach/blob/master/README). **Confidence:** high.
- **abduco.**
  - **Fact:** no screen state is kept. Sockets live in `$HOME/.abduco` or `/tmp/abduco/$USER`, owner-only. `SIGUSR1` recreates a deleted socket. If the binary has been deleted, `/proc/$PID/exe` still reattaches.
  - **Source:** [abduco README](https://github.com/martanne/abduco). **Confidence:** high.
- **shpool.**
  - **Fact:** the default `session_restore_mode = "screen"` replays a screenful from an in-daemon emulator (`shpool_vt100`) and adds the `SIGWINCH` trick. `{ lines = n }` replays n lines. `"simple"` sends only `SIGWINCH`.
  - **Fact:** the restore buffer appends the tracked input modes after the contents. The source comment explains why: otherwise "a paste into a reattached session arrives unbracketed".
  - **Fact:** the emulator is sized at width 1024 because the vt100 crate "eagerly fills in its rows". An experimental `shpool-vterm` replacement exists because of memory use and bugs.
  - **Fact:** connections from another user id are refused through `SO_PEERCRED`.
  - **Sources:** shpool `c3e0a472e73d3cc9a4a74665c2d1ec7ac5a5510b`: `CONFIG.md`, `libshpool/src/session_restore.rs`, `libshpool/src/daemon/peer.rs`; and [shpool-vterm](https://github.com/shell-pool/shpool-vterm). **Confidence:** high.
- **herdr** (the owner's mention): [herdr.dev](https://herdr.dev/docs/session-state/), a Rust "runtime your coding agents live on", in the same family as tmux.
  - **Fact:** a background server keeps panes running. The server embeds a vendored **libghostty-vt** (`vendor/libghostty-vt.vendor.json`, source commit `44f2a44d`).
  - **Fact:** after a server restart, processes are gone. Layout and working directories come back. Screen history comes back only with the opt-in `pane_history`, which is off by default because output can contain secrets. Supported agent tools resume through their own resume commands, for example `claude --resume`.
  - **Fact:** `herdr update --handoff` (experimental) transfers live PTY descriptors to the new server with `SCM_RIGHTS`. Each pane carries up to `MAX_REPLAY_BYTES_PER_PANE = 8 KiB` of replay bytes, plus `initial_history_ansi`, keyboard-protocol flags and the title.
  - On a systemd-logind shutdown warning, herdr requests a short delay to save.
  - **Sources:** herdr `2713feb56e9c9db33992db0a262c68f7426d46dd`: `src/server/handoff.rs`, `src/handoff_runtime.rs`; and the docs pages above. **Confidence:** high. herdr is the closest existing precedent for "libghostty-vt in a long-lived holder, plus handoff on upgrade".
- **Rune** ([unstablebuild/rune](https://github.com/unstablebuild/rune) `604b5478`): a Go IDE and terminal multiplexer with its own emulator (`internal/term/vte`).
  - **Fact:** its docs describe headless network nodes, reconnection after network drops, and recreating warm shells. I found **no** documented mechanism that keeps terminals alive across a restart of the Rune process. Upgrades "ask you to restart Rune".
  - **Support:** direct evidence for what the docs say; absence of a feature is weaker evidence. **Confidence:** medium. It does not appear to do what Tuna wants.
- **VS Code.**
  - **Fact:** it has two features. *Reconnection*: after a window reload, the window reconnects to the same process and restores its content. *Revive*: after a restart, the content is restored and the process is relaunched with its original environment. The relevant settings are `enablePersistentSessions`, `persistentSessionScrollback` and `persistentSessionReviveProcess` ([docs](https://code.visualstudio.com/docs/terminal/advanced)).
  - **Fact:** the pty host keeps a headless xterm.js (`@xterm/headless`) per terminal and serializes it with `@xterm/addon-serialize` to replay on reconnect. The grace times are `GraceTime = 60000` ms and `ShortGraceTime = 6000` ms. Saved state is versioned (`version: 1`).
  - **Source:** vscode `ed3d9c11647cf2d6c7b0e4f327fd1c7c5f0afc6e`: `src/vs/platform/terminal/node/ptyService.ts` and `common/terminal.ts`. **Confidence:** high.
  - **Interpretation:** the pty host is a child of VS Code, so the analogue for Tuna is surviving a plugin swap, not surviving a Tuna restart.
- **iTerm2.**
  - **Fact:** "Session restoration works by running your jobs within long-lived servers rather than as child processes of iTerm2. If iTerm2 crashes or upgrades, the servers keep going." Screen content comes back from the operating system's window restoration. A reboot kills the jobs but restores the window contents, with a *Session Restored* banner.
  - **Source:** [iTerm2 docs](https://iterm2.com/documentation-restoration.html). **Confidence:** high. This is the closest model for design (a).
- **WezTerm.**
  - **Fact:** "unix domains" connect the GUI to a `wezterm-mux-server` over a Unix socket and spawn the server if needed. The docs mention a socket permission check (`skip_permissions_check`).
  - **Source:** [WezTerm multiplexing](https://wezterm.org/multiplexing.html). **Confidence:** high.
- **zellij.**
  - **Fact:** every second, zellij serializes the session layout and pane commands to the cache directory as a human-readable KDL layout. Viewport and scrollback are saved only if you opt in. Resurrected commands wait behind a "Press ENTER to run..." banner.
  - **Source:** [zellij session resurrection](https://zellij.dev/documentation/session-resurrection.html). **Confidence:** high.
- **kitty.**
  - **Fact:** the FAQ says kitty does "all of what tmux does … with the exception of remote persistence". A persistence daemon is "someday" ([issue #8783](https://github.com/kovidgoyal/kitty/issues/8783)).
  - **Source:** [kitty FAQ](https://sw.kovidgoyal.net/kitty/faq/). **Confidence:** high.
- **Ghostty.**
  - **Fact:** `window-save-state` restores the window structure, on macOS only. A maintainer says Ghostty "does not save or restore the contents of terminals" ([discussion #12912](https://github.com/ghostty-org/ghostty/discussions/12912)).
  - **Fact:** Mitchell Hashimoto's new company, Superlogical, "will begin by shipping a terminal multiplexer" built on libghostty ([post](https://mitchellh.com/writing/superlogical)).
  - **Fact:** a community prototype, `ghostty-snap`, puts libghostty plus a PTY in a server and syncs state ([discussion #12176](https://github.com/ghostty-org/ghostty/discussions/12176)). It is AI-generated and was not merged.
  - **Confidence:** high. The announcement is a stated plan, not a shipped product.

### 3. Restoring the screen after reattach

1. **Live emulator in the holder** (tmux, screen, shpool, herdr, VS Code). On attach, the holder sends the screen it already has.
   - Exact for the alternate screen, cursor, modes and scrollback.
   - Costs memory and CPU in the holder even while nobody is watching. shpool's memory trouble with vt100 is the evidence.
   - Crash safety: the emulator dies only with the holder, and the PTY dies then anyway. So it adds no new failure mode, provided the emulator does not crash the holder. **Inference.**
2. **Bounded byte log replay.** Simple and needs no emulator.
   - Wrong once the log is cut. Anything that happened before the cut is lost: entering the alternate screen, scroll regions, character sets, mouse and paste modes. That is why dtach falls back to ^L or `SIGWINCH`, and why shpool replays the input modes explicitly. **Interpretation.**
   - herdr uses 8 KiB only as a supplement to a live emulator.
3. **Serialized snapshot.** A live emulator writes its state as bytes, either on demand or periodically to disk.
   - It is the only one of the three that also survives a reboot.
   - **Fact:** upstream libghostty-vt has a snapshot API (`include/ghostty/vt/snapshot.h`, first commit `d7bb4b8`, 2026-08-03). It is a CRC-protected record stream, and its READY marker lets a reader render before history arrives.
   - **Fact:** version 1 is "the work-in-progress format that we intended to continue to break until we can promise binary compatibility". The file is "NOT a full transport-ready format" for multiplexers. Kitty image and placement registries "remain intentionally omitted".
   - Source: Ghostty `befcdfd2c3a1cb24d9ec886e93c95b2b5daa7028`, `src/terminal/snapshot/main.zig` and the git log.
   - The owner's binding (`gerbil-libghostty/ghostty.md`, "Persistent snapshots") exposes `terminal->snapshot-bytes`, `snapshot-bytes->terminal`, port streaming, and an incremental decoder (`snapshot-decoder-ready!`/`-next!`). Restored terminals start without a selection or tracked references. The binding is pinned to the same Ghostty commit.
   - **Confidence:** high.
   - **Inference:** treat snapshots as safe only between processes built against the same Ghostty commit. Snapshots on disk may become unreadable after Tuna upgrades libghostty. Keep a plain styled-text (ANSI) fallback next to each one, as herdr (`initial_history_ansi`) and VS Code (serialized xterm text) do.

**Recommended combination (inference):**
- **Attach:** a live emulator in the holder.
- **Plugin swap or Tuna restart:** the holder sends a snapshot on attach, then streams raw bytes. Tuna's own emulator for rendering is rebuilt from that snapshot.
- **Reboot:** a periodic snapshot on disk, plus the ANSI fallback.

### 4. Reboot

- No tool keeps processes across a reboot. They restore *context*:
  - herdr: layout, working directory, opt-in screen history, and resume commands for agent tools.
  - zellij: layout and commands behind a confirmation banner, with screen contents opt-in.
  - tmux-resurrect: sessions, layout, working directories and a conservative list of programs (`vi vim nvim emacs man less more tail top htop …`), with pane contents optional ([README](https://github.com/tmux-plugins/tmux-resurrect)).
  - VS Code revive: restored content, then a relaunch.
  - iTerm2: window contents, with a *Session Restored* banner.

  **Confidence:** high.
- **Inference for Tuna:**
  - The terminal plugin's session slot stores: the command, the working directory (from OSC 7 if the shell reports it, otherwise `/proc/PID/cwd`), the environment it asked for, the size, and the path of the last snapshot.
  - On restart with no live holder, show the snapshot read-only with a "restored" banner, then start a fresh shell in that directory.
  - Never rerun a non-shell command automatically (zellij's reason: `rm -rf`).
  - Screen history can hold secrets. Make saving it a setting, write it with mode 0600 under `$XDG_STATE_HOME/tuna/`, and decide its default deliberately (herdr defaults it off).

### 5. Security

- **Fact:** `$XDG_RUNTIME_DIR` "MUST be owned by the user … Its Unix access mode MUST be 0700". It is removed when the user fully logs out ([XDG Base Directory spec](https://specifications.freedesktop.org/basedir-spec/latest/)).
- **Fact:** Linux requires write permission on a stream socket file to connect, but "Portable programs should not rely on this". Abstract-namespace sockets ignore permissions entirely ([unix(7)](https://man7.org/linux/man-pages/man7/unix.7.html)). `SO_PEERCRED` returns the peer's pid, uid and gid as of `connect`.
- **Practice:**
  - tmux: a 700 directory with owner and mode checks, plus a uid access-control list.
  - shpool: rejects other uids through `SO_PEERCRED`.
  - screen and abduco: 700 directories.
  - Tuna already does this for `tuna reload`: `tuna/control.ss` uses `$XDG_RUNTIME_DIR/tuna`, requires owner plus mode 700, and sets 600 on sockets.
- **Inference:**
  - Reuse that convention: put holder sockets under `$XDG_RUNTIME_DIR/tuna/terminals/`, require the directory checks, check `SO_PEERCRED` uid on every connection, and never use abstract sockets.
  - Because the runtime directory disappears at final logout, a holder that outlives logout (with lingering enabled) needs a way to recreate its socket, as abduco does with `SIGUSR1`. Otherwise it is acceptable for the holder to exit at logout.
  - Anyone who can reach the socket can type into a shell, so the socket is as sensitive as a shell login.

### 6. Candidate designs for Tuna

Tuna context (fact, from the repository):
- ADR 2: a swap is restart plus restore. Deactivation runs the receipt's inverses, including subprocesses. In-memory state survives only through session slots.
- ADR 5: slots are plain data written with `write`.

Inference: a PTY descriptor cannot live in a slot, and a PTY owned by the plugin's receipt dies on swap. Hot-swap and restart therefore need the same thing: the PTY must live outside the plugin.

**(a) Holder program (recommended).** A small executable built from the Tuna package. Each instance:
- creates the PTY, forks the shell, and calls `setsid`;
- feeds output through its own libghostty-vt `terminal`;
- serves one Unix socket with a tiny versioned protocol: attach (reply: snapshot, then a stream), input, resize, signal, kill, and status;
- writes a snapshot plus ANSI fallback to disk on idle or on a timer.

The terminal plugin starts holders, keeps socket connections, stores `{holder-id, socket path, cwd, command}` in its slot, and reconnects after a swap or restart. A receipt closes connections and never kills holders. Only an explicit "kill terminal" command, or the shell exiting, ends a holder.
- **(a1) One holder per terminal** (iTerm2, dtach, abduco):
  - One crash loses one terminal.
  - Upgrades are easy: old holders keep running their old binary, and new terminals use the new one. The protocol and snapshot versions must be checked in the handshake.
  - Cost: one process and one libghostty instance per terminal.
- **(a2) One shared daemon** (tmux, herdr, shpool, VS Code):
  - Fewer processes, one place to list sessions.
  - One crash kills everything.
  - Upgrading without losing shells needs herdr-style `SCM_RIGHTS` handoff plus a snapshot of each emulator, which adds a lot of complexity.
- **With or without the holder's emulator:** without it (dtach-style), reattach after a Tuna restart can only use a byte log or `SIGWINCH`, which breaks full-screen programs and modes (finding 3.2). Keep the emulator.
- **Risks (inference):**
  - Holders must run outside Tuna's systemd cgroup if Tuna runs as a user service.
  - Tests must kill holders by exact process id, as the repository's `AGENTS.md` requires.
  - Gambit's built-in `open-process` with a pseudo-terminal returns a port, not a raw master descriptor. The holder may need a small FFI for `posix_openpt`/`forkpty`. Verify with the `gerbil-reference` skill before planning.
  - The kernel stays unchanged: the holder is ordinary program code beside `tuna/control.ss`, and the terminal plugin owns the client side.

**(b) tmux as the backend through control mode.** Tuna runs `tmux -CC`, feeds `%output` bytes into libghostty, uses `capture-pane -p -e -P -S -` to repaint after reattach, and sizes with `refresh-client -C`. iTerm2's tmux integration is the well-known precedent.
- **Gains:** a mature server that is already persistent, plus tmux-resurrect for reboots.
- **Costs** (interpretation from tmux.1 and the kitty FAQ):
  - Two emulators, with tmux's in front. Features tmux does not pass through are lost, including the kitty graphics protocol (kitty's FAQ says tmux refuses image support) and others "depending on the whims of tmux's maintainer".
  - `capture-pane` returns text with attributes, not full mode state.
  - Adds an external dependency and a second keymap and config surface to disable.
  - The tmux server is the single point of failure (inference).
- Good as a later optional backend for remote hosts. Not recommended as the primary design.

**(c) Emacs-style: Tuna holds the PTY.** The simplest design, matching `M-x term`/`vterm`. Terminals die on Tuna restart and on any swap of the terminal plugin or of a service it requires. VS Code-style revive (a snapshot in the slot, then relaunch in the saved directory) softens this but does not meet the owner's tmux-like requirement. It is useful only as a first, throwaway vertical slice.

### 7. Where scrollback rows are read from (added for the native-scroll constraint)

The constraint: Tuna scrolls terminals like other views. The browser scrolls natively, and Tuna reads, on demand, only the rows near what each browser tab shows, from anywhere in the scrollback. Several tabs may look at different parts of one terminal at once.

First, what libghostty-vt offers for reading rows (Ghostty `befcdfd2`, unless noted):
- **Fact:** a terminal has **one viewport**. Scrolling it is a terminal operation (`GHOSTTY_SCROLL_VIEWPORT_TOP/BOTTOM/DELTA/ROW`, `terminal.h`). A render state records the viewport rows, plus optional *overscan* rows above and below. Overscan is meant for smooth scrolling and was added in `2ea1eeae2`, 2026-09-25. A render state "doesn't store the scroll position" (`render.h`).
- **Fact:** grid references can address any cell in `screen` or `history` space (`point.h`). The owner's binding exposes these one cell at a time and calls that "not a render loop" (`ghostty.md`).
- **Fact:** the binding's `terminal-render-snapshot` copies the visible grid only. I found no binding call that scrolls the viewport or requests overscan in `ghostty.md` or `PARITY.md`.
- **Inference:** reading "rows N to N+k for this browser tab" therefore needs a new primitive, wherever the emulator lives. It would move the one viewport to row N, update a render state (with overscan), copy the rows, and move the viewport back, all under the terminal lock. Alternatively it would walk grid references row by row. Each browser tab, or a shared row cache, needs its own position. Row numbers also shift when old scrollback is pruned and when a resize rewraps lines, so a request should name rows by a stable reference (a tracked reference or a pruning counter), not a bare index.
- This primitive is the same work in every design below. What differs is where it runs.

**(a-remote) The holder emulates; Tuna reads rows over the socket.**
- Every scroll into rows Tuna has not cached is a round trip: request, holder lock, viewport move, copy, encode, send, decode.
- **Latency (inference, unmeasured):** a local Unix-socket hop is usually much smaller than the browser-to-Tuna network trip it adds to, but it is not free. Encoding styled rows, graphemes, hyperlinks and kitty-image placements costs time. Fast flick-scrolling through 100k lines turns into many requests, and the holder serves them on the same lock its PTY reader uses, so heavy output and scrolling compete.
- **Complexity (inference):** this is the highest of the three.
  - Tuna's view code becomes asynchronous for terminals only: request, wait, then render.
  - Tuna needs a row cache with invalidation driven by dirty-row, pruning and reflow events from the holder.
  - The holder grows a row-query protocol that is wider and changes more often than "bytes in, bytes out". That means more holder upgrades, and with design (a1) old holders keep running old protocols.
  - Search, selection and copy across the scrollback also go over the socket.
- **Advantage:** one emulator per terminal, so memory is counted once and the screen is restored exactly with nothing extra to do.

**(a-dual) The holder emulates *and* Tuna keeps a mirror emulator (recommended).**
- The holder feeds every byte to its own libghostty terminal. It answers VT queries (`GHOSTTY_TERMINAL_OPT_WRITE_PTY`) even while Tuna is down, and sends the same bytes on to Tuna.
- Tuna's mirror is built from the holder's snapshot on attach and fed the same stream. It does not write query responses back.
- All row reads, search and selection run locally, through the same FFI path as Tuna's other views. Scrolling never touches the socket.
- **Latency:** the same as any local view. Only typing and output cross the socket, as in any terminal.
- **Complexity (inference):**
  - The protocol must stamp resizes and resets into the byte stream with sequence numbers, so both emulators apply the same events in the same order.
  - Attach needs "snapshot at sequence S, then the stream after S".
  - Both sides must build against the same Ghostty commit, because the snapshot format is unstable (finding 3.3). The handshake must check this, falling back to the ANSI text copy.
  - The mirror can drift from the holder if an event is mis-ordered. A cheap fix is to re-snapshot on request, or after a mismatch in a periodic checksum such as a row hash.
- **Cost:** every byte is parsed twice, and the scrollback is kept twice, once in each process. libghostty's caller-driven scrollback compression (`terminal.h`, "Scrollback Compression") can shrink the holder's idle copy. Not measured.
- **Hot-swap fits ADR 5:** the mirror is in-memory plugin state, so on a swap the plugin need not encode anything. The new plugin version asks the holder for a fresh snapshot, which is always current. The slot keeps only the holder's identity.

**(a-log) A byte-only holder with a log; only Tuna emulates.**
- The holder keeps the PTY plus a byte log with sequence numbers, preferably on disk, since `$XDG_RUNTIME_DIR` "should not place larger files" (XDG spec). It has no libghostty at all, so it is the smallest and most stable holder.
- Tuna reads rows locally. It writes a snapshot checkpoint, tagged with a log sequence number, on a timer and before planned restarts or swaps.
- On reconnect, Tuna restores its last checkpoint and replays the log from that sequence number.
- **Latency:** local reads, like (a-dual). Restoring costs a decode plus a replay of everything written since the checkpoint.
- **Weaknesses (inference):**
  - After a crash, the checkpoint is up to one interval old, so the log must keep at least that much.
  - Output larger than the log while Tuna is down, such as a long build during an upgrade, is a gap. The only recovery is a `SIGWINCH` or ^L redraw, the dtach behaviour from finding 3.2.
  - Nobody answers the program's VT queries (device attributes, cursor position) while Tuna is down, and some programs stall without an answer.
  - The checkpoint is a full scrollback encode on a timer.
- It is the simplest holder, but the restored screen is not guaranteed correct.

**(b) tmux control mode, and (c) Emacs-style,** both read rows locally from Tuna's libghostty. In (b), the only restore source is tmux's `capture-pane` text with attributes, so modes are approximate. In (c) there is nothing to restore. Neither changes the conclusion.

**Weighing them (inference):**

| Design | Scroll reads | Exact restore after a Tuna crash | Holder size and protocol churn | Memory |
|---|---|---|---|---|
| a-remote | Over the socket, asynchronous, cached | Yes | Large, high churn | 1x |
| **a-dual** | **Local** | **Yes** | Medium (bytes, sequence numbers, snapshot) | 2x |
| a-log | Local | Only if the log covers the downtime | Tiny | 1x, plus the log |

The native-scroll constraint argues against (a-remote): it turns the most frequent interaction, scrolling, into a remote call, and spreads the row-reading API across a process boundary. (a-dual) keeps scrolling local and keeps the restore exact, at the cost of parsing twice and storing twice. That cost should be measured (next step 2). If it proves too high, (a-log) is the fallback, and it can serve as a first slice, because the holder protocol (bytes plus sequence numbers) is a subset of the (a-dual) protocol.

## Contradictions

- Ghostty says snapshots are "NOT a full transport-ready format … for multiplexers", yet herdr and the `ghostty-snap` prototype use libghostty state for exactly that purpose. The format is meant for state restoration, which is what Tuna needs. Its stability across Ghostty commits is explicitly not promised.
- kitty's maintainer calls multiplexers "a bad idea", while iTerm2, VS Code, WezTerm and herdr all build persistent holders. This is a disagreement of opinion, not of fact.

## Missing evidence

- Whether Gambit v4.9.x `open-process` with `pseudo-terminal: #t` exposes the master descriptor, sets the controlling terminal correctly, and works in a process that has called `setsid`. This was not checked.
- Herdr's in-server emulator was inferred from the vendored libghostty-vt and `crates/ghostty-vt`; its pane code was not traced.
- The memory and CPU cost of one libghostty-vt terminal with large scrollback in an idle holder was not measured.
- Rune: only the docs at `604b5478` were searched; the source was not audited for a persistence mechanism.
- The owner's spike at `~/Code/shux/spikes/libghostty-terminal/` (named in the roadmap) was not read.
- iTerm2's tmux integration was not fetched; it is cited from general knowledge only.

## Sources

- Kept:
  - Linux `drivers/tty/pty.c` and `tty_jobctrl.c` (v6.12): the master-close hangup path.
  - POSIX.1-2024 chapter 11 and `_exit`: SIGHUP semantics.
  - pty(7), credentials(7), unix(7): PTY, session, `SCM_RIGHTS` and `SO_PEERCRED` facts.
  - systemd.kill and logind.conf: cgroup killing, the trap for holders.
  - XDG Base Directory spec: runtime directory rules.
  - tmux source and man page `f7ef88a1`: server, pane emulator, control mode, socket checks.
  - shpool `c3e0a472`: restore modes, mode replay, peer credential check.
  - herdr docs and source `2713feb5`: libghostty holder and `SCM_RIGHTS` handoff.
  - VS Code `ed3d9c11`: pty host, headless xterm serialization.
  - iTerm2 restoration docs: per-session long-lived servers.
  - GNU screen manual, dtach and abduco READMEs, zellij, WezTerm and kitty docs, tmux-resurrect README.
  - Ghostty source `befcdfd2` (snapshot format, `window-save-state`), discussions #12912 and #12176, the Superlogical post.
  - gerbil-libghostty `README.md` and `ghostty.md`.
- Rejected or deprioritized:
  - The Register article on Superlogical: secondary to Mitchell's own post.
  - The context7 shpool mirror: redundant with the primary repository.
  - The `ghostty-snap` prototype code: AI-generated and unmerged; used only as a design signal.

## Next steps

0. Design the "read rows N to N+k in screen space" primitive (viewport move plus overscan, or row-wise grid references) and add it to gerbil-libghostty. Every design needs it, and the binding has no viewport-scroll or overscan call today.
1. Check Gambit PTY support (`open-process` `pseudo-terminal:`, or an FFI for `forkpty`) with the `gerbil-reference` skill, and test a `setsid` holder by hand.
2. Measure one idle libghostty-vt terminal with 10k lines of scrollback, its compressed size, snapshot encode and decode time, and parse throughput. These numbers decide between (a-dual) and (a-log).
3. Read `~/Code/shux/spikes/libghostty-terminal/` and herdr's pane and emulator code for reusable protocol ideas, then write the architecture brief that `AGENTS.md` requires before any ADR.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Brief opens with a plain-language explanation of tmux persistence and a recommendation (one holder process per terminal with a libghostty-vt emulator), answers questions 1-6 with commit-pinned primary sources, separates fact, interpretation and inference, and lists residual risks and missing evidence."
    }
  ],
  "changedFiles": [
    "/home/jay/.pi/agent/sessions/--home-jay-Code-workbench-gerbil-tuna--/subagent-artifacts/outputs/f2c54a7e-c38b-4b53-9b95-302395da10fe/task-2.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {"command": "git clone --depth 1 tmux, herdr, rune; shpool via fetch_content; grep sources", "result": "passed", "summary": "Commit-pinned source evidence gathered"},
    {"command": "grep gerbil-libghostty README/ghostty.md and .build/ghostty-source snapshot files and git log", "result": "passed", "summary": "Confirmed upstream snapshot API and that format v1 is WIP and unstable"},
    {"command": "curl vscode ptyService.ts/terminal.ts at main sha", "result": "passed", "summary": "Confirmed headless xterm plus serialize addon and grace times"}
  ],
  "validationOutput": [
    "No source_check run; key claims were verified by reading the original sources directly (man pages, kernel source, tool source)."
  ],
  "residualRisks": [
    "Gambit PTY and setsid support is unverified and may require FFI.",
    "libghostty snapshot format v1 is explicitly unstable, so on-disk snapshots may not survive library upgrades.",
    "Rune and herdr internals were only partly read; iTerm2 tmux integration is cited from general knowledge.",
    "The holder's resource cost was not measured.",
    "The doubled parse cost and memory of (a-dual) were not measured.",
    "gerbil-libghostty has no primitive for reading scrollback rows at any position (no viewport-scroll or overscan call)."
  ],
  "noStagedFiles": true,
  "diffSummary": "New research brief at the authoritative output path; no repository files changed.",
  "reviewFindings": ["no blockers"],
  "manualNotes": "The task named agents/research/terminal/02-persistent-terminals.md, but the run's authoritative output path overrode it, so only task-2.md was written. Copy it into the repository if wanted. Temporary clones were left in /tmp (tmuxsrc, herdr, rune, vsc)."
}
```
