# 18. Terminals live in helper processes; Tuna keeps a mirror

Status: accepted (2026-10-27, owner approved the brief [`docs/briefs/2026-10-terminal.md`](../../docs/briefs/2026-10-terminal.md)). Plan: [`agents/plans/terminal.md`](../plans/terminal.md). Evidence: [`agents/research/terminal/`](../research/terminal/), above all `02-persistent-terminals.md`.

## Context

The owner wants terminals that survive Tuna restarting, crashing, upgrading and swapping the terminal plugin, as tmux sessions survive their window closing. A shell dies when the last holder of its pseudo-terminal's master side closes it: the kernel hangs up the terminal and sends `SIGHUP` (Linux `pty_close` → `tty_vhangup`). Emacs holds the master itself, so its terminals die with it.

Tuna also scrolls terminals like every view (ADR 15): each browser tab reads the rows near what it shows, from anywhere in the scrollback, and redraws only changed rows (ADR 17).

Options considered (research 02, section 6):
- **(a) A helper process per terminal** that holds the master and its own emulator (iTerm2's long-lived servers; herdr, which embeds libghostty-vt).
- **(b) tmux control mode** as the backend: proven, but tmux's emulator sits in front of libghostty and filters newer sequences (kitty keyboard, OSC 7501, graphics).
- **(c) Tuna holds the master** (Emacs, vterm, ghostel): cannot meet the requirement.

## Decision

- **One helper process per terminal.** The terminal plugin starts it; it detaches (`setsid`, and outside Tuna's systemd scope when one exists, since `KillMode=control-group` would kill it), holds the pseudo-terminal master, starts the program, and runs its own libghostty-vt terminal fed with every output byte.
- **Private socket.** Tuna talks to it over a Unix socket in a per-user directory with mode 0700 (`$XDG_RUNTIME_DIR/tuna/terminals/`), checking the peer's user id. The protocol is versioned framed messages: input bytes, resize, focus, snapshot request, kill; output bytes, exit status. A helper accepts one Tuna at a time.
- **Tuna keeps a mirror.** On connect the helper sends a libghostty snapshot, then the live byte stream. Tuna restores the snapshot into its own libghostty-vt terminal and feeds it the same bytes, so every row read, redraw and scroll is local and never waits on the socket. Parsing runs on the editor thread (it is cheap, and Tuna's threads share one OS thread).
- **Restarts, crashes and plugin swaps take one path:** the connection closes, the helper carries on, and the plugin reconnects using the helper list in its session slot.
- **Reboots restore context, never processes:** the helper saves its snapshot to the state folder now and then (owner-only files; a setting, on by default, owner 2026-10-27); after a reboot the terminal shows that screen read-only, marked restored, and starts a fresh shell in the saved directory. Commands are never rerun.
- **The helper is small and does one job.** It does not render, interpret escape codes for Tuna, or know about buffers. Hooks, keymaps and drawing belong to the terminal plugin.

## Consequences

- A native crash in libghostty inside Tuna takes Tuna down but no shell; a crash in a helper ends only its terminal.
- Output is parsed twice (helper and mirror). Parsing costs about 10 µs per 8 KiB, so this is acceptable.
- Helpers built from an older Tuna keep running after an upgrade. The protocol carries a version; a helper too old to speak to is reported, and its terminal keeps running until the user restarts it. Handing a live pseudo-terminal to a new helper (`SCM_RIGHTS`, as herdr does) is possible later.
- Tuna's build now depends on `gerbil-libghostty` and its native library (Zig, pinned Ghostty).
- Starting programs on a pseudo-terminal lives in the helper until a second user needs it, then moves to the planned process library.

*Status note (2026-10-28, agent chat stage 2):* the process library exists, for the Pi helper, the second user. `tuna/lib/unix.ss` has the system calls a helper and Tuna share (private folders, Unix sockets with the `SO_PEERCRED` user check, raw device reads and writes, a session of its own, standard ports dropped); `tuna/lib/helper-processes.ss` has each kind's private socket folder (`$XDG_RUNTIME_DIR/tuna/KIND`) and socket paths, starting a helper detached (`setsid -f`, and `systemd-run --user --scope` when it leaves Tuna's scope), waiting for its socket, and a device writer so the editor never waits. Starting a program on plain pipes needs no C: Gambit's `open-process`, with standard error left to the helper's log. The pseudo-terminal, libghostty and the framed terminal protocol stay in `plugins/terminal/`. Program status no longer belongs to terminals: the `program-status-report` record and `report-program-status!` are the program-status contract's, records are kept by buffer, and `terminal-program-status-hook` runs with the record's fields, so the terminal and program-status packages do not import each other.

## As built (stage 2, 2026-10-27)

The decision held; these are the details it left open (plan, stage 2 notes):

- **Detaching.** The plugin starts a helper as `setsid -f [systemd-run --user --scope --collect --unit tuna-terminal-ID] tuna-terminal-helper …`, the scope when Tuna's own cgroup is a scope (the `leave-scope` option). The helper also calls `setsid` and drops its standard ports.
- **Who replies.** The helper answers the program's queries (cursor position, device attributes, sizes), since it is there even while no Tuna is; the mirror never writes to the program.
- **One Tuna at a time.** A second connection gets `refused "busy"`; the plugin retries for a few seconds, which covers a swap whose old connection the helper has not yet seen close.
- **Exit.** The helper reports the program's exit and ends once a Tuna acknowledges it (`exit-ack`), so a program that ends while Tuna is down is still reported on reconnect; `kill` hangs up the program's group (SIGKILL a second later) and ends the helper.
- **Resizing.** Tuna sends the new size, then asks for a snapshot; the snapshot, taken after the helper resized, replaces the mirror, so the mirror never parses output written for another size. *Replaced in stage 5:* the helper marks the point in its output where it resized (`resized`, protocol version 3) and the mirror resizes there; only connecting sends a snapshot.
- **Restoring order.** The plugin is declared before the layout, so its session slot makes the terminal buffers before the layout restores the views that show them; a restore during start-up connects once the editor loop runs.
- **Colours (stage 3).** Tuna tells each helper the theme's colours (protocol version 2, `colors`), which its terminal answers colour queries with; a helper of another version is reported and left running.
- **Programs' reports (stage 4).** The mirror's effects (OSC 133, 9, 777, 9;4, 7501, a full reset) run the terminal contract's hooks; the helper only answers, now also `OSC 7501 ; ?`, for which it keeps a program status handler that does nothing. A consequence of the mirror: a report in output the mirror never parsed (sent before Tuna connected, or while it restarted) is in the helper's screen but runs no hook.
- **Reboots (stage 5).** As decided: each helper saves its snapshot, trimmed to `terminal-saved-scrollback-rows`, to `$XDG_STATE_HOME/tuna/terminals/ID.screen` (folder 0700, file 0600) every `terminal-save-interval` while it changes, when Tuna stops, and on SIGTERM, as a shutdown sends; Tuna tells it where and how often (`settings`). Killing a terminal, or its program ending, deletes the file. A terminal whose helper is gone (a reboot, or the helper killed; a stale socket is deleted) shows that screen, or the mirror's when Tuna had one, under a "Restored" line, and a new helper, started from that screen, runs the shell in the terminal's last folder (OSC 7, kept in the session slot): at once, as ghostel-desktop does, or on `RET` (`terminal-restore-start`). Commands are never rerun. The helper stays small: it loads a snapshot file (`--restore`) and saves; the note and the reset of the programs' modes are the plugin's.
- **Floods (stage 5).** Tuna holds at most `terminal-input-buffer-size` of unparsed output; past it the reader stops, so the helper's queue fills and it stops reading the program. A slow Tuna therefore slows the program, never its own memory.
- **Turning the plugin off for good (stage 5).** Removing `terminals` from `init.ss` leaves the helpers running, as a reload or swap does: Tuna cannot tell the two apart without a kernel change, the session keeps a removed plugin's slot so it comes back to its terminals, and ending them would lose running programs on a mistaken edit.
