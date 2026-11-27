#!tuna
(import (web) (tables))

(define %owner #f)

(define (owner) %owner)

(define %upload-owner #f)

(define (upload-owner) %upload-owner)

(define (record-owner client item)
  (set! %owner (current-owner)))

(define (fail client item)
  (car '()))

(define (record-upload-owner client bytes)
  (set! %upload-owner (current-owner)))

(define (fail-upload client bytes)
  (car '()))

(tables:set! web:input-handlers "module-owner" record-owner)
(tables:set! web:input-handlers "module-fail" fail)
(tables:set! web:upload-handlers "module-owner" record-upload-owner)
(tables:set! web:upload-handlers "module-fail" fail-upload)
