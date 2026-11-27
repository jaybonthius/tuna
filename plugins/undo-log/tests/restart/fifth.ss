(import (tuna) (test) (undo) (buffers) (commands) (files) (session))

(session:wait-for-restart!)

(test "exit waits for the log's writer even after many batches"
  (check-equal? '(231 204) (list (string-length (session:text)) (length (undo:history (session:b))))))

(undo:forget! (session:b))
(buffers:replace! (session:b) 1 1 "y")
(commands:run files:save-buffers-kill-tuna)
