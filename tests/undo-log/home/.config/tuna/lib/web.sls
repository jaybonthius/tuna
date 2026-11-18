#!tuna
;; Stands in for the web plugin, so that no server starts.
(define-record-type client (fields number))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)
(define-table early-scripts)

(define-option title "Tuna" string?)

(define-hook client-removed)

(define current-client (make-thread-parameter #f))

(define (clients) '())

(define (call-page! client name value) (void))

(define (client-device client) (number->string (client-number client)))
