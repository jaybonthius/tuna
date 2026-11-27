(import (tuna) (test) (buffers))

(define notes (buffers:make "notes" "Buy milk.\n"))

(import (files) (modes) (auto-mode) (python))

(test "after a restart a buffer has no mode until one is set, though one of its name had a mode before; a visited file's is chosen again"
  (check-equal? modes:fundamental (modes:major-mode notes))
  (check-equal? python:mode (modes:major-mode (files:visit (string-append (getenv "HOME") "/a.py")))))
