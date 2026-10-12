;;; The editor loop: the baton, tasks and their suspension, input order,
;;; job results, redisplay, and the quit lane (ADR 3).
;;;
;;; The loop thread owns the baton. It resolves each input item on the baton
;;; and lends the baton to the resulting task, which runs in its own
;;; thread; later items wait until the task finishes or suspends. A task
;;; suspends only at a yield point (`suspend`), which returns the baton to the
;;; loop; once resumed, it takes the baton back before any further input.
;;; Quit requests arrive out of band, so they reach a running task at once.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/thread spawn-thread)
        :std/error
        :std/interface
        :std/sync/completion
        ./ids
        ./state
        ./plugins
        (only-in ./hooks new-hook))
(export (interface-out Input Display)
        input-service
        display-service
        start-editor-loop!
        stop-editor-loop!
        editor-loop-running?
        submit-input!
        call-on-editor-loop
        task?
        running-task
        spawn-task!
        cancel-task!
        result-poster
        suspension?
        suspend
        resume!
        resume-quit!
        input-pending?
        discard-input
        check-quit
        signal-quit
        call-with-inhibit-quit
        with-inhibit-quit
        quit-condition?
        quit-condition-forced?
        redisplay
        current-task-name
        current-task-id
        task-started-hook
        task-finished-hook)

;;; Services the loop consumes

;; Command-loop policy (ADR 8, ADR 12). Input items are opaque to the
;; kernel: only the provider and whoever submits items know their shape.
(interface Input
  ;; How ITEM is handled on arrival: 'queue to resolve it in order, or
  ;; 'interrupt to request a quit (ADR 3). Called on the submitting thread,
  ;; before queuing, so it must not touch editor state.
  (arrival (item : :t)) => :symbol
  ;; Resolve ITEM on the baton to the task it starts, as a pair of the
  ;; task's name and its thunk, or to #f when it starts none.
  (resolve! (item : :t)) => (Maybe :pair))

(interface Display
  ;; Render the current editor state for every client. Runs on the baton.
  (redisplay!) => :void)

(def input-service
  (new-service 'input is-Input? tier: 'startup
               doc: "Resolves input items to tasks."))

(def display-service
  (new-service 'display is-Display? tier: 'startup
               doc: "Shows the current screen to clients."))

;;; Task lifecycle hooks (ADR 12)
;;;
;;; Callbacks run on the loop thread while it holds the baton (no task is
;;; running), under the rules for lifecycle hooks in ./plugins: they must not
;;; activate or deactivate plugins or wait for the loop, and a failing
;;; callback is removed without affecting the task or the loop. They block
;;; the loop while they run, so they should be quick.

;; Arguments: the task's id and name. Runs once per task, when the loop has
;; made it the running task (current-task-name returns its name) and before
;; its code runs. Resuming a suspended task is not announced.
(def task-started-hook
  (new-hook 'task-started
            doc: "Runs with a task's id and name just before the task first runs."))

;; Arguments: the task's id, its name, and how it finished: returned,
;; raised (an exception other than quit), or quit (including a forced quit,
;; a started task cancelled with cancel-task!, and a task forced out when
;; the loop stops). Runs exactly once for each task announced by
;; task-started, and for no other: after the loop has stopped running it
;; and after its caller has its result. A task cancelled before it started,
;; or still queued when the loop stops, is announced by neither hook.
(def task-finished-hook
  (new-hook 'task-finished
            doc: "Runs with a task's id, name, and how it finished, after it finished."))

;;; Quitting

;; Raised in a task to quit it. Not an Error, so handlers for errors do not
;; swallow it.
(defclass quit-condition ((forced? : :boolean))
  final: #t)

;; A task: code holding the baton in its own thread. The loop thread sets
;; the quit fields; the task's thread reads them at its quit checks.
(defclass task ((id              : :fixnum)
                (name            : :symbol)
                (procedure       : :procedure)
                (reply           :? :procedure)    ; receives raised? and value
                (thread          :? :thread)
                ;; queued, running, suspended, quitting, finished, cancelled
                (state           : :symbol)
                (suspension      :? :t)            ; its wait, while suspended
                (quit-requested? : :boolean)
                (interrupts      : :fixnum)
                (inhibit-depth   : :fixnum))
  final: #t)

(def (new-task (name : :symbol) (procedure : :procedure) (reply :? :procedure)) => task
  (task id: (next-id!) name: name procedure: procedure reply: reply thread: #f
        state: 'queued suspension: #f quit-requested?: #f interrupts: 0 inhibit-depth: 0))

;; One wait of a suspended task. The loop thread records the outcome, a
;; pair of raised? and value, and hands it over with the baton.
(defclass suspension ((waiter  : task)
                      (done    : :t)               ; a completion
                      (outcome :? :pair))
  final: #t)

(def current-task (make-parameter #f))

;; The running task, for cancel-task!, or #f outside tasks.
(def (running-task) => (Maybe task)
  (current-task))

;; The identity of the running task, or #f outside tasks. Undo uses it to
;; group the changes one command makes.
(def (current-task-id) => (Maybe :fixnum)
  (let (running (current-task))
    (and running (task-id running))))

(def (raise-quit! (running : task) (forced? : :boolean)) => :void
  (set! running.state 'quitting)
  (raise (quit-condition forced?: forced?)))

;; Quit now if a quit was requested for the running task (Emacs's quit
;; check). Long-running loops call this.
(def (check-quit) => :void
  (let (running (current-task))
    (when running
      (using (running : task)
        (when (and running.quit-requested? (fxzero? running.inhibit-depth))
          (raise-quit! running #f))))))

;; Quit the running task, as Emacs's quit command does.
(def (signal-quit) => :void
  (raise (quit-condition forced?: #f)))

;; Run THUNK with quitting deferred to its end. A third interrupt while it
;; runs overrides this.
(def (call-with-inhibit-quit (thunk : :procedure)) => :t
  (let (running (current-task))
    (if running
      (using (running : task)
        (let (result (dynamic-wind
                       (lambda () (set! running.inhibit-depth (fx1+ running.inhibit-depth)))
                       thunk
                       (lambda () (set! running.inhibit-depth (fx1- running.inhibit-depth)))))
          (check-quit)
          result))
      (thunk))))

(defrule (with-inhibit-quit body ...)
  (call-with-inhibit-quit (lambda () body ...)))

;; Runs inside the task's thread through thread-interrupt!.
(def (forced-quit-thunk (running : task)) => :procedure
  (lambda ()
    (when (and (eq? running.state 'running)
               (or (fxzero? running.inhibit-depth)
                   (fx>= running.interrupts 3)))
      (raise-quit! running #t))))

;; thread-interrupt! waits until the target runs the thunk, and raises
;; abandoned-mutex-exception in the caller when the thunk escapes (or
;; inactive-thread-exception when the task already ended). It runs in its
;; own thread so a task stuck in foreign code cannot block the loop.
(def (interrupt-task! (loop-thread : :thread) (running : task)) => :void
  (spawn-thread
   (lambda ()
     (let (thread (: running.thread :thread))
       (with-catch
        (lambda (e)
          (unless (or (abandoned-mutex-exception? e) (inactive-thread-exception? e))
            (raise e)))
        (lambda () (thread-interrupt! thread (forced-quit-thunk running))))
       ;; The task reports its own end. If the interrupt landed in the few
       ;; instructions where nothing can catch it, report the end here.
       (with-catch
        (lambda (e)
          (thread-send loop-thread [task-ended: running #t (quit-condition forced?: #t)]))
        (lambda () (thread-join! thread 10 #f)))))
   'tuna-quit))

;;; The loop

;; A submitted input item in the queue, which tells it apart from queued
;; tasks. The kernel never looks inside ITEM.
(defstruct queued-input ((item : :t))
  final: #t)

(defclass editor-loop ((thread         :? :thread)
                       (input          : :t)            ; the Input provider, fixed while running
                       (pending        : :list)         ; queued inputs and tasks, oldest first
                       (pending-tail   : :list)         ; newest first, appended lazily
                       (resumes        : :list)         ; suspensions ready to resume, oldest first
                       (results        : :list)         ; job-result tasks, oldest first
                       (waiting        : :list)         ; suspended tasks
                       (running        :? task)
                       (finished       : :list)         ; (task . how) not yet announced, oldest first
                       (dirty?         : :boolean)
                       (last-redisplay : :real)
                       (quit-grace     : :real)         ; seconds before a quit is forced
                       (force-at       :? :real)
                       (stopping       :? :procedure))  ; reply for stop-editor-loop!
  final: #t)

(def redisplay-cap 0.1) ; seconds; render at least this often under sustained input

(def (kernel-editor-loop) => (Maybe editor-loop)
  (using (k (the-kernel) : kernel)
    (let (loop k.loop)
      (and loop (: loop editor-loop)))))

(def (running-loop) => editor-loop
  (let (loop (kernel-editor-loop))
    (unless loop
      (error "The editor loop is not running"))
    (: loop editor-loop)))

(def (send-to-loop! (msg : :t)) => :void
  (using (loop (running-loop) : editor-loop)
    (thread-send (: loop.thread :thread) msg)))

(def (now) => :real
  (time->seconds (current-time)))

(def (editor-loop-running?) => :boolean
  (and (kernel-editor-loop) #t))

;; Start the loop. The kernel becomes live: startup-tier services refuse
;; replacement from now on.
(def (start-editor-loop! quit-grace: (quit-grace : :real := 0.5)) => :void
  (using (k (the-kernel) : kernel)
    (let (input (service-provider input-service))
      (when k.loop
        (error "The editor loop is already running"))
      (unless input
        (error "No plugin provides the input service"))
      (using (loop (editor-loop thread: #f input: (Input input) pending: [] pending-tail: []
                                resumes: [] results: [] waiting: []
                                running: #f finished: [] dirty?: #t last-redisplay: 0. quit-grace: quit-grace
                                force-at: #f stopping: #f)
                   : editor-loop)
        (set! k.loop loop)
        (set! k.live? #t)
        (let (thread (spawn-thread (lambda () (editor-thread loop)) 'tuna-editor-loop))
          (set! loop.thread thread)
          (thread-send thread [wake:]))))))

;; Stop the loop: force out a running task, quit waiting ones, and fail
;; queued calls. The kernel stops being live.
(def (stop-editor-loop!) => :void
  (using (k (the-kernel) : kernel)
    (let (loop (kernel-editor-loop))
      (when loop
        (using ((loop : editor-loop)
                (thread loop.thread : :thread))
          (let (done (make-completion))
            (thread-send thread [stop: (lambda () (completion-post! done #t))])
            (completion-wait! done)
            (thread-join! thread)
            (set! k.loop #f)
            (set! k.live? #f)))))))

;; Queue the input ITEM for the Input provider to resolve, unless the
;; provider classifies it as an interrupt, which bypasses the queue
;; (ADR 3). Callable from any thread.
(def (submit-input! (item : :t)) => :void
  (using (loop (running-loop) : editor-loop)
    (thread-send (: loop.thread :thread)
                 (case (Input-arrival loop.input item)
                   ((queue) [enqueue: (make-queued-input item)])
                   ((interrupt) [interrupt: item])
                   (else (error "Input arrival must return queue or interrupt" item))))))

;; Run PROCEDURE as a task on the baton, after the input queued before it,
;; and return its value or raise its exception. Callable from any thread
;; except a task's.
(def (call-on-editor-loop (procedure : :procedure)) => :t
  (let (done (make-completion))
    (send-to-loop! [enqueue: (new-task 'call procedure
                                     (lambda (raised? value)
                                       (completion-post! done (cons raised? value))))])
    (let (result (: (completion-wait! done) :pair))
      (if (car result)
        (raise (cdr result))
        (cdr result)))))

;; Queue PROCEDURE to run as a task named NAME, in order with input, and
;; return the task. Callable from any thread.
(def (spawn-task! (name : :symbol) (procedure : :procedure)) => task
  (let (queued (new-task name procedure #f))
    (send-to-loop! [enqueue: queued])
    queued))

;; Cancel QUEUED-OR-RUNNING: a queued task never runs, a suspended one
;; resumes by raising quit, and a running one is asked to quit at its next
;; quit check. Callable from any thread.
(def (cancel-task! (target : task)) => :void
  (when (editor-loop-running?)
    (send-to-loop! [cancel: target])))

;; A procedure of a name and a thunk that queues the thunk as a task on
;; this loop after pending input, but before the next render (ADR 3: job
;; results). It works from any thread, including one whose dynamic
;; environment lacks the kernel.
(def (result-poster) => :procedure
  (using (loop (running-loop) : editor-loop)
    (let (thread (: loop.thread :thread))
      (lambda ((name : :symbol) (procedure : :procedure))
        (thread-send thread [result: (new-task name procedure #f)])))))

;; Render now. Only the baton holder may call this: the loop, or a task.
(def (redisplay) => :void
  (let (display (service-provider display-service))
    (when display
      (Display-redisplay! (Display display)))))

;; The name of the running task, or #f.
(def (current-task-name) => (Maybe :symbol)
  (let (loop (kernel-editor-loop))
    (and loop
         (using (loop : editor-loop)
           (let (running loop.running)
             (and running (using (running : task) running.name)))))))

;;; Yield points

;; Suspend the running task until the suspension that ARM receives is
;; resumed, and return the baton to the loop meanwhile. ARM runs first, on
;; the baton, and arranges for someone to call resume! or resume-quit!.
;; Returns the resumed value, or raises.
(def (suspend (arm : :procedure)) => :t
  (let (running (current-task))
    (unless running
      (error "Only a task can wait"))
    (using ((running : task)
            (loop (running-loop) : editor-loop))
      (check-quit)
      (using (s (suspension waiter: running done: (make-completion) outcome: #f) : suspension)
        (arm s)
        (thread-send (: loop.thread :thread) [suspended: s])
        (let (outcome (: (completion-wait! s.done) :pair))
          (if (car outcome)
            (raise (cdr outcome))
            (cdr outcome)))))))

;; Resume S's task with VALUE once the baton is free, before further input.
;; Only the first resumption counts. Callable from any thread.
(def (resume! (s : suspension) (value : :t)) => :void
  (send-to-loop! [resume: s #f value]))

;; Resume S's task by raising quit in it.
(def (resume-quit! (s : suspension)) => :void
  (send-to-loop! [resume: s #t (quit-condition forced?: #f)]))

;; Whether input items are queued (Emacs `input-pending-p`). Call it from
;; a task.
(def (input-pending?) => :boolean
  (using (loop (running-loop) : editor-loop)
    (if (eq? (current-thread) loop.thread)
      (input-queued? loop)
      (let (done (make-completion))
        (thread-send (: loop.thread :thread)
                     [input-pending?: (lambda (answer) (completion-post! done answer))])
        (:- (completion-wait! done) :boolean)))))

;; Drop every queued input item, but no queued task (Emacs `discard-input`).
(def (discard-input) => :void
  (send-to-loop! [discard-input:]))

;;; The loop thread

(def (editor-thread (loop : editor-loop)) => :void
  (let lp ()
    (let (msg (receive-message loop))
      (match msg
        (#f (on-timeout! loop))
        ([wake:] (void))
        ([enqueue: item] (enqueue! loop item))
        ([result: result-task] (set! loop.results (append loop.results [result-task])))
        ([interrupt: item] (on-interrupt! loop item))
        ([suspended: s] (on-suspended! loop s))
        ([resume: s raised? value] (on-resume! loop s raised? value))
        ([cancel: target] (on-cancel! loop target))
        ([input-pending?: reply] (reply (input-queued? loop)))
        ([discard-input:] (discard-input! loop))
        ([task-ended: ended raised? value] (on-task-ended! loop ended raised? value))
        ([stop: reply] (set! loop.stopping reply)))
      (if loop.stopping
        (finish-stop! loop)
        (begin
          (run-ready! loop)
          (lp))))))

;; The next message, or #f when a pending forced quit is due.
(def (receive-message (loop : editor-loop)) => :t
  (let (force-at loop.force-at)
    (if force-at
      (thread-receive (max 0. (- force-at (now))) #f)
      (thread-receive))))

(def (enqueue! (loop : editor-loop) (item : :t)) => :void
  (set! loop.pending-tail (cons item loop.pending-tail)))

(def (dequeue! (loop : editor-loop)) => :t
  (when (null? loop.pending)
    (set! loop.pending (reverse loop.pending-tail))
    (set! loop.pending-tail []))
  (let (item (car loop.pending))
    (set! loop.pending (cdr loop.pending))
    item))

(def (queue-empty? (loop : editor-loop)) => :boolean
  (and (null? loop.pending) (null? loop.pending-tail)))

(def (input-queued? (loop : editor-loop)) => :boolean
  (or (ormap queued-input? loop.pending)
      (ormap queued-input? loop.pending-tail)))

(def (discard-input! (loop : editor-loop)) => :void
  (let (keep? (lambda (item) (not (queued-input? item))))
    (set! loop.pending (filter keep? loop.pending))
    (set! loop.pending-tail (filter keep? loop.pending-tail))))

(def (redisplay-due? (loop : editor-loop)) => :boolean
  (and loop.dirty? (> (- (now) loop.last-redisplay) redisplay-cap)))

;; Lend the baton until a task holds it or nothing is left to do, in
;; priority order: resumed tasks, input (unless a render is overdue), job
;; results, then a render.
(def (run-ready! (loop : editor-loop)) => :void
  (let lp ()
    (unless loop.running
      (announce-finished! loop)
      (cond
       ((pair? loop.resumes)
        (resume-next! loop))
       ((and (not (queue-empty? loop)) (not (redisplay-due? loop)))
        (dispatch! loop (dequeue! loop))
        (lp))
       ((pair? loop.results)
        (let (next (car loop.results))
          (set! loop.results (cdr loop.results))
          (set! loop.dirty? #t)
          (start-task! loop next)))
       (loop.dirty?
        (redisplay-now! loop)
        (lp))
       (else (void))))))

(def (dispatch! (loop : editor-loop) (next : :t)) => :void
  (cond
   ((task? next)
    (using (next : task)
      (when (eq? next.state 'queued)
        (set! loop.dirty? #t)
        (start-task! loop next))))
   (else
    (set! loop.dirty? #t)
    (with-catch
     (lambda (e) (message (exception-summary e)))
     (lambda ()
       (let (resolved (Input-resolve! loop.input (queued-input-item next)))
         (when resolved
           (start-task! loop (new-task (car resolved) (cdr resolved) #f)))))))))

(def (redisplay-now! (loop : editor-loop)) => :void
  (set! loop.dirty? #f)
  (set! loop.last-redisplay (now))
  (with-catch
   (lambda (e)
     (displayln "Redisplay failed: " (exception-summary e) (current-error-port)))
   redisplay))

(def (start-task! (loop : editor-loop) (next : task)) => :void
  (let (loop-thread (: loop.thread :thread))
    (set! next.state 'running)
    (set! loop.running next)
    (run-lifecycle-hook task-started-hook next.id next.name)
    (set! next.thread (spawn-thread (lambda () (baton-task-thread loop-thread next)) next.name))))

(def (baton-task-thread (loop-thread : :thread) (running : task)) => :void
  (let* ((raised? #t)
         (procedure running.procedure)
         (value (parameterize ((current-task running))
                  (with-catch
                   (lambda (e)
                     (set! running.state 'finished)
                     e)
                   (lambda ()
                     (let (value (procedure))
                       (set! running.state 'finished)
                       (set! raised? #f)
                       value))))))
    (thread-send loop-thread [task-ended: running raised? value])))

(def (on-task-ended! (loop : editor-loop) (ended : task) (raised? : :boolean) (value : :t)) => :void
  (cond
   ((eq? ended loop.running)
    (set! loop.running #f)
    (set! loop.force-at #f)
    (set! loop.dirty? #t)
    (task-finished! loop ended (how-task-ended raised? value))
    (cond
     (ended.reply => (lambda ((reply : :procedure)) (reply raised? value)))
     ((not raised?) (void))
     ((quit-condition? value)
      (message (if (quit-condition-forced? value)
                 "Quit (forced: plugin or library state may be inconsistent)"
                 "Quit")))
     (else
      (message (exception-summary value)))))
   ;; A forced quit that landed just as the task suspended ended it there.
   ((memq ended loop.waiting)
    (set! loop.waiting (remq ended loop.waiting))
    (task-finished! loop ended (how-task-ended raised? value)))
   ;; A second report for the same task is ignored.
   (else (void))))

(def (how-task-ended (raised? : :boolean) (value : :t)) => :symbol
  (cond
   ((not raised?) 'returned)
   ((quit-condition? value) 'quit)
   (else 'raised)))

;; Record that ENDED finished HOW, for announce-finished!.
(def (task-finished! (loop : editor-loop) (ended : task) (how : :symbol)) => :void
  (set! loop.finished (append loop.finished [(cons ended how)])))

;; Announce finished tasks. Only call it while the loop holds the baton.
(def (announce-finished! (loop : editor-loop)) => :void
  (let (finished loop.finished)
    (unless (null? finished)
      (set! loop.finished [])
      (for-each (lambda ((entry : :pair))
                  (using (ended (car entry) : task)
                    (run-lifecycle-hook task-finished-hook ended.id ended.name (cdr entry))))
                finished))))

;;; Suspension

(def (on-suspended! (loop : editor-loop) (s : suspension)) => :void
  (using (suspended s.waiter : task)
    (when (eq? suspended loop.running)
      (set! loop.running #f)
      (set! loop.force-at #f)
      (set! loop.dirty? #t)
      (set! suspended.state 'suspended)
      (set! suspended.suspension s)
      (set! loop.waiting (cons suspended loop.waiting))
      (when s.outcome
        (set! loop.resumes (append loop.resumes [s]))))))

;; Record S's outcome; the task resumes once it has suspended.
(def (on-resume! (loop : editor-loop) (s : suspension) (raised? : :boolean) (value : :t)) => :void
  (unless s.outcome
    (set! s.outcome (cons raised? value))
    (when (eq? (task-suspension s.waiter) s)
      (set! loop.resumes (append loop.resumes [s])))))

(def (resume-next! (loop : editor-loop)) => :void
  (using ((s (car loop.resumes) : suspension)
          (resumed s.waiter : task))
    (set! loop.resumes (cdr loop.resumes))
    (set! loop.waiting (remq resumed loop.waiting))
    (set! resumed.suspension #f)
    (set! resumed.state 'running)
    (set! loop.running resumed)
    (set! loop.dirty? #t)
    (completion-post! s.done s.outcome)))

(def (on-cancel! (loop : editor-loop) (target : task)) => :void
  (case target.state
    ((queued)
     (set! target.state 'cancelled)
     (let (reply target.reply)
       (when reply
         (reply #t (quit-condition forced?: #f)))))
    ((suspended)
     (on-resume! loop (: target.suspension suspension) #t (quit-condition forced?: #f)))
    ((running)
     (set! target.quit-requested? #t))
    (else (void))))

;;; Quitting

;; The first interrupt asks the task to stop; the second, or the grace
;; period running out, interrupts its thread. With no task running, the
;; item is queued as ordinary input, which a waiting prompt may bind.
(def (on-interrupt! (loop : editor-loop) (item : :t)) => :void
  (let (running loop.running)
    (if running
      (using (running : task)
        (set! running.interrupts (fx1+ running.interrupts))
        (set! running.quit-requested? #t)
        (if (fx= running.interrupts 1)
          (set! loop.force-at (+ (now) loop.quit-grace))
          (force-quit! loop running)))
      (enqueue! loop (make-queued-input item)))))

(def (on-timeout! (loop : editor-loop)) => :void
  (let ((running loop.running)
        (force-at loop.force-at))
    (when (and running force-at (>= (now) force-at))
      (force-quit! loop running))))

(def (force-quit! (loop : editor-loop) (running : task)) => :void
  (set! loop.force-at #f)
  (interrupt-task! (: loop.thread :thread) running))

;;; Stopping

;; Force out a running task, resume waiting tasks with quit one at a time
;; so they unwind on the baton, fail queued calls, then reply.
(def (finish-stop! (loop : editor-loop)) => :void
  (let (running loop.running)
    (when running
      (using (running : task)
        (set! running.interrupts 3)
        (set! running.quit-requested? #t)
        (interrupt-task! (: loop.thread :thread) running)
        (await-task-end! loop running))))
  (for-each
    (lambda ((waiting : task))
      (using (s waiting.suspension : suspension)
        (set! s.outcome (cons #t (quit-condition forced?: #f)))
        (set! loop.resumes [s])
        (resume-next! loop)
        (await-task-end! loop waiting)))
    (reverse loop.waiting))
  (let lp ()
    (unless (queue-empty? loop)
      (let (item (dequeue! loop))
        (when (task? item)
          (using (item : task)
            (let (reply item.reply)
              (when (and reply (eq? item.state 'queued))
                (reply #t (loop-stopped-error)))))))
      (lp)))
  (announce-finished! loop)
  ((: loop.stopping :procedure)))

;; Wait briefly for ENDING to report its end, dropping other messages, and
;; record how it ended; one that does not report in time counts as quit.
(def (await-task-end! (loop : editor-loop) (ending : task)) => :void
  (let (how (let wait ()
              (match (thread-receive 2 #f)
                ([task-ended: (? (cut eq? <> ending)) raised? value] (how-task-ended raised? value))
                (#f 'quit)
                (_ (wait)))))
    (set! loop.running #f)
    (task-finished! loop ending how)))

(def (loop-stopped-error) => :t
  (with-catch values (lambda () (error "The editor loop stopped"))))
