(import (tuna) (test-runner) (test-user) (buffers) (files) (command-line) (files-test session))

(test-runner:wait-until (lambda () (files-test/session:showing? "b.txt")))

(buffers:replace! (files:buffer-visiting (files-test/session:home-path "b.txt")) 1 1 "unsaved ")
(test-user:settle)
(exit)
