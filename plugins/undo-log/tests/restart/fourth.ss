(import (tuna) (test) (test-user) (buffers) (commands) (files) (session))

(session:wait-for-restart!)

(test "after an exit that asked nothing about a modified buffer whose log holds its edits, the next start has them back"
  (check-equal? '("unsaved alpha\nbeta\ngamma\ndelta\n" #t) (list (session:text) (buffers:modified? (session:b)))))

(do ([i 0 (+ i 1)]) ((= i 200))
  (buffers:replace! (session:b) 1 1 "x")
  (test-user:settle))
(commands:run files:save-buffers-kill-tuna)
