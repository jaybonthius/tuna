#!tuna
;; Stands in for the web plugin, so no server starts: clients are records
;; the tests make.
(define-record-type client (fields number))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)

(define-hook client-removed)

(define current-client (make-thread-parameter #f))
