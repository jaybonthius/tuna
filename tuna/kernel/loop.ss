;;; The editor loop: the baton, tasks, input order, redisplay, and the quit
;;; lane (ADR 3).
;;;
;;; The loop thread owns the baton. It resolves each input event on the baton
;;; and lends the baton to the resulting command, which runs as a task in its
;;; own thread; later events wait until the task finishes. Quit requests
;;; arrive out of band, so they reach a running task immediately.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/thread spawn-thread)
        :std/error
        :std/interface
        :std/sync/completion
        ./ids
        ./state
        ./plugins)
(export (interface-out Input Display)
        input-service
        display-service
        (struct-out key-event)
        start-editor-loop!
        stop-editor-loop!
        editor-loop-running?
        submit-event!
        call-on-editor-loop
        check-quit
        signal-quit
        call-with-inhibit-quit
        with-inhibit-quit
        quit-condition?
        quit-condition-forced?
        redisplay
        current-command-name
        current-task-id)

;;; Services the loop consumes

;; One keydown from a client, with the client's id and sequence number
;; (ADR 7, ADR 10).
(defstruct key-event ((client     : :string)
                      (sequence   : :fixnum)
                      (key        : :string)
                      (code       : :string)
                      (location   : :fixnum)
                      (repeat?    : :boolean)
                      (composing? : :boolean)
                      (alt?       : :boolean)
                      (ctrl?      : :boolean)
                      (meta?      : :boolean)
                      (shift?     : :boolean))
  final: #t)

;; Command-loop policy (ADR 8).
(interface Input
  ;; Resolve EVENT on the baton to the command it completes, or #f.
  (resolve-event! (event : key-event)) => :t
  ;; Whether EVENT is the quit key. Called on the arriving request's thread,
  ;; before queuing, so it must not touch editor state.
  (quit-event? (event : key-event)) => :boolean)

(interface Display
  ;; Render the current editor state for every client. Runs on the baton.
  (redisplay!) => :void)

(def input-service
  (new-service 'input is-Input? tier: 'startup
               doc: "Resolves input events to commands."))

(def display-service
  (new-service 'display is-Display? tier: 'startup
               doc: "Shows the current screen to clients."))

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
                (reply           :? :procedure)    ; receives (values raised? value)
                (thread          :? :thread)
                (state           : :symbol)        ; running, quitting, finished
                (quit-requested? : :boolean)
                (quit-presses    : :fixnum)
                (inhibit-depth   : :fixnum))
  final: #t)

(def current-task (make-parameter #f))

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

;; Quit the running task, as `keyboard-quit` does.
(def (signal-quit) => :void
  (raise (quit-condition forced?: #f)))

;; Run THUNK with quitting deferred to its end. Pressing the quit key three
;; times overrides this.
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
                   (fx>= running.quit-presses 3)))
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

(defclass editor-loop ((thread         :? :thread)
                       (input          : :t)            ; the Input provider, fixed while running
                       (pending        : :list)         ; queued items, oldest first
                       (pending-tail   : :list)         ; newest first, appended lazily
                       (running        :? task)
                       (dirty?         : :boolean)
                       (last-redisplay : :real)
                       (quit-grace     : :real)         ; seconds before a quit is forced
                       (force-at       :? :real)
                       (stopping       :? :procedure))  ; reply for stop-editor-loop!
  final: #t)

;; A queued request to run a procedure on the baton.
(defstruct baton-call ((procedure : :procedure)
                       (reply     : :procedure))
  final: #t)

(def redisplay-cap 0.1) ; seconds; render at least this often under sustained input

(def (kernel-editor-loop) => (Maybe editor-loop)
  (using (k (the-kernel) : kernel)
    (let (loop k.loop)
      (and loop (: loop editor-loop)))))

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
                                running: #f dirty?: #t last-redisplay: 0. quit-grace: quit-grace
                                force-at: #f stopping: #f)
                   : editor-loop)
        (set! k.loop loop)
        (set! k.live? #t)
        (let (thread (spawn-thread (lambda () (editor-thread loop)) 'tuna-editor-loop))
          (set! loop.thread thread)
          (thread-send thread [wake:]))))))

;; Stop the loop, forcing out a running task. The kernel stops being live.
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

;; Queue EVENT from a client. A quit key bypasses the queue (ADR 3).
;; Callable from any thread.
(def (submit-event! (event : key-event)) => :void
  (let (loop (kernel-editor-loop))
    (unless loop
      (error "The editor loop is not running"))
    (using (loop : editor-loop)
      (thread-send loop.thread
                   (if (Input-quit-event? loop.input event)
                     [quit: event]
                     [event: event])))))

;; Run PROCEDURE as a task on the baton, after the input queued before it,
;; and return its value or raise its exception. Callable from any thread
;; except a task's.
(def (call-on-editor-loop (procedure : :procedure)) => :t
  (let (loop (kernel-editor-loop))
    (unless loop
      (error "The editor loop is not running"))
    (using (loop : editor-loop)
      (let (done (make-completion))
        (thread-send loop.thread
                     [event: (make-baton-call procedure
                                        (lambda (raised? value)
                                          (completion-post! done (cons raised? value))))])
        (let (result (: (completion-wait! done) :pair))
          (if (car result)
            (raise (cdr result))
            (cdr result)))))))

;; Render now. Only the baton holder may call this: the loop, or a task.
(def (redisplay) => :void
  (let (display (service-provider display-service))
    (when display
      (Display-redisplay! (Display display)))))

;; The name of the running task's command, or #f.
(def (current-command-name) => (Maybe :symbol)
  (let (loop (kernel-editor-loop))
    (and loop
         (using (loop : editor-loop)
           (let (running loop.running)
             (and running (using (running : task) running.name)))))))

(def (editor-thread (loop : editor-loop)) => :void
  (let lp ()
    (let (msg (receive-message loop))
      (match msg
        (#f (on-timeout! loop))
        ([wake:] (void))
        ([event: item] (enqueue! loop item))
        ([quit: event] (on-quit! loop event))
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

;; Dispatch queued items until a task holds the baton or the queue is empty,
;; then redisplay if anything changed.
(def (run-ready! (loop : editor-loop)) => :void
  (let lp ()
    (unless loop.running
      (cond
       ((queue-empty? loop)
        (when loop.dirty? (redisplay-now! loop)))
       (else
        (when (and loop.dirty? (> (- (now) loop.last-redisplay) redisplay-cap))
          (redisplay-now! loop))
        (dispatch! loop (dequeue! loop))
        (lp))))))

(def (dispatch! (loop : editor-loop) (item : :t)) => :void
  (set! loop.dirty? #t)
  (if (baton-call? item)
    (start-task! loop 'call (baton-call-procedure item) (baton-call-reply item))
    (with-catch
     (lambda (e) (message (exception-summary e)))
     (lambda ()
       (let (resolved (Input-resolve-event! loop.input item))
         (when resolved
           (using (resolved : command)
             (start-task! loop resolved.name resolved.procedure #f))))))))

(def (redisplay-now! (loop : editor-loop)) => :void
  (set! loop.dirty? #f)
  (set! loop.last-redisplay (now))
  (with-catch
   (lambda (e)
     (displayln "Redisplay failed: " (exception-summary e) (current-error-port)))
   redisplay))

(def (start-task! (loop      : editor-loop)
                  (name      : :symbol)
                  (procedure : :procedure)
                  (reply     :? :procedure))
  => :void
  (using ((running (task id: (next-id!) name: name procedure: procedure reply: reply thread: #f state: 'running
                         quit-requested?: #f quit-presses: 0 inhibit-depth: 0)
                   : task)
           (loop-thread loop.thread : :thread))
    (set! loop.running running)
    (set! running.thread (spawn-thread (lambda () (baton-task-thread loop-thread running)) name))))

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
  ;; A second report for the same task is ignored.
  (when (eq? ended loop.running)
    (set! loop.running #f)
    (set! loop.force-at #f)
    (set! loop.dirty? #t)
    (cond
     (ended.reply => (lambda ((reply : :procedure)) (reply raised? value)))
     ((not raised?) (void))
     ((quit-condition? value)
      (message (if (quit-condition-forced? value)
                 "Quit (forced: plugin or library state may be inconsistent)"
                 "Quit")))
     (else
      (message (exception-summary value))))))

;; The first quit asks the task to stop; the second, or the grace period
;; running out, interrupts it. With no task running, the quit key is an
;; ordinary event.
(def (on-quit! (loop : editor-loop) (event : key-event)) => :void
  (let (running loop.running)
    (if running
      (using (running : task)
        (set! running.quit-presses (fx1+ running.quit-presses))
        (set! running.quit-requested? #t)
        (if (fx= running.quit-presses 1)
          (set! loop.force-at (+ (now) loop.quit-grace))
          (force-quit! loop running)))
      (enqueue! loop event))))

(def (on-timeout! (loop : editor-loop)) => :void
  (let ((running loop.running)
        (force-at loop.force-at))
    (when (and running force-at (>= (now) force-at))
      (force-quit! loop running))))

(def (force-quit! (loop : editor-loop) (running : task)) => :void
  (set! loop.force-at #f)
  (interrupt-task! (: loop.thread :thread) running))

;; Stopping: force out a running task and wait for it briefly, fail queued
;; calls, then reply.
(def (finish-stop! (loop : editor-loop)) => :void
  (let (running loop.running)
    (when running
      (using (running : task)
        (set! running.quit-presses 3)
        (set! running.quit-requested? #t)
        (interrupt-task! (: loop.thread :thread) running)
        (let wait ()
          (match (thread-receive 2 #f)
            ([task-ended: (? (cut eq? <> running)) . _] (void))
            (#f (void))
            (_ (wait)))))))
  (let lp ()
    (unless (queue-empty? loop)
      (let (item (dequeue! loop))
        (when (baton-call? item)
          ((baton-call-reply item) #t (loop-stopped-error))))
      (lp)))
  ((: loop.stopping :procedure)))

(def (loop-stopped-error) => :t
  (with-catch values (lambda () (error "The editor loop stopped"))))
