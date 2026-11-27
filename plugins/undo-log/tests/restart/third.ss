(import (tuna) (test) (test-user) (undo) (buffers) (commands) (files) (undo-log-test session))

(undo-log-test/session:wait-for-restart!)

(test "undone to the file's text before exit, the next start opens the file as it is, with the edit a redo away"
  (check-equal? '("alpha\nbeta\ngamma\ndelta\n" #f) (list (undo-log-test/session:text) (buffers:modified? (undo-log-test/session:b))))
  (buffers:with-buffer (undo-log-test/session:b) (commands:run undo:redo 1))
  (check-equal? '("unsaved alpha\nbeta\ngamma\ndelta\n" #t) (list (undo-log-test/session:text) (buffers:modified? (undo-log-test/session:b)))))

(test-user:settle)
(commands:run files:save-buffers-kill-tuna)
