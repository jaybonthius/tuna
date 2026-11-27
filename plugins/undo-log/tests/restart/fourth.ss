(import (tuna) (test) (test-user) (buffers) (commands) (files) (undo-log-test session))

(undo-log-test/session:wait-for-restart!)

(test "after an exit that asked nothing about a modified buffer whose log holds its edits, the next start has them back"
  (check-equal? '("unsaved alpha\nbeta\ngamma\ndelta\n" #t) (list (undo-log-test/session:text) (buffers:modified? (undo-log-test/session:b)))))

(do ([i 0 (+ i 1)]) ((= i 200))
  (buffers:replace! (undo-log-test/session:b) 1 1 "x")
  (test-user:settle))
(commands:run files:save-buffers-kill-tuna)
