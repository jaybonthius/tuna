(import (test) (test-runner))

(define (home name) (string-append (getenv "HOME") "/" name))

(define (passes file home)
  (let-values ([(status errors) (test-runner:run-file file home)])
    (check-equal? 0 status)
    (check-equal? "" errors)))

(test "a view an atom names by number comes back after a restart, numbered as before, with its cursors, place, folds, narrowing and the plugin's options"
  (passes "restart/views-first.ss" (home "views"))
  (passes "restart/views-second.ss" (home "views")))

(test "only views that atoms name by number are saved, so drawing atoms adds no view at a restart"
  (passes "restart/atoms.ss" (home "atoms"))
  (passes "restart/atoms.ss" (home "atoms"))
  (passes "restart/atoms-counted.ss" (home "atoms")))

(test "a saved view's buffer history and the buffers' last points outlast a restart, each waiting for a buffer of its name"
  (passes "restart/history-first.ss" (home "history"))
  (passes "restart/history-second.ss" (home "history")))

(test "the histories are written when Tuna idles, not after every batch"
  (passes "restart/history-idle.ss" (home "idle")))

(test "an entry whose buffer no start makes again goes at the first idle, so the saved histories do not grow at each restart"
  (passes "restart/gone-first.ss" (home "gone"))
  (passes "restart/gone-later.ss" (home "gone"))
  (passes "restart/gone-later.ss" (home "gone"))
  (passes "restart/gone-made-again.ss" (home "gone")))
