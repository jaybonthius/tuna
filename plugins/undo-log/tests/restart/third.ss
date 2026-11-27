(import (tuna) (test) (test-user) (undo) (buffers) (commands) (files) (session))

(session:wait-for-restart!)

(test "undone to the file's text before exit, the next start opens the file as it is, with the edit a redo away"
  (check-equal? '("alpha\nbeta\ngamma\ndelta\n" #f) (list (session:text) (buffers:modified? (session:b))))
  (buffers:with-buffer (session:b) (commands:run undo:redo 1))
  (check-equal? '("unsaved alpha\nbeta\ngamma\ndelta\n" #t) (list (session:text) (buffers:modified? (session:b)))))

(test-user:settle)
(commands:run files:save-buffers-kill-tuna)
