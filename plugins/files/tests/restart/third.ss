(import (tuna) (test-runner) (commands) (files) (command-line) (files-test session))

(test-runner:wait-until (lambda () (files-test/session:showing? "c.txt")))

(commands:run files:save-buffers-kill-tuna)
