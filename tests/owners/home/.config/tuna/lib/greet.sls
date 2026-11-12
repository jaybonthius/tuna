#!tuna
(define (text name)
  "The greeting for a name."
  (string-append "Hello, " name "!"))

(define shout (lambda (s) (string-upcase s)))

(define (module-name) (this-module))
