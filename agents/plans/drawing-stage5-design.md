# Drawing stage 5 design: work off the editor thread, sources, and `proced`

**Status:** design for review (2026-10-22); not built. Stage 5 of `agents/plans/drawing-only-what-changed.md`, under the owner-approved brief `docs/briefs/2026-10-background-work.md` (API decided), ADR 3, 4, 12, 16 and 17. Evidence: `agents/research/background-work/` (prototypes in `/home/jay/Code/workbench-gerbil/scratch/background-work/`). Line numbers: Tuna at `28b889d`.

The plan's invariant "the kernel does not change" is superseded for one bug fix by the later approved brief (section 1). Section 10 lists the choices this note makes that the brief does not; each needs the reviewer's yes.

## 1. Kernel fix: every "any thread" entry point reaches its own loop

**The bug.** `send-to-loop!` finds the loop through `(the-kernel)` (`loop.ss:168-170`). A root thread (`make-root-thread`, as jobs use, `jobs.ss:155-158`) has the parameter's default kernel (`state.ss:37`), not its creator's. In production that default *is* the kernel, by accident; under `call-with-fresh-kernel` (`tuna/tests/support/kernel.ss:19`) it has no loop, so `resume!` (`loop.ss:308`), `resume-quit!` (`:312`), `spawn-task!` (`:241`) and `call-on-editor-loop` (`:229`) raise "The editor loop is not running", and `cancel-task!` (`:257`) silently does nothing. The web plugin works around it with a thread started from the plugin (`web/plugin.ss:605-609`).

**The fix: an operation on an object goes to that object's loop; an operation without one goes to the caller's loop.** No export, signature or message changes.

| Entry point | Today | After |
|---|---|---|
| `resume!`, `resume-quit!` | `(the-kernel)` | the suspension's loop thread, recorded by `suspend` (which already holds `loop`, `:296`): new private field `(loop-thread : :thread)` in `suspension` (`:99-102`) |
| `cancel-task!` | `(the-kernel)`, no-op when its loop is not running | the task's loop thread: new field `(loop-thread :? :thread)` in `task` (`tasks.ss:29-40`, not exported by the facade), set by `spawn-task!` and `call-on-editor-loop` before sending, and by `start-task!` (`:438`) for tasks the loop builds (input and results). A task never queued falls back to the caller's loop, as today |
| `spawn-task!`, `call-on-editor-loop`, `discard-input` | `(the-kernel)` | `(caller-loop)`: the loop whose thread group contains the calling thread, otherwise the kernel parameter's loop; raises "The editor loop is not running" as today when that loop has stopped (`loop.stopping` set) |

- **Thread group.** `start-editor-loop!` (`:192`) starts the loop thread in its own group, `(make-thread-group loop)`, the loop object as the group's name. Gambit gives a new thread its creator's group, root threads included (checked with `gxi`: a `make-root-thread` started inside a group reports that group and the default parameter). So every task thread, every job thread a task starts, and every worker below belong to the loop that runs them. `caller-loop` walks `thread-group-parent` from `(thread-thread-group (current-thread))` until a group named by an `editor-loop`. Public Gambit API; no `##` primitive.
- **A stopped loop.** `thread-send` to a finished thread returns silently (checked), which matches today's quiet `resume!` and `cancel-task!` after a stop. `spawn-task!` and `call-on-editor-loop` keep raising.
- **Limit (documented in the comments):** a thread that holds no task or suspension and was started outside every loop's threads (for example by a plugin before the loop starts) still finds its loop through its kernel parameter. That is right in production, where there is one kernel.
- **ADR 12 amendment** (kernel contract, "Changes to the kernel"): two private fields and a thread group, adding no capability: the documented "Callable from any thread" now holds. `kernel.ss` exports are unchanged.
- **Tests** (`tuna/tests/unit/loop-test.ss`; 1-4 fail today, and 5's `resume!` raises today):
  1. a root thread started by the test thread calls `resume!` on a waiting task's suspension: the task resumes with the value;
  2. the same with `cancel-task!`: the waiting task ends as quit;
  3. a task starts a root thread that calls `spawn-task!`: the new task runs on the same loop;
  4. a task starts a root thread that calls `call-on-editor-loop`: it returns the value;
  5. after `stop-editor-loop!`, `resume!` and `cancel-task!` from a root thread return without raising.

## 2. Library placement

| Module | Exports | Imports |
|---|---|---|
| **new `tuna/lib/plain-data.ss`** | `plain-value?`, `plain-equal?` (moved from `memo.ss:52-70` unchanged), `set-plain-data-checking!`, `plain-data-checking?`, `(check-plain-data! (what : :string) (x : :t)) => :void` (raises `"<what> must be plain data"` when checking is on and X is not) | `:gerbil` only |
| `tuna/lib/memo.ss` | drops `plain-value?`, `plain-equal?` from its exports | `plain-data` |
| `tuna/lib/jobs.ss` | adds `job-sleep`; `job-group-start!` gains `coalesce:`; `run` gains `post!` (section 6) | unchanged (jobs keep plain data by convention: ADR 3 lets them take snapshots) |
| **new `tuna/lib/background.ss`** | `off-thread`, `background-cancelled?`, `sleep-for`, `background-waiting-tasks`, `quit-background-wait!`, `context-start-source!` | `:tuna/kernel`, `jobs`, `plain-data` |

- Callers of `plain-equal?` import `plain-data`: `plugins/buffers/plugin.ss:317`, `plugins/buffers/contract.ss:1102`, `plugins/buffers/tests/support/toy-buffers.ss:312`. The `plain-equal?`/`plain-value?` case of `memo-test.ss:132-143` moves to a new `tuna/tests/unit/plain-data-test.ss`. No re-export.
- `call-with-fresh-kernel` (`tuna/tests/support/kernel.ss:18-27`) turns plain-data checking on and off beside memo's. A module flag, not a parameter, so root threads see it (memo does the same, `memo.ss:74`).
- Sources live in `background.ss`, not `jobs.ss`: they are the brief's API over jobs, and the plan's "a source helper only after three users" is superseded by the approved brief.
- `build.ss`: `"lib/plain-data"` before `"lib/jobs"`, `"lib/background"` after `"lib/memo"`.

## 3. `off-thread`

```scheme
;; Run (PROC INPUT) on a new root thread (no parameters) and return its
;; value, or raise what it raised, in the calling task; the task waits
;; meanwhile and the editor runs other input. Call from a task. With
;; TIMEOUT, a wait longer than TIMEOUT seconds raises an error instead.
(def (off-thread (proc : :procedure) (input : :t) timeout: (timeout :? :real := #f)) => :t)

;; Whether the caller of the off-thread call running PROC on this thread
;; has stopped waiting (quit, cancelled, timed out), or the source whose
;; read runs on this thread has stopped. #f on any other thread.
(def (background-cancelled?) => :boolean)
```

- **Mechanism.** `(unwind-protect (suspend arm) (cancel! flag) (remove-wait! id))`. ARM, on the baton, records the wait (section 5) and starts the worker: `make-root-thread` with `thread-main`, named `tuna-off-thread`. The worker binds the library's own `current-cancel-flag` parameter (so `background-cancelled?` works; the environment still holds nothing of the editor), runs `(with-catch (lambda (e) (cons #t e)) (lambda () (cons #f (proc input))))`, and calls `(resume! s outcome)` itself, which section 1 makes work. One message per call: no relay thread, no result task (the prototype's variant A cost one task per call, `tuna-mechanics.md` §2.1). After `suspend` returns, the caller raises `(cdr outcome)` when `(car outcome)`, otherwise returns it. The worker's backtrace is lost; the exception object is kept.
- **Plain data, test mode.** `(check-plain-data! "off-thread input" input)` in the caller before ARM; on the worker, a non-plain result becomes the outcome `(cons #t <error "off-thread result must be plain data">)`, raised in the caller. Exceptions cross unchecked. Text snapshots are not plain data under the brief's definition, so a command that needs one off the thread uses a job (risk 3).
- **Cancellation.** The flag is a mutex-guarded boolean, as jobs' (`jobs.ss:58-63`), set by the `unwind-protect` cleanup whenever the caller leaves the wait: quit, `cancel-task!`, a timeout, or deactivation. The worker is never interrupted; it runs until PROC returns, and its late `resume!` is ignored (`on-resume!` keeps the first outcome, `loop.ss:518-522`).
- **Timeout.** ARM also starts a timer thread (`spawn-thread`, named `tuna-off-thread-timeout`) that waits `(thread-receive timeout #f)` and on expiry calls `(resume! s (cons #t (timeout-error)))`, an `Error` reading "off-thread timed out after N seconds". The cleanup sends it `'cancel`. First resumption wins.
- **Owner deactivated mid-wait.** A command's task belongs to its plugin (`call-with-task-owner`, `commands/contract.ss:61`); deactivation runs `cancel-task!`, which resumes the wait with quit (`loop.ss:542-543`), the cleanup sets the flag, and the command ends as quit. A bare `spawn-task!` task has no owner and is the plugin's to cancel (`context-defer!`), as today.
- **Priority.** Resumes outrank input (`loop.ss:396-397`); a tight loop of trivial `off-thread` calls could in theory delay typing (none seen in 300,000 calls, research §2.1). Documented, not mitigated.

## 4. `sleep-for`

```scheme
;; Wait SECONDS in the calling task while the editor runs other input
;; (Emacs `sleep-for`). Call from a task. SECONDS <= 0 returns at once
;; after a quit check.
(def (sleep-for (seconds : :real)) => :void)
```

`(unwind-protect (suspend arm) (thread-send relay 'cancel) (remove-wait! id))`; ARM records the wait and starts the relay with `spawn-thread`, named `tuna-sleep`: `(unless (thread-receive seconds #f) (resume! s (void)))`. Not built on `timers.ss`: a timer runs a new task per tick (`timers.ss:67-73`). A quit or cancel unwinds the wait and the cleanup ends the relay at once, so no thread lingers past its wait; the relay's own `resume!` after expiry is its last act.

## 5. `C-g` quits a command waiting in `off-thread` or `sleep-for`

**Today.** `C-g` arrives as an interrupt (`keys/plugin.ss:341-347`). With a task running, the loop asks that task to quit (`loop.ss:553-561`). With none, the item is queued (`:562`) and resolved by the keys plugin: a keymap binding wins, as the minibuffer's `C-g` → `abort-minibuffers` → `resume-quit!` (`minibuffer/plugin.ss:248-257`), otherwise `keyboard-quit`, which is `signal-quit` in its own new task (`keys/plugin.ss:252-258, 448`). A command waiting in a yield point is not running, so nothing reaches it.

**Rule.** When `keyboard-quit` runs and its `C-g` did not cancel a pending prefix, it quits one waiting command: the innermost (most recently started wait) whose command came from the same client, otherwise the innermost of any client (ADR 16: `C-g` stops a running command whichever tab sends it). Only command tasks qualify: a timer's or other task's `sleep-for` is not quit by `C-g`, as Emacs runs timers with `inhibit-quit`. A `C-g` that cancels a prefix does only that (otherwise a tab that types `C-x C-g` would kill a command started elsewhere). A `C-g` typed in a prompt still runs the prompt's `abort-minibuffers`. A running task still takes the interrupt first, as today.

**Placement: no kernel change.** The quit lane already queues `C-g` to the input provider when nothing runs; the rest is the library and the keys plugin.
- `background.ss` keeps the waits, on the baton, newest first: `[(task-id . suspension) ...]`, added in ARM, removed in the cleanup (one list per process: a stopping loop resumes its waiting tasks with quit, `loop.ss:586-593`, which removes them).
  ```scheme
  (def (background-waiting-tasks) => :list)                        ; task ids, innermost first; on the baton
  (def (quit-background-wait! (task-id : :fixnum)) => :boolean)    ; resume-quit! its wait; #f if not waiting
  ```
- The keys plugin records the client of each command task it starts: `command-task` (`keys/plugin.ss:233-238`) puts `(current-task-id) → (box client)` in a new `command-clients` table on entry and removes it in an `unwind-protect` cleanup (per running command, not per-tab state; ADR 16's list is unchanged). `resolve-key!` binds a private parameter `quit-cancelled-prefix?` in the `C-g` task when the session's prefix was pending. `keyboard-quit` becomes: unless that parameter is true, pick from the ids of `(background-waiting-tasks)` that are in `command-clients` the first with this client, else the first, and `quit-background-wait!` it; then `signal-quit` as today. Keys imports `:tuna/lib/background` (a library; allowed).
- Two "Quit" messages may show (the waiting command's end and `keyboard-quit`'s); they say the same.

## 6. Jobs that post several results

```scheme
(def (job-group-start! (group : job-group) (key : :t)
                       input: (input : :t)
                       run: (run : :procedure)            ; (run input cancelled? post!), on the job's thread
                       apply: (apply : :procedure)
                       target: (target :? JobTarget := #f)
                       validity: (validity : :symbol := 'exact-revision)
                       coalesce: (coalesce : :symbol := 'queue))   ; queue or latest
  => job)

;; On a job's thread: wait SECONDS, returning #t, or return #f as soon as
;; the job is cancelled.
(def (job-sleep (seconds : :real) (cancelled? : :procedure)) => :boolean)
```

- **`post!`**, a procedure of one result, callable from the job's thread. Each posted result is applied on the baton by its own result task after the same validity check as a returned one (`valid-result`, `jobs.ss:185-194`), against the job's start revision, so an `exact-revision` job's posts stop applying once the target changes and a `rebase` job's posts are each rebased. A post after cancellation is dropped before it is sent. The returned value is still applied last, as today; `finish-job!` (`:168-182`) splits into slot bookkeeping at the end and a per-result `apply-result!`.
- **`coalesce:`** `'queue` (default) applies every post in order (the loop's results are FIFO, `loop.ss:339-340, 401-405`). `'latest` keeps one unapplied post per job under the job's lock: a post replaces it and sends a result task only when none is outstanding, so a slow baton costs one task, not a backlog.
- **No target.** `target:` becomes optional: a job without one applies every result until cancelled, and `validity:` is ignored. Sources need this; it avoids a dummy `JobTarget`.
- **`job-sleep`** waits on the job thread's own mailbox (`thread-receive` with the remaining time). `job-cancel!` (`:143-145`) and the pending replacement (`:131-132`) send `'cancel` to a running job's thread (new field `(thread :? :thread)`, set in `run-job!`), so a cancelled sleeper returns within microseconds, not after a poll slice.
- **Callers updated for the arity:** `tests/support/digit-highlighter.ss:60`, `tests/integration/editor-test.ss:82`, `tuna/tests/unit/jobs-test.ss:67, 78, 110` gain an ignored `post!` parameter. Nothing else changes in the digit highlighter.
- **ADR 3 amendment:** "A job may post several results" now names `post!`, `coalesce:` and `job-sleep`.

## 7. Sources

```scheme
;; Start a source of CTX's plugin named NAME: on its own job thread, read
;; (READ INPUT) now and then every EVERY seconds; when the reading is not
;; COMPARE to the last one, post it, and (APPLY READING) runs on the baton.
;; Deactivating the plugin, or job-cancel! on the returned job, stops it,
;; and drops what it had posted but not applied.
(def (context-start-source! (ctx : context) (name : :symbol)
                            every:   (every   : :real)
                            read:    (read    : :procedure)    ; input -> reading, plain data
                            apply:   (apply   : :procedure)    ; reading -> void, on the baton
                            input:   (input   : :t := #f)
                            compare: (compare : :procedure := equal?))
  => job)
```

- **A job.** One `new-job-group` from CTX per call, key NAME, no target, `coalesce: 'latest`: a reading is whole, so only the newest unapplied one matters. (One deferred closure stays in CTX's receipt per call, as each `context-run-with-timer!` adds one, `timers.ss:38`.)
- **The loop, on the job thread:** read; unless cancelled or `(compare last reading)`, `post!` it; remember it as `last`; `(job-sleep every cancelled?)`, and stop when that returns #f. `background-cancelled?` is bound to the job's check. The first read is immediate; no option (no user wants a delayed first read).
- **"Posts only differences"** means a reading is posted only when it differs; `apply` updates its rows, and the buffers' equality cutoff (`set-node-attribute!` stamps nothing for an equal value, `buffers/plugin.ss:313-320`) makes only changed rows redraw. Row-level deltas on the job thread would be a second abstraction with no second user.
- **Apply** runs inside `with-inhibit-quit`, as Emacs runs process filters, so a `C-g` that lands during an apply does not lose the reading (the source compares with what it read, not with what was applied, so a lost reading would stay stale until the next change).
- **Errors in READ or COMPARE, and a non-plain reading in test mode:** the source keeps running and retries next period. It posts a failure once per streak (on the first failure after a success or at start), shown as the message "Source NAME failed: <summary>"; a later differing reading posts normally. A `/proc` read fails transiently when a process exits mid-read. Errors in APPLY are task errors, reported by the loop, and do not stop the source.
- **Plain data, test mode:** `check-plain-data!` on INPUT at start, on each reading on the job thread.
- **Idle is zero:** equal readings post nothing, so the editor runs no task; the job thread wakes once per period. Test below.

## 8. The `proced` plugin

New package `plugins/proced/` (`gerbil.pkg`, `plugin.ss`, `tokens.css`, `rules.css`, `tests/`); no contract (nothing else uses it). Added to `build.ss`. Owns everything about processes; the measurements are outside it.

- **Options** (`defplugin-options`, `tuna/lib/plugin-options.ss`): `root` (string, default `"/proc"`; tests point it at a fixture directory), `interval-ms` (integer 10–60000, default 1000).
- **Reading:** `(read-processes (root : :string)) => :list`, a top-level procedure of plain data: for each numeric directory under ROOT, parse `stat` (comm between the first `(` and the last `)`; state; utime + stime; rss), skipping a pid whose file vanished. A row is `[pid command state time rss]` with TIME (`m:ss`, ticks / 100, Linux's fixed `USER_HZ`) and RSS (MiB to one decimal, 4 KiB pages) already formatted, so a value that would display the same compares equal ("round in read", brief). Sorted by pid. No %CPU: it needs two readings (section 10).
- **Command `proced`** ("Show *Processes*"): creates the buffer the first time (a `proced` node, `items: 'children`, a `proced-header` node then one `proced-row` per pid, `items: 'whole`, as `demo/rows.ss:39-41`), shows it in the selected view, and starts the source (`every:` the option, `input:` ROOT). `kill-buffer-hook` (`buffers/contract.ss:1145`) on that buffer `job-cancel!`s it, so a closed `*Processes*` reads nothing; deactivation stops it too.
- **Apply:** a `pid → node` table. Existing pid: `(set-node-attribute! node 'row row)`, a no-op when equal. New pids: new nodes. When the pid list changed, `set-node-children!` once. Gone nodes are dropped from the table; their pieces are swept by memo's mark and sweep.
- **Renderers:** `proced-row` → `(div (@ (class "proced-row")) (span (@ (class "proced-pid")) …) …)`, one span per column; `proced-header` the same with column names. Columns by CSS grid in `rules.css`; widths and colours as tokens named after the classes in `tokens.css` (`agents/guides/html-css.md`). Not a `<table>`: the scroller places items between spacer elements, which a table cannot contain.
- **Demo:** `(use-plugin proced)` in `demo/init.ss` with `(keymap-set "C-c P" 'proced)` in its `config:`, and a demo command in `demo/demo.ss`, `C-c W` `wait-demo`: `(off-thread slow-answer 3)` then a message, to try `C-g` in the browser.

## 9. Measurements (outside the plugin)

| Claim | How | Where |
|---|---|---|
| rows drawn = rows changed, 1 and 2 tabs | fixture root of 50 pids, `interval-ms` 20, web transport; bind `current-memo-draw-observer` around `with-web-tuna` (the loop thread and every task inherit it; checked with `gxi`); after the first screen, change 2 pids' `stat`; count distinct `['node view row-id]` keys of row nodes drawn: 2, with one tab and with two | `tests/integration/proced-test.ss` |
| idle is zero | same set-up as `tests/integration/idle-test.ss` (task counter on `task-started-hook`, views drawn, nothing sent) with `*Processes*` shown and the fixture unchanged for 3 s (150 reads): 0 tasks, 0 views, 0 bytes; then one change is drawn | same file |
| source idle at the library level | a source every 0.02 s with a constant reading: 0 tasks and 0 redisplays in 0.5 s; one change → one apply | `tuna/tests/unit/background-test.ss` |
| 60 s idle | the same as the integration test, 60 s at `interval-ms` 1000, against real `/proc` minus churn (fixture) | scratch bench `scratch/drawing-5/bench-proced.ss`, reported in the as-built notes |
| typing p95 unchanged | 200 keys at 50 ms intervals through the web client, time from post to the screen showing the key; with proced off, and with a fixture of 200 pids all changing every 100 ms; pass when p95 rises by at most 10 % or 2 ms | scratch bench |
| memory flat under churn | 500 cycles replacing 20 of 200 pids every 20 ms; live heap after `(##gc)` at cycle 100 vs 500 within 5 %; row node count stays 200 | scratch bench |

## 10. Kernel, contracts, choices, risks, steps

**Kernel changes:** section 1 only (two private fields, a thread group, `caller-loop`); no new export. **Contracts changed:** none. Plugins changed: keys (`keyboard-quit`, command clients), buffers (import of `plain-equal?`). New: `plain-data`, `background`, `proced`.

**Choices the brief leaves open (reviewer's yes needed):**
1. `off-thread` calls `(proc input)`, as the brief's sample; the cancellation check is `(background-cancelled?)`, not a second argument (jobs keep theirs).
2. The `C-g` rule of section 5, including "a prefix cancel quits nothing else" and the fall-back to other clients.
3. A timeout raises an error, not quit.
4. Source read errors: report once per streak, keep running.
5. Default coalescing `'queue`; sources use `'latest`.
6. "Posts only differences" = posts a reading only when it differs; rows by equality cutoff.
7. `proced` without %CPU; `target:` optional in jobs; first source read always immediate.

**Risks.**
1. A source's work on the baton is O(rows) per changed reading (200 equality checks; microseconds).
2. Leaked worker threads: a cancelled `off-thread` or job runs to its end (cooperative, ADR 3).
3. Snapshots are not plain data, so `off-thread` cannot take one; the first user that needs one extends `plain-value?` or uses a job.
4. `caller-loop` relies on Gambit thread groups being inherited, including by root threads; a test pins it (step 1, test 3).
5. Under SMP, `loop.stopping` is read off its thread; it changes once, from #f.

**Steps** (each ends with `make test` green under the memory cap, and a commit):
1. Kernel fix and its five loop tests; ADR 12 amendment.
2. `plain-data.ss`, the move, test-mode flag in `call-with-fresh-kernel`; `plain-data-test.ss`.
3. Jobs: `post!`, `coalesce:`, optional target, `job-sleep`; callers updated; `jobs-test.ss`: posts applied in order; `'latest` applies only the newest while the baton is held; per-post `exact-revision` drops after a change; cancel drops unapplied posts; `job-sleep` returns #f within 50 ms of cancel; a target-less job applies. ADR 3 amendment.
4. `background.ss`: `off-thread`, `sleep-for`, waits; `background-test.ss`: value; raised error; baton free while waiting; quit sets `background-cancelled?` and drops the late result; timeout; plain-data checks on input and result; non-task call raises; owner deactivation quits; `sleep-for` resumes, and after a cancel no `tuna-sleep` thread is alive (Gambit `thread-group->thread-list` from the primordial group).
5. `keyboard-quit`: `plugins/keys/tests/unit/keyboard-quit-test.ss` (commands, keys, test input with two clients): same-client wait quit; other client's quit when none here; own before other's; prefix cancel quits nothing; a non-command task's sleep is not quit. ADR 3 and `docs/emacs-equivalents.md`: `sleep-for`, `C-g` on waits.
6. Sources in `background.ss`; tests: idle zero; one change one apply; equal readings post nothing; read errors reported once, recovery applies; deactivation stops the thread and drops an unapplied reading (read gated, deactivate, release).
7. `plugins/proced/`, demo binding and `wait-demo`; `plugins/proced/tests/unit/read-test.ss` (fixture parsing, vanished pid, formatting); `tests/integration/proced-test.ss` (section 9 rows and idle; kill-buffer stops reads; churn keeps rows correct).
8. Scratch benches (60 s idle, typing p95, memory churn); as-built notes here.

**Browser check** (`make`, then `.gerbil/bin/tuna --port N --config demo/init.ss`, stopped by PID afterwards): two Chrome tabs through `agent_browser` plus a second browser (Firefox if installed, otherwise reported): `C-c P` in tab A shows `*Processes*`, rows update in both tabs once a second and only the changed rows' elements are replaced (Datastar morph keeps the others; check with a DOM mutation count); typing in `*scratch*` in tab B stays immediate; `C-c W` then `C-g` in the same tab ends the wait with "Quit"; `C-c W` in A then `C-g` in B also quits it; killing `*Processes*` stops the updates; screenshots in `scratch/drawing-5/`.
