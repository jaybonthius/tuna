;;; Timers: tasks that run after a delay, and optionally repeat, owned by a
;;; plugin context (ADR 2, ADR 3; Emacs `run-with-timer`). A timer thread
;;; only waits and queues; each callback runs as a task on the baton. A
;;; library (ADR 12): it uses only the public kernel API.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/thread spawn-thread)
        :tuna/kernel)
(export context-run-with-timer!
        timer?
        cancel-timer)

(defclass timer ((name       : :symbol)
                 (procedure  : :procedure)
                 (thread     :? :thread)
                 (cancelled? : :boolean)
                 (tasks      : :list))       ; its callback tasks that have not ended
  final: #t)

;; Run PROCEDURE as a task named NAME after SECONDS, then every REPEAT
;; seconds if REPEAT is given. Deactivating CTX's plugin cancels the timer
;; and its callback tasks, even one waiting at a prompt.
(def (context-run-with-timer! (ctx       : context)
                              (seconds   : :real)
                              (repeat    :? :real)
                              (procedure : :procedure)
                              name: (name : :symbol := 'timer))
  => timer
  (using (new (timer name: name procedure: (context-bind ctx procedure) thread: #f cancelled?: #f tasks: []) : timer)
    (set! new.thread (spawn-thread (lambda () (countdown-thread new seconds repeat))
                                   'tuna-timer))
    (context-defer! ctx (lambda () (cancel-timer new)))
    new))

;; Stop T and cancel its callback tasks. Call on the baton.
(def (cancel-timer (t : timer)) => :void
  (unless t.cancelled?
    (set! t.cancelled? #t)
    (thread-send (: t.thread :thread) 'cancel)
    (for-each cancel-task! t.tasks)
    (set! t.tasks [])))

;; Wait, then queue a callback task, until cancelled. Receiving any
;; message cancels.
(def (countdown-thread (t : timer) (seconds : :real) (repeat :? :real)) => :void
  (let lp ((delay seconds))
    (unless (thread-receive delay #f)
      (with-catch void (lambda () (spawn-task! t.name (lambda () (timer-callback t)))))
      (when repeat
        (lp repeat)))))

;; On the baton: run T's procedure unless T was cancelled meanwhile.
(def (timer-callback (t : timer)) => :void
  (unless t.cancelled?
    (let (self (running-task))
      (set! t.tasks (cons self t.tasks))
      (unwind-protect
        (t.procedure)
        (set! t.tasks (remq self t.tasks))))))
