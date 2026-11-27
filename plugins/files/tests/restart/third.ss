(import (tuna) (test) (test-runner) (commands) (files) (command-line) (session))

(test-runner:wait-until (lambda () (session:showing? "c.txt")))

(test "a missing file is an empty buffer of one line, so +2 goes to line 1"
  (check-equal? '("c.txt" 1) (session:shown)))

(commands:run files:save-buffers-kill-tuna)
