(import (only-in :gerbil/runtime/hash HashTable)
        :std/error
        :std/test
        :tuna/kernel
        :tuna/lib/timers)
(export timers-test)

(include "../kernel/test-fixtures.ss")

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

(def (with-loop thunk)
  (call-with-test-kernel
   (lambda ()
     (set! ticks 0)
     (set! waiting #f)
     (set! timer-quit? #f)
     (activate-plugin! test-input-plugin)
     (start-editor-loop!)
     (thunk))))

(def timers-test
  (test-suite "tuna/lib/timers"
    (test-case "timers run as tasks and stop with their plugin"
      (with-loop
       (lambda ()
         (call-on-editor-loop (lambda () (activate-plugin! ticking)))
         (check (wait-until (lambda () (>= ticks 3))) => #t)
         (call-on-editor-loop (lambda () (deactivate-plugin! ticking)))
         (let (stopped ticks)
           (thread-sleep! 0.1)
           (check ticks => stopped)))))

    (test-case "deactivating a timer's plugin quits its waiting callback"
      (with-loop
       (lambda ()
         (call-on-editor-loop (lambda () (activate-plugin! waiting-timer)))
         (check (wait-until (lambda () waiting)) => #t)
         (call-on-editor-loop (lambda () (deactivate-plugin! waiting-timer)))
         (check (wait-until (lambda () timer-quit?)) => #t)
         (check (call-on-editor-loop current-message) => "Quit"))))))
