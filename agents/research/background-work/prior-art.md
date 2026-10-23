# Research: prior art for "work off the main thread, then update state" in Tuna

Read-only research, 2026-10. Labels: **Fact** = read in code or docs (cited); **Inference** = my reasoning; **Unverified** = not re-fetched this session (stated from general knowledge of the system; check before relying). Earlier research already covers Helix, Zed, Lapce, Neovim and VS Code in depth: `agents/research/concurrency-prior-art/README.md`. This brief adds the language runtimes and Emacs mechanics, and compares API shapes for Tuna.

## Summary

- **Every system that keeps UI state single-threaded uses the same four moves:** (1) the work runs elsewhere on plain data; (2) the result returns as a message that a main-thread handler applies; (3) the handler checks that the result still applies (a version, a handle that may have been dropped, a generation); (4) a re-render follows because *any* state update marks the UI dirty. Tuna already has (1)(2)(3)(4); what is missing is API shape, not mechanism.
- **Three shapes recur:** *callback/message* (Emacs process filters and `async-start`, Neovim `vim.schedule`, Helix callbacks, Elm `Cmd`, Erlang mailboxes); *direct-style suspend* (Kotlin `withContext`, Swift `await`, GPUI `cx.spawn` + `.await`, Go channel receive); *declarative subscription* (Elm `Sub`, structured-concurrency scopes that own children). Cancellation is best when it follows **ownership**: drop the handle (GPUI `Task`), cancel the scope (Kotlin), cancel the context (Go), turn off the subscription (Elm). Tuna's plugin context already is that owner.
- **Recommendation (Inference):** keep one substrate, the existing job machinery in `tuna/lib/jobs.ss`, and give it two thin faces. (a) **`post!`-streaming jobs**: the producer runs off-thread in direct style (`loop: read, compare, post! only differences, sleep`), and each post becomes an apply task on the baton. This realizes ADR 3's "a job may post several results" and is the right shape for `/proc`, git status, file watching and LSP, because an idle source costs the editor no task and no redraw. (b) **`(off-thread proc input)`** for commands: sugar over `suspend` so a command reads like Emacs code and resumes on the baton. Do not make long-lived sources "tasks that loop with `sleep`": every resume dirties the screen, so an idle poll would wake the editor each period.

## 1. Editors

### Emacs (Facts unless marked)
- **Threads and the global lock.** Lisp threads share memory; switching happens only at well-defined points: `thread-yield`, waiting for keyboard input, waiting for process output (`accept-process-output`), mutex/condvar/`thread-join` waits. Globals are shared; dynamic `let` bindings, the current buffer and match data are per thread. Source: [Elisp manual, Threads](https://www.gnu.org/software/emacs/manual/html_node/elisp/Threads.html). The manual says correct programs should not rely on cooperative switching. Pitfall: shared buffers across threads are unprotected, so almost no package uses `make-thread`; everything else is below.
- **Timers.** `run-with-timer`/`run-with-idle-timer` run a function on the main thread between commands. Pitfall: timer code that is slow freezes the UI; there is no way to run it elsewhere.
- **Process filters and sentinels.** `make-process :filter F :sentinel S`: the subprocess runs concurrently; its output is delivered to `F` on the main thread *while Emacs is waiting or idle*. This is shape "callback" with the OS process as the off-thread worker and a byte stream as plain data. It streams several results naturally. Pitfalls: filters receive arbitrary chunk boundaries (callers buffer and split), and a slow filter blocks input. (Inference: this is exactly the model Tuna's ADR 3 external-process rule copies.)
- **async.el.** `(async-start (lambda () ...) (lambda (result) ...))` runs the first function in a child Emacs and calls the second with the result on the main thread ([emacs-async README](https://raw.githubusercontent.com/jwiegley/emacs-async/master/README.md)). The input is serialized (plain data by necessity), the result comes back once. No built-in cancel besides killing the process; no staleness check (the callback must test for itself).
- **jit-lock.** Fontification is *pulled by redisplay* for the visible region, optionally deferred by a timer (`jit-lock-defer-time`). Staleness is avoided because the work is requested when needed and applied synchronously on the main thread. (Prior brief: `loop-and-external-state.md` cites `lisp/jit-lock.el`.)
- **auto-revert, proced, magit.** Timer or file-notify trigger, then main-thread work; proced and magit erase and reinsert the whole buffer, they do not diff (see `agents/research/rendering/loop-and-external-state.md`, which cites the source lines). Magit's async git runs through process sentinels, then refreshes. Pitfall (Fact in that brief): full reinsert loses point and folds, and magit patches this with section-based point restoration.

### Zed / GPUI (Facts from source at `main`, fetched this session)
- Two executors. `BackgroundExecutor::spawn(future: Send + 'static) -> Task<R>` runs on a thread pool; `ForegroundExecutor::spawn(future: 'static) -> Task<R>` runs on the main thread ([`executor.rs`](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/executor.rs)).
- From a model/view: `cx.spawn(async move |this: WeakEntity<T>, cx: &mut AsyncApp| {...})` — "The returned task must be held or detached" ([`context.rs`](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/app/context.rs)). Inside, `let r = cx.background_spawn(async { heavy() }).await;` then `this.update(cx, |this, cx| { this.field = r; cx.notify(); })?`.
- `WeakEntity::update` returns `Result`: it fails with "entity released" if the owner is gone ([`entity_map.rs`](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/app/entity_map.rs)). This is the "target-alive" check, built into the type.
- **Cancellation = dropping the `Task`.** Store it in a field: `self._reparse = cx.spawn(...)`; assigning a new one drops (cancels) the old one. `.detach()` opts out. (Unverified in this fetch for the drop wording on `Task` itself; the `executor.rs` text says dropping the scope future cancels its tasks.)
- `cx.notify()` marks the entity dirty and triggers re-render: re-render is an explicit call, but forgetting it is the common bug (Inference).
- Staleness: Zed installs a stale result then re-runs (`Buffer::reparse`), per prior brief.
- Pitfall: a held-across-await borrow is impossible by construction; `AsyncApp` methods panic if the app is gone.

### VS Code (Unverified details; stable, well-known API)
- Extensions run in a separate extension-host process; all APIs are async (`Promise`). Long work takes a `CancellationToken`; a new `CancellationTokenSource` per request cancels the old one (`source.cancel()`), and the provider checks `token.isCancellationRequested`. Events (`onDidChangeTextDocument`) stream changes; `TextDocument.version` is how handlers detect staleness. Pitfall: cancellation is advisory; results of cancelled work must still be discarded by the caller.

### Neovim (Facts from [`lua.txt`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/lua.txt))
- Libuv callbacks (`vim.uv` timers, fs watchers, process handles) run in the main loop's fast context where most `vim.api` calls are forbidden. `vim.schedule(fn)`: "Schedules {fn} to be invoked soon by the main event-loop"; `vim.schedule_wrap(fn)` returns a function that does so. The docs' own examples wrap watcher and timer callbacks in `vim.schedule_wrap`. `jobstart{on_stdout=...}` delivers process output to callbacks (Unverified detail). Pitfalls: forgetting the wrap gives "not allowed in fast event context" errors; no staleness or cancel helpers (the plugin keeps a counter or calls `timer:stop()`).

### Helix / Lapce
Covered in the prior brief (Facts there): Helix sends `Callback::Editor(Box<dyn FnOnce(&mut Editor)>)` through a channel to the main loop; cancellation through `TaskController` generation counters; edit results apply only at the exact document version. Lapce passes cancellation signals and keeps old styles until the new parse arrives.

## 2. Languages and runtimes

- **Kotlin coroutines** ([docs](https://kotlinlang.org/docs/coroutines-basics.html), Fact). `scope.launch { val r = withContext(Dispatchers.Default) { heavy() }; state = r }` — the function suspends, and the code after `withContext` resumes on the original dispatcher (`Dispatchers.Main` on Android/desktop UI). Structured concurrency: every coroutine belongs to a scope; cancelling a scope cancels its children, and a parent waits for its children. Cancellation is cooperative (`isActive`, `ensureActive`, suspension points throw `CancellationException`). Flows (`flow { emit(x) }`, `collect`) stream several values. Pitfall: after resuming, state may have changed ("re-read state"); `conflate`/`collectLatest` is the idiom for "only the newest matters". *This is the closest model to Tuna's tasks (direct style, suspend, plugin context = scope).*
- **Swift** ([Concurrency chapter](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/), Unverified details: the fetch returned only a stub). `@MainActor` confines types and functions to the main thread by the type system; `await` marks suspension points; `Task { ... }` inherits the actor, `Task.detached` does not; `AsyncSequence`/`AsyncStream` stream values; cancellation is cooperative (`Task.checkCancellation()`), and structured child tasks (`async let`, `TaskGroup`) cancel with their parent. Values crossing actors must be `Sendable` — the compiler-enforced version of Tuna's "plain data". Pitfall: actor reentrancy: state may change across every `await`.
- **Clojure** (Unverified; core features). `future` runs on a pool (no cancel beyond `future-cancel`, which interrupts); `agent` + `send`/`send-off` serialize updates to one value asynchronously (a "one-writer queue", like Tuna's baton for one object); `core.async` `go` blocks park on channels, `alts!` selects among channels and a timeout channel; closing a channel is the stop signal. **Hyperlith** (Fact, `src/hyperlith/core.clj:117-144`): `(tx! thunk)` is `LinkedBlockingQueue.offer`; one virtual thread drains the queue every `batch-tick-ms` (default 50), runs `(batch-fn ctx batch)` over *all* queued thunks as the only writer, then re-renders every connection. Shape: *message queue + single writer + unconditional re-render*. Pitfalls (Fact from the existing brief): it re-renders every tick even with an empty batch, and cancellation or staleness is the caller's problem.
- **Erlang/OTP** (Unverified; core). Each `gen_server` owns its state and handles one mailbox message at a time; `cast`/`call`/`handle_info` are the only ways in; a worker is a separate process that sends its result as a message. Cancellation = `exit/2` or monitor/link; stale replies are identified by a reference (`make_ref()` in `gen_server:call`, late replies are dropped). Pitfall: mailbox growth with a slow consumer; selective receive cost. This is Tuna's baton as a process.
- **Go** (Unverified; core). `go f(ctx)`; results on a channel; `select { case r := <-ch: ... case <-ctx.Done(): }`; `context.WithCancel` cancels a tree of goroutines; cancellation is cooperative. Pitfall: leaked goroutines blocked on an unbuffered channel nobody reads; UI libraries (Fyne, Gio) require results to be handed to the UI goroutine by an explicit call.
- **Racket** (Unverified; core). `thread`, `channel`, `sync` over events (`channel-get`, `alarm-evt`, `thread-dead-evt`), `custodian` — a *resource owner*: `custodian-shutdown-all` kills every thread, port and timer created under it. Places run in separate OS threads with message-passing of serializable data; futures are for fine-grained parallelism. The custodian is the closest analogue of Tuna's plugin context. `racket/gui`'s `queue-callback` posts a thunk to the GUI thread (like `result-poster`). Tuna's old Racket attempt lives in `agents/research/`.
- **Elm** ([guide: Time](https://guide.elm-lang.org/effects/time.html), Fact). `Cmd` is a one-shot effect whose result returns as a `Msg` to `update`; `subscriptions : Model -> Sub Msg` is a *function of the model* (e.g. `Time.every 1000 Tick`), and the runtime starts and stops sources as the returned value changes (the guide's clock can be paused by returning `Sub.none`). Cancellation is therefore declarative: stop listing the subscription. Staleness is handled by the model: a `Msg` carries what it was for and `update` decides. Every `Msg` triggers `view model`, and virtual-DOM diffing skips unchanged output.

## 3. Gerbil and Gambit: what exists, what Tuna uses

- **Facts (local Gerbil checkout `v0.19-dev`, `src/std`):** `:std/sync/channel` (buffered channel with `channel-put`/`channel-get`/`channel-try-get`/`channel-sync`/`channel-close`), `:std/sync/completion` (`make-completion`, `completion-post!`, `completion-wait!`, `completion-error!`: a one-shot promise), `:std/sync/{atom,barrier,rwlock,spinlock,wg,threads}`, `:std/actor` (message-passing actors with serialization; designed for networked ensembles; heavy for in-process use), `:std/iter` (iteration protocol). `coroutine.ss` and `event.ss` exist only under `v0.19-WIP/v0.19-TODIE-std`, i.e. not shipped. Gambit threads: `thread-send` / `thread-receive` (with timeout) mailboxes, `thread-interrupt!`, `thread-terminate!`, and one-shot continuations are available (Gambit manual, Unverified here).
- **Fact (Tuna):** `tuna/kernel/loop.ss` provides `spawn-task!`, `result-poster` (a procedure `(name thunk)` sending to the loop thread's mailbox, works from threads with no kernel parameters), and `suspend` (`(suspend arm)`: calls `arm` on the baton with a suspension, sends `suspended:` to the loop, and blocks on a `completion` until some thread calls `resume!` or `resume-quit!`; check-quit before suspending). The loop marks the screen dirty after every resume (`loop.ss:532`, per the earlier brief) and every task end.
- **Fact (Tuna):** `tuna/lib/jobs.ss` runs `(run input cancelled?)` once in a root thread, posts exactly one result through `result-poster`, and `finish-job!` on the baton applies validity (`exact-revision` / `target-alive` / `rebase`). Keys give at-most-one-running-plus-one-pending. Plugin deactivation closes the group (cancel flag only; thread is never interrupted). A job failure becomes a `message`.
- **Fact (Tuna):** `tuna/lib/timers.ss` spawns a countdown thread that calls `spawn-task!` per tick; per `loop-and-external-state.md` this wakes the loop and redisplays every period.
- **Inference:** the required building blocks (mailbox post, completion, suspend/resume, cancel flag under a lock, plugin-scoped group) all exist. `:std/sync/channel` is not needed: `result-poster` is already the "channel to the baton".

## 4. Comparison of the seven concerns

| Concern | Emacs | GPUI | Neovim | Kotlin | Elm | Tuna today |
|---|---|---|---|---|---|---|
| (a) off thread | process / child Emacs | `background_spawn` | libuv / jobs | `Dispatchers.Default` | `Cmd` | `job-group-start!` |
| (b) back on main | filter/sentinel | `this.update(cx, …)` | `vim.schedule` | resume on Main | `update` msg | `result-poster` → apply task |
| (c) several results | repeated filter calls | repeated `update`, channels | repeated callbacks | `Flow` | `Sub` | **one result per job** (gap) |
| (d) cancel | kill process | drop `Task` | `timer:stop` | cancel scope | drop `Sub` | cancel flag via group/key |
| (e) stale | caller | caller / `WeakEntity` | caller | `collectLatest` | model | validity policy |
| (f) no locks | one lock | `App` not `Send` | one thread | Main dispatcher | pure | baton (ADR 4) |
| (g) re-render | redisplay always | `cx.notify()` | `redraw` | state observation | `view` | every task dirties |

## 5. Candidate API shapes for Tuna

All three use the existing substrate (root thread with cleared environment, `result-poster`, validity check on the baton, plugin context cancels).

**A. Direct-style `(off-thread proc input)`.**
```scheme
(def (command-git-status)
  (let (rows (off-thread parse-status (snapshot dir)))   ; suspends; baton free
    (set-rows! (current-status-buffer) rows)))            ; resumes on baton
```
Mechanism: `(suspend (lambda (s) (start-thread (lambda () (resume! s (proc input))))))`. Cancellation: the task is cancelled by quit/deactivation, which already raises in the suspended task; the worker's cancel flag is set by an `unwind-protect`. Staleness: *the calling task must re-check state after resuming* (ADR 3's "hazard"); optional `target:` argument raises a quiet `stale` condition when the target's revision moved. Strengths: reads like Emacs code and Kotlin; trivial to test with a synchronous fake. Weaknesses: one result per call; a polling loop built from it wakes the baton every period and dirties the screen even when nothing changed; easy to capture a live object in `proc` by mistake (needs the same cleared-environment rule).

**B. Streaming job with `post!` (extend `job-group-start!`).**
```scheme
(job-group-start! group 'proced
  input: (proc-root)
  run: (lambda (root cancelled? post!)
         (let lp ((prev #f))
           (unless (cancelled?)
             (let (now (read-processes root))            ; plain data
               (unless (equal? now prev) (post! (diff prev now)))
               (job-sleep 1.0 cancelled?)               ; wakes early on cancel
               (lp now)))))
  apply: (lambda (delta) (reconcile-rows! buffer delta)) ; baton
  target: buffer validity: 'target-alive)
```
Strengths: idle source = zero tasks, zero redraws (the owner's `/proc` goal); plain-data boundary visible in the signature; one mechanism for one-shot and streaming (one-shot posts once); keys/pending/cancel/validity unchanged; deactivation cancels. Weaknesses: producer and consumer are two procedures (callback style); the diff state lives in the producer, so after a `rebase`/drop the consumer cannot ask for a fresh full reading without a second channel back (needs a `reset!` message or a restart); `job-sleep` and a cancel wake-up must be added.

**C. Subscription as a function of state (Elm-style `sources`).**
```scheme
(define-source proced-source (buffer)         ; active while a predicate holds
  active?: (lambda () (buffer-shown? buffer)) ; re-evaluated on layout change
  read: read-processes  every: 1.0
  diff: diff-rows  apply: reconcile-rows!)
```
Strengths: declarative, owner-friendly, visibility gating (stop reading when hidden) and cancellation fall out. Weaknesses: new vocabulary; needs a general "buffer shown/hidden" hook that does not exist yet (loop-and-external-state.md); LSP and git, which are push or process-driven, do not fit `every:`; a framework with one consumer today (AGENTS.md: "prefer deleting an abstraction"). It could later be a plugin-level macro over B.

### Scoring (1 = poor, 3 = good; Inference)

| Criterion | A direct | B streaming job | C subscription |
|---|---|---|---|
| Simplicity for command authors | 3 | 2 | 2 |
| Simplicity for long-lived sources | 1 | 3 | 3 |
| Cancellation (deactivate, superseded) | 3 | 3 | 3 |
| Staleness | 2 (caller re-checks) | 3 (validity at apply) | 3 |
| Plain-data safety | 2 | 3 | 3 |
| Idle cost (no change = no task) | 1 | 3 | 3 |
| Testability | 3 | 3 (call `run` with a fake `post!`) | 2 |
| Fit ADR 3/4/12/17 | 3 | 3 | 2 (new kernel-adjacent surface) |
| New code | small | small | medium |

## 6. Recommendation (Inference)

Adopt **B as the one substrate and add A as its single-result sugar**:

1. Give jobs a `post!` (third argument to `run`) so a job may post several results (this already is ADR 3's wording; it is a library change in `tuna/lib/jobs.ss`, no kernel change). Add a cancel-aware `job-sleep` (a timed `thread-receive` on a per-job mailbox that `job-cancel!` and group close both signal; the existing `cancelled?` flag stays authoritative).
2. Add `(off-thread proc input [target])` in the same library for commands: `suspend` + a one-shot job whose result `resume!`s the task. It is the Kotlin `withContext` equivalent, and it keeps ADR 3's quit semantics because the suspended task is cancelled with its plugin.
3. Sources (proced, git status, file watch, LSP) are plugins that use B: they diff off the baton and post only differences; their apply task reconciles nodes by stable key. ADR 17's rule ("outside state … posts only differences") is then literally this API. Treat C as later sugar if a third and fourth source repeat the same boilerplate.
4. Do not build sources as looping tasks with `sleep` and do not use `context-run-with-timer!` for polling (both wake the baton and dirty the screen each period).

**Open design questions for the owner/implementer (not answered by prior art):**
- What a stale `off-thread` does: return `#f`, raise a quiet condition, or nothing (caller re-checks). Kotlin/Swift do nothing; Helix drops. A quiet `stale` raise unwinds the task but must not report through `Messages`.
- How a producer asks for a full re-read after the apply side drops or rebases a delta (a restart with the same key is the simplest; a second mailbox is more general).
- Whether `post!` coalesces (latest wins per job, like process output) or queues every post. For diffs, queue every post (losing one corrupts the sequence); for full-state readings, coalesce. Choose per job with a keyword.
- Whether `equal?` skipping belongs in the producer (as shown) or in the library (`post!` drops a value `equal?` to the last post). The library variant is a one-liner but hides the "compare what is shown, not raw values" rule.

## Contradictions
- Prior research says jobs "may post several results" (ADR 3); `jobs.ss` posts one. Not a source conflict: a known gap (documented in `loop-and-external-state.md`).
- GPUI/Swift/Kotlin make cancellation automatic with ownership; Emacs and Neovim leave it to the caller. Both are valid; Tuna's context-owned model matches the former.

## Missing evidence
- Swift, Go, Racket, Erlang, Clojure `core.async`, VS Code details are from general knowledge, not fetched this session (the Swift book fetch returned a stub). Check before quoting.
- GPUI `Task` drop-cancels wording was not found in the fetched files (it is in the `gpui` task crate); the `Scope` drop wording was.
- Gambit manual semantics of `thread-receive` timeouts on a per-job mailbox were not re-checked; the existing `timers.ss` already uses that pattern.
- Not measured: wakeup/redraw cost of a looping-task poll versus a streaming job.

## Sources
- Kept: Elisp manual, Threads (https://www.gnu.org/software/emacs/manual/html_node/elisp/Threads.html) — thread switching and per-thread bindings.
- Kept: emacs-async README (https://raw.githubusercontent.com/jwiegley/emacs-async/master/README.md) — `async-start`.
- Kept: GPUI `executor.rs`, `app/context.rs`, `app/entity_map.rs` (https://github.com/zed-industries/zed/tree/main/crates/gpui/src) — spawn, `WeakEntity::update`.
- Kept: Neovim `lua.txt` (https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/lua.txt) — `vim.schedule`.
- Kept: Kotlin coroutines basics (https://kotlinlang.org/docs/coroutines-basics.html) — `withContext`, scopes.
- Kept: Elm guide, Time (https://guide.elm-lang.org/effects/time.html) — subscriptions as a function of the model.
- Kept: Hyperlith `src/hyperlith/core.clj:117-144` (local, `/home/jay/Code/hyperlith`) — batch queue.
- Kept: Gerbil `src/std/sync/{channel,completion}.ss`, `src/std/actor/` (local checkout) — available primitives.
- Kept: Tuna `agents/adr/0003,0004,0017`, `tuna/lib/{jobs,timers}.ss`, `tuna/kernel/loop.ss`, `agents/research/{concurrency-prior-art,rendering/loop-and-external-state}`.
- Deprioritized: search-engine summaries (not used); `v0.19-TODIE` coroutine/event modules (not shipped).

## Next steps
1. Prototype B's `post!` + `job-sleep` + `off-thread` in `tuna/lib/jobs.ss` with a fake-`post!` unit test, then the `proced` demo as acceptance (idle = zero tasks).
2. Decide the four open questions above in a one-page brief before coding.
