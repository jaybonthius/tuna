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
