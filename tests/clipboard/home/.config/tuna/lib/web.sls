#!tuna
;; Stands in for the web plugin, so no server starts: clients are records
;; the tests make, and the calls of their pages' procedures are kept.
(define-record-type client (fields number))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)
(define-table early-scripts)

(define (send-screen! client screen title) (void))

(define-hook client-added)
(define-hook client-removed)

(define connected '())

(define (clients) connected)

(define (add-client! n)
  (let ([c (make-client n)])
    (set! connected (append connected (list c)))
    (client-added c)
    c))

(define current-client (make-thread-parameter #f))

(define %calls '())

(define (call-page! client name value)
  (set! %calls (cons (list (client-number client) name value) %calls)))

(define (take-page-calls!)
  (let ([calls (reverse %calls)])
    (set! %calls '())
    calls))

(define (client-device client) (number->string (client-number client)))
