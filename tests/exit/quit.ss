(import (tuna) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(on-unload (lambda () (let loop ([i 0]) (when (< i 1000000) (loop (+ i 1)))) (exit/log:note! "busy unload ended")))

;; A user's quit cancels the main thread's task only while it runs.
(dynamic-wind
  void
  (lambda () (exit))
  (lambda ()
    (let ([me (current-task)])
      (join-task (fork-task (lambda (restore) (when (eq? (task-state me) 'running) (cancel-task me))))))))
