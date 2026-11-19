#!tuna
(import (web))

(define owner #f)

(define upload-owner #f)

(define (record-owner client item)
  (set! owner (current-owner)))

(define (fail client item)
  (car '()))

(define (record-upload-owner client bytes)
  (set! upload-owner (current-owner)))

(define (fail-upload client bytes)
  (car '()))

(table-set! web:input-handlers "module-owner" record-owner)
(table-set! web:input-handlers "module-fail" fail)
(table-set! web:upload-handlers "module-owner" record-upload-owner)
(table-set! web:upload-handlers "module-fail" fail-upload)
