(import (tuna) (buffers) (files) (files-test session))

;; Killed, so the next start does not visit them again.
(for-each (lambda (name) (buffers:kill! (files:visit (files-test/session:home-path name)))) '("a.txt" "b.txt" "c.txt"))
(exit)
