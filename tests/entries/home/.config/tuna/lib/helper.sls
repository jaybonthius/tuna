#!tuna
(define (shout name)
  (display (string-append "hello " name))
  (newline))
(define (wrap text name)
  (string-append "[" (text name) "]"))
(define (noted option value)
  (display (list 'noted value))
  (newline))
