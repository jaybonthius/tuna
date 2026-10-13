;;; Tasks and their side of the quit lane (ADR 3): the task object, the
;;; running task, the quit condition, quit checks, and inhibiting quit.
;;; ./loop runs tasks and sets their quit fields; ./plugins inhibits quit
;;; around plugin operations.
prelude: :gerbil/core

(import ./ids)
(export (struct-out task)
        new-task
        current-task
        running-task
        current-task-id
        quit-condition
        quit-condition?
        quit-condition-forced?
        raise-quit!
        check-quit
        signal-quit
        call-with-inhibit-quit
        with-inhibit-quit)

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

;; The task running in this thread, or #f outside tasks. ./loop binds it.
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
