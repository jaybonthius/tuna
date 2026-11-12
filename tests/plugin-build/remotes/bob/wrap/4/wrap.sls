#!tuna
(include "build/paths.ss")

(define add
  (begin
    (load-shared-object shared-object)
    (foreign-procedure "cadd" (int int) int)))

(car '())
