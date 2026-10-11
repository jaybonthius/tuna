# Emacs command execution and interactive composition

## Question

What architectural property lets an Emacs command pause for input, let the user
run other commands while supplying that input, receive the result, and then
continue as ordinary Lisp code?

## Finding

Emacs does not model an interactive command as one atomic state transition or
as a callback to run after a prompt closes. An interactive command is an
ordinary Lisp call on a live evaluator stack. When it needs editor-mediated
input, it can enter another command loop. The outer Lisp call remains suspended
on the stack; the inner loop reads and executes normal commands; exiting the
inner loop returns a value to the suspended call.

That execution topology—not the minibuffer UI itself—is the important source of
Emacs's composability.

## The normal command loop

The Emacs Lisp manual describes the top-level cycle as:

1. read a complete key sequence;
2. resolve it through the active keymaps;
3. execute the resulting command;
4. redisplay and repeat.

The manual also explicitly permits Lisp programs to read key sequences or
individual events themselves ([command-loop overview](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/doc/lispref/commands.texi#L37-L75)).

The implementation follows that shape. `command_loop_1` calls
`read_key_sequence`, obtains the command selected by the current keymaps, runs
the pre-command hook, calls `command-execute`, and then runs the post-command
hook ([`src/keyboard.c`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/keyboard.c#L1318-L1600)).

An unfinished sequence such as `C-x` is still inside input reading. Emacs can
echo those unfinished keys after a configurable pause while it continues
waiting ([echo timing](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/keyboard.c#L2847-L2894),
[`echo-keystrokes`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/keyboard.c#L13856-L13866)).
The key sequence and its timer are therefore command-loop concerns, not client
UI concerns.

## Commands are ordinary Lisp functions

A command is an interactively callable function or keyboard macro, not a key
sequence. `command-execute` eventually invokes a function through
`call-interactively` ([manual](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/doc/lispref/commands.texi#L800-L924),
[implementation](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/lisp/simple.el#L2789-L2848)).

`call-interactively` reads arguments according to the function's `interactive`
declaration and then calls the same Lisp function. Its argument readers may
read from the minibuffer. The function's return value propagates normally
([`src/callint.c`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/callint.c#L256-L430)).

This gives Emacs two useful forms of composition:

- Lisp code can call the underlying function directly with ordinary arguments.
- Lisp code can call it interactively, allowing the command to obtain arguments
  from the current editor context and from further user input.

## What happens during `M-x`

`execute-extended-command` is itself an ordinary command. Its interactive
argument reader calls `read-extended-command`; that function uses
`completing-read` to obtain a command name
([reader](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/lisp/simple.el#L2313-L2410),
[execution](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/lisp/simple.el#L2601-L2668)).
After the read returns, `execute-extended-command` resolves the name and invokes
that command through `command-execute`.

The important fact is that `completing-read` does not end the outer command and
register a callback. The call stack remains:

```text
execute-extended-command
  read-extended-command
    completing-read
      read-from-minibuffer
        inner command loop
```

Inside `read-from-minibuffer`, Emacs creates/selects a minibuffer buffer, gives
it a local keymap, runs its setup hook, and calls `recursive_edit_1`
([`src/minibuf.c`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/minibuf.c#L573-L930)).
That inner loop executes ordinary commands. Because the minibuffer is the
current buffer, editing, completion, history, movement, and other applicable
commands naturally operate on the input being collected.

`exit-minibuffer` exits the innermost loop
([`lisp/minibuffer.el`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/lisp/minibuffer.el#L3031-L3069)).
`read-from-minibuffer` then constructs and returns the input string, allowing
the suspended calls above it to resume.

A command may open another minibuffer while one is already active when
recursive minibuffers are enabled. The innermost minibuffer becomes active and
the outer call remains suspended
([manual](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/doc/lispref/minibuf.texi#L60-L106),
[recursive-minibuffer rules](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/doc/lispref/minibuf.texi#L2793-L2827)).

## Recursive editing is the underlying mechanism

The manual is unusually direct: recursive editing suspends the command that
entered it and lets the user perform arbitrary editing before that command
resumes. The inner loop has the normal keymaps and error handling. Minibuffer
input is a specialized recursive edit
([recursive-editing chapter](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/doc/lispref/commands.texi#L4436-L4548)).

The C implementation calls the same `command_loop` recursively and restores its
dynamic environment when the nested loop exits
([`recursive_edit_1`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/keyboard.c#L708-L842)).

This is stackful execution: the suspended computation is the ordinary C/Elisp
call stack. Emacs does not serialize that stack into editor state.

## Dynamic editor context

Nested commands need to mean “operate here” without every function receiving a
large context object. Emacs establishes dynamic context such as the current
buffer, selected window, active keymaps, current command, prefix argument, and
minibuffer variables. Entering a minibuffer changes some of that context;
unwinding restores the outer context. `call-interactively` explicitly saves
command variables that minibuffer reads may overwrite
([`src/callint.c`](https://github.com/emacs-mirror/emacs/blob/c6147e2b539dc3490b47a924bed86da00cc763a7/src/callint.c#L280-L340)).

Racket parameters provide the corresponding mechanism: they are dynamically
scoped, thread-aware, and continuation-aware
([Racket parameters](https://docs.racket-lang.org/reference/parameters.html)).

## Implications for Tuna

### The browser is an input/output terminal

The browser should:

- capture browser events;
- transmit them in order;
- stop the browser from independently acting on editor-owned input.

It should not know keymaps, prefixes, commands, prompts, completion, modes, or
what text to display. All of that is backend state and backend rendering.

### Interactive commands cannot be editor transactions

Tuna's current `call-with-editor-command` holds the global editor semaphore for
the entire command procedure, and external commands and queries wait behind it
(`tuna/api/private/update.rkt:38-70`; the blocking behavior is tested in
`tuna-test/tuna/command.rkt:55-102`). An interactive command that waits for the
next browser event while inside this boundary would freeze the editor.

Tuna therefore needs two distinct concepts:

- **Editor update:** a short, atomic state change using the existing candidate,
  validation, commit, persistence, and notification machinery.
- **Interactive command:** an ordinary Racket procedure executed by a server
  command loop. It may perform several editor updates, wait for input, enter a
  nested command loop, call other commands, and later resume.

An interactive command is not atomic across its whole lifetime. Emacs behaves
the same way: changes made by commands inside recursive editing are real; an
outer quit does not magically roll all of them back.

### Use a live Racket stack, not callbacks or persisted continuations

Racket already supplies the needed execution substrate:

- lightweight threads for retaining the ordinary command call stack
  ([threads](https://docs.racket-lang.org/reference/threads.html));
- asynchronous channels for input delivery
  ([asynchronous channels](https://docs.racket-lang.org/reference/async-channel.html));
- `sync` events for combining input, timers, process output, and cancellation
  ([events](https://docs.racket-lang.org/reference/sync.html));
- parameters for nested dynamic context;
- custodians for lifecycle cleanup;
- continuation prompts or escape continuations for leaving the innermost
  recursive loop without using continuations as the scheduler
  ([continuations](https://docs.racket-lang.org/reference/cont.html)).

A long-lived Racket thread per Tuna session is the simplest faithful shape. A
command that asks for editor-mediated input calls a nested loop on that same
thread. The browser POST handler only places an event on the thread's queue and
returns.

The suspended command stack is intentionally runtime-only. Restarting Tuna may
restore editor data, but it does not restore a half-executed Racket call stack.
That is analogous to restarting Emacs.

### Keep runtime interaction separate from persistent editor data

Tuna needs three lifetimes:

1. **Persistent editor state:** subjects, views, buffers, layouts, and other
   data that belongs in the state file.
2. **Live interaction state:** unfinished key sequences, prompt stack, current
   message, timer generations, and the session command-loop thread.
3. **Executable environment:** command procedures, keymaps, and loaded Racket
   extension code.

Live interaction state must be queryable by server rendering, but it should not
be written into the durable editor snapshot merely because it is visible.

## Weevil comparison

Weevil got two ideas right: HTTP handlers enqueue raw input quickly, and one
server loop serializes it before rendering. It did not preserve ordinary command
composition. `completing-read` opened minibuffer state and returned; acceptance
later resolved a symbolic “exit action” in a different command invocation
(`weevil/completion.rkt`, `weevil/minibuffer.rkt`). That forced callbacks,
serializable action tags, registries, and a large explicit state machine.

Tuna should retain the queue and server rendering, but replace the callback
shape with a live command stack and recursive command loop.

## Architectural requirements

The next Tuna input architecture must satisfy all of these:

1. Every meaningful browser input event reaches the backend immediately.
2. One server command loop orders input for a session.
3. Key-sequence reading, keymaps, timers, prompts, and command lookup are
   backend concerns.
4. Interactive commands are ordinary Racket procedures and may wait for input.
5. A command may enter a nested command loop; inner commands may run; exiting
   returns a value to the suspended outer call.
6. No command waits while holding Tuna's editor-state lock.
7. Each state mutation remains a short validated CQRS update.
8. Interaction changes can invalidate the server-rendered session without
   forcing a persistent state snapshot.
9. Errors and quit unwind to the appropriate command-loop level without killing
   the session loop.
10. The browser contains transport mechanics only, never editor behavior.
