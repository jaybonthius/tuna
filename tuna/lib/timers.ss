;;; Timers: tasks that run after a delay, and optionally repeat, owned by a
;;; plugin context (ADR 2, ADR 3; Emacs `run-with-timer`). A timer thread
;;; only waits and queues; each callback runs as a task on the baton. A
;;; library (ADR 12): it uses only the public kernel API.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/thread spawn-thread)
        :tuna/kernel)
(export context-run-with-timer!
        timer?
        cancel-timer
        restart-timer)

(defclass timer ((name       : :symbol)
                 (procedure  : :procedure)
                 (seconds    : :real)
                 (repeat     :? :real)
                 (thread     :? :thread)
                 (counting?  : :boolean)     ; its callback is due: not yet started, or repeating
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
  ;; A later timer callback may register effects through current-context.
  (using (new (timer name: name procedure: (context-bind ctx procedure) seconds: seconds repeat: repeat
                     thread: #f counting?: #f cancelled?: #f tasks: [])
              : timer)
    (start-countdown! new)
    (context-defer! ctx (lambda () (cancel-timer new)))
    new))

(def (start-countdown! (t : timer)) => :void
  (set! t.counting? #t)
  (set! t.thread (spawn-thread (lambda () (countdown-thread t t.seconds t.repeat))
                               'tuna-timer)))

;; Run T once more, its first delay from now (Emacs `timer-activate`):
;; unless T is cancelled, or its callback is still due (it has not yet
;; started, or T repeats). So a one-shot timer can be armed again and
;; again, as a change asks, while it owns one countdown at a time. Call on
;; the baton.
(def (restart-timer (t : timer)) => :void
  (unless (or t.cancelled? t.counting?)
    (start-countdown! t)))

;; Stop T and cancel its callback tasks. Call on the baton.
(def (cancel-timer (t : timer)) => :void
  (unless t.cancelled?
    (set! t.cancelled? #t)
    (thread-send (: t.thread :thread) 'cancel)
    (for-each cancel-task! t.tasks)
    (set! t.tasks [])))

;; Wait, then queue a callback task, until cancelled. Receiving any
;; message cancels. A callback that cannot be queued, because the editor
;; loop is not running (yet), is not due any more, so a one-shot timer
;; can be restarted.
(def (countdown-thread (t : timer) (seconds : :real) (repeat :? :real)) => :void
  (let lp ((delay seconds))
    (unless (thread-receive delay #f)
      (with-catch (lambda (e) (unless repeat (set! t.counting? #f)))
                  (lambda () (spawn-task! t.name (lambda () (timer-callback t)))))
      (when repeat
        (lp repeat)))))

;; On the baton: run T's procedure unless T was cancelled meanwhile.
(def (timer-callback (t : timer)) => :void
  (unless t.repeat
    (set! t.counting? #f))
  (unless t.cancelled?
    (let (self (running-task))
      (set! t.tasks (cons self t.tasks))
      (unwind-protect
        (t.procedure)
        (set! t.tasks (remq self t.tasks))))))
