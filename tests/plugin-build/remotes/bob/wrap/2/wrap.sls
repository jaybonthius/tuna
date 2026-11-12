#!tuna
(include "build/paths.ss")

(define add
  (begin
    (load-shared-object shared-object)
    (foreign-procedure "cadd" (int int) int)))

(define (build-facts)
  (call-with-input-file (string-append (path-parent shared-object) "/facts.ss") read))
