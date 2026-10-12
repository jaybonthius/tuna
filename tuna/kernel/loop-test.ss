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

(defstruct counting-display ()
  final: #t)

(defmethod {redisplay! counting-display}
  (lambda (self) (set! redisplays (fx1+ redisplays))))

(defplugin (test-commands ctx)
  "Commands exercised by the loop tests."
  (context-provide! ctx display-service (make-counting-display))
  (define-command ctx (note-a) "Note a." (note! 'a))
  (define-command ctx (note-b) "Note b." (note! 'b))
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
    (with-inhibit-quit (let lp () (lp)))))

(for-each (lambda (key) (hash-put! test-bindings key (string->symbol key)))
          ["note-a" "note-b" "fail" "block" "cooperative-loop" "stubborn-loop" "inhibited-loop"])

;; Start a fresh loop with the test commands, run THUNK, and stop.
(def (with-loop thunk quit-grace: (quit-grace 0.5))
  (call-with-test-kernel
   (lambda ()
     (set! log [])
     (set! started? #f)
     (set! cleaned-up? #f)
     (set! released? #f)
     (activate-plugin! test-input-plugin)
     (activate-plugin! test-commands)
     (start-editor-loop! quit-grace: quit-grace)
     (thunk))))

(def (press key) (submit-event! (test-event key)))

;; Wait for every earlier event and its command, then read the echo area.
(def (settled-message) (call-on-editor-loop current-message))

(def (elapsed thunk)
  (let (start (time->seconds (current-time)))
    (thunk)
    (- (time->seconds (current-time)) start)))

(def loop-test
  (test-suite "tuna/kernel/loop"
    (test-case "events run in order, one command at a time"
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

    (test-case "the quit key stops a cooperative command without forcing"
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

    (test-case "inhibit-quit holds off two quits; the third overrides it"
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

