(import (tuna) (test) (modes) (buffers) (files) (faces) (tables) (syntax-highlighting) (chez-scheme) (syntax-highlighting-test marks)
        (syntax-highlighting-test log))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(test "chez-scheme registers a highlighter for its mode"
  (check (syntax-highlighting:highlighter? (tables:ref syntax-highlighting:highlighters chez-scheme:mode #f))))

(test "the documented log mode colours the lines that start with # in the comment face"
  (call-with-output-file (home-file "run.log") (lambda (p) (put-string p "start\n# note\nend\n")) 'replace)
  (let ([b (files:visit (home-file "run.log"))])
    (check-equal? syntax-highlighting-test/log:mode (modes:major-mode b))
    (syntax-highlighting-test/marks:faces-become b (list (list "# note\n" faces:comment)))))
