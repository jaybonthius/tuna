# Research: Background work in Tuna today, and a direct-style `off-thread`

## Summary

- **Today.** Tuna has two background mechanisms. Jobs (`tuna/lib/jobs.ss`) are callback style: a plain-data job on a cleared-environment root thread whose result is applied by a result task after a validity check. Timers (`tuna/lib/timers.ss`) run a fresh task per tick. A direct-style yield point already exists: `suspend` and `resume!` in `tuna/kernel/loop.ss`. Only the minibuffer uses it, and there is no `sleep-for`/`sit-for`.
- **Feasibility.** `(off-thread proc input)` and `(sleep-for seconds)` can be built as a library on `suspend` plus a thread, with no kernel change. I prototyped both against the built package and they worked. Task cancellation (plugin deactivation) works as wanted; C-g does not cancel a suspended task (§2.3).
- **The one wrinkle.** `resume!` cannot be called from a root thread that lacks the kernel parameter. The library works around it with a relay thread (or `result-poster`). A small kernel addition, `(resumer s)`, would remove the wrinkle but is not needed.
- **Redraw and idle cost.** A sleeping source loop costs no tasks. Each wake costs two loop wakeups and two `redisplay!` calls, which memo and `publish-screens!` turn into no-ops when nothing changed.

All experiments are in `/home/jay/Code/workbench-gerbil/scratch/background-work/`: `offthread.ss`, `source.ss`, `bench.ss`, `bench2.ss`. They ran under `systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 timeout 900 gxi …` with `GERBIL_PATH` and `GERBIL_LOADPATH` pointing at the repo's built `.gerbil`. No repository file was edited. Each gxi run printed its output twice, apparently because `main` ran twice, so numbers from the two copies differ slightly.

---

## 1. Today's mechanics

### 1.1 Tasks, the baton, suspend/resume (`tuna/kernel/loop.ss`, `tasks.ss`)

- **Task object.** A task is a class with id, name, procedure, optional reply, thread, state (`queued|running|suspended|quitting|finished|cancelled`), `suspension`, `quit-requested?`, `interrupts` and `inhibit-depth` (`tasks.ss:27-35`). Each running task is its own Gambit thread, with the `current-task` parameter bound (`loop.ss:438-458`).
- **One baton holder.** The loop thread owns the baton and sets `loop.running` (`loop.ss:438-443`). A task ends by sending `[task-ended: …]` back (`loop.ss:456`), handled at `loop.ss:460-484`.
- **Suspension.**
  - `suspend arm` (`loop.ss:291-306`) is the only yield point. It calls `check-quit`, creates a `suspension` holding a completion, runs `arm` on the baton, sends `[suspended: s]`, then blocks on the completion.
  - The task thread blocks in `completion-wait!`. No baton, no loop work, and no timer is needed for it to wait.
  - It returns the resumed value, or raises the raised value.
  - `on-suspended!` (`loop.ss:505-516`) clears `running`, marks dirty, sets state `suspended`, and adds the task to `loop.waiting`.
- **Resume.**
  - `resume! s v` sends `[resume: s #f v]` (`loop.ss:308`). `resume-quit!` sends `#t` plus a `quit-condition` (`loop.ss:312`).
  - `on-resume!` (`loop.ss:518-522`) records the outcome once, so only the first resumption counts. A resume that arrives before `[suspended:]` is handled, because `on-suspended!` re-checks `s.outcome` (`loop.ss:514-515`).
  - `resume-next!` (`loop.ss:524-533`) makes the task `running`, sets dirty, and posts the completion.
  - **Priority** (`run-ready!`, `loop.ss:391-413`): resumes first, then input (unless a redisplay is overdue), then job results, then redisplay. The loop can only start a new input or result task when no task holds the baton.
- **Dirty marking.**
  - Dirty is set when a task starts (`dispatch!`, `loop.ss:416-433`), ends (`:463`), suspends (`:508`), resumes (`:530`), and when a result task starts (`:407`).
  - Redisplay happens when the queue is empty or at the 0.1 s cap (`redisplay-cap`, `:~150`). Nothing else triggers it.
- **Result poster.** `(result-poster)` (`loop.ss:266-272`) captures the loop thread. It returns a procedure `(name thunk)` that does `thread-send [result: name thunk]`. It is callable from a kernel-less root thread. The loop builds a new task from it (`loop.ss:339-340`) with no `reply`, so it cannot be cancelled with `cancel-task!` once queued.
- **Cancel.** `cancel-task!` (`loop.ss:257`) sends `[cancel:]`. `on-cancel!` (`loop.ss:535-546`) handles it by state:
  - queued: the task never runs;
  - suspended: it resumes with quit;
  - running: `quit-requested?` is set, seen at the next `check-quit` or `suspend` entry.
- **Quit/C-g.**
  - The Input provider classifies C-g as `'interrupt`, which bypasses the queue (`loop.ss:213-223`).
  - `on-interrupt!` (`loop.ss:553-565`): with a running task, it sets `quit-requested?`, starts the grace timer, and force-interrupts on the 2nd press or when the timer expires. **With no running task, the item is enqueued as ordinary input.**
  - A suspended task is therefore not quit by C-g. The minibuffer's C-g is a prompt keymap binding to `abort-minibuffers`, which calls `resume-quit!` (`plugins/minibuffer/plugin.ss:249-251`). The global `keyboard-quit` is just `signal-quit`, which raises in the new command's own task (`plugins/keys/plugin.ss:448`, `tasks.ss:73`).
- **Stop.** `finish-stop!` (`loop.ss:578-…`) force-quits the running task, then resumes each waiting task with quit one at a time.

### 1.2 Task ownership and deactivation (`tuna/kernel/plugins.ss`)

- A context holds a receipt, a list of undo thunks (`plugins.ss:60-63`). `context-defer! ctx undo` pushes onto it (`:98`). On deactivation `run-receipt!` runs the thunks newest first, and a failing undo does not stop the rest (`:103-…`).
- `call-with-context-receipt` registers an undo for the dynamic extent of a body (`:88`).
- `call-with-task-owner ctx proc` (`loop.ss:248-254`) registers `(cancel-task! running)` for the duration of the procedure. The commands contract wraps every command in it (`plugins/commands/contract.ss:61`), so deactivating the defining plugin quits even a command waiting at a prompt (ADR 3 note, 2026-10-14).
- A task started with a bare `spawn-task!` has no owner. The plugin must `context-defer!` a cancel itself.

### 1.3 Jobs (`tuna/lib/jobs.ss`)

- **Group and keys.**
  - `new-job-group ctx` makes a group (key → `job-slot{running,pending}`, `jobs.ss:74-91`). It defers a closer that sets `closed?`, cancels all jobs and clears the table.
  - `job-group-start!` (`:108-138`): a closed group raises. If the key has a running job, the new one becomes `pending`, replacing and cancelling the previous pending one. A running `exact-revision` job whose revision differs from the new job's is cancelled. Otherwise the job runs at once.
- **Cooperative cancellation.** `job-cancel!` flips `state` under a mutex, and the job's thread polls it through `cancelled?` (`:62`, `:143`). Threads are never interrupted.
- **Thread and environment.**
  - `run-job!` (`:148-164`) uses `make-root-thread` with `thread-main`, so the thread inherits no parameters (ADR 3, ADR 9).
  - It captures `(result-poster)` on the baton and `post`s `'job-result` with a thunk that runs `finish-job!` on the baton.
  - `finish-job!` (`:168-182`) starts the key's pending job, then, unless cancelled, applies the result if `valid-result` accepts it.
  - A job failure becomes `(message "Job failed: …")`.
- **Validity** (`:185-194`):
  - `exact-revision`: `JobTarget-job-revision` is unchanged;
  - `target-alive`: the target still exists;
  - `rebase`: `JobTarget-job-rebase target result revision`, which returns `(list adjusted)` or `#f`.
- **Plain data** is by convention only. Nothing checks input or result (§2.4).

### 1.4 Timers (`tuna/lib/timers.ss`)

- `context-run-with-timer! ctx seconds repeat proc` (`:221-233`) spawns a countdown thread via `spawn-thread`, so it keeps the kernel parameter.
- On expiry the thread calls `spawn-task!` to run `timer-callback` (`:261-278`). The callback records `self` in `t.tasks` and runs the procedure under `unwind-protect`.
- `cancel-timer` (`:250`) messages the thread and `cancel-task!`s every callback task.
- `restart-timer` (`:245-247`) re-arms a one-shot timer unless it is cancelled or still counting. Session uses it, reset by `task-finished-hook`, to save two seconds after the last task (`plugins/session/plugin.ss:289-295`).
- **A timer tick is a full new task** (thread, hooks, dirty, redisplay), not a resume.

### 1.5 `read-string` suspension (`plugins/minibuffer/plugin.ss`)

- `ask!` (`:~150-170`) builds the prompt buffer and view, then calls `(suspend (lambda (s) (set! p.waiting s) (setup …)))` inside `unwind-protect`, with `end-prompt!` as cleanup.
- RET calls `prompt-exit!`, which calls `(resume! self.waiting value)` on the baton (`:111-113`). C-g calls `resume-quit!` (`:249-251`).
- Deactivating the minibuffer plugin resumes every prompt with quit (`:259-262`).
- This is the only direct-style yield point in the tree. `grep` for `(suspend` finds only this one outside tests.

### 1.6 Who uses jobs today

Grep over all `.ss` files, excluding tests of the lib itself:

- `tests/support/digit-highlighter.ss:56-76`: a demo plugin that starts a `rebase` job per text, with key `['highlight-digits (text-id t)]`, from `after-change-hook`. It sleeps in 20 ms slices using the cancel check, and applies `set-highlights!`.
- `tests/integration/editor-test.ss:46, 76-86`: the same shape with a gated job, in tests.
- `plugins/buffers/plugin.ss:54` implements `JobTarget` for `default-text`. `plugins/buffers/contract.ss` offers `text-changes-since`, `relocate-position`, and `rebase-job-result`.
- **No shipping plugin uses jobs.** The jobs-test and boundary-test also reference the lib.
- **Timers**: only `plugins/session/plugin.ss:289-295`.
- **`spawn-task!`/`result-poster`** are otherwise used by `config-blocks.ss:39` and `plugins/web/plugin.ss:616, 630`.

---

## 2. Feasibility of `off-thread` without kernel change

### 2.1 Construction and measurement (prototype, `offthread.ss`, `bench.ss`)

**Variant A** uses only public API:

```scheme
(def (off-thread proc input)
  (let (r (suspend (lambda (s)
            (let (post (result-poster))                      ; captured on baton
              (thread-start!
               (make-root-thread
                (cut thread-main
                     (lambda ()
                       (let (o (with-catch (lambda (e) (cons #t e))
                                           (lambda () (cons #f (proc input)))))
                         (post 'off-thread-result (lambda () (resume! s o))))))
                'tuna-off-thread))))))
    (if (car r) (raise (cdr r)) (cdr r))))
```

**Why the extra hop is needed (direct evidence).** A root thread has no kernel parameter. `resume!` calls `send-to-loop!` → `(the-kernel)` (`loop.ss:~170`), and `current-kernel` defaults to a global `(new-kernel)` (`state.ss:37`). The worker therefore cannot call `resume!`; at best it would hit the wrong kernel. `result-poster` exists for this (it captures the loop thread). The cost is one extra task per call.

**Variant B** avoids the extra task. A relay thread is created by `spawn-thread` on the baton, so it inherits the kernel. The root worker sends the outcome to it, and it calls `resume!`.

**Results on the working prototype** (interpreted gxi, not compiled):

| Check | Result |
|---|---|
| Value | `(off-thread (λ (x) (* x 2)) 21)` returns 42 |
| Exception | `(error "boom" 1)` raises in the calling task, caught by `with-catch` in task code (`(caught boom)`) |
| Baton released while waiting | A 0.5 s worker and a queued `other` task: `other-ran` was logged before `slow-done` |
| Per-call round trip | A ≈ 3–11 µs, B ≈ 3–8 µs, bare suspend + `spawn-thread` + `resume!` ≈ 1.4 µs. Two runs disagreed on which of A and B was faster, so treat them as equal at about 10 µs |
| Starvation | 300 000 trivial calls: input submitted 50 ms in ran at ≈ 55 ms for both A and B, so no starvation observed. By `run-ready!` order, B's resumes outrank input, so a race is theoretically possible. A's result tasks rank below input |
| 500 queued tasks, each suspended on a 1 s worker | Fine; each is one green thread |

These overheads are dwarfed by any real read.

### 2.2 How exceptions travel

`resume!` has no raise flag, only `resume-quit!`. So the worker catches everything and the outcome is `(cons raised? value-or-exception)`, rethrown by the caller's thread after `suspend` returns. This costs the worker's backtrace, but the exception object and message survive. Variant: add the worker's `exception-summary` for a message.

### 2.3 Quit, C-g and deactivation while suspended

- **Plugin deactivation:** works if the task is owned.
  - A source loop is spawned with `spawn-task!` plus `(context-defer! ctx (λ () (cancel-task! t)))` (shown in `source.ss`), or runs inside a command with `call-with-task-owner`.
  - `on-cancel!` resumes the suspended task with quit (`loop.ss:535-546`). The `suspend` call raises `quit-condition`, `unwind-protect` cleanups run, and the task ends as `'quit`. The worker keeps running, but its later `resume!` is ignored (`on-resume!` ignores the second outcome, and the `task-suspension s` check at `:520`). Its result is dropped.
  - Experiment: after `deactivate-plugin!` there were zero redisplays in 1 s, so the loop was truly idle.
  - A queued A-variant result task still runs once and is harmless.
- **C-g while suspended in `off-thread`:** it does nothing to the task.
  - Experiment: `slow2` was suspended on a 1 s worker, the quit item was submitted, and the task completed normally (`(1 cleanup)`).
  - This follows the code: no running task means the interrupt is queued as input (`loop.ss:553-565`). It matches Emacs semantics only partly, because `read-string` handles C-g through its prompt keymap.
  - **Mitigation needing no kernel change:** an `off-thread` variant with `timeout:`; and the owning plugin or command binds an `abort` command to `resume-quit!`. Or the library keeps a list of waiting off-thread suspensions and a `quit-waiting-off-threads` command. ADR 3 should say if C-g should quit suspended `off-thread`s.
- **`sleep-for`/`sit-for`**: none exists (grep shows only ADR 3 text and the capability audit's J5/D7).

### 2.4 Enforcing "plain data only"

- **Environment**: `make-root-thread` + `thread-main` gives a cleared dynamic environment, same as jobs (`jobs.ss:155-158`).
- **A closure cannot be checked.** `plain-value?` (`tuna/lib/memo.ss:57-64`) accepts numbers, strings, symbols, keywords, chars, booleans, `()`, and pairs/vectors of them. So the safe signature is `(off-thread proc input)`, with `proc` a top-level function and `input` plain.
- **Debug check.** Memo already does this in test mode: `check-piece!` raises "Memo inputs must be plain data" (`memo.ss:200-208`), gated by a flag set by `set-memo-checking!` (`tests/support/kernel.ss`).
  - Inference: `off-thread` can check `(plain-value? input)` before spawning and `(plain-value? result)` before resuming (on the worker; raised into the caller) when checking is on. It costs O(size).
  - `plain-value?` lives in `tuna/lib/memo`, and the checking flag is memo's `checking?` (`memo.ss:~72`).
  - **Recommendation:** move `plain-value?` into a tiny lib shared by memo and the new module (no new dependency from `off-thread` onto drawing code).
  - Mutable objects, hash tables and `text` records are not plain, which matches ADR 3's "snapshots, revisions, values".

---

## 3. A `sleep-for` yield point

None exists. I built one from `suspend` and `spawn-thread` and ran it in `source.ss`:

```scheme
(def (sleep-for (seconds : :real))
  (let (relay #f)
    (unwind-protect
      (suspend (lambda (s)
                 (set! relay (spawn-thread
                              (lambda () (unless (thread-receive seconds #f) (resume! s #t)))
                              'tuna-sleep))))
      (when relay (thread-send relay 'cancel)))))
```

- Inheriting the kernel through `spawn-thread` is what lets `resume!` work, as in the timers lib (`timers.ss:237`).
- A quit while asleep unwinds and cancels the relay, so cancelled sleepers do not linger.
- `sleep-for` does not use `timers.ss`. A timer spawns a task per tick (`timers.ss:265`), so it is the wrong shape.

**15-line `/proc` source loop** (ran in `source.ss`):

```scheme
(def (read-loadavg path)                      ; plain in, plain out; runs off-thread
  (call-with-input-file path read-line))

(defplugin (loadavg ctx) "Keeps load average current."
  (let (t (spawn-task! 'loadavg-source
            (lambda ()
              (let lp ((last #f))
                (let (now (off-thread read-loadavg "/proc/loadavg"))
                  (unless (equal? now last)
                    (set-node-attribute! load-node 'content now))   ; baton, plain-equal? cutoff
                  (sleep-for 2.)
                  (lp now))))))
    (context-defer! ctx (lambda () (cancel-task! t)))))               ; deactivation stops it
```

Measured with a 0.05 s period: 36 distinct updates in 2 s (the pid field changes each read), 80 `redisplay!` calls (two per iteration, §5), and 0 after deactivation. The prototype's `read-loadavg` used `read-file-string` with `with-catch`.

---

## 4. Staleness in direct style

| Today (jobs.ss) | Direct style |
|---|---|
| `exact-revision`: drop if the revision moved (`:187`) | After resuming, `(unless (= (text-content-revision t) rev) …)` |
| `target-alive` (`:190`) | `(text-live? t)` (`Buffers`, `contract.ss:~412`) |
| `rebase` (`:192`) | `(def (rebase-onto t rev result) (let (cs (text-changes-since t rev)) (and cs (rebase-job-result result cs))))`; both exist in the buffers contract (`contract.ss:416-425`, `:257-265`) and return `#f` when the journal no longer reaches back |

- **Inference:** this is a few lines in the task, and it makes "re-read state after a yield" explicit, which ADR 3 already requires for any yield. A `(rebase-onto …)` helper belongs in the buffers contract or a `lib` module that imports only it, not in the kernel.
- **Job keys, "newest wins, one running, one pending":**
  - Needed for highlighting driven by `after-change-hook`: a hook must not spawn one task per keystroke. In direct style the hook sets a per-text `dirty-rev` and wakes one long-lived per-text worker. That worker is a loop doing `(sleep-for delay)`, `(off-thread digit-spans snapshot)`, then rebase and apply.
  - That is the same "one running + one pending" slot, expressed as "latest revision wanted". The job lib's slot logic is still the simplest generic implementation. A thin direct-style wrapper `(job-await group key …)` could reuse it instead of replacing it.
  - Cooperative cancel (`cancelled?`) also needs a path for `off-thread`. The simplest is a `cancelled?` thunk passed as a second argument to `proc`, backed by a flag that the `unwind-protect` in `off-thread` sets when its caller unwinds.
- **Not needed** for sources (poll loops): the single loop is the single slot.

---

## 5. ADR 17 and redraw/idle cost

- **A mutation from the resumed task is enough.** `resume-next!` sets `dirty?` (`loop.ss:530`), and `on-task-ended!` sets it again (`:463`). So the loop redisplays after the task suspends or ends.
- **No explicit redisplay is needed.** Memo-reading code redraws only changed pieces, since renderers read sources through the contract accessors (ADR 17).
- **Equal updates cost nothing.** `set-attribute!` compares with `plain-equal?` and skips `stamp!` if equal (`plugins/buffers/plugin.ss:315-320`). No source revision moves, so memo reuses the same HTML. `publish-screens!` sends nothing for an identical screen (`plugins/web/plugin.ss:~236-243`).
- **What an idle source costs.**
  - While asleep there is no task and no loop work: the loop blocks in `thread-receive` (`receive-message`), and the suspended task is a blocked thread plus a relay thread.
  - Each wake does an off-thread round trip (A: a result task plus a resume; B: one resume). Each causes a `redisplay!` call (~2 per loop iteration measured: 80 per 2 s at 40 iterations).
  - Each redisplay costs `render-screen` per open tab. That is memo validation plus an identity compare, which ADR 17 puts at ~0.01–0.14 µs per piece.
  - ADR 17's "idle is idle" is not yet true in the kernel. Redisplay is still called after every task. Reducing that is a display/web-plugin matter (the tab-keeper already notes "any task, even one doing nothing, is followed by a redisplay", `plugins/web/plugin.ss:~606`), not a kernel one.
- **Order of arriving renders:** after `suspend`, the task holds the baton and mutates state. The next redisplay sees one consistent state.

---

## 6. Risks

1. **C-g cannot cancel a suspended `off-thread`** (§2.3). A hung worker leaves a stuck task. Mitigate with a timeout argument, an abort command, and loop-level cancellation on plugin deactivation.
2. **Leaked worker threads.** A cancelled task's worker runs to completion. Cooperative `cancelled?` is the same trade-off ADR 3 accepted for jobs.
3. **Resume priority.** `resumes` outrank input (`loop.ss:~395`). A task looping `(off-thread f x)` with a trivially fast `f` and no sleep could in theory delay input. I saw none in 300 000 iterations, but with `sleep-for ≥ ~10 ms` it is moot.
4. **Many suspended tasks.** Each costs one thread and one completion (plus a relay thread in B or the sleep case). 500 was fine. `loop.waiting` is a list with `remq` on resume (`loop.ss:~526`), O(n) per resume, which is fine at hundreds.
5. **Exception fidelity.** The caller sees the original exception object but not the worker's backtrace.
6. **SMP.** Variant A is SMP-safe: it shares only plain data and message passing, and a worker only posts through `thread-send`. Variant B's relay mutates nothing shared. A mutex-guarded cancel flag is needed on the worker side. Kernel loop fields are baton-confined.
7. **Hidden dependency on kernel parameter.** `current-kernel` has a default `(new-kernel)` (`state.ss:37`), so a root thread that calls `resume!` hits the wrong kernel silently instead of failing. This is the main footgun for library authors.
8. **Quit inside `suspend` timing.** `suspend` calls `check-quit` first (`loop.ss:~297`), so a quit requested before it surfaces immediately, and inhibit-quit regions will defer it as designed.

---

## 7. API sketch (no kernel change)

Add `tuna/lib/background.ss`, a library that uses only the public kernel API and imports no plugin. `plain-value?` comes from a lib shared with memo.

```scheme
;; Run (PROC INPUT) on a worker thread with a cleared dynamic environment and
;; return its value, or raise its exception. Suspends the calling task
;; (releases the baton); call from a task. INPUT and the result must be plain
;; data; checked when memo/test checking is on. CANCELLED? is a thunk callable from
;; the worker, true once the caller has unwound (quit, deactivation).
(def (off-thread (proc : :procedure)      ; (input cancelled?) -> result
                 (input : :t)
                 timeout: (timeout :? :real := #f))
  => :t)

;; Suspend the calling task for SECONDS, releasing the baton. A quit unwinds it.
(def (sleep-for (seconds : :real)) => :void)

;; The long-lived pattern, as a convenience: spawn a task that loops
;; read -> compare -> apply -> sleep, owned by CTX (cancelled on deactivation).
;; READ runs off-thread (plain in/out); APPLY runs on the baton only when the
;; value differs (equal?) from the last one.
(def (context-run-source! (ctx : context) (name : :symbol)
                          read: (read : :procedure)   input: (input : :t)
                          apply: (apply : :procedure) every: (seconds : :real))
  => task)

;; Staleness helper beside the buffers contract:
(def (rebase-onto (t : text) (revision : :fixnum) (result : :t)) => (Maybe :pair))
;;   = (let (cs (text-changes-since t revision)) (and cs (rebase-job-result result cs)))
```

**Implementation note.** Use variant A if the library must not create threads that inherit a kernel, or variant B if the extra result task per call matters. Both are about 10 µs.

**Minimal kernel change, only if wanted.** `(resumer (s : suspension)) => procedure` would capture the loop thread in a closure, as `result-poster` and `input-submitter` already do, so any thread can resume without the kernel parameter. This removes the relay and result-task detour and the footgun in §6.7. It adds no feature, only makes `resume!` honour its own "Callable from any thread" comment (`loop.ss:308`). It fits ADR 12 because it is a general capability and not shaped around one consumer, but it is optional, since the library works without it.

**Two ADR clarifications to record.** (a) What C-g does to a task suspended in `off-thread` (§2.3). (b) That `sleep-for` is built on `suspend` and not timers (§3).

---

## Contradictions

- ADR 3's "Redisplay … only after a task completes or suspends" and ADR 17's "idle is idle" differ in practice. Each wake of a source costs ~2 redisplay calls, cheap due to memo but not zero. Not resolved here.
- `resume!`'s comment says "Callable from any thread" (`loop.ss:~307`). In the experiments it was not callable from a root thread without the kernel parameter. This is the contradiction §2.1 works around.

## Missing evidence

- The two benchmark runs disagreed on whether A or B is faster (A 10.9/3.0 µs, B 3.1/8.1 µs) and ran interpreted (gxi), not compiled. Treat as ≈10 µs per call. I did not measure compiled code or load-test many concurrent `off-thread`s.
- I did not run the repo's own test suite; all experiments were in scratch.
- I did not measure the real cost of the web plugin's `render-screen` on a no-change wake, only the number of `redisplay!` calls with a stub display.
- SMP behaviour of Gerbil 0.19-dev threads was not tested.

## Sources

- Kept: `tuna/kernel/loop.ss`, `tuna/kernel/tasks.ss`, `tuna/kernel/plugins.ss`, `tuna/lib/jobs.ss`, `tuna/lib/timers.ss`, `tuna/lib/memo.ss`, `plugins/minibuffer/plugin.ss`, `plugins/buffers/{plugin,contract}.ss`, `plugins/web/plugin.ss`, `plugins/commands/contract.ss`, `plugins/keys/plugin.ss`, `plugins/session/plugin.ss`, `tests/support/digit-highlighter.ss`, `tests/integration/editor-test.ss`, ADR 3 and ADR 17, `agents/research/capability-audit/03-runtime-and-environment.md` (J5, D7).
- Kept: scratch experiments listed above.
- Deprioritized: `agents/research/` generally (evidence, not decisions).

## Next steps

- Decide the C-g semantics for suspended `off-thread` and record them in ADR 3.
- Move `plain-value?` to a shared lib and decide whether the debug check is always on in test kernels.
- Prototype the compiled benchmark and the per-text highlighter as one direct-style loop to compare with the jobs lib.