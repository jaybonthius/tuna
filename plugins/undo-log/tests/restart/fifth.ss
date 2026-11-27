(import (tuna) (test) (undo) (buffers) (commands) (files) (undo-log-test session))

(undo-log-test/session:wait-for-restart!)

(test "exit waits for the log's writer even after many batches"
  (check-equal? '(231 204) (list (string-length (undo-log-test/session:text)) (length (undo:history (undo-log-test/session:b))))))

(undo:forget! (undo-log-test/session:b))
(buffers:replace! (undo-log-test/session:b) 1 1 "y")
(commands:run files:save-buffers-kill-tuna)
