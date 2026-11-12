#!tuna
;; Stands in for the web plugin, so no server starts: clients are records
;; the tests make.
(define-record-type client (fields number))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)

(define-hook client-added)
(define-hook client-removed)

(define connected '())

(define (clients) connected)

(define (add-client! n)
  (let ([c (make-client n)])
    (set! connected (append connected (list c)))
    (client-added c)
    c))
