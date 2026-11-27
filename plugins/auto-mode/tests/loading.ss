(import (tuna) (test) (modes) (files) (buffers) (tables))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(call-with-output-file (home-file "three.py") (lambda (p) (put-string p "3\n")) 'replace)

(define three (files:visit (home-file "three.py")))

(import (auto-mode) (python))

(test "a buffer visited before auto-mode loads keeps its mode; normal-mode chooses again on request"
  (check-equal? modes:fundamental (modes:major-mode three))
  (auto-mode:normal-mode three)
  (check-equal? python:mode (modes:major-mode three)))

(test "a rule added keeps the modes of open buffers"
  (call-with-output-file (home-file "four.pyx") (lambda (p) (put-string p "4\n")) 'replace)
  (let ([b (files:visit (home-file "four.pyx"))])
    (tables:set! auto-mode:file-names "pyx" python:mode)
    (check-equal? modes:fundamental (modes:major-mode b))))
