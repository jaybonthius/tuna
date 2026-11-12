#!tuna
(import (web))

(define owner #f)

(define (record-owner client item)
  (set! owner (current-owner)))

(define (fail client item)
  (car '()))

(table-set! web:input-handlers "module-owner" record-owner)
(table-set! web:input-handlers "module-fail" fail)
