#!chez-lang/chez
(library (hello)
  (export greeting)
  (import (rnrs))
  (define (greeting name) (string-append "Hello, " name "!")))
