#!tuna
(define (shout name)
  (display (string-append "hello " name))
  (newline))
(define (wrap text name)
  (string-append "[" (text name) "]"))
