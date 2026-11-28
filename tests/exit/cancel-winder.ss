(import (tuna) (exit log) (exit keeper) (exit user))

(on-unload (lambda () (exit/log:note! "configuration unloading")))

(advice-add! exit-anyway?
  (lambda (next c)
    (exit/log:note! (if (cancelled? c) "asked about a cancel" "asked"))
    (next c)))

(dynamic-wind
  void
  (lambda () (exit))
  (lambda ()
    (let ([me (current-task)])
      (fork-task (lambda (restore) (cancel-task me 'quit)))
      (suspend (lambda (resume) (void))))))
