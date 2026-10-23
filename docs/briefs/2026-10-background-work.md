# Brief: work off the editor thread

**Date:** 2026-10-22. **Status:** proposed; waiting for the owner. Evidence: [`agents/research/background-work/`](../../agents/research/background-work/) (prior art across editors and languages; Tuna's mechanics, with a working prototype). Changes the jobs library (ADR 3) and fixes one kernel bug; stage 5 of [drawing only what changed](2026-10-drawing-only-what-changed.md) builds on it.

## What we're building and why

**Today.** Only one thread may touch editor state: the editor thread. Commands run on it one at a time, so nothing ever needs a lock. Slow work, such as highlighting, runs as a *job* on another thread:
1. The job sees only plain data, such as a snapshot of the text (snapshots are free).
2. When it finishes, its result is queued back to the editor thread.
3. A small task checks that the result still applies, and then lets the job's `apply` procedure change state.
4. The screen redraws what changed.

Nothing ever calls "render".

This works, but it has three problems:
- **Too much ceremony.** One background step takes five keyword arguments and two procedures.
- **One result per job.** A job can't keep watching something, such as `/proc`, git or a file.
- **No simple way for a command to wait for background work** and carry on where it left off. Tasks can already pause, which is how `read-string` waits for your answer without freezing the editor, but nothing gives commands that ability for background work.

**The proposal: two small faces over the machinery we have.** No locks and no new concepts.

1. **`(off-thread proc input)`, for commands.** The command pauses, `proc` runs on another thread with `input`, and the command resumes on the editor thread with the answer, or with its error. Meanwhile you keep typing. It reads like ordinary code, and it is what Kotlin's `withContext`, Swift's `await` and Zed's `cx.spawn` do. `(sleep-for seconds)` is the same kind of pause, Emacs's `sleep-for`.
2. **Sources, for state outside Tuna.** A source reads something every N seconds on its own thread, such as `/proc`, git status or a file. It compares the reading with the last one *on that thread*, and posts only what differs. The editor applies those changes, and only the rows that changed redraw. When nothing differs, nothing is posted, so the editor does no work at all and idle stays at zero.

   Underneath, a source is a job that may post several results, which ADR 3 always allowed and the library never built. Turning the plugin off stops it.

Jobs stay, with an added "post a result" procedure, for work that needs "newest wins": highlighting that restarts on every keystroke keeps its job key.

**One kernel fix.** The kernel documents `resume!`, `spawn-task!` and `cancel-task!` as callable from any thread. From a fresh background thread they reach the wrong kernel. The prototype had to work around this. The fix makes them keep their documented promise and changes no interface.

## The picture

**Status:** planned.

![Work off the editor thread](../diagrams/background-work.svg)

## A walkthrough

1. **You run a magit-like `status` command.** It calls `(off-thread git-status dir)`. The command pauses while `git status` runs on a worker thread; the editor stays responsive, and you can keep typing in another view.
2. **The answer arrives.** The command resumes on the editor thread, builds the status buffer's rows, and finishes. The screen redraws the new buffer.
3. **You press `C-g` while it is still waiting.** The command stops, as `C-g` stops Emacs during `sleep-for` or waiting on a process. Whatever the worker returns later is thrown away.
4. **You open `*Processes*`.** Its source reads `/proc` every second. Most seconds, two of 200 processes changed CPU: it posts two changes, two rows update, and only those two redraw.
5. **Nothing changes for a minute.** The source posts nothing, and the editor runs no task, draws nothing and sends nothing.
6. **You turn the plugin off.** Its source stops, and anything it was about to post is discarded.

## A code sample (package author's view)

```scheme
;; A command that waits for background work.
(defcommand (git-status)
  "Show the repository's status."
  (let (entries (off-thread read-git-status (default-directory)))   ; pauses; the editor stays free
    (show-status-buffer! entries)))                                  ; back on the editor thread

;; A source: runs off the editor thread, and the editor hears only about changes.
(context-start-source! ctx 'processes
  every: 1.0
  read: read-processes            ; plain data in, plain data out, off the editor thread
  apply: update-process-rows!)    ; on the editor thread, only when the reading differs
```

`read-git-status` and `read-processes` are ordinary procedures that take and return plain data (strings, numbers, lists), never live buffers. In tests, Tuna checks this automatically.

## Decisions for the owner

None. Settled by the evidence:
- **`C-g` stops a command waiting in `off-thread` or `sleep-for`,** as in Emacs. A source isn't a command: only turning its plugin off stops it.
- **A source is a looping job, not a looping command with `sleep-for`.** The command version would wake the editor every second even when nothing changed. The job version wakes nothing.
- **Comparison happens where the data is read, by default with `equal?`.** A source that wants to compare only what it shows (say, CPU rounded to one decimal) rounds in `read`.
- **No subscription framework yet** (Elm-style "run this source only while its buffer is visible"). It needs a "buffer shown or hidden" hook. Add it when a third or fourth source repeats the same code.

## New terms

- **Off-thread:** run a procedure on another thread while the calling command pauses, then resume it with the answer.
- **Source:** something outside Tuna, read on its own thread, that posts only its changes.
- **Plain data:** numbers, strings, symbols, booleans, and lists and vectors of them. Anything crossing threads must be plain data.
