#!tuna
;; Stands in for the web plugin, which this configuration lacks.
(define-record-type client (fields number))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)

(define-hook client-removed)

(define current-client (make-thread-parameter #f))
