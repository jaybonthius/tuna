(import :std/error
        :std/test
        :tuna/kernel
        :tuna/lib/timers
        "../support/kernel"
        "../support/string-input")
(export timers-test)

(def ticks 0)
(def waiting #f)          ; the suspension of the waiting timer's callback
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

;; A one-shot timer the test restarts.
(def once #f)

(defplugin (once-timer ctx)
  "A one-shot timer that counts its runs."
  (set! once (context-run-with-timer! ctx 0.01 #f (lambda () (set! ticks (fx1+ ticks))) name: 'once)))

(def (with-loop thunk)
  (set! ticks 0)
  (set! waiting #f)
  (set! timer-quit? #f)
  (call-with-fresh-kernel [test-input]
    (lambda ()
      (start-editor-loop!)
      (thunk))))

(def timers-test
  (test-suite "tuna/lib/timers"
    (test-case "later timer registrations belong to the timer owner"
      (with-loop
       (lambda ()
         (let (entries (new-entry-table))
           (defplugin (registering-timer ctx) "Registers an entry on a later tick."
             (context-run-with-timer! ctx 0.01 #f
               (lambda () (context-add-entry! (current-context) entries 'later 'owned))))
           (call-on-editor-loop (lambda () (activate-plugin! registering-timer)))
           (check (wait-until (lambda () (entry-table-ref entries 'later))) => #t)
           (check (entry-owner (entry-table-ref entries 'later)) => 'registering-timer)
           (call-on-editor-loop (lambda () (deactivate-plugin! registering-timer)))
           (check (entry-table-ref entries 'later) => #f)))))
    (test-case "timers run as tasks and stop with their plugin"
      (with-loop
       (lambda ()
         (call-on-editor-loop (lambda () (activate-plugin! ticking)))
         (check (wait-until (lambda () (>= ticks 3))) => #t)
         (call-on-editor-loop (lambda () (deactivate-plugin! ticking)))
         (let (stopped ticks)
           (thread-sleep! 0.1)
           (check ticks => stopped)))))

    (test-case "a one-shot timer runs once per restart; restarting it while due changes nothing"
      (with-loop
       (lambda ()
         (call-on-editor-loop (lambda () (activate-plugin! once-timer)))
         (check (wait-until (lambda () (= ticks 1))) => #t)
         (thread-sleep! 0.05)
         (check ticks => 1)
         (call-on-editor-loop (lambda () (restart-timer once) (restart-timer once)))
         (check (wait-until (lambda () (= ticks 2))) => #t)
         (thread-sleep! 0.05)
         (check ticks => 2)
         ;; A cancelled timer does not restart.
         (call-on-editor-loop (lambda () (deactivate-plugin! once-timer) (restart-timer once)))
         (thread-sleep! 0.05)
         (check ticks => 2))))

    (test-case "a restart can give a one-shot timer a new delay, which it keeps"
      (with-loop
       (lambda ()
         (call-on-editor-loop (lambda () (activate-plugin! once-timer)))
         (check (wait-until (lambda () (= ticks 1))) => #t)
         (call-on-editor-loop (lambda () (restart-timer once seconds: 0.3)))
         (thread-sleep! 0.15)
         (check ticks => 1)
         (check (wait-until (lambda () (= ticks 2))) => #t)
         (call-on-editor-loop (lambda () (restart-timer once)))
         (thread-sleep! 0.15)
         (check ticks => 2)
         (check (wait-until (lambda () (= ticks 3))) => #t))))

    (test-case "a one-shot timer that came due before the editor loop ran can be restarted"
      (set! ticks 0)
      (call-with-fresh-kernel [test-input]
        (lambda ()
          (activate-plugin! once-timer)
          (thread-sleep! 0.05)
          (start-editor-loop!)
          (thread-sleep! 0.05)
          (check ticks => 0)
          (call-on-editor-loop (lambda () (restart-timer once)))
          (check (wait-until (lambda () (= ticks 1))) => #t))))

    (test-case "deactivating a timer's plugin quits its waiting callback"
      (with-loop
       (lambda ()
         (call-on-editor-loop (lambda () (activate-plugin! waiting-timer)))
         (check (wait-until (lambda () waiting)) => #t)
         (call-on-editor-loop (lambda () (deactivate-plugin! waiting-timer)))
         (check (wait-until (lambda () timer-quit?)) => #t)
         (check (call-on-editor-loop current-message) => "Quit"))))))
