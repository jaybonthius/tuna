# 3. One editor thread, direct-style commands, background jobs on snapshots

Status: accepted (2026-10-11)

## Context

Typing must reach the screen without waiting for syntax highlighting, language servers, search, or other follow-up work. Emacs serializes Lisp with a global lock and redisplays only when no input is pending; its commands can block in direct style (`read-string`, `y-or-n-p`) through recursive edits. Emacs freezes when a command or process filter computes for a long time, because nothing preempts it.

Gambit threads are preemptive green threads. Today Gerbil runs them on one OS thread; the Gerbil developers are enabling SMP, after which threads may run in parallel. Gerbil's MOP still marks some paths as not SMP-safe, so Tuna must not rely on shared mutable state between threads.

## Decision

- **Editor baton.** Exactly one thread at a time holds the editor baton and may mutate editor state ([ADR 4](0004-state-ownership.md)). The editor loop owns the baton and lends it to one command at a time.
- **Input.** Browser events are acknowledged with `204` on receipt and enqueued. The loop dequeues events, resolves keys through the active keymaps, and runs the resulting command.
- **Commands.** Each interactive command runs in its own Gambit thread holding the baton. A command that needs input (`read-string`, `completing-read`, `y-or-n-p`) suspends: it returns the baton to the loop and waits. The loop keeps processing events, which go to the minibuffer or other active input target. When the answer arrives, the loop hands the baton back and the command resumes. At most one command holds the baton; several may be suspended. This gives Emacs's direct-style ergonomics without callbacks.
- **Errors.** A command error is reported in the echo area and the loop continues. There is no rollback ([ADR 4](0004-state-ownership.md)).
- **Redisplay.** After a command completes or suspends, the loop marks the frame dirty. Rendering happens when the input queue is empty, or after a frame-time cap under sustained input, and coalesces: only the newest state is rendered ([ADR 7](0007-rendering-and-transport.md)).
- **Jobs.** Long or blocking work runs as a job: a thread that receives immutable inputs (text snapshots, revisions, plain data) and must not touch live editor objects. A job's result is posted back to the loop as a message and applied on the editor thread only if the revisions it was computed from are still current; otherwise it is discarded or restarted. Jobs have keys, such as `(highlight buffer-7)`, and a new job with the same key cancels the pending one. Jobs are registered through a plugin context and cancelled when the plugin deactivates.
- **Hooks schedule, they do not compute.** Change hooks run synchronously on the editor thread and must be cheap; expensive reactions schedule jobs.
- **External processes.** Language servers, shells, and tools run as subprocesses whose reader threads post messages into the loop.
- **Priority.** User input is processed before job results and process output.

## Consequences

- A keystroke's latency is the command plus one render. Highlighting and diagnostics arrive later as separate, cheap renders.
- Long-running Scheme computation in a command does not freeze rendering of other connections, but it does delay subsequent commands. Such work belongs in jobs.
- When SMP lands, jobs gain real parallelism with no API change, because they already share only immutable data.
- Persistent text ([ADR 6](0006-buffers-nodes-and-text-store.md)) makes job snapshots free; the job API never needs to copy a buffer.
- The baton protocol needs care: a suspended command may resume into a changed world (as with Emacs recursive edits). Commands re-read state after waiting.

## Alternatives considered

- **Callback- or promise-style prompts.** Rejected: hostile to porting Emacs code, and needless in a language with cheap threads and continuations.
- **One actor per buffer.** Rejected for now: cross-buffer commands are common and would need distributed coordination. Revisit only with evidence.
- **Shared mutable state with locks.** Rejected: fragile under SMP and with arbitrary extension code.
