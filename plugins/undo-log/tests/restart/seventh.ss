(import (tuna) (test) (test-user) (buffers) (commands) (files) (undo-log-test session))

(undo-log-test/session:wait-for-restart!)

(test "after a restart undo puts every cursor back where it was before the edit, and redo where it was after it"
  (check-equal? '("xalpha\nxbeta\nxgamma\n" #t) (list (undo-log-test/session:text) (buffers:modified? (undo-log-test/session:b))))
  (test-user:press! "C-/")
  (check-equal? '("alpha\nbeta\ngamma\n" (1 7 12)) (list (undo-log-test/session:text) (undo-log-test/session:points)))
  (test-user:press! "C-?")
  (check-equal? '("xalpha\nxbeta\nxgamma\n" (2 9 15)) (list (undo-log-test/session:text) (undo-log-test/session:points))))

(commands:run files:save-buffers-kill-tuna)
