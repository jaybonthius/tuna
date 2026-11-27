#!tuna
(import (hooks) (tables))
;; Stands in for the web plugin, so no server starts: clients are records
;; the tests make, and the calls of their pages' procedures are kept.
(define-record-type client (fields number))

(tables:define-table input-handlers)
(tables:define-table scripts)
(tables:define-table stylesheets)
(tables:define-table early-scripts)

(define (send-screen! client screen title) (void))

(hooks:define-hook client-added)
(hooks:define-hook client-removed)

(define %connected '())

(define (clients) %connected)

(define (add-client! n)
  (let ([c (make-client n)])
    (set! %connected (append %connected (list c)))
    (client-added c)
    c))

(define current-client (make-thread-parameter #f))

(define %calls '())

(define (call-page! client name value)
  (set! %calls (cons (list (client-number client) name value) %calls)))

;; No page answers a stand-in client.
(define (ask-page client name value) #f)

(define (take-page-calls!)
  (let ([calls (reverse %calls)])
    (set! %calls '())
    calls))

