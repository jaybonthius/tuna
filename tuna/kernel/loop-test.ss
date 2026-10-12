(import (only-in :gerbil/runtime/hash HashTable)
        :std/error
        :std/test
        :tuna/kernel)
(export loop-test)

(include "test-fixtures.ss")

(def log [])
(def (note! item) (set! log (cons item log)))

(def started? #f)
(def cleaned-up? #f)
(def released? #f)
(def redisplays 0)
(def waiting #f)          ; the suspension of the `wait` command
(def saw-pending? #f)

(defstruct counting-display ()
  final: #t)

(defmethod {redisplay! counting-display}
  (lambda (self) (set! redisplays (fx1+ redisplays))))

(defplugin (test-commands ctx)
  "Commands exercised by the loop tests."
  (context-provide! ctx display-service (make-counting-display))
  (define-command ctx (note-a) "Note a." (note! 'a))
  (define-command ctx (note-b) "Note b." (note! 'b))
  (define-command ctx (note-quit) "Note quit." (note! 'quit))
  (define-command ctx (fail) "Fail." (error "deliberate failure"))
  (define-command ctx (block) "Wait for the test to release it."
    (set! started? #t)
    (let lp () (unless released? (thread-sleep! 0.01) (lp))))
  (define-command ctx (cooperative-loop) "Loop, checking for quit."
    (set! started? #t)
    (let lp () (check-quit) (lp)))
  (define-command ctx (stubborn-loop) "Loop without checking for quit."
    (set! started? #t)
    (dynamic-wind void (lambda () (let lp () (lp))) (lambda () (set! cleaned-up? #t))))
  (define-command ctx (inhibited-loop) "Loop without checking, with quit inhibited."
    (set! started? #t)
    (with-inhibit-quit (let lp () (lp))))
  (define-command ctx (wait) "Wait to be resumed, then note the value."
    (note! [(suspend (lambda (s) (set! waiting s)))]))
  (define-command ctx (discard) "Note whether input is pending, then discard it."
    (set! saw-pending? (input-pending?))
    (discard-input)))

(for-each (lambda (key) (hash-put! test-bindings key (string->symbol key)))
          ["note-a" "note-b" "fail" "block" "cooperative-loop" "stubborn-loop" "inhibited-loop"
           "wait" "discard"])

(def ticks 0)
(def timer-quit? #f)

(defplugin (ticking ctx)
  "Counts timer ticks."
  (context-run-with-timer! ctx 0.01 0.01 (lambda () (set! ticks (fx1+ ticks))) name: 'tick))

(defplugin (waiting-timer ctx)
  "A timer whose callback waits until it is cancelled."
  (context-run-with-timer! ctx 0.01 #f
                           (lambda ()
                             (with-catch (lambda (e) (set! timer-quit? (quit-condition? e)) (raise e))
                                         (lambda () (suspend (lambda (s) (set! waiting s))))))))

;; Start a fresh loop with the test commands, run THUNK, and stop.
(def (with-loop thunk quit-grace: (quit-grace 0.5))
  (call-with-test-kernel
   (lambda ()
     (set! log [])
     (set! started? #f)
     (set! cleaned-up? #f)
     (set! released? #f)
     (set! waiting #f)
     (activate-plugin! test-input-plugin)
     (activate-plugin! test-commands)
     (start-editor-loop! quit-grace: quit-grace)
     (thunk))))

;; Submit the input item ITEM, usually a plain string, which the test Input
;; provider resolves.
(def (press item) (submit-input! item))

;; Wait for every earlier item and its command, then read the last message.
(def (settled-message) (call-on-editor-loop current-message))

(def (elapsed thunk)
  (let (start (time->seconds (current-time)))
    (thunk)
    (- (time->seconds (current-time)) start)))

(def loop-test
  (test-suite "tuna/kernel/loop"
    (test-case "queued input items resolve in order, one command at a time"
      (with-loop
       (lambda ()
         (for-each press ["note-a" "note-b" "unbound" "note-a"])
         (settled-message)
         (check (reverse log) => '(a b a)))))

    (test-case "a failing command is reported and the loop continues"
      (with-loop
       (lambda ()
         (press "fail")
         (check (settled-message) => "deliberate failure")
         (press "note-a")
         (settled-message)
         (check log => '(a)))))

    (test-case "redisplay waits until queued input is processed"
      (with-loop
       (lambda ()
         (press "block")
         (check (wait-until (lambda () started?)) => #t)
         (let (before redisplays)
           (for-each press ["note-a" "note-b" "note-a" "note-b" "note-a"])
           (set! released? #t)
           (settled-message)
           ;; Six commands ran (block, five notes) plus the settling call.
           (check (<= (- redisplays before) 3) ? values)))))

    (test-case "an interrupt arrival stops a cooperative command without forcing"
      (with-loop
       (lambda ()
         (press "cooperative-loop")
         (check (wait-until (lambda () started?)) => #t)
         (let (seconds (elapsed (lambda () (press "quit") (check (settled-message) => "Quit"))))
           (check (< seconds 5) ? values))
         (press "note-a")
         (settled-message)
         (check log => '(a)))
       quit-grace: 10.))

    (test-case "an interrupt with no task running is queued and resolved as input"
      (with-loop
       (lambda ()
         (hash-put! test-bindings "quit" 'note-quit)
         (try
          (press "quit")
          (press "note-a")
          (settled-message)
          (check (reverse log) => '(quit a))
          (finally (hash-remove! test-bindings "quit"))))))

    (test-case "input items of any shape are queued and resolved untouched"
      (with-loop
       (lambda ()
         (hash-put! test-bindings '(note a) 'note-a)
         (hash-put! test-bindings #f 'note-b)
         (try
          (press '(note a))
          (press #f)
          (settled-message)
          (check (reverse log) => '(a b))
          (finally
           (hash-remove! test-bindings '(note a))
           (hash-remove! test-bindings #f))))))

    (test-case "a command that ignores quit is interrupted after the grace period"
      (with-loop
       (lambda ()
         (press "stubborn-loop")
         (check (wait-until (lambda () started?)) => #t)
         (press "quit")
         (check (settled-message) => "Quit (forced: plugin or library state may be inconsistent)")
         (check cleaned-up? => #t)
         (press "note-b")
         (settled-message)
         (check log => '(b)))
       quit-grace: 0.2))

    (test-case "a second quit interrupts at once"
      (with-loop
       (lambda ()
         (press "stubborn-loop")
         (check (wait-until (lambda () started?)) => #t)
         (let (seconds (elapsed (lambda ()
                                  (press "quit")
                                  (press "quit")
                                  (check (settled-message)
                                         => "Quit (forced: plugin or library state may be inconsistent)"))))
           (check (< seconds 5) ? values))
         (check cleaned-up? => #t))
       quit-grace: 30.))

    (test-case "a waiting task returns the baton, and resumes before queued input"
      (with-loop
       (lambda ()
         (press "wait")
         (press "note-a")
         (settled-message)
         (check log => '(a))
         (check (current-command-name) => #f)
         (call-on-editor-loop
          (lambda ()
            (submit-input! "note-b")
            (resume! waiting 'answer)))
         (settled-message)
         (check (reverse log) => '(a (answer) b)))))

    (test-case "a waiting task resumed with quit unwinds and reports Quit"
      (with-loop
       (lambda ()
         (press "wait")
         (settled-message)
         (call-on-editor-loop (lambda () (resume-quit! waiting)))
         (check (settled-message) => "Quit")
         (check log => '()))))

    (test-case "stopping the loop quits waiting tasks"
      (with-loop
       (lambda ()
         (press "wait")
         (settled-message)
         (stop-editor-loop!)
         (check (editor-loop-running?) => #f))))

    (test-case "input-pending? sees queued input; discard-input drops only input"
      (with-loop
       (lambda ()
         (set! saw-pending? #f)
         (press "block")
         (check (wait-until (lambda () started?)) => #t)
         (press "discard")
         (spawn-task! 'queued-task (lambda () (note! 'task)))
         (press "note-a")
         ((result-poster) 'job-result (lambda () (note! 'result)))
         (press "note-b")
         (set! released? #t)
         (check (wait-until (lambda () (and (memq 'task log) (memq 'result log) #t))) => #t)
         (settled-message)
         (check saw-pending? => #t)
         (check (memq 'a log) => #f)
         (check (memq 'b log) => #f))))

    (test-case "input-pending? ignores queued tasks and job results"
      (with-loop
       (lambda ()
         (set! saw-pending? #t)
         (press "block")
         (check (wait-until (lambda () started?)) => #t)
         (press "discard")
         (spawn-task! 'queued-task (lambda () (note! 'task)))
         ((result-poster) 'job-result (lambda () (note! 'result)))
         (set! released? #t)
         (check (wait-until (lambda () (and (memq 'task log) (memq 'result log) #t))) => #t)
         (check saw-pending? => #f))))

    (test-case "timers run as tasks and stop with their plugin"
      (with-loop
       (lambda ()
         (set! ticks 0)
         (call-on-editor-loop (lambda () (activate-plugin! ticking)))
         (check (wait-until (lambda () (>= ticks 3))) => #t)
         (call-on-editor-loop (lambda () (deactivate-plugin! ticking)))
         (let (stopped ticks)
           (thread-sleep! 0.1)
           (check ticks => stopped)))))

    (test-case "deactivating a timer's plugin quits its waiting callback"
      (with-loop
       (lambda ()
         (set! timer-quit? #f)
         (call-on-editor-loop (lambda () (activate-plugin! waiting-timer)))
         (check (wait-until (lambda () waiting)) => #t)
         (call-on-editor-loop (lambda () (deactivate-plugin! waiting-timer)))
         (check (wait-until (lambda () timer-quit?)) => #t)
         (check (settled-message) => "Quit"))))

    (test-case "inhibit-quit holds off two interrupts; the third overrides it"
      (with-loop
       (lambda ()
         (press "inhibited-loop")
         (check (wait-until (lambda () started?)) => #t)
         (press "quit")
         (press "quit")
         (thread-sleep! 0.3)
         ;; Read without queuing behind the running command.
         (check (current-command-name) => 'inhibited-loop)
         (press "quit")
         (check (settled-message)
                => "Quit (forced: plugin or library state may be inconsistent)"))
       quit-grace: 0.1))))

